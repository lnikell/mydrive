//! Canned SMB transport for protocol tests; never opens a network socket.
use async_trait::async_trait;
use smb2::{
    client::connection::Connection,
    msg::header::Header,
    pack::{Pack, WriteCursor},
    transport::{MockTransport, TransportReceive, TransportSend},
    types::{flags::HeaderFlags, Command},
};
use std::sync::Arc;

#[derive(Clone)]
struct Mock(Arc<MockTransport>);
#[async_trait]
impl TransportSend for Mock {
    async fn send(&self, data: &[u8]) -> smb2::Result<()> {
        self.0.send(data).await
    }
}
#[async_trait]
impl TransportReceive for Mock {
    async fn receive(&self) -> smb2::Result<Vec<u8>> {
        self.0.receive().await
    }
}

pub(crate) async fn connection() -> (Connection, Arc<MockTransport>) {
    connection_mode(true).await
}
pub(crate) async fn connection_no_rewrite() -> (Connection, Arc<MockTransport>) {
    connection_mode(false).await
}
async fn connection_mode(rewrite: bool) -> (Connection, Arc<MockTransport>) {
    let mock = Arc::new(MockTransport::new());
    if rewrite {
        mock.enable_auto_rewrite_msg_id();
    }
    let mut connection = Connection::from_transport(
        Box::new(Mock(mock.clone())),
        Box::new(Mock(mock.clone())),
        "synthetic",
    );
    reply(
        &mock,
        Command::Negotiate,
        &smb2::msg::negotiate::NegotiateResponse {
            security_mode: smb2::types::flags::SecurityMode::new(0),
            dialect_revision: smb2::types::Dialect::Smb2_0_2,
            server_guid: smb2::pack::Guid::ZERO,
            capabilities: smb2::types::flags::Capabilities::new(0),
            max_transact_size: 65536,
            max_read_size: 65536,
            max_write_size: 65536,
            system_time: 0,
            server_start_time: 0,
            security_buffer: vec![],
            negotiate_contexts: vec![],
        },
    );
    connection.negotiate().await.unwrap();
    mock.clear_sent();
    (connection, mock)
}
pub(crate) fn reply(mock: &MockTransport, command: Command, body: &dyn Pack) {
    let mut header = Header::new_request(command);
    header.flags = HeaderFlags::new(HeaderFlags::SERVER_TO_REDIR);
    header.credits = 8;
    let mut packed = WriteCursor::new();
    header.pack(&mut packed);
    body.pack(&mut packed);
    mock.queue_response(packed.into_inner());
}
pub(crate) struct Empty;
impl Pack for Empty {
    fn pack(&self, _: &mut WriteCursor) {}
}
