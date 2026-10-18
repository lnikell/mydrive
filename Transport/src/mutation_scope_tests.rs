//! Recursive authority is tested at the real CREATE/QUERY_INFO seam. There is
//! no socket, NAS write, or pathname-only substitute for the held identities.
use super::{parent_tests::*, *};
use crate::mutation::{DeleteScope, DirectoryIdentity, MutationKind, Outcome};
use crate::test_wire::{connection, reply};
use serde_json::json;
use smb2::msg::header::Header;

fn identity(index: u64) -> DirectoryIdentity {
    DirectoryIdentity {
        index_number: index,
        created_filetime: index + 1,
    }
}
fn scope() -> DeleteScope {
    DeleteScope {
        root_path: "selection".into(),
        root: identity(10),
        parent: identity(20),
    }
}
fn intent(path: &str, directory: bool) -> MutationRequest {
    serde_json::from_value(json!({
        "operation_id":"11111111-2222-4333-8444-555555555555",
        "kind":"delete", "path":path,
        "parent":if path == "selection" {identity(20)} else {identity(10)},
        "delete_scope":scope(),
        "expected":{"name":"item", "bytes":0, "directory":directory,
            "index_number":if directory {10} else {30},
            "created_filetime":if directory {11} else {31},
            "modified_filetime":40, "changed_filetime":50,
            "attributes":if directory {16} else {32}}
    }))
    .unwrap()
}

fn missing(mock: &smb2::transport::MockTransport) {
    let mut header = Header::new_request(Command::Create);
    header.flags =
        smb2::types::flags::HeaderFlags::new(smb2::types::flags::HeaderFlags::SERVER_TO_REDIR);
    header.status = NtStatus::OBJECT_NAME_NOT_FOUND;
    header.credits = 8;
    let mut bytes = smb2::pack::WriteCursor::new();
    header.pack(&mut bytes);
    mock.queue_response(bytes.into_inner());
}

#[test]
fn scope_membership_is_exact_bounded_and_not_an_arbitrary_mutation_capability() {
    let mut selection = scope();
    for path in ["selection", "selection/child", "selection/child/deep"] {
        selection.validate_path(path).unwrap();
    }
    for path in [
        "",
        "selection-sibling/file",
        "Selection/file",
        "selection/../file",
        "/selection",
    ] {
        assert!(selection.validate_path(path).is_err());
    }
    selection.root_path = "cafe\u{301}".into();
    selection.validate_path("cafe\u{301}/file").unwrap();
    assert!(selection.validate_path("café/file").is_err());
    selection.root_path = "a/".repeat(128) + "a";
    assert!(selection.validate_path(&selection.root_path).is_err());

    let mut request = intent("selection/file", false);
    request.validate().unwrap();
    request.parent = identity(99);
    assert!(request.validate().is_err()); // same path cannot name two objects
    request = intent("selection", true);
    request.expected.as_mut().unwrap().index_number = Some(99);
    assert!(request.validate().is_err()); // cannot skip a different root target
    request = intent("selection/file", false);
    request.kind = MutationKind::Move;
    request.destination = Some("selection/other".into());
    request.destination_parent = Some(identity(10));
    assert!(request.validate().is_err());
    request = intent("selection/file", false);
    request.delete_scope.as_mut().unwrap().root.index_number = 0;
    assert!(request.validate().is_err());
    let mut wire = serde_json::to_value(scope()).unwrap();
    wire["unknown"] = json!(true);
    assert!(serde_json::from_value::<DeleteScope>(wire).is_err());
}

