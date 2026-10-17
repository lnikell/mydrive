//! SMB reservations, metadata, streaming and SET_INFO stay in one owner. All
//! rename requests prohibit replacement; no path-based check can authorize an
//! overwrite. Ancestor reservations prohibit SMB rename/reparse substitution.
use crate::content_metadata::require_plain_streams as plain_streams;
use crate::{
    mutation::{self, MutationRequest, Remote, VerifiedPayload},
    CancellationToken, Entry, Error, Result,
};
use smb2::{
    client::connection::Connection,
    msg::{
        close::CloseRequest,
        create::{
            CreateDisposition, CreateRequest, CreateResponse, ImpersonationLevel, ShareAccess,
        },
        flush::FlushRequest,
        query_info::{InfoType, QueryInfoRequest, QueryInfoResponse},
        read::{ReadRequest, ReadResponse},
        set_info::SetInfoRequest,
        write::{WriteRequest, WriteResponse},
    },
    pack::{Pack, ReadCursor, Unpack},
    types::{flags::FileAccessMask, status::NtStatus, Command, FileId, OplockLevel, TreeId},
    Frame, Tree,
};

const REPARSE: u32 = 0x400;
const DIRECTORY: u32 = 0x10;
const BASIC_ATTRIBUTES: u32 = 1 | 2 | 4 | 32 | 128 | 256 | 4096 | 8192;

#[path = "mutation_names.rs"]
mod names;

#[path = "mutation_allocation.rs"]
mod allocation;
#[path = "mutation_handle.rs"]
mod handle;
#[cfg(test)]
use handle::rename_buffer;
use handle::{Handle, Open};

#[path = "directory_listing.rs"]
pub(crate) mod listing;

pub(crate) struct MutationIO {
    connection: Connection,
    tree: TreeId,
    cancel: CancellationToken,
    parents: Vec<Handle>,
}

impl MutationIO {
    pub async fn new(
        connection: Connection,
        tree: &Tree,
        paths: &[&str],
        cancel: &CancellationToken,
    ) -> Result<Self> {
        Self::ancestors(connection, tree, paths, &[], &[], cancel, Open::Parent).await
    }

    pub async fn for_mutation(
        connection: Connection,
        tree: &Tree,
        request: &MutationRequest,
        cancel: &CancellationToken,
    ) -> Result<Self> {
        let mut paths = vec![request.path.as_str()];
        if let Some(destination) = &request.destination {
            paths.push(destination);
        }
        // A second deny-delete open on the selected root would forbid our own
        // root deletion. Its exact expected target is guarded by remove().
        let scope = request.scope_snapshots();
        Self::ancestors(
            connection,
            tree,
            &paths,
            &request.parent_snapshots(),
            &scope,
            cancel,
            Open::Parent,
        )
        .await
    }

    pub async fn for_read(
        connection: Connection,
        tree: &Tree,
        path: &str,
        cancel: &CancellationToken,
    ) -> Result<Self> {
        Self::for_scoped_read(connection, tree, path, None, cancel).await
    }

    pub async fn for_scoped_read(
        connection: Connection,
        tree: &Tree,
        path: &str,
        scope: Option<&mutation::DeleteScope>,
        cancel: &CancellationToken,
    ) -> Result<Self> {
        let snapshots = if let Some(scope) = scope {
            scope.validate_path(path)?;
            scope.snapshots(false)
        } else {
            Vec::new()
        };
        Self::ancestors(
            connection,
            tree,
            &[path],
            &[],
            &snapshots,
            cancel,
            Open::ReadParent,
        )
        .await
    }

    pub async fn for_scoped_stat(
        connection: Connection,
        tree: &Tree,
        path: &str,
        scope: &mutation::DeleteScope,
        cancel: &CancellationToken,
    ) -> Result<Self> {
        scope.validate_path(path)?;
        // A deleted selection cannot supply a root handle. Only exact-root
        // stat can establish its absence under the unchanged parent instead.
        let snapshots = scope.snapshots(path == scope.root_path);
        Self::ancestors(
            connection,
            tree,
            &[path],
            &[],
            &snapshots,
            cancel,
            Open::ReadParent,
        )
        .await
    }

