//! Same-handle SMB reservations, bounded wire I/O and observation validation.
use super::*;

#[derive(Clone, Copy)]
pub(super) enum Open {
    Parent,
    ReadParent,
    ReadItem,
    Enumerate,
    Inspect,
    Guarded,
    SecurityGuarded,
    CreateFile,
    CreateDirectory,
    UploadAllocated,
}

pub(super) struct Handle {
    pub(super) connection: Connection,
    pub(super) tree: TreeId,
    pub(super) file: FileId,
    pub(super) cancel: CancellationToken,
    pub(super) closed: bool,
}

impl Handle {
    pub(super) async fn open(
        connection: Connection,
        tree: TreeId,
        path: &str,
        mode: Open,
        cancel: &CancellationToken,
    ) -> Result<Self> {
        Self::open_security(connection, tree, path, mode, cancel, None).await
    }

    pub(super) async fn open_security(
        connection: Connection,
        tree: TreeId,
        path: &str,
        mode: Open,
        cancel: &CancellationToken,
        security: Option<&crate::mutation_security::AccessSecurity>,
    ) -> Result<Self> {
        let create = matches!(mode, Open::CreateFile | Open::CreateDirectory);
        let guarded = matches!(
            mode,
            Open::Guarded | Open::SecurityGuarded | Open::UploadAllocated
        ) || create;
        let mut access = FileAccessMask::FILE_READ_ATTRIBUTES | FileAccessMask::SYNCHRONIZE;
        if guarded {
            access |= FileAccessMask::FILE_READ_DATA | FileAccessMask::DELETE;
        }
        if matches!(mode, Open::Enumerate) {
            access |= FileAccessMask::FILE_READ_DATA;
        }
        if matches!(mode, Open::SecurityGuarded | Open::UploadAllocated)
            || create
            || security.is_some()
        {
            access |= FileAccessMask::READ_CONTROL;
        }
        if matches!(mode, Open::CreateFile | Open::UploadAllocated) {
            access |= FileAccessMask::FILE_WRITE_DATA | FileAccessMask::FILE_WRITE_ATTRIBUTES;
        }
        let options = 0x0020_0000 // FILE_OPEN_REPARSE_POINT: inspect the link itself.
            |if matches!(mode,Open::Parent|Open::ReadParent|Open::Enumerate|Open::CreateDirectory){1}else if matches!(mode,Open::CreateFile|Open::UploadAllocated){0x40}else{0};
        let request = CreateRequest {
            requested_oplock_level: OplockLevel::None,
            impersonation_level: ImpersonationLevel::Impersonation,
            desired_access: FileAccessMask::new(access),
            file_attributes: if matches!(mode, Open::CreateDirectory) {
                DIRECTORY
            } else {
                0
            },
            share_access: ShareAccess(if guarded {
                ShareAccess::FILE_SHARE_READ
            } else if matches!(mode, Open::Parent) {
                ShareAccess::FILE_SHARE_READ | ShareAccess::FILE_SHARE_WRITE
            } else if matches!(mode, Open::ReadParent | Open::ReadItem | Open::Enumerate) {
                ShareAccess::FILE_SHARE_READ
            } else {
                ShareAccess::FILE_SHARE_READ
                    | ShareAccess::FILE_SHARE_WRITE
                    | ShareAccess::FILE_SHARE_DELETE
            }),
            create_disposition: if create {
                CreateDisposition::FileCreate
            } else {
                CreateDisposition::FileOpen
            },
            create_options: options,
            name: smb2::encode_path(path),
            create_contexts: security.map_or_else(Vec::new, |security| security.create_context()),
        };
        let frame = tokio::select! {biased;_=cancel.cancelled()=>{connection.mark_dead();return Err(Error::Cancelled);},frame=connection.execute(Command::Create,&request,Some(tree))=>frame?};
        success(&frame, Command::Create)?;
        let opened =
            CreateResponse::unpack(&mut ReadCursor::new(&frame.body)).map_err(|error| {
                connection.mark_dead();
                Error::from(error)
            })?;
        if matches!(mode, Open::ReadParent)
            && (opened.file_attributes & REPARSE != 0 || opened.file_attributes & DIRECTORY == 0)
        {
            connection.mark_dead();
            return Err(Error::Smb(smb2::ErrorKind::Unsupported));
        }
        Ok(Self {
            connection,
            tree,
            file: opened.file_id,
            cancel: cancel.clone(),
            closed: false,
        })
    }

    pub(super) async fn execute(&self, command: Command, request: &dyn Pack) -> Result<Frame> {
        let frame = tokio::select! {biased;_=self.cancel.cancelled()=>{self.connection.mark_dead();return Err(Error::Cancelled);},frame=self.connection.execute(command,request,Some(self.tree))=>frame?};
        success(&frame, command)?;
        Ok(frame)
    }
    pub(super) async fn query(&self, class: u8, length: u32) -> Result<Vec<u8>> {
        let frame = self
            .execute(
                Command::QueryInfo,
                &QueryInfoRequest {
                    info_type: InfoType::File,
                    file_info_class: class,
                    output_buffer_length: length,
                    additional_information: 0,
                    flags: 0,
                    file_id: self.file,
                    input_buffer: vec![],
                },
            )
            .await?;
        Ok(QueryInfoResponse::unpack(&mut ReadCursor::new(&frame.body))?.output_buffer)
    }
    pub(super) async fn security(&self) -> Result<crate::mutation_security::AccessSecurity> {
        let frame = self
            .execute(
                Command::QueryInfo,
                &QueryInfoRequest {
                    info_type: InfoType::Security,
                    file_info_class: 0,
                    output_buffer_length: 64 * 1024,
                    additional_information: 7,
                    flags: 0,
                    file_id: self.file,
                    input_buffer: vec![],
                },
            )
            .await?;
        crate::mutation_security::AccessSecurity::parse(
            QueryInfoResponse::unpack(&mut ReadCursor::new(&frame.body))?.output_buffer,
        )
    }

