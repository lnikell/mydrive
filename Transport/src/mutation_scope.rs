//! Fixed-size object fences for one frozen recursive-delete selection. Exact
//! path bytes establish membership; held SMB identities establish authority.
use super::{request::parent_path, DirectoryIdentity};
use crate::{Error, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DeleteScope {
    pub root_path: String,
    pub root: DirectoryIdentity,
    pub parent: DirectoryIdentity,
}

impl DeleteScope {
    pub fn validate_path(&self, path: &str) -> Result<()> {
        crate::validate_path(&self.root_path, false)?;
        crate::validate_path(path, false)?;
        if !self.root.valid()
            || !self.parent.valid()
            || self.root_path.split('/').count() > 128
            || path.split('/').count() > 128
            || (path != self.root_path
                && !path
                    .strip_prefix(&self.root_path)
                    .is_some_and(|suffix| suffix.starts_with('/')))
        {
            return Err(Error::Input("invalid recursive deletion scope"));
        }
        Ok(())
    }

    pub(crate) fn snapshots(&self, skip_root: bool) -> Vec<(&str, DirectoryIdentity)> {
        let mut snapshots = vec![(parent_path(&self.root_path), self.parent)];
        if !skip_root {
            snapshots.push((self.root_path.as_str(), self.root));
        }
        snapshots
    }
}
