//! Exercise the real raw-handle module through smb2's transport demultiplexer.
//! Canned SMB replies never open a socket or authenticate to a NAS.
use super::*;
use crate::test_wire::{connection, reply, Empty};
use sha2::{Digest, Sha256};
use smb2::{
    msg::{create::CreateAction, header::Header},
    pack::{FileTime, WriteCursor},
    transport::MockTransport,
    types::flags::HeaderFlags,
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
fn written(count: u32) -> WriteResponse {
    WriteResponse {
        count,
        remaining: 0,
        write_channel_info_offset: 0,
        write_channel_info_length: 0,
    }
}

#[tokio::test]
async fn short_writes_advance_only_confirmed_bytes_on_the_same_handle() {
    let (connection, mock) = connection().await;
    reply(&mock, Command::Write, &written(2));
    reply(&mock, Command::Write, &written(1));
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    let handle = handle(connection, CancellationToken::new());
    handle.write_all(10, b"abc").await.unwrap();
    handle.close().await.unwrap();
    let sent = mock.sent_messages();
    let first = WriteRequest::unpack(&mut ReadCursor::new(&sent[0][64..])).unwrap();
    let second = WriteRequest::unpack(&mut ReadCursor::new(&sent[1][64..])).unwrap();
    assert_eq!((first.offset, first.data), (10, b"abc".to_vec()));
    assert_eq!((second.offset, second.data), (12, b"c".to_vec()));
    assert_eq!(first.file_id, second.file_id);
    mock.close();
}

#[tokio::test]
async fn zero_or_oversized_write_acknowledgement_never_loops_or_advances() {
    for count in [0, 4] {
        let (connection, mock) = connection().await;
        reply(&mock, Command::Write, &written(count));
        let handle = handle(connection, CancellationToken::new());
        assert!(matches!(
            handle.write_all(0, b"abc").await,
            Err(Error::Smb(smb2::ErrorKind::InvalidData))
        ));
        assert_eq!(mock.sent_messages().len(), 1);
        drop(handle);
        mock.close();
    }
}

#[tokio::test]
async fn destructive_open_denies_other_smb_writers_and_deleters_and_does_not_follow_links() {
    let (connection, mock) = connection().await;
    reply(
        &mock,
        Command::Create,
        &CreateResponse {
            oplock_level: OplockLevel::None,
            flags: 0,
            create_action: CreateAction::FileOpened,
            creation_time: FileTime(1),
            last_access_time: FileTime(2),
            last_write_time: FileTime(3),
            change_time: FileTime(4),
            allocation_size: 4096,
            end_of_file: 3,
            file_attributes: 32,
            file_id: FileId {
                persistent: 2,
                volatile: 3,
            },
            create_contexts: vec![],
        },
    );
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    Handle::open(
        connection,
        TreeId(1),
        "parent/file",
        Open::Guarded,
        &CancellationToken::new(),
    )
    .await
    .unwrap()
    .close()
    .await
    .unwrap();
    let sent = mock.sent_messages();
    let create = CreateRequest::unpack(&mut ReadCursor::new(&sent[0][64..])).unwrap();
    assert_eq!(create.share_access.0, ShareAccess::FILE_SHARE_READ);
    assert!(create.desired_access.contains(FileAccessMask::DELETE));
    assert_eq!(create.create_disposition, CreateDisposition::FileOpen);
    assert_ne!(create.create_options & 0x0020_0000, 0);
    mock.close();
}

#[tokio::test]
async fn read_ancestor_reservation_denies_conversion_and_rejects_reparse_directories() {
    for attributes in [16u32, 16 | 0x400] {
        let (connection, mock) = connection().await;
        reply(
            &mock,
            Command::Create,
            &CreateResponse {
                oplock_level: OplockLevel::None,
                flags: 0,
                create_action: CreateAction::FileOpened,
                creation_time: FileTime(1),
                last_access_time: FileTime(1),
                last_write_time: FileTime(1),
                change_time: FileTime(1),
                allocation_size: 0,
                end_of_file: 0,
                file_attributes: attributes,
                file_id: FileId {
                    persistent: 2,
                    volatile: 3,
                },
                create_contexts: vec![],
            },
        );
        if attributes & 0x400 == 0 {
            reply(&mock, Command::Close, &crate::test_wire::Closed);
        }
        let result = Handle::open(
            connection,
            TreeId(1),
            "parent",
            Open::ReadParent,
            &CancellationToken::new(),
        )
        .await;
        if attributes & 0x400 == 0 {
            result.unwrap().close().await.unwrap();
        } else {
            assert!(matches!(
                result,
                Err(Error::Smb(smb2::ErrorKind::Unsupported))
            ));
        }
        let sent = mock.sent_messages();
        let request = CreateRequest::unpack(&mut ReadCursor::new(&sent[0][64..])).unwrap();
        assert_eq!(request.share_access.0, ShareAccess::FILE_SHARE_READ);
        assert_ne!(request.create_options & 1, 0);
        assert_ne!(request.create_options & 0x0020_0000, 0);
        assert_eq!(
            request.desired_access.bits()
                & (FileAccessMask::FILE_WRITE_DATA | FileAccessMask::DELETE),
            0
        );
        mock.assert_fully_consumed();
        mock.close();
    }
}

#[tokio::test]
async fn cancelling_an_inflight_write_invalidates_the_session_without_replay() {
    let (connection, mock) = connection().await;
    let cancel = CancellationToken::new();
    let handle = handle(connection.clone(), cancel.clone());
    {
        let write = handle.write_all(0, b"abc");
        tokio::pin!(write);
        tokio::select! {biased;result=&mut write=>panic!("unexpected result {result:?}"),_=async{while mock.sent_messages().is_empty(){tokio::task::yield_now().await;}}=>cancel.cancel()}
        assert!(matches!(write.await, Err(Error::Cancelled)));
    }
    assert_eq!(mock.sent_messages().len(), 1);
    drop(handle);
    let later = tokio::time::timeout(
        std::time::Duration::from_secs(1),
        connection.execute(
            Command::Close,
            &CloseRequest {
                flags: 0,
                file_id: FileId {
                    persistent: 2,
                    volatile: 3,
                },
            },
            Some(TreeId(1)),
        ),
    )
    .await;
    assert!(later.unwrap().is_err());
    mock.close();
}

fn create_reply(mock: &MockTransport, id: u64) {
    reply(
        mock,
        Command::Create,
        &CreateResponse {
            oplock_level: OplockLevel::None,
            flags: 0,
            create_action: CreateAction::FileOpened,
            creation_time: FileTime(1),
            last_access_time: FileTime(2),
            last_write_time: FileTime(3),
            change_time: FileTime(4),
            allocation_size: 4096,
            end_of_file: 3,
            file_attributes: 32,
            file_id: FileId {
                persistent: id,
                volatile: id,
            },
            create_contexts: vec![],
        },
    );
}
fn query_reply(mock: &MockTransport, data: Vec<u8>) {
    reply(
        mock,
        Command::QueryInfo,
        &QueryInfoResponse {
            output_buffer: data,
        },
    );
}

#[tokio::test]
async fn ignored_or_denied_security_at_create_never_uploads_or_archives_bytes() {
    for denied in [false, true] {
        let (connection, mock) = connection().await;
        create_reply(&mock, 1);
        let mut basic = vec![0; 40];
        basic[0..8].copy_from_slice(&1u64.to_le_bytes());
        basic[16..24].copy_from_slice(&3u64.to_le_bytes());
        basic[24..32].copy_from_slice(&4u64.to_le_bytes());
        basic[32..36].copy_from_slice(&32u32.to_le_bytes());
        let mut standard = vec![0; 24];
        standard[8..16].copy_from_slice(&3u64.to_le_bytes());
        standard[16..20].copy_from_slice(&1u32.to_le_bytes());
        for data in [
            basic,
            standard.clone(),
            9u64.to_le_bytes().to_vec(),
            standard,
            vec![0; 4],
            vec![],
            crate::mutation_security::fixture(),
        ] {
            query_reply(&mock, data);
        }
        if denied {
            let mut header = Header::new_request(Command::Create);
            header.flags = HeaderFlags::new(HeaderFlags::SERVER_TO_REDIR);
            header.status = NtStatus(0xC000_0022);
            header.credits = 8;
            let mut packed = WriteCursor::new();
            header.pack(&mut packed);
            mock.queue_response(packed.into_inner());
        } else {
            create_reply(&mock, 2);
            let mut widened = crate::mutation_security::fixture();
            widened[16..20].copy_from_slice(&0u32.to_le_bytes());
            query_reply(&mock, widened);
            reply(&mock, Command::Close, &crate::test_wire::Closed);
            reply(&mock, Command::Close, &crate::test_wire::Closed);
        }
        let mut io = MutationIO {
            connection,
            tree: TreeId(1),
            cancel: CancellationToken::new(),
            parents: vec![],
        };
        let request = mutation::MutationRequest {
            operation_id: "11111111-2222-4333-8444-555555555555".into(),
            kind: mutation::MutationKind::ReplaceFile,
            path: "file".into(),
            parent: mutation::DirectoryIdentity {
                index_number: 5,
                created_filetime: 6,
            },
            delete_scope: None,
            tree_scope: None,
            destination: None,
            destination_parent: None,
            expected: Some(Entry {
                name: "file".into(),
                bytes: 3,
                directory: false,
                index_number: Some(9),
                created_filetime: 1,
                modified_filetime: 3,
                changed_filetime: 4,
                attributes: 32,
            }),
            payload: Some(mutation::Payload {
                source: "/tmp/unused".into(),
                bytes: 3,
                sha256: "a".repeat(64),
            }),
            receipt: mutation::Receipt::default(),
        };
        let result = io.allocate(&request, &request.sidecar("stage")).await;
        assert!(matches!(
            result,
            Err(Error::Smb(
                smb2::ErrorKind::AccessDenied | smb2::ErrorKind::Unsupported
            ))
        ));
        let commands: Vec<_> = mock
            .sent_messages()
            .iter()
            .map(|bytes| Header::unpack(&mut ReadCursor::new(bytes)).unwrap().command)
            .collect();
        assert!(!commands.contains(&Command::Write));
        assert!(!commands.contains(&Command::SetInfo));
        let sent = mock.sent_messages();
        let created: Vec<_> = sent
            .iter()
            .filter_map(|bytes| {
                let header = Header::unpack(&mut ReadCursor::new(bytes)).ok()?;
                (header.command == Command::Create)
                    .then(|| CreateRequest::unpack(&mut ReadCursor::new(&bytes[64..])).unwrap())
            })
            .collect();
        let contexts =
            smb2::msg::create_context::parse_contexts(&created[1].create_contexts).unwrap();
        assert_eq!(contexts[0].name, b"SecD");
        mock.close();
    }
}

fn observation_reply(mock: &MockTransport, modified: u64, changed: u64) {
    let mut basic = vec![0; 40];
    basic[0..8].copy_from_slice(&1u64.to_le_bytes());
    basic[16..24].copy_from_slice(&modified.to_le_bytes());
    basic[24..32].copy_from_slice(&changed.to_le_bytes());
    basic[32..36].copy_from_slice(&32u32.to_le_bytes());
    let mut standard = vec![0; 24];
    standard[8..16].copy_from_slice(&3u64.to_le_bytes());
    standard[16..20].copy_from_slice(&1u32.to_le_bytes());
    for data in [basic, standard, 9u64.to_le_bytes().to_vec()] {
        query_reply(mock, data);
    }
}

fn plain_reply(mock: &MockTransport) {
    let mut standard = vec![0; 24];
    standard[16..20].copy_from_slice(&1u32.to_le_bytes());
    query_reply(mock, standard);
    query_reply(mock, vec![0; 4]);
    query_reply(mock, vec![]);
}

#[tokio::test]
async fn prepared_receipt_observes_and_hashes_the_closed_writer() {
    let (connection, mock) = connection().await;
    create_reply(&mock, 2);
    observation_reply(&mock, 3, 4);
    plain_reply(&mock);
    query_reply(&mock, crate::mutation_security::fixture());
    reply(&mock, Command::SetInfo, &Empty); // Reset only the acknowledged allocation.
    reply(&mock, Command::Write, &written(3));
    reply(&mock, Command::Flush, &Empty);
    observation_reply(&mock, 3, 4);
    query_reply(&mock, crate::mutation_security::fixture());
    reply(&mock, Command::Flush, &Empty);
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    create_reply(&mock, 2);
    observation_reply(&mock, 10, 11);
    plain_reply(&mock);
    query_reply(&mock, crate::mutation_security::fixture());
    reply(
        &mock,
        Command::Read,
        &ReadResponse {
            data_offset: 80,
            data_remaining: 0,
            flags: 0,
            data: b"abc".to_vec(),
        },
    );
    observation_reply(&mock, 10, 11);
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    let root = std::env::temp_dir().join(format!("mydrive-stage-lifetime-{}", std::process::id()));
    tokio::fs::create_dir_all(&root).await.unwrap();
    let source = root.join("payload");
    tokio::fs::write(&source, b"abc").await.unwrap();
    let payload = mutation::Payload {
        source: source.to_string_lossy().into(),
        bytes: 3,
        sha256: mutation::hex(&Sha256::digest(b"abc")),
    };
    let cancel = CancellationToken::new();
    let mut verified = VerifiedPayload::open(&payload, &cancel).await.unwrap();
    let mut request = MutationRequest {
        operation_id: "11111111-2222-4333-8444-555555555555".into(),
        kind: mutation::MutationKind::CreateFile,
        path: "file".into(),
        parent: mutation::DirectoryIdentity {
            index_number: 5,
            created_filetime: 6,
        },
        delete_scope: None,
        tree_scope: None,
        destination: None,
        destination_parent: None,
        expected: None,
        payload: Some(payload),
        receipt: mutation::Receipt::default(),
    };
    request.receipt.staged = Some(mutation::Artifact {
        path: request.sidecar("stage"),
        entry: Entry {
            name: "stage".into(),
            bytes: 0,
            directory: false,
            index_number: Some(9),
            created_filetime: 1,
            modified_filetime: 2,
            changed_filetime: 2,
            attributes: 32,
        },
        cleanup_safe: true,
        phase: mutation::StagePhase::Allocated,
        security_sha256: Some(
            crate::mutation_security::AccessSecurity::parse(crate::mutation_security::fixture())
                .unwrap()
                .fingerprint(),
        ),
    });
    request.validate().unwrap();
    let mut io = MutationIO {
        connection,
        tree: TreeId(1),
        cancel,
        parents: vec![],
    };
    let mut samples = vec![];
    let result = io
        .stage(
            &request,
            &request.sidecar("stage"),
            Some(&mut verified),
            &mut |bytes| samples.push(bytes),
        )
        .await
        .unwrap();
    assert_eq!(
        (result.modified_filetime, result.changed_filetime),
        (10, 11)
    );
    assert_eq!(samples, [3]);
    let sent = mock.sent_messages();
    let opens: Vec<_> = sent
        .iter()
        .filter(|m| Header::unpack(&mut ReadCursor::new(m)).unwrap().command == Command::Create)
        .map(|m| CreateRequest::unpack(&mut ReadCursor::new(&m[64..])).unwrap())
        .collect();
    assert!(opens
        .iter()
        .all(|r| r.create_disposition == CreateDisposition::FileOpen));
    mock.assert_fully_consumed();
    mock.close();
    drop(verified);
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn name_derived_hidden_attribute_is_the_only_accepted_rename_delta() {
    for (source, destination, before, after, accepted) in [
        (".mydrive.stage", "folder", 18u32, 16u32, true),
        ("folder", ".mydrive.backup", 16, 18, true),
        (".stage", ".other", 18, 16, false),
        ("folder", "other", 16, 18, false),
        (".stage", "folder", 18, 17, false),
        (".stage", "folder", 16, 18, false),
        ("folder", ".backup", 18, 16, false),
    ] {
        let (connection, mock) = connection().await;
        let observed = |attributes: u32| {
            let mut basic = vec![0; 40];
            basic[0..8].copy_from_slice(&1u64.to_le_bytes());
            basic[16..24].copy_from_slice(&3u64.to_le_bytes());
            basic[24..32].copy_from_slice(&4u64.to_le_bytes());
            basic[32..36].copy_from_slice(&attributes.to_le_bytes());
            let mut standard = vec![0; 24];
            standard[16..20].copy_from_slice(&1u32.to_le_bytes());
            standard[21] = 1;
            for data in [basic, standard, 9u64.to_le_bytes().to_vec()] {
                query_reply(&mock, data);
            }
        };
        observed(before);
        reply(&mock, Command::SetInfo, &Empty);
        observed(after);
        reply(&mock, Command::Close, &crate::test_wire::Closed);
        let handle = handle(connection, CancellationToken::new());
        let expected = Entry {
            name: source.into(),
            bytes: 0,
            directory: true,
            index_number: Some(9),
            created_filetime: 1,
            modified_filetime: 3,
            changed_filetime: 4,
            attributes: before,
        };
        let result = handle.rename(source, &expected, destination, None).await;
        if accepted {
            assert_eq!(result.unwrap().attributes, after);
        } else {
            assert!(matches!(result, Err(Error::CommitUncertain)));
        }
        handle.close().await.unwrap();
        mock.assert_fully_consumed();
        mock.close();
    }
}
