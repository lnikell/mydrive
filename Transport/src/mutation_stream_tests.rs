use super::*;
use crate::test_wire::{connection_no_rewrite, Empty};
use smb2::{
    msg::header::Header, pack::WriteCursor, transport::MockTransport, types::flags::HeaderFlags,
};
use std::{
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};

fn handle(connection: Connection, cancel: CancellationToken) -> Handle {
    Handle {
        connection,
        tree: TreeId(1),
        file: FileId {
            persistent: 2,
            volatile: 3,
        },
        cancel,
        closed: false,
    }
}

fn answer(mock: &MockTransport, sent: &[u8], status: NtStatus, body: &dyn Pack) {
    let request = Header::unpack(&mut ReadCursor::new(sent)).unwrap();
    let mut header = Header::new_request(request.command);
    header.message_id = request.message_id;
    header.flags = HeaderFlags::new(HeaderFlags::SERVER_TO_REDIR);
    header.status = status;
    header.credits = 8;
    let mut cursor = WriteCursor::new();
    header.pack(&mut cursor);
    body.pack(&mut cursor);
    mock.queue_response(cursor.into_inner());
}

async fn sent(mock: &MockTransport, count: usize) -> Vec<Vec<u8>> {
    tokio::time::timeout(Duration::from_secs(5), async {
        while mock.sent_count() < count {
            tokio::task::yield_now().await;
        }
        mock.sent_messages()
    })
    .await
    .expect("bounded pipeline did not issue its expected requests")
}

fn read_answer(mock: &MockTransport, sent: &[u8], short: bool) {
    let request = ReadRequest::unpack(&mut ReadCursor::new(&sent[64..])).unwrap();
    assert!(request.length as usize <= WIRE_BYTES);
    let length = request.length as usize - usize::from(short);
    answer(
        mock,
        sent,
        NtStatus::SUCCESS,
        &ReadResponse {
            data_offset: 80,
            data_remaining: 0,
            flags: 0,
            data: vec![(request.offset / WIRE_BYTES as u64) as u8; length],
        },
    );
}

fn write_answer(mock: &MockTransport, sent: &[u8], count: u32) {
    answer(
        mock,
        sent,
        NtStatus::SUCCESS,
        &WriteResponse {
            count,
            remaining: 0,
            write_channel_info_offset: 0,
            write_channel_info_length: 0,
        },
    );
}

fn bytes(chunks: usize) -> Vec<u8> {
    (0..chunks)
        .flat_map(|i| vec![i as u8; WIRE_BYTES])
        .collect()
}

