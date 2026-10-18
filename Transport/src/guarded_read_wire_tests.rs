use super::*;
use smb2::msg::read::ReadResponse;
use smb2::pack::WriteCursor;
#[test]
fn raw_reads_bound_copy_before_payload_allocation_and_reject_bad_envelopes() {
    let mut cursor = WriteCursor::new();
    ReadResponse {
        data_offset: 80,
        data_remaining: 0,
        flags: 0,
        data: b"abc".to_vec(),
    }
    .pack(&mut cursor);
    let valid = cursor.into_inner();
    assert_eq!(exact_read_data(&valid, 3).unwrap(), b"abc");
    for kind in ["structure", "offset", "advertised", "short", "truncated"] {
        let mut bad = valid.clone();
        match kind {
            "structure" => bad[0] = 0,
            "offset" => bad[2] = 64,
            "advertised" => bad[4..8].copy_from_slice(&u32::MAX.to_le_bytes()),
            "short" => bad[4..8].copy_from_slice(&2u32.to_le_bytes()),
            _ => {
                bad.pop();
            }
        }
        assert!(exact_read_data(&bad, 3).is_err());
    }
}
#[test]
fn read_open_preserves_name_and_denies_writers_and_reparse_following() {
    let request = read_request("parent/cafe\u{301}", read_access());
    assert_eq!(request.name.as_bytes(), "parent\\cafe\u{301}".as_bytes());
    assert_eq!(request.share_access.0, ShareAccess::FILE_SHARE_READ);
    assert_eq!(request.create_options, 0x0020_0040);
    assert_ne!(request.desired_access.0 & FileAccessMask::FILE_READ_EA, 0);
    assert_eq!(
        request.desired_access.0 & (FileAccessMask::FILE_WRITE_DATA | FileAccessMask::DELETE),
        0
    );
}
