//! Real SMB frames exercise the shared query-envelope boundary before delivery.
use super::*;

struct Envelope(Vec<u8>);
impl Envelope {
    fn new(offset: u16, buffer: &[u8]) -> Self {
        let mut body = Vec::from(9u16.to_le_bytes());
        body.extend_from_slice(&offset.to_le_bytes());
        body.extend_from_slice(&(buffer.len() as u32).to_le_bytes());
        body.extend_from_slice(buffer);
        Self(body)
    }
    fn padded(buffer: &[u8]) -> Self {
        let mut result = Self::new(80, buffer);
        result.0.splice(8..8, [0; 8]);
        result
    }
}
impl Pack for Envelope {
    fn pack(&self, cursor: &mut WriteCursor) {
        cursor.write_bytes(&self.0);
    }
}

fn assert_closed(mock: &MockTransport) {
    let sent = mock.sent_messages();
    assert_eq!(
        sent.iter()
            .filter(
                |bytes| Header::unpack(&mut ReadCursor::new(bytes)).unwrap().command
                    == Command::Close
            )
            .count(),
        1
    );
    assert_eq!(
        Header::unpack(&mut ReadCursor::new(sent.last().unwrap()))
            .unwrap()
            .command,
        Command::Close
    );
    let close =
        smb2::msg::close::CloseRequest::unpack(&mut ReadCursor::new(&sent.last().unwrap()[64..]))
            .unwrap();
    assert_eq!(
        close.file_id,
        FileId {
            persistent: 2,
            volatile: 3
        }
    );
    mock.assert_fully_consumed();
}

#[derive(Clone, Copy)]
enum FaultAt {
    Info(u8),
    Directory,
}

// Respond to each actual request so both old (incorrectly accepting) and fixed
// paths can finish their checked CLOSE without fake response-order failures.
async fn listing_fault(at: FaultAt, envelope: Envelope) -> (Result<Listing>, usize, usize) {
    let (connection, mock) = connection().await;
    opened(&mock);
    let handle = handle(connection).await;
    let mut started = 0;
    let mut pages = 0;
    let listing = read_reserved_observed(handle, None, "folder", None, |event| {
        match event {
            ListingObservation::Started(_) => started += 1,
            ListingObservation::Page(_) => pages += 1,
        }
        Ok(())
    });
    let responder = async {
        let mut next = 1; // CREATE was answered above.
        let mut injected = false;
        loop {
            let sent = mock.sent_messages();
            if next == sent.len() {
                tokio::task::yield_now().await;
                continue;
            }
            assert!(next < 12, "query did not reach bounded cleanup");
            let request = &sent[next];
            next += 1;
            let header = Header::unpack(&mut ReadCursor::new(request)).unwrap();
            match header.command {
                Command::QueryInfo => {
                    let query =
                        QueryInfoRequest::unpack(&mut ReadCursor::new(&request[64..])).unwrap();
                    if matches!(at, FaultAt::Info(class) if class == query.file_info_class)
                        && !injected
                    {
                        reply(&mock, Command::QueryInfo, &envelope);
                        injected = true;
                    } else {
                        let output_buffer = match query.file_info_class {
                            4 => {
                                let mut basic = vec![0; 40];
                                basic[..8].copy_from_slice(&55u64.to_le_bytes());
                                basic[16..24].copy_from_slice(&66u64.to_le_bytes());
                                basic[24..32].copy_from_slice(&77u64.to_le_bytes());
                                basic[32..36].copy_from_slice(&16u32.to_le_bytes());
                                basic
                            }
                            5 => {
                                let mut standard = vec![0; 24];
                                standard[21] = 1;
                                standard
                            }
                            6 => 44u64.to_le_bytes().to_vec(),
                            class => panic!("unexpected class {class}"),
                        };
                        reply(
                            &mock,
                            Command::QueryInfo,
                            &QueryInfoResponse { output_buffer },
                        );
                    }
                }
                Command::QueryDirectory => {
                    if matches!(at, FaultAt::Directory) && !injected {
                        reply(&mock, Command::QueryDirectory, &envelope);
                        injected = true;
                    } else {
                        status(&mock, Command::QueryDirectory, NtStatus::NO_MORE_FILES);
                    }
                }
                Command::Close => {
                    reply(&mock, Command::Close, &crate::test_wire::Closed);
                    break;
                }
                command => panic!("unexpected command {command:?}"),
            }
        }
        assert!(injected);
    };
    let (result, ()) = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        tokio::join!(listing, responder)
    })
    .await
    .unwrap();
    assert_closed(&mock);
    mock.close();
    (result, started, pages)
}

