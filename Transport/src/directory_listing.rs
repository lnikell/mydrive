//! Bounded QUERY_DIRECTORY and parent observations use the exact same handle.
//! All ancestors and the listed directory stay reserved until explicit CLOSE.
use super::{Handle, MutationIO, Open};
use crate::{CancellationToken, Entry, Error, Listing, Result};
use futures_util::{stream::FuturesOrdered, StreamExt};
use smb2::{
    client::connection::Connection,
    msg::{
        directory_info,
        query_directory::{
            FileInformationClass, QueryDirectoryFlags, QueryDirectoryRequest,
            QueryDirectoryResponse,
        },
    },
    pack::{ReadCursor, Unpack},
    types::{status::NtStatus, Command},
    Tree,
};

const BUFFER_BYTES: u32 = 64 * 1024;

pub(crate) async fn read(
    connection: Connection,
    tree: &Tree,
    path: &str,
    limit: Option<usize>,
    scope: Option<&crate::mutation::DeleteScope>,
    cancel: &CancellationToken,
    page: impl FnMut(Vec<Entry>) -> Result<()>,
) -> Result<Listing> {
    if limit == Some(0) {
        return Err(Error::Input("page limit must be positive"));
    }
    let parents =
        MutationIO::for_scoped_read(connection.clone(), tree, path, scope, cancel).await?;
    let handle = Handle::open(connection, tree.tree_id, path, Open::Enumerate, cancel).await?;
    read_reserved(handle, Some(parents), path, limit, page).await
}

async fn read_reserved(
    handle: Handle,
    parents: Option<MutationIO>,
    path: &str,
    limit: Option<usize>,
    mut page: impl FnMut(Vec<Entry>) -> Result<()>,
) -> Result<Listing> {
    let outcome = async {
        let before = handle.observe(path).await?;
        if !before.directory {
            return Err(Error::Smb(smb2::ErrorKind::NotADirectory));
        }
        let mut class = FileInformationClass::FileIdBothDirectoryInformation;
        let mut count = 0usize;
        let mut pages = 0usize;
        let complete = loop {
            let request = QueryDirectoryRequest {
                file_information_class: class,
                flags: QueryDirectoryFlags(if pages == 0 {
                    QueryDirectoryFlags::RESTART_SCANS
                } else {
                    0
                }),
                file_index: 0,
                file_id: handle.file,
                output_buffer_length: BUFFER_BYTES,
                file_name: "*".to_owned(),
            };
            let frame = tokio::select! {
                biased;
                _ = handle.cancel.cancelled() => {
                    handle.connection.mark_dead();
                    return Err(Error::Cancelled);
                }
                result = handle.connection.execute(Command::QueryDirectory, &request, Some(handle.tree)) => result?,
            };
            if frame.header.status == NtStatus::NO_MORE_FILES {
                break true;
            }
            if pages == 0 && class == FileInformationClass::FileIdBothDirectoryInformation
                && matches!(frame.header.status, NtStatus::INVALID_INFO_CLASS | NtStatus::NOT_SUPPORTED)
            {
                class = FileInformationClass::FileBothDirectoryInformation;
                continue;
            }
            if frame.header.status != NtStatus::SUCCESS {
                return Err(smb2::Error::Protocol { status: frame.header.status, command: Command::QueryDirectory }.into());
            }
            if frame.body.len() > BUFFER_BYTES as usize + 8 {
                return Err(Error::Smb(smb2::ErrorKind::InvalidData));
            }
            let response = QueryDirectoryResponse::unpack(&mut ReadCursor::new(&frame.body))?;
            let entries = enrich(&handle, path, parse(class, &response.output_buffer)?).await?;
            count = count.checked_add(entries.len()).ok_or(Error::Smb(smb2::ErrorKind::TooLarge))?;
            page(entries)?;
            pages += 1;
            if limit.is_some_and(|limit| pages >= limit) {
                break false;
            }
        };
        let after = handle.observe(path).await?;
        if !crate::mutation::same_identity(&before, &after) || !after.directory {
            return Err(Error::Changed);
        }
        Ok(Listing { entries: count, complete, entry: after })
    }.await;
    // Any dropped owner or failed CLOSE invalidates the session through Handle.
    // A completeness claim cannot outlive a failed leaf-handle cleanup.
    let closed = handle.close().await;
    let parents_closed = if let Some(parents) = parents {
        parents.close_checked().await
    } else {
        Ok(())
    };
    match closed.and(parents_closed) {
        Ok(()) => outcome,
        Err(error) => outcome.and(Err(error)),
    }
}