    pub async fn stat_in_scope(
        &mut self,
        path: &str,
        scope: &mutation::DeleteScope,
    ) -> Result<Option<Entry>> {
        if path != scope.root_path {
            return self.stat(path).await;
        }
        let handle = match self.open(path, Open::ReadParent).await {
            Ok(handle) => handle,
            Err(Error::Smb(smb2::ErrorKind::NotFound)) => return Ok(None),
            Err(Error::Smb(smb2::ErrorKind::NotADirectory | smb2::ErrorKind::Unsupported)) => {
                return Err(Error::ScopeChanged);
            }
            Err(error) => return Err(error),
        };
        let result = handle.observe(path).await.and_then(|entry| {
            if scope.root.matches(&entry) {
                Ok(Some(entry))
            } else {
                Err(Error::ScopeChanged)
            }
        });
        let closed = handle.close().await;
        result.and_then(|entry| closed.map(|()| entry))
    }

    async fn ancestors(
        connection: Connection,
        tree: &Tree,
        paths: &[&str],
        expected: &[(&str, mutation::DirectoryIdentity)],
        scope: &[(&str, mutation::DirectoryIdentity)],
        cancel: &CancellationToken,
        mode: Open,
    ) -> Result<Self> {
        if tree.is_dfs {
            return Err(Error::Input("mutations require a direct non-DFS share"));
        }
        let mut owner = Self {
            connection,
            tree: tree.tree_id,
            cancel: cancel.clone(),
            parents: Vec::new(),
        };
        let result = owner.reserve_ancestors(paths, expected, scope, mode).await;
        if let Err(error) = result {
            owner.close().await;
            return Err(error);
        }
        Ok(owner)
    }

    async fn reserve_ancestors(
        &mut self,
        paths: &[&str],
        expected: &[(&str, mutation::DirectoryIdentity)],
        scope: &[(&str, mutation::DirectoryIdentity)],
        mode: Open,
    ) -> Result<()> {
        let mut ancestors = std::collections::BTreeSet::new();
        for path in paths {
            let components: Vec<_> = path.split('/').collect();
            if components.len() > 128 {
                return Err(Error::Input("path exceeds the supported depth"));
            }
            for end in 1..components.len() {
                ancestors.insert(components[..end].join("/"));
            }
        }
        // Include the actual share-root handle when it is an immediate parent.
        // Never substitute a synthetic Catalog root identifier for SMB identity.
        ancestors.extend(expected.iter().map(|(path, _)| (*path).to_owned()));
        ancestors.extend(scope.iter().map(|(path, _)| (*path).to_owned()));
        for path in ancestors {
            // Child activity is allowed. Reparse conversion or moving either
            // selected directory object while this operation runs is not.
            let open_mode = if scope.iter().any(|(required, _)| *required == path) {
                Open::ReadParent
            } else {
                mode
            };
            let handle = match self.open(&path, open_mode).await {
                Err(Error::Smb(
                    smb2::ErrorKind::NotFound
                    | smb2::ErrorKind::NotADirectory
                    | smb2::ErrorKind::Unsupported,
                )) if !scope.is_empty() => return Err(Error::ScopeChanged),
                Err(Error::Smb(smb2::ErrorKind::NotFound | smb2::ErrorKind::NotADirectory))
                    if !expected.is_empty() =>
                {
                    return Err(Error::Changed)
                }
                result => result?,
            };
            self.parents.push(handle);
            if !matches!(mode, Open::ReadParent) || !scope.is_empty() {
                let entry = match self.parents.last().unwrap().observe(&path).await {
                    Err(Error::Smb(smb2::ErrorKind::Unsupported)) if !scope.is_empty() => {
                        return Err(Error::ScopeChanged);
                    }
                    result => result?,
                };
                if scope
                    .iter()
                    .any(|(required, identity)| *required == path && !identity.matches(&entry))
                {
                    return Err(Error::ScopeChanged);
                }
                if !entry.directory {
                    return Err(if expected.is_empty() {
                        Error::Smb(smb2::ErrorKind::NotADirectory)
                    } else {
                        Error::Changed
                    });
                }
                if expected
                    .iter()
                    .any(|(required, identity)| *required == path && !identity.matches(&entry))
                {
                    return Err(Error::Changed);
                }
            }
        }
        Ok(())
    }

