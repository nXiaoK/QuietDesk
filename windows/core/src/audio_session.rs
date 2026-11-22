//! Bounded connections between one authenticated desktop and its audio device workers.
use crate::audio::{AudioControl, AudioPacket, AudioState};
use crate::datagram_path::DatagramPath;
use crate::error::{DeskError, Result};
use crate::host::HostPlatform;
use crate::peer::PeerHandle;
use crate::viewer::{ViewerEvent, ViewerPlatform};
use crate::wire::Message;
use std::num::NonZeroU32;
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use tokio::time::{Instant, timeout_at};
use uuid::Uuid;

/// Stamps the samples from each uninterrupted run of a device worker.
#[derive(Clone, Copy, Debug)]
pub struct AudioRunState {
    pub paused: bool,
    pub revision: u64,
}

impl AudioRunState {
    fn set_paused(tx: &watch::Sender<Self>, paused: bool) {
        tx.send_if_modified(|state| {
            if state.paused == paused {
                return false;
            }
            state.paused = paused;
            state.revision = state.revision.wrapping_add(1);
            true
        });
    }
}

pub enum CaptureEvent {
    Ready,
    Packet(AudioPacket, u64),
    Failed(DeskError),
}

pub enum PlaybackEvent {
    Ready,
    Failed(DeskError),
}

pub struct AudioCapture {
    events: mpsc::Receiver<CaptureEvent>,
    paused: watch::Sender<AudioRunState>,
}

pub struct CaptureWorker {
    pub events: mpsc::Sender<CaptureEvent>,
    pub paused: watch::Receiver<AudioRunState>,
}

impl AudioCapture {
    pub fn channel(paused: bool) -> (Self, CaptureWorker) {
        let (tx, events) = mpsc::channel(5);
        let (control, rx) = watch::channel(AudioRunState { paused, revision: 0 });
        (Self { events, paused: control }, CaptureWorker { events: tx, paused: rx })
    }

    pub(crate) fn pause(&self, paused: bool) {
        AudioRunState::set_paused(&self.paused, paused);
    }

    pub(crate) async fn next(&mut self) -> CaptureEvent {
        self.events.recv().await.unwrap_or_else(|| CaptureEvent::Failed(DeskError::platform("远端声音采集已停止")))
    }
}

pub struct AudioPlayback {
    packets: mpsc::Sender<AudioPacket>,
    events: mpsc::Receiver<PlaybackEvent>,
    paused: watch::Sender<AudioRunState>,
}

pub struct PlaybackWorker {
    pub packets: mpsc::Receiver<AudioPacket>,
    pub events: mpsc::Sender<PlaybackEvent>,
    pub paused: watch::Receiver<AudioRunState>,
}

impl AudioPlayback {
    pub fn channel(paused: bool) -> (Self, PlaybackWorker) {
        let (packets, rx) = mpsc::channel(5);
        let (tx, events) = mpsc::channel(2);
        let (control, state) = watch::channel(AudioRunState { paused, revision: 0 });
        (Self { packets, events, paused: control }, PlaybackWorker { packets: rx, events: tx, paused: state })
    }

    pub(crate) fn pause(&self, paused: bool) {
        AudioRunState::set_paused(&self.paused, paused);
    }

    pub(crate) fn play(&self, packet: AudioPacket) -> Result<()> {
        match self.packets.try_send(packet) {
            Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => Ok(()),
            Err(mpsc::error::TrySendError::Closed(_)) => Err(DeskError::platform("本机声音播放已停止")),
        }
    }

    pub(crate) async fn next(&mut self) -> PlaybackEvent {
        self.events.recv().await.unwrap_or_else(|| PlaybackEvent::Failed(DeskError::platform("本机声音播放已停止")))
    }
}

fn error_text(error: DeskError) -> String {
    let text: String = error.to_string().chars().filter(|c| !c.is_control()).take(240).collect();
    if text.is_empty() { "声音设备不可用".into() } else { text }
}

#[derive(Default)]
pub(crate) struct HostAudio {
    capture: Option<AudioCapture>,
    starting: Option<(Uuid, Instant)>,
    epoch: u32,
    redundant: bool,
}

