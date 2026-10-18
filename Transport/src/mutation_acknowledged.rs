//! V2 state transitions reuse the canonical remote owner and byte pipeline.
use super::*;

pub(super) async fn execute(
    remote: &mut impl Remote,
    request: &MutationRequest,
    result: &mut MutationResult,
    current: Option<Entry>,
    payload: &mut Option<&mut VerifiedPayload>,
    reconcile: bool,
    progress: &mut dyn FnMut(u64),
) -> Result<()> {
    let stage_path = request.sidecar("stage");
    let stage = remote.stat(&stage_path).await?;
    let backup = if request.kind == MutationKind::ReplaceFile {
        remote.stat(&request.sidecar("backup")).await?
    } else {
        None
    };
    if let Some(entry) = &backup {
        if !same_renamed_version(request.expected.as_ref().unwrap(), entry) {
            return Err(Error::Changed);
        }
        result.receipt.archived = Some(Artifact {
            path: request.sidecar("backup"),
            entry: entry.clone(),
            cleanup_safe: durable_artifact_matches(&request.receipt.archived, entry),
            phase: StagePhase::Prepared,
            security_sha256: request
                .receipt
                .archived
                .as_ref()
                .and_then(|a| a.security_sha256.clone()),
            save_contract: None,
        });
    }
    let Some(origin) = request.receipt.staged.as_ref() else {
        if stage.is_some() {
            result.outcome = Outcome::Uncertain;
            result.code = "allocation_unknown";
            return Ok(());
        }
        if current.as_ref().is_some_and(|entry| {
            request
                .expected
                .as_ref()
                .is_none_or(|base| !same_version(base, entry))
        }) || (request.kind == MutationKind::ReplaceFile
            && (backup.is_some() || current.is_none()))
        {
            return Err(Error::Changed);
        }
        if reconcile {
            return Ok(());
        }
        result.outcome = Outcome::Uncertain;
        result.receipt.staged = Some(remote.allocate(request, &stage_path).await?);
        result.outcome = Outcome::NotApplied;
        result.code = "allocated";
        return Ok(());
    };
    let body = request.payload.as_ref().unwrap();
    if let Some(entry) = &current {
        if same_identity(&origin.entry, entry)
            && entry.bytes == body.bytes
            && !entry.directory
            && stage.is_none()
        {
            if request.kind == MutationKind::ReplaceFile && backup.is_none() {
                return Err(Error::Changed);
            }
            // Only explicit recovery can turn an old creator binding into fresh
            // remote-body evidence. A normal retry cannot manufacture an ACK.
            if !reconcile {
                result.outcome = Outcome::Uncertain;
                result.code = "reconcile_required";
                return Ok(());
            }
            if remote.hash_origin(&request.path, entry, origin).await? != body.sha256 {
                return Err(Error::Changed);
            }
            result.entry = Some(entry.clone());
            result.receipt.staged = None;
            result.content_evidence = Some(ContentEvidence::new(
                ContentEvidenceKind::RemoteSha256,
                body,
            ));
            return committed(result);
        }
        if request
            .expected
            .as_ref()
            .is_none_or(|base| !same_version(base, entry))
            || backup.is_some()
        {
            return Err(Error::Changed);
        }
    } else if request.kind == MutationKind::ReplaceFile && backup.is_none() {
        return Err(Error::Changed);
    }
    let stage = stage.ok_or(Error::Changed)?;
    if !same_identity(&origin.entry, &stage) || stage.directory || stage.bytes > body.bytes {
        return Err(Error::Changed);
    }
    if reconcile {
        // The original zero-byte Allocated receipt remains ownership evidence,
        // never a description of the partially uploaded object's current bytes.
        result.code = "allocated";
        return Ok(());
    }
    result.outcome = Outcome::Uncertain;
    let entry = remote
        .acknowledged_commit(
            request,
            origin,
            payload
                .as_deref_mut()
                .ok_or(Error::Input("missing verified payload"))?,
            &mut result.receipt.archived,
            progress,
        )
        .await?;
    result.entry = Some(entry);
    result.receipt.staged = None;
    result.content_evidence = Some(ContentEvidence::new(
        ContentEvidenceKind::SmbAcknowledged,
        body,
    ));
    committed(result)
}
