//! The host side of a session: the role of `DeskModel.accept` and `handleHost` in the macOS application,
//! for a host that streams over the control connection and advertises only what it implements.

use crate::error::{DeskError, Result};
use crate::input::{HostInputTranslator, InjectOp};
use crate::keymap::MacModifierMapping;
use crate::media::{Gate, HostFrame, HostMedia, HostMediaEvent, MediaControl, MediaFeedback, MediaOperation};
use crate::messages::{
    ControlStatus, HOST_ENDED_REASON, Hello, RemoteInput, SessionPauseRequest, SessionPauseResult, SessionTermination, StreamSettings, StreamSettingsRequest,
    StreamSettingsResult, TerminationOperation, VideoCodec, VideoStreamState,
};
use crate::peer::{PeerEvent, PeerHandle};
use crate::video::EncodedFrame;
use crate::wire::{self, Message, MessageKind};
use std::collections::VecDeque;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::Instant;

/// How long a host that announced `initialStreamNegotiationV1` waits for the viewer's first settings
/// before it starts with the ones in its hello.
const INITIAL_SETTINGS_GRACE: Duration = Duration::from_millis(250);

struct CapturedFrame {
    generation: u64,
    frame: EncodedFrame,
}

struct FrameWindow {
    outstanding: usize,
    gate: Gate,
    generation: u64,
    key_submitted: bool,
}

impl FrameWindow {
    fn new(gate: Gate) -> Self {
        Self { outstanding: 0, gate, generation: 0, key_submitted: false }
    }

    fn set_gate(&mut self, gate: Gate) {
        if self.gate != gate {
            self.gate = gate;
            self.generation = self.generation.wrapping_add(1);
            self.key_submitted = false;
        }
    }

    fn has_credit(&self) -> bool {
        self.outstanding < FrameSink::WINDOW && (self.gate == Gate::Open || (self.gate == Gate::One && !self.key_submitted))
    }
}

/// Where the capture pipeline delivers encoded frames, and how it learns that the viewer keeps up.
#[derive(Clone)]
pub struct FrameSink {
    frames: mpsc::UnboundedSender<CapturedFrame>,
    window: Arc<Mutex<FrameWindow>>,
}

impl FrameSink {
    /// Frames a viewer may have received without acknowledging, as released viewers expect.
    pub const WINDOW: usize = 3;

    /// Whether another frame may be encoded. A frame produced without credit only adds delay.
    pub fn has_credit(&self) -> bool {
        self.window.lock().unwrap().has_credit()
    }

    /// Frames queued at capture or waiting for the viewer to acknowledge them.
    pub fn outstanding(&self) -> usize {
        self.window.lock().unwrap().outstanding
    }

    /// Hands over one frame; false once the stream it belongs to has been replaced or the session ended.
    pub fn submit(&self, frame: EncodedFrame) -> bool {
        let mut window = self.window.lock().unwrap();
        if self.frames.is_closed() {
            return false;
        }
        // Capture may have started encoding just before a prepare closed the gate. Only an IDR
        // may consume the single permit; a queued frame from an older gate cannot consume it again.
        if !window.has_credit() || (window.gate == Gate::One && !frame.is_key_frame()) {
            return true;
        }
        if self.frames.send(CapturedFrame { generation: window.generation, frame }).is_err() {
            return false;
        }
        window.outstanding += 1;
        window.key_submitted = window.gate == Gate::One;
        true
    }
}

/// What a host needs from its machine. The session calls these from one task, never concurrently.
pub trait HostPlatform {
    /// Pixel size of the display that will be shared.
    fn display_size(&mut self) -> Result<(u32, u32)>;
    /// Starts or restarts capture and encoding with these settings, delivering to `frames` from a keyframe on.
    /// Returns the size actually encoded and the settings actually in effect.
    fn configure(&mut self, settings: StreamSettings, frames: FrameSink) -> impl Future<Output = Result<VideoStreamState>> + Send;
    /// Finishes any in-progress encode and arms a keyframe of the current screen before the gate opens.
    fn request_key_frame(&mut self) -> impl Future<Output = Result<()>> + Send;
    /// Stops or resumes frame production; a resumed stream continues with a keyframe of the current screen.
    fn set_paused(&mut self, paused: bool) -> impl Future<Output = Result<()>> + Send;
    fn inject(&mut self, operations: &[InjectOp]);
    fn clipboard_text(&mut self) -> Option<String>;
    fn set_clipboard_text(&mut self, text: &str) -> Result<()>;
    fn stop(&mut self);
}

