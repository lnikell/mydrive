//! Private-tree requests cross the same held-handle seam as production.
use super::{parent_tests::*, *};
use crate::mutation::{DirectoryIdentity, MutationKind, Outcome, TreeScope};
use crate::test_wire::{connection, reply, Empty};
use serde_json::json;
use smb2::msg::header::Header;

const KEY: &str = "11111111-2222-4333-8444-555555555555";
fn identity(index: u64) -> DirectoryIdentity {
    DirectoryIdentity {
        index_number: index,
        created_filetime: index + 1,
    }
}
fn scope() -> TreeScope {
    TreeScope {
        layout_version: 2,
        arena_path: "arena".into(),
        arena: identity(10),
        parent: identity(20),
    }
}
fn intent(kind: &str, path: &str) -> MutationRequest {
    let mut wire = json!({"operation_id":KEY,"kind":kind,"path":path,
        "parent":identity(10),"tree_scope":scope()});
    if kind == "create_file" {
        wire["payload"] = json!({"source":"/tmp/payload","bytes":3,"sha256":"a".repeat(64)});
    } else if kind != "create_directory" {
        wire["expected"] = json!({"name":"node","bytes":0,"directory":true,
            "index_number":30,"created_filetime":31,"modified_filetime":40,
            "changed_filetime":50,"attributes":16});
    }
    if kind == "move" {
        wire["destination"] = json!("arena/payload");
        wire["destination_parent"] = json!(identity(10));
    }
    serde_json::from_value(wire).unwrap()
}
fn scratch() -> String {
    format!("arena/.mydrive-{KEY}.node")
}

#[test]
fn correct_depth_scratch_stays_in_its_logical_parent_and_only_root_can_publish() {
    let mut create = intent("create_file", &scratch());
    create.validate().unwrap();
    assert_eq!(
        create.sidecar("stage"),
        format!("arena/.mydrive-{KEY}.stage")
    );
    create.operation_id = "99999999-2222-4333-8444-555555555555".into();
    create.path = format!("arena/Nested/.mydrive-{KEY}.node");
    create.parent = identity(40);
    create.validate().unwrap();
    assert_eq!(
        create.sidecar("stage"),
        "arena/Nested/.mydrive-99999999-2222-4333-8444-555555555555.stage"
    );
    for bad in [
        "arena/Nested/file",
        "arena/ordinary",
        "arena-sibling/file",
        "arena",
    ] {
        create.path = bad.into();
        assert!(create.validate().is_err(), "{bad}");
    }
    let mut place = intent("move", &scratch());
    place.destination = Some("arena/Folder".into());
    place.validate().unwrap();
    // Inheritable permissions are determined by CREATE in this actual parent,
    // never by a cross-parent scratch relocation or inferred ACL mapping.
    place.path = format!("arena/Nested/.mydrive-{KEY}.node");
    place.parent = identity(40);
    place.destination = Some("arena/Nested/file".into());
    place.destination_parent = Some(identity(40));
    place.validate().unwrap();
    for bad in [
        "arena/file",
        "arena/Elsewhere/file",
        "outside/file",
        "outside",
    ] {
        place.destination = Some(bad.into());
        assert!(place.validate().is_err(), "{bad}");
    }
    let mut publish = intent("move", "arena");
    publish.parent = identity(20);
    publish.destination = Some("Published folder".into());
    publish.destination_parent = Some(identity(20));
    publish.expected.as_mut().unwrap().index_number = Some(10);
    publish.expected.as_mut().unwrap().created_filetime = 11;
    publish.validate().unwrap();
    for bad in ["outside/Folder", "arena", "arena/Nested"] {
        publish.destination = Some(bad.into());
        assert!(publish.validate().is_err(), "{bad}");
    }
    publish.destination = Some("Published folder".into());
    publish.expected.as_mut().unwrap().index_number = Some(99);
    assert!(publish.validate().is_err());
    publish.expected.as_mut().unwrap().index_number = Some(10);
    publish.destination_parent = Some(identity(99));
    assert!(publish.validate().is_err());
    publish.destination_parent = Some(identity(20));
    publish.expected.as_mut().unwrap().directory = false;
    publish.expected.as_mut().unwrap().attributes = 32;
    assert!(publish.validate().is_err());
    let mut delete = intent("delete", "arena/Nested/file");
    assert!(delete.validate().is_err());
    delete.path = scratch();
    delete.validate().unwrap();
    delete.kind = MutationKind::ReplaceFile;
    assert!(delete.validate().is_err());
}

