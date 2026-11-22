//! Video and clipboard TCP connections belonging to one authenticated control session.
use crate::clipboard_session::SessionClipboard;
use crate::error::{DeskError, Result};
use crate::media::{MediaControl, MediaOperation};
use crate::pairing::PairingKey;
use crate::peer::{self, PeerConfig, PeerEvent, PeerHandle};
use crate::tls::{self, AuxiliaryRole, SecureStream};
use crate::wire::{self, MAXIMUM_CONTROL_BYTES, Message, MessageKind};
use std::net::SocketAddr;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;
use tokio::task::JoinSet;
use tokio::time::{Instant, timeout};
use uuid::Uuid;

pub type Accepted = mpsc::Receiver<(AuxiliaryRole, SecureStream)>;
const BIND_TIMEOUT: Duration = Duration::from_secs(5);

struct Lane {
    peer: PeerHandle,
    incoming: mpsc::Receiver<PeerEvent>,
}

impl Drop for Lane {
    fn drop(&mut self) {
        self.peer.abort();
    }
}

struct Grant {
    session: Uuid,
    token: [u8; 32],
    expires: Instant,
    video_used: bool,
    bulk_used: bool,
}

impl Grant {
    fn consume(&mut self, role: AuxiliaryRole, binding: &MediaControl, now: Instant, expected: MediaOperation) -> bool {
        let used = match role {
            AuxiliaryRole::Video => &mut self.video_used,
            AuxiliaryRole::Bulk => &mut self.bulk_used,
        };
        if *used
            || (expected == MediaOperation::Bind && now > self.expires)
            || binding.operation != expected
            || binding.session_id != Some(self.session)
            || binding.role.as_deref() != Some(role.as_str())
            || !binding.token.as_ref().is_some_and(|token| token.len() == self.token.len() && openssl::memcmp::eq(&self.token, token))
        {
            return false;
        }
        *used = true;
        true
    }
}

enum Side {
    Host(Option<Accepted>),
    Viewer(Option<(SocketAddr, PairingKey)>),
}

pub(crate) enum AuxiliaryEvent {
    Bound(AuxiliaryRole),
    Lost(AuxiliaryRole),
    Message(AuxiliaryRole, Message),
}

pub(crate) struct Auxiliary {
    side: Side,
    grant: Option<Grant>,
    pending: JoinSet<Result<(AuxiliaryRole, SecureStream, MediaControl)>>,
    video: Option<Lane>,
    bulk: Option<Lane>,
}

impl Auxiliary {
    fn new(side: Side) -> Self {
        Self { side, grant: None, pending: JoinSet::new(), video: None, bulk: None }
    }

    pub fn host(incoming: Option<Accepted>) -> Self {
        Self::new(Side::Host(incoming))
    }
    pub fn viewer(target: Option<(SocketAddr, PairingKey)>) -> Self {
        Self::new(Side::Viewer(target))
    }
    pub fn enabled(&self) -> bool {
        matches!(self.side, Side::Host(Some(_)) | Side::Viewer(Some(_)))
    }

