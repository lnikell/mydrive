//! A disposable SMB experiment, not a synchronization engine.
//!
//! The module owns signing checks, bounded I/O, handle cleanup and a lexical
//! mutation guard. The NAS account's ACL remains the containment control.
//! Cancellation invalidates the session; construct a new session afterward.

use serde::{Deserialize, Serialize};
use smb2::{ClientConfig, RenameOptions, SmbClient, Tree};
use std::{path::Path, time::Duration};
use tokio::io::AsyncReadExt;
pub use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

mod connection_readiness;
mod content_metadata;
mod guarded_download;
mod guarded_read;
mod held_metadata;
pub mod mutation;
mod mutation_io;
mod mutation_security;
#[cfg(test)]
mod test_wire;

pub const CHUNK_BYTES: usize = 256 * 1024;
pub const READ_WINDOW: usize = 8;
pub const WRITE_BUDGET: u64 = 4 * 1024 * 1024;
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Input(&'static str),
    #[error("the authenticated session is not signed")]
    Unsigned,
    #[error("the share did not enable required encryption")]
    Unencrypted,
    #[error("operation cancelled; reconnect before further work")]
    Cancelled,
    #[error("SMB operation failed ({0:?})")]
    Smb(smb2::ErrorKind),
    #[error("local I/O failed ({0:?})")]
    Io(std::io::ErrorKind),
    #[error("handle cleanup exceeded its deadline; session invalidated")]
    Cleanup,
    #[error("the file version or confirmed transfer length changed")]
    Changed,
    #[error("the frozen recursive deletion selection changed")]
    ScopeChanged,
    #[error("the private new-tree arena or its parent changed")]
    TreeScopeChanged,
    #[error("the directory is not empty")]
    DirectoryNotEmpty,
    #[error("a dispatched mutation could not be verified; reconcile before retrying")]
    CommitUncertain,
}

impl Error {
    /// Stable CLI classifications. Callers must handle unknown future codes.
    pub fn code(&self) -> &'static str {
        use smb2::ErrorKind as S;
        match self {
            Self::Input(_) => "invalid_input",
            Self::Unsigned => "unsigned",
            Self::Unencrypted => "encryption_required",
            Self::Cancelled => "cancelled",
            Self::Cleanup => "cleanup_timeout",
            Self::Changed => "changed",
            Self::ScopeChanged => "scope_changed",
            Self::TreeScopeChanged => "tree_scope_changed",
            Self::DirectoryNotEmpty => "directory_not_empty",
            Self::CommitUncertain => "commit_uncertain",
            Self::Io(_) => "local_io",
            Self::Smb(kind) => match kind {
                S::AuthRequired => "auth_required",
                S::SigningRequired => "signing_required",
                S::AccessDenied => "access_denied",
                S::NotFound => "not_found",
                S::AlreadyExists => "already_exists",
                S::SharingViolation => "sharing_violation",
                S::IsADirectory => "is_directory",
                S::NotADirectory => "not_directory",
                S::DiskFull => "disk_full",
                S::ConnectionLost => "connection_lost",
                S::TimedOut => "timed_out",
                S::Cancelled => "cancelled",
                S::SessionExpired => "session_expired",
                S::DfsReferral => "dfs_referral",
                S::InvalidData => "invalid_data",
                S::TooLarge => "too_large",
                S::Io => "transport_io",
                S::InvalidName => "invalid_name",
                S::Unsupported => "unsupported",
                S::ResumeRefused => "resume_refused",
                S::SignatureInvalid => "signature_invalid",
                S::GuestSessionRefused => "guest_refused",
                _ => "smb_error",
            },
        }
    }
}

impl From<smb2::Error> for Error {
    fn from(value: smb2::Error) -> Self {
        Self::Smb(value.kind())
    }
}
impl From<std::io::Error> for Error {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value.kind())
    }
}
pub type Result<T> = std::result::Result<T, Error>;

fn tree_scope_error(error: Error) -> Error {
    match error {
        Error::ScopeChanged => Error::TreeScopeChanged,
        other => other,
    }
}

