//! Creator-confirmed allocation is durable before the first payload WRITE.
//! Only an allocated, unpublished sidecar grants whole-payload restart rights.
use super::*;
use crate::mutation::{Artifact, StagePhase};
use crate::mutation_security::AccessSecurity;

impl MutationIO {
    async fn guarded_base(
        &self,
        request: &MutationRequest,
    ) -> Result<Option<(Handle, AccessSecurity)>> {
        let Some(expected) = &request.expected else {
            return Ok(None);
        };
        if expected.attributes & !BASIC_ATTRIBUTES != 0 {
            return Err(Error::Smb(smb2::ErrorKind::Unsupported));
        }
        let handle = self.open(&request.path, Open::SecurityGuarded).await?;
        let checked = async {
            if !mutation::same_version(expected, &handle.observe(&request.path).await?) {
                return Err(Error::Changed);
            }
            handle.ensure_plain(expected).await?;
            handle.security().await
        }
        .await;
        match checked {
            Ok(security) => Ok(Some((handle, security))),
            Err(error) => {
                let _ = handle.close().await;
                Err(error)
            }
        }
    }

    pub(super) async fn allocate_stage(
        &self,
        request: &MutationRequest,
        path: &str,
    ) -> Result<Artifact> {
        let original = self.guarded_base(request).await?;
        let security = original.as_ref().map(|(_, value)| value);
        let directory = request.kind == mutation::MutationKind::CreateDirectory;
        let handle = Handle::open_security(
            self.connection.clone(),
            self.tree,
            path,
            if directory {
                Open::CreateDirectory
            } else {
                Open::CreateFile
            },
            &self.cancel,
            security,
        )
        .await?;
        let observed = async {
            let actual = handle.security().await?;
            if let Some(expected) = security {
                expected.require_same(&actual)?;
            }
            if let Some(expected) = &request.expected {
                // Creation time participates in object identity. Change it now,
                // never after the allocation's identity has been acknowledged.
                let mut basic = vec![0; 40];
                basic[..8].copy_from_slice(&expected.created_filetime.to_le_bytes());
                handle.set(4, basic).await?;
                handle
                    .execute(
                        Command::Flush,
                        &FlushRequest {
                            file_id: handle.file,
                        },
                    )
                    .await?;
            }
            let entry = handle.observe(path).await?;
            if entry.directory != directory || entry.bytes != 0 {
                return Err(Error::Changed);
            }
            handle.ensure_plain(&entry).await?;
            if let Some(expected) = &request.expected {
                if entry.created_filetime != expected.created_filetime {
                    return Err(Error::Changed);
                }
            }
            Ok((entry, actual.fingerprint()))
        }
        .await;
        let closed = handle.close().await;
        let allocation = match observed {
            Ok((entry, fingerprint)) => {
                closed?;
                self.verify_allocated(path, &entry, &fingerprint, None)
                    .await
                    .map(|entry| Artifact {
                        save_contract: request.save_contract,
                        path: path.to_owned(),
                        entry,
                        cleanup_safe: true,
                        phase: if directory {
                            StagePhase::Prepared
                        } else {
                            StagePhase::Allocated
                        },
                        security_sha256: Some(fingerprint),
                    })
            }
            Err(error) => Err(error),
        };
        if let Some((original, _)) = original {
            let _ = original.close().await;
        }
        allocation
    }

