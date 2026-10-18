//! The actual V2 writer over the existing SMB mock, never a socket.
use super::*;
use std::{
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

struct PayloadFile {
    descriptor: mutation::Payload,
    path: PathBuf,
}
impl Drop for PayloadFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}
async fn local(bytes: &[u8]) -> PayloadFile {
    use std::os::unix::fs::OpenOptionsExt;
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let path = std::env::temp_dir().join(format!(
        "mydrive-ack-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true).mode(0o600);
    use std::io::Write;
    options.open(&path).unwrap().write_all(bytes).unwrap();
    PayloadFile {
        descriptor: mutation::Payload {
            source: path.to_string_lossy().into(),
            bytes: bytes.len() as u64,
            sha256: mutation::hex(&Sha256::digest(bytes)),
        },
        path,
    }
}
fn intent(replace: bool, body: &[u8]) -> MutationRequest {
    let mut r = request(replace, body);
    r.save_contract = Some(mutation::SaveContract::AcknowledgedSmbV2);
    let origin = r.receipt.staged.as_mut().unwrap();
    origin.entry.bytes = 0;
    origin.phase = mutation::StagePhase::Allocated;
    origin.save_contract = r.save_contract;
    r
}
fn uploaded(r: &MutationRequest) -> Entry {
    let mut e = r.receipt.staged.as_ref().unwrap().entry.clone();
    e.bytes = r.payload.as_ref().unwrap().bytes;
    e
}
fn final_entry(r: &MutationRequest) -> Entry {
    let mut e = uploaded(r);
    e.name = "file".into();
    e.attributes = 32;
    e.changed_filetime += 1;
    e
}
fn named(mock: &MockTransport, name: &str) {
    let utf16: Vec<u16> = name.encode_utf16().collect();
    let mut bytes = (utf16.len() as u32 * 2).to_le_bytes().to_vec();
    for unit in utf16 {
        bytes.extend(unit.to_le_bytes());
    }
    query(mock, bytes);
}
fn start_writer(mock: &MockTransport, r: &MutationRequest) {
    if let Some(base) = &r.expected {
        opened(mock, 9);
        observed(mock, base);
        plain(mock);
    }
    opened(mock, 10);
    checked(mock, &r.receipt.staged.as_ref().unwrap().entry);
    if r.expected.is_some() {
        query(mock, security());
        query(mock, security());
    }
    reply(mock, Command::SetInfo, &Empty);
}
fn writes(mock: &MockTransport, r: &MutationRequest) {
    for bytes in (0..r.payload.as_ref().unwrap().bytes).step_by(65536) {
        let count = (r.payload.as_ref().unwrap().bytes - bytes).min(65536) as u32;
        reply(
            mock,
            Command::Write,
            &WriteResponse {
                count,
                remaining: 0,
                write_channel_info_offset: 0,
                write_channel_info_length: 0,
            },
        );
    }
}
fn flushed(mock: &MockTransport, r: &MutationRequest) {
    if r.expected.is_some() {
        reply(mock, Command::SetInfo, &Empty);
    }
    reply(mock, Command::Flush, &Empty);
    checked(mock, &uploaded(r));
}
fn original_archive(mock: &MockTransport, r: &MutationRequest) {
    if let Some(base) = &r.expected {
        observed(mock, base);
        query(mock, security());
        query(mock, security());
        observed(mock, base);
        plain(mock);
        reply(mock, Command::SetInfo, &Empty);
        observed(mock, &archived(r));
    }
}
fn before_rename(mock: &MockTransport, r: &MutationRequest) {
    checked(mock, &uploaded(r));
}
fn renamed(mock: &MockTransport, r: &MutationRequest) {
    reply(mock, Command::SetInfo, &Empty);
    observed(mock, &final_entry(r));
}
fn closed(mock: &MockTransport, r: &MutationRequest) {
    reply(mock, Command::Close, &Closed);
    if r.expected.is_some() {
        reply(mock, Command::Close, &Closed);
    }
}
fn final_open(mock: &MockTransport, r: &MutationRequest) {
    opened(mock, 20);
    checked(mock, &final_entry(r));
    named(mock, "file");
    observed(mock, &final_entry(r));
    reply(mock, Command::Close, &Closed);
}
async fn body_call(
    r: &MutationRequest,
    body: &[u8],
    mock: &MockTransport,
    io: &MutationIO,
) -> (Result<Entry>, Option<mutation::Artifact>) {
    let file = local(body).await;
    let mut payload = VerifiedPayload::open(&file.descriptor, &io.cancel)
        .await
        .unwrap();
    let mut archive = None;
    let result = io
        .commit_acknowledged_writer(
            r,
            r.receipt.staged.as_ref().unwrap(),
            &mut payload,
            &mut archive,
            &mut |_| {},
        )
        .await;
    assert!(mock.sent_count() > 0);
    (result, archive)
}

#[tokio::test]
async fn create_and_replace_acknowledge_exact_bytes_without_any_body_read() {
    for (replace, size) in [(false, 0), (false, 65537), (true, 0), (true, 65537)] {
        let body = vec![123; size];
        let r = intent(replace, &body);
        let (c, mock) = connection().await;
        let io = owner(c, CancellationToken::new());
        start_writer(&mock, &r);
        writes(&mock, &r);
        flushed(&mock, &r);
        original_archive(&mock, &r);
        before_rename(&mock, &r);
        renamed(&mock, &r);
        closed(&mock, &r);
        final_open(&mock, &r);
        let (result, archive) = body_call(&r, &body, &mock, &io).await;
        assert_eq!(result.unwrap(), final_entry(&r));
        assert_eq!(archive.is_some(), replace);
        assert!(archive.as_ref().is_none_or(|a| a.save_contract.is_none()));
        let messages = mock.sent_messages();
        assert!(!messages.iter().any(|m| command(m) == Command::Read));
        let writes: Vec<_> = messages
            .iter()
            .filter(|m| command(m) == Command::Write)
            .map(|m| WriteRequest::unpack(&mut ReadCursor::new(&m[64..])).unwrap())
            .collect();
        assert_eq!(
            writes.iter().map(|w| w.data.len()).sum::<usize>(),
            body.len()
        );
        assert!(writes.iter().all(|w| w.file_id
            == FileId {
                persistent: 10,
                volatile: 10
            }));
        let renames: Vec<_> = messages
            .iter()
            .filter(|m| command(m) == Command::SetInfo)
            .map(|m| SetInfoRequest::unpack(&mut ReadCursor::new(&m[64..])).unwrap())
            .filter(|m| m.file_info_class == 10)
            .collect();
        assert_eq!(
            renames.last().unwrap().file_id,
            FileId {
                persistent: 10,
                volatile: 10
            }
        );
        assert_eq!(
            u32::from_le_bytes(renames.last().unwrap().buffer[..4].try_into().unwrap()),
            0
        );
        assert_eq!(r.receipt.staged.as_ref().unwrap().entry.bytes, 0);
        io.close_checked().await.unwrap();
        mock.assert_fully_consumed();
        mock.close();
    }
}

#[tokio::test]
async fn publication_failure_keeps_acknowledged_original_archive_and_creator_origin() {
    let body = b"ack-body";
    let r = intent(true, body);
    let (c, mock) = connection().await;
    let mut io = owner(c, CancellationToken::new());
    stat(&mock, r.expected.as_ref());
    stat(&mock, Some(&r.receipt.staged.as_ref().unwrap().entry));
    stat(&mock, None);
    start_writer(&mock, &r);
    writes(&mock, &r);
    flushed(&mock, &r);
    original_archive(&mock, &r);
    before_rename(&mock, &r);
    failure(&mock, Command::SetInfo, 0xc0000022);
    closed(&mock, &r);
    let file = local(body).await;
    let mut payload = VerifiedPayload::open(&file.descriptor, &io.cancel)
        .await
        .unwrap();
    let result = mutation::run(&mut io, &r, Some(&mut payload), false, &mut |_| {}).await;
    assert_eq!(result.outcome, mutation::Outcome::Uncertain);
    assert_eq!(result.receipt.archived.unwrap().entry, archived(&r));
    assert_eq!(result.save_contract, r.save_contract);
    assert!(result.sha256.is_none() && result.content_evidence.is_none());
    assert_eq!(result.receipt.staged.unwrap().entry.bytes, 0);
    assert_eq!(r.receipt.staged.as_ref().unwrap().entry.bytes, 0);
    io.close_checked().await.unwrap();
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn post_close_version_and_security_drift_are_uncertain_without_an_ack() {
    for fault in ["version", "security", "name"] {
        let body = b"ack-body";
        let r = intent(false, body);
        let (c, mock) = connection().await;
        let io = owner(c, CancellationToken::new());
        start_writer(&mock, &r);
        writes(&mock, &r);
        flushed(&mock, &r);
        before_rename(&mock, &r);
        renamed(&mock, &r);
        closed(&mock, &r);
        opened(&mock, 20);
        let mut e = final_entry(&r);
        if fault == "version" {
            e.modified_filetime += 1;
            observed(&mock, &e);
        } else if fault == "security" {
            observed(&mock, &e);
            plain(&mock);
            let mut bytes = security();
            bytes[25] = 9;
            query(&mock, bytes);
        } else {
            checked(&mock, &e);
            named(&mock, "FILE");
        }
        reply(&mock, Command::Close, &Closed);
        let (result, _) = body_call(&r, body, &mock, &io).await;
        assert!(matches!(result, Err(Error::CommitUncertain)));
        io.close_checked().await.unwrap();
        mock.assert_fully_consumed();
        mock.close();
    }
}

#[tokio::test]
async fn zero_write_ack_or_failed_flush_can_never_publish() {
    for fault in ["write", "flush"] {
        let body = b"ack-body";
        let r = intent(false, body);
        let (c, mock) = connection().await;
        let io = owner(c, CancellationToken::new());
        start_writer(&mock, &r);
        if fault == "write" {
            reply(
                &mock,
                Command::Write,
                &WriteResponse {
                    count: 0,
                    remaining: 0,
                    write_channel_info_offset: 0,
                    write_channel_info_length: 0,
                },
            );
        } else {
            writes(&mock, &r);
            failure(&mock, Command::Flush, 0xc0000022);
            reply(&mock, Command::Close, &Closed);
        }
        let (result, _) = body_call(&r, body, &mock, &io).await;
        assert!(result.is_err());
        assert!(!mock
            .sent_messages()
            .iter()
            .filter(|m| command(m) == Command::SetInfo)
            .map(|m| SetInfoRequest::unpack(&mut ReadCursor::new(&m[64..])).unwrap())
            .any(|m| m.file_info_class == 10));
        let _ = io.close_checked().await;
        mock.close();
    }
}

#[tokio::test]
async fn full_state_result_binds_ack_contract_and_clears_only_terminal_stage() {
    let body = b"ack-body";
    let r = intent(false, body);
    let (c, mock) = connection().await;
    let mut io = owner(c, CancellationToken::new());
    stat(&mock, None);
    stat(&mock, Some(&r.receipt.staged.as_ref().unwrap().entry));
    start_writer(&mock, &r);
    writes(&mock, &r);
    flushed(&mock, &r);
    before_rename(&mock, &r);
    renamed(&mock, &r);
    closed(&mock, &r);
    final_open(&mock, &r);
    let file = local(body).await;
    let mut payload = VerifiedPayload::open(&file.descriptor, &io.cancel)
        .await
        .unwrap();
    let result = mutation::run(&mut io, &r, Some(&mut payload), false, &mut |_| {}).await;
    assert_eq!(result.outcome, mutation::Outcome::Committed);
    assert_eq!(result.save_contract, r.save_contract);
    assert!(result.sha256.is_none());
    let proof = result.content_evidence.unwrap();
    assert_eq!(proof.kind, mutation::ContentEvidenceKind::SmbAcknowledged);
    assert_eq!(proof.sha256, r.payload.as_ref().unwrap().sha256);
    assert_eq!(proof.bytes, body.len() as u64);
    assert!(result.receipt.staged.is_none());
    assert_eq!(r.receipt.staged.as_ref().unwrap().entry.bytes, 0);
    io.close_checked().await.unwrap();
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn strict_recovery_reads_every_byte_and_never_returns_ack_evidence() {
    let body = vec![111; 65537];
    let r = intent(false, &body);
    let (c, mock) = connection().await;
    let mut io = owner(c, CancellationToken::new());
    let final_entry = final_entry(&r);
    stat(&mock, Some(&final_entry));
    stat(&mock, None);
    opened(&mock, 20);
    checked(&mock, &final_entry);
    bytes(&mock, &body);
    checked(&mock, &final_entry);
    named(&mock, "file");
    reply(&mock, Command::Close, &Closed);
    let result = mutation::run(&mut io, &r, None, true, &mut |_| {}).await;
    assert_eq!(result.outcome, mutation::Outcome::Committed);
    assert!(result.sha256.is_none());
    assert_eq!(
        result.content_evidence.unwrap().kind,
        mutation::ContentEvidenceKind::RemoteSha256
    );
    let messages = mock.sent_messages();
    assert_eq!(
        messages
            .iter()
            .filter(|m| command(m) == Command::Read)
            .map(|m| ReadRequest::unpack(&mut ReadCursor::new(&m[64..]))
                .unwrap()
                .length as u64)
            .sum::<u64>(),
        body.len() as u64
    );
    assert!(!messages
        .iter()
        .any(|m| matches!(command(m), Command::Write | Command::SetInfo)));
    io.close_checked().await.unwrap();
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn normal_retry_of_published_creator_requires_explicit_reconcile() {
    let body = b"ack-body";
    let r = intent(false, body);
    let (c, mock) = connection().await;
    let mut io = owner(c, CancellationToken::new());
    stat(&mock, Some(&final_entry(&r)));
    stat(&mock, None);
    let result = mutation::run(&mut io, &r, None, false, &mut |_| {}).await;
    assert_eq!(result.outcome, mutation::Outcome::Uncertain);
    assert_eq!(result.code, "reconcile_required");
    assert_eq!(result.save_contract, r.save_contract);
    assert!(result.content_evidence.is_none());
    assert!(result.sha256.is_none());
    assert_eq!(result.receipt.staged.unwrap().entry.bytes, 0);
    io.close_checked().await.unwrap();
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn malformed_writer_close_cannot_be_followed_by_success_or_a_reopen() {
    let body = b"ack-body";
    let r = intent(false, body);
    let (c, mock) = connection().await;
    let io = owner(c, CancellationToken::new());
    start_writer(&mock, &r);
    writes(&mock, &r);
    flushed(&mock, &r);
    before_rename(&mock, &r);
    renamed(&mock, &r);
    reply(&mock, Command::Close, &Empty);
    assert!(body_call(&r, body, &mock, &io).await.0.is_err());
    assert_eq!(
        mock.sent_messages()
            .iter()
            .filter(|m| command(m) == Command::Create)
            .count(),
        1
    );
    let _ = io.close_checked().await;
    mock.assert_fully_consumed();
    mock.close();
}

async fn reaches(mock: &MockTransport, command: Command, count: usize) {
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if mock
                .sent_messages()
                .iter()
                .filter(|m| super::command(m) == command)
                .count()
                >= count
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("ACK future did not reach its bounded wire checkpoint");
}
#[tokio::test]
async fn cancellation_or_drop_at_each_owned_effect_retires_without_success() {
    for phase in ["create", "write", "flush", "rename", "close", "reopen"] {
        for dropping in [false, true] {
            let body = b"ack-body";
            let r = intent(false, body);
            let (c, mock) = connection().await;
            let cancel = CancellationToken::new();
            let io = owner(c.clone(), cancel.clone());
            if phase != "create" {
                start_writer(&mock, &r);
            }
            if !matches!(phase, "create" | "write") {
                writes(&mock, &r);
            }
            if !matches!(phase, "create" | "write" | "flush") {
                flushed(&mock, &r);
                before_rename(&mock, &r);
            }
            if matches!(phase, "close" | "reopen") {
                renamed(&mock, &r);
            }
            if phase == "reopen" {
                closed(&mock, &r);
            }
            let (command, count) = match phase {
                "create" => (Command::Create, 1),
                "write" => (Command::Write, 1),
                "flush" => (Command::Flush, 1),
                "rename" => (Command::SetInfo, 2),
                "close" => (Command::Close, 1),
                _ => (Command::Create, 2),
            };
            let mut operation = Box::pin(body_call(&r, body, &mock, &io));
            tokio::select! { _=reaches(&mock,command,count)=>{},result=&mut operation=>panic!("unexpected early ACK result {result:?}") }
            if dropping {
                drop(operation);
            } else {
                cancel.cancel();
                let result = tokio::time::timeout(Duration::from_secs(5), &mut operation)
                    .await
                    .unwrap()
                    .0;
                assert!(
                    matches!(result, Err(Error::Cancelled)),
                    "phase {phase}: {result:?}"
                );
                drop(operation);
            }
            dead(&c).await;
            let _ = io.close_checked().await;
            mock.close();
        }
    }
}

#[tokio::test]
async fn creator_metadata_refusal_never_truncates_or_writes() {
    for fault in ["identity", "size", "ea", "stream", "security"] {
        let body = b"ack-body";
        let r = intent(false, body);
        let (c, mock) = connection().await;
        let io = owner(c, CancellationToken::new());
        opened(&mock, 10);
        let mut e = r.receipt.staged.as_ref().unwrap().entry.clone();
        if fault == "identity" {
            e.index_number = Some(99);
        }
        if fault == "size" {
            e.bytes = 99;
        }
        observed(&mock, &e);
        if !matches!(fault, "identity" | "size") {
            let mut links = vec![0; 24];
            links[16..20].copy_from_slice(&1u32.to_le_bytes());
            query(&mock, links);
            query(
                &mock,
                if fault == "ea" {
                    1u32.to_le_bytes().to_vec()
                } else {
                    vec![0; 4]
                },
            );
            if fault != "ea" {
                let mut stream = vec![];
                if fault == "stream" {
                    let name: Vec<_> = ":AFP_Resource:$DATA".encode_utf16().collect();
                    stream = vec![0; 24];
                    stream[4..8].copy_from_slice(&(name.len() as u32 * 2).to_le_bytes());
                    for unit in name {
                        stream.extend(unit.to_le_bytes());
                    }
                }
                query(&mock, stream);
                if fault != "stream" {
                    let mut sd = security();
                    sd[25] = 9;
                    query(&mock, sd);
                }
            }
        }
        reply(&mock, Command::Close, &Closed);
        assert!(body_call(&r, body, &mock, &io).await.0.is_err());
        assert!(!mock
            .sent_messages()
            .iter()
            .any(|m| matches!(command(m), Command::Write | Command::SetInfo)));
        io.close_checked().await.unwrap();
        mock.assert_fully_consumed();
        mock.close();
    }
}

#[tokio::test]
async fn parent_close_failure_or_post_close_cancel_removes_ack_and_retains_origin() {
    for cancelled in [false, true] {
        let body = b"ack-body";
        let r = intent(false, body);
        let (c, mock) = connection().await;
        let cancel = CancellationToken::new();
        let mut io = owner(c.clone(), cancel.clone());
        stat(&mock, None);
        stat(&mock, Some(&r.receipt.staged.as_ref().unwrap().entry));
        start_writer(&mock, &r);
        writes(&mock, &r);
        flushed(&mock, &r);
        before_rename(&mock, &r);
        renamed(&mock, &r);
        closed(&mock, &r);
        final_open(&mock, &r);
        let file = local(body).await;
        let mut payload = VerifiedPayload::open(&file.descriptor, &cancel)
            .await
            .unwrap();
        let mut result = mutation::run(&mut io, &r, Some(&mut payload), false, &mut |_| {}).await;
        assert_eq!(result.outcome, mutation::Outcome::Committed);
        io.parents.push(Handle {
            connection: c,
            tree: TreeId(1),
            file: FileId {
                persistent: 5,
                volatile: 5,
            },
            cancel: cancel.clone(),
            closed: false,
        });
        if cancelled {
            reply(&mock, Command::Close, &Closed);
        } else {
            reply(&mock, Command::Close, &Empty);
        }
        let closed = io.close_checked().await;
        if cancelled {
            cancel.cancel();
        } else {
            assert!(closed.is_err());
        }
        mutation::finish_acknowledged(&r, &mut result, closed, &cancel);
        assert_eq!(result.outcome, mutation::Outcome::Uncertain);
        assert_eq!(result.save_contract, r.save_contract);
        assert!(
            result.content_evidence.is_none() && result.sha256.is_none() && result.entry.is_none()
        );
        assert_eq!(result.receipt.staged.unwrap().entry.bytes, 0);
        mock.assert_fully_consumed();
        mock.close();
    }
}

#[tokio::test]
async fn archive_ack_then_publication_collision_keeps_both_receipts_uncertain() {
    let body = b"ack-body";
    let r = intent(true, body);
    let (c, mock) = connection().await;
    let mut io = owner(c, CancellationToken::new());
    stat(&mock, r.expected.as_ref());
    stat(&mock, Some(&r.receipt.staged.as_ref().unwrap().entry));
    stat(&mock, None);
    start_writer(&mock, &r);
    writes(&mock, &r);
    flushed(&mock, &r);
    original_archive(&mock, &r);
    before_rename(&mock, &r);
    failure(&mock, Command::SetInfo, 0xc0000035);
    closed(&mock, &r);
    let file = local(body).await;
    let mut payload = VerifiedPayload::open(&file.descriptor, &io.cancel)
        .await
        .unwrap();
    let result = mutation::run(&mut io, &r, Some(&mut payload), false, &mut |_| {}).await;
    assert_eq!(result.outcome, mutation::Outcome::Uncertain);
    assert_eq!(result.code, "already_exists");
    assert_eq!(result.receipt.archived.unwrap().entry, archived(&r));
    assert_eq!(result.receipt.staged.unwrap().entry.bytes, 0);
    assert_eq!(result.save_contract, r.save_contract);
    assert!(result.sha256.is_none() && result.content_evidence.is_none());
    let messages = mock.sent_messages();
    let rename = messages
        .iter()
        .filter(|m| command(m) == Command::SetInfo)
        .map(|m| SetInfoRequest::unpack(&mut ReadCursor::new(&m[64..])).unwrap())
        .rfind(|r| r.file_info_class == 10)
        .unwrap();
    assert_eq!(
        u32::from_le_bytes(rename.buffer[..4].try_into().unwrap()),
        0
    ); // competitor cannot be replaced
    io.close_checked().await.unwrap();
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn discovered_or_restored_archive_prevents_later_drift_becoming_fresh_conflict() {
    for saved in [false, true] {
        for stage_drift in [false, true] {
            let body = b"ack-body";
            let mut r = intent(true, body);
            let archive = archived(&r);
            if saved {
                r.receipt.archived = Some(mutation::Artifact {
                    path: r.sidecar("backup"),
                    entry: archive.clone(),
                    cleanup_safe: true,
                    phase: mutation::StagePhase::Prepared,
                    security_sha256: None,
                    save_contract: None,
                });
            }
            let (c, mock) = connection().await;
            let mut io = owner(c, CancellationToken::new());
            let competitor = entry(&r.path, 99, 77);
            stat(&mock, if stage_drift { None } else { Some(&competitor) });
            let mut stage = r.receipt.staged.as_ref().unwrap().entry.clone();
            if stage_drift {
                stage.index_number = Some(88);
            }
            stat(&mock, Some(&stage));
            stat(&mock, Some(&archive));
            let result = mutation::run(&mut io, &r, None, false, &mut |_| {}).await;
            assert_eq!(result.outcome, mutation::Outcome::Uncertain);
            assert_eq!(result.code, "changed");
            assert_eq!(result.receipt.archived.unwrap().entry, archive);
            assert_eq!(result.receipt.staged.unwrap().entry.bytes, 0);
            assert!(result.content_evidence.is_none() && result.sha256.is_none());
            assert_eq!(result.save_contract, r.save_contract);
            assert!(!mock
                .sent_messages()
                .iter()
                .any(|m| matches!(command(m), Command::Write | Command::SetInfo)));
            io.close_checked().await.unwrap();
            mock.assert_fully_consumed();
            mock.close();
        }
    }
}
