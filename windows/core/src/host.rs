//! The host side of a session: the role of `DeskModel.accept` and `handleHost` in the macOS application,
//! for a host that streams over the control connection and advertises only what it implements.

use crate::error::{DeskError, Result};
use crate::input::{HostInputTranslator, InjectOp};
use crate::keymap::MacModifierMapping;
use crate::messages::{
    ControlStatus, HOST_ENDED_REASON, Hello, RemoteInput, SessionPauseRequest, SessionPauseResult, SessionTermination, StreamSettings, StreamSettingsRequest,
    StreamSettingsResult, TerminationOperation, VideoCodec, VideoStreamState,
};
use crate::peer::{PeerEvent, PeerHandle};
use crate::video::{EncodedFrame, VideoPacket};
use crate::wire::{self, Message, MessageKind};
use std::collections::VecDeque;
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::Instant;

/// How long a host that announced `initialStreamNegotiationV1` waits for the viewer's first settings
/// before it starts with the ones in its hello.
const INITIAL_SETTINGS_GRACE: Duration = Duration::from_millis(250);

/// Where the capture pipeline delivers encoded frames, and how it learns that the viewer keeps up.
#[derive(Clone)]
pub struct FrameSink {
    frames: mpsc::UnboundedSender<EncodedFrame>,
    outstanding: Arc<AtomicUsize>,
}

impl FrameSink {
    /// Frames a viewer may have received without acknowledging, as released viewers expect.
    pub const WINDOW: usize = 3;

    /// Whether another frame may be encoded. A frame produced without credit only adds delay.
    pub fn has_credit(&self) -> bool {
        self.outstanding.load(Ordering::Acquire) < Self::WINDOW
    }

    /// Hands over one frame; false once the stream it belongs to has been replaced or the session ended.
    pub fn submit(&self, frame: EncodedFrame) -> bool {
        self.outstanding.fetch_add(1, Ordering::AcqRel);
        self.frames.send(frame).is_ok()
    }
}

/// What a host needs from its machine. The session calls these from one task, never concurrently.
pub trait HostPlatform {
    /// Pixel size of the display that will be shared.
    fn display_size(&mut self) -> Result<(u32, u32)>;
    /// Starts or restarts capture and encoding with these settings, delivering to `frames` from a keyframe on.
    /// Returns the size actually encoded and the settings actually in effect.
    fn configure(&mut self, settings: StreamSettings, frames: FrameSink) -> impl Future<Output = Result<VideoStreamState>> + Send;
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
    frames: Option<mpsc::UnboundedReceiver<EncodedFrame>>,
    outstanding: Arc<AtomicUsize>,
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
        outstanding: Arc::new(AtomicUsize::new(0)),
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
            let outcome = tokio::select! {
                event = incoming.recv() => match event {
                    Some(PeerEvent::Message(message)) => self.receive(message, events).await,
                    Some(PeerEvent::RoundTrip(milliseconds)) => { events(HostEvent::RoundTrip(milliseconds)); Ok(()) }
                    Some(PeerEvent::Closed(reason)) => Err(reason),
                    None => Err(DeskError::Network("连接已关闭".to_string())),
                },
                _ = tokio::time::sleep_until(start_by), if self.state.is_none() => self.start(initial, events).await.map(drop),
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
                session_termination_v1: Some(true),
                initial_stream_negotiation_v1: Some(true),
            },
        )?)?;
        Ok(initial)
    }

    async fn start(&mut self, settings: StreamSettings, events: &impl Fn(HostEvent)) -> Result<VideoStreamState> {
        let (sender, receiver) = mpsc::unbounded_channel();
        // Frames of the previous stream may still be queued; a new channel and counter leave them behind.
        self.outstanding = Arc::new(AtomicUsize::new(0));
        self.unacknowledged.clear();
        self.frames = None;
        let state = self.platform.configure(settings, FrameSink { frames: sender, outstanding: self.outstanding.clone() }).await?;
        self.frames = Some(receiver);
        self.state = Some(state);
        events(HostEvent::Streaming(state));
        Ok(state)
    }

    fn send_frame(&mut self, frame: Option<EncodedFrame>) -> Result<()> {
        let Some(frame) = frame else {
            return Err(DeskError::platform("屏幕采集已停止"));
        };
        if self.paused {
            self.outstanding.fetch_sub(1, Ordering::AcqRel);
            return Ok(());
        }
        self.sequence = self.sequence.wrapping_add(1);
        self.unacknowledged.push_back(self.sequence);
        self.peer.send(&Message::new(MessageKind::Video, VideoPacket::h264(self.sequence, frame).encode()?))
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
                    self.outstanding.fetch_sub(1, Ordering::AcqRel);
                }
            }
            MessageKind::StreamSettingsRequest => {
                let request: StreamSettingsRequest = message.read_json()?;
                self.apply_settings(request, events).await?;
            }
            MessageKind::SessionPauseRequest => {
                let request: SessionPauseRequest = message.read_json()?;
                let released = self.translator.release_all();
                self.platform.inject(&released);
                let error = match self.platform.set_paused(request.paused).await {
                    Ok(()) => {
                        self.paused = request.paused;
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

async fn next_frame(frames: &mut Option<mpsc::UnboundedReceiver<EncodedFrame>>) -> Option<EncodedFrame> {
    match frames {
        Some(frames) => frames.recv().await,
        None => std::future::pending().await,
    }
}
