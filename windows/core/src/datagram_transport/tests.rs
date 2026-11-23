use super::*;
use tokio::time::timeout;

fn loopback() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

async fn connected(server: &mut DatagramTransport, client: &mut DatagramTransport) {
    let (a, b) = timeout(Duration::from_secs(3), async { tokio::join!(server.next(), client.next()) }).await.unwrap();
    assert!(matches!((a, b), (DatagramEvent::Ready, DatagramEvent::Ready)));
}

#[tokio::test]
async fn authenticates_the_session_and_preserves_datagrams_on_the_original_listener() {
    let addr = std::net::UdpSocket::bind(loopback()).unwrap().local_addr().unwrap();
    let mut key = [0; 32];
    openssl::rand::rand_bytes(&mut key).unwrap();
    let id = Uuid::new_v4();
    let mut server = host(addr, key, id).unwrap();
    assert!(host(addr, key, id).is_err());
    assert!(!server.try_send(vec![1; 1024]));

    let mut wrong_key = key;
    wrong_key[0] ^= 1;
    for (secret, identity) in [(wrong_key, id), (key, Uuid::new_v4())] {
        let mut rejected = viewer(addr, secret, identity).unwrap();
        assert!(matches!(timeout(HANDSHAKE + Duration::from_secs(1), rejected.next()).await.unwrap(), DatagramEvent::Closed));
    }
    let mut client = viewer(addr, key, id).unwrap();
    connected(&mut server, &mut client).await;
    assert!(!server.try_send(vec![]));
    assert!(!server.try_send(vec![3; MAX_DATAGRAM + 1]));
    for n in [19, MAX_DATAGRAM, 37] {
        assert!(server.try_send(vec![n as u8; n]));
    }
    for n in [19, MAX_DATAGRAM, 37] {
        let DatagramEvent::Data(msg) = timeout(Duration::from_secs(1), client.next()).await.unwrap() else {
            panic!("missing datagram");
        };
        assert_eq!(msg, vec![n as u8; n]);
    }
    drop(server);
    timeout(Duration::from_millis(500), async {
        loop {
            if std::net::UdpSocket::bind(addr).is_ok() {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn unverified_sources_have_bounded_slots_and_absolute_deadlines() {
    let addr = std::net::UdpSocket::bind(loopback()).unwrap().local_addr().unwrap();
    let mut key = [0; 32];
    openssl::rand::rand_bytes(&mut key).unwrap();
    let id = Uuid::new_v4();
    let mut server = host(addr, key, id).unwrap();
    let client_ctx = context(false, key, id, Arc::new(Mutex::new(None))).unwrap();
    let mut buffer = [0; WIRE_LIMIT];
    let mut candidates = Vec::new();
    for index in 0..3 {
        let candidate = UdpSocket::bind(loopback()).await.unwrap();
        let mut peer = Peer::new(addr, &client_ctx, false).unwrap();
        // Send bare ClientHello, receive stateless HelloVerifyRequest, then stop after sending cookie ClientHello.
        let Err(_) = peer.ssl.do_handshake() else { panic!("expected WANT_READ") };
        let hello = peer.ssl.get_mut().flight.pop_front().unwrap();
        candidate.send_to(&hello, addr).await.unwrap();
        let (hvr_len, _) = timeout(Duration::from_secs(1), candidate.recv_from(&mut buffer)).await.unwrap().unwrap();
        peer.ssl.get_mut().received.extend_from_slice(&buffer[..hvr_len]);
        let Err(_) = peer.ssl.do_handshake() else { panic!("expected WANT_READ after cookie") };
        let verified_hello = peer.ssl.get_mut().flight.pop_front().unwrap();
        candidate.send_to(&verified_hello, addr).await.unwrap();

        let wait = if index < 2 { Duration::from_secs(1) } else { Duration::from_millis(150) };
        let reply = timeout(wait, candidate.recv_from(&mut buffer)).await;
        assert_eq!(reply.is_ok(), index < 2);
        candidates.push(candidate);
    }
    tokio::time::sleep(HANDSHAKE).await;
    let mut client = viewer(addr, key, id).unwrap();
    connected(&mut server, &mut client).await;
}

#[tokio::test]
async fn the_authenticated_endpoint_remains_bound_for_the_session() {
    let addr = std::net::UdpSocket::bind(loopback()).unwrap().local_addr().unwrap();
    let mut key = [0; 32];
    openssl::rand::rand_bytes(&mut key).unwrap();
    let id = Uuid::new_v4();
    let mut server = host(addr, key, id).unwrap();
    let mut first = viewer(addr, key, id).unwrap();
    connected(&mut server, &mut first).await;
    let mut second = viewer(addr, key, id).unwrap();
    assert!(matches!(timeout(HANDSHAKE + Duration::from_secs(1), second.next()).await.unwrap(), DatagramEvent::Closed));
    assert!(first.try_send(vec![6, 24]));
    assert!(matches!(timeout(Duration::from_secs(1), server.next()).await.unwrap(), DatagramEvent::Data(bytes) if bytes == [6, 24]));
}

#[test]
fn congested_application_datagrams_do_not_accumulate_old_audio() {
    let (outgoing, mut drain) = mpsc::channel(QUEUE);
    let sender = DatagramSender { outgoing, ready: Arc::new(AtomicBool::new(true)) };
    for _ in 0..AUDIO_BACKLOG {
        assert!(sender.try_send(vec![crate::audio::DATAGRAM_KIND]));
    }
    assert!(!sender.try_send(vec![crate::audio::DATAGRAM_KIND]));
    assert!(sender.try_send(vec![2]));
    drain.try_recv().unwrap();
    drain.try_recv().unwrap();
    assert!(sender.try_send(vec![crate::audio::DATAGRAM_KIND]));
}

#[tokio::test]
async fn spoofed_client_hellos_cannot_starve_a_real_viewer_handshake() {
    let addr = std::net::UdpSocket::bind(loopback()).unwrap().local_addr().unwrap();
    let mut key = [0; 32];
    openssl::rand::rand_bytes(&mut key).unwrap();
    let id = Uuid::new_v4();
    let mut server = host(addr, key, id).unwrap();

    // Capture a bare ClientHello without continuing the DTLS handshake.
    let dummy = UdpSocket::bind(loopback()).await.unwrap();
    let probe = viewer(dummy.local_addr().unwrap(), key, id).unwrap();
    let mut buffer = [0; WIRE_LIMIT];
    let (length, _) = timeout(Duration::from_secs(1), dummy.recv_from(&mut buffer)).await.unwrap().unwrap();
    drop(probe);
    let bare_hello = buffer[..length].to_vec();

    let stop = Arc::new(AtomicBool::new(false));
    let mut floods = Vec::new();
    for _ in 0..6 {
        let sock = UdpSocket::bind(loopback()).await.unwrap();
        let flag = stop.clone();
        let pkt = bare_hello.clone();
        floods.push(tokio::spawn(async move {
            while !flag.load(Ordering::Relaxed) {
                let _ = sock.send_to(&pkt, addr).await;
                tokio::time::sleep(Duration::from_millis(30)).await;
            }
        }));
    }

    tokio::time::sleep(Duration::from_millis(120)).await;
    let mut client = viewer(addr, key, id).unwrap();
    let result = timeout(Duration::from_millis(1500), async { tokio::join!(server.next(), client.next()) }).await;
    stop.store(true, Ordering::Relaxed);
    for task in floods {
        let _ = task.await;
    }
    let (a, b) = result.expect("real viewer was starved by spoofed unverified ClientHellos");
    assert!(matches!((a, b), (DatagramEvent::Ready, DatagramEvent::Ready)));
}

struct TransientUnreachableSocket {
    inner: UdpSocket,
    recv_calls: std::sync::atomic::AtomicUsize,
}

impl PacketSocket for TransientUnreachableSocket {
    async fn recv_from(&self, buf: &mut [u8]) -> io::Result<(usize, SocketAddr)> {
        match self.recv_calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst) {
            0 => Err(io::Error::from(io::ErrorKind::ConnectionReset)),
            1 => Err(io::Error::from(io::ErrorKind::ConnectionRefused)),
            _ => self.inner.recv_from(buf).await,
        }
    }

    async fn send_to(&self, buf: &[u8], target: SocketAddr) -> io::Result<usize> {
        self.inner.send_to(buf, target).await
    }
}

struct FatalRecvSocket {
    inner: UdpSocket,
    recv_calls: Arc<std::sync::atomic::AtomicUsize>,
}

impl PacketSocket for FatalRecvSocket {
    async fn recv_from(&self, _buf: &mut [u8]) -> io::Result<(usize, SocketAddr)> {
        self.recv_calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Err(io::Error::other("injected socket fault"))
    }

    async fn send_to(&self, buf: &[u8], target: SocketAddr) -> io::Result<usize> {
        self.inner.send_to(buf, target).await
    }
}

#[tokio::test]
async fn viewer_ignores_transient_icmp_unreachable_and_closes_on_fatal_socket_error() {
    let addr = std::net::UdpSocket::bind(loopback()).unwrap().local_addr().unwrap();
    let mut key = [0; 32];
    openssl::rand::rand_bytes(&mut key).unwrap();
    let id = Uuid::new_v4();
    let mut server = host(addr, key, id).unwrap();

    let inner = UdpSocket::bind(loopback()).await.unwrap();
    let faulty = TransientUnreachableSocket { inner, recv_calls: std::sync::atomic::AtomicUsize::new(0) };
    let mut client = start_with_socket(faulty, Some(addr), key, id).unwrap();
    let (a, b) = timeout(Duration::from_secs(3), async { tokio::join!(server.next(), client.next()) }).await.unwrap();
    assert!(matches!((a, b), (DatagramEvent::Ready, DatagramEvent::Ready)));
    assert!(client.try_send(vec![9, 42]));
    assert!(matches!(timeout(Duration::from_secs(1), server.next()).await.unwrap(), DatagramEvent::Data(bytes) if bytes == [9, 42]));

    let fatal_calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let fatal_socket = FatalRecvSocket { inner: UdpSocket::bind(loopback()).await.unwrap(), recv_calls: fatal_calls.clone() };
    let mut fatal_client = start_with_socket(fatal_socket, Some(addr), key, id).unwrap();
    assert!(matches!(timeout(Duration::from_millis(500), fatal_client.next()).await.unwrap(), DatagramEvent::Closed));
    assert_eq!(fatal_calls.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[tokio::test]
async fn viewer_completes_handshake_when_host_binds_after_initial_client_hello() {
    let mut key = [0; 32];
    openssl::rand::rand_bytes(&mut key).unwrap();
    let id = Uuid::new_v4();
    let mut completed = false;
    for _ in 0..3 {
        let addr = std::net::UdpSocket::bind(loopback()).unwrap().local_addr().unwrap();
        let mut client = viewer(addr, key, id).unwrap();
        tokio::time::sleep(Duration::from_millis(350)).await;
        let Ok(mut server) = host(addr, key, id) else {
            continue;
        };
        let (a, b) = timeout(Duration::from_millis(2500), async { tokio::join!(server.next(), client.next()) }).await.unwrap();
        assert!(matches!((a, b), (DatagramEvent::Ready, DatagramEvent::Ready)));
        assert!(client.try_send(vec![7, 19]));
        assert!(matches!(timeout(Duration::from_secs(1), server.next()).await.unwrap(), DatagramEvent::Data(bytes) if bytes == [7, 19]));
        completed = true;
        break;
    }
    assert!(completed, "could not bind test listener after transient delay");
}

struct StallingSendSocket {
    inner: UdpSocket,
    stall_remaining: Arc<std::sync::atomic::AtomicUsize>,
}

impl PacketSocket for StallingSendSocket {
    async fn recv_from(&self, buf: &mut [u8]) -> io::Result<(usize, SocketAddr)> {
        self.inner.recv_from(buf).await
    }

    async fn send_to(&self, buf: &[u8], target: SocketAddr) -> io::Result<usize> {
        if self.stall_remaining.try_update(Ordering::SeqCst, Ordering::SeqCst, |v| v.checked_sub(1)).is_ok() {
            std::future::pending::<()>().await;
        }
        self.inner.send_to(buf, target).await
    }
}

struct FailingSendSocket {
    inner: UdpSocket,
    fail_sends: Arc<AtomicBool>,
}

impl PacketSocket for FailingSendSocket {
    async fn recv_from(&self, buf: &mut [u8]) -> io::Result<(usize, SocketAddr)> {
        self.inner.recv_from(buf).await
    }

    async fn send_to(&self, buf: &[u8], target: SocketAddr) -> io::Result<usize> {
        if self.fail_sends.load(Ordering::SeqCst) {
            return Err(io::Error::other("injected send fault"));
        }
        self.inner.send_to(buf, target).await
    }
}

#[tokio::test]
async fn send_timeout_drops_stalled_flight_without_closing_the_channel() {
    let addr = std::net::UdpSocket::bind(loopback()).unwrap().local_addr().unwrap();
    let mut key = [0; 32];
    openssl::rand::rand_bytes(&mut key).unwrap();
    let id = Uuid::new_v4();
    let mut server = host(addr, key, id).unwrap();

    let stall_remaining = Arc::new(std::sync::atomic::AtomicUsize::new(1));
    let stalling_socket = StallingSendSocket { inner: UdpSocket::bind(loopback()).await.unwrap(), stall_remaining: stall_remaining.clone() };
    let mut client = start_with_socket(stalling_socket, Some(addr), key, id).unwrap();
    let (a, b) = timeout(Duration::from_secs(3), async { tokio::join!(server.next(), client.next()) }).await.unwrap();
    assert!(matches!((a, b), (DatagramEvent::Ready, DatagramEvent::Ready)));

    // Trigger a send timeout on an application datagram, then verify subsequent traffic still arrives.
    stall_remaining.store(1, Ordering::SeqCst);
    assert!(client.try_send(vec![1, 2, 3]));
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(client.try_send(vec![9, 8, 7]));
    assert!(matches!(timeout(Duration::from_secs(1), server.next()).await.unwrap(), DatagramEvent::Data(bytes) if bytes == [9, 8, 7]));

    // A genuine send io::Error must still close the channel.
    let addr2 = std::net::UdpSocket::bind(loopback()).unwrap().local_addr().unwrap();
    let mut server2 = host(addr2, key, id).unwrap();
    let fail_sends = Arc::new(AtomicBool::new(false));
    let failing_socket = FailingSendSocket { inner: UdpSocket::bind(loopback()).await.unwrap(), fail_sends: fail_sends.clone() };
    let mut failing_client = start_with_socket(failing_socket, Some(addr2), key, id).unwrap();
    connected(&mut server2, &mut failing_client).await;
    fail_sends.store(true, Ordering::SeqCst);
    assert!(failing_client.try_send(vec![4, 5, 6]));
    assert!(matches!(timeout(Duration::from_millis(500), failing_client.next()).await.unwrap(), DatagramEvent::Closed));
}
