//! One read-only SMB handle that denies SMB writers and deletion until close.
//!
//! smb2 0.31's high-level reader always shares writes. Keep the reservation,
//! bounded raw reads and same-handle observations together here; the crate still
//! owns framing, credits, signing, encryption and response validation.

use crate::{CancellationToken, Error, Result};
use smb2::{
    client::connection::Connection,
    msg::{
        close::{CloseRequest, CloseResponse},
        create::{
            CreateAction, CreateDisposition, CreateRequest, CreateResponse, ImpersonationLevel,
            ShareAccess,
        },
        read::{ReadRequest, SMB2_CHANNEL_NONE},
    },
    pack::{Pack, ReadCursor, Unpack},
    types::{flags::FileAccessMask, status::NtStatus, Command, FileId, OplockLevel, TreeId},
    Frame, Tree,
};

// One credit per wire request also works with servers granting only one credit.
// Eight range futures can run concurrently; each range is at most CHUNK_BYTES.
const WIRE_READ_BYTES: u32 = 64 * 1024;

pub(crate) struct GuardedRead {
    connection: Connection,
    tree: TreeId,
    file: FileId,
    max_read: u32,
    closed: bool,
    cancel: CancellationToken,
    ancestors: Option<crate::mutation_io::MutationIO>,
    path: String,
}

impl GuardedRead {
    pub async fn open(
        connection: Connection,
        tree: &Tree,
        path: &str,
        cancel: &CancellationToken,
    ) -> Result<Self> {
        // A dropped first CREATE has no recoverable file ID. Own its connection
        // before any ancestor/leaf await; disarm only after the reader owns it.
        let mut lifetime = OpenLifetime(Some(connection.clone()));
        // DFS is disabled on this experiment's client. Do not silently use a
        // raw relative path on a DFS tree or introduce an unpinned reconnect.
        if tree.is_dfs {
            return Err(Error::Input("guarded reads require a direct non-DFS share"));
        }
        let ancestors =
            crate::mutation_io::MutationIO::for_read(connection.clone(), tree, path, cancel)
                .await?;
        let request = read_request(path, read_access());
        let frame = tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                connection.mark_dead();
                return Err(Error::Cancelled);
            }
            frame = connection.execute(Command::Create, &request, Some(tree.tree_id)) => frame?,
        };
        require_success(&frame, Command::Create)?;
        // A malformed successful CREATE may still have opened a server handle.
        // Tear down the session when its returned handle cannot be recovered.
        let opened =
            CreateResponse::unpack(&mut ReadCursor::new(&frame.body)).map_err(|error| {
                connection.mark_dead();
                Error::from(error)
            })?;
        let max_read = connection
            .params()
            .map_or(WIRE_READ_BYTES, |params| params.max_read_size)
            .min(WIRE_READ_BYTES);
        let reader = Self {
            connection,
            tree: tree.tree_id,
            file: opened.file_id,
            max_read,
            closed: false,
            cancel: cancel.clone(),
            ancestors: Some(ancestors),
            path: path.to_owned(),
        };
        if opened.create_action != CreateAction::FileOpened {
            return Err(Error::Smb(smb2::ErrorKind::InvalidData));
        }
        lifetime.0 = None;
        Ok(reader)
    }

    pub(crate) async fn snapshot(&self) -> Result<crate::held_metadata::Snapshot> {
        crate::held_metadata::View::new(&self.connection, self.tree, self.file, &self.cancel)
            .snapshot(&self.path)
            .await
    }
    pub(crate) fn invalidate(&self) {
        self.connection.mark_dead();
    }

    pub async fn read_at(&self, offset: u64, length: u64) -> Result<Vec<u8>> {
        if length > crate::CHUNK_BYTES as u64 || self.max_read == 0 {
            return Err(Error::Input("invalid bounded read size"));
        }
        let mut bytes = Vec::with_capacity(length as usize);
        while (bytes.len() as u64) < length {
            let count = (length - bytes.len() as u64).min(u64::from(self.max_read)) as u32;
            let request = ReadRequest {
                padding: 0x50,
                flags: 0,
                length: count,
                offset: offset + bytes.len() as u64,
                file_id: self.file,
                minimum_count: 0,
                channel: SMB2_CHANNEL_NONE,
                remaining_bytes: 0,
                read_channel_info: vec![],
            };
            let frame = self.execute(Command::Read, &request).await?;
            bytes.extend_from_slice(&exact_read_data(&frame.body, count)?);
        }
        Ok(bytes)
    }

    async fn execute(&self, command: Command, request: &dyn Pack) -> Result<Frame> {
        let frame = tokio::select! {
            biased;
            _ = self.cancel.cancelled() => {
                self.connection.mark_dead();
                return Err(Error::Cancelled);
            }
            frame = self.connection.execute(command, request, Some(self.tree)) => frame?,
        };
        require_success(&frame, command)?;
        Ok(frame)
    }

    async fn close_leaf(&mut self) -> smb2::Result<()> {
        let request = CloseRequest {
            flags: 0,
            file_id: self.file,
        };
        let frame = self
            .connection
            .execute(Command::Close, &request, Some(self.tree))
            .await?;
        if frame.header.command != Command::Close {
            return Err(smb2::Error::invalid_data(
                "unexpected checked close command",
            ));
        }
        if frame.header.status != NtStatus::SUCCESS {
            return Err(smb2::Error::Protocol {
                status: frame.header.status,
                command: Command::Close,
            });
        }
        CloseResponse::unpack(&mut ReadCursor::new(&frame.body))?;
        self.closed = true;
        Ok(())
    }

    pub(crate) async fn close_checked(mut self) -> Result<()> {
        let leaf = tokio::time::timeout(crate::CLEANUP_TIMEOUT, self.close_leaf())
            .await
            .map_err(|_| Error::Cleanup)
            .and_then(|r| r.map_err(Error::from));
        let parents = if let Some(ancestors) = self.ancestors.take() {
            ancestors.close_checked().await
        } else {
            Ok(())
        };
        if leaf.is_err() || parents.is_err() {
            self.connection.mark_dead();
        }
        leaf?;
        parents?;
        if self.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        Ok(())
    }
}