#[derive(Clone, Debug)]
pub struct HostOptions {
    pub name: String,
    pub allow_control: bool,
    /// Whether the viewer may read and write the clipboard text with the manual clipboard messages.
    pub clipboard: bool,
    /// The quality a viewer without a preference of its own receives.
    pub preferred: StreamSettings,
    /// The most this host encodes, whatever a viewer asks for.
    pub limit: StreamSettings,
    pub modifiers: MacModifierMapping,
}

#[derive(Debug)]
pub enum HostCommand {
    /// The user ended the session; a subscribed viewer is told so and does not reconnect by itself.
    End,
    AllowControl(bool),
    Clipboard(bool),
}

#[derive(Clone, Debug, PartialEq)]
pub enum HostEvent {
    Streaming(VideoStreamState),
    Paused(bool),
    RoundTrip(f64),
}

struct HostSession<'a, P: HostPlatform> {
    peer: &'a PeerHandle,
    platform: &'a mut P,
    options: HostOptions,
    display: (u32, u32),
    translator: HostInputTranslator,
    /// `None` until the stream has started.
    state: Option<VideoStreamState>,
    frames: Option<mpsc::UnboundedReceiver<CapturedFrame>>,
    window: Arc<Mutex<FrameWindow>>,
    media: HostMedia,
    recover_after: Instant,
    unacknowledged: VecDeque<u32>,
    sequence: u32,
    paused: bool,
    control_subscribed: bool,
    termination_subscribed: bool,
}

/// Runs one viewer's session until it ends and returns why. `events` reports state for the user interface.
pub async fn run<P: HostPlatform>(
    peer: PeerHandle,
    mut incoming: mpsc::Receiver<PeerEvent>,
    platform: &mut P,
    options: HostOptions,
    mut commands: mpsc::UnboundedReceiver<HostCommand>,
    events: impl Fn(HostEvent),
) -> DeskError {
    let translator = HostInputTranslator::new(options.modifiers);
    let mut session = HostSession {
        peer: &peer,
        platform,
        options,
        display: (0, 0),
        translator,
        state: None,
        frames: None,
        window: Arc::new(Mutex::new(FrameWindow::new(Gate::Open))),
        media: HostMedia::default(),
        recover_after: Instant::now(),
        unacknowledged: VecDeque::new(),
        sequence: 0,
        paused: false,
        control_subscribed: false,
        termination_subscribed: false,
    };
    let reason = session.serve(&mut incoming, &mut commands, &events).await;
    let released = session.translator.release_all();
    session.platform.inject(&released);
    session.platform.stop();
    peer.close();
    reason
}

