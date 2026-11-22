//! A framed, heartbeat-supervised connection, the counterpart of `Peer` in
//! `Sources/QuietDeskCore/Transport.swift`.

use crate::error::{DeskError, Result};
use crate::wire::{self, MAXIMUM_MESSAGE_BYTES, Message, MessageKind};
use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;

#[derive(Clone, Copy, Debug)]
pub struct PeerConfig {
    /// How often a ping is sent, and how often silence is checked.
    pub heartbeat: Duration,
    /// Silence longer than this closes the connection. Both sides ping, so a live path is never silent.
    pub idle_timeout: Duration,
}

impl Default for PeerConfig {
    fn default() -> Self {
        Self { heartbeat: Duration::from_secs(5), idle_timeout: Duration::from_secs(30) }
    }
}

#[derive(Debug)]
pub enum PeerEvent {
    Message(Message),
    /// Round trip of an application heartbeat in milliseconds, queueing on both sides included.
    RoundTrip(f64),
    /// Always the last event.
    Closed(DeskError),
}

enum Outgoing {
    Message(Vec<u8>),
    /// Send what is queued, then close; with a reason when the connection itself gave up.
    Close(Option<DeskError>),
}

struct Shared {
    ordered_ping_kind: AtomicU8,
    pending_bytes: AtomicUsize,
    last_received: Mutex<Instant>,
    ping: Mutex<Option<(u64, Instant)>>,
}

/// Queues messages for sending. Clones share one connection.
#[derive(Clone)]
pub struct PeerHandle {
    outgoing: mpsc::UnboundedSender<Outgoing>,
    shared: Arc<Shared>,
    finished: watch::Receiver<bool>,
}

impl PeerHandle {
    /// A released Mac finishes the preceding input/release handler before echoing the next ping.
    /// The two Rust roles order these echoes with input, while ordinary heartbeats stay on the I/O task.
    pub(crate) fn order_input_echoes(&self, kind: MessageKind) {
        self.shared.ordered_ping_kind.store(kind as u8, Ordering::Release);
    }

    /// Queues a message behind those already queued. An error means the message itself cannot be sent;
    /// a connection that has closed drops it, and `PeerEvent::Closed` tells the session why it closed.
    pub fn send(&self, message: &Message) -> Result<()> {
        let bytes = message.framed()?;
        // Video is paced by acknowledgements, so a queue this deep means the path has stalled.
        if self.shared.pending_bytes.fetch_add(bytes.len(), Ordering::Relaxed) + bytes.len() > MAXIMUM_MESSAGE_BYTES * 2 {
            let _ = self.outgoing.send(Outgoing::Close(Some(DeskError::Network("网络发送队列已满".to_string()))));
        } else {
            let _ = self.outgoing.send(Outgoing::Message(bytes));
        }
        Ok(())
    }

    /// Sends what is queued, then closes the connection.
    pub fn close(&self) {
        let _ = self.outgoing.send(Outgoing::Close(None));
    }

    /// Completes once the connection has closed and everything it could still send or receive is done.
    pub async fn finished(&self) {
        let _ = self.finished.clone().wait_for(|finished| *finished).await;
    }
}

pub(crate) fn input_echo(sequence: u32) -> [u8; 8] {
    let mut bytes = *b"QDIN0000";
    bytes[4..].copy_from_slice(&sequence.to_be_bytes());
    bytes
}

struct ActivityReader<R> {
    inner: R,
    shared: Arc<Shared>,
}

impl<R: AsyncRead + Unpin> AsyncRead for ActivityReader<R> {
    fn poll_read(mut self: Pin<&mut Self>, context: &mut Context<'_>, buffer: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let before = buffer.filled().len();
        let result = Pin::new(&mut self.inner).poll_read(context, buffer);
        if buffer.filled().len() > before {
            *self.shared.last_received.lock().unwrap() = Instant::now();
        }
        result
    }
}

/// After this side stops sending, how long the other side has to finish what it was sending.
const LINGER: Duration = Duration::from_millis(500);

