//! Strict, nonsecret durable mutation wire intent and receipt schema.
use crate::{Entry, Error, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MutationKind {
    CreateFile,
    CreateDirectory,
    ReplaceFile,
    Move,
    Delete,
    Cleanup,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Payload {
    pub source: String,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Artifact {
    pub path: String,
    pub entry: Entry,
    /// Evidence authorizing automatic cleanup, not a claim of atomicity.
    #[serde(default)]
    pub cleanup_safe: bool,
    #[serde(default)]
    pub phase: StagePhase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub security_sha256: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StagePhase {
    Allocated,
    #[default]
    Prepared,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Receipt {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub staged: Option<Artifact>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archived: Option<Artifact>,
}

/// A directory object, independent of child-driven timestamps and DOS flags.
/// Paths come from the immutable request, so parent guards add fixed-size data.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DirectoryIdentity {
    pub index_number: u64,
    pub created_filetime: u64,
}

impl DirectoryIdentity {
    pub(crate) fn matches(self, entry: &Entry) -> bool {
        entry.directory
            && entry.attributes & 0x400 == 0
            && entry.index_number == Some(self.index_number)
            && entry.created_filetime == self.created_filetime
    }

    pub(crate) fn valid(self) -> bool {
        self.index_number != 0 && self.created_filetime != 0
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct MutationRequest {
    pub operation_id: String,
    pub kind: MutationKind,
    pub path: String,
    pub parent: DirectoryIdentity,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delete_scope: Option<super::DeleteScope>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tree_scope: Option<super::TreeScope>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub destination: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub destination_parent: Option<DirectoryIdentity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected: Option<Entry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<Payload>,
    #[serde(default)]
    pub receipt: Receipt,
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Committed,
    NotApplied,
    Conflict,
    Uncertain,
}

#[derive(Debug, Serialize)]
pub struct MutationResult {
    pub operation_id: String,
    pub outcome: Outcome,
    pub code: &'static str,
    pub entry: Option<Entry>,
    pub sha256: Option<String>,
    pub cleanup_pending: bool,
    #[serde(flatten)]
    pub receipt: Receipt,
}

impl MutationRequest {
    pub fn validate(&self) -> Result<()> {
        if self.delete_scope.is_some() && self.tree_scope.is_some() {
            return Err(Error::Input(
                "a mutation cannot combine tree and deletion scopes",
            ));
        }
        if !canonical_uuid(&self.operation_id) {
            return Err(Error::Input("invalid mutation operation ID"));
        }
        crate::validate_path(&self.path, false)?;
        if !self.parent.valid()
            || self.destination_parent.is_some() != (self.kind == MutationKind::Move)
            || self
                .destination_parent
                .is_some_and(|parent| !parent.valid())
        {
            return Err(Error::Input(
                "mutation requires its observed parent identity",
            ));
        }
        if self.path.split('/').count() > 128 {
            return Err(Error::Input("mutation path is too deep"));
        }
        let creates = matches!(
            self.kind,
            MutationKind::CreateFile | MutationKind::CreateDirectory
        );
        let uploads = matches!(
            self.kind,
            MutationKind::CreateFile | MutationKind::ReplaceFile
        );
        if (self.receipt.staged.is_some() && !creates && self.kind != MutationKind::ReplaceFile)
            || (self.receipt.archived.is_some()
                && !matches!(self.kind, MutationKind::ReplaceFile | MutationKind::Delete))
        {
            return Err(Error::Input("receipt fields do not match mutation kind"));
        }
        if self.expected.is_some() == creates
            || self.payload.is_some() != uploads
            || self.destination.is_some() != (self.kind == MutationKind::Move)
        {
            return Err(Error::Input("mutation fields do not match its kind"));
        }
        if let Some(destination) = &self.destination {
            crate::validate_path(destination, false)?;
            if destination == &self.path
                || destination.starts_with(&(self.path.clone() + "/"))
                || destination.split('/').count() > 128
            {
                return Err(Error::Input("invalid move destination"));
            }
            if parent_path(destination) == parent_path(&self.path)
                && self.destination_parent != Some(self.parent)
            {
                return Err(Error::Input(
                    "one parent has inconsistent observed identities",
                ));
            }
        }
        if let Some(expected) = &self.expected {
            if expected.index_number.is_none_or(|id| id == 0)
                || expected.created_filetime == 0
                || expected.attributes & 0x400 != 0
                || expected.directory != (expected.attributes & 0x10 != 0)
                || (self.kind == MutationKind::ReplaceFile && expected.directory)
            {
                return Err(Error::Input(
                    "mutation requires an ordinary item with a stable observed identity",
                ));
            }
        }
        if let Some(payload) = &self.payload {
            if !Path::new(&payload.source).is_absolute()
                || payload.source.contains('\0')
                || payload.bytes > i64::MAX as u64
                || payload.sha256.len() != 64
                || !payload
                    .sha256
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            {
                return Err(Error::Input("invalid staged payload description"));
            }
        }
        for (artifact, suffix) in [
            (&self.receipt.staged, "stage"),
            (
                &self.receipt.archived,
                if self.kind == MutationKind::Delete {
                    "deleted"
                } else {
                    "backup"
                },
            ),
        ] {
            if let Some(artifact) = artifact {
                if artifact.path != self.sidecar(suffix)
                    || artifact.entry.index_number.is_none_or(|id| id == 0)
                    || artifact.entry.created_filetime == 0
                    || artifact
                        .security_sha256
                        .as_ref()
                        .is_some_and(|hash| !valid_hash(hash))
                    || (artifact.phase == StagePhase::Allocated
                        && (suffix != "stage"
                            || !uploads
                            || artifact.entry.directory
                            || artifact.entry.bytes != 0
                            || !artifact.cleanup_safe
                            || artifact.security_sha256.is_none()))
                {
                    return Err(Error::Input("mutation receipt is outside its operation"));
                }
            }
        }
        if self.kind == MutationKind::Cleanup {
            let name = self.path.rsplit('/').next().unwrap_or_default();
            if !["stage", "backup", "deleted"]
                .iter()
                .any(|suffix| name == format!(".mydrive-{}.{}", self.operation_id, suffix))
                || self.receipt.staged.is_some()
                || self.receipt.archived.is_some()
            {
                return Err(Error::Input("cleanup requires an exact operation artifact"));
            }
        }
        if let Some(scope) = &self.delete_scope {
            scope.validate_path(&self.path)?;
            if !matches!(self.kind, MutationKind::Delete | MutationKind::Cleanup)
                || (self.path == scope.root_path
                    && self
                        .expected
                        .as_ref()
                        .is_none_or(|entry| !scope.root.matches(entry)))
                || scope.snapshots(false).iter().any(|(path, identity)| {
                    self.parent_snapshots()
                        .iter()
                        .any(|(parent, expected)| path == parent && identity != expected)
                })
            {
                return Err(Error::Input("mutation has inconsistent deletion fences"));
            }
        }
        if let Some(scope) = &self.tree_scope {
            scope.validate_mutation(self)?;
        }
        Ok(())
    }

    pub fn sidecar(&self, suffix: &str) -> String {
        let name = format!(".mydrive-{}.{}", self.operation_id, suffix);
        self.path
            .rsplit_once('/')
            .map_or(name.clone(), |(parent, _)| format!("{parent}/{name}"))
    }

    pub(crate) fn parent_snapshots(&self) -> Vec<(&str, DirectoryIdentity)> {
        let mut parents = vec![(parent_path(&self.path), self.parent)];
        if let (Some(path), Some(identity)) = (&self.destination, self.destination_parent) {
            parents.push((parent_path(path), identity));
        }
        parents
    }

    pub(crate) fn scope_snapshots(&self) -> Vec<(&str, DirectoryIdentity)> {
        if let Some(scope) = &self.tree_scope {
            // Only the exact root publication or empty-root deletion can
            // reach this path. validate() requires the full target identity;
            // move/remove holds that target without a conflicting self-open.
            return scope.snapshots(self.path == scope.arena_path);
        }
        self.delete_scope.as_ref().map_or_else(Vec::new, |scope| {
            // validate() requires the full target identity to match here.
            scope.snapshots(self.path == scope.root_path)
        })
    }
}

fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub(crate) fn parent_path(path: &str) -> &str {
    path.rsplit_once('/').map_or("", |(parent, _)| parent)
}

pub(crate) fn canonical_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
        && value.bytes().any(|byte| byte != b'0' && byte != b'-')
}
