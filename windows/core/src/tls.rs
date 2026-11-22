//! TLS 1.2 with the pairing key as pre-shared key, as `SecureTransport.parameters` configures it in
//! `Sources/QuietDeskCore/Transport.swift`: one PSK identity, one AEAD suite, no tickets or resumption.
//! Only this suite is enabled, so a peer without the key cannot complete a handshake in any other way.

use crate::error::{DeskError, Result};
use crate::pairing::PairingKey;
use openssl::error::ErrorStack;
use openssl::ssl::{AlpnError, ErrorCode, Ssl, SslContext, SslContextBuilder, SslMethod, SslOptions, SslSessionCacheMode, SslVersion};
use std::net::SocketAddr;
use std::pin::Pin;
use std::time::Duration;
use tokio::net::{TcpStream, ToSocketAddrs};
use tokio::task::JoinSet;
use tokio_openssl::SslStream;

pub type SecureStream = SslStream<TcpStream>;

const IDENTITY: &[u8] = b"quietdesk-v1";
const CIPHER_SUITE: &str = "PSK-AES128-GCM-SHA256";
/// The role a viewer may name for its control connection; a connection without ALPN is a control connection too.
const CONTROL_PROTOCOL: &[u8] = b"\x13quietdesk-control/1";
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum AuxiliaryRole {
    Video,
    Bulk,
}

impl AuxiliaryRole {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Video => "video",
            Self::Bulk => "bulk",
        }
    }
    fn protocol_list(self) -> &'static [u8] {
        match self {
            Self::Video => b"\x11quietdesk-media/1",
            Self::Bulk => b"\x10quietdesk-bulk/1",
        }
    }
    fn negotiated(self) -> &'static [u8] {
        &self.protocol_list()[1..]
    }
}

pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);

fn context(method: SslMethod) -> std::result::Result<SslContextBuilder, ErrorStack> {
    let mut builder = SslContext::builder(method)?;
    builder.set_min_proto_version(Some(SslVersion::TLS1_2))?;
    builder.set_max_proto_version(Some(SslVersion::TLS1_2))?;
    builder.set_cipher_list(CIPHER_SUITE)?;
    builder.set_options(SslOptions::NO_TICKET);
    builder.set_session_cache_mode(SslSessionCacheMode::OFF);
    Ok(builder)
}

fn configuration_error(error: ErrorStack) -> DeskError {
    DeskError::platform(format!("TLS 配置不可用：{error}"))
}

/// OpenSSL's reason for a peer that closed the connection without a TLS alert.
const UNEXPECTED_EOF_WHILE_READING: i32 = 294;

/// Maps a failed handshake. A peer that answers with an alert, or whose messages fail verification, holds
/// another key or is not QuietDesk. A connection that fails or simply closes says nothing about the key:
/// a host also closes connections it has no room for.
fn handshake_error(error: openssl::ssl::Error) -> DeskError {
    let closed = error.code() == ErrorCode::SYSCALL
        || error.code() == ErrorCode::ZERO_RETURN
        || error.ssl_error().is_some_and(|stack| stack.errors().iter().any(|entry| entry.reason_code() == UNEXPECTED_EOF_WHILE_READING));
    match error.into_io_error() {
        Ok(io) => io.into(),
        Err(_) if closed => DeskError::Network("对方在建立加密连接时断开，可能正忙或已关闭共享".to_string()),
        Err(_) => DeskError::Pairing("TLS 握手失败：配对码不一致，或对端不是 QuietDesk".to_string()),
    }
}

async fn handshake(context: &SslContext, tcp: TcpStream, server: bool) -> Result<SecureStream> {
    tcp.set_nodelay(true)?;
    let ssl = Ssl::new(context).map_err(configuration_error)?;
    let mut stream = SslStream::new(ssl, tcp).map_err(configuration_error)?;
    let exchange = async { if server { Pin::new(&mut stream).accept().await } else { Pin::new(&mut stream).connect().await } };
    match tokio::time::timeout(HANDSHAKE_TIMEOUT, exchange).await {
        Ok(Ok(())) => Ok(stream),
        Ok(Err(error)) => Err(handshake_error(error)),
        Err(_) => Err(DeskError::Network("建立连接超时，请检查地址或远端状态".to_string())),
    }
}

/// Connects to a host and proves knowledge of its pairing key.
pub async fn connect(host: &str, port: u16, key: &PairingKey) -> Result<SecureStream> {
    connect_to((host, port), key, None).await
}

/// Authenticate the same endpoint as the established control socket; an omitted ALPN is not an auxiliary connection.
pub async fn connect_auxiliary(addr: SocketAddr, key: &PairingKey, role: AuxiliaryRole) -> Result<SecureStream> {
    let stream = connect_to(addr, key, Some(role.protocol_list())).await?;
    if stream.ssl().selected_alpn_protocol() != Some(role.negotiated()) {
        return Err(DeskError::invalid("未协商所需的辅助连接角色"));
    }
    Ok(stream)
}

