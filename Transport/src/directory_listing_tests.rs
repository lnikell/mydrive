//! Actual SMB frames exercise handle identity and bounded scan completion.
use super::*;
use crate::test_wire::{connection, reply};
use smb2::{
    msg::{
        create::{CreateAction, CreateRequest, CreateResponse},
        directory_info::DirectoryInfoEntry,
        header::Header,
        query_directory::QueryDirectoryResponse,
        query_info::{QueryInfoRequest, QueryInfoResponse},
    },
    pack::{FileTime, Pack, ReadCursor, Unpack, WriteCursor},
    transport::MockTransport,
    types::{flags::HeaderFlags, FileId, OplockLevel, TreeId},
};

fn status(mock: &MockTransport, command: Command, status: NtStatus) {
    let mut header = Header::new_request(command);
    header.flags = HeaderFlags::new(HeaderFlags::SERVER_TO_REDIR);
    header.status = status;
    header.credits = 8;
    let mut bytes = WriteCursor::new();
    header.pack(&mut bytes);
    mock.queue_response(bytes.into_inner());
}

fn opened(mock: &MockTransport) {
    opened_at(
        mock,
        FileId {
            persistent: 2,
            volatile: 3,
        },
        16,
    );
}

fn opened_at(mock: &MockTransport, file_id: FileId, attributes: u32) {
    reply(
        mock,
        Command::Create,
        &CreateResponse {
            oplock_level: OplockLevel::None,
            flags: 0,
            create_action: CreateAction::FileOpened,
            creation_time: FileTime(55),
            last_access_time: FileTime(0),
            last_write_time: FileTime(66),
            change_time: FileTime(77),
            allocation_size: 0,
            end_of_file: 0,
            file_attributes: attributes,
            file_id,
            create_contexts: vec![],
        },
    );
}

fn observed_file(mock: &MockTransport) {
    let mut basic = vec![0; 40];
    basic[..8].copy_from_slice(&1u64.to_le_bytes());
    basic[16..24].copy_from_slice(&2u64.to_le_bytes());
    basic[24..32].copy_from_slice(&3u64.to_le_bytes());
    basic[32..36].copy_from_slice(&32u32.to_le_bytes());
    let mut standard = vec![0; 24];
    standard[8..16].copy_from_slice(&4u64.to_le_bytes());
    for output_buffer in [basic, standard, 9u64.to_le_bytes().to_vec()] {
        reply(
            mock,
            Command::QueryInfo,
            &QueryInfoResponse { output_buffer },
        );
    }
}

fn observed(mock: &MockTransport, index: u64, attributes: u32) {
    let mut basic = vec![0; 40];
    basic[..8].copy_from_slice(&55u64.to_le_bytes());
    basic[16..24].copy_from_slice(&66u64.to_le_bytes());
    basic[24..32].copy_from_slice(&77u64.to_le_bytes());
    basic[32..36].copy_from_slice(&attributes.to_le_bytes());
    let mut standard = vec![0; 24];
    standard[21] = u8::from(attributes & 16 != 0);
    for output_buffer in [basic, standard, index.to_le_bytes().to_vec()] {
        reply(
            mock,
            Command::QueryInfo,
            &QueryInfoResponse { output_buffer },
        );
    }
}

fn batch(class: FileInformationClass, name: &str) -> Vec<u8> {
    directory_info::pack_entries(
        class,
        &[DirectoryInfoEntry {
            file_name: name.to_owned(),
            file_id: Some(9),
            creation_time: FileTime(1),
            last_write_time: FileTime(2),
            change_time: FileTime(3),
            end_of_file: 4,
            file_attributes: 32,
            ..Default::default()
        }],
    )
    .unwrap()
}