    pub fn offer(&mut self, offer: &MediaControl) {
        if !self.enabled() || self.grant.is_some() || offer.operation != MediaOperation::Offer {
            return;
        }
        let (Some(session), Some(token)) = (offer.session_id, offer.token.as_deref().and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())) else { return };
        self.grant = Some(Grant { session, token, expires: Instant::now() + Duration::from_secs(15), video_used: false, bulk_used: false });
        if let Side::Viewer(Some((addr, key))) = &self.side {
            for role in [AuxiliaryRole::Video, AuxiliaryRole::Bulk] {
                let (addr, key) = (*addr, key.clone());
                self.pending.spawn(async move {
                    let mut stream =
                        timeout(BIND_TIMEOUT, tls::connect_auxiliary(addr, &key, role)).await.map_err(|_| DeskError::invalid("辅助通道连接超时"))??;
                    let binding = MediaControl::binding(MediaOperation::Bind, session, &token, role.as_str());
                    stream.write_all(&binding.message()?.framed()?).await?;
                    let bound = read_binding(&mut stream).await?;
                    Ok((role, stream, bound))
                });
            }
        }
    }

    fn slot(&mut self, role: AuxiliaryRole) -> &mut Option<Lane> {
        match role {
            AuxiliaryRole::Video => &mut self.video,
            AuxiliaryRole::Bulk => &mut self.bulk,
        }
    }

    pub fn close(&mut self, role: AuxiliaryRole) {
        *self.slot(role) = None;
    }

    pub fn peer(&self, role: AuxiliaryRole) -> Option<&PeerHandle> {
        match role {
            AuxiliaryRole::Video => &self.video,
            AuxiliaryRole::Bulk => &self.bulk,
        }
        .as_ref()
        .map(|lane| &lane.peer)
    }

    fn install(&mut self, role: AuxiliaryRole, stream: SecureStream, binding: MediaControl) -> bool {
        let host = matches!(self.side, Side::Host(_));
        let expected = if host { MediaOperation::Bind } else { MediaOperation::Bound };
        let Some(grant) = self.grant.as_mut() else { return false };
        if !grant.consume(role, &binding, Instant::now(), expected) {
            return false;
        }
        let (peer, incoming) = peer::spawn(stream, PeerConfig::default());
        let lane = Lane { peer, incoming };
        if host {
            let reply = MediaControl::binding(MediaOperation::Bound, grant.session, &grant.token, role.as_str());
            if reply.message().and_then(|message| lane.peer.send(&message)).is_err() {
                return false;
            }
        }
        *self.slot(role) = Some(lane);
        true
    }

    pub async fn next(&mut self) -> AuxiliaryEvent {
        loop {
            let (role, event) = tokio::select! {
                candidate = async {
                    match &mut self.side {
                        Side::Host(Some(rx)) => rx.recv().await,
                        _ => std::future::pending().await,
                    }
                } => {
                    if let Some((role, mut stream)) = candidate {
                        if self.grant.as_ref().is_some_and(|grant| Instant::now() <= grant.expires) && self.pending.len() < 4 {
                            self.pending.spawn(async move {
                                let bind = read_binding(&mut stream).await?;
                                Ok((role, stream, bind))
                            });
                        }
                    } else { self.side = Side::Host(None); }
                    continue;
                },
                result = self.pending.join_next(), if !self.pending.is_empty() => {
                    if let Some(Ok(Ok((role, stream, bind)))) = result
                        && self.install(role, stream, bind) { return AuxiliaryEvent::Bound(role); }
                    continue;
                },
                event = next_event(&mut self.video) => (AuxiliaryRole::Video, event),
                event = next_event(&mut self.bulk) => (AuxiliaryRole::Bulk, event),
            };
            match event {
                Some(PeerEvent::RoundTrip(_)) => continue,
                Some(PeerEvent::Message(message))
                    if match role {
                        AuxiliaryRole::Video => matches!(self.side, Side::Viewer(_)) && message.kind == MessageKind::MediaFrame,
                        AuxiliaryRole::Bulk => SessionClipboard::is_bulk(message.kind),
                    } =>
                {
                    return AuxiliaryEvent::Message(role, message);
                }
                _ => {
                    self.close(role);
                    return AuxiliaryEvent::Lost(role);
                }
            }
        }
    }
}

async fn next_event(lane: &mut Option<Lane>) -> Option<PeerEvent> {
    match lane {
        Some(lane) => lane.incoming.recv().await,
        None => std::future::pending().await,
    }
}

// Swift peers may start the heartbeat before the binding exchange.
async fn read_binding(stream: &mut SecureStream) -> Result<MediaControl> {
    timeout(BIND_TIMEOUT, async {
        while let Some(message) = wire::read_message_limited(stream, MAXIMUM_CONTROL_BYTES + 1).await? {
            match message.kind {
                MessageKind::MediaControl => return MediaControl::read(&message),
                MessageKind::Ping => {
                    let echo = if message.payload.len() == 8 { message.payload } else { Vec::new() };
                    stream.write_all(&Message::new(MessageKind::Pong, echo).framed()?).await?;
                }
                MessageKind::Pong => {}
                _ => break,
            }
        }
        Err(DeskError::invalid("辅助通道缺少绑定信息"))
    })
    .await
    .map_err(|_| DeskError::invalid("辅助通道绑定超时"))?
}

#[cfg(test)]
mod tests;
