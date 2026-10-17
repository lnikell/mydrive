//! Parent identity checks cross the actual SMB handle seam, without sockets.
use super::*;
use crate::mutation::{DirectoryIdentity, MutationKind, Outcome, Receipt};
use crate::test_wire::{connection, reply, Empty};
use smb2::msg::{create::CreateAction, header::Header};
use smb2::pack::FileTime;
use smb2::transport::MockTransport;

pub(super) fn observed_parent(mock: &MockTransport, index: u64, created: u64, attributes: u32) {
    reply(
        mock,
        Command::Create,
        &CreateResponse {
            oplock_level: OplockLevel::None,
            flags: 0,
            create_action: CreateAction::FileOpened,
            creation_time: FileTime(created),
            last_access_time: FileTime(2),
            last_write_time: FileTime(99),
            change_time: FileTime(100),
            allocation_size: 0,
            end_of_file: 0,
            file_attributes: attributes,
            file_id: FileId {
                persistent: index,
                volatile: index,
            },
            create_contexts: vec![],
        },
    );
    let mut basic = vec![0; 40];
    basic[..8].copy_from_slice(&created.to_le_bytes());
    basic[16..24].copy_from_slice(&99u64.to_le_bytes());
    basic[24..32].copy_from_slice(&100u64.to_le_bytes());
    basic[32..36].copy_from_slice(&attributes.to_le_bytes());
    let mut standard = vec![0; 24];
    standard[21] = u8::from(attributes & DIRECTORY != 0);
    for output_buffer in [basic, standard, index.to_le_bytes().to_vec()] {
        reply(
            mock,
            Command::QueryInfo,
            &QueryInfoResponse { output_buffer },
        );
    }
}

pub(super) fn owner(connection: Connection, cancel: CancellationToken) -> MutationIO {
    MutationIO {
        connection,
        tree: TreeId(1),
        cancel,
        parents: vec![],
    }
}

pub(super) fn commands(mock: &MockTransport) -> Vec<Command> {
    mock.sent_messages()
        .iter()
        .map(|data| Header::unpack(&mut ReadCursor::new(data)).unwrap().command)
        .collect()
}

#[tokio::test]
async fn replaced_source_or_destination_parent_refuses_before_any_namespace_or_data_rpc() {
    for replaced in ["source", "target"] {
        for replace_creation_only in [false, true] {
            let (connection, mock) = connection().await;
            let expected = DirectoryIdentity {
                index_number: 10,
                created_filetime: 20,
            };
            // Reservations are acquired in deterministic path order.
            observed_parent(
                &mock,
                if replaced == "source" && !replace_creation_only {
                    11
                } else {
                    10
                },
                if replaced == "source" && replace_creation_only {
                    21
                } else {
                    20
                },
                DIRECTORY,
            );
            let count = if replaced == "source" {
                1
            } else {
                observed_parent(
                    &mock,
                    if replace_creation_only { 10 } else { 11 },
                    if replace_creation_only { 21 } else { 20 },
                    DIRECTORY,
                );
                2
            };
            for _ in 0..count {
                reply(&mock, Command::Close, &Empty);
            }
            let mut io = owner(connection, CancellationToken::new());
            let result = io
                .reserve_ancestors(
                    &["source/file", "target/file"],
                    &[("source", expected), ("target", expected)],
                    &[],
                    Open::Parent,
                )
                .await;
            assert!(matches!(result, Err(Error::Changed)));
            io.close().await;
            let sent = commands(&mock);
            assert_eq!(
                sent.iter().filter(|c| **c == Command::Create).count(),
                count
            );
            assert!(sent
                .iter()
                .all(|c| matches!(c, Command::Create | Command::QueryInfo | Command::Close)));
            mock.assert_fully_consumed();
            mock.close();
        }
    }
}