/// Credentials are never serialized. The upstream client retains a password
/// copy for its session; this input copy is cleared when connection completes.
pub struct Connection {
    pub address: String,
    pub username: String,
    pub password: Zeroizing<String>,
    pub share: String,
    pub require_encryption: bool,
    /// Explicit experiment namespace, for example `.mydrive-transport-tests/run-1`.
    pub mutation_root: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Security {
    pub dialect: String,
    pub signing: bool,
    pub signing_algorithm: String,
    pub encryption: bool,
    pub cipher: String,
    pub compression: bool,
    pub read_chunk_bytes: usize,
    pub read_window: usize,
    pub write_budget_bytes: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    pub name: String,
    pub bytes: u64,
    pub directory: bool,
    pub index_number: Option<u64>,
    pub created_filetime: u64,
    pub modified_filetime: u64,
    pub changed_filetime: u64,
    pub attributes: u32,
}

#[derive(Debug, Serialize)]
pub struct Download {
    pub bytes: u64,
    /// Same-handle metadata that agreed before and after the guarded read.
    pub entry: Entry,
}

#[derive(Debug, Serialize)]
pub struct Listing {
    pub entries: usize,
    pub complete: bool,
    /// The actual reserved directory handle used for every emitted batch.
    pub entry: Entry,
}

/// Closed observed-list events. Legacy listing callers receive pages only.
pub enum ListingObservation {
    Started(Entry),
    Page(Vec<Entry>),
}

#[derive(Debug, Serialize)]
pub struct Share {
    pub name: String,
    pub comment: String,
}

/// Read-only named-pipe RPC discovery. Reported disk shares still need an
/// explicit connect/access check; enumeration is not proof of write access.
pub async fn discover_shares(config: Connection) -> Result<(Security, Vec<Share>)> {
    let mut client = authenticated(&config).await?;
    if config.require_encryption && !client.diagnostics().primary.encryption.active {
        client.connection().mark_dead();
        return Err(Error::Unencrypted);
    }
    let result = client.list_shares().await;
    let security = session_security(&client);
    client.connection().mark_dead();
    Ok((
        security,
        result?
            .into_iter()
            .map(|entry| Share {
                name: entry.name,
                comment: entry.comment,
            })
            .collect(),
    ))
}

async fn authenticated(config: &Connection) -> Result<SmbClient> {
    if config.username.is_empty() {
        return Err(Error::Input("a named account is required"));
    }
    let client = connection_readiness::connect(|| {
        SmbClient::connect(ClientConfig {
            addr: config.address.clone(),
            username: config.username.clone(),
            password: config.password.to_string(),
            timeout: Duration::from_secs(10),
            response_timeout: Some(Duration::from_secs(15)),
            auto_reconnect: false,
            compression: false,
            dfs_enabled: false,
            ..Default::default()
        })
    })
    .await?;
    if !client.diagnostics().primary.signing.active {
        client.connection().mark_dead();
        return Err(Error::Unsigned);
    }
    client.connection().set_write_budget(WRITE_BUDGET);
    Ok(client)
}

fn session_security(client: &SmbClient) -> Security {
    let diag = client.diagnostics().primary;
    Security {
        dialect: diag
            .negotiated
            .map(|x| format!("{:?}", x.dialect))
            .unwrap_or_default(),
        signing: diag.signing.active,
        signing_algorithm: format!("{:?}", diag.signing.algorithm),
        encryption: diag.encryption.active,
        cipher: format!("{:?}", diag.encryption.cipher),
        compression: diag.compression.negotiated,
        read_chunk_bytes: CHUNK_BYTES,
        read_window: READ_WINDOW,
        write_budget_bytes: WRITE_BUDGET,
    }
}

/// A signed session with one selected share and no automatic mutation replay.
pub struct Nas {
    client: SmbClient,
    tree: Tree,
    security: Security,
    mutation_root: Option<String>,
}

impl Nas {
    /// Observe an ordinary item without following reparse points. A missing
    /// path is a successful `None`; permissions and unsupported metadata fail.
    pub async fn stat(&self, path: &str, cancel: &CancellationToken) -> Result<Option<Entry>> {
        self.stat_scoped(path, None, cancel).await
    }