    /// The durable allocation receipt authorizes resetting this exact owned
    /// temporary object even when interrupted pipelining left holes. It never
    /// grants overwrite/truncate authority over a document or archived original.
    pub(super) async fn upload_allocated_stage(
        &self,
        request: &MutationRequest,
        path: &str,
        payload: Option<&mut VerifiedPayload>,
        progress: &mut dyn FnMut(u64),
    ) -> Result<Entry> {
        let allocation = request
            .receipt
            .staged
            .as_ref()
            .ok_or(Error::Input("missing allocation receipt"))?;
        if allocation.phase != StagePhase::Allocated
            || allocation.path != request.sidecar("stage")
            || allocation.path != path
            || !allocation.cleanup_safe
        {
            return Err(Error::Input(
                "upload requires a creator-confirmed allocation",
            ));
        }
        let fingerprint = allocation
            .security_sha256
            .as_ref()
            .ok_or(Error::Input("missing allocation security"))?;
        let payload = payload.ok_or(Error::Input("missing verified local payload"))?;
        mutation::ensure_local_plain(&payload.file)?;
        let original = self.guarded_base(request).await?;
        let handle = self.open(path, Open::UploadAllocated).await?;
        let uploaded = async {
            let before = handle.observe(path).await?;
            if !mutation::same_identity(&allocation.entry, &before)
                || before.directory
                || before.bytes > payload.bytes
                || before.attributes & !BASIC_ATTRIBUTES != 0
            {
                return Err(Error::Changed);
            }
            handle.ensure_plain(&before).await?;
            let security = handle.security().await?;
            if security.fingerprint() != *fingerprint {
                return Err(Error::Changed);
            }
            if let Some((_, expected)) = &original {
                expected.require_same(&security)?;
            }
            // FILE_END_OF_FILE_INFORMATION. This is the sole reset authority:
            // the same held identity, still an ordinary private allocation.
            handle.set(20, 0u64.to_le_bytes().to_vec()).await?;
            handle.write_payload(payload, progress).await?;
            mutation::ensure_local_plain(&payload.file)?;
            handle
                .execute(
                    Command::Flush,
                    &FlushRequest {
                        file_id: handle.file,
                    },
                )
                .await?;
            if let Some(expected) = &request.expected {
                let mut basic = vec![0; 40];
                basic[32..36].copy_from_slice(&expected.attributes.to_le_bytes());
                handle.set(4, basic).await?;
            }
            let entry = handle.observe(path).await?;
            if !mutation::same_identity(&allocation.entry, &entry) || entry.bytes != payload.bytes {
                return Err(Error::Changed);
            }
            if handle.security().await?.fingerprint() != *fingerprint {
                return Err(Error::Changed);
            }
            handle
                .execute(
                    Command::Flush,
                    &FlushRequest {
                        file_id: handle.file,
                    },
                )
                .await?;
            Ok(entry)
        }
        .await;
        let closed = handle.close().await;
        let prepared = match uploaded {
            Ok(entry) => {
                closed?;
                self.verify_allocated(path, &entry, fingerprint, Some(payload))
                    .await
            }
            Err(error) => Err(error),
        };
        if let Some((original, _)) = original {
            let _ = original.close().await;
        }
        prepared
    }

    async fn verify_allocated(
        &self,
        path: &str,
        expected: &Entry,
        fingerprint: &str,
        payload: Option<&VerifiedPayload>,
    ) -> Result<Entry> {
        // CLOSE may finalize timestamps. The prepared receipt always describes
        // a reopened, full-hash-verified writer; no prior integrity pass is lost.
        let handle = self.open(path, Open::SecurityGuarded).await?;
        let verified = async {
            let entry = handle.observe(path).await?;
            if !mutation::same_identity(expected, &entry) {
                return Err(Error::Changed);
            }
            handle.ensure_plain(&entry).await?;
            if handle.security().await?.fingerprint() != fingerprint {
                return Err(Error::Changed);
            }
            if let Some(payload) = payload {
                if entry.bytes != payload.bytes || handle.hash(entry.bytes).await? != payload.sha256
                {
                    return Err(Error::Changed);
                }
            } else if entry.bytes != 0 {
                return Err(Error::Changed);
            }
            let after = handle.observe(path).await?;
            if !mutation::same_version(&entry, &after) {
                return Err(Error::Changed);
            }
            Ok(after)
        }
        .await;
        let closed = handle.close().await;
        verified.and_then(|value| closed.map(|()| value))
    }
}

#[cfg(test)]
#[path = "mutation_allocation_tests.rs"]
mod tests;
