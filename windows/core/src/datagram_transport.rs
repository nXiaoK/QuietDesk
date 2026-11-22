//! One control session's DTLS listener or client, with one application message per UDP datagram.
use crate::error::{DeskError, Result};
use foreign_types::ForeignTypeRef;
use openssl::error::ErrorStack;
use openssl::ex_data::Index;
use openssl::ssl::{ErrorCode, Ssl, SslContext, SslMethod, SslOptions, SslSessionCacheMode, SslStream, SslVersion};
use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::{Instant, timeout_at};
use uuid::Uuid;

pub const MAX_DATAGRAM: usize = 1 + crate::media::fragment::MAX_RECORD_BYTES;
const WIRE_LIMIT: usize = 2048;
const LINK_MTU: u32 = 1200;
const QUEUE: usize = 128;
const AUDIO_BACKLOG: usize = 5;
const HANDSHAKE: Duration = Duration::from_secs(2);
const MAX_CANDIDATES: usize = 4;

pub enum DatagramEvent {
    Ready,
    Data(Vec<u8>),
    Closed,
}

pub struct DatagramTransport {
    events: mpsc::Receiver<DatagramEvent>,
    sender: DatagramSender,
    task: JoinHandle<()>,
}

impl DatagramTransport {
    pub async fn next(&mut self) -> DatagramEvent {
        self.events.recv().await.unwrap_or(DatagramEvent::Closed)
    }

    pub(crate) fn sender(&self) -> DatagramSender {
        self.sender.clone()
    }

    pub fn try_send(&self, data: Vec<u8>) -> bool {
        self.sender.try_send(data)
    }
}

#[derive(Clone)]
pub(crate) struct DatagramSender {
    outgoing: mpsc::Sender<Box<[u8]>>,
    ready: Arc<AtomicBool>,
}

impl DatagramSender {
    pub(crate) fn authenticated(&self) -> bool {
        self.ready.load(Ordering::Acquire) && !self.outgoing.is_closed()
    }

    /// Returns true for an enqueued application datagram.
    pub(crate) fn try_send(&self, data: Vec<u8>) -> bool {
        // Five 20 ms packets already span the playback queue. Skip audio while the socket is this far behind.
        if data.first() == Some(&crate::audio::DATAGRAM_KIND) && self.outgoing.max_capacity() - self.outgoing.capacity() >= AUDIO_BACKLOG {
            return false;
        }
        self.authenticated() && (1..=MAX_DATAGRAM).contains(&data.len()) && self.outgoing.try_send(data.into_boxed_slice()).is_ok()
    }
}

impl Drop for DatagramTransport {
    fn drop(&mut self) {
        self.sender.ready.store(false, Ordering::Release);
        self.task.abort();
    }
}

pub fn host(local: SocketAddr, key: [u8; 32], id: Uuid) -> Result<DatagramTransport> {
    start(local, None, key, id)
}

pub fn viewer(remote: SocketAddr, key: [u8; 32], id: Uuid) -> Result<DatagramTransport> {
    let any = if remote.is_ipv4() { IpAddr::V4(Ipv4Addr::UNSPECIFIED) } else { IpAddr::V6(Ipv6Addr::UNSPECIFIED) };
    start(SocketAddr::new(any, 0), Some(remote), key, id)
}

fn start(local: SocketAddr, remote: Option<SocketAddr>, key: [u8; 32], id: Uuid) -> Result<DatagramTransport> {
    let context = context(remote.is_none(), key, id).map_err(|_| DeskError::platform("无法配置媒体 DTLS"))?;
    let socket = std::net::UdpSocket::bind(local)?;
    socket.set_nonblocking(true)?;
    let socket = UdpSocket::from_std(socket)?;
    let (events, received) = mpsc::channel(QUEUE);
    let (outgoing, send) = mpsc::channel(QUEUE);
    let ready = Arc::new(AtomicBool::new(false));
    let run_state = ready.clone();
    let task = tokio::spawn(async move {
        run(socket, context, remote, &events, send, &run_state).await;
        run_state.store(false, Ordering::Release);
    });
    Ok(DatagramTransport { events: received, sender: DatagramSender { outgoing, ready }, task })
}