impl<P: HostPlatform> HostSession<'_, P> {
    async fn serve(
        &mut self,
        incoming: &mut mpsc::Receiver<PeerEvent>,
        commands: &mut mpsc::UnboundedReceiver<HostCommand>,
        events: &impl Fn(HostEvent),
    ) -> DeskError {
        let initial = match self.announce() {
            Ok(settings) => settings,
            Err(error) => return error,
        };
        let start_by = Instant::now() + INITIAL_SETTINGS_GRACE;
        loop {
            let media_deadline = self.media.deadline().into_iter().chain(self.media.recovery().map(|_| self.recover_after)).min();
            let outcome = tokio::select! {
                event = incoming.recv() => match event {
                    Some(PeerEvent::Message(message)) => self.receive(message, events).await,
                    Some(PeerEvent::RoundTrip(milliseconds)) => { events(HostEvent::RoundTrip(milliseconds)); Ok(()) }
                    Some(PeerEvent::Closed(reason)) => Err(reason),
                    None => Err(DeskError::Network("连接已关闭".to_string())),
                },
                _ = tokio::time::sleep_until(start_by), if self.state.is_none() => self.start(initial, events).await.map(drop),
                _ = tokio::time::sleep_until(media_deadline.unwrap_or(start_by)), if !self.paused && media_deadline.is_some() => self.tick_media(),
                frame = next_frame(&mut self.frames) => self.send_frame(frame),
                command = commands.recv() => match command {
                    Some(HostCommand::End) | None => Err(self.end()),
                    Some(HostCommand::AllowControl(allowed)) => self.allow_control(allowed),
                    Some(HostCommand::Clipboard(enabled)) => { self.options.clipboard = enabled; Ok(()) }
                },
            };
            if let Err(reason) = outcome {
                return reason;
            }
        }
    }

    /// Sends the hello. Its settings are the ones the stream starts with unless the viewer asks first.
    fn announce(&mut self) -> Result<StreamSettings> {
        self.display = self.platform.display_size()?;
        let preferred = self.options.preferred.limited_to(&self.options.limit);
        let initial = preferred.legacy_compatible();
        let (width, height) = initial.dimensions(self.display.0, self.display.1);
        self.peer.send(&Message::json(
            MessageKind::Hello,
            &Hello {
                version: wire::VERSION,
                name: self.options.name.clone(),
                width: i64::from(width),
                height: i64::from(height),
                settings: initial,
                can_control: self.options.allow_control,
                live_settings: Some(true),
                control_status_updates: Some(true),
                extended_video_settings: Some(true),
                preferred_settings: Some(preferred.extended_compatible()),
                high_refresh_video_settings: Some(true),
                preferred_high_refresh_settings: Some(preferred.high_refresh_compatible()),
                session_pause: Some(true),
                media_transport_v1: Some(true),
                session_termination_v1: Some(true),
                initial_stream_negotiation_v1: Some(true),
            },
        )?)?;
        Ok(initial)
    }

    async fn start(&mut self, settings: StreamSettings, events: &impl Fn(HostEvent)) -> Result<VideoStreamState> {
        if self.state.take().is_some() {
            self.interrupt_media()?;
        }
        let (sender, receiver) = mpsc::unbounded_channel();
        // Frames of the previous stream may still be queued; a new channel and counter leave them behind.
        self.window = Arc::new(Mutex::new(FrameWindow::new(self.capture_gate())));
        self.unacknowledged.clear();
        self.frames = None;
        let state = self.platform.configure(settings, FrameSink { frames: sender, window: self.window.clone() }).await?;
        if self.paused {
            self.platform.set_paused(true).await?;
        }
        self.frames = Some(receiver);
        self.state = Some(state);
        self.finish_preparation()?;
        events(HostEvent::Streaming(state));
        Ok(state)
    }

    fn send_frame(&mut self, frame: Option<CapturedFrame>) -> Result<()> {
        let Some(captured) = frame else {
            return Err(DeskError::platform("屏幕采集已停止"));
        };
        if self.paused || captured.generation != self.window.lock().unwrap().generation {
            self.settle(1);
            return Ok(());
        }
        self.sequence = self.sequence.wrapping_add(1);
        match self.media.frame(self.sequence, captured.frame)? {
            HostFrame::Legacy(packet) => {
                self.unacknowledged.push_back(self.sequence);
                self.peer.send(&Message::new(MessageKind::Video, packet.encode()?))?;
            }
            HostFrame::Media(message) => self.peer.send(&message)?,
            HostFrame::Dropped => self.settle(1),
        }
        self.sync_gate();
        Ok(())
    }

    fn capture_gate(&self) -> Gate {
        if self.paused { Gate::Closed } else { self.media.gate() }
    }

    fn sync_gate(&self) {
        self.window.lock().unwrap().set_gate(self.capture_gate());
    }

    fn settle(&self, count: usize) {
        self.window.lock().unwrap().outstanding -= count;
    }

    fn send_control(&mut self, control: MediaControl) -> Result<()> {
        if control.operation == MediaOperation::Recover {
            self.recover_after = Instant::now() + Duration::from_secs(1);
        }
        self.peer.send(&control.message()?)
    }

    fn finish_preparation(&mut self) -> Result<()> {
        if let Some(ready) = self.media.prepared() {
            self.send_control(ready)?;
        }
        Ok(())
    }

    async fn receive_control(&mut self, control: MediaControl) -> Result<()> {
        for event in self.media.control(&control, self.paused)? {
            match event {
                HostMediaEvent::Send(reply) => self.send_control(*reply)?,
                HostMediaEvent::Prepare(_) => {
                    self.sync_gate();
                    self.settle(self.unacknowledged.len());
                    self.unacknowledged.clear();
                    if self.state.is_some() {
                        self.finish_preparation()?;
                    }
                }
                HostMediaEvent::ProduceKeyFrame => {
                    let deadline = self.media.deadline().expect("an opening stream has a transaction deadline");
                    match tokio::time::timeout_at(deadline, self.platform.request_key_frame()).await {
                        Ok(result) => result?,
                        Err(_) => self.tick_media()?,
                    }
                }
                HostMediaEvent::Settled(count) => self.settle(count),
            }
        }
        self.sync_gate();
        Ok(())
    }

    fn apply_media_update(&mut self, (settled, controls): (usize, Vec<MediaControl>)) -> Result<()> {
        self.sync_gate();
        self.settle(settled);
        for control in controls {
            self.send_control(control)?;
        }
        Ok(())
    }

    fn interrupt_media(&mut self) -> Result<()> {
        let update = self.media.interrupted();
        self.apply_media_update(update)
    }

    fn tick_media(&mut self) -> Result<()> {
        let now = Instant::now();
        let update = self.media.expire(now);
        self.apply_media_update(update)?;
        if now >= self.recover_after
            && let Some(recover) = self.media.recovery()
        {
            self.send_control(recover)?;
        }
        Ok(())
    }

    fn end(&mut self) -> DeskError {
        if self.termination_subscribed
            && let Ok(message) = Message::json(MessageKind::SessionTermination, &SessionTermination { operation: TerminationOperation::Ended })
        {
            let _ = self.peer.send(&message);
        }
        DeskError::Network(HOST_ENDED_REASON.to_string())
    }

    fn allow_control(&mut self, allowed: bool) -> Result<()> {
        if self.options.allow_control == allowed {
            return Ok(());
        }
        self.options.allow_control = allowed;
        if !allowed {
            let released = self.translator.release_all();
            self.platform.inject(&released);
        }
        if self.control_subscribed {
            self.peer.send(&Message::json(MessageKind::ControlStatus, &ControlStatus { can_control: allowed })?)?;
        }
        Ok(())
    }

    async fn receive(&mut self, message: Message, events: &impl Fn(HostEvent)) -> Result<()> {
        match message.kind {
            MessageKind::Input => {
                let input: RemoteInput = message.read_json()?;
                input.validate()?;
                if self.options.allow_control && !self.paused && self.state.is_some() {
                    let operations = self.translator.translate(&input);
                    self.platform.inject(&operations);
                }
            }
            MessageKind::ReleaseInput => {
                let released = self.translator.release_all();
                self.platform.inject(&released);
            }
            MessageKind::Acknowledgement => {
                let sequence = u32::from_be_bytes(message.payload[..].try_into().map_err(|_| DeskError::invalid("画面确认无效"))?);
                if let Some(position) = self.unacknowledged.iter().position(|sent| *sent == sequence) {
                    self.unacknowledged.remove(position);
                    self.settle(1);
                }
            }
            MessageKind::MediaControl => self.receive_control(MediaControl::read(&message)?).await?,
            MessageKind::MediaFeedback => {
                let feedback = MediaFeedback::decode(&message.payload)?;
                let update = self.media.feedback(&feedback);
                self.apply_media_update(update)?;
            }
            MessageKind::StreamSettingsRequest => {
                let request: StreamSettingsRequest = message.read_json()?;
                self.apply_settings(request, events).await?;
            }
            MessageKind::SessionPauseRequest => {
                let request: SessionPauseRequest = message.read_json()?;
                let released = self.translator.release_all();
                self.platform.inject(&released);
                if self.paused && !request.paused {
                    self.interrupt_media()?;
                }
                let error = match self.platform.set_paused(request.paused).await {
                    Ok(()) => {
                        self.paused = request.paused;
                        if self.paused
                            && let Some(abort) = self.media.paused()
                        {
                            self.send_control(abort)?;
                        }
                        self.sync_gate();
                        events(HostEvent::Paused(self.paused));
                        None
                    }
                    Err(error) => Some(error.to_string()),
                };
                let result = SessionPauseResult { id: request.id, paused: self.paused, error };
                self.peer.send(&Message::json(MessageKind::SessionPauseResult, &result)?)?;
            }
            MessageKind::ControlStatus => {
                if !message.payload.is_empty() {
                    return Err(DeskError::invalid("控制权限订阅消息无效"));
                }
                self.control_subscribed = true;
                let status = ControlStatus { can_control: self.options.allow_control };
                self.peer.send(&Message::json(MessageKind::ControlStatus, &status)?)?;
            }
            MessageKind::SessionTermination => {
                let notice: SessionTermination = message.read_json()?;
                if notice.operation != TerminationOperation::Subscribe {
                    return Err(DeskError::invalid("结束连接消息方向无效"));
                }
                self.termination_subscribed = true;
            }
            MessageKind::Clipboard => {
                let text = String::from_utf8(message.payload).ok().filter(|text| text.len() <= wire::MAXIMUM_CLIPBOARD_BYTES);
                let text = text.ok_or_else(|| DeskError::invalid("剪贴板文字过大或编码无效"))?;
                if self.options.clipboard
                    && let Err(error) = self.platform.set_clipboard_text(&text)
                {
                    log::warn!("clipboard text from the viewer was not stored: {error}");
                }
            }
            MessageKind::RequestClipboard => {
                let text = if self.options.clipboard { self.platform.clipboard_text() } else { None };
                if let Some(text) = text.filter(|text| text.len() <= wire::MAXIMUM_CLIPBOARD_BYTES) {
                    self.peer.send(&Message::new(MessageKind::Clipboard, text.into_bytes()))?;
                }
            }
            _ => return Err(DeskError::invalid("收到当前角色不支持的消息")),
        }
        Ok(())
    }

    async fn apply_settings(&mut self, request: StreamSettingsRequest, events: &impl Fn(HostEvent)) -> Result<()> {
        let reply = |state: VideoStreamState, error: Option<String>| StreamSettingsResult {
            id: request.id,
            state,
            error,
            // This host encodes H.264 only; a viewer that named a codec hears which one it gets.
            codec: request.codec.map(|_| VideoCodec::H264),
            chroma_subsampling: request.chroma_subsampling.map(|_| crate::messages::ChromaSubsampling::Yuv420),
        };
        let requested = match request.settings.validate_control_values() {
            Ok(()) => request.settings.limited_to(&self.options.limit),
            Err(error) => {
                // Before the stream exists there is no state to report; the request is answered once it does.
                let state = match self.state {
                    Some(state) => state,
                    None => self.start(self.options.preferred.limited_to(&self.options.limit).legacy_compatible(), events).await?,
                };
                return self.peer.send(&Message::json(MessageKind::StreamSettingsResult, &reply(state, Some(error.to_string())))?);
            }
        };
        let result = match self.state {
            Some(state) if state.settings == requested => reply(state, None),
            previous => match self.start(requested, events).await {
                Ok(state) => reply(state, None),
                Err(error) => {
                    // The failed attempt stopped the stream. Return to what worked, or end the session.
                    let Some(previous) = previous else { return Err(error) };
                    log::warn!("stream settings {requested:?} failed, restoring {:?}: {error}", previous.settings);
                    reply(self.start(previous.settings, events).await?, Some(error.to_string()))
                }
            },
        };
        self.peer.send(&Message::json(MessageKind::StreamSettingsResult, &result)?)
    }
}