    async fn open(&self, path: &str, mode: Open) -> Result<Handle> {
        Handle::open(self.connection.clone(), self.tree, path, mode, &self.cancel).await
    }

    pub async fn close(self) {
        // A failure invalidates the session. It cannot undo a verified commit.
        let _ = self.close_checked().await;
    }

    pub async fn close_checked(mut self) -> Result<()> {
        let mut failure = None;
        for parent in self.parents.drain(..).rev() {
            let result = tokio::time::timeout(crate::CLEANUP_TIMEOUT, parent.close())
                .await
                .unwrap_or(Err(Error::Cleanup));
            if let Err(error) = result {
                failure.get_or_insert(error);
            }
        }
        failure.map_or(Ok(()), Err)
    }
}

#[cfg(test)]
#[path = "mutation_parent_tests.rs"]
mod parent_tests;

#[cfg(test)]
#[path = "mutation_scope_tests.rs"]
mod scope_tests;

impl Remote for MutationIO {
    async fn canonical_name(&mut self, path: &str, expected: &Entry) -> Result<String> {
        let handle = self.open(path, Open::Guarded).await?;
        let result = async {
            let observed = handle.observe(path).await?;
            if !mutation::same_version(expected, &observed) {
                return Err(Error::Changed);
            }
            handle.ensure_plain(&observed).await?;
            handle.canonical_name(path, &observed).await
        }
        .await;
        let closed = handle.close().await;
        result.and_then(|value| closed.map(|()| value))
    }

    async fn move_item(
        &mut self,
        path: &str,
        expected: &Entry,
        destination: &str,
    ) -> Result<Entry> {
        let handle = self.open(path, Open::Guarded).await?;
        let result = async {
            let mut entry = handle.rename(path, expected, destination, None).await?;
            let name = handle.canonical_name(destination, &entry).await?;
            if name.as_bytes() != destination.rsplit('/').next().unwrap().as_bytes() {
                return Err(Error::CommitUncertain);
            }
            entry.name = name;
            Ok(entry)
        }
        .await;
        let _ = handle.close().await;
        result
    }
    async fn stat(&mut self, path: &str) -> Result<Option<Entry>> {
        let handle = match self.open(path, Open::Inspect).await {
            Ok(handle) => handle,
            Err(Error::Smb(smb2::ErrorKind::NotFound)) => return Ok(None),
            Err(error) => return Err(error),
        };
        let result = handle.observe(path).await;
        handle.close().await?;
        result.map(Some)
    }

    async fn hash(&mut self, path: &str, expected: &Entry) -> Result<String> {
        let handle = self.open(path, Open::Guarded).await?;
        let result = async {
            let before = handle.observe(path).await?;
            if !mutation::same_version(expected, &before) {
                return Err(Error::Changed);
            }
            handle.ensure_plain(&before).await?;
            let hash = handle.hash(before.bytes).await?;
            if !mutation::same_version(&before, &handle.observe(path).await?) {
                return Err(Error::Changed);
            }
            Ok(hash)
        }
        .await;
        let closed = handle.close().await;
        result.and_then(|value| closed.map(|()| value))
    }

    async fn allocate(
        &mut self,
        request: &MutationRequest,
        path: &str,
    ) -> Result<mutation::Artifact> {
        self.allocate_stage(request, path).await
    }

    async fn stage(
        &mut self,
        request: &MutationRequest,
        path: &str,
        payload: Option<&mut VerifiedPayload>,
        progress: &mut dyn FnMut(u64),
    ) -> Result<Entry> {
        self.upload_allocated_stage(request, path, payload, progress)
            .await
    }

