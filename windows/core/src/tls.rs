//! TLS 1.2 with the pairing key as pre-shared key, as `SecureTransport.parameters` configures it in
//! `Sources/QuietDeskCore/Transport.swift`: one PSK identity, one AEAD suite, no tickets or resumption.
//! Only this suite is enabled, so a peer without the key cannot complete a handshake in any other way.

use crate::error::{DeskError, Result};
use crate::pairing::PairingKey;
use openssl::error::ErrorStack;
use openssl::ssl::{AlpnError, ErrorCode, Ssl, SslContext, SslContextBuilder, SslMethod, SslOptions, SslSessionCacheMode, SslVersion};
use std::pin::Pin;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio_openssl::SslStream;

pub type SecureStream = SslStream<TcpStream>;

const IDENTITY: &[u8] = b"quietdesk-v1";
const CIPHER_SUITE: &str = "PSK-AES128-GCM-SHA256";
/// The role a viewer may name for its control connection; a connection without ALPN is a control connection too.
const CONTROL_PROTOCOL: &[u8] = b"\x13quietdesk-control/1";
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
    let mut builder = context(SslMethod::tls_client()).map_err(configuration_error)?;
    let secret = *key.bytes();
    builder.set_psk_client_callback(move |_, _, identity, psk| {
        // OpenSSL sizes both buffers for the largest identity and key it supports.
        identity[..IDENTITY.len()].copy_from_slice(IDENTITY);
        identity[IDENTITY.len()] = 0;
        psk[..secret.len()].copy_from_slice(&secret);
        Ok(secret.len())
    });
    let context = builder.build();
    let tcp = match tokio::time::timeout(HANDSHAKE_TIMEOUT, TcpStream::connect((host, port))).await {
        Ok(connected) => connected?,
        Err(_) => return Err(DeskError::Network("建立连接超时，请检查地址或远端状态".to_string())),
    };
    handshake(&context, tcp, false).await
}

/// Accepts control connections from viewers that hold the pairing key.
pub struct Acceptor {
    context: SslContext,
}

impl Acceptor {
    pub fn new(key: &PairingKey) -> Result<Self> {
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
        // A viewer that names roles for its connection must include the control role; the video, bulk and
        // port-mapping roles of the macOS host have no counterpart here.
        builder.set_alpn_select_callback(|_, offered| openssl::ssl::select_next_proto(CONTROL_PROTOCOL, offered).ok_or(AlpnError::ALERT_FATAL));
        Ok(Self { context: builder.build() })
    }

    pub async fn accept(&self, tcp: TcpStream) -> Result<SecureStream> {
        handshake(&self.context, tcp, true).await
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
}