#[tokio::test]
async fn replaced_selection_or_parent_refuses_before_any_child_or_data_rpc() {
    for replaced in ["parent", "root"] {
        for mode in [Open::Parent, Open::ReadParent] {
            let (connection, mock) = connection().await;
            let count = if replaced == "parent" {
                observed_parent(&mock, 99, 21, DIRECTORY);
                1
            } else {
                observed_parent(&mock, 20, 21, DIRECTORY);
                observed_parent(&mock, 99, 11, DIRECTORY);
                2
            };
            for _ in 0..count {
                reply(&mock, Command::Close, &crate::test_wire::Closed);
            }
            let mut io = owner(connection, CancellationToken::new());
            let selection = scope();
            let result = io
                .reserve_ancestors(
                    &["selection/nested/file"],
                    &[],
                    &selection.snapshots(false),
                    mode,
                )
                .await;
            assert!(matches!(result, Err(Error::ScopeChanged)));
            io.close_checked().await.unwrap();
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
async fn unchanged_selection_keeps_both_reservations_through_scoped_absence_stat() {
    let (connection, mock) = connection().await;
    observed_parent(&mock, 20, 21, DIRECTORY);
    observed_parent(&mock, 10, 11, DIRECTORY | 2); // child-driven flags are not identity
    let mut io = owner(connection, CancellationToken::new());
    io.reserve_ancestors(
        &["selection/missing"],
        &[],
        &scope().snapshots(false),
        Open::Parent,
    )
    .await
    .unwrap();
    assert_eq!(io.parents.len(), 2);
    let sent = mock.sent_messages();
    let opens: Vec<_> = sent
        .iter()
        .filter(|data| {
            Header::unpack(&mut ReadCursor::new(data)).unwrap().command == Command::Create
        })
        .map(|data| CreateRequest::unpack(&mut ReadCursor::new(&data[64..])).unwrap())
        .collect();
    assert_eq!(
        opens
            .iter()
            .map(|open| open.name.as_str())
            .collect::<Vec<_>>(),
        ["", "selection"]
    );
    for open in opens {
        assert_eq!(open.share_access.0, ShareAccess::FILE_SHARE_READ);
        assert_eq!(open.create_disposition, CreateDisposition::FileOpen);
        assert_eq!(open.create_options & 0x0020_0001, 0x0020_0001);
    }
    missing(&mock);
    assert!(io.stat("selection/missing").await.unwrap().is_none());
    assert_eq!(io.parents.len(), 2); // no early fence close on missing leaf
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    io.close_checked().await.unwrap();
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn exact_root_stat_proves_absence_under_parent_or_rejects_a_replacement() {
    for absent in [false, true] {
        let (connection, mock) = connection().await;
        observed_parent(&mock, 20, 21, DIRECTORY);
        if absent {
            missing(&mock);
        } else {
            observed_parent(&mock, 99, 11, DIRECTORY);
            reply(&mock, Command::Close, &crate::test_wire::Closed);
        }
        reply(&mock, Command::Close, &crate::test_wire::Closed);
        let mut io = owner(connection, CancellationToken::new());
        let selection = scope();
        io.reserve_ancestors(
            &["selection"],
            &[],
            &selection.snapshots(true),
            Open::ReadParent,
        )
        .await
        .unwrap();
        let result = io.stat_in_scope("selection", &selection).await;
        if absent {
            assert!(result.unwrap().is_none());
        } else {
            assert!(matches!(result, Err(Error::ScopeChanged)));
        }
        assert_eq!(io.parents.len(), 1);
        io.close_checked().await.unwrap();
        assert!(commands(&mock)
            .iter()
            .all(|c| matches!(c, Command::Create | Command::QueryInfo | Command::Close)));
        mock.assert_fully_consumed();
        mock.close();
    }
}

#[tokio::test]
async fn exact_root_delete_skips_only_its_own_reservation_and_keeps_parent_guard() {
    let request = intent("selection", true);
    request.validate().unwrap();
    assert_eq!(request.scope_snapshots(), [("", identity(20))]);
    let (connection, mock) = connection().await;
    observed_parent(&mock, 20, 21, DIRECTORY);
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    let mut io = owner(connection, CancellationToken::new());
    io.reserve_ancestors(
        &[&request.path],
        &request.parent_snapshots(),
        &request.scope_snapshots(),
        Open::Parent,
    )
    .await
    .unwrap();
    assert_eq!(io.parents.len(), 1);
    io.close_checked().await.unwrap();
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn cancellation_stops_scope_reservation_before_opening_an_object() {
    let (connection, mock) = connection().await;
    let cancel = CancellationToken::new();
    cancel.cancel();
    let mut io = owner(connection, cancel);
    assert!(matches!(
        io.reserve_ancestors(
            &["selection/file"],
            &[],
            &scope().snapshots(false),
            Open::Parent
        )
        .await,
        Err(Error::Cancelled)
    ));
    assert!(mock.sent_messages().is_empty());
    io.close_checked().await.unwrap();
    mock.close();
}

#[test]
fn refused_scope_preserves_durable_recovery_evidence_and_cleanup_scope() {
    let mut request = intent("selection/file", false);
    request.receipt.archived = Some(mutation::Artifact {
        save_contract: None,
        path: request.sidecar("deleted"),
        entry: request.expected.clone().unwrap(),
        cleanup_safe: true,
        phase: mutation::StagePhase::Prepared,
        security_sha256: None,
    });
    request.validate().unwrap();
    let refusal = mutation::scope_changed(&request);
    assert_eq!(refusal.code, "scope_changed");
    assert_eq!(refusal.outcome, Outcome::Conflict);
    assert!(refusal.cleanup_pending);
    assert_eq!(
        serde_json::to_value(&refusal.receipt).unwrap(),
        serde_json::to_value(&request.receipt).unwrap()
    );
    let artifact = request.receipt.archived.take().unwrap();
    request.kind = MutationKind::Cleanup;
    request.path = artifact.path;
    request.expected = Some(artifact.entry);
    request.validate().unwrap();
    assert_eq!(request.scope_snapshots().len(), 2);
}