fn context(server: bool, key: [u8; 32], id: Uuid) -> std::result::Result<SslContext, openssl::error::ErrorStack> {
    let method = if server { SslMethod::dtls_server() } else { SslMethod::dtls_client() };
    let mut builder = SslContext::builder(method)?;
    builder.set_min_proto_version(Some(SslVersion::DTLS1_2))?;
    builder.set_max_proto_version(Some(SslVersion::DTLS1_2))?;
    builder.set_cipher_list("PSK-AES128-GCM-SHA256")?;
    builder.set_options(SslOptions::NO_TICKET | SslOptions::NO_QUERY_MTU | SslOptions::NO_RENEGOTIATION);
    builder.set_session_cache_mode(SslSessionCacheMode::OFF);
    let identity = id.hyphenated().encode_upper(&mut Uuid::encode_buffer()).as_bytes().to_owned();
    if server {
        type CookieSlot = std::result::Result<Index<Ssl, [u8; 16]>, ErrorStack>;
        static SLOT: OnceLock<CookieSlot> = OnceLock::new();
        let slot = SLOT.get_or_init(Ssl::new_ex_index).clone()?;
        builder.set_options(SslOptions::COOKIE_EXCHANGE);
        builder.set_cookie_generate_cb(move |ssl, dest| {
            if ssl.ex_data(slot).is_none() {
                let mut cookie = [0; 16];
                openssl::rand::rand_bytes(&mut cookie)?;
                ssl.set_ex_data(slot, cookie);
            }
            let cookie = ssl.ex_data(slot).expect("the cookie belongs to this source's SSL object");
            dest[..cookie.len()].copy_from_slice(cookie);
            Ok(cookie.len())
        });
        builder.set_cookie_verify_cb(move |ssl, offered| {
            ssl.ex_data(slot).is_some_and(|cookie| offered.len() == cookie.len() && openssl::memcmp::eq(offered, cookie))
        });
        builder.set_psk_server_callback(move |_, offered, psk| {
            if offered != Some(&identity) || psk.len() < key.len() {
                return Ok(0);
            }
            psk[..key.len()].copy_from_slice(&key);
            Ok(key.len())
        });
    } else {
        builder.set_psk_client_callback(move |_, _, name, psk| {
            if name.len() <= identity.len() || psk.len() < key.len() {
                return Ok(0);
            }
            name[..identity.len()].copy_from_slice(&identity);
            name[identity.len()] = 0;
            psk[..key.len()].copy_from_slice(&key);
            Ok(key.len())
        });
    }
    Ok(builder.build())
}

#[derive(Default)]
struct Wire {
    received: Vec<u8>,
    flight: VecDeque<Vec<u8>>,
}

impl Read for Wire {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if self.received.is_empty() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        let len = self.received.len();
        let dest = output.get_mut(..len).ok_or(io::ErrorKind::InvalidData)?;
        dest.copy_from_slice(&self.received);
        self.received.clear();
        Ok(len)
    }
}

