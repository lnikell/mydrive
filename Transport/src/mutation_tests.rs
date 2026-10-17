use super::*;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

const OP: &str = "11111111-2222-4333-8444-555555555555";
fn entry(name: &str, index: u64) -> Entry {
    Entry {
        name: name.into(),
        bytes: 3,
        directory: false,
        index_number: Some(index),
        created_filetime: 100 + index,
        modified_filetime: 20,
        changed_filetime: 30,
        attributes: 32,
    }
}
fn request(kind: MutationKind) -> MutationRequest {
    MutationRequest {
        operation_id: OP.into(),
        kind,
        path: "folder/file.txt".into(),
        parent: DirectoryIdentity {
            index_number: 5,
            created_filetime: 6,
        },
        delete_scope: None,
        tree_scope: None,
        destination: None,
        destination_parent: (kind == MutationKind::Move).then_some(DirectoryIdentity {
            index_number: 5,
            created_filetime: 6,
        }),
        expected: matches!(
            kind,
            MutationKind::ReplaceFile
                | MutationKind::Move
                | MutationKind::Delete
                | MutationKind::Cleanup
        )
        .then(|| entry("file.txt", 1)),
        payload: matches!(kind, MutationKind::CreateFile | MutationKind::ReplaceFile).then(|| {
            Payload {
                source: "/tmp/staged".into(),
                bytes: 3,
                sha256: "a".repeat(64),
            }
        }),
        receipt: Receipt::default(),
    }
}
#[derive(Default)]
struct Fake {
    files: BTreeMap<String, (Entry, String)>,
    renames: usize,
    fail_rename: Option<usize>,
    after_effect: bool,
    create_race: bool,
    nonempty: bool,
    lose_remove_reply: bool,
    removes: usize,
    verification_failure: bool,
    case_insensitive: bool,
    unicode_alias: bool,
    partial_upload_failure: bool,
    uploads: usize,
}
impl Fake {
    fn stored_path(&self, path: &str) -> Option<String> {
        if self.files.contains_key(path) {
            return Some(path.to_owned());
        }
        self.files
            .keys()
            .find(|candidate| {
                candidate.as_str() == path
                    || self.case_insensitive && candidate.eq_ignore_ascii_case(path)
                    || self.unicode_alias
                        && candidate.replace("e\u{301}", "é") == path.replace("e\u{301}", "é")
            })
            .cloned()
    }
    fn original() -> Self {
        let mut remote = Self::default();
        remote.files.insert(
            "folder/file.txt".into(),
            (entry("file.txt", 1), "old".into()),
        );
        remote
    }
}

