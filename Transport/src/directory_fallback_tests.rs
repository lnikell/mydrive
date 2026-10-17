use super::*;

fn directory_batch(attributes: u32, created: u64) -> Vec<u8> {
    directory_info::pack_entries(
        FileInformationClass::FileBothDirectoryInformation,
        &[DirectoryInfoEntry {
            file_name: "subfolder".to_owned(),
            creation_time: FileTime(created),
            last_write_time: FileTime(66),
            change_time: FileTime(77),
            file_attributes: attributes,
            ..Default::default()
        }],
    )
    .unwrap()
}

#[tokio::test]
async fn fallback_directory_gets_a_real_child_identity_under_its_own_readonly_handle() {
    let (connection, mock) = connection().await;
    opened(&mock);
    observed(&mock, 44, 16);
    status(&mock, Command::QueryDirectory, NtStatus::NOT_SUPPORTED);
    reply(
        &mock,
        Command::QueryDirectory,
        &QueryDirectoryResponse {
            output_buffer: directory_batch(16, 55),
        },
    );
    opened_at(
        &mock,
        FileId {
            persistent: 4,
            volatile: 5,
        },
        16,
    );
    observed(&mock, 99, 16);
    reply(&mock, Command::Close, &Empty);
    status(&mock, Command::QueryDirectory, NtStatus::NO_MORE_FILES);
    observed(&mock, 44, 16);
    reply(&mock, Command::Close, &Empty);
    let listing = read_reserved(handle(connection).await, None, "folder", None, |entries| {
        assert_eq!(entries[0].name, "subfolder");
        assert!(entries[0].directory);
        assert_eq!(entries[0].index_number, Some(99));
        assert_eq!(entries[0].created_filetime, 55);
        Ok(())
    })
    .await
    .unwrap();
    assert!(listing.complete);
    let creates: Vec<_> = mock
        .sent_messages()
        .iter()
        .filter(|data| {
            Header::unpack(&mut ReadCursor::new(data)).unwrap().command == Command::Create
        })
        .map(|data| CreateRequest::unpack(&mut ReadCursor::new(&data[64..])).unwrap())
        .collect();
    assert_eq!(creates.len(), 2);
    assert_eq!(
        creates[1].share_access.0,
        smb2::msg::create::ShareAccess::FILE_SHARE_READ
    );
    assert_eq!(
        creates[1].desired_access.bits() & smb2::types::flags::FileAccessMask::DELETE,
        0
    );
    assert_ne!(creates[1].create_options & 0x0020_0000, 0);
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn fallback_child_replacement_cannot_be_adopted_by_name() {
    let (connection, mock) = connection().await;
    opened(&mock);
    observed(&mock, 44, 16);
    status(&mock, Command::QueryDirectory, NtStatus::NOT_SUPPORTED);
    reply(
        &mock,
        Command::QueryDirectory,
        &QueryDirectoryResponse {
            output_buffer: directory_batch(16, 54),
        },
    );
    opened_at(
        &mock,
        FileId {
            persistent: 4,
            volatile: 5,
        },
        16,
    );
    observed(&mock, 99, 16);
    reply(&mock, Command::Close, &Empty);
    reply(&mock, Command::Close, &Empty);
    let result = read_reserved(handle(connection).await, None, "folder", None, |_| {
        panic!("replacement must not publish")
    })
    .await;
    assert!(matches!(result, Err(Error::Changed)));
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn fallback_reparse_child_is_listed_without_following_or_inventing_its_identity() {
    let (connection, mock) = connection().await;
    opened(&mock);
    observed(&mock, 44, 16);
    status(&mock, Command::QueryDirectory, NtStatus::NOT_SUPPORTED);
    reply(
        &mock,
        Command::QueryDirectory,
        &QueryDirectoryResponse {
            output_buffer: directory_batch(16 | 0x400, 55),
        },
    );
    status(&mock, Command::QueryDirectory, NtStatus::NO_MORE_FILES);
    observed(&mock, 44, 16);
    reply(&mock, Command::Close, &Empty);
    let listing = read_reserved(handle(connection).await, None, "folder", None, |entries| {
        assert_eq!(entries[0].index_number, None);
        assert_eq!(entries[0].attributes & 0x400, 0x400);
        Ok(())
    })
    .await
    .unwrap();
    assert!(listing.complete);
    assert_eq!(
        mock.sent_messages()
            .iter()
            .filter(
                |data| Header::unpack(&mut ReadCursor::new(data)).unwrap().command
                    == Command::Create
            )
            .count(),
        1
    );
    mock.assert_fully_consumed();
    mock.close();
}