    /// Absence is observed while the frozen selection's directory objects stay
    /// reserved. It does not authorize adopting a different object at the path.
    pub async fn stat_scoped(
        &self,
        path: &str,
        scope: Option<&mutation::DeleteScope>,
        cancel: &CancellationToken,
    ) -> Result<Option<Entry>> {
        use mutation::Remote;
        validate_path(path, true)?;
        let mut io = if let Some(scope) = scope {
            mutation_io::MutationIO::for_scoped_stat(
                self.client.connection().clone(),
                &self.tree,
                path,
                scope,
                cancel,
            )
            .await?
        } else {
            mutation_io::MutationIO::new(
                self.client.connection().clone(),
                &self.tree,
                &[path],
                cancel,
            )
            .await?
        };
        let result = if let Some(scope) = scope {
            io.stat_in_scope(path, scope).await
        } else {
            io.stat(path).await
        };
        let closed = io.close_checked().await;
        result.and_then(|entry| closed.map(|()| entry))
    }

    pub async fn stat_tree_scoped(
        &self,
        path: &str,
        scope: &mutation::TreeScope,
        cancel: &CancellationToken,
    ) -> Result<Option<Entry>> {
        scope.validate_path(path)?;
        self.stat_scoped(path, Some(&scope.fence()), cancel)
            .await
            .map_err(tree_scope_error)
    }

    /// The complete intent must already be durable in the caller. `prepared`
    /// requires persisting its receipt before a second invocation publishes.
    pub async fn mutate(
        &self,
        request: &mutation::MutationRequest,
        reconcile: bool,
        cancel: &CancellationToken,
        mut progress: impl FnMut(u64),
    ) -> Result<mutation::MutationResult> {
        request.validate()?;
        if let Some(root) = &self.mutation_root {
            let prefix = format!("{root}/");
            if !request.path.starts_with(&prefix)
                || request
                    .destination
                    .as_ref()
                    .is_some_and(|path| !path.starts_with(&prefix))
                || request.delete_scope.as_ref().is_some_and(|scope| {
                    scope.root_path != *root && !scope.root_path.starts_with(&prefix)
                })
                || request.tree_scope.as_ref().is_some_and(|scope| {
                    scope.arena_path != *root && !scope.arena_path.starts_with(&prefix)
                })
            {
                return Err(Error::Input(
                    "native mutation is outside the configured experiment root",
                ));
            }
        }
        let mut payload = if !reconcile {
            match &request.payload {
                Some(payload) => Some(mutation::VerifiedPayload::open(payload, cancel).await?),
                None => None,
            }
        } else {
            None
        };
        let mut io = match mutation_io::MutationIO::for_mutation(
            self.client.connection().clone(),
            &self.tree,
            request,
            cancel,
        )
        .await
        {
            Ok(io) => io,
            Err(Error::Changed) => return Ok(mutation::parent_changed(request)),
            Err(Error::ScopeChanged) => return Ok(mutation::scope_changed(request)),
            Err(error) => return Err(error),
        };
        let result =
            mutation::run(&mut io, request, payload.as_mut(), reconcile, &mut progress).await;
        io.close().await;
        Ok(result)
    }
    pub async fn connect(config: Connection) -> Result<Self> {
        if config.share.is_empty() {
            return Err(Error::Input("a share is required"));
        }
        if let Some(root) = &config.mutation_root {
            validate_root(root)?;
        }
        let mut client = authenticated(&config).await?;
        let tree = client.connect_share(&config.share).await?;
        let diag = client.diagnostics().primary;
        if config.require_encryption && !diag.encryption.active {
            client.connection().mark_dead();
            return Err(Error::Unencrypted);
        }
        let security = session_security(&client);
        Ok(Self {
            client,
            tree,
            security,
            mutation_root: config.mutation_root,
        })
    }

    pub fn security(&self) -> &Security {
        &self.security
    }

    /// Each callback receives one server page. No complete-directory array.
    /// A limit closes the reader early without making a completeness claim.
    pub async fn list(
        &mut self,
        path: &str,
        page_limit: Option<usize>,
        cancel: &CancellationToken,
        page: impl FnMut(Vec<Entry>) -> Result<()>,
    ) -> Result<Listing> {
        self.list_scoped(path, page_limit, None, cancel, page).await
    }

    pub async fn list_scoped(
        &mut self,
        path: &str,
        page_limit: Option<usize>,
        scope: Option<&mutation::DeleteScope>,
        cancel: &CancellationToken,
        page: impl FnMut(Vec<Entry>) -> Result<()>,
    ) -> Result<Listing> {
        validate_path(path, true)?;
        mutation_io::listing::read(
            self.client.connection().clone(),
            &self.tree,
            path,
            page_limit,
            scope,
            cancel,
            page,
        )
        .await
    }