#[tokio::test]
async fn case_and_unicode_alias_renames_reconcile_actual_spelling_without_overwrite() {
    for (source, destination, unicode) in [
        ("file.txt", "FILE.txt", false),
        ("cafe\u{301}.txt", "café.txt", true),
    ] {
        let mut remote = Fake {
            case_insensitive: !unicode,
            unicode_alias: unicode,
            ..Default::default()
        };
        let path = format!("folder/{source}");
        remote
            .files
            .insert(path.clone(), (entry(source, 1), "old".into()));
        let mut request = request(MutationKind::Move);
        request.path = path;
        request.destination = Some(format!("folder/{destination}"));
        request.expected = Some(entry(source, 1));
        remote.fail_rename = Some(1);
        remote.after_effect = true;
        assert_eq!(
            run(&mut remote, &request, None, false, &mut |_| {})
                .await
                .outcome,
            Outcome::Uncertain
        );
        let replay = run(&mut remote, &request, None, true, &mut |_| {}).await;
        assert_eq!(replay.outcome, Outcome::Committed);
        assert_eq!(
            replay.entry.unwrap().name.as_bytes(),
            destination.as_bytes()
        );
        assert_eq!(remote.renames, 1);
    }
    let mut remote = Fake::original();
    remote.case_insensitive = true;
    remote.files.insert(
        "folder/FILE.txt".into(),
        (entry("FILE.txt", 99), "other".into()),
    );
    let mut request = request(MutationKind::Move);
    request.destination = Some("folder/FILE.txt".into());
    assert_eq!(
        run(&mut remote, &request, None, false, &mut |_| {})
            .await
            .outcome,
        Outcome::Conflict
    );
    assert_eq!(remote.renames, 0);
    assert_eq!(remote.files["folder/FILE.txt"].1, "other");
}
impl Remote for Fake {
    async fn stat(&mut self, path: &str) -> Result<Option<Entry>> {
        Ok(self
            .stored_path(path)
            .and_then(|path| self.files.get(&path))
            .map(|(entry, _)| entry.clone()))
    }
    async fn canonical_name(&mut self, path: &str, _: &Entry) -> Result<String> {
        let path = self.stored_path(path).ok_or(Error::Changed)?;
        Ok(self.files[&path].0.name.clone())
    }
    async fn hash(&mut self, path: &str, expected: &Entry) -> Result<String> {
        let (entry, hash) = self.files.get(path).unwrap();
        if !same_version(entry, expected) {
            return Err(Error::Changed);
        }
        Ok(hash.clone())
    }
    async fn allocate(&mut self, request: &MutationRequest, path: &str) -> Result<Artifact> {
        if self.files.contains_key(path) {
            return Err(Error::Smb(smb2::ErrorKind::AlreadyExists));
        }
        let mut entry = entry(path, 2);
        entry.name = path.rsplit('/').next().unwrap().into();
        entry.bytes = 0;
        if let Some(expected) = &request.expected {
            entry.created_filetime = expected.created_filetime;
        }
        if request.kind == MutationKind::CreateDirectory {
            entry.directory = true;
            entry.attributes = 16;
        }
        if entry.name.starts_with('.') {
            entry.attributes |= 2;
        }
        self.files
            .insert(path.into(), (entry.clone(), "empty".into()));
        Ok(Artifact {
            path: path.into(),
            entry,
            cleanup_safe: true,
            phase: if request.kind == MutationKind::CreateDirectory {
                StagePhase::Prepared
            } else {
                StagePhase::Allocated
            },
            security_sha256: Some("b".repeat(64)),
        })
    }
    async fn stage(
        &mut self,
        request: &MutationRequest,
        path: &str,
        _: Option<&mut VerifiedPayload>,
        _: &mut dyn FnMut(u64),
    ) -> Result<Entry> {
        let allocation = request.receipt.staged.as_ref().ok_or(Error::Changed)?;
        let mut entry = self.files.get(path).ok_or(Error::Changed)?.0.clone();
        if allocation.phase != StagePhase::Allocated || !same_identity(&allocation.entry, &entry) {
            return Err(Error::Changed);
        }
        entry.bytes = request.payload.as_ref().unwrap().bytes;
        entry.changed_filetime += 1;
        self.uploads += 1;
        if self.partial_upload_failure {
            self.partial_upload_failure = false;
            entry.bytes /= 2;
            self.files
                .insert(path.into(), (entry, "partial-with-holes".into()));
            return Err(Error::Smb(smb2::ErrorKind::ConnectionLost));
        }
        self.files.insert(
            path.into(),
            (
                entry.clone(),
                request
                    .payload
                    .as_ref()
                    .map_or("".into(), |payload| payload.sha256.clone()),
            ),
        );
        Ok(entry)
    }
    async fn rename(
        &mut self,
        path: &str,
        expected: &Entry,
        destination: &str,
        hash: Option<&str>,
    ) -> Result<Entry> {
        self.renames += 1;
        if self.create_race && destination == "folder/file.txt" {
            self.files.insert(
                destination.into(),
                (entry("outsider", 77), "external".into()),
            );
        }
        if self.files.contains_key(destination) {
            return Err(Error::Smb(smb2::ErrorKind::AlreadyExists));
        }
        let (observed, body) = self.files.get(path).ok_or(Error::Changed)?;
        if !same_version(observed, expected) || hash.is_some_and(|hash| hash != body) {
            return Err(Error::Changed);
        }
        if self.fail_rename == Some(self.renames) && !self.after_effect {
            return Err(Error::Cancelled);
        }
        let (mut moved, body) = self.files.remove(path).unwrap();
        moved.name = destination.rsplit('/').next().unwrap().into();
        if moved.name.starts_with('.') {
            moved.attributes |= 2;
        } else {
            moved.attributes &= !2;
        }
        moved.changed_filetime += 1;
        self.files.insert(destination.into(), (moved.clone(), body));
        if self.fail_rename == Some(self.renames) {
            if self.verification_failure {
                return Err(Error::CommitUncertain);
            }
            return Err(Error::Smb(smb2::ErrorKind::ConnectionLost));
        }
        Ok(moved)
    }
    async fn remove(&mut self, path: &str, expected: &Entry) -> Result<()> {
        if self.nonempty {
            return Err(Error::DirectoryNotEmpty);
        }
        if !self
            .files
            .get(path)
            .is_some_and(|(entry, _)| same_version(entry, expected))
        {
            return Err(Error::Changed);
        }
        self.files.remove(path);
        self.removes += 1;
        if self.lose_remove_reply {
            return Err(Error::Smb(smb2::ErrorKind::ConnectionLost));
        }
        Ok(())
    }
}

