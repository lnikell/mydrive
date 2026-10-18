use super::*;

fn v2() -> MutationRequest {
    let mut r = request(MutationKind::CreateFile);
    r.save_contract = Some(SaveContract::AcknowledgedSmbV2);
    let mut e = entry(&r.sidecar("stage"), 2);
    e.name = r.sidecar("stage").rsplit('/').next().unwrap().into();
    e.bytes = 0;
    r.receipt.staged = Some(Artifact {
        path: r.sidecar("stage"),
        entry: e,
        cleanup_safe: true,
        phase: StagePhase::Allocated,
        security_sha256: Some("b".repeat(64)),
        save_contract: r.save_contract,
    });
    r
}
#[tokio::test]
async fn partial_reconcile_keeps_the_original_empty_creator_receipt() {
    let r = v2();
    let mut remote = Fake::default();
    let mut partial = r.receipt.staged.as_ref().unwrap().entry.clone();
    partial.bytes = 1;
    remote
        .files
        .insert(r.sidecar("stage"), (partial, "partial".into()));
    let result = run(&mut remote, &r, None, true, &mut |_| {}).await;
    assert_eq!(result.outcome, Outcome::NotApplied);
    assert_eq!(result.code, "allocated");
    assert_eq!(result.save_contract, r.save_contract);
    assert!(result.sha256.is_none() && result.content_evidence.is_none());
    assert_eq!(result.receipt.staged.unwrap().entry.bytes, 0);
    assert_eq!(remote.uploads, 0);
    assert_eq!(remote.renames, 0);
}
#[tokio::test]
async fn fresh_hash_recovery_is_distinct_from_normal_ack_and_legacy_sha() {
    let r = v2();
    let mut remote = Fake::default();
    let mut target = r.receipt.staged.as_ref().unwrap().entry.clone();
    target.bytes = 3;
    target.name = "file.txt".into();
    target.attributes = 32;
    remote
        .files
        .insert(r.path.clone(), (target, "a".repeat(64)));
    let normal = run(&mut remote, &r, None, false, &mut |_| {}).await;
    assert_eq!(normal.code, "reconcile_required");
    assert!(normal.content_evidence.is_none());
    let recovered = run(&mut remote, &r, None, true, &mut |_| {}).await;
    assert_eq!(recovered.outcome, Outcome::Committed);
    assert_eq!(recovered.save_contract, r.save_contract);
    assert!(recovered.sha256.is_none());
    assert_eq!(
        recovered.content_evidence.unwrap().kind,
        ContentEvidenceKind::RemoteSha256
    );
    assert!(recovered.receipt.staged.is_none());
    assert_eq!(remote.uploads, 0);
}
#[test]
fn failed_parent_fences_echo_v2_but_never_content_evidence() {
    let r = v2();
    for result in [parent_changed(&r), scope_changed(&r)] {
        assert_eq!(result.outcome, Outcome::Conflict);
        assert_eq!(result.save_contract, r.save_contract);
        assert!(result.content_evidence.is_none() && result.sha256.is_none());
        assert!(result.receipt.staged.is_some());
    }
}

#[test]
fn restored_archive_keeps_parent_and_scope_failure_uncertain_only_for_v2() {
    let mut r = v2();
    r.kind = MutationKind::ReplaceFile;
    r.expected = Some(entry("file.txt", 1));
    r.receipt.staged.as_mut().unwrap().entry.created_filetime =
        r.expected.as_ref().unwrap().created_filetime;
    let mut archive = r.expected.as_ref().unwrap().clone();
    archive.name = r.sidecar("backup").rsplit('/').next().unwrap().into();
    archive.attributes |= 2;
    archive.changed_filetime += 1;
    r.receipt.archived = Some(Artifact {
        path: r.sidecar("backup"),
        entry: archive,
        cleanup_safe: true,
        phase: StagePhase::Prepared,
        security_sha256: None,
        save_contract: None,
    });
    r.validate().unwrap();
    for result in [parent_changed(&r), scope_changed(&r)] {
        assert_eq!(result.outcome, Outcome::Uncertain);
        assert_eq!(result.save_contract, r.save_contract);
        assert!(result.content_evidence.is_none() && result.sha256.is_none());
        assert!(result.receipt.archived.is_some() && result.receipt.staged.is_some());
    }
    r.save_contract = None;
    r.receipt.staged.as_mut().unwrap().save_contract = None;
    r.validate().unwrap();
    for result in [parent_changed(&r), scope_changed(&r)] {
        assert_eq!(result.outcome, Outcome::Conflict);
        assert!(result.save_contract.is_none());
    }
}
