//! Recoverable, no-overwrite namespace mutations. The caller durably journals
//! the complete intent before invoking this module and persists every receipt.
//! Replacement deliberately has a namespace gap; it is not an atomic replace.
use crate::{Entry, Error, Result};

#[path = "mutation_request.rs"]
mod request;
pub use request::{
    Artifact, DirectoryIdentity, MutationKind, MutationRequest, MutationResult, Outcome, Payload,
    Receipt, StagePhase,
};

#[path = "mutation_scope.rs"]
mod scope;
pub use scope::DeleteScope;

#[path = "mutation_tree_scope.rs"]
mod tree_scope;
pub use tree_scope::TreeScope;

/// A failed parent guard cannot authorize publication or erase prior receipts.
pub(crate) fn parent_changed(request: &MutationRequest) -> MutationResult {
    fence_changed(request, "parent_changed")
}

pub(crate) fn scope_changed(request: &MutationRequest) -> MutationResult {
    fence_changed(
        request,
        if request.tree_scope.is_some() {
            "tree_scope_changed"
        } else {
            "scope_changed"
        },
    )
}

fn fence_changed(request: &MutationRequest, code: &'static str) -> MutationResult {
    MutationResult {
        operation_id: request.operation_id.clone(),
        outcome: Outcome::Conflict,
        code,
        entry: None,
        sha256: None,
        cleanup_pending: request.receipt.staged.is_some() || request.receipt.archived.is_some(),
        receipt: request.receipt.clone(),
    }
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(DIGITS[(byte >> 4) as usize] as char);
        text.push(DIGITS[(byte & 15) as usize] as char);
    }
    text
}

/// Rename changes ChangeTime on some servers. Recovery compares identity and
/// content-bearing observations, while an initial destructive open compares all.
pub(crate) fn same_identity(left: &Entry, right: &Entry) -> bool {
    left.index_number
        .is_some_and(|id| id != 0 && Some(id) == right.index_number)
        && left.created_filetime == right.created_filetime
        && left.directory == right.directory
}
pub(crate) fn same_version(left: &Entry, right: &Entry) -> bool {
    same_identity(left, right)
        && left.bytes == right.bytes
        && left.modified_filetime == right.modified_filetime
        && left.changed_filetime == right.changed_filetime
        && left.attributes == right.attributes
}
fn same_renamed_version(left: &Entry, right: &Entry) -> bool {
    same_identity(left, right)
        && left.bytes == right.bytes
        && left.modified_filetime == right.modified_filetime
        && same_rename_attributes(left, right)
}

pub(crate) fn same_rename_attributes(left: &Entry, right: &Entry) -> bool {
    // Samba can synthesize HIDDEN from a leading dot rather than persist it as
    // a DOS attribute. Only a change across that name boundary explains this
    // bit changing; readonly/system/directory/archive and all other bits stay
    // exact. Full-version preconditions are deliberately unchanged.
    let hidden_explained = match (left.name.starts_with('.'), right.name.starts_with('.')) {
        (false, true) => left.attributes & 2 == 0 && right.attributes & 2 != 0,
        (true, false) => left.attributes & 2 != 0 && right.attributes & 2 == 0,
        _ => false,
    };
    let mut derived = if hidden_explained { 2 } else { 0 };
    // MS-FSA permits a data-file rename to set ARCHIVE. Clearing it, or
    // changing it for a directory, cannot be explained by that operation.
    if !left.directory
        && !right.directory
        && left.attributes & 32 == 0
        && right.attributes & 32 != 0
    {
        derived |= 32;
        if left.attributes == 128 && right.attributes & 128 == 0 {
            derived |= 128;
        }
    }
    (left.attributes ^ right.attributes) & !derived == 0
}

#[path = "mutation_payload.rs"]
mod payload;
pub(crate) use payload::{ensure_local_plain, VerifiedPayload};

