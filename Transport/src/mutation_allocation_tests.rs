use super::*;
use crate::test_wire::{connection, reply, Empty};
use sha2::Digest;
use smb2::{
    msg::{create::CreateAction, header::Header},
    pack::FileTime,
    transport::MockTransport,
};

fn create(mock: &MockTransport, id: u64) {
    reply(
        mock,
        Command::Create,
        &CreateResponse {
            oplock_level: OplockLevel::None,
            flags: 0,
            create_action: CreateAction::FileOpened,
            creation_time: FileTime(7),
            last_access_time: FileTime(2),
            last_write_time: FileTime(3),
            change_time: FileTime(4),
            allocation_size: 0,
            end_of_file: 0,
            file_attributes: 32,
            file_id: FileId {
                persistent: id,
                volatile: id,
            },
            create_contexts: vec![],
        },
    );
}
fn query(mock: &MockTransport, output_buffer: Vec<u8>) {
    reply(
        mock,
        Command::QueryInfo,
        &QueryInfoResponse { output_buffer },
    );
}
fn observed(mock: &MockTransport, size: u64, id: u64, attributes: u32) {
    let mut basic = vec![0; 40];
    basic[..8].copy_from_slice(&1u64.to_le_bytes());
    basic[16..24].copy_from_slice(&3u64.to_le_bytes());
    basic[24..32].copy_from_slice(&4u64.to_le_bytes());
    basic[32..36].copy_from_slice(&attributes.to_le_bytes());
    let mut standard = vec![0; 24];
    standard[8..16].copy_from_slice(&size.to_le_bytes());
    standard[16..20].copy_from_slice(&1u32.to_le_bytes());
    for data in [basic, standard, id.to_le_bytes().to_vec()] {
        query(mock, data);
    }
}
fn links(mock: &MockTransport, count: u32) {
    let mut bytes = vec![0; 24];
    bytes[16..20].copy_from_slice(&count.to_le_bytes());
    query(mock, bytes);
}
fn plain(mock: &MockTransport) {
    links(mock, 1);
    query(mock, vec![0; 4]);
    query(mock, vec![]);
}
fn security() -> Vec<u8> {
    crate::mutation_security::fixture()
}
fn request() -> MutationRequest {
    MutationRequest {
        operation_id: "11111111-2222-4333-8444-555555555555".into(),
        kind: mutation::MutationKind::CreateFile,
        path: "file".into(),
        parent: mutation::DirectoryIdentity {
            index_number: 5,
            created_filetime: 6,
        },
        delete_scope: None,
        tree_scope: None,
        destination: None,
        destination_parent: None,
        expected: None,
        payload: Some(mutation::Payload {
            source: "/tmp/unused".into(),
            bytes: 3,
            sha256: "a".repeat(64),
        }),
        receipt: mutation::Receipt::default(),
    }
}
fn io(connection: Connection) -> MutationIO {
    MutationIO {
        connection,
        tree: TreeId(1),
        cancel: CancellationToken::new(),
        parents: vec![],
    }
}
fn allocation(request: &MutationRequest) -> Artifact {
    Artifact {
        path: request.sidecar("stage"),
        entry: Entry {
            name: "stage".into(),
            bytes: 0,
            directory: false,
            index_number: Some(10),
            created_filetime: 1,
            modified_filetime: 3,
            changed_filetime: 4,
            attributes: 32,
        },
        cleanup_safe: true,
        phase: StagePhase::Allocated,
        security_sha256: Some(AccessSecurity::parse(security()).unwrap().fingerprint()),
    }
}