struct LocalPayload {
    payload: VerifiedPayload,
    path: std::path::PathBuf,
}
impl Drop for LocalPayload {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}
async fn payload(bytes: &[u8]) -> LocalPayload {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let path = std::env::temp_dir().join(format!(
        "mydrive-stream-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    tokio::fs::write(&path, bytes).await.unwrap();
    LocalPayload {
        payload: VerifiedPayload {
            file: tokio::fs::File::open(&path).await.unwrap(),
            bytes: bytes.len() as u64,
            sha256: mutation::hex(&Sha256::digest(bytes)),
        },
        path,
    }
}

#[tokio::test]
async fn shuffled_hash_replies_keep_file_order_and_completed_ranges_count_toward_window() {
    let (connection, mock) = connection_no_rewrite().await;
    let handle = handle(connection.clone(), CancellationToken::new());
    let source = bytes(WINDOW + 1);
    let (result, ()) = tokio::join!(handle.hash(source.len() as u64), async {
        let batch = sent(&mock, WINDOW).await;
        assert_eq!(batch.len(), WINDOW);
        for request in batch[1..].iter().rev() {
            read_answer(&mock, request, false);
        }
        tokio::time::timeout(Duration::from_secs(5), async {
            while connection.outstanding_requests().len() != 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        // The seven buffered replies cannot admit an unbounded tail behind a
        // missing first response. Only one more range follows that first one.
        assert_eq!(mock.sent_count(), WINDOW);
        read_answer(&mock, &batch[0], false);
        let final_batch = sent(&mock, WINDOW + 1).await;
        assert_eq!(final_batch.len(), WINDOW + 1);
        read_answer(&mock, final_batch.last().unwrap(), false);
    });
    assert_eq!(result.unwrap(), mutation::hex(&Sha256::digest(&source)));
    assert!(connection.outstanding_requests().is_empty());
    let closing = handle.close();
    let (closed, ()) = tokio::join!(closing, async {
        let all = sent(&mock, WINDOW + 2).await;
        answer(
            &mock,
            all.last().unwrap(),
            NtStatus::SUCCESS,
            &crate::test_wire::Closed,
        );
    });
    closed.unwrap();
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn short_or_error_later_read_aborts_all_earlier_waiters_before_any_publication() {
    for short in [false, true] {
        let (connection, mock) = connection_no_rewrite().await;
        let handle = handle(connection.clone(), CancellationToken::new());
        let operation = async {
            let result = handle.hash((WIRE_BYTES * WINDOW) as u64).await;
            assert!(result.is_err());
        };
        let peer = async {
            let batch = sent(&mock, WINDOW).await;
            if short {
                read_answer(&mock, batch.last().unwrap(), true);
            } else {
                answer(&mock, batch.last().unwrap(), NtStatus(0xc000_0022), &Empty);
            }
        };
        tokio::time::timeout(Duration::from_secs(5), async {
            tokio::join!(operation, peer);
        })
        .await
        .unwrap();
        assert!(connection.outstanding_requests().is_empty());
        assert_eq!(mock.sent_count(), WINDOW);
        assert!(handle
            .execute(
                Command::Flush,
                &FlushRequest {
                    file_id: handle.file
                }
            )
            .await
            .is_err());
        assert_eq!(mock.sent_count(), WINDOW);
        drop(handle);
        mock.close();
    }
}

#[tokio::test]
async fn shuffled_short_writes_confirm_only_their_own_tail_and_report_contiguous_bytes() {
    let (connection, mock) = connection_no_rewrite().await;
    let handle = handle(connection.clone(), CancellationToken::new());
    let source = bytes(WINDOW + 1);
    let mut local = payload(&source).await;
    let mut progress = vec![];
    let mut record_progress = |n| progress.push(n);
    let (result, ()) = tokio::join!(
        handle.write_payload(&mut local.payload, &mut record_progress),
        async {
            let batch = sent(&mock, WINDOW).await;
            assert_eq!(batch.len(), WINDOW);
            for request in batch[1..].iter().rev() {
                write_answer(&mock, request, WIRE_BYTES as u32);
            }
            write_answer(&mock, &batch[0], (WIRE_BYTES / 2) as u32);
            let partial = sent(&mock, WINDOW + 1).await;
            let tail = WriteRequest::unpack(&mut ReadCursor::new(&partial[WINDOW][64..])).unwrap();
            assert_eq!(tail.offset, (WIRE_BYTES / 2) as u64);
            assert_eq!(tail.data, source[WIRE_BYTES / 2..WIRE_BYTES]);
            assert!(connection.outstanding_requests().len() <= WINDOW);
            write_answer(&mock, &partial[WINDOW], tail.data.len() as u32);
            let final_batch = sent(&mock, WINDOW + 2).await;
            let last =
                WriteRequest::unpack(&mut ReadCursor::new(&final_batch[WINDOW + 1][64..])).unwrap();
            assert_eq!(last.offset, (WIRE_BYTES * WINDOW) as u64);
            assert_eq!(last.data, source[WIRE_BYTES * WINDOW..]);
            write_answer(&mock, final_batch.last().unwrap(), last.data.len() as u32);
        }
    );
    result.unwrap();
    assert_eq!(
        progress,
        (1..=WINDOW + 1)
            .map(|n| (n * WIRE_BYTES) as u64)
            .collect::<Vec<_>>()
    );
    assert!(connection.outstanding_requests().is_empty());
    drop(handle);
    mock.close();
}

#[tokio::test]
async fn invalid_later_write_acknowledgement_stops_without_flush_or_publication() {
    let (connection, mock) = connection_no_rewrite().await;
    let handle = handle(connection.clone(), CancellationToken::new());
    let mut local = payload(&bytes(WINDOW + 1)).await;
    let mut ignore_progress = |_| {};
    let (result, ()) = tokio::join!(
        handle.write_payload(&mut local.payload, &mut ignore_progress),
        async {
            let batch = sent(&mock, WINDOW).await;
            write_answer(&mock, batch.last().unwrap(), 0);
        }
    );
    assert!(matches!(
        result,
        Err(Error::Smb(smb2::ErrorKind::InvalidData))
    ));
    assert_eq!(mock.sent_count(), WINDOW);
    assert!(connection.outstanding_requests().is_empty());
    drop(handle);
    mock.close();
}

#[tokio::test]
async fn changed_local_payload_length_or_hash_cannot_reach_flush_or_publication() {
    for truncated in [false, true] {
        let (connection, mock) = connection_no_rewrite().await;
        let handle = handle(connection.clone(), CancellationToken::new());
        let original = bytes(2);
        let mut local = payload(&original).await;
        let changed = if truncated {
            original[..WIRE_BYTES].to_vec()
        } else {
            vec![99; original.len()]
        };
        tokio::fs::write(&local.path, &changed).await.unwrap();
        let mut ignore_progress = |_| {};
        let (result, ()) = tokio::join!(
            handle.write_payload(&mut local.payload, &mut ignore_progress),
            async {
                let batch = sent(&mock, changed.len() / WIRE_BYTES).await;
                for message in &batch {
                    let request =
                        WriteRequest::unpack(&mut ReadCursor::new(&message[64..])).unwrap();
                    write_answer(&mock, message, request.data.len() as u32);
                }
            }
        );
        assert!(matches!(result, Err(Error::Changed)));
        assert!(connection.outstanding_requests().is_empty());
        let before = mock.sent_count();
        assert!(handle
            .execute(
                Command::Flush,
                &FlushRequest {
                    file_id: handle.file
                }
            )
            .await
            .is_err());
        assert_eq!(mock.sent_count(), before);
        assert_eq!(tokio::fs::read(&local.path).await.unwrap(), changed);
        drop(handle);
        mock.close();
    }
}

#[tokio::test]
async fn cancelling_or_dropping_read_and_write_windows_retires_every_owned_request() {
    for writing in [false, true] {
        for dropping in [false, true] {
            let (connection, mock) = connection_no_rewrite().await;
            let cancel = CancellationToken::new();
            let handle = handle(connection.clone(), cancel.clone());
            let mut local = payload(&bytes(WINDOW + 1)).await;
            {
                let operation = async {
                    if writing {
                        handle.write_payload(&mut local.payload, &mut |_| {}).await
                    } else {
                        handle
                            .hash((WIRE_BYTES * (WINDOW + 1)) as u64)
                            .await
                            .map(|_| ())
                    }
                };
                tokio::pin!(operation);
                tokio::select! { biased;
                    result = &mut operation => panic!("unanswered pipeline finished: {result:?}"),
                    _ = sent(&mock, WINDOW) => {},
                }
                assert_eq!(mock.sent_count(), WINDOW);
                if !dropping {
                    cancel.cancel();
                    let result = tokio::time::timeout(Duration::from_secs(5), operation)
                        .await
                        .unwrap();
                    assert!(matches!(result, Err(Error::Cancelled)));
                }
            }
            assert!(connection.outstanding_requests().is_empty());
            assert!(handle
                .execute(
                    Command::Flush,
                    &FlushRequest {
                        file_id: handle.file
                    }
                )
                .await
                .is_err());
            assert_eq!(mock.sent_count(), WINDOW);
            drop(handle);
            mock.close();
        }
    }
}