// This seam models SMB operations, not paths-as-transactions: each rename/remove
// implementation holds and checks a same-handle reservation through SET_INFO.
pub(crate) trait Remote {
    async fn stat(&mut self, path: &str) -> Result<Option<Entry>>;
    async fn hash(&mut self, path: &str, expected: &Entry) -> Result<String>;
    async fn allocate(&mut self, request: &MutationRequest, path: &str) -> Result<Artifact>;
    async fn stage(
        &mut self,
        request: &MutationRequest,
        path: &str,
        payload: Option<&mut VerifiedPayload>,
        progress: &mut dyn FnMut(u64),
    ) -> Result<Entry>;
    async fn rename(
        &mut self,
        path: &str,
        expected: &Entry,
        destination: &str,
        hash: Option<&str>,
    ) -> Result<Entry>;
    async fn remove(&mut self, path: &str, expected: &Entry) -> Result<()>;
    async fn canonical_name(&mut self, path: &str, expected: &Entry) -> Result<String>;
    async fn move_item(
        &mut self,
        path: &str,
        expected: &Entry,
        destination: &str,
    ) -> Result<Entry> {
        self.rename(path, expected, destination, None).await
    }
    async fn archive(
        &mut self,
        path: &str,
        expected: &Entry,
        destination: &str,
        staged: &Artifact,
    ) -> Result<Entry> {
        let _ = staged;
        self.rename(path, expected, destination, None).await
    }
    async fn publish(
        &mut self,
        staged: &Artifact,
        destination: &str,
        hash: Option<&str>,
        archived: Option<&Artifact>,
    ) -> Result<Entry> {
        let _ = archived;
        self.rename(&staged.path, &staged.entry, destination, hash)
            .await
    }
}

pub(crate) async fn run(
    remote: &mut impl Remote,
    request: &MutationRequest,
    mut payload: Option<&mut VerifiedPayload>,
    reconcile: bool,
    progress: &mut dyn FnMut(u64),
) -> MutationResult {
    let mut result = MutationResult {
        operation_id: request.operation_id.clone(),
        outcome: Outcome::NotApplied,
        code: "not_applied",
        entry: None,
        sha256: None,
        cleanup_pending: false,
        receipt: request.receipt.clone(),
    };
    let operation = execute(
        remote,
        request,
        &mut result,
        &mut payload,
        reconcile,
        progress,
    )
    .await;
    if let Err(error) = operation {
        result.code = error.code();
        if matches!(
            error,
            Error::Changed | Error::ScopeChanged | Error::Smb(smb2::ErrorKind::AlreadyExists)
        ) {
            result.outcome = Outcome::Conflict;
        } else if matches!(error, Error::DirectoryNotEmpty) || result.outcome != Outcome::Uncertain
        {
            result.outcome = Outcome::NotApplied;
        }
    }
    result.cleanup_pending = result.receipt.staged.is_some() || result.receipt.archived.is_some();
    result
}

async fn execute(
    remote: &mut impl Remote,
    request: &MutationRequest,
    result: &mut MutationResult,
    payload: &mut Option<&mut VerifiedPayload>,
    reconcile: bool,
    progress: &mut dyn FnMut(u64),
) -> Result<()> {
    let current = remote.stat(&request.path).await?;
    match request.kind {
        MutationKind::CreateFile | MutationKind::CreateDirectory | MutationKind::ReplaceFile => {
            publish(
                remote, request, result, current, payload, reconcile, progress,
            )
            .await
        }
        MutationKind::Move => {
            let expected = request.expected.as_ref().unwrap();
            let destination = request.destination.as_ref().unwrap();
            let target = remote.stat(destination).await?;
            if current.is_none()
                && target
                    .as_ref()
                    .is_some_and(|entry| same_renamed_version(expected, entry))
            {
                let entry = target.as_ref().unwrap();
                if remote.canonical_name(destination, entry).await?.as_bytes()
                    != destination.rsplit('/').next().unwrap().as_bytes()
                {
                    return Err(Error::Changed);
                }
                result.entry = target;
                return committed(result);
            }
            let aliases = current
                .as_ref()
                .zip(target.as_ref())
                .is_some_and(|(source, target)| same_identity(source, target));
            if aliases {
                let source = current.as_ref().unwrap();
                let name = remote.canonical_name(&request.path, source).await?;
                if name.as_bytes() == destination.rsplit('/').next().unwrap().as_bytes()
                    && same_renamed_version(expected, source)
                {
                    let mut entry = source.clone();
                    entry.name = name;
                    result.entry = Some(entry);
                    return committed(result);
                }
                if name.as_bytes() != request.path.rsplit('/').next().unwrap().as_bytes() {
                    return Err(Error::Changed);
                }
            }
            if current
                .as_ref()
                .is_none_or(|entry| !same_version(expected, entry))
                || (target.is_some() && !aliases)
            {
                return Err(Error::Changed);
            }
            if reconcile {
                return Ok(());
            }
            result.outcome = Outcome::Uncertain;
            result.entry = Some(
                remote
                    .move_item(&request.path, current.as_ref().unwrap(), destination)
                    .await?,
            );
            committed(result)
        }
        MutationKind::Delete | MutationKind::Cleanup => {
            let expected = request.expected.as_ref().unwrap();
            if request.kind == MutationKind::Cleanup && current.is_none() {
                return committed(result);
            }
            if expected.directory || request.kind == MutationKind::Cleanup {
                // SET_DISPOSITION checks empty directories atomically. Never
                // rename a nonempty user directory into an invisible tombstone.
                if current.is_none() {
                    return committed(result);
                }
                if current
                    .as_ref()
                    .is_none_or(|entry| !same_version(expected, entry))
                {
                    return Err(Error::Changed);
                }
                if reconcile {
                    return Ok(());
                }
                result.outcome = Outcome::Uncertain;
                remote
                    .remove(&request.path, current.as_ref().unwrap())
                    .await?;
                return committed(result);
            }
            let archived_path = request.sidecar("deleted");
            let archived = remote.stat(&archived_path).await?;
            if current.is_none() && archived.is_none() {
                // Success means the requested namespace absence is verified;
                // reconciliation never deletes an item found elsewhere.
                return committed(result);
            }
            if current.is_none()
                && archived
                    .as_ref()
                    .is_some_and(|entry| same_renamed_version(expected, entry))
            {
                result.receipt.archived = archived.map(|entry| Artifact {
                    cleanup_safe: durable_artifact_matches(&request.receipt.archived, &entry),
                    path: archived_path,
                    entry,
                    phase: StagePhase::Prepared,
                    security_sha256: None,
                });
                return committed(result);
            }
            if current
                .as_ref()
                .is_none_or(|entry| !same_version(expected, entry))
                || archived.is_some()
            {
                return Err(Error::Changed);
            }
            if reconcile {
                return Ok(());
            }
            result.outcome = Outcome::Uncertain;
            let entry = remote
                .rename(
                    &request.path,
                    current.as_ref().unwrap(),
                    &archived_path,
                    None,
                )
                .await?;
            result.receipt.archived = Some(Artifact {
                path: archived_path,
                entry,
                cleanup_safe: true,
                phase: StagePhase::Prepared,
                security_sha256: None,
            });
            committed(result)
        }
    }
}