async fn prepare(remote: &mut Fake, request: &MutationRequest) -> MutationResult {
    let allocated = run(remote, request, None, false, &mut |_| {}).await;
    if allocated.code != "allocated" {
        return allocated;
    }
    let mut follow = request.clone();
    follow.receipt = allocated.receipt;
    run(remote, &follow, None, false, &mut |_| {}).await
}

#[tokio::test]
async fn allocated_receipt_precedes_bytes_and_recovers_interrupted_owned_stage() {
    let mut remote = Fake::original();
    let mut request = request(MutationKind::ReplaceFile);
    let allocated = run(&mut remote, &request, None, false, &mut |_| {}).await;
    assert_eq!(allocated.code, "allocated");
    let artifact = allocated.receipt.staged.as_ref().unwrap();
    assert_eq!(artifact.phase, StagePhase::Allocated);
    assert_eq!(artifact.entry.bytes, 0);
    assert_eq!(
        artifact.entry.created_filetime,
        request.expected.as_ref().unwrap().created_filetime
    );
    assert_eq!(remote.uploads, 0);
    assert_eq!(remote.renames, 0);
    request.receipt = allocated.receipt;
    remote.partial_upload_failure = true;
    assert_eq!(
        run(&mut remote, &request, None, false, &mut |_| {})
            .await
            .outcome,
        Outcome::Uncertain
    );
    assert_eq!(
        remote.files[&request.sidecar("stage")].1,
        "partial-with-holes"
    );
    assert_eq!(remote.files[&request.path].1, "old");
    let reconciled = run(&mut remote, &request, None, true, &mut |_| {}).await;
    assert_eq!(reconciled.code, "allocated");
    assert_eq!(remote.uploads, 1); // Reconciliation never rewrites bytes.
    request.receipt = reconciled.receipt;
    let prepared = run(&mut remote, &request, None, false, &mut |_| {}).await;
    assert_eq!(prepared.code, "prepared");
    assert_eq!(
        prepared.receipt.staged.as_ref().unwrap().phase,
        StagePhase::Prepared
    );
    assert_eq!(remote.renames, 0);
    request.receipt = prepared.receipt;
    let committed = run(&mut remote, &request, None, false, &mut |_| {}).await;
    assert_eq!(committed.outcome, Outcome::Committed);
    assert_eq!(remote.files[&request.path].1, "a".repeat(64));
    assert_eq!(remote.files[&request.sidecar("backup")].1, "old");
}

#[tokio::test]
async fn missing_allocation_receipt_never_adopts_even_a_full_matching_payload() {
    let mut remote = Fake::default();
    let request = request(MutationKind::CreateFile);
    let _lost = run(&mut remote, &request, None, false, &mut |_| {}).await;
    let stage = remote.files.get_mut(&request.sidecar("stage")).unwrap();
    stage.0.bytes = request.payload.as_ref().unwrap().bytes;
    stage.1 = request.payload.as_ref().unwrap().sha256.clone();
    for reconcile in [false, true] {
        let unknown = run(&mut remote, &request, None, reconcile, &mut |_| {}).await;
        assert_eq!(unknown.outcome, Outcome::Uncertain);
        assert_eq!(unknown.code, "allocation_unknown");
        assert!(unknown.receipt.staged.is_none());
        assert_eq!(remote.uploads, 0);
        assert_eq!(remote.renames, 0);
    }
    let mut replacement = Fake::original();
    let request = self::request(MutationKind::ReplaceFile);
    let _lost = run(&mut replacement, &request, None, false, &mut |_| {}).await;
    replacement
        .files
        .get_mut(&request.path)
        .unwrap()
        .0
        .changed_filetime += 1;
    let changed_base = run(&mut replacement, &request, None, true, &mut |_| {}).await;
    assert_eq!(changed_base.code, "allocation_unknown");
    assert!(changed_base.receipt.staged.is_none());
    assert_eq!(replacement.uploads, 0);
}