    /// Ordinary visibility observes the actual held parent before any page.
    pub async fn list_observed(
        &mut self,
        path: &str,
        cancel: &CancellationToken,
        observation: impl FnMut(ListingObservation) -> Result<()>,
    ) -> Result<Listing> {
        validate_path(path, true)?;
        mutation_io::listing::read_observed(
            self.client.connection().clone(),
            &self.tree,
            path,
            None,
            None,
            cancel,
            observation,
        )
        .await
    }

    pub async fn list_tree_scoped(
        &mut self,
        path: &str,
        page_limit: Option<usize>,
        scope: &mutation::TreeScope,
        cancel: &CancellationToken,
        page: impl FnMut(Vec<Entry>) -> Result<()>,
    ) -> Result<Listing> {
        scope.validate_path(path)?;
        self.list_scoped(path, page_limit, Some(&scope.fence()), cancel, page)
            .await
            .map_err(tree_scope_error)
    }

    /// Full readback keeps both arena fences alive through the ordinary
    /// same-handle content validation. A separate path stat is not a fence.
    pub async fn download_tree_scoped(
        &mut self,
        remote: &str,
        local: &Path,
        scope: &mutation::TreeScope,
        cancel: &CancellationToken,
        progress: impl FnMut(u64),
    ) -> Result<Download> {
        scope.validate_payload_path(remote)?;
        let fences = mutation_io::MutationIO::for_scoped_read(
            self.client.connection().clone(),
            &self.tree,
            remote,
            Some(&scope.fence()),
            cancel,
        )
        .await
        .map_err(tree_scope_error)?;
        let result = guarded_download::run(
            self.client.connection().clone(),
            &self.tree,
            remote,
            local,
            guarded_download::Purpose::Strict {
                offset: 0,
                length: None,
            },
            cancel,
            progress,
        )
        .await;
        let closed = fences.close_checked().await.map_err(tree_scope_error);
        match (result, closed) {
            (Ok(staged), Ok(())) => staged.finish(cancel).await,
            (Ok(_), Err(error)) => Err(error),
            (Err(error), _) => Err(error),
        }
    }

    /// Writes a new local destination, using eight positioned reads of at most
    /// 256 KiB each. Range length never controls an unbounded allocation.
    pub async fn download(
        &mut self,
        remote: &str,
        local: &Path,
        offset: u64,
        length: Option<u64>,
        cancel: &CancellationToken,
        mut progress: impl FnMut(u64),
    ) -> Result<Download> {
        guarded_download::run(
            self.client.connection().clone(),
            &self.tree,
            remote,
            local,
            guarded_download::Purpose::Strict { offset, length },
            cancel,
            &mut progress,
        )
        .await?
        .finish(cancel)
        .await
    }

    /// Ordinary macOS replica hydration. The closed sync profile is never used
    /// by strict archive, mutation or tree verification downloads.
    pub async fn hydrate(
        &mut self,
        remote: &str,
        local: &Path,
        cancel: &CancellationToken,
        progress: impl FnMut(u64),
    ) -> Result<Download> {
        guarded_download::run(
            self.client.connection().clone(),
            &self.tree,
            remote,
            local,
            guarded_download::Purpose::Hydration,
            cancel,
            progress,
        )
        .await?
        .finish(cancel)
        .await
    }

