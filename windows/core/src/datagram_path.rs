//! Authenticated media datagrams and the bidirectional path challenge shared by both desktop roles.
use crate::datagram_transport::{self, DatagramEvent, DatagramSender, DatagramTransport};
use crate::media::{MediaControl, MediaOperation};
use openssl::rand::rand_bytes;
use std::net::SocketAddr;
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use tokio::time::Instant;

const PROBE_SIZE: usize = 1024;
const PROBE_INTERVAL: Duration = Duration::from_millis(200);
const NONCE_LIFETIME: Duration = Duration::from_secs(1);

pub(crate) enum PathEvent {
    Verified,
    Lost,
    Record(u8, Vec<u8>),
}

#[derive(Default)]
struct Challenge {
    outstanding: Option<([u8; 16], Instant)>,
    received: bool,
    last_pong: Option<Instant>,
}

impl Challenge {
    fn ping(&mut self, now: Instant) -> Option<Vec<u8>> {
        if self.outstanding.is_none_or(|(_, sent)| now.duration_since(sent) >= NONCE_LIFETIME) {
            let mut nonce = [0; 16];
            rand_bytes(&mut nonce).ok()?;
            self.outstanding = Some((nonce, now));
        }
        let mut bytes = vec![0; PROBE_SIZE];
        bytes[0] = 1;
        bytes[1..17].copy_from_slice(&self.outstanding?.0);
        Some(bytes)
    }

    fn pong(&mut self, bytes: &[u8], now: Instant) -> Option<Duration> {
        let (nonce, sent) = self.outstanding?;
        let elapsed = now.duration_since(sent);
        if bytes.len() != PROBE_SIZE || bytes[1..17] != nonce || elapsed >= NONCE_LIFETIME {
            return None;
        }
        self.outstanding = None;
        self.last_pong = Some(now);
        Some(elapsed.clamp(Duration::from_millis(1), Duration::from_secs(2)))
    }

    fn verified(&self, now: Instant) -> bool {
        self.received && self.last_pong.is_some_and(|seen| now.duration_since(seen) < NONCE_LIFETIME)
    }
}

struct PathDriver {
    send: DatagramSender,
    events: mpsc::Receiver<PathEvent>,
    paused: watch::Sender<bool>,
    rtt: watch::Receiver<Duration>,
    task: JoinHandle<()>,
}

impl Drop for PathDriver {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub(crate) struct DatagramPath {
    endpoint: Option<SocketAddr>,
    driver: Option<PathDriver>,
    started: bool,
    paused: bool,
    verified: bool,
    pub rtt: Duration,
}

impl DatagramPath {
    pub fn new(endpoint: Option<SocketAddr>) -> Self {
        Self { endpoint, driver: None, started: false, paused: false, verified: false, rtt: Duration::from_millis(50) }
    }

    /// Called before sending the first host offer or processing the first accepted viewer offer.
    pub fn offer(&mut self, offer: &MediaControl, host: bool) -> bool {
        if self.started || offer.operation != MediaOperation::Offer {
            return self.driver.is_some();
        }
        self.started = true;
        let Some(endpoint) = self.endpoint else { return false };
        if !host && offer.path.as_deref() == Some("tcp") {
            return false;
        }
        let (Some(session), Some(key)) = (offer.session_id, offer.datagram_key.as_deref().and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())) else {
            return false;
        };
        let io = if host { datagram_transport::host(endpoint, key, session) } else { datagram_transport::viewer(endpoint, key, session) };
        let Ok(io) = io else {
            log::info!("media DTLS endpoint unavailable");
            return false;
        };
        // Screen configuration and keyframe requests may await a slow driver. Keep path probes live throughout.
        let send = io.sender();
        let (events, received) = mpsc::channel(128);
        let (paused, pause_events) = watch::channel(self.paused);
        let (rtt, measured_rtt) = watch::channel(self.rtt);
        let task = tokio::spawn(drive(io, events, pause_events, rtt));
        self.driver = Some(PathDriver { send, events: received, paused, rtt: measured_rtt, task });
        true
    }

    pub fn enabled(&self) -> bool {
        self.endpoint.is_some()
    }

    pub fn verified(&self) -> bool {
        self.verified
    }

    pub fn authenticated(&self) -> bool {
        self.driver.as_ref().is_some_and(|io| io.send.authenticated())
    }

    pub fn retire(&mut self) {
        self.driver = None;
        self.verified = false;
    }

    pub fn pause(&mut self, paused: bool) {
        self.paused = paused;
        if let Some(io) = &self.driver {
            io.paused.send_if_modified(|value| std::mem::replace(value, paused) != paused);
        }
    }

    pub fn send(&self, record: Vec<u8>) -> bool {
        self.verified && !self.paused && self.driver.as_ref().is_some_and(|io| io.send.try_send(record))
    }

    pub async fn next(&mut self) -> PathEvent {
        loop {
            let Some(io) = &mut self.driver else { return std::future::pending().await };
            let event = io.events.recv().await;
            self.rtt = *io.rtt.borrow_and_update();
            match event {
                Some(PathEvent::Record(_, _)) if self.paused => continue,
                Some(PathEvent::Verified) if !io.events.is_closed() && io.send.authenticated() => {
                    self.verified = true;
                    return PathEvent::Verified;
                }
                None | Some(PathEvent::Lost | PathEvent::Verified) => {
                    self.retire();
                    return PathEvent::Lost;
                }
                Some(event) => return event,
            }
        }
    }
}

async fn drive(mut io: DatagramTransport, events: mpsc::Sender<PathEvent>, mut pause_events: watch::Receiver<bool>, measured_rtt: watch::Sender<Duration>) {
    let mut challenge = Challenge::default();
    let mut resumed = Instant::now();
    let mut next_ping = resumed;
    let mut ready = false;
    let mut verified = false;
    let mut paused = *pause_events.borrow_and_update();
    loop {
        let incoming = tokio::select! {
            event = io.next() => event,
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
                next_ping = now + PROBE_INTERVAL;
                if let Some(ping) = challenge.ping(now) { io.try_send(ping); }
                let last = challenge.last_pong.unwrap_or(resumed).max(resumed);
                if verified && now.duration_since(last) >= NONCE_LIFETIME {
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
                    Some(2) => {
                        if let Some(rtt) = challenge.pong(&bytes, now) {
                            measured_rtt.send_replace(rtt);
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
        let now = Instant::now();
        let mut challenge = Challenge::default();
        let ping = challenge.ping(now).unwrap();
        assert_eq!(ping.len(), PROBE_SIZE);
        assert_eq!(challenge.ping(now + PROBE_INTERVAL).unwrap(), ping);
        let mut reply = ping.clone();
        reply[0] = 2;
        reply[5] ^= 1;
        assert_eq!(challenge.pong(&reply, now), None);
        reply[5] ^= 1;
        assert_eq!(challenge.pong(&reply, now + PROBE_INTERVAL), Some(PROBE_INTERVAL));
        assert!(!challenge.verified(now + PROBE_INTERVAL));
        challenge.received = true;
        assert!(challenge.verified(now + PROBE_INTERVAL));
        assert_eq!(challenge.pong(&reply, now + PROBE_INTERVAL), None);
        let later = now + PROBE_INTERVAL + NONCE_LIFETIME;
        assert!(!challenge.verified(later));
        let late_reply = challenge.ping(later).unwrap();
        assert_eq!(challenge.pong(&late_reply, later + NONCE_LIFETIME), None);
    }
}