#[tokio::test]
async fn replaced_or_oversized_allocation_cannot_authorize_restart() {
    for replaced in [false, true] {
        let mut remote = Fake::default();
        let mut request = request(MutationKind::CreateFile);
        request.receipt = run(&mut remote, &request, None, false, &mut |_| {})
            .await
            .receipt;
        let stage = &mut remote.files.get_mut(&request.sidecar("stage")).unwrap().0;
        if replaced {
            stage.index_number = Some(99);
        } else {
            stage.bytes = 4;
        }
        let before = remote.files[&request.sidecar("stage")].clone();
        assert_eq!(
            run(&mut remote, &request, None, false, &mut |_| {})
                .await
                .outcome,
            Outcome::Conflict
        );
        assert_eq!(remote.files[&request.sidecar("stage")], before);
        assert_eq!(remote.uploads, 0);
    }
}

#[tokio::test]
async fn stage_receipt_precedes_namespace_changes_and_backup_cleanup_is_explicit() {
    let mut remote = Fake::original();
    let mut request = request(MutationKind::ReplaceFile);
    let prepared = prepare(&mut remote, &request).await;
    assert_eq!(prepared.code, "prepared");
    assert_eq!(remote.files[&request.path].1, "old");
    assert_eq!(remote.renames, 0);
    request.receipt = prepared.receipt;
    let committed = run(&mut remote, &request, None, false, &mut |_| {}).await;
    assert_eq!(committed.outcome, Outcome::Committed);
    assert_eq!(remote.files[&request.path].1, "a".repeat(64));
    assert!(committed.cleanup_pending);
    assert_eq!(remote.files[&request.sidecar("backup")].1, "old");
    let artifact = committed.receipt.archived.unwrap();
    let mut cleanup = request.clone();
    cleanup.kind = MutationKind::Cleanup;
    cleanup.path = artifact.path;
    cleanup.expected = Some(artifact.entry);
    cleanup.payload = None;
    cleanup.receipt = Receipt::default();
    cleanup.validate().unwrap();
    assert_eq!(
        run(&mut remote, &cleanup, None, false, &mut |_| {})
            .await
            .outcome,
        Outcome::Committed
    );
    assert_eq!(remote.files.len(), 1);
}

#[tokio::test]
async fn lost_publication_reply_recovers_identity_and_hash_without_replay() {
    let mut remote = Fake::original();
    let mut request = request(MutationKind::ReplaceFile);
    request.receipt = prepare(&mut remote, &request).await.receipt;
    remote.fail_rename = Some(2);
    remote.after_effect = true;
    let lost = run(&mut remote, &request, None, false, &mut |_| {}).await;
    assert_eq!(lost.outcome, Outcome::Uncertain);
    let count = remote.renames;
    let recovered = run(&mut remote, &request, None, true, &mut |_| {}).await;
    assert_eq!(recovered.outcome, Outcome::Committed);
    assert_eq!(remote.renames, count);
    assert!(recovered.receipt.archived.is_some());
    // Equal payload bytes with an unrelated identity must not be adopted.
    remote.files.get_mut(&request.path).unwrap().0.index_number = Some(999);
    assert_eq!(
        run(&mut remote, &request, None, true, &mut |_| {})
            .await
            .outcome,
        Outcome::Conflict
    );
}