impl Drop for GuardedRead {
    fn drop(&mut self) {
        // This also covers dropped operation futures, failed CLOSE and timeout.
        // Never retain a reservation in a reusable session after losing its owner.
        if !self.closed {
            self.connection.mark_dead();
        }
    }
}

pub(crate) struct OpenLifetime(pub(crate) Option<Connection>);
impl Drop for OpenLifetime {
    fn drop(&mut self) {
        if let Some(connection) = &self.0 {
            connection.mark_dead();
        }
    }
}
fn read_access() -> u32 {
    FileAccessMask::FILE_READ_DATA
        | FileAccessMask::FILE_READ_ATTRIBUTES
        | FileAccessMask::FILE_READ_EA
        | FileAccessMask::SYNCHRONIZE
}
fn read_request(path: &str, access: u32) -> CreateRequest {
    CreateRequest {
        requested_oplock_level: OplockLevel::None,
        impersonation_level: ImpersonationLevel::Impersonation,
        desired_access: FileAccessMask::new(access),
        file_attributes: 0,
        share_access: ShareAccess(ShareAccess::FILE_SHARE_READ),
        create_disposition: CreateDisposition::FileOpen,
        create_options: 0x0020_0040, // FILE_OPEN_REPARSE_POINT | FILE_NON_DIRECTORY_FILE
        name: smb2::encode_path(path),
        create_contexts: vec![],
    }
}

fn require_success(frame: &Frame, command: Command) -> Result<()> {
    if frame.header.command != command {
        return Err(Error::Smb(smb2::ErrorKind::InvalidData));
    }
    if frame.header.status == NtStatus(0xC000_0003) {
        return Err(Error::Smb(smb2::ErrorKind::Unsupported));
    }
    if frame.header.status != NtStatus::SUCCESS {
        return Err(smb2::Error::Protocol {
            status: frame.header.status,
            command,
        }
        .into());
    }
    Ok(())
}

fn exact_read_data(body: &[u8], expected: u32) -> Result<Vec<u8>> {
    if body.len() < 16 || u16::from_le_bytes([body[0], body[1]]) != 17 {
        return Err(Error::Smb(smb2::ErrorKind::InvalidData));
    }
    let length = u32::from_le_bytes(body[4..8].try_into().unwrap());
    if length < expected {
        return Err(Error::Changed);
    }
    if length > expected {
        return Err(Error::Smb(smb2::ErrorKind::InvalidData));
    }
    let start = (body[2] as usize)
        .checked_sub(64)
        .filter(|s| *s >= 16)
        .ok_or(Error::Smb(smb2::ErrorKind::InvalidData))?;
    let end = start
        .checked_add(length as usize)
        .ok_or(Error::Smb(smb2::ErrorKind::InvalidData))?;
    Ok(body
        .get(start..end)
        .ok_or(Error::Smb(smb2::ErrorKind::InvalidData))?
        .to_vec())
}

#[cfg(test)]
#[path = "guarded_read_wire_tests.rs"]
mod tests;