async fn connect_to(addr: impl ToSocketAddrs, key: &PairingKey, protocols: Option<&[u8]>) -> Result<SecureStream> {
    let mut builder = context(SslMethod::tls_client()).map_err(configuration_error)?;
    if let Some(protocols) = protocols {
        builder.set_alpn_protos(protocols).map_err(configuration_error)?;
    }
    let secret = *key.bytes();
    builder.set_psk_client_callback(move |_, _, identity, psk| {
        // OpenSSL sizes both buffers for the largest identity and key it supports.
        identity[..IDENTITY.len()].copy_from_slice(IDENTITY);
        identity[IDENTITY.len()] = 0;
        psk[..secret.len()].copy_from_slice(&secret);
        Ok(secret.len())
    });
    let context = builder.build();
    let tcp = match tokio::time::timeout(HANDSHAKE_TIMEOUT, TcpStream::connect(addr)).await {
        Ok(connected) => connected?,
        Err(_) => return Err(DeskError::Network("建立连接超时，请检查地址或远端状态".to_string())),
    };
    handshake(&context, tcp, false).await
}

/// Accepts desktop connections from viewers that hold the pairing key.
#[derive(Clone)]
pub struct Acceptor {
    context: SslContext,
}

impl Acceptor {
    pub fn new(key: &PairingKey) -> Result<Self> {
        let mut builder = Self::server_context(key)?;
        builder.set_alpn_select_callback(|_, offered| {
            [CONTROL_PROTOCOL, AuxiliaryRole::Video.protocol_list(), AuxiliaryRole::Bulk.protocol_list()]
                .into_iter()
                .find_map(|protocol| openssl::ssl::select_next_proto(protocol, offered))
                .ok_or(AlpnError::ALERT_FATAL)
        });
        Ok(Self { context: builder.build() })
    }

    fn server_context(key: &PairingKey) -> Result<SslContextBuilder> {
        let mut builder = context(SslMethod::tls_server()).map_err(configuration_error)?;
        let secret = *key.bytes();
        builder.set_psk_server_callback(move |_, identity, psk| {
            // Zero tells OpenSSL the identity is unknown; the handshake then fails.
            if identity != Some(IDENTITY) {
                return Ok(0);
            }
            psk[..secret.len()].copy_from_slice(&secret);
            Ok(secret.len())
        });
        Ok(builder)
    }

    pub async fn accept(&self, tcp: TcpStream) -> Result<SecureStream> {
        let (role, stream) = self.accept_role(tcp).await?;
        if role.is_some() {
            return Err(DeskError::invalid("控制连接角色不匹配"));
        }
        Ok(stream)
    }

    pub async fn accept_role(&self, tcp: TcpStream) -> Result<(Option<AuxiliaryRole>, SecureStream)> {
        let stream = handshake(&self.context, tcp, true).await?;
        let role = match stream.ssl().selected_alpn_protocol() {
            None => None,
            Some(protocol) if protocol == &CONTROL_PROTOCOL[1..] => None,
            Some(protocol) => Some(
                [AuxiliaryRole::Video, AuxiliaryRole::Bulk]
                    .into_iter()
                    .find(|role| role.negotiated() == protocol)
                    .ok_or_else(|| DeskError::invalid("不支持的连接角色"))?,
            ),
        };
        Ok((role, stream))
    }
}

/// The handshakes admitted while waiting for a control connection or during one active session.
pub struct PendingHandshakes {
    acceptor: Acceptor,
    attempts: JoinSet<Result<(Option<AuxiliaryRole>, SecureStream)>>,
}

impl PendingHandshakes {
    const LIMIT: usize = 4;
    pub fn new(acceptor: &Acceptor) -> Self {
        Self { acceptor: acceptor.clone(), attempts: JoinSet::new() }
    }

    pub fn start(&mut self, tcp: TcpStream) {
        if self.attempts.len() < Self::LIMIT {
            let acceptor = self.acceptor.clone();
            self.attempts.spawn(async move { acceptor.accept_role(tcp).await });
        }
    }

