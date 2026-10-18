//! One bounded streaming owner for strict verification and ordinary hydration.
//! The closed purpose is selected by named entrypoints, never by metadata names.
use crate::{
    guarded_read::GuardedRead, held_metadata::Eligibility, CancellationToken, Download, Error,
    Result, CHUNK_BYTES, READ_WINDOW,
};
use futures_util::{stream::FuturesOrdered, StreamExt};
use smb2::{client::connection::Connection, Tree};
use std::{
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
};
use tokio::io::AsyncWriteExt;

pub(crate) enum Purpose {
    Strict { offset: u64, length: Option<u64> },
    Hydration,
}
impl Purpose {
    fn eligibility(&self) -> Eligibility {
        match self {
            Self::Strict { .. } => Eligibility::StrictContent,
            Self::Hydration => Eligibility::SyncHydration,
        }
    }
    fn end(&self, size: u64) -> Result<(u64, u64)> {
        match self {
            Self::Strict { offset, length } => {
                Ok((*offset, crate::range_end(size, *offset, *length)?))
            }
            Self::Hydration => Ok((0, size)),
        }
    }
}

pub(crate) async fn run(
    connection: Connection,
    tree: &Tree,
    remote: &str,
    local: &Path,
    purpose: Purpose,
    cancel: &CancellationToken,
    mut progress: impl FnMut(u64),
) -> Result<StagedDownload> {
    crate::validate_path(remote, false)?;
    let mut output = OwnedOutput::create(local)?;
    let reader = GuardedRead::open(connection, tree, remote, cancel).await?;
    let mut in_flight_aborted = false;
    let result = async {
        let before = reader.snapshot().await?;
        before.qualify(purpose.eligibility())?;
        let (offset, end) = purpose.end(before.entry().bytes)?;
        let mut next = offset;
        let mut completed = 0;
        let mut pending = FuturesOrdered::new();
        let body = async {
            loop {
                while next < end && pending.len() < READ_WINDOW {
                    let size = (end - next).min(CHUNK_BYTES as u64);
                    pending.push_back(reader.read_at(next, size));
                    next += size;
                }
                let batch = tokio::select! {
                    biased;
                    _ = cancel.cancelled() => return Err(Error::Cancelled),
                    next = pending.next() => next,
                };
                let Some(bytes) = batch else { break };
                let bytes = bytes?;
                if bytes.is_empty() {
                    return Err(Error::Changed);
                }
                output.file.write_all(&bytes).await?;
                completed += bytes.len() as u64;
                progress(completed);
            }
            Ok(())
        }
        .await;
        if body.is_err() && !pending.is_empty() {
            // Dropped range futures may have outstanding SMB replies. Retire
            // this connection instead of reusing it or claiming checked CLOSE.
            in_flight_aborted = true;
            reader.invalidate();
            pending.clear();
        }
        body?;
        if completed != end - offset {
            return Err(Error::Changed);
        }
        let after = reader.snapshot().await?;
        after.qualify(purpose.eligibility())?;
        if before != after {
            return Err(Error::Changed);
        }
        output.file.sync_all().await?;
        output.verify(completed).await?;
        Ok(Download {
            bytes: completed,
            entry: before.entry().clone(),
        })
    }
    .await;
    if in_flight_aborted {
        return Err(result.err().unwrap_or(Error::Changed));
    }
    // Terminal failures override eligibility failures, but never hide a known
    // cancellation behind a close on the connection it intentionally retired.
    let closed = reader.close_checked().await;
    if matches!(result, Err(Error::Cancelled)) {
        return Err(Error::Cancelled);
    }
    closed?;
    let download = result?;
    Ok(StagedDownload { download, output })
}

/// Retains local pathname ownership through any caller-held remote fences.
/// A caller cannot obtain a completed Download without the last identity check.
pub(crate) struct StagedDownload {
    download: Download,
    output: OwnedOutput,
}
impl StagedDownload {
    pub(crate) async fn finish(mut self, cancel: &CancellationToken) -> Result<Download> {
        self.output.verify(self.download.bytes).await?;
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        self.output.complete = true;
        Ok(self.download)
    }
}

struct OwnedOutput {
    file: tokio::fs::File,
    path: PathBuf,
    id: (u64, u64),
    complete: bool,
}
impl OwnedOutput {
    fn create(path: &Path) -> Result<Self> {
        // Arm pathname ownership before the first await that can be dropped.
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?;
        let metadata = file.metadata()?;
        Ok(Self {
            file: tokio::fs::File::from_std(file),
            path: path.to_owned(),
            id: (metadata.dev(), metadata.ino()),
            complete: false,
        })
    }
    async fn verify(&self, expected: u64) -> Result<()> {
        let descriptor = self.file.metadata().await?;
        let path = tokio::fs::symlink_metadata(&self.path).await?;
        if !path.is_file()
            || path.file_type().is_symlink()
            || (path.dev(), path.ino()) != self.id
            || (descriptor.dev(), descriptor.ino()) != self.id
            || descriptor.len() != expected
            || path.len() != expected
        {
            return Err(Error::Io(std::io::ErrorKind::InvalidData));
        }
        Ok(())
    }
}
impl Drop for OwnedOutput {
    fn drop(&mut self) {
        if !self.complete {
            if let Ok(metadata) = std::fs::symlink_metadata(&self.path) {
                if metadata.is_file()
                    && !metadata.file_type().is_symlink()
                    && (metadata.dev(), metadata.ino()) == self.id
                {
                    let _ = std::fs::remove_file(&self.path);
                }
            }
        }
    }
}

#[cfg(test)]
#[path = "guarded_download_tests.rs"]
mod tests;
