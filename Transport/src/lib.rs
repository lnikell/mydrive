//! A disposable SMB experiment, not a synchronization engine.
//!
//! The module owns signing checks, bounded I/O, handle cleanup and a lexical
//! mutation guard. The NAS account's ACL remains the containment control.
//! Cancellation invalidates the session; construct a new session afterward.

use futures_util::{stream::FuturesOrdered, StreamExt};
use serde::Serialize;
use smb2::{ClientConfig, ListOptions, RenameOptions, SmbClient, Tree};
use std::{path::Path, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
pub use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

mod connection_readiness;
mod guarded_read;

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

#[derive(Debug, Serialize)]
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
        mut page: impl FnMut(Vec<Entry>) -> Result<()>,
    ) -> Result<(usize, bool)> {
        validate_path(path, true)?;
        let mut reader = tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                self.client.connection().mark_dead();
                return Err(Error::Cancelled);
            }
            reader = self.client.open_directory_reader_with(
                &mut self.tree,
                path,
                ListOptions::new().index_numbers(true),
            ) => reader?,
        };
        let outcome = async {
            let mut count = 0;
            let mut pages = 0;
            loop {
                let batch = tokio::select! {
                    biased;
                    _ = cancel.cancelled() => return Err(Error::Cancelled),
                    result = reader.next_batch() => result?,
                };
                let Some(batch) = batch else {
                    return Ok((count, true));
                };
                let entries: Vec<_> = batch
                    .into_iter()
                    .filter(|e| e.name != "." && e.name != "..")
                    .map(|e| Entry {
                        name: e.name,
                        bytes: e.size,
                        directory: e.is_directory,
                        index_number: e.index_number,
                        created_filetime: e.created.0,
                        modified_filetime: e.modified.0,
                        changed_filetime: e.changed.0,
                        attributes: e.attributes.bits(),
                    })
                    .collect();
                count += entries.len();
                page(entries)?;
                pages += 1;
                if page_limit.is_some_and(|limit| pages >= limit) {
                    return Ok((count, false));
                }
            }
        }
        .await;
        if matches!(outcome, Err(Error::Cancelled)) {
            self.client.connection().mark_dead();
        }
        let cleanup = tokio::time::timeout(CLEANUP_TIMEOUT, reader.close()).await;
        self.finish_cleanup(outcome, cleanup)
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
        validate_path(remote, false)?;
        let mut output = tokio::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(local)
            .await?;
        let result = self
            .download_to(remote, &mut output, offset, length, cancel, &mut progress)
            .await;
        drop(output);
        if result.is_err() {
            let _ = tokio::fs::remove_file(local).await;
        }
        result
    }

    async fn download_to(
        &mut self,
        remote: &str,
        output: &mut tokio::fs::File,
        offset: u64,
        length: Option<u64>,
        cancel: &CancellationToken,
        progress: &mut impl FnMut(u64),
    ) -> Result<Download> {
        let reader = guarded_read::GuardedRead::open(
            self.client.connection().clone(),
            &self.tree,
            remote,
            cancel,
        )
        .await?;
        let outcome = async {
            let observed = reader.observe().await?;
            let end = range_end(observed.size, offset, length)?;
            let mut next = offset;
            let mut completed = 0;
            let mut pending = FuturesOrdered::new();
            loop {
                while next < end && pending.len() < READ_WINDOW {
                    let size = (end - next).min(CHUNK_BYTES as u64);
                    pending.push_back(reader.read_at(next, size));
                    next += size;
                }
                let batch = tokio::select! {
                    biased;
                    _ = cancel.cancelled() => return Err(Error::Cancelled),
                    batch = pending.next() => batch,
                };
                let Some(bytes) = batch else {
                    break;
                };
                let bytes = bytes?;
                if bytes.is_empty() {
                    return Err(Error::Changed);
                }
                output.write_all(&bytes).await?;
                completed += bytes.len() as u64;
                progress(completed);
            }
            if completed != end - offset {
                return Err(Error::Changed);
            }
            if reader.observe().await? != observed {
                return Err(Error::Changed);
            }
            output.sync_all().await?;
            Ok(Download {
                bytes: completed,
                entry: observed.entry(remote),
            })
        }
        .await;
        if matches!(outcome, Err(Error::Cancelled)) {
            self.client.connection().mark_dead();
        }
        let cleanup = tokio::time::timeout(CLEANUP_TIMEOUT, reader.close()).await;
        self.finish_cleanup(outcome, cleanup)
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
    fn finish_cleanup<T>(
        &self,
        outcome: Result<T>,
        cleanup: std::result::Result<smb2::Result<()>, tokio::time::error::Elapsed>,
    ) -> Result<T> {
        match cleanup {
            Ok(Ok(())) => outcome,
            Ok(Err(error)) => {
                self.client.connection().mark_dead();
                outcome.and(Err(error.into()))
            }
            Err(_) => {
                self.client.connection().mark_dead();
                outcome.and(Err(Error::Cleanup))
            }
        }
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
