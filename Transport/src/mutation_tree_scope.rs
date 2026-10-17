//! Fixed-size fences for a private new-tree arena. These establish membership,
//! never ownership: the caller must retain each creator-confirmed receipt.
use super::{request::parent_path, DeleteScope, DirectoryIdentity, MutationKind, MutationRequest};
use crate::{Error, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TreeScope {
    /// Version 1 staged every node in an extra artifact arena. It must never
    /// be reinterpreted as correct-depth staging by a newer executable.
    pub layout_version: u8,
    pub arena_path: String,
    pub arena: DirectoryIdentity,
    pub parent: DirectoryIdentity,
}

impl TreeScope {
    pub fn validate_path(&self, path: &str) -> Result<()> {
        if self.layout_version != 2 {
            return Err(Error::Input("unsupported private tree layout"));
        }
        self.fence().validate_path(path)
    }

    pub fn validate_payload_path(&self, path: &str) -> Result<()> {
        self.validate_path(path)?;
        if path == self.arena_path {
            return Err(Error::Input("tree content read requires a descendant file"));
        }
        Ok(())
    }

    pub(crate) fn fence(&self) -> DeleteScope {
        DeleteScope {
            root_path: self.arena_path.clone(),
            root: self.arena,
            parent: self.parent,
        }
    }

    pub(crate) fn snapshots(&self, skip_arena: bool) -> Vec<(&str, DirectoryIdentity)> {
        let mut result = vec![(parent_path(&self.arena_path), self.parent)];
        if !skip_arena {
            result.push((self.arena_path.as_str(), self.arena));
        }
        result
    }

    fn scratch(&self, path: &str) -> bool {
        if path == self.arena_path {
            return false;
        }
        path.rsplit('/').next().is_some_and(|name| {
            name.strip_prefix(".mydrive-")
                .and_then(|name| name.strip_suffix(".node"))
                .is_some_and(super::request::canonical_uuid)
        })
    }

    pub(crate) fn validate_mutation(&self, request: &MutationRequest) -> Result<()> {
        self.validate_path(&request.path)?;
        let valid = match request.kind {
            MutationKind::CreateFile | MutationKind::CreateDirectory => self.scratch(&request.path),
            MutationKind::Move => {
                let destination = request.destination.as_deref().unwrap_or("");
                // A node is born in its final logical parent. Same-parent
                // placement keeps normal server inheritance at that depth;
                // only the complete staged root may leave the private tree.
                (self.scratch(&request.path)
                    && self.validate_path(destination).is_ok()
                    && parent_path(&request.path) == parent_path(destination))
                    || (request.path == self.arena_path
                        && parent_path(destination) == parent_path(&self.arena_path)
                        && destination != self.arena_path
                        && request.parent == self.parent
                        && request.destination_parent == Some(self.parent)
                        && request
                            .expected
                            .as_ref()
                            .is_some_and(|entry| self.arena.matches(entry)))
            }
            MutationKind::Delete | MutationKind::Cleanup => {
                (request.kind == MutationKind::Cleanup && request.path != self.arena_path)
                    || self.scratch(&request.path)
                    || (request.kind == MutationKind::Delete
                        && request.path == self.arena_path
                        && request
                            .expected
                            .as_ref()
                            .is_some_and(|entry| self.arena.matches(entry)))
            }
            MutationKind::ReplaceFile => false,
        };
        if !valid
            || self.snapshots(false).iter().any(|(path, identity)| {
                request
                    .parent_snapshots()
                    .iter()
                    .any(|(parent, expected)| path == parent && identity != expected)
            })
        {
            return Err(Error::Input(
                "mutation is outside its private new-tree scope",
            ));
        }
        Ok(())
    }
}
