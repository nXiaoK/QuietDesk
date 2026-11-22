use super::*;
use crate::media::{HostMedia, HostMediaEvent, ViewerMedia};
use tokio::io::AsyncReadExt;
use tokio::net::TcpListener;

fn offer() -> MediaControl {
    let mut host = HostMedia::default();
    let Some(HostMediaEvent::Send(offer)) = host.control(&ViewerMedia::request(), false).unwrap().pop() else { panic!("missing offer") };
    *offer
}

fn binding(offer: &MediaControl, operation: MediaOperation, role: AuxiliaryRole) -> MediaControl {
    MediaControl::binding(operation, offer.session_id.unwrap(), offer.token.as_deref().unwrap().try_into().unwrap(), role.as_str())
}

fn host_with_offer() -> (Auxiliary, mpsc::Sender<(AuxiliaryRole, SecureStream)>, MediaControl) {
    let (tx, rx) = mpsc::channel(8);
    let mut host = Auxiliary::host(Some(rx));
    let offer = offer();
    host.offer(&offer);
    (host, tx, offer)
}

#[tokio::test(start_paused = true)]
async fn a_grant_accepts_each_role_once_through_its_expiry_and_repeated_offers_do_not_extend_it() {
    let (mut host, _incoming, offer) = host_with_offer();
    let start = Instant::now();
    tokio::time::advance(Duration::from_secs(10)).await;
    host.offer(&offer);
    let grant = host.grant.as_mut().unwrap();
    assert_eq!(grant.expires, start + Duration::from_secs(15));
    let video = binding(&offer, MediaOperation::Bind, AuxiliaryRole::Video);
    let bulk = binding(&offer, MediaOperation::Bind, AuxiliaryRole::Bulk);
    assert!(grant.consume(AuxiliaryRole::Video, &video, start, MediaOperation::Bind));
    assert!(!grant.consume(AuxiliaryRole::Video, &video, start, MediaOperation::Bind));
    assert!(!grant.consume(AuxiliaryRole::Bulk, &bulk, grant.expires + Duration::from_nanos(1), MediaOperation::Bind));
    assert!(grant.consume(AuxiliaryRole::Bulk, &bulk, grant.expires, MediaOperation::Bind));
}

#[test]
fn mismatched_session_role_operation_or_token_cannot_consume_a_role() {
    let (mut host, _incoming, offer) = host_with_offer();
    let grant = host.grant.as_mut().unwrap();
    let now = Instant::now();
    let valid = binding(&offer, MediaOperation::Bind, AuxiliaryRole::Video);
    let accepted = |candidate: &MediaControl, grant: &mut Grant| grant.consume(AuxiliaryRole::Video, candidate, now, MediaOperation::Bind);
    let mut other_session = valid.clone();
    other_session.session_id = Some(Uuid::new_v4());
    assert!(!accepted(&other_session, grant));
    assert!(!accepted(&binding(&offer, MediaOperation::Bind, AuxiliaryRole::Bulk), grant));
    assert!(!accepted(&binding(&offer, MediaOperation::Bound, AuxiliaryRole::Video), grant));
    for i in 0..32 {
        let mut altered = valid.clone();
        altered.token.as_mut().unwrap()[i] ^= 1;
        assert!(!accepted(&altered, grant));
    }
    let mut truncated = valid.clone();
    truncated.token.as_mut().unwrap().pop();
    assert!(!accepted(&truncated, grant));
    assert!(accepted(&valid, grant));
}

#[test]
fn a_matching_confirmation_may_arrive_after_the_host_accepted_the_bind_at_its_deadline() {
    let (mut viewer, _incoming, offer) = host_with_offer();
    let grant = viewer.grant.as_mut().unwrap();
    let delivered = grant.expires + Duration::from_millis(1);
    let request = binding(&offer, MediaOperation::Bind, AuxiliaryRole::Video);
    assert!(!grant.consume(AuxiliaryRole::Video, &request, delivered, MediaOperation::Bound));
    let echo = binding(&offer, MediaOperation::Bound, AuxiliaryRole::Video);
    assert!(grant.consume(AuxiliaryRole::Video, &echo, delivered, MediaOperation::Bound));
    assert!(!grant.consume(AuxiliaryRole::Video, &echo, delivered, MediaOperation::Bound));
}

struct Endpoint {
    key: PairingKey,
    acceptor: tls::Acceptor,
    listener: TcpListener,
}

impl Endpoint {
    async fn new() -> Self {
        let key = PairingKey::generate().unwrap();
        let acceptor = tls::Acceptor::new(&key).unwrap();
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        Self { key, acceptor, listener }
    }