#[tokio::test]
async fn lost_archival_reply_retains_original_without_inventing_cleanup_authority() {
    let mut remote = Fake::original();
    let mut request = request(MutationKind::ReplaceFile);
    request.receipt = prepare(&mut remote, &request).await.receipt;
    remote.fail_rename = Some(1);
    remote.after_effect = true;
    let lost = run(&mut remote, &request, None, false, &mut |_| {}).await;
    assert_eq!(lost.outcome, Outcome::Uncertain);
    assert!(lost.receipt.archived.is_none());
    let recovered = run(&mut remote, &request, None, true, &mut |_| {}).await;
    assert_eq!(recovered.outcome, Outcome::NotApplied);
    assert!(!recovered.receipt.archived.as_ref().unwrap().cleanup_safe);
    request.receipt = recovered.receipt;
    remote.fail_rename = None;
    let committed = run(&mut remote, &request, None, false, &mut |_| {}).await;
    assert_eq!(committed.outcome, Outcome::Committed);
    assert!(!committed.receipt.archived.unwrap().cleanup_safe);
    assert_eq!(remote.files[&request.sidecar("backup")].1, "old");
}

#[tokio::test]
async fn failed_post_commit_verification_is_uncertain_not_a_precondition_conflict() {
    let mut remote = Fake::original();
    let mut request = request(MutationKind::ReplaceFile);
    request.receipt = prepare(&mut remote, &request).await.receipt;
    remote.fail_rename = Some(2);
    remote.after_effect = true;
    remote.verification_failure = true;
    let failed = run(&mut remote, &request, None, false, &mut |_| {}).await;
    assert_eq!(failed.outcome, Outcome::Uncertain);
    assert_eq!(failed.code, "commit_uncertain");
    assert_eq!(remote.files[&request.sidecar("backup")].1, "old");
}

#[tokio::test]
async fn nonempty_directory_delete_is_definitively_not_applied() {
    let mut remote = Fake::original();
    let mut request = request(MutationKind::Delete);
    let observed = &mut remote.files.get_mut(&request.path).unwrap().0;
    observed.directory = true;
    observed.attributes = 16;
    request.expected = Some(observed.clone());
    remote.nonempty = true;
    let result = run(&mut remote, &request, None, false, &mut |_| {}).await;
    assert_eq!(result.outcome, Outcome::NotApplied);
    assert_eq!(result.code, "directory_not_empty");
    assert_eq!(remote.renames, 0);
    assert!(remote.files.contains_key(&request.path));
}

#[tokio::test]
async fn lost_directory_delete_reply_reconciles_absence_without_any_additional_delete() {
    let mut remote = Fake::original();
    let mut request = request(MutationKind::Delete);
    let observed = &mut remote.files.get_mut(&request.path).unwrap().0;
    observed.directory = true;
    observed.attributes = 16;
    request.expected = Some(observed.clone());
    remote.lose_remove_reply = true;
    assert_eq!(
        run(&mut remote, &request, None, false, &mut |_| {})
            .await
            .outcome,
        Outcome::Uncertain
    );
    assert_eq!(remote.removes, 1);
    assert!(remote.files.is_empty());
    assert_eq!(
        run(&mut remote, &request, None, true, &mut |_| {})
            .await
            .outcome,
        Outcome::Committed
    );
    assert_eq!(remote.removes, 1);
    assert_eq!(remote.renames, 0);
    // A new unrelated directory at the same path is never deleted on replay.
    remote.files.insert(
        request.path.clone(),
        (entry("outsider", 999), "external".into()),
    );
    assert_eq!(
        run(&mut remote, &request, None, true, &mut |_| {})
            .await
            .outcome,
        Outcome::Conflict
    );
    assert_eq!(remote.removes, 1);
}

#[tokio::test]
async fn concurrent_creator_wins_and_original_is_preserved() {
    let mut remote = Fake::original();
    let mut request = request(MutationKind::ReplaceFile);
    request.receipt = prepare(&mut remote, &request).await.receipt;
    remote.create_race = true;
    let conflict = run(&mut remote, &request, None, false, &mut |_| {}).await;
    assert_eq!(conflict.outcome, Outcome::Conflict);
    assert_eq!(remote.files[&request.path].1, "external");
    assert_eq!(remote.files[&request.sidecar("backup")].1, "old");
    assert!(conflict.cleanup_pending);
}