impl HostAudio {
    pub fn control(&mut self, message: &Message, platform: &mut impl HostPlatform, paused: bool, peer: &PeerHandle) -> Result<()> {
        let AudioControl::Request { request_id, enabled, redundant_opus } = AudioControl::read(message)? else {
            return Err(DeskError::invalid("声音控制消息方向无效"));
        };
        if self.starting.is_some_and(|(id, _)| id == request_id) {
            return Ok(());
        }
        self.capture = None;
        self.starting = None;
        let next_epoch = self.epoch.checked_add(1).and_then(NonZeroU32::new);
        let error = if !enabled {
            None
        } else if let Some(epoch) = next_epoch {
            match platform.start_audio_capture(epoch, redundant_opus, paused) {
                Ok(capture) => {
                    self.epoch = epoch.get();
                    self.redundant = redundant_opus;
                    self.capture = Some(capture);
                    self.starting = Some((request_id, Instant::now() + Duration::from_secs(12)));
                    return Ok(());
                }
                Err(error) => Some(error_text(error)),
            }
        } else {
            Some("音频会话代次已耗尽，请重新连接".into())
        };
        peer.send(&AudioControl::Status { request_id: Some(request_id), state: AudioState::Disabled { error } }.message()?)
    }

    pub fn pause(&self, paused: bool) {
        if let Some(capture) = &self.capture {
            capture.pause(paused);
        }
    }

    /// A device may have reported ready or failed while capture settings were changing.
    /// Deliver those events and skip just the audio samples already queued at this boundary.
    pub fn configuration_finished(&mut self, peer: &PeerHandle) -> Result<()> {
        let queued = self.capture.as_ref().map_or(0, |capture| capture.events.len());
        for _ in 0..queued {
            let Some(event) = self.capture.as_mut().and_then(|capture| capture.events.try_recv().ok()) else { break };
            self.deliver(event, true, peer, None)?;
        }
        Ok(())
    }

    pub async fn next(&mut self) -> CaptureEvent {
        let Some(capture) = self.capture.as_mut() else { return std::future::pending().await };
        if let Some((_, deadline)) = self.starting {
            timeout_at(deadline, capture.next()).await.unwrap_or_else(|_| CaptureEvent::Failed(DeskError::platform("声音采集设备启动超时")))
        } else {
            capture.next().await
        }
    }

    pub fn deliver(&mut self, event: CaptureEvent, paused: bool, peer: &PeerHandle, datagrams: Option<&DatagramPath>) -> Result<()> {
        match event {
            CaptureEvent::Ready => {
                let Some((request_id, _)) = self.starting.take() else { return Ok(()) };
                let state = AudioState::Enabled {
                    epoch: NonZeroU32::new(self.epoch).expect("active capture epoch"),
                    magic_cookie: None,
                    redundant_opus: self.redundant,
                };
                peer.send(&AudioControl::Status { request_id: Some(request_id), state }.message()?)
            }
            CaptureEvent::Packet(packet, revision) => {
                let current_run = self.capture.as_ref().is_some_and(|capture| capture.paused.borrow().revision == revision);
                if !current_run || paused || self.starting.is_some() || packet.epoch().get() != self.epoch {
                    return Ok(());
                }
                if let Some(path) = datagrams.filter(|path| path.verified()) {
                    path.send(packet.datagram());
                } else if peer.queued_send_bytes() <= 512 * 1024 {
                    peer.send(&packet.message())?;
                }
                Ok(())
            }
            CaptureEvent::Failed(error) => {
                self.capture = None;
                let request_id = self.starting.take().map(|(id, _)| id);
                peer.send(&AudioControl::Status { request_id, state: AudioState::Disabled { error: Some(error_text(error)) } }.message()?)
            }
        }
    }
}

#[derive(Default)]
pub(crate) struct ViewerAudio {
    pub supported: bool,
    desired: bool,
    playing: bool,
    epoch: Option<NonZeroU32>,
    request: Option<Uuid>,
    deadline: Option<Instant>,
    output: Option<AudioPlayback>,
}

impl ViewerAudio {
    pub fn request(&mut self, enabled: bool, peer: &PeerHandle, platform: &mut impl ViewerPlatform) -> Result<()> {
        if !self.supported || enabled == self.desired {
            return Ok(());
        }
        self.desired = enabled;
        if !enabled {
            self.stop();
        }
        let id = Uuid::new_v4();
        self.request = Some(id);
        self.deadline = Some(Instant::now() + Duration::from_secs(15));
        peer.send(&AudioControl::Request { request_id: id, enabled, redundant_opus: enabled }.message()?)?;
        platform.event(ViewerEvent::Audio { enabled: self.playing, pending: true, error: None });
        Ok(())
    }

    fn stop(&mut self) {
        self.output = None;
        self.playing = false;
        self.epoch = None;
        self.request = None;
        self.deadline = None;
    }

