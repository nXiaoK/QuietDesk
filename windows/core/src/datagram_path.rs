//! Authenticated media datagrams and the bidirectional path challenge shared by both desktop roles.
mod retry;
use crate::datagram_transport::{self, DatagramEvent, DatagramSender, DatagramTransport};
use crate::media::{MediaControl, MediaOperation};
use openssl::rand::rand_bytes;
use retry::Recovery;
use std::collections::VecDeque;
use std::net::SocketAddr;
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use tokio::time::Instant;

const PROBE_SIZE: usize = 1024;
const PROBE_INTERVAL: Duration = Duration::from_millis(200);
const FAST_PROBE_INTERVAL: Duration = Duration::from_millis(50);
const NONCE_LIFETIME: Duration = Duration::from_secs(1);
const MAX_OUTSTANDING_PROBES: usize = (NONCE_LIFETIME.as_millis() / FAST_PROBE_INTERVAL.as_millis()) as usize;
const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

pub(crate) enum PathEvent {
    Verified,
    Lost,
    FreshPong(uuid::Uuid),
    Record(u8, Vec<u8>),
}

#[derive(Default)]
struct Challenge {
    outstanding: VecDeque<([u8; 16], Instant)>,
    received: bool,
    last_pong: Option<Instant>,
}

impl Challenge {
    fn ping(&mut self, now: Instant, send: impl FnOnce(Vec<u8>) -> bool) {
        let mut nonce = [0; 16];
        if rand_bytes(&mut nonce).is_err() {
            return;
        }
        let mut bytes = vec![0; PROBE_SIZE];
        bytes[0] = 1;
        bytes[1..17].copy_from_slice(&nonce);
        if send(bytes) {
            self.outstanding.retain(|(_, sent)| now.duration_since(*sent) < NONCE_LIFETIME);
            if self.outstanding.len() == MAX_OUTSTANDING_PROBES {
                self.outstanding.pop_front();
            }
            self.outstanding.push_back((nonce, now));
        }
    }

    fn pong(&mut self, bytes: &[u8], now: Instant) -> Option<Duration> {
        if bytes.len() != PROBE_SIZE {
            return None;
        }
        let matched = self.outstanding.iter().position(|(nonce, _)| bytes[1..17] == *nonce)?;
        let (_, sent) = self.outstanding.remove(matched)?;
        let elapsed = now.checked_duration_since(sent)?;
        if elapsed >= NONCE_LIFETIME {
            return None;
        }
        self.last_pong = Some(now);
        Some(elapsed.max(Duration::from_millis(1)))
    }

    fn verified(&self, now: Instant) -> bool {
        self.received && self.last_pong.is_some_and(|seen| now.duration_since(seen) < NONCE_LIFETIME)
    }
}

struct PathDriver {
    send: DatagramSender,
    events: mpsc::Receiver<PathEvent>,
    paused: watch::Sender<bool>,
    fresh_probe: watch::Sender<Option<uuid::Uuid>>,
    rtt: watch::Receiver<Duration>,
    task: JoinHandle<()>,
}

impl Drop for PathDriver {
    fn drop(&mut self) {
        self.task.abort();
    }
}

#[derive(Clone, Copy)]
struct Endpoint {
    addr: SocketAddr,
    host: bool,
    key: [u8; 32],
    session: uuid::Uuid,
}

pub(crate) struct DatagramPath {
    credentials: Option<Endpoint>,
    recovery: Recovery,
    listen_after: Option<Instant>,
    probe_by: Option<Instant>,
    endpoint: Option<SocketAddr>,
    driver: Option<PathDriver>,
    started: bool,
    paused: bool,
    verified: bool,
    rtt: Duration,
}

impl DatagramPath {
    pub fn new(endpoint: Option<SocketAddr>) -> Self {
        Self {
            credentials: None,
            recovery: Recovery::default(),
            listen_after: None,
            probe_by: None,
            endpoint,
            driver: None,
            started: false,
            paused: false,
            verified: false,
            rtt: Duration::from_millis(50),
        }
    }

