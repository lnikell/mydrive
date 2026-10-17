//! One read-only SMB handle that denies SMB writers and deletion until close.
//!
//! smb2 0.31's high-level reader always shares writes. Keep the reservation,
//! bounded raw reads and same-handle observations together here; the crate still
//! owns framing, credits, signing, encryption and response validation.

use crate::{CancellationToken, Entry, Error, Result};
use smb2::{
    client::connection::Connection,
    msg::{
        close::CloseRequest,
        create::{
            CreateDisposition, CreateRequest, CreateResponse, ImpersonationLevel, ShareAccess,
        },
        query_info::{InfoType, QueryInfoRequest, QueryInfoResponse},
        read::{ReadRequest, ReadResponse, SMB2_CHANNEL_NONE},
    },
    pack::{Pack, ReadCursor, Unpack},
    types::{flags::FileAccessMask, status::NtStatus, Command, FileId, OplockLevel, TreeId},
    Frame, Tree,
};

// One credit per wire request also works with servers granting only one credit.
// Eight range futures can run concurrently; each range is at most CHUNK_BYTES.
const WIRE_READ_BYTES: u32 = 64 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Observation {
    pub size: u64,
    created: u64,
    modified: u64,
    changed: u64,
    attributes: u32,
    index: u64,
}

impl Observation {
    pub fn entry(&self, path: &str) -> Entry {
        Entry {
            name: path.rsplit('/').next().unwrap_or(path).to_owned(),
            bytes: self.size,
            directory: false,
            index_number: Some(self.index),
            created_filetime: self.created,
            modified_filetime: self.modified,
            changed_filetime: self.changed,
            attributes: self.attributes,
        }
    }
}

pub(crate) struct GuardedRead {
    connection: Connection,
    tree: TreeId,
    file: FileId,
    max_read: u32,
    closed: bool,
    cancel: CancellationToken,
}

impl GuardedRead {
    pub async fn open(
        connection: Connection,
        tree: &Tree,
        path: &str,
        cancel: &CancellationToken,
    ) -> Result<Self> {
        // DFS is disabled on this experiment's client. Do not silently use a
        // raw relative path on a DFS tree or introduce an unpinned reconnect.
        if tree.is_dfs {
            return Err(Error::Input("guarded reads require a direct non-DFS share"));
        }
        let request = CreateRequest {
            requested_oplock_level: OplockLevel::None,
            impersonation_level: ImpersonationLevel::Impersonation,
            desired_access: FileAccessMask::new(
                FileAccessMask::FILE_READ_DATA
                    | FileAccessMask::FILE_READ_ATTRIBUTES
                    | FileAccessMask::SYNCHRONIZE,
            ),
            file_attributes: 0,
            share_access: ShareAccess(ShareAccess::FILE_SHARE_READ),
            create_disposition: CreateDisposition::FileOpen,
            create_options: 0x0000_0040, // FILE_NON_DIRECTORY_FILE
            name: smb2::encode_path(path),
            create_contexts: vec![],
        };
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
        Ok(Self {
            connection,
            tree: tree.tree_id,
            file: opened.file_id,
            max_read,
            closed: false,
            cancel: cancel.clone(),
        })
    }

    pub async fn observe(&self) -> Result<Observation> {
        // FileBasicInformation, FileStandardInformation, FileInternalInformation.
        // Fail closed if the server cannot provide these observations.
        let basic = self.query(4, 40).await?;
        let standard = self.query(5, 24).await?;
        let internal = self.query(6, 8).await?;
        observation(&basic, &standard, &internal)
    }

    async fn query(&self, class: u8, length: u32) -> Result<Vec<u8>> {
        let request = QueryInfoRequest {
            info_type: InfoType::File,
            file_info_class: class,
            output_buffer_length: length,
            additional_information: 0,
            flags: 0,
            file_id: self.file,
            input_buffer: vec![],
        };
        let frame = self.execute(Command::QueryInfo, &request).await?;
        Ok(QueryInfoResponse::unpack(&mut ReadCursor::new(&frame.body))?.output_buffer)
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
            let response = ReadResponse::unpack(&mut ReadCursor::new(&frame.body))?;
            // A hydration of an observed range must return exactly that range.
            // Short reads, including a concurrent truncation, fail the transfer.
            if response.data.len() != count as usize {
                return Err(Error::Changed);
            }
            bytes.extend_from_slice(&response.data);
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

    pub async fn close(mut self) -> smb2::Result<()> {
        let request = CloseRequest {
            flags: 0,
            file_id: self.file,
        };
        let frame = self
            .connection
            .execute(Command::Close, &request, Some(self.tree))
            .await?;
        if frame.header.status != NtStatus::SUCCESS {
            return Err(smb2::Error::Protocol {
                status: frame.header.status,
                command: Command::Close,
            });
        }
        self.closed = true;
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

fn require_success(frame: &Frame, command: Command) -> Result<()> {
    if frame.header.status != NtStatus::SUCCESS {
        return Err(smb2::Error::Protocol {
            status: frame.header.status,
            command,
        }
        .into());
    }
    Ok(())
}

fn observation(basic: &[u8], standard: &[u8], internal: &[u8]) -> Result<Observation> {
    if basic.len() < 40 || standard.len() < 24 || internal.len() < 8 {
        return Err(Error::Smb(smb2::ErrorKind::InvalidData));
    }
    let mut basic = ReadCursor::new(basic);
    let created = basic.read_u64_le()?;
    basic.read_u64_le()?; // Access time may change because of this read itself.
    let modified = basic.read_u64_le()?;
    let changed = basic.read_u64_le()?;
    let attributes = basic.read_u32_le()?;
    let mut standard = ReadCursor::new(standard);
    standard.read_u64_le()?; // Allocation size is not content length.
    let size = standard.read_u64_le()?;
    standard.read_u32_le()?; // Number of links.
    let delete_pending = standard.read_u8()?;
    let directory = standard.read_u8()?;
    if delete_pending != 0 || directory != 0 || attributes & 0x10 != 0 {
        return Err(Error::Changed);
    }
    Ok(Observation {
        size,
        created,
        modified,
        changed,
        attributes,
        index: ReadCursor::new(internal).read_u64_le()?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_rejects_truncation_directory_and_delete_pending() {
        let basic = [0; 40];
        let mut standard = [0; 24];
        let internal = [0; 8];
        assert!(observation(&basic[..39], &standard, &internal).is_err());
        assert!(observation(&basic, &standard[..23], &internal).is_err());
        standard[20] = 1;
        assert!(observation(&basic, &standard, &internal).is_err());
        standard[20] = 0;
        standard[21] = 1;
        assert!(observation(&basic, &standard, &internal).is_err());
    }

    #[test]
    fn access_time_is_excluded_but_size_and_change_time_are_observed() {
        let mut basic = [0; 40];
        let mut standard = [0; 24];
        let internal = [0; 8];
        let initial = observation(&basic, &standard, &internal).unwrap();
        basic[8] = 1;
        assert_eq!(observation(&basic, &standard, &internal).unwrap(), initial);
        basic[24] = 1;
        assert_ne!(observation(&basic, &standard, &internal).unwrap(), initial);
        basic[24] = 0;
        standard[8] = 1;
        assert_ne!(observation(&basic, &standard, &internal).unwrap(), initial);
    }
}