async fn publish(
    remote: &mut impl Remote,
    request: &MutationRequest,
    result: &mut MutationResult,
    current: Option<Entry>,
    payload: &mut Option<&mut VerifiedPayload>,
    reconcile: bool,
    progress: &mut dyn FnMut(u64),
) -> Result<()> {
    let stage_path = request.sidecar("stage");
    let backup_path = request.sidecar("backup");
    let staged = remote.stat(&stage_path).await?;
    let backup = if request.kind == MutationKind::ReplaceFile {
        remote.stat(&backup_path).await?
    } else {
        None
    };
    if let Some(backup) = &backup {
        if !same_renamed_version(request.expected.as_ref().unwrap(), backup) {
            return Err(Error::Changed);
        }
        result.receipt.archived = Some(Artifact {
            path: backup_path.clone(),
            entry: backup.clone(),
            cleanup_safe: durable_artifact_matches(&request.receipt.archived, backup),
            phase: StagePhase::Prepared,
            security_sha256: None,
        });
    }
    // Surface the ambiguous sidecar before a later base conflict can replace
    // the plan and lose its path. A backup receipt, if any, remains attached
    // and prevents the caller from rotating an already-archived operation.
    if staged.is_some() && request.receipt.staged.is_none() {
        result.outcome = Outcome::Uncertain;
        result.code = "allocation_unknown";
        return Ok(());
    }
    if let Some(entry) = &current {
        // A receipt is mandatory to adopt a directory after a lost reply;
        // filenames alone are never sufficient ownership evidence.
        let receipt_match = request.receipt.staged.as_ref().is_some_and(|artifact| {
            artifact.phase == StagePhase::Prepared && same_renamed_version(&artifact.entry, entry)
        });
        let is_new = if let Some(payload) = &request.payload {
            receipt_match
                && entry.bytes == payload.bytes
                && !entry.directory
                && remote.hash(&request.path, entry).await? == payload.sha256
        } else {
            receipt_match && entry.directory
        };
        if is_new && staged.is_none() {
            result.entry = current;
            result.receipt.staged = None;
            result.sha256 = request
                .payload
                .as_ref()
                .map(|payload| payload.sha256.clone());
            return committed(result);
        }
        if request.kind != MutationKind::ReplaceFile
            || backup.is_some()
            || !same_version(request.expected.as_ref().unwrap(), entry)
        {
            return Err(Error::Changed);
        }
    } else if request.kind == MutationKind::ReplaceFile && backup.is_none() {
        return Err(Error::Changed);
    }

    if let Some(entry) = &staged {
        let Some(receipt) = request.receipt.staged.as_ref() else {
            result.outcome = Outcome::Uncertain;
            result.code = "allocation_unknown";
            return Ok(());
        };
        if !same_identity(&receipt.entry, entry) {
            return Err(Error::Changed);
        }
        if receipt.phase == StagePhase::Allocated {
            let expected = request
                .payload
                .as_ref()
                .ok_or(Error::Input("allocation has no payload"))?;
            if entry.directory || entry.bytes > expected.bytes {
                return Err(Error::Changed);
            }
            if reconcile {
                result.code = "allocated";
                return Ok(());
            }
            result.outcome = Outcome::Uncertain;
            let prepared = remote
                .stage(request, &stage_path, payload.as_deref_mut(), progress)
                .await?;
            result.receipt.staged = Some(Artifact {
                path: stage_path,
                entry: prepared,
                cleanup_safe: true,
                phase: StagePhase::Prepared,
                security_sha256: receipt.security_sha256.clone(),
            });
            result.outcome = Outcome::NotApplied;
            result.code = "prepared";
            return Ok(());
        }
        let receipt_match = request
            .receipt
            .staged
            .as_ref()
            .is_some_and(|artifact| same_version(&artifact.entry, entry));
        let verified = if let Some(payload) = &request.payload {
            !entry.directory
                && entry.bytes == payload.bytes
                && remote.hash(&stage_path, entry).await? == payload.sha256
        } else {
            receipt_match && entry.directory
        };
        if !verified {
            result.outcome = Outcome::Uncertain;
            result.code = "unverified_stage";
            return Ok(());
        }
        result.receipt.staged = Some(Artifact {
            path: stage_path.clone(),
            entry: entry.clone(),
            cleanup_safe: durable_artifact_matches(&request.receipt.staged, entry),
            phase: StagePhase::Prepared,
            security_sha256: receipt.security_sha256.clone(),
        });
        if !receipt_match && !reconcile {
            result.outcome = Outcome::NotApplied;
            result.code = "prepared";
            return Ok(());
        }
    }
    if reconcile {
        return Ok(());
    }
    if staged.is_none() {
        if request.receipt.staged.is_some() {
            return Err(Error::Changed);
        }
        if reconcile {
            return Ok(());
        }
        result.outcome = Outcome::Uncertain;
        let allocation = match remote.allocate(request, &stage_path).await {
            Err(Error::Smb(smb2::ErrorKind::AlreadyExists)) => {
                result.code = "allocation_unknown";
                return Ok(());
            }
            result => result?,
        };
        let phase = allocation.phase;
        result.receipt.staged = Some(allocation);
        // No payload bytes precede this receipt's durable acknowledgement.
        result.outcome = Outcome::NotApplied;
        result.code = if phase == StagePhase::Allocated {
            "allocated"
        } else {
            "prepared"
        };
        return Ok(());
    }
    if request.kind == MutationKind::ReplaceFile && backup.is_none() {
        result.outcome = Outcome::Uncertain;
        let original = remote
            .archive(
                &request.path,
                current.as_ref().unwrap(),
                &backup_path,
                result.receipt.staged.as_ref().unwrap(),
            )
            .await?;
        result.receipt.archived = Some(Artifact {
            path: backup_path,
            entry: original,
            cleanup_safe: true,
            phase: StagePhase::Prepared,
            security_sha256: None,
        });
    }
    result.outcome = Outcome::Uncertain;
    let hash = request
        .payload
        .as_ref()
        .map(|payload| payload.sha256.as_str());
    let entry = remote
        .publish(
            result.receipt.staged.as_ref().unwrap(),
            &request.path,
            hash,
            result.receipt.archived.as_ref(),
        )
        .await?;
    result.entry = Some(entry);
    result.receipt.staged = None;
    result.sha256 = hash.map(str::to_owned);
    committed(result)
}

fn committed(result: &mut MutationResult) -> Result<()> {
    result.outcome = Outcome::Committed;
    result.code = "committed";
    Ok(())
}

fn durable_artifact_matches(receipt: &Option<Artifact>, observed: &Entry) -> bool {
    receipt
        .as_ref()
        .is_some_and(|artifact| artifact.cleanup_safe && same_version(&artifact.entry, observed))
}

#[cfg(test)]
#[path = "mutation_tests.rs"]
mod tests;