    async fn sockets(&self, role: AuxiliaryRole) -> (SecureStream, SecureStream) {
        let client = tls::connect_auxiliary(self.listener.local_addr().unwrap(), &self.key, role);
        let server = async {
            let (tcp, _) = self.listener.accept().await.unwrap();
            let (negotiated, stream) = self.acceptor.accept_role(tcp).await.unwrap();
            assert_eq!(negotiated, Some(role));
            stream
        };
        let (client, server) = tokio::join!(client, server);
        (client.unwrap(), server)
    }
}

#[tokio::test]
async fn an_oversize_bind_is_rejected_from_its_length_prefix_without_waiting_for_the_body() {
    let endpoint = Endpoint::new().await;
    let (mut client, mut server) = endpoint.sockets(AuxiliaryRole::Video).await;
    client.write_all(&(MAXIMUM_CONTROL_BYTES as u32 + 2).to_be_bytes()).await.unwrap();
    let result = timeout(Duration::from_secs(2), read_binding(&mut server)).await;
    assert!(matches!(result, Ok(Err(DeskError::Invalid(_)))));
}

async fn rejected_without_event(host: &mut Auxiliary, client: &mut SecureStream) {
    let mut byte = [0];
    tokio::select! {
        _ = host.next() => panic!("a rejected candidate changed a bound lane"),
        closed = timeout(Duration::from_secs(3), client.read(&mut byte)) => {
            assert!(matches!(closed, Ok(Ok(0) | Err(_))));
        }
    }
}

#[tokio::test]
async fn four_unbound_candidates_time_out_and_the_next_valid_connection_can_bind() {
    let endpoint = Endpoint::new().await;
    let (mut host, tx, offer) = host_with_offer();
    let mut idle = Vec::new();
    for _ in 0..4 {
        let (client, server) = endpoint.sockets(AuxiliaryRole::Video).await;
        idle.push(client);
        tx.send((AuxiliaryRole::Video, server)).await.unwrap();
    }
    let (mut excess, server) = endpoint.sockets(AuxiliaryRole::Video).await;
    tx.send((AuxiliaryRole::Video, server)).await.unwrap();
    rejected_without_event(&mut host, &mut excess).await;
    assert_eq!(host.pending.len(), 4);

    tokio::time::pause();
    assert!(timeout(Duration::from_secs(4), host.next()).await.is_err());
    assert_eq!(host.pending.len(), 4);
    assert!(timeout(Duration::from_secs(2), host.next()).await.is_err());
    assert!(host.pending.is_empty());
    tokio::time::resume();

    let (mut client, server) = endpoint.sockets(AuxiliaryRole::Video).await;
    let request = binding(&offer, MediaOperation::Bind, AuxiliaryRole::Video);
    client.write_all(&request.message().unwrap().framed().unwrap()).await.unwrap();
    tx.send((AuxiliaryRole::Video, server)).await.unwrap();
    assert!(matches!(timeout(Duration::from_secs(3), host.next()).await, Ok(AuxiliaryEvent::Bound(AuxiliaryRole::Video))));
}

#[tokio::test]
async fn an_incorrect_video_binding_keeps_the_existing_bulk_socket_and_grant() {
    let endpoint = Endpoint::new().await;
    let (mut host, tx, offer) = host_with_offer();
    let (mut bulk, server) = endpoint.sockets(AuxiliaryRole::Bulk).await;
    let bind = binding(&offer, MediaOperation::Bind, AuxiliaryRole::Bulk);
    bulk.write_all(&bind.message().unwrap().framed().unwrap()).await.unwrap();
    tx.send((AuxiliaryRole::Bulk, server)).await.unwrap();
    assert!(matches!(timeout(Duration::from_secs(3), host.next()).await, Ok(AuxiliaryEvent::Bound(AuxiliaryRole::Bulk))));
    let reply = read_binding(&mut bulk).await.unwrap();
    assert_eq!(reply.operation, MediaOperation::Bound);
    assert_eq!(reply.role.as_deref(), Some("bulk"));
    assert!(reply.session_id == bind.session_id && reply.token == bind.token);

    let (mut wrong, server) = endpoint.sockets(AuxiliaryRole::Video).await;
    wrong.write_all(&bind.message().unwrap().framed().unwrap()).await.unwrap();
    tx.send((AuxiliaryRole::Video, server)).await.unwrap();
    rejected_without_event(&mut host, &mut wrong).await;
    assert!(host.peer(AuxiliaryRole::Video).is_none());
    assert!(!host.grant.as_ref().unwrap().video_used);

    let receipt = Message::json(
        MessageKind::ClipboardReceipt,
        &serde_json::json!({
            "revision":{"origin":Uuid::new_v4(),"counter":1},"sequence":0
        }),
    )
    .unwrap();
    bulk.write_all(&receipt.framed().unwrap()).await.unwrap();
    assert!(matches!(timeout(Duration::from_secs(3), host.next()).await, Ok(AuxiliaryEvent::Message(AuxiliaryRole::Bulk, m)) if m == receipt));
}
