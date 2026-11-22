//! Bounded connections between one authenticated desktop and its audio device workers.
use crate::audio::{AudioControl, AudioPacket, AudioState};
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

    pub async fn next(&mut self) -> CaptureEvent {
        let Some(capture) = self.capture.as_mut() else { return std::future::pending().await };
        if let Some((_, deadline)) = self.starting {
            timeout_at(deadline, capture.next()).await.unwrap_or_else(|_| CaptureEvent::Failed(DeskError::platform("声音采集设备启动超时")))
        } else {
            capture.next().await
        }
    }

    pub fn deliver(&mut self, event: CaptureEvent, paused: bool, peer: &PeerHandle) -> Result<()> {
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
                if current_run && !paused && self.starting.is_none() && packet.epoch().get() == self.epoch && peer.queued_send_bytes() <= 512 * 1024 {
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
        let Some(output) = &self.output else { return Ok(()) };
        if paused {
            return Ok(());
        }
        let packet = AudioPacket::read(&message.payload)?;
        if self.epoch == Some(packet.epoch())
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