    /// Exclusive temporary sibling + FLUSH/CLOSE + rename without replacement.
    /// An uncertain final rename is returned as an error, never blindly replayed.
    pub async fn upload(
        &mut self,
        local: &Path,
        relative: &str,
        cancel: &CancellationToken,
        mut progress: impl FnMut(u64),
    ) -> Result<u64> {
        let destination = self.mutation_path(relative)?;
        let mut input = tokio::fs::File::open(local).await?;
        if !input.metadata().await?.is_file() {
            return Err(Error::Input("upload source must be a regular file"));
        }
        let temporary = temporary_sibling(&destination);
        let mut writer = tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                self.client.connection().mark_dead();
                return Err(Error::Cancelled);
            }
            writer = self.client.create_file_writer_exclusive(&self.tree, &temporary) => writer?,
        };
        let outcome: Result<u64> = async {
            let mut buffer = vec![0; CHUNK_BYTES];
            let mut total = 0;
            loop {
                let count = tokio::select! {
                    biased;
                    _ = cancel.cancelled() => return Err(Error::Cancelled),
                    result = input.read(&mut buffer) => result?,
                };
                if count == 0 {
                    return Ok(total);
                }
                tokio::select! {
                    biased;
                    _ = cancel.cancelled() => return Err(Error::Cancelled),
                    result = writer.write_chunk(&buffer[..count]) => result?,
                }
                total += count as u64;
                progress(total);
            }
        }
        .await;
        let expected = match outcome {
            Ok(count) => count,
            Err(error) => {
                // The helper's abort is best-effort; discard this session if
                // draining or closing fails to finish within the fixed budget.
                if tokio::time::timeout(CLEANUP_TIMEOUT, writer.abort())
                    .await
                    .is_err()
                {
                    self.client.connection().mark_dead();
                }
                let _ = tokio::time::timeout(
                    CLEANUP_TIMEOUT,
                    self.client.delete_file(&self.tree, &temporary),
                )
                .await;
                // Upstream abort deliberately swallows a failed CLOSE. End
                // the session after an aborted write so no hidden handle is
                // retained by a subsequent operation on this Nas value.
                self.client.connection().mark_dead();
                return Err(error);
            }
        };
        let finished = tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                self.client.connection().mark_dead();
                return Err(Error::Cancelled);
            },
            result = writer.finish() => result,
        };
        let written = match finished {
            Ok(written) => written,
            Err(error) => {
                self.client.connection().mark_dead();
                return Err(error.into());
            }
        };
        if expected != written {
            return Err(Error::Changed);
        }
        let renamed = tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                self.client.connection().mark_dead();
                return Err(Error::Cancelled);
            }
            renamed = self.client.rename(&self.tree, &temporary, &destination) => renamed,
        };
        if let Err(error) = renamed {
            // This name was created exclusively by us. If the rename actually
            // committed, it no longer exists; never delete the final name.
            let _ = tokio::time::timeout(
                CLEANUP_TIMEOUT,
                self.client.delete_file(&self.tree, &temporary),
            )
            .await;
            return Err(error.into());
        }
        Ok(written)
    }

    pub async fn mkdir(&mut self, relative: &str) -> Result<()> {
        let path = self.mutation_path(relative)?;
        Ok(self.client.create_directory(&self.tree, &path).await?)
    }
    /// Creates only the reserved experiment directory and selected run root.
    pub async fn prepare_experiment(&mut self) -> Result<()> {
        let root = required_experiment_root(self.mutation_root.as_deref())?.to_owned();
        for path in [".mydrive-transport-tests", root.as_str()] {
            match self.client.create_directory(&self.tree, path).await {
                Ok(()) => {}
                Err(error) if error.kind() == smb2::ErrorKind::AlreadyExists => {
                    let info = self.client.stat(&mut self.tree, path).await?;
                    if !info.is_directory
                        || info
                            .attributes
                            .contains(smb2::types::flags::FileAttributes::REPARSE_POINT)
                    {
                        return Err(Error::Input(
                            "experiment root must be an ordinary directory",
                        ));
                    }
                }
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    }

    /// Removes exactly the configured run directory. The server rejects a
    /// nonempty directory; no children or reserved parent are ever removed.
    pub async fn cleanup_experiment(&mut self) -> Result<()> {
        let root = required_experiment_root(self.mutation_root.as_deref())?.to_owned();
        let info = self.client.stat(&mut self.tree, &root).await?;
        if !info.is_directory
            || info
                .attributes
                .contains(smb2::types::flags::FileAttributes::REPARSE_POINT)
        {
            return Err(Error::Input(
                "experiment root must be an ordinary directory",
            ));
        }
        // delete_directory uses a nonrecursive disposition operation. Emptiness
        // is checked by the server at deletion, not by a racy preceding listing.
        self.client.delete_directory(&self.tree, &root).await?;
        Ok(())
    }
    pub async fn rename(&mut self, from: &str, to: &str, replace: bool) -> Result<()> {
        let from = self.mutation_path(from)?;
        let to = self.mutation_path(to)?;
        Ok(self
            .client
            .rename_with(
                &self.tree,
                &from,
                &to,
                RenameOptions::new().replace_if_exists(replace),
            )
            .await?)
    }
    pub async fn delete(&mut self, relative: &str, directory: bool) -> Result<()> {
        let path = self.mutation_path(relative)?;
        if directory {
            self.client.delete_directory(&self.tree, &path).await?;
        } else {
            self.client.delete_file(&self.tree, &path).await?;
        }
        Ok(())
    }
    pub async fn disconnect(mut self) -> Result<()> {
        let result =
            tokio::time::timeout(CLEANUP_TIMEOUT, self.client.disconnect_share(&self.tree)).await;
        self.client.connection().mark_dead();
        result.map_err(|_| Error::Cleanup)?.map_err(Into::into)
    }

    fn mutation_path(&self, relative: &str) -> Result<String> {
        validate_path(relative, false)?;
        let root = self.mutation_root.as_ref().ok_or(Error::Input(
            "mutations require an explicit experiment root",
        ))?;
        Ok(format!("{root}/{relative}"))
    }
}

impl Drop for Nas {
    fn drop(&mut self) {
        self.client.connection().mark_dead();
    }
}

fn validate_root(root: &str) -> Result<()> {
    validate_path(root, false)?;
    if !root.starts_with(".mydrive-transport-tests/") || root.split('/').count() != 2 {
        return Err(Error::Input(
            "experiment root must be .mydrive-transport-tests/<run-name>",
        ));
    }
    Ok(())
}
fn required_experiment_root(root: Option<&str>) -> Result<&str> {
    let root = root.ok_or(Error::Input(
        "mutations require an explicit experiment root",
    ))?;
    validate_root(root)?;
    Ok(root)
}
fn validate_path(path: &str, allow_root: bool) -> Result<()> {
    if path.is_empty() {
        return if allow_root {
            Ok(())
        } else {
            Err(Error::Input("empty file path"))
        };
    }
    if path.len() > 4096
        || path.contains(['\\', ':', '\0'])
        || path.chars().any(char::is_control)
        || path
            .split('/')
            .any(|p| p.is_empty() || p == "." || p == ".." || p.ends_with([' ', '.']))
    {
        return Err(Error::Input(
            "use a relative, slash-separated path without traversal or ambiguous names",
        ));
    }
    Ok(())
}
fn range_end(size: u64, offset: u64, length: Option<u64>) -> Result<u64> {
    if offset > size {
        return Err(Error::Input("range offset exceeds file length"));
    }
    let end = match length {
        Some(length) => offset
            .checked_add(length)
            .ok_or(Error::Input("range overflow"))?
            .min(size),
        None => size,
    };
    Ok(end)
}
fn temporary_sibling(destination: &str) -> String {
    let (parent, _) = destination
        .rsplit_once('/')
        .expect("mutation root supplies a parent");
    let tick = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("{parent}/.upload-{}-{tick}.partial", std::process::id())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mutation_namespace_rejects_escape_and_scope_expansion() {
        for root in [
            "",
            "share",
            "../run",
            ".mydrive-transport-tests",
            ".mydrive-transport-tests/run/deeper",
        ] {
            assert!(validate_root(root).is_err());
        }
        assert!(validate_root(".mydrive-transport-tests/run-1").is_ok());
        for path in [
            "/etc",
            "../file",
            "x/../file",
            "x//file",
            "x\\file",
            "file:stream",
            "file.",
            "file\n",
        ] {
            assert!(validate_path(path, false).is_err(), "accepted {path:?}");
        }
    }
    #[test]
    fn ranges_are_checked_without_allocating_the_range() {
        assert_eq!(range_end(100, 90, Some(100)).unwrap(), 100);
        assert_eq!(range_end(0, 0, None).unwrap(), 0);
        assert!(range_end(100, 101, None).is_err());
        assert!(range_end(u64::MAX, 1, Some(u64::MAX)).is_err());
        assert_eq!(CHUNK_BYTES * READ_WINDOW, 2 * 1024 * 1024);
    }

    #[test]
    fn cleanup_requires_exact_reserved_run_directory() {
        assert!(required_experiment_root(None).is_err());
        for path in [
            ".mydrive-transport-tests",
            ".mydrive-transport-tests/",
            ".mydrive-transport-tests/run/child",
            ".mydrive-transport-tests/run/..",
            ".mydrive-transport-tests/../other",
            "/.mydrive-transport-tests/run",
        ] {
            assert!(required_experiment_root(Some(path)).is_err());
        }
        let root = ".mydrive-transport-tests/benchmark-1234";
        assert_eq!(required_experiment_root(Some(root)).unwrap(), root);
    }
}
