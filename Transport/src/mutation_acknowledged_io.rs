//! One held allocated writer, compliant-server acknowledgements and final facts.
use super::*;

impl MutationIO {
    pub(super) async fn hash_creator_content(
        &self,
        path: &str,
        expected: &Entry,
        origin: &mutation::Artifact,
    ) -> Result<String> {
        if origin.save_contract != Some(mutation::SaveContract::AcknowledgedSmbV2)
            || !mutation::same_identity(&origin.entry, expected)
        {
            return Err(Error::Changed);
        }
        let security = origin.security_sha256.as_deref().ok_or(Error::Changed)?;
        let handle = self.acknowledged_open(path, Open::SecurityGuarded).await?;
        let result = async {
            let before = handle.observe(path).await?;
            if !mutation::same_version(expected, &before) {
                return Err(Error::Changed);
            }
            require_acknowledged(&handle, &origin.entry, &before, expected.bytes, security).await?;
            let hash = handle.hash(expected.bytes).await?;
            let after = handle.observe(path).await?;
            if !mutation::same_version(&before, &after) {
                return Err(Error::Changed);
            }
            require_acknowledged(&handle, &origin.entry, &after, expected.bytes, security).await?;
            if handle.canonical_name(path, &after).await?.as_bytes()
                != path.rsplit('/').next().unwrap().as_bytes()
            {
                return Err(Error::Changed);
            }
            Ok(hash)
        }
        .await;
        let closed = handle.close().await;
        if self.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        result.and_then(|value| closed.map(|()| value))
    }
    async fn acknowledged_open(&self, path: &str, mode: Open) -> Result<Handle> {
        let mut opening = crate::guarded_read::OpenLifetime(Some(self.connection.clone()));
        let handle = self.open(path, mode).await?;
        opening.0 = None;
        Ok(handle)
    }

    async fn acknowledged_original(
        &self,
        request: &MutationRequest,
        archived: &Option<mutation::Artifact>,
    ) -> Result<Option<Handle>> {
        let expected = archived
            .as_ref()
            .map(|a| (&a.path, &a.entry))
            .or_else(|| request.expected.as_ref().map(|e| (&request.path, e)));
        let Some((path, expected)) = expected else {
            return Ok(None);
        };
        let handle = self.acknowledged_open(path, Open::SecurityGuarded).await?;
        let checked = async {
            if !mutation::same_version(expected, &handle.observe(path).await?) {
                return Err(Error::Changed);
            }
            handle.ensure_plain(expected).await?;
            Ok(())
        }
        .await;
        if let Err(error) = checked {
            let _ = handle.close().await;
            return Err(error);
        }
        Ok(Some(handle))
    }