#[tokio::test]
async fn stale_base_and_cancellation_cannot_publish_or_delete_original() {
    let mut remote = Fake::original();
    let mut request = request(MutationKind::ReplaceFile);
    request.receipt = prepare(&mut remote, &request).await.receipt;
    remote
        .files
        .get_mut(&request.path)
        .unwrap()
        .0
        .changed_filetime += 1;
    assert_eq!(
        run(&mut remote, &request, None, false, &mut |_| {})
            .await
            .outcome,
        Outcome::Conflict
    );
    assert_eq!(remote.renames, 0);
    remote
        .files
        .get_mut(&request.path)
        .unwrap()
        .0
        .changed_filetime -= 1;
    remote.fail_rename = Some(1);
    assert_eq!(
        run(&mut remote, &request, None, false, &mut |_| {})
            .await
            .outcome,
        Outcome::Uncertain
    );
    assert_eq!(remote.files[&request.path].1, "old");
}

#[tokio::test]
async fn directory_create_lost_stage_receipt_is_not_guessed_from_name() {
    let mut remote = Fake::default();
    let request = request(MutationKind::CreateDirectory);
    let prepared = prepare(&mut remote, &request).await;
    assert_eq!(prepared.code, "prepared");
    let missing = run(&mut remote, &request, None, true, &mut |_| {}).await;
    assert_eq!(missing.outcome, Outcome::Uncertain);
    assert_eq!(remote.renames, 0);
    let mut receipted = request;
    receipted.receipt = prepared.receipt;
    assert_eq!(
        run(&mut remote, &receipted, None, false, &mut |_| {})
            .await
            .outcome,
        Outcome::Committed
    );
}

#[test]
fn invalid_intents_and_cross_operation_receipts_fail_closed() {
    let good = request(MutationKind::ReplaceFile);
    good.validate().unwrap();
    let mut wrong = good.clone();
    wrong.operation_id = OP.to_uppercase() + "x";
    assert!(wrong.validate().is_err());
    let mut wrong = good.clone();
    wrong.path = "../escape".into();
    assert!(wrong.validate().is_err());
    let mut wrong = good.clone();
    wrong.receipt.staged = Some(Artifact {
        path: "folder/another.stage".into(),
        entry: entry("a", 2),
        cleanup_safe: false,
        phase: crate::mutation::StagePhase::Prepared,
        security_sha256: None,
    });
    assert!(wrong.validate().is_err());
    let mut wrong = good.clone();
    wrong.expected.as_mut().unwrap().index_number = None;
    assert!(wrong.validate().is_err());
    let mut wrong = good.clone();
    wrong.kind = MutationKind::Cleanup;
    assert!(wrong.validate().is_err());
    let mut wrong = good;
    wrong.destination = Some("elsewhere".into());
    assert!(wrong.validate().is_err());
}

#[test]
fn parent_snapshot_contract_is_required_bounded_and_path_derived() {
    let good = request(MutationKind::ReplaceFile);
    good.validate().unwrap();
    let mut old = serde_json::to_value(&good).unwrap();
    old.as_object_mut().unwrap().remove("parent");
    assert!(serde_json::from_value::<MutationRequest>(old).is_err());
    for identity in [
        DirectoryIdentity {
            index_number: 0,
            created_filetime: 6,
        },
        DirectoryIdentity {
            index_number: 5,
            created_filetime: 0,
        },
    ] {
        let mut invalid = good.clone();
        invalid.parent = identity;
        assert!(invalid.validate().is_err());
    }
    let mut root = good.clone();
    root.path = "file.txt".into();
    assert_eq!(root.parent_snapshots(), vec![("", root.parent)]);
    let mut movement = request(MutationKind::Move);
    movement.destination = Some("target/file.txt".into());
    movement.destination_parent = Some(DirectoryIdentity {
        index_number: 7,
        created_filetime: 8,
    });
    movement.validate().unwrap();
    assert_eq!(
        movement.parent_snapshots(),
        vec![
            ("folder", movement.parent),
            ("target", movement.destination_parent.unwrap())
        ]
    );
    movement.destination = Some("folder/other.txt".into());
    assert!(movement.validate().is_err());
    movement.destination_parent = None;
    assert!(movement.validate().is_err());
    let mut unrelated = good;
    unrelated.destination_parent = Some(unrelated.parent);
    assert!(unrelated.validate().is_err());
}

