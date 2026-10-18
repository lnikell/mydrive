//! Live-only stage verification, retained by the existing mutation owner.
use super::*;

pub(super) struct PreparedStage {
    handle: Handle,
    artifact: mutation::Artifact,
    hash: Option<String>,
    destination: String,
    original: Option<Entry>,
    backup_path: String,
}
impl PreparedStage {
    pub(super) async fn verify(
        io: &MutationIO,
        request: &MutationRequest,
        staged: &mutation::Artifact,
    ) -> Result<Option<Self>> {
        if staged.path != request.sidecar("stage") || staged.phase != mutation::StagePhase::Prepared
        {
            return Err(Error::Changed);
        }
        let hash = request
            .payload
            .as_ref()
            .map(|payload| payload.sha256.clone());
        if staged.entry.directory != hash.is_none()
            || request
                .payload
                .as_ref()
                .is_some_and(|payload| payload.bytes != staged.entry.bytes)
        {
            return Err(Error::Changed);
        }
        // The same canonical open lifetime covers a dropped first CREATE.
        let mut opening = crate::guarded_read::OpenLifetime(Some(io.connection.clone()));
        let handle = io
            .open(
                &staged.path,
                if request.kind == mutation::MutationKind::ReplaceFile
                    || staged.security_sha256.is_some()
                {
                    Open::SecurityGuarded
                } else {
                    Open::Guarded
                },
            )
            .await?;
        opening.0 = None;
        let owner = Self {
            handle,
            artifact: staged.clone(),
            hash,
            destination: request.path.clone(),
            original: request.expected.clone(),
            backup_path: request.sidecar("backup"),
        };
        let verified = async {
            let before = owner.recheck().await?;
            let matches = if let Some(hash) = &owner.hash {
                owner.handle.hash(before.bytes).await? == *hash
            } else {
                true
            };
            owner.recheck().await?;
            Ok(matches)
        }
        .await;
        match verified {
            Ok(true) => Ok(Some(owner)),
            outcome => {
                let closed = owner.close().await;
                match outcome {
                    Err(error) => Err(error),
                    Ok(false) => {
                        closed?;
                        Ok(None)
                    }
                    Ok(true) => unreachable!(),
                }
            }
        }
    }

    fn matches(&self, staged: &mutation::Artifact) -> bool {
        self.artifact.path == staged.path
            && self.artifact.entry == staged.entry
            && self.artifact.phase == staged.phase
            && self.artifact.cleanup_safe == staged.cleanup_safe
            && self.artifact.security_sha256 == staged.security_sha256
            && self.artifact.save_contract == staged.save_contract
    }
    async fn recheck(&self) -> Result<Entry> {
        let observed = self.handle.observe(&self.artifact.path).await?;
        if observed != self.artifact.entry {
            return Err(Error::Changed);
        }
        self.handle.ensure_plain(&observed).await?;
        if let Some(expected) = &self.artifact.security_sha256 {
            if self.handle.security().await?.fingerprint() != *expected {
                return Err(Error::Changed);
            }
        }
        Ok(observed)
    }

    pub(super) async fn archive(
        &self,
        io: &MutationIO,
        path: &str,
        expected: &Entry,
        destination: &str,
        staged: &mutation::Artifact,
    ) -> Result<Entry> {
        if !self.matches(staged)
            || path != self.destination
            || destination != self.backup_path
            || self
                .original
                .as_ref()
                .is_none_or(|original| !mutation::same_version(original, expected))
        {
            return Err(Error::Changed);
        }
        self.recheck().await?;
        let mut opening = crate::guarded_read::OpenLifetime(Some(io.connection.clone()));
        let original = io.open(path, Open::SecurityGuarded).await?;
        opening.0 = None;
        let result = async {
            if !mutation::same_version(expected, &original.observe(path).await?) {
                return Err(Error::Changed);
            }
            original
                .security()
                .await?
                .require_same(&self.handle.security().await?)?;
            original.rename(path, expected, destination, None).await
        }
        .await;
        let _ = original.close().await;
        result
    }

    pub(super) async fn publish(
        self,
        io: &MutationIO,
        staged: &mutation::Artifact,
        destination: &str,
        hash: Option<&str>,
        archived: Option<&mutation::Artifact>,
    ) -> Result<Entry> {
        let result = self
            .publish_held(io, staged, destination, hash, archived)
            .await;
        // Match existing publication semantics: cleanup cannot erase a verified
        // rename or the caller's already acknowledged archive receipt.
        let _ = self.close().await;
        result
    }
    async fn publish_held(
        &self,
        io: &MutationIO,
        staged: &mutation::Artifact,
        destination: &str,
        hash: Option<&str>,
        archived: Option<&mutation::Artifact>,
    ) -> Result<Entry> {
        if !self.matches(staged)
            || destination != self.destination
            || hash != self.hash.as_deref()
            || archived.is_some_and(|artifact| artifact.path != self.backup_path)
        {
            return Err(Error::Changed);
        }
        let before = self.recheck().await?;
        let backup = if let Some(artifact) = archived {
            let handle = io.open(&artifact.path, Open::SecurityGuarded).await?;
            let verified = async {
                if !mutation::same_version(&artifact.entry, &handle.observe(&artifact.path).await?)
                {
                    return Err(Error::Changed);
                }
                handle
                    .security()
                    .await?
                    .require_same(&self.handle.security().await?)
            }
            .await;
            if let Err(error) = verified {
                let _ = handle.close().await;
                return Err(error);
            }
            Some(handle)
        } else {
            None
        };
        let result = self.handle.rename_observed(&before, destination).await;
        if let Some(backup) = backup {
            let _ = backup.close().await;
        }
        result
    }
    pub(super) async fn close(self) -> Result<()> {
        self.handle.close().await
    }
}