impl Write for Wire {
    fn write(&mut self, packet: &[u8]) -> io::Result<usize> {
        if packet.is_empty() || packet.len() > WIRE_LIMIT || self.flight.len() >= 16 {
            return Err(io::ErrorKind::InvalidData.into());
        }
        self.flight.push_back(packet.to_vec());
        Ok(packet.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct Peer {
    addr: SocketAddr,
    ssl: SslStream<Wire>,
    expires: Instant,
    timer: Option<Instant>,
    authenticated: bool,
}

fn wants_io(e: &openssl::ssl::Error) -> bool {
    matches!(e.code(), ErrorCode::WANT_READ | ErrorCode::WANT_WRITE)
}

impl Peer {
    fn new(addr: SocketAddr, ctx: &SslContext, server: bool) -> Option<Self> {
        let mut ssl = Ssl::new(ctx).ok()?;
        ssl.set_mtu(LINK_MTU).ok()?;
        if server {
            ssl.set_accept_state();
        } else {
            ssl.set_connect_state();
        }
        Some(Self { addr, ssl: SslStream::new(ssl, Wire::default()).ok()?, expires: Instant::now() + HANDSHAKE, timer: None, authenticated: false })
    }

    fn deadline(&self) -> Option<Instant> {
        if self.authenticated { self.timer } else { Some(self.timer.map_or(self.expires, |t| t.min(self.expires))) }
    }

    fn refresh_timer(&mut self) -> Option<()> {
        // The vendored OpenSSL exposes its own next DTLS retransmission deadline since version 3.2.
        let mut tv = std::mem::MaybeUninit::uninit();
        let mut infinite = 0;
        if unsafe { openssl_sys::SSL_get_event_timeout(self.ssl.ssl().as_ptr(), tv.as_mut_ptr(), &mut infinite) } != 1 {
            return None;
        }
        self.timer = if infinite != 0 {
            None
        } else {
            let tv = unsafe { tv.assume_init() };
            let delay = Duration::from_secs(tv.tv_sec.try_into().ok()?) + Duration::from_micros(tv.tv_usec.try_into().ok()?);
            Some(Instant::now().checked_add(delay)?)
        };
        Some(())
    }

    async fn flush(&mut self, socket: &UdpSocket) -> Option<()> {
        let deadline = Instant::now() + Duration::from_millis(20);
        while let Some(packet) = self.ssl.get_mut().flight.pop_front() {
            let len = timeout_at(deadline, socket.send_to(&packet, self.addr)).await.ok()?.ok()?;
            if len != packet.len() {
                return None;
            }
        }
        Some(())
    }

    async fn advance(&mut self, socket: &UdpSocket, events: &mpsc::Sender<DatagramEvent>, ready: &AtomicBool) -> Option<()> {
        let now = Instant::now();
        if !self.authenticated && now >= self.expires {
            return None;
        }
        if self.timer.is_some_and(|at| at <= now) && unsafe { openssl_sys::SSL_handle_events(self.ssl.ssl().as_ptr()) } != 1 {
            return None;
        }
        if !self.authenticated {
            match self.ssl.do_handshake() {
                Ok(()) => {
                    self.flush(socket).await?;
                    self.authenticated = true;
                    ready.store(true, Ordering::Release);
                    events.try_send(DatagramEvent::Ready).ok()?;
                }
                Err(e) if wants_io(&e) => {
                    self.flush(socket).await?;
                    return self.refresh_timer();
                }
                Err(_) => return None,
            }
        }
        let mut plain = [0; MAX_DATAGRAM + 1];
        loop {
            match self.ssl.ssl_read(&mut plain) {
                Ok(n) if (1..=MAX_DATAGRAM).contains(&n) => {
                    // A full media queue drops this UDP message. The control socket has its own budget.
                    let _ = events.try_send(DatagramEvent::Data(plain[..n].to_vec()));
                }
                Err(e) if wants_io(&e) => break,
                _ => return None,
            }
        }
        self.flush(socket).await?;
        self.refresh_timer()
    }
}

// Only a DTLS ClientHello can allocate a server-side SSL object. OpenSSL verifies its contents and the PSK.
fn initial_hello(packet: &[u8]) -> bool {
    packet.len() >= 25 && packet[0] == 22 && packet[1] == 0xfe && matches!(packet[2], 0xfd | 0xff) && packet[3..5] == [0, 0] && packet[13] == 1
}

async fn run(
    socket: UdpSocket,
    context: SslContext,
    remote: Option<SocketAddr>,
    events: &mpsc::Sender<DatagramEvent>,
    mut outgoing: mpsc::Receiver<Box<[u8]>>,
    ready: &AtomicBool,
) {
    let mut peers = Vec::with_capacity(MAX_CANDIDATES);
    if let Some(addr) = remote {
        let Some(mut first) = Peer::new(addr, &context, false) else { return };
        if first.advance(&socket, events, ready).await.is_none() {
            return;
        }
        peers.push(first);
    }
    // A full-sized receive buffer distinguishes an oversized UDP message from a truncated valid one on WinSock.
    let mut wire = vec![0; u16::MAX as usize + 1];
    let mut admissions = VecDeque::<(Instant, IpAddr)>::new();
    loop {
        let next = peers.iter().filter_map(Peer::deadline).min();
        let index = tokio::select! {
            datagram = socket.recv_from(&mut wire) => {
                let (len, addr) = match datagram {
                    Ok((len, addr)) if (1..=WIRE_LIMIT).contains(&len) => (len, addr),
                    Ok(_) => continue,
                    Err(error) if remote.is_none() && matches!(error.kind(), io::ErrorKind::ConnectionRefused | io::ErrorKind::ConnectionReset) => continue,
                    Err(_) => return,
                };
                let index = if let Some(i) = peers.iter().position(|p| p.addr == addr) { i } else {
                    if remote.is_some() || ready.load(Ordering::Acquire) || peers.len() >= MAX_CANDIDATES || !initial_hello(&wire[..len]) { continue; }
                    let now = Instant::now();
                    while admissions.front().is_some_and(|(time, _)| now.duration_since(*time) >= Duration::from_secs(1)) { admissions.pop_front(); }
                    if admissions.len() >= 16 || admissions.iter().filter(|(_, ip)| *ip == addr.ip()).count() >= 4 ||
                        peers.iter().filter(|p| p.addr.ip() == addr.ip()).count() >= 2 { continue; }
                    admissions.push_back((now, addr.ip()));
                    let Some(peer) = Peer::new(addr, &context, true) else { continue };
                    peers.push(peer);
                    peers.len() - 1
                };
                let received = &mut peers[index].ssl.get_mut().received;
                received.clear();
                received.extend_from_slice(&wire[..len]);
                index
            }
            _ = async {
                match next { Some(at) => tokio::time::sleep_until(at).await, None => std::future::pending().await }
            } => {
                let Some(index) = peers.iter().position(|p| p.deadline().is_some_and(|at| at <= Instant::now())) else { continue };
                index
            }
            packet = outgoing.recv() => {
                let Some(packet) = packet else { return };
                let Some(peer) = peers.first_mut().filter(|p| p.authenticated) else { continue };
                if peer.ssl.ssl_write(&packet).ok() != Some(packet.len()) || peer.flush(&socket).await.is_none() { return; }
                if peer.refresh_timer().is_none() { return; }
                continue;
            }
        };
        let previously_ready = peers[index].authenticated;
        if peers[index].advance(&socket, events, ready).await.is_none() {
            if remote.is_some() || peers[index].authenticated {
                return;
            }
            peers.swap_remove(index);
        } else if !previously_ready && peers[index].authenticated {
            let active = peers.swap_remove(index);
            peers.clear();
            peers.push(active);
        }
    }
}

#[cfg(test)]
mod tests;
