//! Protocol-only peer for the real download engine; no network socket.
use super::*;
use crate::test_wire::{connection_no_rewrite, Closed, Empty};
use smb2::{
    msg::{
        create::{CreateAction, CreateRequest, CreateResponse},
        header::Header,
        query_info::{QueryInfoRequest, QueryInfoResponse},
        read::{ReadRequest, ReadResponse},
        tree_connect::{ShareType, TreeConnectResponse},
    },
    pack::{FileTime, Pack, ReadCursor, Unpack, WriteCursor},
    transport::MockTransport,
    types::{
        flags::{HeaderFlags, ShareCapabilities, ShareFlags},
        status::NtStatus,
        Command, FileId, OplockLevel, TreeId,
    },
};
use std::{
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};

pub(super) struct Local(std::path::PathBuf);
impl Local {
    pub(super) fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "mydrive-download-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    pub(super) fn output(&self) -> std::path::PathBuf {
        self.0.join("output")
    }
    pub(super) fn other(&self) -> std::path::PathBuf {
        self.0.join("replaced")
    }
}
impl Drop for Local {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub(super) struct Fixture {
    pub connection: Connection,
    pub tree: Tree,
    pub mock: Arc<MockTransport>,
    pub local: Local,
}
impl Fixture {
    pub(super) async fn new() -> Self {
        let (mut connection, mock) = connection_no_rewrite().await;
        connection.set_session_id(smb2::types::SessionId(1));
        let (tree, ()) = tokio::join!(Tree::connect(&mut connection, "synthetic"), async {
            let request = sent(&mock, 1).await;
            answer(
                &mock,
                &request[0],
                None,
                NtStatus::SUCCESS,
                &TreeConnectResponse {
                    share_type: ShareType::Disk,
                    share_flags: ShareFlags::new(0),
                    capabilities: ShareCapabilities::new(0),
                    maximal_access: 0,
                },
            );
        });
        let tree = tree.unwrap();
        mock.clear_sent();
        Self {
            connection,
            tree,
            mock,
            local: Local::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Fault {
    None,
    AfterVersion,
    AfterEa,
    AfterStreams,
    MalformedClose,
    WrongClose,
    ParentClose,
    WrongCreate,
    WrongRead,
    ShortRead,
    DeniedRead,
    CancelCreate,
    CancelRead,
    CancelClose,
}
#[derive(Clone)]
pub(super) struct Config {
    pub body: Vec<u8>,
    pub provenance: bool,
    pub attributes: u32,
    pub ea: u32,
    pub links: u32,
    pub fault: Fault,
}
impl Config {
    pub(super) fn new(body: Vec<u8>) -> Self {
        Self {
            body,
            provenance: false,
            attributes: 32,
            ea: 0,
            links: 1,
            fault: Fault::None,
        }
    }
}
#[derive(Default)]
pub(super) struct Stats {
    pub reads: usize,
    pub closes: usize,
    pub snapshots: usize,
}

pub(super) fn answer(
    mock: &MockTransport,
    sent: &[u8],
    command: Option<Command>,
    status: NtStatus,
    body: &dyn Pack,
) {
    let request = Header::unpack(&mut ReadCursor::new(sent)).unwrap();
    let mut header = Header::new_request(command.unwrap_or(request.command));
    header.message_id = request.message_id;
    header.tree_id = Some(TreeId(1));
    header.flags = HeaderFlags::new(HeaderFlags::SERVER_TO_REDIR);
    header.status = status;
    header.credits = 16;
    let mut cursor = WriteCursor::new();
    header.pack(&mut cursor);
    body.pack(&mut cursor);
    mock.queue_response(cursor.into_inner());
}
pub(super) async fn sent(mock: &MockTransport, count: usize) -> Vec<Vec<u8>> {
    tokio::time::timeout(Duration::from_secs(5), async {
        while mock.sent_count() < count {
            tokio::task::yield_now().await;
        }
        mock.sent_messages()
    })
    .await
    .expect("download did not issue the expected protocol request")
}
fn streams(config: &Config, after: bool) -> Vec<u8> {
    let mut names = vec![("::$DATA", config.body.len() as u64, 65536)];
    if config.provenance || (after && config.fault == Fault::AfterStreams) {
        names.push((":com.apple.provenance:$DATA", 11, 11));
    }
    let mut output = vec![];
    for (i, (name, length, allocation)) in names.iter().enumerate() {
        let units: Vec<u8> = name.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let end = 24 + units.len();
        let size = if i + 1 < names.len() {
            (end + 7) & !7
        } else {
            end
        };
        let mut record = vec![0; size];
        if i + 1 < names.len() {
            record[..4].copy_from_slice(&(size as u32).to_le_bytes());
        }
        record[4..8].copy_from_slice(&(units.len() as u32).to_le_bytes());
        record[8..16].copy_from_slice(&length.to_le_bytes());
        record[16..24].copy_from_slice(&(*allocation as u64).to_le_bytes());
        record[24..end].copy_from_slice(&units);
        output.extend(record);
    }
    output
}
pub(super) fn respond(
    mock: &MockTransport,
    message: &[u8],
    config: &Config,
    stats: &mut Stats,
    cancel: &CancellationToken,
) {
    let header = Header::unpack(&mut ReadCursor::new(message)).unwrap();
    match header.command {
        Command::Create => {
            if config.fault == Fault::CancelCreate {
                cancel.cancel();
                return;
            }
            let request = CreateRequest::unpack(&mut ReadCursor::new(&message[64..])).unwrap();
            let directory = request.create_options & 1 != 0;
            assert_eq!(request.share_access.0, 1);
            assert_ne!(request.create_options & 0x0020_0000, 0);
            if !directory {
                assert_ne!(
                    request.desired_access.bits()
                        & smb2::types::flags::FileAccessMask::FILE_READ_EA,
                    0
                );
            }
            answer(
                mock,
                message,
                (config.fault == Fault::WrongCreate).then_some(Command::Read),
                NtStatus::SUCCESS,
                &CreateResponse {
                    oplock_level: OplockLevel::None,
                    flags: 0,
                    create_action: CreateAction::FileOpened,
                    creation_time: FileTime(1),
                    last_access_time: FileTime(0),
                    last_write_time: FileTime(2),
                    change_time: FileTime(3),
                    allocation_size: 65536,
                    end_of_file: config.body.len() as u64,
                    file_attributes: if directory { 16 } else { config.attributes },
                    file_id: FileId {
                        persistent: if directory { 4 } else { 2 },
                        volatile: 3,
                    },
                    create_contexts: vec![],
                },
            );
        }
        Command::QueryInfo => {
            let query = QueryInfoRequest::unpack(&mut ReadCursor::new(&message[64..])).unwrap();
            assert_eq!(query.file_id.persistent, 2);
            if query.file_info_class == 4 {
                stats.snapshots += 1;
            }
            let after = stats.snapshots > 1;
            let bytes = match query.file_info_class {
                4 => {
                    let mut v = vec![0; 40];
                    v[..8].copy_from_slice(&1u64.to_le_bytes());
                    v[16..24].copy_from_slice(&2u64.to_le_bytes());
                    v[24..32].copy_from_slice(
                        &(if after && config.fault == Fault::AfterVersion {
                            4u64
                        } else {
                            3
                        })
                        .to_le_bytes(),
                    );
                    v[32..36].copy_from_slice(&config.attributes.to_le_bytes());
                    v
                }
                5 => {
                    let mut v = vec![0; 24];
                    v[8..16].copy_from_slice(&(config.body.len() as u64).to_le_bytes());
                    v[16..20].copy_from_slice(&config.links.to_le_bytes());
                    v
                }
                6 => 9u64.to_le_bytes().to_vec(),
                7 => (if after && config.fault == Fault::AfterEa {
                    1
                } else {
                    config.ea
                })
                .to_le_bytes()
                .to_vec(),
                22 => streams(config, after),
                other => panic!("unexpected query {other}"),
            };
            assert!(bytes.len() <= query.output_buffer_length as usize);
            answer(
                mock,
                message,
                None,
                NtStatus::SUCCESS,
                &QueryInfoResponse {
                    output_buffer: bytes,
                },
            );
        }
        Command::Read => {
            stats.reads += 1;
            if config.fault == Fault::CancelRead {
                cancel.cancel();
                return;
            }
            let request = ReadRequest::unpack(&mut ReadCursor::new(&message[64..])).unwrap();
            assert!(request.length <= 65536);
            assert_eq!(request.file_id.persistent, 2);
            if config.fault == Fault::DeniedRead {
                answer(mock, message, None, NtStatus(0xc000_0022), &Empty);
                return;
            }
            let end = request.offset as usize + request.length as usize
                - usize::from(config.fault == Fault::ShortRead);
            answer(
                mock,
                message,
                (config.fault == Fault::WrongRead).then_some(Command::Create),
                NtStatus::SUCCESS,
                &ReadResponse {
                    data_offset: 80,
                    data_remaining: 0,
                    flags: 0,
                    data: config.body[request.offset as usize..end].to_vec(),
                },
            );
        }
        Command::Close => {
            stats.closes += 1;
            if config.fault == Fault::CancelClose {
                cancel.cancel();
            }
            if config.fault == Fault::MalformedClose
                || (config.fault == Fault::ParentClose && stats.closes == 2)
            {
                answer(mock, message, None, NtStatus::SUCCESS, &Empty);
            } else {
                answer(
                    mock,
                    message,
                    (config.fault == Fault::WrongClose).then_some(Command::Read),
                    NtStatus::SUCCESS,
                    &Closed,
                );
            }
        }
        other => panic!("unexpected command {other:?}"),
    }
}
pub(super) async fn serve(
    fixture: &Fixture,
    config: &Config,
    done: &CancellationToken,
    cancel: &CancellationToken,
) -> Stats {
    let mut stats = Stats::default();
    let mut consumed = 0;
    loop {
        let messages = tokio::select! {biased;_=done.cancelled()=>break, messages=sent(&fixture.mock,consumed+1)=>messages};
        for message in &messages[consumed..] {
            respond(&fixture.mock, message, config, &mut stats, cancel);
        }
        consumed = messages.len();
    }
    stats
}
pub(super) async fn execute(
    fixture: &Fixture,
    config: &Config,
    remote: &str,
    purpose: Purpose,
    cancel: &CancellationToken,
    progress: impl FnMut(u64),
) -> (Result<Download>, Stats) {
    let done = CancellationToken::new();
    let operation = async {
        let result = match run(
            fixture.connection.clone(),
            &fixture.tree,
            remote,
            &fixture.local.output(),
            purpose,
            cancel,
            progress,
        )
        .await
        {
            Ok(staged) => staged.finish(cancel).await,
            Err(error) => Err(error),
        };
        done.cancel();
        result
    };
    tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(operation, serve(fixture, config, &done, cancel))
    })
    .await
    .unwrap()
}