#[tokio::test]
async fn query_envelope_invalid_info_offsets_never_start_listing() {
    for class in [4, 6] {
        let mut buffer = if class == 4 {
            vec![0; 40]
        } else {
            44u64.to_le_bytes().to_vec()
        };
        if class == 4 {
            buffer[..8].copy_from_slice(&55u64.to_le_bytes());
            buffer[16..24].copy_from_slice(&66u64.to_le_bytes());
            buffer[24..32].copy_from_slice(&77u64.to_le_bytes());
            buffer[32..36].copy_from_slice(&16u32.to_le_bytes());
        }
        for offset in [0, 63, 64, 71] {
            let (result, started, pages) =
                listing_fault(FaultAt::Info(class), Envelope::new(offset, &buffer)).await;
            assert!(result.is_err(), "accepted class {class} offset {offset}");
            assert_eq!((started, pages), (0, 0));
        }
    }
}

#[tokio::test]
async fn query_envelope_info_cannot_exceed_its_requested_class_limit() {
    for (class, length) in [(4, 41), (6, 9)] {
        let mut buffer = vec![0; length];
        if class == 4 {
            buffer[..8].copy_from_slice(&55u64.to_le_bytes());
            buffer[16..24].copy_from_slice(&66u64.to_le_bytes());
            buffer[24..32].copy_from_slice(&77u64.to_le_bytes());
            buffer[32..36].copy_from_slice(&16u32.to_le_bytes());
        }
        if class == 6 {
            buffer[..8].copy_from_slice(&44u64.to_le_bytes());
        }
        let (result, started, pages) =
            listing_fault(FaultAt::Info(class), Envelope::new(72, &buffer)).await;
        assert!(result.is_err(), "accepted overlength class {class}");
        assert_eq!((started, pages), (0, 0));
    }
}

#[tokio::test]
async fn query_envelope_invalid_directory_offsets_deliver_no_children() {
    let buffer = batch(
        FileInformationClass::FileIdBothDirectoryInformation,
        "child",
    );
    for offset in [0, 63, 64, 71] {
        let (result, started, pages) =
            listing_fault(FaultAt::Directory, Envelope::new(offset, &buffer)).await;
        assert!(result.is_err(), "accepted directory offset {offset}");
        assert_eq!((started, pages), (1, 0));
    }
}

#[tokio::test]
async fn query_envelope_security_rejects_header_offsets_before_parsing_descriptor() {
    for offset in [0, 63, 64, 71] {
        let (connection, mock) = connection().await;
        opened(&mock);
        reply(
            &mock,
            Command::QueryInfo,
            &Envelope::new(offset, &crate::mutation_security::fixture()),
        );
        reply(&mock, Command::Close, &crate::test_wire::Closed);
        let handle = handle(connection).await;
        let result = handle.security().await;
        handle.close().await.unwrap();
        assert_closed(&mock);
        mock.close();
        assert!(result.is_err(), "accepted security offset {offset}");
    }
}

#[tokio::test]
async fn query_envelope_valid_padding_empty_and_request_boundaries_stay_compatible() {
    for body in [
        Envelope::new(72, &[7; 40]),
        Envelope::padded(&[7; 40]),
        Envelope::new(0, &[]),
        Envelope::new(72, &[]),
    ] {
        let (connection, mock) = connection().await;
        opened(&mock);
        reply(&mock, Command::QueryInfo, &body);
        reply(&mock, Command::Close, &crate::test_wire::Closed);
        let handle = handle(connection).await;
        let result = handle.query(4, 40).await.unwrap();
        handle.close().await.unwrap();
        assert_eq!(
            result,
            if body.0.len() == 8 {
                vec![]
            } else {
                vec![7; 40]
            }
        );
        assert_closed(&mock);
        mock.close();
    }
    let security = crate::mutation_security::fixture();
    let (connection, mock) = connection().await;
    opened(&mock);
    reply(&mock, Command::QueryInfo, &Envelope::padded(&security));
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    let handle = handle(connection).await;
    let result = handle.security().await.unwrap();
    handle.close().await.unwrap();
    result
        .require_same(&crate::mutation_security::AccessSecurity::parse(security).unwrap())
        .unwrap();
    assert_closed(&mock);
    mock.close();
}

#[tokio::test]
async fn query_envelope_truncation_and_huge_declarations_remain_frame_bounded() {
    for body in [
        Envelope(vec![]),
        Envelope(vec![9; 7]),
        Envelope::new(73, &[0; 40]),
        {
            let mut body = Envelope::new(72, &[0; 40]);
            body.0[4..8].copy_from_slice(&u32::MAX.to_le_bytes());
            body
        },
    ] {
        let (result, started, pages) = listing_fault(FaultAt::Info(4), body).await;
        assert!(result.is_err());
        assert_eq!((started, pages), (0, 0));
    }
}
