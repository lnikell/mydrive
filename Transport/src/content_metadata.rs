//! One bounded stream-list policy shared by hydration and mutations.
use crate::{Error, Result};

pub(crate) fn require_plain_streams(mut data: &[u8]) -> Result<()> {
    if data.len() > 64 * 1024 {
        return Err(Error::Smb(smb2::ErrorKind::InvalidData));
    }
    // Only the unnamed data stream is representable by this File Provider.
    // Unknown/malformed stream lists fail closed rather than flattening forks.
    while !data.is_empty() {
        if data.len() < 24 {
            return Err(Error::Smb(smb2::ErrorKind::InvalidData));
        }
        let next = u32::from_le_bytes(data[0..4].try_into().unwrap()) as usize;
        let length = u32::from_le_bytes(data[4..8].try_into().unwrap()) as usize;
        if length % 2 != 0 || length > data.len() - 24 {
            return Err(Error::Smb(smb2::ErrorKind::InvalidData));
        }
        let name: Vec<_> = data[24..24 + length]
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .collect();
        if String::from_utf16(&name).ok().as_deref() != Some("::$DATA") {
            return Err(Error::Smb(smb2::ErrorKind::Unsupported));
        }
        if next == 0 {
            break;
        }
        if next < 24 + length || next >= data.len() {
            return Err(Error::Smb(smb2::ErrorKind::InvalidData));
        }
        data = &data[next..];
    }
    Ok(())
}