#[test]
fn legacy_or_unknown_layout_cannot_be_reinterpreted_as_correct_depth_staging() {
    let current = serde_json::to_value(scope()).unwrap();
    for version in [None, Some(1), Some(0), Some(3)] {
        let mut wire = current.clone();
        if let Some(version) = version {
            wire["layout_version"] = json!(version);
        } else {
            wire.as_object_mut().unwrap().remove("layout_version");
        }
        if let Ok(scope) = serde_json::from_value::<TreeScope>(wire) {
            assert!(scope.validate_path("arena/file").is_err());
        }
    }
    let mut wire = current;
    wire["security_sha256"] = json!("a".repeat(64));
    assert!(serde_json::from_value::<TreeScope>(wire).is_err());
}

#[test]
fn scope_is_byte_exact_bounded_and_cannot_be_combined_with_delete_authority() {
    let mut selection = scope();
    selection.arena_path = "cafe\u{301}".into();
    selection.validate_path("cafe\u{301}/payload").unwrap();
    selection
        .validate_payload_path("cafe\u{301}/payload/file")
        .unwrap();
    assert!(selection.validate_payload_path("cafe\u{301}").is_err());
    selection.validate_payload_path("cafe\u{301}/file").unwrap();
    for bad in [
        "café/payload",
        "cafe\u{301}-sibling/payload",
        "",
        "cafe\u{301}/../outside",
    ] {
        assert!(selection.validate_path(bad).is_err());
    }
    selection.arena.index_number = 0;
    assert!(selection.validate_path("cafe\u{301}/payload").is_err());
    let mut create = intent("create_directory", &scratch());
    create.parent = identity(99);
    assert!(create.validate().is_err());
    create.parent = identity(10);
    create.delete_scope = Some(scope().fence());
    assert!(create.validate().is_err());
    let mut wire = serde_json::to_value(scope()).unwrap();
    wire["unknown"] = json!(true);
    assert!(serde_json::from_value::<TreeScope>(wire).is_err());
    let deep = "a/".repeat(128) + "a";
    assert!(scope().validate_path(&format!("arena/{deep}")).is_err());
}

#[tokio::test]
async fn cancellation_stops_private_tree_reservations_before_any_open() {
    let (connection, mock) = connection().await;
    let cancel = CancellationToken::new();
    cancel.cancel();
    let mut io = owner(connection, cancel);
    let request = intent("create_directory", &scratch());
    assert!(matches!(
        io.reserve_ancestors(
            &[&request.path],
            &request.parent_snapshots(),
            &request.scope_snapshots(),
            Open::Parent
        )
        .await,
        Err(Error::Cancelled)
    ));
    assert!(mock.sent_messages().is_empty());
    io.close_checked().await.unwrap();
    mock.close();
}

#[tokio::test]
async fn replaced_arena_or_parent_refuses_before_any_node_or_namespace_rpc() {
    for replaced in ["parent", "arena"] {
        for kind in ["create_file", "create_directory", "move", "delete"] {
            let (connection, mock) = connection().await;
            observed_parent(
                &mock,
                if replaced == "parent" { 99 } else { 20 },
                21,
                DIRECTORY,
            );
            let count = if replaced == "parent" {
                1
            } else {
                observed_parent(&mock, 99, 11, DIRECTORY);
                2
            };
            for _ in 0..count {
                reply(&mock, Command::Close, &Empty);
            }
            let request = intent(kind, &scratch());
            request.validate().unwrap();
            let mut io = owner(connection, CancellationToken::new());
            let result = io
                .reserve_ancestors(
                    &[&request.path],
                    &request.parent_snapshots(),
                    &request.scope_snapshots(),
                    Open::Parent,
                )
                .await;
            assert!(matches!(result, Err(Error::ScopeChanged)));
            io.close_checked().await.unwrap();
            assert_eq!(
                commands(&mock)
                    .iter()
                    .filter(|c| **c == Command::Create)
                    .count(),
                count
            );
            assert!(commands(&mock)
                .iter()
                .all(|c| matches!(c, Command::Create | Command::QueryInfo | Command::Close)));
            mock.assert_fully_consumed();
            mock.close();
        }
    }
}