    fn failed(&mut self, error: DeskError, peer: &PeerHandle, platform: &mut impl ViewerPlatform) -> Result<()> {
        self.stop();
        self.desired = false;
        // Shut down capture even if a late enable succeeds after a local device failure.
        peer.send(&AudioControl::Request { request_id: Uuid::new_v4(), enabled: false, redundant_opus: false }.message()?)?;
        platform.event(ViewerEvent::Audio { enabled: false, pending: false, error: Some(error_text(error)) });
        Ok(())
    }

    pub fn status(&mut self, message: &Message, platform: &mut impl ViewerPlatform, paused: bool, peer: &PeerHandle) -> Result<()> {
        let AudioControl::Status { request_id, state } = AudioControl::read(message)? else {
            return Err(DeskError::invalid("声音状态消息方向无效"));
        };
        if request_id != self.request {
            return Ok(());
        }
        self.request = None;
        match state {
            AudioState::Disabled { error } => {
                self.stop();
                self.desired = false;
                platform.event(ViewerEvent::Audio { enabled: false, pending: false, error });
            }
            AudioState::Enabled { epoch, .. } if self.desired => {
                if self.epoch != Some(epoch) {
                    self.stop();
                    match platform.start_audio_playback(epoch, paused) {
                        Ok(output) => {
                            self.epoch = Some(epoch);
                            self.output = Some(output);
                            self.deadline = Some(Instant::now() + Duration::from_secs(12));
                        }
                        Err(error) => return self.failed(error, peer, platform),
                    }
                }
            }
            AudioState::Enabled { .. } => {}
        }
        Ok(())
    }

    pub fn pause(&self, paused: bool) {
        if let Some(output) = &self.output {
            output.pause(paused);
        }
    }

    pub fn frame(&mut self, message: &Message, paused: bool, peer: &PeerHandle, platform: &mut impl ViewerPlatform) -> Result<()> {
        if paused || self.output.is_none() {
            return Ok(());
        }
        self.play(AudioPacket::read(&message.payload)?, paused, peer, platform)
    }

    pub fn play(&mut self, packet: AudioPacket, paused: bool, peer: &PeerHandle, platform: &mut impl ViewerPlatform) -> Result<()> {
        if !paused
            && self.epoch == Some(packet.epoch())
            && let Some(output) = &self.output
            && let Err(error) = output.play(packet)
        {
            return self.failed(error, peer, platform);
        }
        Ok(())
    }

    pub async fn next(&mut self) -> PlaybackEvent {
        let wait = async { if let Some(output) = &mut self.output { output.next().await } else { std::future::pending().await } };
        if let Some(deadline) = self.deadline {
            timeout_at(deadline, wait).await.unwrap_or_else(|_| PlaybackEvent::Failed(DeskError::platform("远端声音切换超时")))
        } else {
            wait.await
        }
    }