    pub(super) async fn rename(
        &self,
        path: &str,
        expected: &Entry,
        destination: &str,
        hash: Option<&str>,
    ) -> Result<Entry> {
        let before = self.observe(path).await?;
        if !mutation::same_version(expected, &before) {
            return Err(Error::Changed);
        }
        self.ensure_plain(&before).await?;
        if let Some(hash) = hash {
            if self.hash(before.bytes).await? != hash {
                return Err(Error::Changed);
            }
        }
        self.set(10, rename_buffer(destination)).await?;
        let after = self.observe(destination).await?;
        if !mutation::same_identity(&before, &after)
            || before.bytes != after.bytes
            || before.modified_filetime != after.modified_filetime
            || !mutation::same_rename_attributes(&before, &after)
        {
            return Err(Error::CommitUncertain);
        }
        Ok(after)
    }

    pub(super) async fn set(&self, class: u8, buffer: Vec<u8>) -> Result<()> {
        self.execute(
            Command::SetInfo,
            &SetInfoRequest {
                info_type: InfoType::File,
                file_info_class: class,
                additional_information: 0,
                file_id: self.file,
                buffer,
            },
        )
        .await?;
        Ok(())
    }
    pub(super) async fn observe(&self, path: &str) -> Result<Entry> {
        let basic = self.query(4, 40).await?;
        let standard = self.query(5, 24).await?;
        let internal = self.query(6, 8).await?;
        observe(path, &basic, &standard, &internal)
    }
    pub(super) async fn ensure_plain(&self, entry: &Entry) -> Result<()> {
        if entry.directory {
            return Ok(());
        }
        let standard = self.query(5, 24).await?;
        if standard.len() < 24 || u32::from_le_bytes(standard[16..20].try_into().unwrap()) != 1 {
            return Err(Error::Smb(smb2::ErrorKind::Unsupported));
        }
        let ea = self.query(7, 4).await?;
        if ea.len() < 4 || u32::from_le_bytes(ea[..4].try_into().unwrap()) != 0 {
            return Err(Error::Smb(smb2::ErrorKind::Unsupported));
        }
        plain_streams(&self.query(22, 64 * 1024).await?)
    }
    pub(super) async fn close(mut self) -> Result<()> {
        let frame = tokio::time::timeout(
            crate::CLEANUP_TIMEOUT,
            self.connection.execute(
                Command::Close,
                &CloseRequest {
                    flags: 0,
                    file_id: self.file,
                },
                Some(self.tree),
            ),
        )
        .await
        .map_err(|_| Error::Cleanup)??;
        success(&frame, Command::Close)?;
        CloseResponse::unpack(&mut ReadCursor::new(&frame.body))?;
        self.closed = true;
        Ok(())
    }
}

#[path = "mutation_stream.rs"]
mod stream;
impl Drop for Handle {
    fn drop(&mut self) {
        if !self.closed {
            self.connection.mark_dead();
        }
    }
}

fn success(frame: &Frame, command: Command) -> Result<()> {
    if frame.header.command != command {
        return Err(Error::Smb(smb2::ErrorKind::InvalidData));
    }
    if frame.header.status == NtStatus(0xC000_0003) {
        return Err(Error::Smb(smb2::ErrorKind::Unsupported));
    }
    if frame.header.status == NtStatus(0xC000_0101) {
        return Err(Error::DirectoryNotEmpty);
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

fn observe(path: &str, basic: &[u8], standard: &[u8], internal: &[u8]) -> Result<Entry> {
    if basic.len() < 40 || standard.len() < 24 || internal.len() < 8 {
        return Err(Error::Smb(smb2::ErrorKind::InvalidData));
    }
    let u64_at =
        |data: &[u8], offset| u64::from_le_bytes(data[offset..offset + 8].try_into().unwrap());
    let attributes = u32::from_le_bytes(basic[32..36].try_into().unwrap());
    let index = u64_at(internal, 0);
    if attributes & REPARSE != 0 || standard[20] != 0 || index == 0 || u64_at(basic, 0) == 0 {
        return Err(Error::Smb(smb2::ErrorKind::Unsupported));
    }
    let directory = standard[21] != 0;
    if directory != (attributes & DIRECTORY != 0) {
        return Err(Error::Smb(smb2::ErrorKind::InvalidData));
    }
    Ok(Entry {
        name: path.rsplit('/').next().unwrap_or(path).to_owned(),
        bytes: u64_at(standard, 8),
        directory,
        index_number: Some(index),
        created_filetime: u64_at(basic, 0),
        modified_filetime: u64_at(basic, 16),
        changed_filetime: u64_at(basic, 24),
        attributes,
    })
}

pub(super) fn rename_buffer(destination: &str) -> Vec<u8> {
    let encoded = smb2::encode_path(destination);
    let name: Vec<_> = encoded.encode_utf16().collect();
    let mut buffer = vec![0; 16]; // ReplaceIfExists=false, reserved and RootDirectory=0.
    buffer.extend_from_slice(&(name.len() as u32 * 2).to_le_bytes());
    for character in name {
        buffer.extend_from_slice(&character.to_le_bytes());
    }
    buffer
}
