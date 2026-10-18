//! Bounded complete FileStreamInformation decoding, separate from strict policy.
use super::{invalid, u32_at, u64_at, Entry, Error, Result, StreamDescriptor};
const STREAM_LIMIT: u32 = 65536;

const MAX_STREAMS: usize = 32;
const MAX_NAME_UNITS: usize = 256;
const MAX_TOTAL_UNITS: usize = 1024;

/// Decode the entire chain before a caller evaluates any representation policy.
/// Names remain exact UTF16/UTF8 metadata; they never become filesystem paths.
pub(super) fn inventory(mut bytes: &[u8], entry: &Entry) -> Result<Vec<StreamDescriptor>> {
    if bytes.len() > STREAM_LIMIT as usize {
        return Err(invalid());
    }
    let mut descriptors = Vec::new();
    let mut total_units = 0;
    while !bytes.is_empty() {
        if bytes.len() < 24 {
            return Err(invalid());
        }
        if descriptors.len() == MAX_STREAMS {
            return Err(invalid());
        }
        let next = u32_at(bytes, 0) as usize;
        let length = u32_at(bytes, 4) as usize;
        let logical_size = u64_at(bytes, 8);
        let allocation_size = u64_at(bytes, 16);
        if length == 0
            || length % 2 != 0
            || length > bytes.len() - 24
            || logical_size > i64::MAX as u64
            || allocation_size > i64::MAX as u64
        {
            return Err(invalid());
        }
        let units = length / 2;
        if units > MAX_NAME_UNITS || units > MAX_TOTAL_UNITS - total_units {
            return Err(invalid());
        }
        let end = 24 + length;
        if next == 0 {
            // FSCC permits only up to seven bytes of final alignment padding.
            if bytes.len() - end > 7 {
                return Err(invalid());
            }
        } else if next % 8 != 0
            || next < end
            || next - end > 7
            || next > bytes.len().saturating_sub(24)
        {
            return Err(invalid());
        }
        let name_utf16: Vec<_> = bytes[24..end]
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .collect();
        let name = String::from_utf16(&name_utf16).map_err(|_| invalid())?;
        descriptors.push(StreamDescriptor {
            name_utf16,
            name,
            name_length_bytes: length as u32,
            logical_size,
            allocation_size,
        });
        total_units += units;
        if next == 0 {
            break;
        }
        bytes = &bytes[next..];
    }
    descriptors.sort_by(|left, right| left.name.as_bytes().cmp(right.name.as_bytes()));
    let mut unnamed = false;
    for (index, descriptor) in descriptors.iter().enumerate() {
        if index > 0 && descriptors[index - 1].name == descriptor.name {
            return Err(invalid());
        }
        if descriptor.name == "::$DATA" {
            unnamed = true;
            if descriptor.logical_size != entry.bytes {
                return Err(Error::Changed);
            }
        }
    }
    if !entry.directory && !unnamed {
        return Err(invalid());
    }
    Ok(descriptors)
}
