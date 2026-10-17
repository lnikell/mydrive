//! Verify one owned staging descriptor before any remote mutation.
use super::Payload;
use crate::{Error, Result};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

pub(crate) struct VerifiedPayload {
    pub file: tokio::fs::File,
    pub bytes: u64,
    pub sha256: String,
}

impl VerifiedPayload {
    pub async fn open(payload: &Payload, cancel: &crate::CancellationToken) -> Result<Self> {
        let mut options = tokio::fs::OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        }
        let mut file = options.open(&payload.source).await?;
        let before = file.metadata().await?;
        if !before.is_file() || before.len() != payload.bytes {
            return Err(Error::Changed);
        }
        ensure_local_plain(&file)?;
        let mut digest = Sha256::new();
        let mut count = 0u64;
        let mut buffer = vec![0; crate::CHUNK_BYTES];
        loop {
            let read = tokio::select! { biased; _ = cancel.cancelled() => return Err(Error::Cancelled), read = file.read(&mut buffer) => read? };
            if read == 0 {
                break;
            }
            count = count.checked_add(read as u64).ok_or(Error::Changed)?;
            if count > payload.bytes {
                return Err(Error::Changed);
            }
            digest.update(&buffer[..read]);
        }
        let hash = crate::mutation::hex(&digest.finalize());
        if count != payload.bytes
            || hash != payload.sha256
            || file.metadata().await?.len() != before.len()
        {
            return Err(Error::Changed);
        }
        ensure_local_plain(&file)?;
        file.seek(std::io::SeekFrom::Start(0)).await?;
        Ok(Self {
            file,
            bytes: count,
            sha256: hash,
        })
    }
}

pub(crate) fn ensure_local_plain(file: &tokio::fs::File) -> Result<()> {
    #[cfg(target_os = "macos")]
    {
        use std::os::fd::AsRawFd;
        let count = unsafe {
            libc::fgetxattr(
                file.as_raw_fd(),
                c"com.apple.ResourceFork".as_ptr(),
                std::ptr::null_mut(),
                0,
                0,
                0,
            )
        };
        if count > 0 {
            return Err(Error::Smb(smb2::ErrorKind::Unsupported));
        }
        if count < 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ENOATTR) {
                return Err(error.into());
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = file;
    Ok(())
}