#[tokio::test]
async fn root_and_same_object_parent_changes_keep_real_reserved_directory_handles() {
    let (connection, mock) = connection().await;
    // Child activity changes timestamps/hidden flags, but not directory identity.
    observed_parent(&mock, 10, 20, DIRECTORY | 2);
    observed_parent(&mock, 30, 40, DIRECTORY);
    reply(&mock, Command::Close, &Empty);
    reply(&mock, Command::Close, &Empty);
    let mut io = owner(connection, CancellationToken::new());
    io.reserve_ancestors(
        &["file", "target/file"],
        &[
            (
                "",
                DirectoryIdentity {
                    index_number: 10,
                    created_filetime: 20,
                },
            ),
            (
                "target",
                DirectoryIdentity {
                    index_number: 30,
                    created_filetime: 40,
                },
            ),
        ],
        &[],
        Open::Parent,
    )
    .await
    .unwrap();
    assert_eq!(io.parents.len(), 2);
    let messages = mock.sent_messages();
    let opens: Vec<_> = messages
        .iter()
        .filter(|data| {
            Header::unpack(&mut ReadCursor::new(data)).unwrap().command == Command::Create
        })
        .map(|data| CreateRequest::unpack(&mut ReadCursor::new(&data[64..])).unwrap())
        .collect();
    assert_eq!(opens[0].name, "");
    assert_eq!(opens[1].name, "target");
    for open in opens {
        assert_eq!(open.create_disposition, CreateDisposition::FileOpen);
        assert_eq!(open.create_options & 0x0020_0001, 0x0020_0001);
        assert_eq!(open.share_access.0 & ShareAccess::FILE_SHARE_DELETE, 0);
    }
    io.close().await;
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn parent_reservation_is_cancellable_before_creating_any_handle() {
    let (connection, mock) = connection().await;
    let cancel = CancellationToken::new();
    cancel.cancel();
    let mut io = owner(connection, cancel);
    let result = io
        .reserve_ancestors(
            &["file"],
            &[(
                "",
                DirectoryIdentity {
                    index_number: 10,
                    created_filetime: 20,
                },
            )],
            &[],
            Open::Parent,
        )
        .await;
    assert!(matches!(result, Err(Error::Cancelled)));
    assert!(mock.sent_messages().is_empty());
    io.close().await;
    mock.close();
}

#[test]
fn parent_refusal_retains_existing_recovery_evidence() {
    let entry = Entry {
        name: "stage".into(),
        bytes: 3,
        directory: false,
        index_number: Some(50),
        created_filetime: 60,
        modified_filetime: 70,
        changed_filetime: 80,
        attributes: 32,
    };
    let request = MutationRequest {
        operation_id: "11111111-2222-4333-8444-555555555555".into(),
        kind: MutationKind::ReplaceFile,
        path: "file".into(),
        parent: DirectoryIdentity {
            index_number: 10,
            created_filetime: 20,
        },
        delete_scope: None,
        tree_scope: None,
        destination: None,
        destination_parent: None,
        expected: Some(entry.clone()),
        payload: Some(mutation::Payload {
            source: "/tmp/owned-payload".into(),
            bytes: 3,
            sha256: "a".repeat(64),
        }),
        receipt: Receipt {
            staged: Some(mutation::Artifact {
                path: ".mydrive-11111111-2222-4333-8444-555555555555.stage".into(),
                entry,
                cleanup_safe: false,
                phase: crate::mutation::StagePhase::Prepared,
                security_sha256: None,
            }),
            archived: None,
        },
    };
    request.validate().unwrap();
    let refusal = mutation::parent_changed(&request);
    assert_eq!(refusal.outcome, Outcome::Conflict);
    assert_eq!(refusal.code, "parent_changed");
    assert!(refusal.cleanup_pending);
    assert_eq!(
        serde_json::to_value(refusal.receipt).unwrap(),
        serde_json::to_value(request.receipt).unwrap()
    );
}

#[tokio::test]
async fn share_root_stat_returns_real_nonzero_identity_without_a_synthetic_name() {
    let (connection, mock) = connection().await;
    observed_parent(&mock, 10, 20, DIRECTORY);
    reply(&mock, Command::Close, &Empty);
    let mut io = owner(connection, CancellationToken::new());
    let entry = io.stat("").await.unwrap().unwrap();
    assert_eq!(entry.name, "");
    assert_eq!(entry.index_number, Some(10));
    assert_eq!(entry.created_filetime, 20);
    assert!(entry.directory);
    io.close().await;
    mock.assert_fully_consumed();
    mock.close();
}