    async fn archive(
        &mut self,
        path: &str,
        expected: &Entry,
        destination: &str,
        staged: &mutation::Artifact,
    ) -> Result<Entry> {
        let original = self.open(path, Open::SecurityGuarded).await?;
        let stage = self.open(&staged.path, Open::SecurityGuarded).await?;
        let result = async {
            if !mutation::same_version(expected, &original.observe(path).await?)
                || !mutation::same_version(&staged.entry, &stage.observe(&staged.path).await?)
            {
                return Err(Error::Changed);
            }
            original
                .security()
                .await?
                .require_same(&stage.security().await?)?;
            if let Some(expected) = &staged.security_sha256 {
                if stage.security().await?.fingerprint() != *expected {
                    return Err(Error::Changed);
                }
            }
            original.rename(path, expected, destination, None).await
        }
        .await;
        let _ = stage.close().await;
        let _ = original.close().await;
        result
    }

    async fn publish(
        &mut self,
        staged: &mutation::Artifact,
        destination: &str,
        hash: Option<&str>,
        archived: Option<&mutation::Artifact>,
    ) -> Result<Entry> {
        let path = &staged.path;
        let expected = &staged.entry;
        let stage = self
            .open(
                path,
                if archived.is_some() || staged.security_sha256.is_some() {
                    Open::SecurityGuarded
                } else {
                    Open::Guarded
                },
            )
            .await?;
        let backup = if let Some(artifact) = archived {
            let handle = self.open(&artifact.path, Open::SecurityGuarded).await?;
            if !mutation::same_version(&artifact.entry, &handle.observe(&artifact.path).await?) {
                return Err(Error::Changed);
            }
            Some(handle)
        } else {
            None
        };
        let result = async {
            if let Some(expected) = &staged.security_sha256 {
                if stage.security().await?.fingerprint() != *expected {
                    return Err(Error::Changed);
                }
            }
            if let Some(backup) = &backup {
                backup
                    .security()
                    .await?
                    .require_same(&stage.security().await?)?;
            }
            stage.rename(path, expected, destination, hash).await
        }
        .await;
        let _ = stage.close().await;
        if let Some(backup) = backup {
            let _ = backup.close().await;
        }
        result
    }

    async fn rename(
        &mut self,
        path: &str,
        expected: &Entry,
        destination: &str,
        hash: Option<&str>,
    ) -> Result<Entry> {
        let handle = self.open(path, Open::Guarded).await?;
        let result = handle.rename(path, expected, destination, hash).await;
        let _ = handle.close().await;
        result
    }

    async fn remove(&mut self, path: &str, expected: &Entry) -> Result<()> {
        let handle = self.open(path, Open::Guarded).await?;
        let result = async {
            let before = handle.observe(path).await?;
            if !mutation::same_version(expected, &before) {
                return Err(Error::Changed);
            }
            handle.ensure_plain(&before).await?;
            handle.set(13, vec![1]).await
        }
        .await;
        // The server checks nonempty directories before marking deletion. A
        // confirmed CLOSE is needed before deletion is reported committed.
        let close = handle.close().await;
        result?;
        close
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rename_is_exclusive_and_preserves_wire_unicode() {
        let buffer = rename_buffer("a/cafe\u{301}.txt");
        assert_eq!(&buffer[..16], &[0; 16]);
        let name: Vec<_> = buffer[20..]
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .collect();
        assert_eq!(String::from_utf16(&name).unwrap(), "a\\cafe\u{301}.txt");
    }
    #[test]
    fn named_streams_and_malformed_lists_are_refused() {
        let stream = |name: &str| {
            let name: Vec<_> = name.encode_utf16().collect();
            let mut data = vec![0; 24];
            data[4..8].copy_from_slice(&(name.len() as u32 * 2).to_le_bytes());
            for c in name {
                data.extend_from_slice(&c.to_le_bytes());
            }
            data
        };
        assert!(plain_streams(&stream("::$DATA")).is_ok());
        assert!(plain_streams(&stream(":AFP_Resource:$DATA")).is_err());
        assert!(plain_streams(&[0; 23]).is_err());
    }
}

#[cfg(test)]
#[path = "mutation_wire_tests.rs"]
mod wire_tests;