#[test]
fn only_conforming_archive_addition_is_accepted_for_file_rename() {
    let mut before = entry("old", 1);
    let mut after = entry("new", 1);
    for (old, new, accepted) in [
        (0, 32, true),
        (128, 32, true),
        (1, 33, true),
        (32, 0, false),
        (32, 128, false),
        (0, 1, false),
    ] {
        before.attributes = old;
        after.attributes = new;
        assert_eq!(same_rename_attributes(&before, &after), accepted);
    }
    before.directory = true;
    after.directory = true;
    before.attributes = 16;
    after.attributes = 48;
    assert!(!same_rename_attributes(&before, &after));
}

#[tokio::test]
async fn local_payload_hash_size_symlink_and_cancellation_preflight() {
    let root = std::env::temp_dir().join(format!("mydrive-payload-test-{}", std::process::id()));
    tokio::fs::create_dir_all(&root).await.unwrap();
    let path = root.join("body");
    tokio::fs::write(&path, b"abc").await.unwrap();
    let mut payload = Payload {
        source: path.to_string_lossy().into(),
        bytes: 3,
        sha256: crate::mutation::hex(&Sha256::digest(b"abc")),
    };
    let cancel = crate::CancellationToken::new();
    assert!(VerifiedPayload::open(&payload, &cancel).await.is_ok());
    payload.sha256 = "0".repeat(64);
    assert!(matches!(
        VerifiedPayload::open(&payload, &cancel).await,
        Err(Error::Changed)
    ));
    payload.sha256 = crate::mutation::hex(&Sha256::digest(b"abc"));
    let cancelled = crate::CancellationToken::new();
    cancelled.cancel();
    assert!(matches!(
        VerifiedPayload::open(&payload, &cancelled).await,
        Err(Error::Cancelled)
    ));
    #[cfg(unix)]
    {
        let link = root.join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        payload.source = link.to_string_lossy().into();
        assert!(VerifiedPayload::open(&payload, &cancel).await.is_err());
    }
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn layout2_root_lost_publication_reply_reconciles_without_an_arena_or_another_rename() {
    let source = "folder/.mydrive-11111111-2222-4333-8444-555555555555.tree";
    let destination = "folder/Imported folder";
    let mut root = entry(source.rsplit('/').next().unwrap(), 1);
    root.directory = true;
    root.attributes = 18;
    let mut request = request(MutationKind::Move);
    request.path = source.into();
    request.destination = Some(destination.into());
    request.expected = Some(root.clone());
    request.tree_scope = Some(TreeScope {
        layout_version: 2,
        arena_path: source.into(),
        arena: DirectoryIdentity {
            index_number: 1,
            created_filetime: 101,
        },
        parent: request.parent,
    });
    request.validate().unwrap();
    assert_eq!(request.scope_snapshots(), [("folder", request.parent)]);
    let mut remote = Fake {
        fail_rename: Some(1),
        after_effect: true,
        ..Default::default()
    };
    remote
        .files
        .insert(source.into(), (root.clone(), "directory".into()));
    let result = run(&mut remote, &request, None, false, &mut |_| {}).await;
    assert_eq!(result.outcome, Outcome::Uncertain);
    assert!(!remote.files.contains_key(source));
    let final_entry = remote.files[destination].0.clone();
    let result = run(&mut remote, &request, None, true, &mut |_| {}).await;
    assert_eq!(result.outcome, Outcome::Committed);
    assert!(same_identity(result.entry.as_ref().unwrap(), &root));
    assert_eq!(remote.renames, 1);
    // A different object at the published pathname is never adopted, even if
    // all lengths/timestamps happen to match the saved root receipt.
    remote.files.get_mut(destination).unwrap().0.index_number = Some(99);
    let result = run(&mut remote, &request, None, true, &mut |_| {}).await;
    assert_eq!(result.outcome, Outcome::Conflict);
    assert_eq!(remote.renames, 1);
    assert_eq!(remote.files[destination].0.index_number, Some(99));
    // The original remains recoverable in the frozen receipt, not a new stat.
    assert_eq!(
        request.expected.as_ref().unwrap().index_number,
        final_entry.index_number
    );
}