/// Starts the connection's tasks on the current runtime. Events end with `PeerEvent::Closed`.
pub fn spawn<S>(stream: S, config: PeerConfig) -> (PeerHandle, mpsc::Receiver<PeerEvent>)
where
    S: AsyncRead + AsyncWrite + Send + 'static,
{
    let (reader, mut writer) = tokio::io::split(stream);
    let (outgoing, mut queued) = mpsc::unbounded_channel();
    // A full channel stops reading, which lets TCP push back on a peer that sends faster than the session consumes.
    let (events, incoming) = mpsc::channel(32);
    let (finish, finished) = watch::channel(false);
    let shared = Arc::new(Shared {
        ordered_ping_kind: AtomicU8::new(0),
        pending_bytes: AtomicUsize::new(0),
        last_received: Mutex::new(Instant::now()),
        ping: Mutex::new(None),
    });
    let handle = PeerHandle { outgoing, shared: shared.clone(), finished };

    let read_handle = handle.clone();
    let read_events = events.clone();
    let mut reading = tokio::spawn(async move {
        let mut reader = ActivityReader { inner: reader, shared: read_handle.shared.clone() };
        loop {
            let message = match wire::read_message(&mut reader).await {
                Ok(Some(message)) => message,
                Ok(None) => return DeskError::Network("对方已断开连接".to_string()),
                Err(error) => return error,
            };
            let ordered = read_handle.shared.ordered_ping_kind.load(Ordering::Acquire) == message.kind as u8
                && message.payload.len() == 8
                && message.payload.starts_with(b"QDIN");
            match message.kind {
                MessageKind::Ping if !ordered => {
                    let echo = if message.payload.len() == 8 { message.payload } else { Vec::new() };
                    let _ = read_handle.send(&Message::new(MessageKind::Pong, echo));
                }
                MessageKind::Pong if !ordered => {
                    let sent = read_handle.shared.ping.lock().unwrap().take_if(|(identifier, _)| identifier.to_be_bytes()[..] == message.payload[..]);
                    if let Some((_, sent)) = sent {
                        let _ = read_events.send(PeerEvent::RoundTrip(sent.elapsed().as_secs_f64() * 1000.0)).await;
                    }
                }
                _ => {
                    if read_events.send(PeerEvent::Message(message)).await.is_err() {
                        return DeskError::Network("已断开连接".to_string());
                    }
                }
            }
        }
    });

    tokio::spawn(async move {
        let mut heartbeat = tokio::time::interval(config.heartbeat);
        let mut sequence = 0u64;
        let stopped = loop {
            tokio::select! {
                next = queued.recv() => match next {
                    Some(Outgoing::Message(bytes)) => {
                        let written = writer.write_all(&bytes).await;
                        shared.pending_bytes.fetch_sub(bytes.len(), Ordering::Relaxed);
                        if let Err(error) = written { break Err(DeskError::from(error)); }
                    }
                    Some(Outgoing::Close(reason)) => break Err(reason.unwrap_or_else(|| DeskError::Network("已断开连接".to_string()))),
                    None => break Err(DeskError::Network("已断开连接".to_string())),
                },
                ended = &mut reading => break Ok(ended.unwrap_or_else(|_| DeskError::Network("已断开连接".to_string()))),
                _ = heartbeat.tick() => {
                    if shared.last_received.lock().unwrap().elapsed() > config.idle_timeout {
                        break Err(DeskError::Network(format!("连接超过 {} 秒无数据", config.idle_timeout.as_secs())));
                    }
                    sequence += 1;
                    let payload = {
                        let mut ping = shared.ping.lock().unwrap();
                        // An unanswered ping keeps its start time, so a slow answer still measures the real delay.
                        let (identifier, _) = *ping.get_or_insert((sequence, Instant::now()));
                        identifier.to_be_bytes().to_vec()
                    };
                    let bytes = Message::new(MessageKind::Ping, payload).framed().expect("a ping fits a frame");
                    if let Err(error) = writer.write_all(&bytes).await { break Err(DeskError::from(error)); }
                }
            }
        };
        let _ = writer.shutdown().await;
        let reason = match stopped {
            Ok(read_reason) => read_reason,
            Err(reason) => {
                // The other side may still be sending its last messages, such as the notice that it ended the
                // session. They reach the session before the closing event; a side that never finishes is cut off.
                if tokio::time::timeout(LINGER, &mut reading).await.is_err() {
                    reading.abort();
                }
                reason
            }
        };
        let _ = events.send(PeerEvent::Closed(reason)).await;
        let _ = finish.send(true);
    });

    (handle, incoming)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;

    fn fast() -> PeerConfig {
        PeerConfig { heartbeat: Duration::from_millis(20), idle_timeout: Duration::from_millis(200) }
    }

    async fn next_message(events: &mut mpsc::Receiver<PeerEvent>) -> Option<Message> {
        loop {
            match events.recv().await? {
                PeerEvent::Message(message) => return Some(message),
                PeerEvent::RoundTrip(_) => {}
                PeerEvent::Closed(_) => return None,
            }
        }
    }

    #[tokio::test]
    async fn messages_arrive_in_order_and_heartbeats_measure_the_round_trip() {
        let (left, right) = tokio::io::duplex(64 * 1024);
        let (sender, mut sender_events) = spawn(left, fast());
        let (_receiver, mut receiver_events) = spawn(right, fast());
        for number in 0..5u8 {
            sender.send(&Message::new(MessageKind::Input, vec![number])).unwrap();
        }
        for number in 0..5u8 {
            assert_eq!(next_message(&mut receiver_events).await.unwrap().payload, vec![number]);
        }
        let round_trip = loop {
            match sender_events.recv().await.unwrap() {
                PeerEvent::RoundTrip(milliseconds) => break milliseconds,
                PeerEvent::Message(_) => {}
                PeerEvent::Closed(reason) => panic!("closed: {reason}"),
            }
        };
        assert!((0.0..1000.0).contains(&round_trip));
    }

    #[tokio::test]
    async fn close_delivers_queued_messages_then_ends_both_sides() {
        let (left, right) = tokio::io::duplex(64 * 1024);
        let (sender, mut sender_events) = spawn(left, fast());
        let (_receiver, mut receiver_events) = spawn(right, fast());
        sender.send(&Message::empty(MessageKind::ReleaseInput)).unwrap();
        sender.close();
        assert_eq!(next_message(&mut receiver_events).await.unwrap().kind, MessageKind::ReleaseInput);
        assert!(next_message(&mut receiver_events).await.is_none());
        assert!(next_message(&mut sender_events).await.is_none());
        sender.finished().await;
        // A message for a closed connection is dropped; only one that cannot be framed is an error.
        sender.send(&Message::empty(MessageKind::ReleaseInput)).unwrap();
        assert!(sender.send(&Message::new(MessageKind::Video, vec![0; MAXIMUM_MESSAGE_BYTES])).is_err());
    }

    #[tokio::test]
    async fn a_silent_peer_times_out_and_a_ping_is_answered_with_its_payload() {
        let (left, mut raw) = tokio::io::duplex(64 * 1024);
        let (_handle, mut events) = spawn(left, fast());
        raw.write_all(&Message::new(MessageKind::Ping, vec![1, 2, 3, 4, 5, 6, 7, 8]).framed().unwrap()).await.unwrap();
        let mut seen_pong = false;
        // Read what the peer writes without ever answering its own pings.
        let reader = async {
            loop {
                let mut header = [0u8; 5];
                if raw.read_exact(&mut header).await.is_err() {
                    break;
                }
                let mut payload = vec![0u8; u32::from_be_bytes(header[..4].try_into().unwrap()) as usize - 1];
                raw.read_exact(&mut payload).await.unwrap();
                if header[4] == MessageKind::Pong as u8 {
                    assert_eq!(payload, [1, 2, 3, 4, 5, 6, 7, 8]);
                    seen_pong = true;
                }
            }
        };
        let closed = async {
            loop {
                if let PeerEvent::Closed(reason) = events.recv().await.unwrap() {
                    break reason;
                }
            }
        };
        let (_, reason) = tokio::join!(reader, closed);
        assert!(seen_pong);
        assert!(reason.to_string().contains("无数据"));
    }

    #[tokio::test]
    async fn an_unknown_message_kind_closes_the_connection() {
        let (left, mut raw) = tokio::io::duplex(1024);
        let (_handle, mut events) = spawn(left, fast());
        raw.write_all(&[0, 0, 0, 1, 99]).await.unwrap();
        let reason = loop {
            if let PeerEvent::Closed(reason) = events.recv().await.unwrap() {
                break reason;
            }
        };
        assert!(matches!(reason, DeskError::Invalid(_)));
    }
}