    /// Called before sending the first host offer or processing the first accepted viewer offer.
    pub fn offer(&mut self, offer: &MediaControl, host: bool) -> bool {
        if self.started || offer.operation != MediaOperation::Offer {
            return self.credentials.is_some();
        }
        self.started = true;
        let Some(endpoint) = self.endpoint else { return false };
        if !host && offer.path.as_deref() == Some("tcp") {
            return false;
        }
        let (Some(session), Some(key)) = (offer.session_id, offer.datagram_key.as_deref().and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())) else {
            return false;
        };
        let target = Endpoint { addr: endpoint, host, key, session };
        if !self.start_driver(target) {
            return false;
        }
        self.credentials = Some(target);
        true
    }

    fn start_driver(&mut self, target: Endpoint) -> bool {
        let Endpoint { addr, host, key, session } = target;
        let io = if host { datagram_transport::host(addr, key, session) } else { datagram_transport::viewer(addr, key, session) };
        let Ok(io) = io else {
            if self.credentials.is_none() {
                log::info!("media DTLS endpoint unavailable");
            }
            return false;
        };
        // The first probe may finish during the initial reliable cutover. Recovery probes have their own budget.
        self.probe_by = (!host).then(|| Instant::now() + PROBE_TIMEOUT);
        // Screen configuration and keyframe requests may await a slow driver. Keep path probes live throughout.
        let send = io.sender();
        let (events, received) = mpsc::channel(128);
        let (paused, pause_events) = watch::channel(self.paused);
        let (rtt, measured_rtt) = watch::channel(self.rtt);
        let (fresh_probe, probes) = watch::channel(None);
        let task = tokio::spawn(drive(io, events, pause_events, probes, rtt));
        self.driver = Some(PathDriver { send, events: received, paused, fresh_probe, rtt: measured_rtt, task });
        true
    }

    pub fn enabled(&self) -> bool {
        self.endpoint.is_some()
    }

    pub fn verified(&self) -> bool {
        self.verified
    }

    pub fn rtt(&self) -> Duration {
        self.driver.as_ref().map_or(self.rtt, |io| *io.rtt.borrow())
    }

    pub fn authenticated(&self) -> bool {
        self.driver.as_ref().is_some_and(|io| io.send.authenticated())
    }

    pub fn retire(&mut self) {
        if self.driver.take().is_some() {
            self.schedule_probe(Instant::now());
        }
        self.probe_by = None;
        self.verified = false;
    }

    fn schedule_probe(&mut self, now: Instant) {
        if self.credentials.is_some_and(|endpoint| endpoint.host) {
            // Dropping the DTLS task releases its socket on the runtime. Re-bind for the viewer's next attempt.
            self.listen_after = Some(now + PROBE_INTERVAL);
        } else {
            self.recovery.failed(now);
        }
    }

    pub fn pause(&mut self, paused: bool) {
        self.recovery.pause(paused, Instant::now());
        if paused {
            self.probe_by = None;
        } else if self.driver.is_some() && !self.verified && self.credentials.is_some_and(|endpoint| !endpoint.host) {
            self.probe_by = Some(Instant::now() + PROBE_TIMEOUT);
        }
        self.paused = paused;
        if let Some(io) = &self.driver {
            io.paused.send_if_modified(|value| std::mem::replace(value, paused) != paused);
        }
    }

    pub fn probe_transaction(&self, id: Option<uuid::Uuid>) {
        if let Some(io) = &self.driver {
            io.fresh_probe.send_if_modified(|value| std::mem::replace(value, id) != id);
        }
    }

    pub fn send_payload(&self, kind: u8, bytes: &[u8]) -> bool {
        if bytes.len() >= datagram_transport::MAX_DATAGRAM {
            return false;
        }
        let mut record = Vec::with_capacity(1 + bytes.len());
        record.push(kind);
        record.extend_from_slice(bytes);
        self.send(record)
    }

    pub fn send(&self, record: Vec<u8>) -> bool {
        self.verified && !self.paused && self.driver.as_ref().is_some_and(|io| io.send.try_send(record))
    }

    pub async fn next(&mut self) -> PathEvent {
        loop {
            if self.driver.is_none() {
                let Some(target) = self.credentials else { return std::future::pending().await };
                let deadline = if target.host { self.listen_after } else { self.recovery.deadline() };
                let Some(at) = deadline.filter(|_| !self.paused) else { return std::future::pending().await };
                tokio::time::sleep_until(at).await;
                self.listen_after = None;
                if !self.start_driver(target) {
                    if target.host {
                        self.listen_after = Some(Instant::now() + Duration::from_secs(2));
                    } else {
                        self.schedule_probe(Instant::now());
                    }
                }
                continue;
            }
            let io = self.driver.as_mut().expect("a datagram driver is running");
            let event = tokio::select! {
                event = io.events.recv() => event,
                _ = async { match self.probe_by {
                    Some(at) => tokio::time::sleep_until(at).await,
                    None => std::future::pending().await,
                }} => None,
            };
            self.rtt = *io.rtt.borrow_and_update();
            let event =
                event.filter(|event| !matches!(event, PathEvent::Verified | PathEvent::FreshPong(_)) || (!io.events.is_closed() && io.send.authenticated()));
            match event {
                Some(PathEvent::Record(_, _) | PathEvent::FreshPong(_)) if self.paused => continue,
                Some(PathEvent::Verified) => {
                    self.verified = true;
                    self.probe_by = None;
                    self.recovery.selected(Instant::now());
                    return PathEvent::Verified;
                }
                None | Some(PathEvent::Lost) => {
                    self.retire();
                    return PathEvent::Lost;
                }
                Some(event) => return event,
            }
        }
    }
}

