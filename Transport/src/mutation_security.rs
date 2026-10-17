//! Qualified replacement preserves owner, group and access DACL. Privileged
//! SACL/audit/security-label preservation is unqualified. Never relax an ACL.
use crate::{Error, Result};
use sha2::{Digest, Sha256};
use smb2::msg::create_context::{pack_contexts, CreateContext};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AccessSecurity(Vec<u8>);

impl AccessSecurity {
    pub fn parse(bytes: Vec<u8>) -> Result<Self> {
        let unsupported = || Error::Smb(smb2::ErrorKind::Unsupported);
        if bytes.len() < 20 || bytes.len() > 64 * 1024 || bytes[0] != 1 {
            return Err(unsupported());
        }
        let control = u16::from_le_bytes(bytes[2..4].try_into().unwrap());
        if control & 0x8000 == 0 {
            return Err(unsupported());
        }
        let offset = |position| {
            u32::from_le_bytes(bytes[position..position + 4].try_into().unwrap()) as usize
        };
        for sid in [offset(4), offset(8)] {
            if sid < 20 || sid > bytes.len().saturating_sub(8) || bytes[sid] != 1 {
                return Err(unsupported());
            }
            let length = 8usize + usize::from(bytes[sid + 1]) * 4;
            if length > bytes.len() - sid {
                return Err(unsupported());
            }
        }
        if offset(12) != 0 {
            return Err(unsupported());
        }
        let dacl = offset(16);
        if dacl != 0 {
            if control & 4 == 0 || dacl < 20 || dacl > bytes.len().saturating_sub(8) {
                return Err(unsupported());
            }
            let length = u16::from_le_bytes(bytes[dacl + 2..dacl + 4].try_into().unwrap()) as usize;
            if length < 8 || length > bytes.len() - dacl {
                return Err(unsupported());
            }
        }
        Ok(Self(bytes))
    }
    pub fn create_context(&self) -> Vec<u8> {
        pack_contexts(&[CreateContext::new(b"SecD", self.0.clone())])
    }
    pub fn require_same(&self, actual: &Self) -> Result<()> {
        if self != actual {
            return Err(Error::Smb(smb2::ErrorKind::Unsupported));
        }
        Ok(())
    }
    pub fn fingerprint(&self) -> String {
        crate::mutation::hex(&Sha256::digest(&self.0))
    }
}

#[cfg(test)]
pub(crate) fn fixture() -> Vec<u8> {
    let mut bytes = vec![0; 44];
    bytes[0] = 1;
    bytes[2..4].copy_from_slice(&0x8004u16.to_le_bytes());
    bytes[4..8].copy_from_slice(&20u32.to_le_bytes());
    bytes[8..12].copy_from_slice(&28u32.to_le_bytes());
    bytes[16..20].copy_from_slice(&36u32.to_le_bytes());
    bytes[20] = 1;
    bytes[28] = 1;
    bytes[36] = 2;
    bytes[38..40].copy_from_slice(&8u16.to_le_bytes());
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ignored_or_changed_security_descriptor_is_not_accepted() {
        let security = AccessSecurity::parse(fixture()).unwrap();
        let mut widened = fixture();
        widened[16..20].copy_from_slice(&0u32.to_le_bytes());
        assert!(security
            .require_same(&AccessSecurity::parse(widened).unwrap())
            .is_err());
        let mut owner = fixture();
        owner[25] = 9;
        assert!(security
            .require_same(&AccessSecurity::parse(owner).unwrap())
            .is_err());
        let contexts =
            smb2::msg::create_context::parse_contexts(&security.create_context()).unwrap();
        assert_eq!(contexts[0].name, b"SecD");
        assert_eq!(contexts[0].data, fixture());
    }
    #[test]
    fn unavailable_or_malformed_security_metadata_fails_closed() {
        for bytes in [vec![], vec![0; 19], vec![0; 44]] {
            assert!(AccessSecurity::parse(bytes).is_err());
        }
        let mut sacl = fixture();
        sacl[12..16].copy_from_slice(&36u32.to_le_bytes());
        assert!(AccessSecurity::parse(sacl).is_err());
    }
}