    pub fn deliver(&mut self, event: PlaybackEvent, peer: &PeerHandle, platform: &mut impl ViewerPlatform) -> Result<()> {
        match event {
            PlaybackEvent::Ready => {
                self.deadline = None;
                self.playing = true;
                platform.event(ViewerEvent::Audio { enabled: true, pending: false, error: None });
                Ok(())
            }
            PlaybackEvent::Failed(error) => self.failed(error, peer, platform),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::{AudioEncoder, DATAGRAM_KIND, INTERLEAVED_SAMPLES};
    use crate::datagram_path::PathEvent;
    use crate::media::{MediaControl, MediaOperation, ViewerMedia};
    use crate::peer::{self, PeerConfig, PeerEvent};
    use crate::wire::MessageKind;

    #[tokio::test]
    async fn reconfiguration_drops_stale_sound_and_preserves_device_readiness_and_failure() {
        let (left, right) = tokio::io::duplex(8192);
        let (control, _) = peer::spawn(left, PeerConfig::default());
        let (_other, mut messages) = peer::spawn(right, PeerConfig::default());
        let (capture, worker) = AudioCapture::channel(false);
        let epoch = NonZeroU32::new(1).unwrap();
        let id = Uuid::new_v4();
        let mut audio =
            HostAudio { capture: Some(capture), epoch: epoch.get(), starting: Some((id, Instant::now() + Duration::from_secs(2))), ..Default::default() };
        let mut encoder = AudioEncoder::new(epoch, false).unwrap();
        worker.events.try_send(CaptureEvent::Ready).unwrap();
        worker.events.try_send(CaptureEvent::Packet(encoder.encode(&[0.0; INTERLEAVED_SAMPLES]).unwrap(), 0)).unwrap();
        audio.configuration_finished(&control).unwrap();
        let fresh = encoder.encode(&[0.0; INTERLEAVED_SAMPLES]).unwrap();
        let expected = fresh.sequence();
        worker.events.try_send(CaptureEvent::Packet(fresh, 0)).unwrap();
        let event = audio.next().await;
        audio.deliver(event, false, &control, None).unwrap();
        worker.events.try_send(CaptureEvent::Failed(DeskError::platform("synthetic device stopped"))).unwrap();
        audio.configuration_finished(&control).unwrap();
        tokio::time::timeout(Duration::from_secs(1),async {
            for (index,kind) in [MessageKind::AudioControl,MessageKind::AudioFrame,MessageKind::AudioControl].into_iter().enumerate() {
                let message=loop { if let Some(PeerEvent::Message(message))=messages.recv().await { break message; } };
                assert_eq!(message.kind,kind);
                match index {
                    0 => assert!(matches!(AudioControl::read(&message).unwrap(),AudioControl::Status{request_id:Some(request),state:AudioState::Enabled{..}} if request==id)),
                    1 => assert_eq!(AudioPacket::read(&message.payload).unwrap().sequence(),expected),
                    _ => assert!(matches!(AudioControl::read(&message).unwrap(),AudioControl::Status{state:AudioState::Disabled{error:Some(error)},..} if error.contains("synthetic device stopped"))),
                }
            }
        }).await.unwrap();
        assert!(audio.capture.is_none());
        assert_eq!(worker.paused.borrow().revision, 0);
    }

    #[tokio::test]
    async fn verified_audio_uses_one_dtls_record_and_lost_or_legacy_paths_resume_on_control() {
        let address = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let offer = MediaControl {
            operation: MediaOperation::Offer,
            session_id: Some(Uuid::new_v4()),
            datagram_key: Some(vec![17; 32]),
            path: Some("udp".into()),
            ..ViewerMedia::request()
        };
        let mut server = DatagramPath::new(Some(address));
        let mut client = DatagramPath::new(Some(address));
        assert!(server.offer(&offer, true));
        assert!(client.offer(&offer, false));
        let (left, right) = tokio::io::duplex(8192);
        let (control, _) = peer::spawn(left, PeerConfig::default());
        let (_control, mut replies) = peer::spawn(right, PeerConfig::default());
        let (capture, _worker) = AudioCapture::channel(false);
        let epoch = NonZeroU32::new(7).unwrap();
        let mut audio = HostAudio { capture: Some(capture), epoch: epoch.get(), ..Default::default() };
        let mut encoder = AudioEncoder::new(epoch, true).unwrap();
        let mut packet = || encoder.encode(&[0.0; INTERLEAVED_SAMPLES]).unwrap();

        tokio::time::timeout(Duration::from_secs(5), async {
            let before = packet();
            audio.deliver(CaptureEvent::Packet(before.clone(), 0), false, &control, Some(&server)).unwrap();
            let (client_event, server_event) = tokio::join!(client.next(), server.next());
            assert!(matches!((client_event, server_event), (PathEvent::Verified, PathEvent::Verified)));
            let via_dtls = packet();
            audio.deliver(CaptureEvent::Packet(via_dtls.clone(), 0), false, &control, Some(&server)).unwrap();
            let PathEvent::Record(DATAGRAM_KIND, record) = client.next().await else {
                panic!("missing verified audio datagram");
            };
            assert_eq!(AudioPacket::read(&record[1..]).unwrap(), via_dtls);
            assert!(via_dtls.previous_opus_payload().is_some());

            audio.pause(true);
            audio.deliver(CaptureEvent::Packet(packet(), 1), true, &control, Some(&server)).unwrap();
            audio.pause(false);
            audio.deliver(CaptureEvent::Packet(packet(), 0), false, &control, Some(&server)).unwrap();
            let current = packet();
            audio.deliver(CaptureEvent::Packet(current.clone(), 2), false, &control, Some(&server)).unwrap();
            assert!(matches!(client.next().await,PathEvent::Record(DATAGRAM_KIND,bytes) if AudioPacket::read(&bytes[1..]).unwrap()==current));

            let legacy = packet();
            audio.deliver(CaptureEvent::Packet(legacy.clone(), 2), false, &control, None).unwrap();
            server.retire();
            let after = packet();
            audio.deliver(CaptureEvent::Packet(after.clone(), 2), false, &control, Some(&server)).unwrap();
            for expected in [before, legacy, after] {
                loop {
                    match replies.recv().await.unwrap() {
                        PeerEvent::Message(message) => {
                            assert_eq!(message.kind, MessageKind::AudioFrame);
                            assert_eq!(AudioPacket::read(&message.payload).unwrap(), expected);
                            break;
                        }
                        PeerEvent::RoundTrip(_) => {}
                        PeerEvent::Closed(error) => panic!("{error}"),
                    }
                }
            }
        })
        .await
        .unwrap();
    }
}