async fn drive(
    mut io: DatagramTransport,
    events: mpsc::Sender<PathEvent>,
    mut pause_events: watch::Receiver<bool>,
    mut probes: watch::Receiver<Option<uuid::Uuid>>,
    measured_rtt: watch::Sender<Duration>,
) {
    let mut challenge = Challenge::default();
    let mut resumed = Instant::now();
    let mut next_ping = resumed;
    let mut ready = false;
    let mut verified = false;
    let mut paused = *pause_events.borrow_and_update();
    let mut pending_probe = *probes.borrow_and_update();
    loop {
        let incoming = tokio::select! {
            event = io.next() => event,
            changed = probes.changed() => {
                if changed.is_err() { return }
                pending_probe = *probes.borrow_and_update();
                if pending_probe.is_some() {
                    challenge.outstanding.clear();
                    next_ping = Instant::now();
                }
                continue;
            }
            changed = pause_events.changed() => {
                if changed.is_err() { return }
                paused = *pause_events.borrow_and_update();
                resumed = Instant::now();
                next_ping = resumed;
                challenge = Challenge::default();
                continue;
            }
            _ = tokio::time::sleep_until(next_ping), if ready && !paused => {
                let now = Instant::now();
                next_ping = now + if pending_probe.is_some() { FAST_PROBE_INTERVAL } else { PROBE_INTERVAL };
                challenge.ping(now, |ping| io.try_send(ping));
                let last = challenge.last_pong.unwrap_or(resumed).max(resumed);
                if (verified && now.duration_since(last) >= NONCE_LIFETIME) || (!verified && now.duration_since(resumed) >= PROBE_TIMEOUT) {
                    log::info!("media UDP challenge timed out");
                    break;
                }
                continue;
            }
        };
        match incoming {
            DatagramEvent::Ready => {
                log::info!("media DTLS authenticated");
                ready = true;
                resumed = Instant::now();
                next_ping = resumed;
            }
            DatagramEvent::Closed => {
                log::info!("media DTLS closed (authenticated={ready}, verified={verified})");
                break;
            }
            DatagramEvent::Data(mut bytes) => {
                let now = Instant::now();
                match bytes.first().copied() {
                    Some(1) if bytes.len() == PROBE_SIZE => {
                        bytes[0] = 2;
                        io.try_send(bytes);
                        challenge.received = true;
                    }
                    Some(2) if !paused => {
                        if let Some(rtt) = challenge.pong(&bytes, now) {
                            measured_rtt.send_replace(rtt);
                            if let Some(id) = pending_probe
                                && events.try_send(PathEvent::FreshPong(id)).is_ok()
                            {
                                pending_probe = None;
                            }
                        }
                    }
                    Some(kind) if verified && !paused => {
                        // Media loss is handled by NACK. A slow decoder must never hold the next pong.
                        let _ = events.try_send(PathEvent::Record(kind, bytes));
                    }
                    _ => continue,
                }
                if !paused && !verified && challenge.verified(now) {
                    verified = true;
                    log::info!("media UDP path verified");
                    if events.send(PathEvent::Verified).await.is_err() {
                        return;
                    }
                }
            }
        }
    }
    // Dropping the sender preserves event order and reports loss after any queued records.
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_slow_capture_worker_cannot_starve_the_media_path_challenges() {
        let reservation = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let address = reservation.local_addr().unwrap();
        drop(reservation);
        let offer = MediaControl {
            operation: MediaOperation::Offer,
            session_id: Some(uuid::Uuid::new_v4()),
            datagram_key: Some(vec![7; 32]),
            path: Some("udp".into()),
            ..crate::media::ViewerMedia::request()
        };
        let mut host = DatagramPath::new(Some(address));
        let mut viewer = DatagramPath::new(Some(address));
        assert!(host.offer(&offer, true));
        assert!(viewer.offer(&offer, false));
        tokio::time::timeout(Duration::from_secs(4), async {
            assert!(matches!(viewer.next().await, PathEvent::Verified));
            assert!(matches!(host.next().await, PathEvent::Verified));
            // Neither session reads events while the encoder is reconfiguring.
            tokio::time::sleep(NONCE_LIFETIME * 2).await;
            assert!(host.rtt() < Duration::from_millis(50));
            assert!(viewer.rtt() < Duration::from_millis(50));
            assert!(viewer.send(vec![3, 123]));
            assert!(matches!(host.next().await, PathEvent::Record(3, bytes) if bytes == [3, 123]));
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn a_queued_verification_cannot_upgrade_after_the_driver_has_lost_its_peer() {
        let address = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let offer = MediaControl {
            operation: MediaOperation::Offer,
            session_id: Some(uuid::Uuid::new_v4()),
            datagram_key: Some(vec![7; 32]),
            path: Some("udp".into()),
            ..crate::media::ViewerMedia::request()
        };
        let mut host = DatagramPath::new(Some(address));
        let mut viewer = DatagramPath::new(Some(address));
        assert!(host.offer(&offer, true));
        assert!(viewer.offer(&offer, false));
        tokio::time::timeout(Duration::from_secs(5), async {
            assert!(matches!(host.next().await, PathEvent::Verified));
            let io = viewer.driver.as_ref().unwrap();
            while io.events.is_empty() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            assert!(io.send.authenticated());
            host.retire();
            while !io.events.is_closed() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            assert!(!io.send.authenticated());
            assert!(matches!(viewer.next().await, PathEvent::Lost));
            assert!(!viewer.verified());
        })
        .await
        .unwrap();
    }

    #[test]
    fn both_directions_and_a_fresh_matching_nonce_are_required() {
        fn send_probe(challenge: &mut Challenge, at: Instant) -> Vec<u8> {
            let mut pong = None;
            challenge.ping(at, |mut data| {
                assert_eq!(data.len(), PROBE_SIZE);
                assert_eq!(data[0], 1);
                data[0] = 2;
                pong = Some(data);
                true
            });
            pong.unwrap()
        }

        let now = Instant::now();
        let mut challenge = Challenge::default();
        let lost = send_probe(&mut challenge, now);
        let second_at = now + PROBE_INTERVAL;
        let mut reply = send_probe(&mut challenge, second_at);
        assert_ne!(reply, lost);
        let answered = second_at + Duration::from_millis(5);
        reply[5] ^= 1;
        assert_eq!(challenge.pong(&reply, answered), None);
        reply[5] ^= 1;
        assert_eq!(challenge.pong(&reply, answered), Some(Duration::from_millis(5)));
        assert!(!challenge.verified(answered));
        challenge.received = true;
        assert!(challenge.verified(answered));
        assert_eq!(challenge.pong(&reply, answered), None);

        let delayed_at = second_at + PROBE_INTERVAL;
        let delayed = send_probe(&mut challenge, delayed_at);
        let newer = send_probe(&mut challenge, delayed_at + PROBE_INTERVAL);
        assert_ne!(delayed, newer);
        let delayed_rtt = Duration::from_millis(270);
        let later = delayed_at + delayed_rtt;
        assert_eq!(challenge.pong(&delayed, later), Some(delayed_rtt));
        let expired = later + NONCE_LIFETIME;
        assert!(!challenge.verified(expired));
        assert_eq!(challenge.pong(&newer, expired), None);
    }

    #[tokio::test]
    async fn fast_recovery_accepts_only_the_pong_to_the_new_transaction_challenge() {
        let address = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let key = [7; 32];
        let session = uuid::Uuid::new_v4();
        let offer = MediaControl {
            operation: MediaOperation::Offer,
            session_id: Some(session),
            datagram_key: Some(key.to_vec()),
            path: Some("udp".into()),
            ..crate::media::ViewerMedia::request()
        };
        let mut host = DatagramPath::new(Some(address));
        assert!(host.offer(&offer, true));
        let mut peer = datagram_transport::viewer(address, key, session).unwrap();
        async fn ping(peer: &mut DatagramTransport) -> Vec<u8> {
            loop {
                match peer.next().await {
                    DatagramEvent::Data(bytes) if bytes.first() == Some(&1) => return bytes,
                    DatagramEvent::Closed => panic!("authenticated datagram peer closed"),
                    _ => {}
                }
            }
        }
        tokio::time::timeout(Duration::from_secs(5), async {
            assert!(matches!(peer.next().await, DatagramEvent::Ready));
            let mut previous = ping(&mut peer).await;
            assert!(peer.try_send(previous.clone())); // Other direction of the admission proof.
            previous[0] = 2;
            assert!(peer.try_send(previous));
            assert!(matches!(host.next().await, PathEvent::Verified));
            let mut old = ping(&mut peer).await;
            let id = uuid::Uuid::new_v4();
            host.probe_transaction(Some(id));
            let mut current = loop {
                let candidate = ping(&mut peer).await;
                if candidate != old {
                    break candidate;
                }
            };
            old[0] = 2;
            assert!(peer.try_send(old));
            assert!(tokio::time::timeout(Duration::from_millis(80), host.next()).await.is_err());
            current[0] = 2;
            assert!(peer.try_send(current.clone()));
            assert!(matches!(host.next().await, PathEvent::FreshPong(answer) if answer == id));
            assert!(peer.try_send(current));
            assert!(tokio::time::timeout(Duration::from_millis(80), host.next()).await.is_err());
            // A valid answer still sitting in the session queue cannot authorize an IDR after path loss.
            host.probe_transaction(Some(uuid::Uuid::new_v4()));
            loop {
                let mut next = ping(&mut peer).await;
                next[0] = 2;
                assert!(peer.try_send(next));
                if tokio::time::timeout(Duration::from_millis(30), async {
                    while host.driver.as_ref().unwrap().events.is_empty() {
                        tokio::time::sleep(Duration::from_millis(2)).await;
                    }
                })
                .await
                .is_ok()
                {
                    break;
                }
            }
            drop(peer);
            while !host.driver.as_ref().unwrap().events.is_closed() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            assert!(matches!(host.next().await, PathEvent::Lost));
        })
        .await
        .unwrap();
    }
}