#[tokio::test]
async fn root_publication_holds_only_frozen_parent_without_self_reserving_root() {
    let mut request = intent("move", "arena");
    request.parent = identity(20);
    request.expected.as_mut().unwrap().index_number = Some(10);
    request.expected.as_mut().unwrap().created_filetime = 11;
    request.destination = Some("Published folder".into());
    request.destination_parent = Some(identity(20));
    request.validate().unwrap();
    let (connection, mock) = connection().await;
    observed_parent(&mock, 20, 21, DIRECTORY);
    reply(&mock, Command::Close, &Empty);
    let mut io = owner(connection, CancellationToken::new());
    io.reserve_ancestors(
        &[&request.path, request.destination.as_deref().unwrap()],
        &request.parent_snapshots(),
        &request.scope_snapshots(),
        Open::Parent,
    )
    .await
    .unwrap();
    assert_eq!(io.parents.len(), 1);
    let paths: Vec<_> = mock
        .sent_messages()
        .iter()
        .filter(|data| {
            Header::unpack(&mut ReadCursor::new(data)).unwrap().command == Command::Create
        })
        .map(|data| CreateRequest::unpack(&mut ReadCursor::new(&data[64..])).unwrap())
        .collect();
    assert_eq!(
        paths.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(),
        [""]
    );
    assert!(paths
        .iter()
        .all(|p| p.share_access.0 == ShareAccess::FILE_SHARE_READ));
    io.close_checked().await.unwrap();
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn descendant_place_keeps_root_and_actual_parent_reserved_and_rejects_replacement() {
    let mut request = intent("move", &format!("arena/Nested/.mydrive-{KEY}.node"));
    request.parent = identity(40);
    request.destination = Some("arena/Nested/file".into());
    request.destination_parent = Some(identity(40));
    request.validate().unwrap();
    // The root is never skipped merely because this is a move. In addition,
    // its actual nested parent must match before a target/stage RPC is sent.
    assert_eq!(
        request.scope_snapshots(),
        [("", identity(20)), ("arena", identity(10))]
    );
    let (connection, mock) = connection().await;
    observed_parent(&mock, 20, 21, DIRECTORY);
    observed_parent(&mock, 10, 11, DIRECTORY);
    observed_parent(&mock, 99, 41, DIRECTORY);
    for _ in 0..3 {
        reply(&mock, Command::Close, &Empty);
    }
    let mut io = owner(connection, CancellationToken::new());
    let result = io
        .reserve_ancestors(
            &[&request.path, request.destination.as_deref().unwrap()],
            &request.parent_snapshots(),
            &request.scope_snapshots(),
            Open::Parent,
        )
        .await;
    assert!(matches!(result, Err(Error::Changed)));
    io.close_checked().await.unwrap();
    assert_eq!(
        commands(&mock)
            .iter()
            .filter(|c| **c == Command::Create)
            .count(),
        3
    );
    assert!(commands(&mock)
        .iter()
        .all(|c| matches!(c, Command::Create | Command::QueryInfo | Command::Close)));
    mock.assert_fully_consumed();
    mock.close();
}

#[test]
fn fence_refusal_retains_receipts_and_arena_cleanup_is_empty_only_exact_identity() {
    let mut request = intent("create_directory", &scratch());
    request.receipt.staged = Some(mutation::Artifact {
        path: request.sidecar("stage"),
        entry: Entry {
            name: "stage".into(),
            bytes: 0,
            directory: true,
            index_number: Some(30),
            created_filetime: 31,
            modified_filetime: 40,
            changed_filetime: 50,
            attributes: 16,
        },
        cleanup_safe: true,
        phase: mutation::StagePhase::Prepared,
        security_sha256: None,
    });
    request.validate().unwrap();
    let refusal = mutation::scope_changed(&request);
    assert_eq!(refusal.code, "tree_scope_changed");
    assert_eq!(refusal.outcome, Outcome::Conflict);
    assert!(refusal.cleanup_pending);
    assert_eq!(
        serde_json::to_value(refusal.receipt).unwrap(),
        serde_json::to_value(&request.receipt).unwrap()
    );
    let mut root = intent("delete", "arena");
    root.parent = identity(20);
    root.expected.as_mut().unwrap().index_number = Some(10);
    root.expected.as_mut().unwrap().created_filetime = 11;
    root.validate().unwrap();
    assert_eq!(root.scope_snapshots(), [("", identity(20))]);
    root.expected.as_mut().unwrap().index_number = Some(99);
    assert!(root.validate().is_err());
}
