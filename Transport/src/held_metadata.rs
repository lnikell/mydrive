//! Complete borrowed metadata snapshots on an already owned file handle.
//! Capturing metadata creates no codec, mutation or metadata-fidelity capability.
use crate::{CancellationToken, Entry, Error, Result};
use smb2::{
    client::connection::Connection,
    msg::query_info::{InfoType, QueryInfoRequest},
    types::{status::NtStatus, Command, FileId, TreeId},
    Frame,
};

#[path = "held_metadata/policy.rs"]
mod policy;
#[path = "held_metadata/streams.rs"]
mod streams;
pub(crate) use policy::{sync_exclusion_allowed, Eligibility};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct StreamDescriptor {
    name_utf16: Vec<u16>,
    name: String,
    name_length_bytes: u32,
    logical_size: u64,
    allocation_size: u64,
}
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Snapshot {
    entry: Entry,
    links: u32,
    ea_size_bytes: u32,
    streams: Vec<StreamDescriptor>,
}
impl Snapshot {
    pub(crate) fn entry(&self) -> &Entry {
        &self.entry
    }
    pub(crate) fn qualify(&self, purpose: Eligibility) -> Result<()> {
        policy::qualify(self, purpose, sync_exclusion_allowed)
    }
}
pub(crate) struct View<'a> {
    connection: &'a Connection,
    tree: TreeId,
    file: FileId,
    cancel: &'a CancellationToken,
}
impl<'a> View<'a> {
    pub(crate) fn new(
        connection: &'a Connection,
        tree: TreeId,
        file: FileId,
        cancel: &'a CancellationToken,
    ) -> Self {
        Self {
            connection,
            tree,
            file,
            cancel,
        }
    }
    async fn query(&self, class: u8, limit: u32) -> Result<Vec<u8>> {
        let request = QueryInfoRequest {
            info_type: InfoType::File,
            file_info_class: class,
            output_buffer_length: limit,
            additional_information: 0,
            flags: 0,
            file_id: self.file,
            input_buffer: vec![],
        };
        let frame = tokio::select! {biased;
            _=self.cancel.cancelled()=>{self.connection.mark_dead();return Err(Error::Cancelled);},
            response=self.connection.execute(Command::QueryInfo,&request,Some(self.tree))=>response?,
        };
        success(&frame, Command::QueryInfo)?;
        query_buffer(&frame.body, limit)
    }
    pub(crate) async fn snapshot(&self, path: &str) -> Result<Snapshot> {
        let basic = self.query(4, 40).await?;
        let standard = self.query(5, 24).await?;
        let internal = self.query(6, 8).await?;
        let (entry, links) = parse_entry(path, &basic, &standard, &internal)?;
        let ea = self.query(7, 4).await?;
        if ea.len() != 4 {
            return Err(invalid());
        }
        let streams = streams::inventory(&self.query(22, 65536).await?, &entry)?;
        if self.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        Ok(Snapshot {
            entry,
            links,
            ea_size_bytes: u32_at(&ea, 0),
            streams,
        })
    }
}
fn parse_entry(path: &str, basic: &[u8], standard: &[u8], internal: &[u8]) -> Result<(Entry, u32)> {
    if basic.len() != 40 || standard.len() != 24 || internal.len() != 8 {
        return Err(invalid());
    }
    let attributes = u32_at(basic, 32);
    if attributes & 0x400 != 0 {
        return Err(unsupported());
    }
    if standard[20] > 1 || standard[21] > 1 {
        return Err(invalid());
    }
    if standard[20] != 0 || standard[21] != 0 || attributes & 16 != 0 {
        return Err(Error::Changed);
    }
    let bytes = u64_at(standard, 8);
    if bytes > i64::MAX as u64 {
        return Err(invalid());
    }
    let index = u64_at(internal, 0);
    let created = u64_at(basic, 0);
    if index == 0 || created == 0 {
        return Err(unsupported());
    }
    Ok((
        Entry {
            name: path.rsplit('/').next().unwrap_or(path).to_owned(),
            bytes,
            directory: false,
            index_number: Some(index),
            created_filetime: created,
            modified_filetime: u64_at(basic, 16),
            changed_filetime: u64_at(basic, 24),
            attributes,
        },
        u32_at(standard, 16),
    ))
}
fn success(frame: &Frame, command: Command) -> Result<()> {
    if frame.header.command != command {
        return Err(invalid());
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
fn query_buffer(body: &[u8], maximum: u32) -> Result<Vec<u8>> {
    if body.len() < 8 || u16::from_le_bytes([body[0], body[1]]) != 9 {
        return Err(invalid());
    }
    let offset = u16::from_le_bytes([body[2], body[3]]) as usize;
    let length = u32_at(body, 4) as usize;
    if length > maximum as usize {
        return Err(invalid());
    }
    if length == 0 && offset == 0 {
        return Ok(vec![]);
    }
    let start = offset
        .checked_sub(64)
        .filter(|x| *x >= 8)
        .ok_or_else(invalid)?;
    let end = start.checked_add(length).ok_or_else(invalid)?;
    Ok(body.get(start..end).ok_or_else(invalid)?.to_vec())
}
fn invalid() -> Error {
    Error::Smb(smb2::ErrorKind::InvalidData)
}
fn unsupported() -> Error {
    Error::Smb(smb2::ErrorKind::Unsupported)
}
fn u32_at(v: &[u8], i: usize) -> u32 {
    u32::from_le_bytes(v[i..i + 4].try_into().unwrap())
}
fn u64_at(v: &[u8], i: usize) -> u64 {
    u64::from_le_bytes(v[i..i + 8].try_into().unwrap())
}

#[cfg(test)]
#[path = "held_metadata/tests.rs"]
mod tests;