async fn enrich(parent: &Handle, path: &str, mut entries: Vec<Entry>) -> Result<Vec<Entry>> {
    // Only servers omitting listing IDs pay for these metadata reads. Keep the
    // directory reservation and at most four child handles through each batch.
    for chunk in entries.chunks_mut(4) {
        let mut observations: FuturesOrdered<_> = chunk
            .iter()
            .map(|entry| {
                let entry = entry.clone();
                async move {
                    if entry.index_number.is_some_and(|index| index != 0)
                        || entry.attributes & 0x400 != 0
                    {
                        return Ok(entry);
                    }
                    if entry.name.contains(['/', '\\', '\0']) {
                        return Ok(entry); // It cannot safely form one child pathname.
                    }
                    let child_path = if path.is_empty() {
                        entry.name.clone()
                    } else {
                        format!("{path}/{}", entry.name)
                    };
                    let child = match Handle::open(
                        parent.connection.clone(),
                        parent.tree,
                        &child_path,
                        Open::ReadItem,
                        &parent.cancel,
                    )
                    .await
                    {
                        Ok(child) => child,
                        Err(Error::Smb(
                            smb2::ErrorKind::Unsupported | smb2::ErrorKind::AccessDenied,
                        )) => return Ok(entry),
                        Err(error) => return Err(error),
                    };
                    let observed = child.observe(&child_path).await;
                    child.close().await?;
                    let observed = match observed {
                        Ok(observed) => observed,
                        Err(Error::Smb(
                            smb2::ErrorKind::Unsupported | smb2::ErrorKind::AccessDenied,
                        )) => return Ok(entry),
                        Err(error) => return Err(error),
                    };
                    if entry.directory != observed.directory
                        || entry.created_filetime != observed.created_filetime
                        || entry.modified_filetime != observed.modified_filetime
                        || entry.changed_filetime != observed.changed_filetime
                        || entry.attributes != observed.attributes
                        || (!entry.directory && entry.bytes != observed.bytes)
                    {
                        return Err(Error::Changed);
                    }
                    Ok(observed)
                }
            })
            .collect();
        for destination in chunk {
            *destination = observations
                .next()
                .await
                .expect("one observation per child")?;
        }
    }
    Ok(entries)
}

fn parse(class: FileInformationClass, bytes: &[u8]) -> Result<Vec<Entry>> {
    // Upstream deliberately accepts truncated tails. An exhaustive Catalog scan
    // cannot infer deletion from a partial record, so validate the chain first.
    let fixed = if class == FileInformationClass::FileIdBothDirectoryInformation {
        104
    } else {
        94
    };
    if bytes.is_empty() || bytes.len() > BUFFER_BYTES as usize {
        return Err(Error::Smb(smb2::ErrorKind::InvalidData));
    }
    let mut offset = 0usize;
    loop {
        let remaining = &bytes[offset..];
        if remaining.len() < fixed {
            return Err(Error::Smb(smb2::ErrorKind::InvalidData));
        }
        let next = u32::from_le_bytes(remaining[..4].try_into().unwrap()) as usize;
        let name_len = u32::from_le_bytes(remaining[60..64].try_into().unwrap()) as usize;
        let end = fixed + name_len;
        if name_len == 0
            || name_len % 2 != 0
            || end > remaining.len()
            || std::char::decode_utf16(
                remaining[fixed..end]
                    .chunks_exact(2)
                    .map(|pair| u16::from_le_bytes(pair.try_into().unwrap())),
            )
            .any(|character| character.is_err())
        {
            return Err(Error::Smb(smb2::ErrorKind::InvalidData));
        }
        if next == 0 {
            if remaining.len() - end > 7 {
                return Err(Error::Smb(smb2::ErrorKind::InvalidData));
            }
            break;
        }
        if next % 8 != 0 || next < end || next > remaining.len().saturating_sub(fixed) {
            return Err(Error::Smb(smb2::ErrorKind::InvalidData));
        }
        offset += next;
    }
    Ok(directory_info::parse_entries(class, bytes)?
        .into_iter()
        .filter_map(|entry| {
            let name = smb2::name::decode_name(&entry.file_name).into_owned();
            (name != "." && name != "..").then_some(Entry {
                name,
                bytes: entry.end_of_file,
                directory: entry.file_attributes & 16 != 0,
                index_number: entry.file_id.filter(|&id| id != 0),
                created_filetime: entry.creation_time.0,
                modified_filetime: entry.last_write_time.0,
                changed_filetime: entry.change_time.0,
                attributes: entry.file_attributes,
            })
        })
        .collect())
}

#[cfg(test)]
#[path = "directory_listing_tests.rs"]
mod tests;