    pub(super) async fn commit_acknowledged_writer(
        &self,
        request: &MutationRequest,
        origin: &mutation::Artifact,
        payload: &mut VerifiedPayload,
        archived: &mut Option<mutation::Artifact>,
        progress: &mut dyn FnMut(u64),
    ) -> Result<Entry> {
        if request.save_contract != Some(mutation::SaveContract::AcknowledgedSmbV2)
            || origin.save_contract != request.save_contract
            || origin.phase != mutation::StagePhase::Allocated
            || origin.path != request.sidecar("stage")
            || origin.entry.bytes != 0
            || !origin.cleanup_safe
        {
            return Err(Error::Input("ACK requires its exact creator allocation"));
        }
        if request.payload.as_ref().is_none_or(|expected| {
            expected.bytes != payload.bytes || expected.sha256 != payload.sha256
        }) || request.receipt.staged.as_ref().is_none_or(|saved| {
            saved.path != origin.path
                || saved.entry != origin.entry
                || saved.security_sha256 != origin.security_sha256
                || saved.phase != origin.phase
                || saved.save_contract != origin.save_contract
                || saved.cleanup_safe != origin.cleanup_safe
        }) {
            return Err(Error::Input(
                "ACK inputs differ from their immutable request",
            ));
        }
        let security = origin
            .security_sha256
            .as_deref()
            .ok_or(Error::Input("missing creator security"))?;
        let original = self.acknowledged_original(request, archived).await?;
        let writer = self
            .acknowledged_open(&origin.path, Open::UploadAllocated)
            .await?;
        let operation = async {
            let before = writer.observe(&origin.path).await?;
            if !mutation::same_identity(&origin.entry, &before)
                || before.directory
                || before.bytes > payload.bytes
                || before.attributes & !BASIC_ATTRIBUTES != 0
            {
                return Err(Error::Changed);
            }
            writer.ensure_plain(&before).await?;
            if writer.security().await?.fingerprint() != security {
                return Err(Error::Changed);
            }
            if let Some(original) = &original {
                original
                    .security()
                    .await?
                    .require_same(&writer.security().await?)?;
            }
            mutation::ensure_local_plain(&payload.file)?;
            // Only an unpublished, creator-confirmed sidecar may be reset.
            writer.set(20, 0u64.to_le_bytes().to_vec()).await?;
            writer.write_payload(payload, progress).await?;
            mutation::ensure_local_plain(&payload.file)?;
            if let Some(base) = &request.expected {
                let mut basic = vec![0; 40];
                basic[32..36].copy_from_slice(&base.attributes.to_le_bytes());
                writer.set(4, basic).await?;
            }
            writer
                .execute(
                    Command::Flush,
                    &FlushRequest {
                        file_id: writer.file,
                    },
                )
                .await?;
            let uploaded = writer.observe(&origin.path).await?;
            require_acknowledged(&writer, &origin.entry, &uploaded, payload.bytes, security)
                .await?;
            if let Some(base) = &request.expected {
                if archived.is_none() {
                    let original = original.as_ref().ok_or(Error::Changed)?;
                    if !mutation::same_version(base, &original.observe(&request.path).await?) {
                        return Err(Error::Changed);
                    }
                    original
                        .security()
                        .await?
                        .require_same(&writer.security().await?)?;
                    let entry = original
                        .rename(&request.path, base, &request.sidecar("backup"), None)
                        .await?;
                    // Caller-owned partial receipt survives every later await.
                    *archived = Some(mutation::Artifact {
                        path: request.sidecar("backup"),
                        entry,
                        cleanup_safe: true,
                        phase: mutation::StagePhase::Prepared,
                        security_sha256: Some(security.to_owned()),
                        save_contract: None,
                    });
                }
            }
            let current = writer.observe(&origin.path).await?;
            if !mutation::same_version(&uploaded, &current) {
                return Err(Error::Changed);
            }
            require_acknowledged(&writer, &origin.entry, &current, payload.bytes, security).await?;
            writer.rename_observed(&current, &request.path).await
        }
        .await;
        let writer_closed = writer.close().await;
        let original_closed = if let Some(original) = original {
            original.close().await
        } else {
            Ok(())
        };
        if self.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let published = operation?;
        writer_closed?;
        original_closed?;
        if self.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        // CLOSE has no portable ownership/version bridge. Reopen and compare
        // every final version fact; unexplained drift requires strict recovery.
        let final_handle = self
            .acknowledged_open(&request.path, Open::SecurityGuarded)
            .await?;
        let observed = async {
            let final_entry = final_handle.observe(&request.path).await?;
            if !mutation::same_version(&published, &final_entry) {
                return Err(Error::CommitUncertain);
            }
            require_acknowledged(
                &final_handle,
                &origin.entry,
                &final_entry,
                payload.bytes,
                security,
            )
            .await?;
            if final_handle
                .canonical_name(&request.path, &final_entry)
                .await?
                .as_bytes()
                != request.path.rsplit('/').next().unwrap().as_bytes()
            {
                return Err(Error::CommitUncertain);
            }
            if !mutation::same_version(&final_entry, &final_handle.observe(&request.path).await?) {
                return Err(Error::CommitUncertain);
            }
            Ok(final_entry)
        }
        .await;
        let closed = final_handle.close().await;
        if self.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let final_entry = observed.map_err(|error| {
            if matches!(error, Error::Changed) {
                Error::CommitUncertain
            } else {
                error
            }
        })?;
        closed?;
        if self.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        Ok(final_entry)
    }
}

async fn require_acknowledged(
    handle: &Handle,
    origin: &Entry,
    entry: &Entry,
    bytes: u64,
    security: &str,
) -> Result<()> {
    if !mutation::same_identity(origin, entry)
        || entry.directory
        || entry.bytes != bytes
        || entry.attributes & !BASIC_ATTRIBUTES != 0
    {
        return Err(Error::Changed);
    }
    handle.ensure_plain(entry).await?;
    if handle.security().await?.fingerprint() != security {
        return Err(Error::Changed);
    }
    Ok(())
}