    pub async fn next(&mut self) -> Result<(Option<AuxiliaryRole>, SecureStream)> {
        if self.attempts.is_empty() {
            return std::future::pending().await;
        }
        self.attempts.join_next().await.expect("the handshake set is nonempty").map_err(|_| DeskError::platform("加密连接握手任务已停止"))?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    async fn pair(server_key: &PairingKey, client_key: &PairingKey) -> (Result<SecureStream>, Result<SecureStream>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let acceptor = Acceptor::new(server_key).unwrap();
        let server = async {
            let (tcp, _) = listener.accept().await.unwrap();
            acceptor.accept(tcp).await
        };
        tokio::join!(server, connect("127.0.0.1", port, client_key))
    }

    #[tokio::test]
    async fn matching_keys_exchange_data_over_the_psk_suite() {
        let key = PairingKey::generate().unwrap();
        let (server, client) = pair(&key, &key).await;
        let (mut server, mut client) = (server.unwrap(), client.unwrap());
        assert_eq!(client.ssl().current_cipher().unwrap().name(), CIPHER_SUITE);
        assert_eq!(client.ssl().version_str(), "TLSv1.2");
        assert_eq!(server.ssl().selected_alpn_protocol(), None);
        client.write_all(b"ping").await.unwrap();
        let mut received = [0u8; 4];
        server.read_exact(&mut received).await.unwrap();
        assert_eq!(&received, b"ping");
    }

    #[tokio::test]
    async fn a_peer_that_closes_during_the_handshake_is_a_network_failure_not_a_pairing_one() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let closing = async { drop(listener.accept().await.unwrap()) };
        let key = PairingKey::generate().unwrap();
        let (_, client) = tokio::join!(closing, connect("127.0.0.1", port, &key));
        assert!(matches!(client, Err(DeskError::Network(_))), "{:?}", client.err());
    }

    #[tokio::test]
    async fn different_keys_fail_as_a_pairing_error_on_both_sides() {
        let (server, client) = pair(&PairingKey::generate().unwrap(), &PairingKey::generate().unwrap()).await;
        assert!(matches!(server, Err(DeskError::Pairing(_))));
        assert!(matches!(client, Err(DeskError::Pairing(_))));
    }

    async fn role_pair(
        acceptor: Acceptor,
        connect: impl AsyncFnOnce(SocketAddr) -> Result<SecureStream>,
    ) -> (Result<(Option<AuxiliaryRole>, SecureStream)>, Result<SecureStream>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let accept = async {
            let (tcp, _) = listener.accept().await.unwrap();
            acceptor.accept_role(tcp).await
        };
        tokio::join!(accept, connect(addr))
    }

    #[tokio::test]
    async fn authenticates_both_auxiliary_roles_and_explicit_control() {
        let key = PairingKey::generate().unwrap();
        for role in [AuxiliaryRole::Video, AuxiliaryRole::Bulk] {
            let (server, client) = role_pair(Acceptor::new(&key).unwrap(), async |addr| connect_auxiliary(addr, &key, role).await).await;
            assert_eq!(server.unwrap().0, Some(role));
            assert_eq!(client.unwrap().ssl().selected_alpn_protocol(), Some(role.negotiated()));
        }
        let (server, client) = role_pair(Acceptor::new(&key).unwrap(), async |addr| connect_to(addr, &key, Some(CONTROL_PROTOCOL)).await).await;
        assert_eq!(server.unwrap().0, None);
        assert_eq!(client.unwrap().ssl().selected_alpn_protocol(), Some(&CONTROL_PROTOCOL[1..]));
    }

    #[tokio::test]
    async fn rejects_mapping_and_unknown_protocols() {
        let key = PairingKey::generate().unwrap();
        for offer in [b"\x13quietdesk-mapping/1".as_slice(), b"\x07unknown"] {
            let (server, client) = role_pair(Acceptor::new(&key).unwrap(), async |addr| connect_to(addr, &key, Some(offer)).await).await;
            assert!(server.is_err() && client.is_err());
        }
    }

    #[tokio::test]
    async fn an_unnegotiated_auxiliary_connection_never_becomes_control_on_the_viewer() {
        let key = PairingKey::generate().unwrap();
        let legacy = Acceptor { context: Acceptor::server_context(&key).unwrap().build() };
        let (server, client) = role_pair(legacy, async |addr| connect_auxiliary(addr, &key, AuxiliaryRole::Video).await).await;
        assert_eq!(server.unwrap().0, None);
        assert!(matches!(client, Err(DeskError::Invalid(_))));
    }

    #[tokio::test]
    async fn excess_and_previous_generation_handshakes_close_without_blocking_the_listener() {
        let key = PairingKey::generate().unwrap();
        let mut pending = PendingHandshakes::new(&Acceptor::new(&key).unwrap());
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut clients = Vec::new();
        for _ in 0..=PendingHandshakes::LIMIT {
            clients.push(TcpStream::connect(listener.local_addr().unwrap()).await.unwrap());
            pending.start(listener.accept().await.unwrap().0);
        }
        assert_eq!(clients.pop().unwrap().read(&mut [0u8; 1]).await.unwrap(), 0);
        drop(pending);
        for mut client in clients {
            assert_eq!(client.read(&mut [0u8; 1]).await.unwrap(), 0);
        }
    }
}
