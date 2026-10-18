//! The real owner and state machine over canned SMB frames, never a socket.
use super::*;
use crate::test_wire::{connection, reply, Closed, Empty};
use sha2::{Digest, Sha256};
use smb2::{
    msg::{create::CreateAction, header::Header},
    pack::{FileTime, WriteCursor},
    transport::MockTransport,
    types::flags::HeaderFlags,
};
use std::time::Duration;

fn entry(path: &str, size: u64, id: u64) -> Entry {
    Entry {
        name: path.rsplit('/').next().unwrap().into(),
        bytes: size,
        directory: false,
        index_number: Some(id),
        created_filetime: id + 1,
        modified_filetime: 3,
        changed_filetime: 4,
        attributes: if path.rsplit('/').next().unwrap().starts_with('.') {
            34
        } else {
            32
        },
    }
}
fn security() -> Vec<u8> {
    crate::mutation_security::fixture()
}
fn request(replace: bool, body: &[u8]) -> MutationRequest {
    let mut request = MutationRequest {
        operation_id: "11111111-2222-4333-8444-555555555555".into(),
        kind: if replace {
            mutation::MutationKind::ReplaceFile
        } else {
            mutation::MutationKind::CreateFile
        },
        path: "folder/file".into(),
        parent: mutation::DirectoryIdentity {
            index_number: 5,
            created_filetime: 6,
        },
        delete_scope: None,
        tree_scope: None,
        destination: None,
        destination_parent: None,
        expected: replace.then(|| entry("folder/file", 7, 9)),
        payload: Some(mutation::Payload {
            source: "/tmp/unused-local-body".into(),
            bytes: body.len() as u64,
            sha256: mutation::hex(&Sha256::digest(body)),
        }),
        receipt: mutation::Receipt::default(),
    };
    request.receipt.staged = Some(mutation::Artifact {
        path: request.sidecar("stage"),
        entry: entry(&request.sidecar("stage"), body.len() as u64, 10),
        cleanup_safe: true,
        phase: mutation::StagePhase::Prepared,
        security_sha256: Some(
            crate::mutation_security::AccessSecurity::parse(security())
                .unwrap()
                .fingerprint(),
        ),
    });
    request
}
fn query(mock: &MockTransport, bytes: Vec<u8>) {
    reply(
        mock,
        Command::QueryInfo,
        &QueryInfoResponse {
            output_buffer: bytes,
        },
    );
}
fn observed(mock: &MockTransport, entry: &Entry) {
    let mut basic = vec![0; 40];
    basic[..8].copy_from_slice(&entry.created_filetime.to_le_bytes());
    basic[16..24].copy_from_slice(&entry.modified_filetime.to_le_bytes());
    basic[24..32].copy_from_slice(&entry.changed_filetime.to_le_bytes());
    basic[32..36].copy_from_slice(&entry.attributes.to_le_bytes());
    let mut standard = vec![0; 24];
    standard[8..16].copy_from_slice(&entry.bytes.to_le_bytes());
    standard[16..20].copy_from_slice(&1u32.to_le_bytes());
    standard[21] = u8::from(entry.directory);
    for data in [
        basic,
        standard,
        entry.index_number.unwrap().to_le_bytes().to_vec(),
    ] {
        query(mock, data);
    }
}
fn plain(mock: &MockTransport) {
    let mut standard = vec![0; 24];
    standard[16..20].copy_from_slice(&1u32.to_le_bytes());
    query(mock, standard);
    query(mock, vec![0; 4]);
    query(mock, vec![]);
}
fn opened(mock: &MockTransport, id: u64) {
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
            allocation_size: 0,
            end_of_file: 0,
            file_attributes: 32,
            file_id: FileId {
                persistent: id,
                volatile: id,
            },
            create_contexts: vec![],
        },
    );
}
fn failure(mock: &MockTransport, command: Command, status: u32) {
    let mut h = Header::new_request(command);
    h.flags = HeaderFlags::new(HeaderFlags::SERVER_TO_REDIR);
    h.credits = 8;
    h.status = NtStatus(status);
    let mut cursor = WriteCursor::new();
    h.pack(&mut cursor);
    mock.queue_response(cursor.into_inner());
}
fn stat(mock: &MockTransport, entry: Option<&Entry>) {
    if let Some(entry) = entry {
        opened(mock, entry.index_number.unwrap());
        observed(mock, entry);
        reply(mock, Command::Close, &Closed);
    } else {
        failure(mock, Command::Create, 0xC000_0034);
    }
}
fn checked(mock: &MockTransport, entry: &Entry) {
    observed(mock, entry);
    if !entry.directory {
        plain(mock);
    }
    query(mock, security());
}
fn bytes(mock: &MockTransport, body: &[u8]) {
    for chunk in body.chunks(65536) {
        reply(
            mock,
            Command::Read,
            &ReadResponse {
                data_offset: 80,
                data_remaining: 0,
                flags: 0,
                data: chunk.to_vec(),
            },
        );
    }
}
fn prepare(mock: &MockTransport, request: &MutationRequest, body: &[u8]) {
    let stage = &request.receipt.staged.as_ref().unwrap().entry;
    opened(mock, 10);
    checked(mock, stage);
    bytes(mock, body);
    checked(mock, stage);
}
fn archived(request: &MutationRequest) -> Entry {
    let mut entry = request.expected.clone().unwrap();
    entry.name = request.sidecar("backup").rsplit('/').next().unwrap().into();
    entry.changed_filetime += 1;
    entry.attributes |= 2;
    entry
}
fn archive(mock: &MockTransport, request: &MutationRequest) {
    checked(mock, &request.receipt.staged.as_ref().unwrap().entry);
    let original = request.expected.as_ref().unwrap();
    opened(mock, 9);
    observed(mock, original);
    query(mock, security());
    query(mock, security());
    observed(mock, original);
    plain(mock);
    reply(mock, Command::SetInfo, &Empty);
    observed(mock, &archived(request));
    reply(mock, Command::Close, &Closed);
}
fn publish(mock: &MockTransport, request: &MutationRequest, status: Option<u32>) {
    checked(mock, &request.receipt.staged.as_ref().unwrap().entry);
    if request.expected.is_some() {
        opened(mock, 9);
        observed(mock, &archived(request));
        query(mock, security());
        query(mock, security());
    }
    if let Some(status) = status {
        failure(mock, Command::SetInfo, status);
    } else {
        reply(mock, Command::SetInfo, &Empty);
        let mut result = request.receipt.staged.as_ref().unwrap().entry.clone();
        result.attributes = if result.directory { 16 } else { 32 };
        result.changed_filetime += 1;
        observed(mock, &result);
    }
    if request.expected.is_some() {
        reply(mock, Command::Close, &Closed);
    }
    reply(mock, Command::Close, &Closed);
}
fn owner(connection: Connection, cancel: CancellationToken) -> MutationIO {
    super::parent_tests::owner(connection, cancel)
}
fn command(message: &[u8]) -> Command {
    Header::unpack(&mut ReadCursor::new(message))
        .unwrap()
        .command
}
fn namespace_count(mock: &MockTransport) -> usize {
    mock.sent_messages()
        .iter()
        .filter(|m| command(m) == Command::SetInfo)
        .count()
}
async fn reached(mock: &MockTransport, wanted: Command) {
    tokio::time::timeout(Duration::from_secs(2), async {
        while !mock.sent_messages().iter().any(|m| command(m) == wanted) {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
}
async fn dead(connection: &Connection) {
    assert!(tokio::time::timeout(
        Duration::from_secs(1),
        connection.execute(
            Command::Flush,
            &FlushRequest {
                file_id: FileId {
                    persistent: 10,
                    volatile: 10
                }
            },
            Some(TreeId(1))
        )
    )
    .await
    .unwrap()
    .is_err());
    assert!(connection.outstanding_requests().is_empty());
}

#[tokio::test]
async fn prepared_create_and_replace_hash_once_then_publish_the_same_held_file() {
    for replace in [false, true] {
        let body = vec![0xA5; 65537];
        let request = request(replace, &body);
        let (connection, mock) = connection().await;
        stat(&mock, request.expected.as_ref());
        stat(&mock, Some(&request.receipt.staged.as_ref().unwrap().entry));
        if replace {
            stat(&mock, None);
        }
        prepare(&mock, &request, &body);
        if replace {
            archive(&mock, &request);
        }
        publish(&mock, &request, None);
        let mut io = owner(connection, CancellationToken::new());
        let result = mutation::run(&mut io, &request, None, false, &mut |_| {}).await;
        assert_eq!(
            result.outcome,
            mutation::Outcome::Committed,
            "{}",
            result.code
        );
        assert!(result.receipt.staged.is_none());
        assert_eq!(result.receipt.archived.is_some(), replace);
        io.close_checked().await.unwrap();
        let messages = mock.sent_messages();
        let reads: Vec<_> = messages
            .iter()
            .filter(|m| command(m) == Command::Read)
            .map(|m| ReadRequest::unpack(&mut ReadCursor::new(&m[64..])).unwrap())
            .collect();
        assert_eq!(
            reads.iter().map(|r| u64::from(r.length)).sum::<u64>(),
            65537
        );
        assert_eq!(reads.len(), 2);
        assert!(reads.iter().all(|r| r.file_id.persistent == 10));
        let sets: Vec<_> = messages
            .iter()
            .filter(|m| command(m) == Command::SetInfo)
            .map(|m| SetInfoRequest::unpack(&mut ReadCursor::new(&m[64..])).unwrap())
            .collect();
        assert_eq!(
            sets.iter()
                .map(|s| s.file_id.persistent)
                .collect::<Vec<_>>(),
            if replace { vec![9, 10] } else { vec![10] }
        );
        assert!(sets.iter().all(|s| s.buffer[0] == 0)); // ReplaceIfExists is never enabled.
        let first_read = messages
            .iter()
            .position(|m| command(m) == Command::Read)
            .unwrap();
        let last_set = messages
            .iter()
            .rposition(|m| command(m) == Command::SetInfo)
            .unwrap();
        assert!(!messages[first_read..last_set]
            .iter()
            .any(|m| command(m) == Command::Close
                && CloseRequest::unpack(&mut ReadCursor::new(&m[64..]))
                    .unwrap()
                    .file_id
                    .persistent
                    == 10));
        let stage_opens = messages
            .iter()
            .filter(|m| command(m) == Command::Create)
            .map(|m| CreateRequest::unpack(&mut ReadCursor::new(&m[64..])).unwrap())
            .filter(|r| r.name == smb2::encode_path(&request.sidecar("stage")))
            .count();
        assert_eq!(stage_opens, 2); // Initial stat + one held verifier, never reopen before publish.
        mock.close();
    }
}

#[tokio::test]
async fn corrupt_same_version_stage_never_archives_the_original() {
    let request = request(true, b"abc");
    let (connection, mock) = connection().await;
    stat(&mock, request.expected.as_ref());
    stat(&mock, Some(&request.receipt.staged.as_ref().unwrap().entry));
    stat(&mock, None);
    prepare(&mock, &request, b"abd");
    reply(&mock, Command::Close, &Closed);
    let mut io = owner(connection, CancellationToken::new());
    let result = mutation::run(&mut io, &request, None, false, &mut |_| {}).await;
    assert_eq!(result.code, "unverified_stage");
    assert_eq!(result.outcome, mutation::Outcome::Uncertain);
    assert!(result.receipt.archived.is_none() && result.receipt.staged.is_some());
    assert_eq!(namespace_count(&mock), 0);
    io.close_checked().await.unwrap();
    mock.close();
}

#[tokio::test]
async fn acknowledged_archive_receipt_survives_failed_publication() {
    for (status, code, outcome) in [
        (0xC000_0022, "access_denied", mutation::Outcome::Uncertain),
        (0xC000_0035, "already_exists", mutation::Outcome::Conflict),
    ] {
        let request = request(true, b"abc");
        let (connection, mock) = connection().await;
        stat(&mock, request.expected.as_ref());
        stat(&mock, Some(&request.receipt.staged.as_ref().unwrap().entry));
        stat(&mock, None);
        prepare(&mock, &request, b"abc");
        archive(&mock, &request);
        publish(&mock, &request, Some(status));
        let mut io = owner(connection, CancellationToken::new());
        let result = mutation::run(&mut io, &request, None, false, &mut |_| {}).await;
        assert_eq!(result.outcome, outcome);
        assert_eq!(result.code, code);
        assert_eq!(
            result.receipt.archived.as_ref().unwrap().entry,
            archived(&request)
        );
        assert!(result.receipt.archived.unwrap().cleanup_safe && result.receipt.staged.is_some());
        assert_eq!(namespace_count(&mock), 2);
        io.close_checked().await.unwrap();
        mock.close();
    }
}

#[tokio::test]
async fn missing_or_mismatched_live_owner_never_falls_back_to_receipt_trust() {
    for variant in 0..4 {
        let request = request(false, b"abc");
        let stage = request.receipt.staged.as_ref().unwrap();
        let (connection, mock) = connection().await;
        let mut io = owner(connection, CancellationToken::new());
        assert!(matches!(
            io.publish(
                stage,
                &request.path,
                Some(&request.payload.as_ref().unwrap().sha256),
                None
            )
            .await,
            Err(Error::Changed)
        ));
        assert!(mock.sent_messages().is_empty());
        prepare(&mock, &request, b"abc");
        assert_eq!(
            io.prepare_publication(&request, stage).await.unwrap(),
            mutation::PreparedStatus::Verified
        );
        let mut changed = stage.clone();
        if variant == 2 {
            changed.security_sha256 = Some("b".repeat(64));
        }
        if variant == 3 {
            changed.entry.created_filetime += 1;
        }
        let hash = if variant == 1 {
            "different-hash"
        } else {
            &request.payload.as_ref().unwrap().sha256
        };
        let destination = if variant == 0 { "other" } else { &request.path };
        reply(&mock, Command::Close, &Closed);
        assert!(matches!(
            io.publish(&changed, destination, Some(hash), None).await,
            Err(Error::Changed)
        ));
        assert_eq!(namespace_count(&mock), 0);
        io.close_checked().await.unwrap();
        mock.close();
    }
}

#[tokio::test]
async fn publication_preparation_cancellation_or_drop_at_create_and_hash_retires_session() {
    for pending_hash in [false, true] {
        for dropping in [false, true] {
            let request = request(false, b"abc");
            let stage = request.receipt.staged.as_ref().unwrap();
            let (connection, mock) = connection().await;
            let cancel = CancellationToken::new();
            let mut io = owner(connection.clone(), cancel.clone());
            if pending_hash {
                opened(&mock, 10);
                checked(&mock, &stage.entry);
            }
            {
                let prepare = io.prepare_publication(&request, stage);
                tokio::pin!(prepare);
                tokio::select! {biased;result=&mut prepare=>panic!("pending operation returned {result:?}"),_=reached(&mock,if pending_hash {Command::Read}else{Command::Create})=>{}}
                if !dropping {
                    cancel.cancel();
                    assert!(matches!(
                        tokio::time::timeout(Duration::from_secs(2), prepare)
                            .await
                            .unwrap(),
                        Err(Error::Cancelled)
                    ));
                }
            }
            dead(&connection).await;
            assert_eq!(namespace_count(&mock), 0);
            io.close().await;
            mock.close();
        }
    }
}

#[tokio::test]
async fn changed_metadata_security_or_unsupported_content_never_reaches_archive() {
    for variant in 0..5 {
        let request = request(true, b"abc");
        let stage = request.receipt.staged.as_ref().unwrap();
        let (connection, mock) = connection().await;
        stat(&mock, request.expected.as_ref());
        stat(&mock, Some(&stage.entry));
        stat(&mock, None);
        opened(&mock, 10);
        if variant == 0 {
            let mut changed = stage.entry.clone();
            changed.index_number = Some(99);
            observed(&mock, &changed);
        } else {
            observed(&mock, &stage.entry);
            let mut standard = vec![0; 24];
            standard[16..20].copy_from_slice(&1u32.to_le_bytes());
            query(&mock, standard);
            query(
                &mock,
                if variant == 1 {
                    1u32.to_le_bytes().to_vec()
                } else {
                    vec![0; 4]
                },
            );
            if variant != 1 {
                if variant == 2 {
                    let mut stream = vec![0; 24];
                    let name = ":com.apple.ResourceFork:$DATA"
                        .encode_utf16()
                        .collect::<Vec<_>>();
                    stream[4..8].copy_from_slice(&(name.len() as u32 * 2).to_le_bytes());
                    for unit in name {
                        stream.extend_from_slice(&unit.to_le_bytes());
                    }
                    query(&mock, stream);
                } else {
                    query(&mock, vec![]);
                    let mut descriptor = security();
                    if variant == 3 {
                        descriptor[25] = 9;
                    }
                    query(&mock, descriptor);
                    if variant == 4 {
                        bytes(&mock, b"abc");
                        let mut changed = stage.entry.clone();
                        changed.changed_filetime += 1;
                        observed(&mock, &changed);
                    }
                }
            }
        }
        reply(&mock, Command::Close, &Closed);
        let mut io = owner(connection, CancellationToken::new());
        let result = mutation::run(&mut io, &request, None, false, &mut |_| {}).await;
        assert_ne!(result.outcome, mutation::Outcome::Committed);
        assert_eq!(namespace_count(&mock), 0);
        assert!(result.receipt.archived.is_none() && result.receipt.staged.is_some());
        io.close_checked().await.unwrap();
        mock.close();
    }
}

async fn reached_count(mock: &MockTransport, wanted: Command, count: usize) {
    tokio::time::timeout(Duration::from_secs(2), async {
        while mock
            .sent_messages()
            .iter()
            .filter(|m| command(m) == wanted)
            .count()
            < count
        {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
}
fn archive_before_set(mock: &MockTransport, request: &MutationRequest) {
    checked(mock, &request.receipt.staged.as_ref().unwrap().entry);
    let original = request.expected.as_ref().unwrap();
    opened(mock, 9);
    observed(mock, original);
    query(mock, security());
    query(mock, security());
    observed(mock, original);
    plain(mock);
}

#[tokio::test]
async fn archive_create_or_namespace_drop_and_cancel_retire_without_cleanup() {
    for pending_set in [false, true] {
        for dropping in [false, true] {
            let request = request(true, b"abc");
            let stage = request.receipt.staged.as_ref().unwrap();
            let (connection, mock) = connection().await;
            let cancel = CancellationToken::new();
            let mut io = owner(connection.clone(), cancel.clone());
            prepare(&mock, &request, b"abc");
            assert_eq!(
                io.prepare_publication(&request, stage).await.unwrap(),
                mutation::PreparedStatus::Verified
            );
            if pending_set {
                archive_before_set(&mock, &request);
            } else {
                checked(&mock, &stage.entry);
            }
            {
                let backup = request.sidecar("backup");
                let archive = io.archive(
                    &request.path,
                    request.expected.as_ref().unwrap(),
                    &backup,
                    stage,
                );
                tokio::pin!(archive);
                tokio::select! {biased;result=&mut archive=>panic!("pending archive returned {result:?}"),_=reached_count(&mock,if pending_set {Command::SetInfo}else{Command::Create},if pending_set {1}else{2})=>{}}
                if !dropping {
                    cancel.cancel();
                    assert!(matches!(
                        tokio::time::timeout(Duration::from_secs(2), archive)
                            .await
                            .unwrap(),
                        Err(Error::Cancelled)
                    ));
                }
            }
            dead(&connection).await;
            assert_eq!(namespace_count(&mock), usize::from(pending_set));
            io.close().await;
            mock.close();
        }
    }
}

#[tokio::test]
async fn cancellation_after_archive_ack_preserves_partial_receipt_and_no_success() {
    let request = request(true, b"abc");
    let stage = request.receipt.staged.as_ref().unwrap();
    let (connection, mock) = connection().await;
    stat(&mock, request.expected.as_ref());
    stat(&mock, Some(&stage.entry));
    stat(&mock, None);
    prepare(&mock, &request, b"abc");
    archive(&mock, &request);
    checked(&mock, &stage.entry);
    opened(&mock, 9);
    observed(&mock, &archived(&request));
    query(&mock, security());
    query(&mock, security());
    let cancel = CancellationToken::new();
    let mut io = owner(connection.clone(), cancel.clone());
    {
        let mut progress = |_| {};
        let operation = mutation::run(&mut io, &request, None, false, &mut progress);
        tokio::pin!(operation);
        tokio::select! {biased;result=&mut operation=>panic!("pending publication returned {result:?}"),_=reached_count(&mock,Command::SetInfo,2)=>cancel.cancel()}
        let result = tokio::time::timeout(Duration::from_secs(2), operation)
            .await
            .unwrap();
        assert_eq!(result.code, "cancelled");
        assert_eq!(result.outcome, mutation::Outcome::Uncertain);
        assert_eq!(result.receipt.archived.unwrap().entry, archived(&request));
        assert!(result.receipt.staged.is_some());
    }
    dead(&connection).await;
    io.close().await;
    mock.close();
}

#[tokio::test]
async fn uncertain_post_rename_observation_requires_fresh_full_hash_reconciliation() {
    let mut request = request(true, b"abc");
    let stage = request.receipt.staged.as_ref().unwrap().clone();
    let (first, mock) = connection().await;
    stat(&mock, request.expected.as_ref());
    stat(&mock, Some(&stage.entry));
    stat(&mock, None);
    prepare(&mock, &request, b"abc");
    archive(&mock, &request);
    checked(&mock, &stage.entry);
    opened(&mock, 9);
    observed(&mock, &archived(&request));
    query(&mock, security());
    query(&mock, security());
    reply(&mock, Command::SetInfo, &Empty);
    let mut published = stage.entry.clone();
    published.name = "file".into();
    published.attributes = 32;
    published.changed_filetime += 1;
    let mut wrong = published.clone();
    wrong.index_number = Some(99);
    observed(&mock, &wrong);
    reply(&mock, Command::Close, &Closed);
    reply(&mock, Command::Close, &Closed);
    let mut io = owner(first, CancellationToken::new());
    let uncertain = mutation::run(&mut io, &request, None, false, &mut |_| {}).await;
    assert_eq!(uncertain.code, "commit_uncertain");
    assert_eq!(uncertain.outcome, mutation::Outcome::Uncertain);
    assert!(uncertain.receipt.archived.is_some() && uncertain.receipt.staged.is_some());
    io.close_checked().await.unwrap();
    mock.close();
    request.receipt = uncertain.receipt;
    let (second, mock) = connection().await;
    stat(&mock, Some(&published));
    stat(&mock, None);
    stat(&mock, Some(&archived(&request)));
    opened(&mock, 10);
    observed(&mock, &published);
    plain(&mock);
    bytes(&mock, b"abc");
    observed(&mock, &published);
    reply(&mock, Command::Close, &Closed);
    let mut io = owner(second, CancellationToken::new());
    let committed = mutation::run(&mut io, &request, None, true, &mut |_| {}).await;
    assert_eq!(
        committed.outcome,
        mutation::Outcome::Committed,
        "{}",
        committed.code
    );
    assert!(committed.receipt.staged.is_none());
    assert!(committed.receipt.archived.is_some());
    assert_eq!(namespace_count(&mock), 0);
    assert!(io.prepared.is_none());
    let read_bytes: u64 = mock
        .sent_messages()
        .iter()
        .filter(|m| command(m) == Command::Read)
        .map(|m| {
            u64::from(
                ReadRequest::unpack(&mut ReadCursor::new(&m[64..]))
                    .unwrap()
                    .length,
            )
        })
        .sum();
    assert_eq!(read_bytes, 3);
    io.close_checked().await.unwrap();
    mock.close();
}

#[tokio::test]
async fn directory_publication_keeps_its_no_body_hash_contract() {
    let mut request = request(false, b"");
    request.kind = mutation::MutationKind::CreateDirectory;
    request.payload = None;
    let stage = request.receipt.staged.as_mut().unwrap();
    stage.entry.directory = true;
    stage.entry.attributes = 18;
    let (connection, mock) = connection().await;
    stat(&mock, None);
    stat(&mock, Some(&stage.entry));
    prepare(&mock, &request, b"");
    publish(&mock, &request, None);
    let mut io = owner(connection, CancellationToken::new());
    let result = mutation::run(&mut io, &request, None, false, &mut |_| {}).await;
    assert_eq!(
        result.outcome,
        mutation::Outcome::Committed,
        "{}",
        result.code
    );
    assert!(result.entry.unwrap().directory);
    assert!(!mock
        .sent_messages()
        .iter()
        .any(|m| command(m) == Command::Read));
    assert!(io.prepared.is_none());
    io.close_checked().await.unwrap();
    mock.close();
}

#[tokio::test]
async fn changed_receipt_still_reverifies_and_returns_a_checkpoint_without_live_guard() {
    let request = request(false, b"abc");
    let mut current = request.receipt.staged.as_ref().unwrap().entry.clone();
    current.changed_filetime += 1;
    let (connection, mock) = connection().await;
    stat(&mock, None);
    stat(&mock, Some(&current));
    opened(&mock, 10);
    observed(&mock, &current);
    plain(&mock);
    bytes(&mock, b"abc");
    observed(&mock, &current);
    reply(&mock, Command::Close, &Closed);
    let mut io = owner(connection, CancellationToken::new());
    let result = mutation::run(&mut io, &request, None, false, &mut |_| {}).await;
    assert_eq!(result.outcome, mutation::Outcome::NotApplied);
    assert_eq!(result.code, "prepared");
    assert_eq!(result.receipt.staged.as_ref().unwrap().entry, current);
    assert!(!result.receipt.staged.as_ref().unwrap().cleanup_safe);
    assert!(io.prepared.is_none());
    assert_eq!(namespace_count(&mock), 0);
    io.close_checked().await.unwrap();
    mock.close();
}

#[tokio::test]
async fn changed_backup_identity_or_security_preserves_archive_and_refuses_stage_rename() {
    for changed_security in [false, true] {
        let request = request(true, b"abc");
        let stage = request.receipt.staged.as_ref().unwrap();
        let (connection, mock) = connection().await;
        stat(&mock, request.expected.as_ref());
        stat(&mock, Some(&stage.entry));
        stat(&mock, None);
        prepare(&mock, &request, b"abc");
        archive(&mock, &request);
        checked(&mock, &stage.entry);
        opened(&mock, 9);
        let mut backup = archived(&request);
        if !changed_security {
            backup.index_number = Some(99);
        }
        observed(&mock, &backup);
        if changed_security {
            let mut bad = security();
            bad[25] = 9;
            query(&mock, bad);
            query(&mock, security());
        }
        reply(&mock, Command::Close, &Closed);
        reply(&mock, Command::Close, &Closed);
        let mut io = owner(connection, CancellationToken::new());
        let result = mutation::run(&mut io, &request, None, false, &mut |_| {}).await;
        assert_ne!(result.outcome, mutation::Outcome::Committed);
        assert_eq!(result.receipt.archived.unwrap().entry, archived(&request));
        assert!(result.receipt.staged.is_some());
        assert_eq!(namespace_count(&mock), 1);
        io.close_checked().await.unwrap();
        mock.close();
    }
}