async fn handle(connection: Connection) -> Handle {
    Handle::open(
        connection,
        TreeId(1),
        "folder",
        Open::Enumerate,
        &CancellationToken::new(),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn complete_listing_observes_the_actual_reserved_handle_before_and_after_query() {
    let (connection, mock) = connection().await;
    opened(&mock);
    observed(&mock, 44, 16);
    reply(
        &mock,
        Command::QueryDirectory,
        &QueryDirectoryResponse {
            output_buffer: batch(
                FileInformationClass::FileIdBothDirectoryInformation,
                "cafe\u{301}.txt",
            ),
        },
    );
    status(&mock, Command::QueryDirectory, NtStatus::NO_MORE_FILES);
    observed(&mock, 44, 16);
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    let mut names = vec![];
    let result = read_reserved(handle(connection).await, None, "folder", None, |entries| {
        names.extend(entries.into_iter().map(|entry| entry.name));
        Ok(())
    })
    .await
    .unwrap();
    assert!(result.complete);
    assert_eq!(result.entries, 1);
    assert_eq!(result.entry.index_number, Some(44));
    assert_eq!(result.entry.created_filetime, 55);
    assert_eq!(names[0].as_bytes(), "cafe\u{301}.txt".as_bytes());
    let sent = mock.sent_messages();
    let create = CreateRequest::unpack(&mut ReadCursor::new(&sent[0][64..])).unwrap();
    assert_eq!(
        create.share_access.0,
        smb2::msg::create::ShareAccess::FILE_SHARE_READ
    );
    assert_ne!(create.create_options & 0x0020_0000, 0);
    assert_ne!(create.create_options & 1, 0);
    assert_ne!(create.desired_access.bits() & 1, 0); // FILE_LIST_DIRECTORY
    for data in sent.iter().skip(1) {
        let frame = Header::unpack(&mut ReadCursor::new(data)).unwrap();
        let id = match frame.command {
            Command::QueryInfo => {
                QueryInfoRequest::unpack(&mut ReadCursor::new(&data[64..]))
                    .unwrap()
                    .file_id
            }
            Command::QueryDirectory => {
                QueryDirectoryRequest::unpack(&mut ReadCursor::new(&data[64..]))
                    .unwrap()
                    .file_id
            }
            Command::Close => {
                smb2::msg::close::CloseRequest::unpack(&mut ReadCursor::new(&data[64..]))
                    .unwrap()
                    .file_id
            }
            other => panic!("unexpected command {other:?}"),
        };
        assert_eq!(
            id,
            FileId {
                persistent: 2,
                volatile: 3
            }
        );
    }
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn page_limit_returns_partial_and_class_fallback_stays_on_original_handle() {
    let (connection, mock) = connection().await;
    opened(&mock);
    observed(&mock, 44, 16);
    status(&mock, Command::QueryDirectory, NtStatus::INVALID_INFO_CLASS);
    reply(
        &mock,
        Command::QueryDirectory,
        &QueryDirectoryResponse {
            output_buffer: batch(FileInformationClass::FileBothDirectoryInformation, "file"),
        },
    );
    opened_at(
        &mock,
        FileId {
            persistent: 4,
            volatile: 5,
        },
        32,
    );
    observed_file(&mock);
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    observed(&mock, 44, 16);
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    let listing = read_reserved(
        handle(connection).await,
        None,
        "folder",
        Some(1),
        |entries| {
            assert_eq!(entries[0].index_number, Some(9));
            Ok(())
        },
    )
    .await
    .unwrap();
    assert!(!listing.complete);
    assert_eq!(listing.entries, 1);
    assert_eq!(listing.entry.index_number, Some(44));
    let queries: Vec<_> = mock
        .sent_messages()
        .iter()
        .filter(|data| {
            Header::unpack(&mut ReadCursor::new(data)).unwrap().command == Command::QueryDirectory
        })
        .map(|data| QueryDirectoryRequest::unpack(&mut ReadCursor::new(&data[64..])).unwrap())
        .collect();
    assert_eq!(queries.len(), 2);
    assert_eq!(queries[0].file_id, queries[1].file_id);
    assert_eq!(queries[1].flags.0, QueryDirectoryFlags::RESTART_SCANS);
    mock.assert_fully_consumed();
    mock.close();
}

#[path = "directory_fallback_tests.rs"]
mod fallback;

#[tokio::test]
async fn unqualified_directory_or_post_listing_identity_never_returns_completion() {
    for (before_index, before_attributes, after_index) in
        [(0, 16, None), (44, 16 | 0x400, None), (44, 16, Some(45))]
    {
        let (connection, mock) = connection().await;
        opened(&mock);
        observed(&mock, before_index, before_attributes);
        if let Some(after_index) = after_index {
            status(&mock, Command::QueryDirectory, NtStatus::NO_MORE_FILES);
            observed(&mock, after_index, 16);
        }
        reply(&mock, Command::Close, &crate::test_wire::Closed);
        assert!(
            read_reserved(handle(connection).await, None, "folder", None, |_| Ok(()))
                .await
                .is_err()
        );
        mock.assert_fully_consumed();
        mock.close();
    }
}

#[tokio::test]
async fn truncated_batch_and_failed_close_cannot_claim_a_complete_scan() {
    for close_fails in [false, true] {
        let (connection, mock) = connection().await;
        opened(&mock);
        observed(&mock, 44, 16);
        if close_fails {
            status(&mock, Command::QueryDirectory, NtStatus::NO_MORE_FILES);
            observed(&mock, 44, 16);
            status(&mock, Command::Close, NtStatus::ACCESS_DENIED);
        } else {
            let mut bytes = batch(FileInformationClass::FileIdBothDirectoryInformation, "file");
            bytes.pop();
            reply(
                &mock,
                Command::QueryDirectory,
                &QueryDirectoryResponse {
                    output_buffer: bytes,
                },
            );
            reply(&mock, Command::Close, &crate::test_wire::Closed);
        }
        assert!(
            read_reserved(handle(connection).await, None, "folder", None, |_| panic!(
                "no valid batch"
            ))
            .await
            .is_err()
        );
        mock.assert_fully_consumed();
        mock.close();
    }
}

#[tokio::test]
async fn cancelled_query_releases_owner_without_sending_another_listing_request() {
    let (connection, mock) = connection().await;
    opened(&mock);
    observed(&mock, 44, 16);
    let handle = handle(connection).await;
    let cancel = handle.cancel.clone();
    let future = read_reserved(handle, None, "folder", None, |_| Ok(()));
    tokio::pin!(future);
    tokio::select! {
        biased;
        result = &mut future => panic!("unexpected completion {result:?}"),
        _ = async { while mock.sent_messages().len() < 5 { tokio::task::yield_now().await; } } => cancel.cancel(),
    }
    assert!(matches!(future.await, Err(Error::Cancelled)));
    let count = mock
        .sent_messages()
        .iter()
        .filter(|data| {
            Header::unpack(&mut ReadCursor::new(data)).unwrap().command == Command::QueryDirectory
        })
        .count();
    assert_eq!(count, 1);
    mock.close();
}

#[tokio::test]
async fn observed_listing_starts_on_the_held_handle_before_pages_and_failure_never_completes() {
    for fail_after_page in [false, true] {
        let (connection, mock) = connection().await;
        opened(&mock);
        observed(&mock, 44, 16);
        reply(
            &mock,
            Command::QueryDirectory,
            &QueryDirectoryResponse {
                output_buffer: batch(
                    FileInformationClass::FileIdBothDirectoryInformation,
                    "first.txt",
                ),
            },
        );
        if fail_after_page {
            status(&mock, Command::QueryDirectory, NtStatus::ACCESS_DENIED);
        } else {
            status(&mock, Command::QueryDirectory, NtStatus::NO_MORE_FILES);
            observed(&mock, 44, 16);
        }
        reply(&mock, Command::Close, &crate::test_wire::Closed);
        let mut events = vec![];
        let result =
            read_reserved_observed(handle(connection).await, None, "folder", None, |event| {
                events.push(match event {
                    ListingObservation::Started(entry) => {
                        assert_eq!(entry.index_number, Some(44));
                        "start"
                    }
                    ListingObservation::Page(entries) => {
                        assert_eq!(entries[0].name, "first.txt");
                        "page"
                    }
                });
                Ok(())
            })
            .await;
        assert_eq!(events, ["start", "page"]);
        assert_eq!(result.is_err(), fail_after_page);
        mock.close();
    }
}

#[tokio::test]
async fn rejected_start_closes_handle_without_querying_or_exposing_children() {
    let (connection, mock) = connection().await;
    opened(&mock);
    observed(&mock, 44, 16);
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    let result = read_reserved_observed(handle(connection).await, None, "folder", None, |event| {
        assert!(matches!(event, ListingObservation::Started(_)));
        Err(Error::Changed)
    })
    .await;
    assert!(matches!(result, Err(Error::Changed)));
    assert_eq!(mock.sent_messages().len(), 5);
    mock.close();
}

#[path = "query_envelope_tests.rs"]
mod query_envelope;
