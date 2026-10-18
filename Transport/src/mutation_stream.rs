//! Bounded same-handle byte pipelines. No verification pass is elided here.
use super::*;
use futures_util::{stream::FuturesUnordered, StreamExt};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use tokio::io::AsyncReadExt;

// One-credit requests work with small-credit servers too. At most 512 KiB of
// range payloads are retained (plus one local input buffer and SMB framing).
const WIRE_BYTES: usize = 64 * 1024;
const WINDOW: usize = 8;

/// Losing any pipeline future invalidates the whole session before its caller
/// can publish. No spawned transfer task or reusable orphan request survives.
struct PipelineLifetime<'a> {
    connection: &'a Connection,
    completed: bool,
}
impl Drop for PipelineLifetime<'_> {
    fn drop(&mut self) {
        if !self.completed {
            self.connection.mark_dead();
        }
    }
}

impl Handle {
    pub(in crate::mutation_io) async fn hash(&self, size: u64) -> Result<String> {
        let mut lifetime = PipelineLifetime {
            connection: &self.connection,
            completed: false,
        };
        if self.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let limit = self
            .connection
            .params()
            .map_or(WIRE_BYTES, |p| p.max_read_size as usize)
            .min(WIRE_BYTES);
        if limit == 0 {
            return Err(Error::Input("server advertised an empty read limit"));
        }
        let mut digest = Sha256::new();
        let mut next = 0u64;
        let mut consumed = 0u64;
        let mut pending = FuturesUnordered::new();
        let mut ready = BTreeMap::new();
        loop {
            while next < size && pending.len() + ready.len() < WINDOW {
                let length = (size - next).min(limit as u64) as u32;
                pending.push(self.read_range(next, length));
                next += u64::from(length);
            }
            let Some(result) = pending.next().await else {
                break;
            };
            let (offset, bytes) = result?;
            ready.insert(offset, bytes);
            while let Some(bytes) = ready.remove(&consumed) {
                consumed += bytes.len() as u64;
                digest.update(&bytes);
            }
        }
        if consumed != size || !ready.is_empty() {
            return Err(Error::Changed);
        }
        if self.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        lifetime.completed = true;
        Ok(crate::mutation::hex(&digest.finalize()))
    }

    async fn read_range(&self, offset: u64, length: u32) -> Result<(u64, Vec<u8>)> {
        crate::transfer_limits::wait(false, u64::from(length), &self.cancel).await?;
        let frame = self
            .execute(
                Command::Read,
                &ReadRequest {
                    padding: 0x50,
                    flags: 0,
                    length,
                    offset,
                    file_id: self.file,
                    minimum_count: 0,
                    channel: 0,
                    remaining_bytes: 0,
                    read_channel_info: vec![],
                },
            )
            .await?;
        let bytes = ReadResponse::unpack(&mut ReadCursor::new(&frame.body))?.data;
        if bytes.len() != length as usize {
            return Err(Error::Changed);
        }
        Ok((offset, bytes))
    }

    pub(in crate::mutation_io) async fn write_payload(
        &self,
        payload: &mut VerifiedPayload,
        progress: &mut dyn FnMut(u64),
    ) -> Result<()> {
        let mut lifetime = PipelineLifetime {
            connection: &self.connection,
            completed: false,
        };
        let limit = self
            .connection
            .params()
            .map_or(WIRE_BYTES, |p| p.max_write_size as usize)
            .min(WIRE_BYTES);
        if limit == 0 {
            return Err(Error::Input("server advertised an empty write limit"));
        }
        let mut digest = Sha256::new();
        let mut next = 0u64;
        let mut confirmed = 0u64;
        let mut eof = false;
        let mut pending = FuturesUnordered::new();
        let mut ready = BTreeMap::new();
        loop {
            while !eof && pending.len() + ready.len() < WINDOW {
                let mut bytes = vec![0; limit];
                let count = tokio::select! { biased;
                    _ = self.cancel.cancelled() => return Err(Error::Cancelled),
                    count = payload.file.read(&mut bytes) => count?,
                };
                if count == 0 {
                    eof = true;
                    break;
                }
                bytes.truncate(count);
                let offset = next;
                next = next.checked_add(count as u64).ok_or(Error::Changed)?;
                if next > payload.bytes {
                    return Err(Error::Changed);
                }
                digest.update(&bytes);
                pending.push(async move {
                    self.write_all(offset, &bytes).await?;
                    Ok::<_, Error>((offset, bytes.len() as u64))
                });
            }
            let Some(result) = pending.next().await else {
                break;
            };
            let (offset, length) = result?;
            ready.insert(offset, length);
            while let Some(length) = ready.remove(&confirmed) {
                confirmed += length;
                progress(confirmed);
            }
        }
        if !eof
            || confirmed != payload.bytes
            || crate::mutation::hex(&digest.finalize()) != payload.sha256
        {
            return Err(Error::Changed);
        }
        lifetime.completed = true;
        Ok(())
    }

    pub(in crate::mutation_io) async fn write_all(&self, offset: u64, bytes: &[u8]) -> Result<()> {
        crate::transfer_limits::wait(true, bytes.len() as u64, &self.cancel).await?;
        let mut written = 0;
        while written < bytes.len() {
            let frame = self
                .execute(
                    Command::Write,
                    &WriteRequest {
                        data_offset: 112,
                        offset: offset + written as u64,
                        file_id: self.file,
                        channel: 0,
                        remaining_bytes: 0,
                        write_channel_info_offset: 0,
                        write_channel_info_length: 0,
                        flags: 0,
                        data: bytes[written..].to_vec(),
                    },
                )
                .await?;
            let count = WriteResponse::unpack(&mut ReadCursor::new(&frame.body))?.count as usize;
            if count == 0 || count > bytes.len() - written {
                return Err(Error::Smb(smb2::ErrorKind::InvalidData));
            }
            written += count;
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "mutation_stream_tests.rs"]
mod tests;