async fn next_frame(frames: &mut Option<mpsc::UnboundedReceiver<CapturedFrame>>) -> Option<CapturedFrame> {
    match frames {
        Some(frames) => frames.recv().await,
        None => std::future::pending().await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_gate_change_fences_queued_frames_and_only_one_keyframe_consumes_the_permit() {
        let (frames, mut queue) = mpsc::unbounded_channel();
        let window = Arc::new(Mutex::new(FrameWindow::new(Gate::Open)));
        let sink = FrameSink { frames, window: window.clone() };
        let key = EncodedFrame { sps: vec![0x67, 1], pps: vec![0x68, 2], avcc: vec![0, 0, 0, 2, 0x65, 3] };
        let delta = EncodedFrame { sps: vec![], pps: vec![], avcc: vec![0, 0, 0, 2, 0x41, 4] };
        assert!(sink.submit(key.clone()));
        window.lock().unwrap().set_gate(Gate::Closed);
        assert!(!sink.has_credit());
        assert!(sink.submit(delta.clone()));
        window.lock().unwrap().set_gate(Gate::One);
        assert!(sink.submit(delta.clone()));
        assert!(sink.has_credit(), "a dependent frame was finishing when capture heard the request");
        assert!(sink.submit(key.clone()));
        window.lock().unwrap().set_gate(Gate::One);
        assert!(!sink.has_credit(), "unrelated messages cannot reopen the permit");
        assert!(sink.submit(delta));
        assert!(sink.submit(key));
        let stale = queue.try_recv().unwrap();
        let current = queue.try_recv().unwrap();
        assert_ne!(stale.generation, current.generation);
        assert_eq!(current.generation, window.lock().unwrap().generation);
        assert!(queue.try_recv().is_err());
        assert_eq!(sink.outstanding(), 2);
    }
}