#[tokio::test]
async fn allocation_acknowledges_empty_object_after_creation_time_and_security_before_any_write() {
    let (connection, mock) = connection().await;
    // Guard original access security, then exclusively allocate the new object.
    create(&mock, 9);
    observed(&mock, 3, 9, 32);
    plain(&mock);
    query(&mock, security());
    create(&mock, 10);
    query(&mock, security());
    reply(&mock, Command::SetInfo, &Empty);
    reply(&mock, Command::Flush, &Empty);
    observed(&mock, 0, 10, 32);
    plain(&mock);
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    create(&mock, 10);
    observed(&mock, 0, 10, 32);
    plain(&mock);
    query(&mock, security());
    observed(&mock, 0, 10, 32);
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    reply(&mock, Command::Close, &crate::test_wire::Closed);
    let mut request = request();
    request.kind = mutation::MutationKind::ReplaceFile;
    request.expected = Some(Entry {
        name: "file".into(),
        bytes: 3,
        directory: false,
        index_number: Some(9),
        created_filetime: 1,
        modified_filetime: 3,
        changed_filetime: 4,
        attributes: 32,
    });
    let mut io = io(connection);
    let result = io
        .allocate(&request, &request.sidecar("stage"))
        .await
        .unwrap();
    assert_eq!(result.phase, StagePhase::Allocated);
    assert_eq!(result.entry.bytes, 0);
    assert_eq!(result.entry.index_number, Some(10));
    assert_eq!(result.entry.created_filetime, 1);
    assert_eq!(result.security_sha256, allocation(&request).security_sha256);
    let sent = mock.sent_messages();
    let commands: Vec<_> = sent
        .iter()
        .map(|m| Header::unpack(&mut ReadCursor::new(m)).unwrap().command)
        .collect();
    assert!(!commands.contains(&Command::Write));
    assert!(!commands.contains(&Command::Read));
    let sets: Vec<_> = sent
        .iter()
        .filter(|m| Header::unpack(&mut ReadCursor::new(m)).unwrap().command == Command::SetInfo)
        .map(|m| SetInfoRequest::unpack(&mut ReadCursor::new(&m[64..])).unwrap())
        .collect();
    assert_eq!(sets.len(), 1);
    assert_eq!(sets[0].file_info_class, 4);
    assert_eq!(&sets[0].buffer[..8], &1u64.to_le_bytes());
    mock.assert_fully_consumed();
    mock.close();
}

#[tokio::test]
async fn restart_refuses_replaced_oversized_linked_reparse_forked_or_resecured_stages_before_truncate(
) {
    for fault in ["identity", "size", "links", "reparse", "fork", "security"] {
        let (connection, mock) = connection().await;
        create(&mock, 10);
        observed(
            &mock,
            if fault == "size" { 4 } else { 2 },
            if fault == "identity" { 11 } else { 10 },
            if fault == "reparse" { 32 | 0x400 } else { 32 },
        );
        if !matches!(fault, "identity" | "size" | "reparse") {
            links(&mock, if fault == "links" { 2 } else { 1 });
            if fault != "links" {
                query(&mock, vec![0; 4]);
                let mut stream = vec![];
                if fault == "fork" {
                    let name: Vec<_> = ":AFP_Resource:$DATA".encode_utf16().collect();
                    stream = vec![0; 24];
                    stream[4..8].copy_from_slice(&(name.len() as u32 * 2).to_le_bytes());
                    for c in name {
                        stream.extend_from_slice(&c.to_le_bytes());
                    }
                }
                query(&mock, stream);
                if fault != "fork" {
                    let mut sd = security();
                    sd[25] = 9;
                    query(&mock, sd);
                }
            }
        }
        reply(&mock, Command::Close, &crate::test_wire::Closed);
        let root =
            std::env::temp_dir().join(format!("mydrive-allocation-{}-{fault}", std::process::id()));
        tokio::fs::write(&root, b"abc").await.unwrap();
        let mut request = request();
        request.payload = Some(mutation::Payload {
            source: root.to_string_lossy().into(),
            bytes: 3,
            sha256: mutation::hex(&sha2::Sha256::digest(b"abc")),
        });
        request.receipt.staged = Some(allocation(&request));
        request.validate().unwrap();
        let mut payload =
            VerifiedPayload::open(request.payload.as_ref().unwrap(), &CancellationToken::new())
                .await
                .unwrap();
        let mut io = io(connection);
        assert!(
            io.stage(
                &request,
                &request.sidecar("stage"),
                Some(&mut payload),
                &mut |_| {}
            )
            .await
            .is_err(),
            "accepted {fault}"
        );
        assert!(
            mock.sent_messages().iter().all(|m| matches!(
                Header::unpack(&mut ReadCursor::new(m)).unwrap().command,
                Command::Create | Command::QueryInfo | Command::Close
            )),
            "wrote/truncated {fault}"
        );
        mock.assert_fully_consumed();
        mock.close();
        drop(payload);
        tokio::fs::remove_file(root).await.unwrap();
    }
}
