//! Server-resolved spelling for alias renames. A lookup by a different case or
//! Unicode sequence is not evidence of the stored filename. Never casefold or
//! normalize a caller's names to invent that evidence.
use super::{Command, Entry, Error, Handle, Open, Result};
use smb2::{
    msg::{
        directory_info,
        query_directory::{
            FileInformationClass, QueryDirectoryFlags, QueryDirectoryRequest,
            QueryDirectoryResponse,
        },
    },
    pack::{ReadCursor, Unpack},
};

impl Handle {
    pub(super) async fn canonical_name(&self, path: &str, expected: &Entry) -> Result<String> {
        match self.query(48, 8192).await {
            Ok(bytes) => return normalized_name(&bytes),
            Err(Error::Smb(smb2::ErrorKind::Unsupported)) => {}
            Err(error) => return Err(error),
        }
        let (parent, name) = path.rsplit_once('/').unwrap_or(("", path));
        let directory = Self::open(
            self.connection.clone(),
            self.tree,
            parent,
            Open::Enumerate,
            &self.cancel,
        )
        .await?;
        let result = async {
            let frame = directory
                .execute(
                    Command::QueryDirectory,
                    &QueryDirectoryRequest {
                        file_information_class:
                            FileInformationClass::FileIdBothDirectoryInformation,
                        flags: QueryDirectoryFlags(QueryDirectoryFlags::RESTART_SCANS),
                        file_index: 0,
                        file_id: directory.file,
                        output_buffer_length: 64 * 1024,
                        file_name: smb2::encode_name(name).into_owned(),
                    },
                )
                .await?;
            let bytes =
                QueryDirectoryResponse::unpack(&mut ReadCursor::new(&frame.body))?.output_buffer;
            if bytes.len() > 64 * 1024 {
                return Err(Error::Smb(smb2::ErrorKind::InvalidData));
            }
            let entries = directory_info::parse_entries(
                FileInformationClass::FileIdBothDirectoryInformation,
                &bytes,
            )?;
            let mut matches = entries.iter().filter(|entry| {
                entry.file_id == expected.index_number
                    && entry.creation_time.0 == expected.created_filetime
            });
            let entry = matches
                .next()
                .ok_or(Error::Smb(smb2::ErrorKind::Unsupported))?;
            if matches.next().is_some() {
                return Err(Error::Smb(smb2::ErrorKind::Unsupported));
            }
            valid_name(smb2::decode_name(&entry.file_name).into_owned())
        }
        .await;
        directory.close().await?;
        result
    }
}

fn normalized_name(bytes: &[u8]) -> Result<String> {
    if bytes.len() < 4 {
        return Err(Error::Smb(smb2::ErrorKind::InvalidData));
    }
    let length = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
    if length == 0 || length % 2 != 0 || length > bytes.len() - 4 || length > 8192 {
        return Err(Error::Smb(smb2::ErrorKind::InvalidData));
    }
    let name: Vec<_> = bytes[4..4 + length]
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    let name = String::from_utf16(&name).map_err(|_| Error::Smb(smb2::ErrorKind::InvalidData))?;
    valid_name(smb2::decode_name(name.rsplit('\\').next().unwrap()).into_owned())
}
fn valid_name(name: String) -> Result<String> {
    if name.is_empty() || name.contains(['/', '\\', '\0']) || name == "." || name == ".." {
        return Err(Error::Smb(smb2::ErrorKind::InvalidData));
    }
    Ok(name)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn actual_name_preserves_case_and_unicode_bytes() {
        for name in ["FILE.txt", "cafe\u{301}.txt", "café.txt"] {
            let path = format!("\\parent\\{name}");
            let mut bytes = vec![];
            let encoded: Vec<_> = path.encode_utf16().collect();
            bytes.extend_from_slice(&(encoded.len() as u32 * 2).to_le_bytes());
            for c in encoded {
                bytes.extend_from_slice(&c.to_le_bytes());
            }
            assert_eq!(normalized_name(&bytes).unwrap().as_bytes(), name.as_bytes());
        }
        assert!(normalized_name(&[0; 3]).is_err());
        assert!(normalized_name(&[9, 0, 0, 0, 0, 0]).is_err());
    }

    #[tokio::test]
    async fn unsupported_normalized_name_falls_back_to_server_directory_spelling() {
        use crate::test_wire::{connection, reply};
        use smb2::{
            msg::{
                create::{CreateAction, CreateResponse},
                header::Header,
            },
            pack::{FileTime, Pack, WriteCursor},
            types::{flags::HeaderFlags, status::NtStatus, FileId, OplockLevel, TreeId},
        };
        let (connection, mock) = connection().await;
        let mut header = Header::new_request(Command::QueryInfo);
        header.flags = HeaderFlags::new(HeaderFlags::SERVER_TO_REDIR);
        header.credits = 8;
        header.status = NtStatus::NOT_SUPPORTED;
        let mut bytes = WriteCursor::new();
        header.pack(&mut bytes);
        mock.queue_response(bytes.into_inner());
        reply(
            &mock,
            Command::Create,
            &CreateResponse {
                oplock_level: OplockLevel::None,
                flags: 0,
                create_action: CreateAction::FileOpened,
                creation_time: FileTime(1),
                last_access_time: FileTime(1),
                last_write_time: FileTime(1),
                change_time: FileTime(1),
                allocation_size: 0,
                end_of_file: 0,
                file_attributes: 16,
                file_id: FileId {
                    persistent: 4,
                    volatile: 4,
                },
                create_contexts: vec![],
            },
        );
        let entries = directory_info::pack_entries(
            FileInformationClass::FileIdBothDirectoryInformation,
            &[directory_info::DirectoryInfoEntry {
                file_id: Some(9),
                creation_time: FileTime(1),
                file_name: "file.txt".into(),
                ..Default::default()
            }],
        )
        .unwrap();
        reply(
            &mock,
            Command::QueryDirectory,
            &QueryDirectoryResponse {
                output_buffer: entries,
            },
        );
        reply(&mock, Command::Close, &crate::test_wire::Closed);
        reply(&mock, Command::Close, &crate::test_wire::Closed);
        let handle = Handle {
            connection,
            tree: TreeId(1),
            file: FileId {
                persistent: 2,
                volatile: 3,
            },
            cancel: crate::CancellationToken::new(),
            closed: false,
        };
        let expected = Entry {
            name: "FILE.txt".into(),
            bytes: 3,
            directory: false,
            index_number: Some(9),
            created_filetime: 1,
            modified_filetime: 3,
            changed_filetime: 4,
            attributes: 32,
        };
        assert_eq!(
            handle
                .canonical_name("parent/FILE.txt", &expected)
                .await
                .unwrap(),
            "file.txt"
        );
        handle.close().await.unwrap();
        mock.assert_fully_consumed();
        mock.close();
    }
}
