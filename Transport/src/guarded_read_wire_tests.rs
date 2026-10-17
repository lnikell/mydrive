use super::*;
use crate::test_wire::{connection, reply, Empty};
use smb2::msg::query_info::QueryInfoResponse;

fn metadata(mock: &smb2::transport::MockTransport, attributes: u32) {
    let mut basic = vec![0; 40];
    basic[0..8].copy_from_slice(&1u64.to_le_bytes());
    basic[32..36].copy_from_slice(&attributes.to_le_bytes());
    let mut standard = vec![0; 24];
    standard[8..16].copy_from_slice(&3u64.to_le_bytes());
    standard[16..20].copy_from_slice(&1u32.to_le_bytes());
    for data in [basic, standard, 9u64.to_le_bytes().to_vec()] {
        reply(
            mock,
            Command::QueryInfo,
            &QueryInfoResponse {
                output_buffer: data,
            },
        );
    }
}
fn stream(name: &str) -> Vec<u8> {
    let name: Vec<_> = name.encode_utf16().collect();
    let mut bytes = vec![0; 24];
    bytes[4..8].copy_from_slice(&(name.len() as u32 * 2).to_le_bytes());
    for c in name {
        bytes.extend_from_slice(&c.to_le_bytes());
    }
    bytes
}

#[tokio::test]
async fn hydration_refuses_named_forks_and_reparse_points_before_any_data_read() {
    for (attributes, name, accepted) in [
        (32, "::$DATA", true),
        (32, ":AFP_Resource:$DATA", false),
        (32 | 0x400, "", false),
    ] {
        let (connection, mock) = connection().await;
        metadata(&mock, attributes);
        if attributes & 0x400 == 0 {
            reply(
                &mock,
                Command::QueryInfo,
                &QueryInfoResponse {
                    output_buffer: stream(name),
                },
            );
        }
        reply(&mock, Command::Close, &Empty);
        let handle = GuardedRead {
            connection,
            tree: TreeId(1),
            file: FileId {
                persistent: 2,
                volatile: 3,
            },
            max_read: 65536,
            closed: false,
            cancel: CancellationToken::new(),
            ancestors: None,
        };
        let result = handle.observe().await;
        if accepted {
            assert_eq!(result.unwrap().size, 3);
        } else {
            assert!(matches!(
                result,
                Err(Error::Smb(smb2::ErrorKind::Unsupported))
            ));
        }
        handle.close().await.unwrap();
        let commands: Vec<_> = mock
            .sent_messages()
            .iter()
            .map(|bytes| {
                smb2::msg::header::Header::unpack(&mut ReadCursor::new(bytes))
                    .unwrap()
                    .command
            })
            .collect();
        assert!(!commands.contains(&Command::Read));
        mock.assert_fully_consumed();
        mock.close();
    }
}

#[test]
fn hydration_create_explicitly_opens_the_link_itself_and_denies_smb_writers() {
    let request = read_request("parent/cafe\u{301}");
    assert_ne!(request.create_options & 0x0020_0000, 0);
    assert_eq!(request.share_access.0, ShareAccess::FILE_SHARE_READ);
    assert_eq!(request.name.as_bytes(), "parent\\cafe\u{301}".as_bytes());
}
