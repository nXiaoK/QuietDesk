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
    let dummy = UdpSocket::bind(loopback()).await.unwrap();
    let sender = viewer(dummy.local_addr().unwrap(), key, id).unwrap();
    let mut buffer = [0; WIRE_LIMIT];
    let (length, _) = timeout(Duration::from_secs(1), dummy.recv_from(&mut buffer)).await.unwrap().unwrap();
    drop(sender);
    let hello = buffer[..length].to_vec();
    let mut candidates = Vec::new();
    for index in 0..3 {
        let candidate = UdpSocket::bind(loopback()).await.unwrap();
        candidate.send_to(&hello, addr).await.unwrap();
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
