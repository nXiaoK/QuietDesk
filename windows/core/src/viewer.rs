//! The viewer side of a session: the role of `DeskModel.handleViewer` in the macOS application, for a
//! viewer that negotiates its media paths and platform capabilities with the host.

use crate::audio_session::{AudioPlayback, ViewerAudio};
use crate::auxiliary::{Auxiliary, AuxiliaryEvent};
use crate::clipboard_session::SessionClipboard;
use crate::cursor::{CursorControl, CursorOperation, CursorPosition, CursorPresentationState, CursorShape};
use crate::datagram_path::{DatagramPath, PathEvent};
use crate::display::{DisplayControl, RemoteDisplayInfo};
use crate::error::{DeskError, Result};
use crate::media::fragment::{ReceiveEvent, Receiver};
use crate::media::{DecodeReceipt, MediaControl, MediaStreamId, ViewerMedia, ViewerMediaEvent};
use crate::media::{FeedbackKind, MediaFeedback, MediaOperation, MediaPath};
use crate::messages::{
    ControlStatus, DeviceIdentity, HOST_ENDED_REASON, Hello, InputFeedback, RemoteInput, SessionPauseRequest, SessionPauseResult, SessionTermination,
    StreamSettings, StreamSettingsRequest, StreamSettingsResult, TerminationOperation, VideoCodec, VideoStreamState, device_display_name,
};
use crate::peer::{PeerEvent, PeerHandle, input_echo};
use crate::reliability::{Attempt, AttemptProgress};
use crate::tls::AuxiliaryRole;
use crate::video::VideoPacket;
use crate::wire::{self, Message, MessageKind};
use std::collections::VecDeque;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::Instant;
use uuid::Uuid;

/// A host that authenticated but never describes its screen is treated as failed.
const HELLO_TIMEOUT: Duration = Duration::from_secs(30);
/// How long a requested clipboard text is still accepted.
const CLIPBOARD_REPLY_TIMEOUT: Duration = Duration::from_secs(5);
const INPUT_REPLY_TIMEOUT: Duration = Duration::from_secs(6);
/// A host that does not confirm a quality change in this time has stopped responding.
const SETTINGS_REPLY_TIMEOUT: Duration = Duration::from_secs(25);

#[derive(Debug)]
pub enum ViewerCommand {
    Input(RemoteInput),
    /// The window lost the keyboard: the host lets go of every key and button.
    ReleaseInput,
    Quality(StreamSettings),
    SelectDisplay(u32),
    RemoteAudio(bool),
    SendClipboard(String),
    RequestClipboard,
    AutomaticClipboard {
        enabled: bool,
        receives: bool,
    },
    /// Stops or resumes the picture while keeping the session, when the host supports it.
    Pause(bool),
    Disconnect,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ViewerEvent {
    Connected {
        name: String,
        device_id: Option<Uuid>,
        can_control: bool,
        stream: VideoStreamState,
        live_settings: bool,
        session_pause: bool,
        input_actions: bool,
        relative_mouse: bool,
        trackpad_gestures: bool,
        clipboard_sync: bool,
        remote_audio: bool,
    },
    /// The stream now has this size and quality; `error` says why a requested change was not applied.
    Stream {
        stream: VideoStreamState,
        error: Option<String>,
    },
    /// The viewer committed this stream after decoding its first keyframe and receiving the host's commit.
    MediaCommitted(MediaStreamId),
    Cursor(Arc<CursorPresentationState>),
    Control(bool),
    InputStatus(InputFeedback),
    InputActionTimeout,
    Displays {
        displays: Vec<RemoteDisplayInfo>,
        selected: Option<u32>,
        pending: Option<u32>,
        error: Option<String>,
        /// Local capture geometry that subsequently received pictures belong to.
        revision: u64,
    },
    Paused {
        paused: bool,
        error: Option<String>,
    },
    RoundTrip(f64),
    ClipboardText(String),
    ClipboardStatus(String),
    Audio {
        enabled: bool,
        pending: bool,
        error: Option<String>,
    },
}

/// Why a session ended.
#[derive(Debug)]
pub struct ViewerEnd {
    pub reason: String,
    /// The host's user ended the session on purpose; reconnecting would be unwelcome.
    pub host_ended: bool,
    pub retryable: bool,
    /// The viewer's owner requested the stop or closed its command channel.
    pub local_stop: bool,
}

impl ViewerEnd {
    pub(crate) fn stopped(reason: &str) -> Self {
        Self { reason: reason.into(), host_ended: false, retryable: false, local_stop: true }
    }

    pub fn should_retry(&self, auto_reconnect: bool) -> bool {
        auto_reconnect && self.retryable && !self.host_ended
    }
}

impl From<DeskError> for ViewerEnd {
    fn from(error: DeskError) -> Self {
        Self { retryable: error.is_retryable(), reason: error.to_string(), host_ended: false, local_stop: false }
    }
}

pub trait ViewerPlatform {
    fn supports_audio_playback(&self) -> bool {
        false
    }
    fn start_audio_playback(&mut self, _epoch: std::num::NonZeroU32, _paused: bool) -> Result<AudioPlayback> {
        Err(DeskError::platform("当前系统不支持播放远端声音"))
    }
    fn open_clipboard(&mut self) -> Option<SessionClipboard> {
        None
    }
    /// The installation's persistent identity, if available for this authenticated session.
    fn local_identity(&self) -> Option<&DeviceIdentity> {
        None
    }
    /// A legacy frame. The platform reports its sequence once the decoder has taken it.
    fn video(&mut self, packet: VideoPacket) -> Result<()>;
    /// Media feedback confirms decoded output. A buffering decoder must report this sequence only
    /// when it produces the corresponding picture, including the keyframe that opens the stream.
    fn media_video(&mut self, packet: VideoPacket, stream: MediaStreamId, first_in_stream: bool) -> Result<()>;
    fn media_committed(&mut self, stream: MediaStreamId) -> Result<()> {
        self.event(ViewerEvent::MediaCommitted(stream));
        Ok(())
    }
    fn event(&mut self, event: ViewerEvent);
}

struct ReceivingDatagrams {
    frames: Receiver,
    stream: MediaStreamId,
    poll_at: Instant,
}

struct ViewerSession<'a, P: ViewerPlatform> {
    peer: &'a PeerHandle,
    platform: &'a mut P,
    hello: Option<Hello>,
    media: Option<ViewerMedia>,
    cursor: CursorPresentationState,
    cursor_requested: bool,
    pending_cursor: Option<(Uuid, Instant)>,
    stream: Option<VideoStreamState>,
    desired: StreamSettings,
    displays: Vec<RemoteDisplayInfo>,
    selected_display: Option<u32>,
    display_revision: u64,
    display_request: Option<(Uuid, u32, Instant)>,
    /// The request in flight: its identifier, when it was sent and what it asked for.
    pending_settings: Option<(Uuid, Instant, StreamSettings)>,
    pending_pause: Option<Uuid>,
    paused: bool,
    input_reply_deadline: Option<Instant>,
    queued_input: VecDeque<RemoteInput>,
    input_echo_sequence: u32,
    pointer_sequence: u64,
    waiting_for_input_echo: bool,
    clipboard_requested: Option<Instant>,
    clipboard: Option<SessionClipboard>,
    audio: ViewerAudio,
    auxiliary: Auxiliary,
    datagrams: DatagramPath,
    udp_receiver: Option<ReceivingDatagrams>,
    host_ended: bool,
    progress: &'a AttemptProgress,
}

/// Runs a session on an authenticated connection until it ends. `quality` is the viewer's preference;
/// `acknowledgements` reports the sequence numbers completed by the platform as specified by `ViewerPlatform`.
pub async fn run<P: ViewerPlatform>(
    peer: PeerHandle,
    incoming: mpsc::Receiver<PeerEvent>,
    platform: &mut P,
    quality: StreamSettings,
    commands: mpsc::UnboundedReceiver<ViewerCommand>,
    acknowledgements: mpsc::UnboundedReceiver<DecodeReceipt>,
) -> ViewerEnd {
    Attempt::new(quality, commands).run(peer, incoming, platform, acknowledgements).await
}

pub(crate) async fn run_attempt<P: ViewerPlatform>(
    peer: PeerHandle,
    mut incoming: mpsc::Receiver<PeerEvent>,
    platform: &mut P,
    attempt: Attempt,
    mut acknowledgements: mpsc::UnboundedReceiver<DecodeReceipt>,
) -> ViewerEnd {
    let Attempt { quality, mut commands, progress, auxiliary, datagram } = attempt;
    let mut session = ViewerSession {
        peer: &peer,
        platform,
        hello: None,
        media: None,
        cursor: CursorPresentationState::default(),
        cursor_requested: false,
        pending_cursor: None,
        stream: None,
        desired: quality,
        displays: Vec::new(),
        selected_display: None,
        display_revision: 0,
        display_request: None,
        pending_settings: None,
        pending_pause: None,
        paused: false,
        input_reply_deadline: None,
        queued_input: VecDeque::new(),
        input_echo_sequence: 0,
        pointer_sequence: 0,
        waiting_for_input_echo: false,
        clipboard_requested: None,
        clipboard: None,
        audio: ViewerAudio::default(),
        auxiliary: Auxiliary::viewer(auxiliary),
        datagrams: DatagramPath::new(datagram),
        udp_receiver: None,
        host_ended: false,
        progress: &progress,
    };
    let hello_by = Instant::now() + HELLO_TIMEOUT;
    let end = loop {
        let settings_by = session.pending_settings.map(|(_, sent, _)| sent + SETTINGS_REPLY_TIMEOUT);
        let media_by = session.media.as_ref().and_then(ViewerMedia::deadline);
        let cursor_by = session.pending_cursor.map(|(_, deadline)| deadline);
        let display_by = session.display_request.map(|(_, _, deadline)| deadline);
        let input_by = session.input_reply_deadline;
        let fragment_by = session.udp_receiver.as_ref().map(|receiver| receiver.poll_at);
        let bulk = session.auxiliary.peer(AuxiliaryRole::Bulk).cloned();
        let outcome = tokio::select! {
            event = incoming.recv() => match event {
                Some(PeerEvent::Message(message)) => session.receive(message),
                Some(PeerEvent::RoundTrip(milliseconds)) => { session.platform.event(ViewerEvent::RoundTrip(milliseconds)); Ok(()) }
                Some(PeerEvent::Closed(reason)) => Err(reason),
                None => Err(DeskError::Network("连接已关闭".to_string())),
            },
            audio = session.audio.next() => session.audio.deliver(audio, &peer, session.platform),
            event = session.datagrams.next() => session.datagram_event(event),
            _ = tokio::time::sleep_until(fragment_by.unwrap_or(hello_by)), if fragment_by.is_some() => session.poll_datagrams(),
            event = session.auxiliary.next() => session.auxiliary_event(event),
            status = SessionClipboard::next(&mut session.clipboard, &peer, bulk.as_ref()) => match status {
                Ok(Some(status)) => { session.platform.event(ViewerEvent::ClipboardStatus(status)); Ok(()) }
                Ok(None) => Ok(()),
                Err(error) => Err(error),
            },
            receipt = acknowledgements.recv() => match receipt {
                Some(receipt) => session.decoded(receipt),
                None => Err(DeskError::platform("视频解码已停止")),
            },
            command = commands.recv() => match command {
                Some(ViewerCommand::Disconnect) | None => break ViewerEnd::stopped("已断开连接"),
                Some(command) => session.command(command),
            },
            _ = tokio::time::sleep_until(hello_by), if session.hello.is_none() => {
                Err(DeskError::Network("加密连接建立后超过 30 秒未收到共享信息".to_string()))
            }
            _ = tokio::time::sleep_until(settings_by.unwrap_or(hello_by)), if settings_by.is_some() => {
                Err(DeskError::Network("画质调整超过 25 秒未确认".to_string()))
            }
            _ = tokio::time::sleep_until(media_by.unwrap_or(hello_by)), if media_by.is_some() => {
                session.update_media(|media| media.tick(Instant::now()))
            }
            _ = tokio::time::sleep_until(cursor_by.unwrap_or(hello_by)), if cursor_by.is_some() => {
                Err(DeskError::Network("光标模式切换超时，重新建立会话".into()))
            }
            _ = tokio::time::sleep_until(display_by.unwrap_or(hello_by)), if display_by.is_some() => {
                session.display_request = None;
                session.display_event(Some("切换显示器超时，请稍后重试".into()));
                Ok(())
            }
            _ = tokio::time::sleep_until(input_by.unwrap_or(hello_by)), if input_by.is_some() => session.input_timeout(),
        };
        if let Err(error) = outcome {
            let mut end = ViewerEnd::from(error);
            // A decoder can stop while the host's final notice is already in the peer queue.
            if !session.host_ended && end.retryable {
                let notice = (0..incoming.len()).find_map(|_| match incoming.try_recv() {
                    Ok(PeerEvent::Message(message)) if message.kind == MessageKind::SessionTermination => Some(message),
                    _ => None,
                });
                if let Some(notice) = notice
                    && let Err(termination) = session.receive(notice)
                {
                    end = ViewerEnd::from(termination);
                }
            }
            if session.host_ended {
                end.host_ended = true;
                end.retryable = false;
            }
            break end;
        }
    };
    let _ = progress.end.set(std::time::Instant::now());
    peer.close();
    end
}

impl<P: ViewerPlatform> ViewerSession<'_, P> {
    fn receive(&mut self, message: Message) -> Result<()> {
        let Some(hello) = &self.hello else {
            if message.kind != MessageKind::Hello {
                return Err(DeskError::invalid("缺少会话信息"));
            }
            return self.connected(message.read_json()?);
        };
        match message.kind {
            MessageKind::Video => {
                let packet = VideoPacket::decode(&message.payload)?;
                if let Some(media) = &mut self.media {
                    media.legacy(packet.sequence, message.payload.len())?;
                }
                self.platform.video(packet)?;
            }
            MessageKind::MediaControl => {
                let control = MediaControl::read(&message)?;
                if control.operation == MediaOperation::Offer {
                    let media = self.media.as_mut().ok_or_else(|| DeskError::invalid("当前连接未协商媒体会话"))?;
                    if !media.has_offer() {
                        media.set_udp_available(self.datagrams.offer(&control, false));
                        self.auxiliary.offer(&control);
                    }
                }
                self.update_media(|media| media.control(&control, Instant::now()))?;
            }
            MessageKind::DisplayControl if hello.display_switching_v1 == Some(true) => self.receive_displays(DisplayControl::read(&message)?)?,
            MessageKind::MediaFrame => self.update_media(|media| media.frame(&message.payload, Instant::now()))?,
            MessageKind::CursorControl | MessageKind::CursorPosition | MessageKind::CursorShape
                if hello.independent_cursor_v1 == Some(true) && self.media.is_some() =>
            {
                self.receive_cursor(message)?
            }
            MessageKind::StreamSettingsResult if hello.live_settings == Some(true) => {
                let result: StreamSettingsResult = message.read_json()?;
                // A reply to a request this viewer no longer waits for changes nothing.
                let Some((_, _, requested)) = self.pending_settings.filter(|(id, _, _)| *id == result.id) else { return Ok(()) };
                result.state.validate()?;
                if result.state.settings.frames_per_second > 60 || result.codec.is_some_and(|codec| codec != VideoCodec::H264) {
                    return Err(DeskError::invalid("画质回复超出已协商的范围"));
                }
                self.pending_settings = None;
                self.stream = Some(result.state);
                // The host decides what it can do: asking again for what it just lowered or declined would loop.
                // A choice the user made while this request was in flight is still sent.
                if self.supported(self.desired) == requested {
                    self.desired = result.state.settings;
                }
                self.platform.event(ViewerEvent::Stream { stream: result.state, error: result.error });
                self.request_settings()?;
                self.request_cursor()?;
            }
            MessageKind::ControlStatus if hello.control_status_updates == Some(true) => {
                let status: ControlStatus = message.read_json()?;
                self.hello.as_mut().unwrap().can_control = status.can_control;
                if !status.can_control {
                    self.cancel_input_replies(false)?;
                }
                self.platform.event(ViewerEvent::Control(status.can_control));
            }
            MessageKind::InputStatus if hello.input_actions == Some(true) => {
                let feedback: InputFeedback = message.read_json()?;
                if let Some(deadline) = self.input_reply_deadline
                    && !self.waiting_for_input_echo
                {
                    let now = Instant::now();
                    if now >= deadline {
                        return self.input_timeout();
                    }
                    self.input_reply_deadline = None;
                    self.platform.event(ViewerEvent::InputStatus(feedback));
                    while self.queued_input.front().is_some_and(|next| self.input_reply_deadline.is_none() || next.kind.action().is_none()) {
                        let input = self.queued_input.pop_front().unwrap();
                        self.send_input(input)?;
                    }
                }
            }
            MessageKind::Pong if hello.input_actions == Some(true) => {
                if message.payload == input_echo(self.input_echo_sequence) {
                    self.waiting_for_input_echo = false;
                }
            }
            MessageKind::SessionPauseResult if hello.session_pause == Some(true) => {
                let result: SessionPauseResult = message.read_json()?;
                if self.pending_pause == Some(result.id) {
                    self.pending_pause = None;
                    self.paused = result.paused;
                    self.audio.pause(self.paused);
                    self.datagrams.pause(self.paused);
                    if self.media.is_some() {
                        self.update_media(|media| media.set_paused(result.paused, Instant::now()))?;
                    }
                    self.platform.event(ViewerEvent::Paused { paused: result.paused, error: result.error });
                }
            }
            MessageKind::SessionTermination if hello.session_termination_v1 == Some(true) => {
                let notice: SessionTermination = message.read_json()?;
                if notice.operation != TerminationOperation::Ended {
                    return Err(DeskError::invalid("结束连接消息方向无效"));
                }
                self.host_ended = true;
                return Err(DeskError::Network(HOST_ENDED_REASON.to_string()));
            }
            MessageKind::AudioControl if self.audio.supported => self.audio.status(&message, self.platform, self.paused, self.peer)?,
            MessageKind::AudioFrame if self.audio.supported => self.audio.frame(&message, self.paused, self.peer, self.platform)?,
            kind if SessionClipboard::accepts(kind) => {
                self.clipboard.as_ref().ok_or_else(|| DeskError::invalid("尚未协商自动剪贴板"))?.receive(message)?;
            }
            MessageKind::Clipboard => {
                // Only text this viewer asked for moments ago is taken.
                if self.clipboard_requested.take().is_some_and(|asked| asked.elapsed() <= CLIPBOARD_REPLY_TIMEOUT) {
                    let text = String::from_utf8(message.payload).ok().filter(|text| text.len() <= wire::MAXIMUM_CLIPBOARD_BYTES);
                    self.platform.event(ViewerEvent::ClipboardText(text.ok_or_else(|| DeskError::invalid("剪贴板文字过大或编码无效"))?));
                }
            }
            _ => return Err(DeskError::invalid("收到当前角色不支持的消息")),
        }
        Ok(())
    }

    fn connected(&mut self, mut hello: Hello) -> Result<()> {
        hello.validate()?;
        let stream = VideoStreamState { settings: hello.settings, width: hello.width, height: hello.height };
        self.stream = Some(stream);
        let live_settings = hello.live_settings == Some(true);
        let _ = self.progress.hello.set(std::time::Instant::now());
        if hello.clipboard_sync == Some(true) {
            self.clipboard = self.platform.open_clipboard();
        }
        self.audio.supported = hello.remote_audio_v1 == Some(true) && self.platform.supports_audio_playback();
        self.platform.event(ViewerEvent::Connected {
            remote_audio: self.audio.supported,
            clipboard_sync: self.clipboard.is_some(),
            name: device_display_name(&hello.name),
            device_id: hello.device_id,
            can_control: hello.can_control,
            stream,
            live_settings,
            session_pause: hello.session_pause == Some(true),
            input_actions: hello.input_actions == Some(true),
            relative_mouse: hello.relative_mouse_v1 == Some(true),
            trackpad_gestures: hello.trackpad_gestures_v1 == Some(true),
        });
        if hello.device_identity_exchange == Some(true)
            && let Some(identity) = self.platform.local_identity()
        {
            self.peer.send(&identity.message()?)?;
        }
        if hello.input_actions == Some(true) {
            self.peer.order_input_echoes(MessageKind::Pong);
        }
        if hello.session_termination_v1 == Some(true) {
            self.peer.send(&Message::json(MessageKind::SessionTermination, &SessionTermination { operation: TerminationOperation::Subscribe })?)?;
        }
        if hello.control_status_updates == Some(true) {
            self.peer.send(&Message::empty(MessageKind::ControlStatus))?;
        }
        if hello.display_switching_v1 == Some(true) {
            self.displays = hello.displays.take().unwrap_or_default();
            self.selected_display = hello.selected_display_id.or_else(|| self.displays.first().map(|display| display.id));
            self.display_event(None);
            self.peer.send(&DisplayControl::Subscribe.message()?)?;
        }
        if hello.media_transport_v1 == Some(true) {
            let mut media = ViewerMedia::default();
            if self.auxiliary.enabled() {
                media.enable_auxiliary();
            }
            self.media = Some(media);
            let mut request = ViewerMedia::request();
            if self.datagrams.enabled() {
                request.request_fragment_features();
            }
            self.peer.send(&request.message()?)?;
        }
        let confirm = live_settings && hello.initial_stream_negotiation_v1 == Some(true);
        self.hello = Some(hello);
        if confirm && self.supported(self.desired) == stream.settings {
            // The host holds its first frame until it hears the viewer's choice, even an unchanged one.
            return self.send_settings(stream.settings);
        }
        self.request_settings()
    }

    fn display_event(&mut self, error: Option<String>) {
        self.platform.event(ViewerEvent::Displays {
            displays: self.displays.clone(),
            selected: self.selected_display,
            pending: self.display_request.map(|(_, target, _)| target),
            error,
            revision: self.display_revision,
        });
    }

    fn receive_displays(&mut self, control: DisplayControl) -> Result<()> {
        let restarted = matches!(control, DisplayControl::State { video_state: Some(_), .. });
        let (displays, selected, state, error) = match control {
            DisplayControl::State { displays, selected, video_state } => (displays, selected, video_state, None),
            DisplayControl::Result { id, displays, selected, video_state, error } => {
                if self.display_request.is_none_or(|(pending, _, _)| pending != id) {
                    return Ok(());
                }
                self.display_request = None;
                (displays, selected, error.is_none().then_some(video_state), error)
            }
            _ => return Err(DeskError::invalid("显示器控制消息方向无效")),
        };
        if let Some(previous) = self.displays.iter().find(|screen| Some(screen.id) == self.selected_display)
            && error.is_none()
            && (restarted
                || previous.id != selected
                || state.zip(self.stream).is_some_and(|(next, old)| (next.width, next.height) != (old.width, old.height))
                || displays.iter().any(|screen| screen.id == selected && (screen.width, screen.height) != (previous.width, previous.height)))
        {
            self.display_revision += 1;
            self.cancel_input_replies(false)?;
        }
        if let Some(stream) = state {
            if stream.settings.frames_per_second > 60 {
                return Err(DeskError::invalid("显示器画质超出已协商的范围"));
            }
            self.stream = Some(stream);
            self.platform.event(ViewerEvent::Stream { stream, error: None });
        }
        self.displays = displays;
        self.selected_display = Some(selected);
        self.display_event(error);
        Ok(())
    }

    fn auxiliary_event(&mut self, event: AuxiliaryEvent) -> Result<()> {
        match event {
            AuxiliaryEvent::Bound(AuxiliaryRole::Video) | AuxiliaryEvent::Lost(AuxiliaryRole::Video) => {
                self.update_media(|media| media.set_video_bound(matches!(event, AuxiliaryEvent::Bound(_)), Instant::now()))
            }
            AuxiliaryEvent::Message(AuxiliaryRole::Video, message) => {
                let update =
                    self.media.as_mut().ok_or_else(|| DeskError::invalid("媒体会话尚未协商"))?.frame_on(MediaPath::Tcp, &message.payload, Instant::now());
                match update {
                    Ok(events) => self.apply_media_events(events),
                    Err(_) => {
                        self.auxiliary.close(AuxiliaryRole::Video);
                        self.update_media(|media| media.set_video_bound(false, Instant::now()))
                    }
                }
            }
            AuxiliaryEvent::Message(role, message) => {
                if !self.clipboard.as_ref().is_some_and(|copy| copy.receive(message).is_ok()) {
                    self.auxiliary.close(role);
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }

    fn datagram_event(&mut self, event: PathEvent) -> Result<()> {
        match event {
            PathEvent::Verified => self.update_media(|media| media.set_udp_verified(true, Instant::now())),
            PathEvent::Lost => self.lose_datagrams(),
            PathEvent::Record(kind @ (3 | 5 | 8 | 10), data) => {
                let parity = matches!(kind, 8 | 10);
                if parity && !self.media.as_ref().is_some_and(|media| media.accepts_fec(kind)) {
                    return Ok(());
                }
                let Some(receiver) = &mut self.udp_receiver else { return Ok(()) };
                let now = Instant::now();
                let events = if parity { receiver.frames.parity(kind, &data[1..], now) } else { receiver.frames.push(&data[1..], now) };
                match events {
                    Ok(events) => self.receive_datagrams(events),
                    Err(_) => self.lose_datagrams(),
                }
            }
            _ => Ok(()),
        }
    }

    fn lose_datagrams(&mut self) -> Result<()> {
        self.datagrams.retire();
        self.update_media(|media| media.set_udp_verified(false, Instant::now()))
    }

    fn poll_datagrams(&mut self) -> Result<()> {
        let Some(receiver) = &mut self.udp_receiver else { return Ok(()) };
        let now = Instant::now();
        receiver.poll_at = now + Duration::from_millis(10);
        receiver.frames.set_round_trip(self.datagrams.rtt);
        let events = receiver.frames.poll(now);
        self.receive_datagrams(events)
    }

    fn sync_datagram_receiver(&mut self) {
        let stream = self.media.as_ref().filter(|media| media.frame_path() == MediaPath::Udp).and_then(ViewerMedia::receiving_stream);
        if stream != self.udp_receiver.as_ref().map(|receiver| receiver.stream) {
            self.udp_receiver = stream.map(|stream| ReceivingDatagrams { frames: Receiver::new(stream), stream, poll_at: Instant::now() });
        }
    }

    fn send_datagram_feedback(&self, feedback: &MediaFeedback) {
        let payload = feedback.message().payload;
        let mut datagram = Vec::with_capacity(1 + payload.len());
        datagram.push(4);
        datagram.extend_from_slice(&payload);
        // NACK and cumulative decode status are repeated by the receiver if the send queue is full.
        self.datagrams.send(datagram);
    }

    fn receive_datagrams(&mut self, events: Vec<ReceiveEvent>) -> Result<()> {
        for event in events {
            match event {
                ReceiveEvent::Frame(frame) => self.update_media(|media| media.assembled_frame(frame, Instant::now()))?,
                ReceiveEvent::Feedback(feedback) => {
                    self.send_datagram_feedback(&feedback);
                    if feedback.kind == FeedbackKind::Expired {
                        return self.lose_datagrams();
                    }
                }
            }
        }
        Ok(())
    }

    fn update_media(&mut self, update: impl FnOnce(&mut ViewerMedia) -> Result<Vec<ViewerMediaEvent>>) -> Result<()> {
        let media = self.media.as_mut().ok_or_else(|| DeskError::invalid("当前连接未协商媒体会话"))?;
        let events = update(media)?;
        self.apply_media_events(events)
    }

    fn apply_media_events(&mut self, events: Vec<ViewerMediaEvent>) -> Result<()> {
        self.sync_datagram_receiver();
        let mut after_commit = Vec::new();
        for event in events {
            match event {
                ViewerMediaEvent::Send(message) => self.peer.send(&message)?,
                ViewerMediaEvent::DatagramFeedback(feedback) => {
                    self.send_datagram_feedback(&feedback);
                    if feedback.kind == FeedbackKind::Decoded
                        && let Some(receiver) = &mut self.udp_receiver
                    {
                        let ready = receiver.frames.decoded(feedback.header, Instant::now());
                        self.receive_datagrams(ready)?;
                    }
                }
                ViewerMediaEvent::Video(packet, stream, first_in_stream) => self.platform.media_video(packet, stream, first_in_stream)?,
                ViewerMediaEvent::Committed(stream) => {
                    if self.cursor.commit(stream) {
                        self.platform.event(ViewerEvent::Cursor(Arc::new(self.cursor.clone())));
                    }
                    self.platform.media_committed(stream)?;
                    if let Some(receiver) = &mut self.udp_receiver {
                        after_commit = receiver.frames.committed(stream, Instant::now());
                    }
                }
            }
        }
        if self.datagrams.verified() && self.media.as_ref().is_some_and(|media| !media.udp_verified()) {
            self.datagrams.retire();
        }
        self.receive_datagrams(after_commit)?;
        // The host must receive committed before a request that interrupts capture to change cursor mode.
        self.request_cursor()
    }

    fn request_cursor(&mut self) -> Result<()> {
        if self.cursor_requested
            || self.hello.as_ref().is_none_or(|hello| hello.independent_cursor_v1 != Some(true))
            || self.media.as_ref().and_then(ViewerMedia::active).is_none()
            || self.pending_settings.is_some()
        {
            return Ok(());
        }
        let id = Uuid::new_v4();
        self.peer.send(&CursorControl::request(id, true).message()?)?;
        self.cursor_requested = true;
        self.pending_cursor = Some((id, Instant::now() + Duration::from_secs(25)));
        Ok(())
    }

    fn receive_cursor(&mut self, message: Message) -> Result<()> {
        let changed = match message.kind {
            MessageKind::CursorShape => self.cursor.update_shape(&CursorShape::decode(&message.payload)?),
            MessageKind::CursorPosition => self.cursor.update_position(&CursorPosition::decode(&message.payload)?),
            _ => {
                let control = CursorControl::read(&message)?;
                match control.operation {
                    CursorOperation::Status => {
                        if self.pending_cursor.map(|(id, _)| id) != control.request_id {
                            return Ok(());
                        }
                        self.pending_cursor = None;
                        self.cursor.status(&control)
                    }
                    CursorOperation::Binding => self.cursor.bind(&control),
                    CursorOperation::Request => return Err(DeskError::invalid("光标控制方向无效")),
                }
            }
        };
        if changed {
            if let Some(stream) = self.media.as_ref().and_then(ViewerMedia::active) {
                self.cursor.commit(stream);
            }
            self.platform.event(ViewerEvent::Cursor(Arc::new(self.cursor.clone())));
        }
        Ok(())
    }

    fn decoded(&mut self, receipt: DecodeReceipt) -> Result<()> {
        if let Some(media) = &mut self.media {
            let events = media.decoded(receipt)?;
            return self.apply_media_events(events);
        }
        if let DecodeReceipt::Legacy(sequence) = receipt {
            self.peer.send(&Message::new(MessageKind::Acknowledgement, sequence.to_be_bytes().to_vec()))?;
        }
        Ok(())
    }

    /// The closest settings to `settings` that this host's capabilities allow.
    fn supported(&self, settings: StreamSettings) -> StreamSettings {
        // The decoder path of this viewer is specified up to 60 frames per second.
        let capped = StreamSettings { frames_per_second: settings.frames_per_second.min(60), ..settings };
        match &self.hello {
            Some(hello) if hello.extended_video_settings == Some(true) && hello.high_refresh_video_settings == Some(true) => capped,
            Some(hello) if hello.extended_video_settings == Some(true) => capped.extended_compatible(),
            _ => {
                let legacy = capped.legacy_compatible();
                let megabits = StreamSettings::LEGACY_BIT_RATES.iter().copied().filter(|rate| *rate <= legacy.megabits).max().unwrap_or(1);
                StreamSettings { megabits, ..legacy }
            }
        }
    }

    /// Asks for the desired quality when it differs from the stream and no request is in flight.
    fn request_settings(&mut self) -> Result<()> {
        let live = self.hello.as_ref().is_some_and(|hello| hello.live_settings == Some(true));
        let desired = self.supported(self.desired);
        if !live || self.pending_settings.is_some() || self.stream.is_some_and(|stream| stream.settings == desired) {
            return Ok(());
        }
        self.send_settings(desired)
    }

    fn send_settings(&mut self, settings: StreamSettings) -> Result<()> {
        let request = StreamSettingsRequest::new(settings);
        self.pending_settings = Some((request.id, Instant::now(), settings));
        self.peer.send(&Message::json(MessageKind::StreamSettingsRequest, &request)?)
    }

    fn command(&mut self, command: ViewerCommand) -> Result<()> {
        match command {
            ViewerCommand::Quality(settings) => {
                settings.validate_control_values()?;
                self.desired = settings;
                self.request_settings()
            }
            _ if self.hello.is_none() => Ok(()),
            ViewerCommand::Input(mut input) => {
                let hello = self.hello.as_ref().unwrap();
                if !hello.can_control || self.paused || self.pending_pause.is_some() || self.display_request.is_some() {
                    return Ok(());
                }
                if input.relative_mouse == Some(true) && hello.relative_mouse_v1 != Some(true) {
                    return Ok(());
                }
                if input.kind.is_gesture() && hello.trackpad_gestures_v1 != Some(true) {
                    return Ok(());
                }
                if hello.input_actions != Some(true) {
                    if input.kind.action().is_some() {
                        return Ok(());
                    }
                    input.independent_caps_lock = None;
                }
                // inputStatus has no request ID. Only one action can be confirmed at a time.
                if !self.queued_input.is_empty() || (self.input_reply_deadline.is_some() && input.kind.action().is_some()) {
                    if self.queued_input.len() == crate::input::INPUT_QUEUE_CAPACITY {
                        return self.input_timeout();
                    }
                    self.queued_input.push_back(input);
                    Ok(())
                } else {
                    self.send_input(input)
                }
            }
            ViewerCommand::ReleaseInput => self.cancel_input_replies(true),
            ViewerCommand::SelectDisplay(id) => {
                if self.display_request.is_some() || self.selected_display == Some(id) {
                    self.display_event(None);
                    return Ok(());
                }
                if !self.displays.iter().any(|display| display.id == id) {
                    self.display_event(Some("所选显示器当前不可用".into()));
                    return Ok(());
                }
                let request = Uuid::new_v4();
                self.cancel_input_replies(true)?;
                self.peer.send(&DisplayControl::Select { id: request, display_id: id }.message()?)?;
                self.display_request = Some((request, id, Instant::now() + Duration::from_secs(15)));
                self.display_event(None);
                Ok(())
            }
            ViewerCommand::RemoteAudio(enabled) => self.audio.request(enabled, self.peer, self.platform),
            ViewerCommand::SendClipboard(text) => {
                if text.len() > wire::MAXIMUM_CLIPBOARD_BYTES {
                    return Err(DeskError::invalid("文字剪贴板最大支持 1 MB"));
                }
                self.peer.send(&Message::new(MessageKind::Clipboard, text.into_bytes()))
            }
            ViewerCommand::AutomaticClipboard { enabled, receives } => self.clipboard.as_ref().map_or(Ok(()), |copy| copy.preferences(enabled, receives)),
            ViewerCommand::RequestClipboard => {
                self.clipboard_requested = Some(Instant::now());
                self.peer.send(&Message::empty(MessageKind::RequestClipboard))
            }
            ViewerCommand::Pause(paused) => {
                if !self.hello.as_ref().is_some_and(|hello| hello.session_pause == Some(true)) || self.pending_pause.is_some() {
                    return Ok(());
                }
                let request = SessionPauseRequest { id: Uuid::new_v4(), paused };
                self.cancel_input_replies(false)?;
                self.pending_pause = Some(request.id);
                self.peer.send(&Message::json(MessageKind::SessionPauseRequest, &request)?)
            }
            ViewerCommand::Disconnect => Ok(()),
        }
    }

    fn cancel_input_replies(&mut self, release: bool) -> Result<()> {
        let awaiting = self.input_reply_deadline.take().is_some();
        self.queued_input.clear();
        if release || awaiting {
            self.peer.send(&Message::empty(MessageKind::ReleaseInput))?;
        }
        if awaiting {
            // inputStatus carries no request ID. The echo follows all earlier statuses and the release
            // on the remote connection, so a late result cannot be assigned to the next physical press.
            self.input_echo_sequence = self.input_echo_sequence.wrapping_add(1);
            self.waiting_for_input_echo = true;
            self.peer.send(&Message::new(MessageKind::Ping, input_echo(self.input_echo_sequence).to_vec()))?;
        }
        Ok(())
    }

    fn send_input(&mut self, mut input: RemoteInput) -> Result<()> {
        if input.kind.action().is_some() {
            self.input_reply_deadline = Some(Instant::now() + INPUT_REPLY_TIMEOUT);
        }
        if input.kind.is_pointer() {
            input.pointer_sequence = self.pointer_sequence.checked_add(1);
            if let Some(sequence) = input.pointer_sequence {
                self.pointer_sequence = sequence;
            }
        }
        self.peer.send(&Message::json(MessageKind::Input, &input)?)
    }

    fn input_timeout(&mut self) -> Result<()> {
        self.cancel_input_replies(false)?;
        self.platform.event(ViewerEvent::InputActionTimeout);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::{FeedbackKind, HostMedia, HostMediaEvent, MediaFeedback, MediaFrame, MediaOperation};
    use crate::peer::{self, PeerConfig};
    use crate::video::EncodedFrame;

    struct Decoder;

    impl ViewerPlatform for Decoder {
        fn video(&mut self, _: VideoPacket) -> Result<()> {
            Ok(())
        }
        fn media_video(&mut self, _: VideoPacket, _: MediaStreamId, _: bool) -> Result<()> {
            Ok(())
        }
        fn event(&mut self, _: ViewerEvent) {}
    }

    async fn next(events: &mut mpsc::Receiver<PeerEvent>) -> Message {
        loop {
            match events.recv().await.unwrap() {
                PeerEvent::Message(message) => return message,
                PeerEvent::RoundTrip(_) => {}
                PeerEvent::Closed(error) => panic!("session ended before expected message: {error}"),
            }
        }
    }

    struct Observer(mpsc::UnboundedSender<ViewerEvent>);
    impl ViewerPlatform for Observer {
        fn video(&mut self, _: VideoPacket) -> Result<()> {
            unreachable!()
        }
        fn media_video(&mut self, _: VideoPacket, _: MediaStreamId, _: bool) -> Result<()> {
            unreachable!()
        }
        fn event(&mut self, event: ViewerEvent) {
            self.0.send(event).unwrap();
        }
    }

    #[tokio::test]
    async fn pointer_capabilities_are_independent_and_sequence_numbers_follow_wire_order() {
        use crate::messages::{InputKind, ScrollPhase};
        for (supported, gestures) in [(false, false), (false, true), (true, false), (true, true)] {
            let (left, right) = tokio::io::duplex(8192);
            let (host, mut from_viewer) = peer::spawn(left, PeerConfig::default());
            let (viewer, incoming) = peer::spawn(right, PeerConfig::default());
            let (input, commands) = mpsc::unbounded_channel();
            let (_decoder, acks) = mpsc::unbounded_channel();
            let (notices, mut events) = mpsc::unbounded_channel();
            let mut observer = Observer(notices);
            let quality = StreamSettings::new(1920, 30, 8);
            let exchange = async {
                let mut hello = serde_json::json!({"version":1,"name":"host","width":1280,"height":720,"settings":quality,"canControl":true});
                if supported {
                    hello["relativeMouseV1"] = serde_json::Value::Bool(true);
                }
                if gestures {
                    hello["trackpadGesturesV1"] = serde_json::Value::Bool(true);
                }
                host.send(&Message::json(MessageKind::Hello, &hello).unwrap()).unwrap();
                assert!(
                    matches!(events.recv().await.unwrap(), ViewerEvent::Connected{relative_mouse,trackpad_gestures,..} if relative_mouse==supported && trackpad_gestures==gestures)
                );
                let mut relative = RemoteInput::new(InputKind::Move).at_current_pointer();
                relative.pointer_delta_x = Some(3.0);
                relative.pointer_delta_y = Some(-4.0);
                input.send(ViewerCommand::Input(relative)).unwrap();
                input.send(ViewerCommand::ReleaseInput).unwrap();
                input.send(ViewerCommand::Input(RemoteInput::new(InputKind::Down))).unwrap();
                if supported {
                    let movement: RemoteInput = next(&mut from_viewer).await.read_json().unwrap();
                    assert_eq!((movement.pointer_sequence, movement.relative_mouse), (Some(1), Some(true)));
                }
                assert_eq!(next(&mut from_viewer).await.kind, MessageKind::ReleaseInput);
                let absolute: RemoteInput = next(&mut from_viewer).await.read_json().unwrap();
                assert_eq!((absolute.kind, absolute.relative_mouse, absolute.pointer_sequence), (InputKind::Down, None, Some(if supported { 2 } else { 1 })));
                input.send(ViewerCommand::Input(RemoteInput::new(InputKind::SmartMagnify))).unwrap();
                let mut scroll = RemoteInput::new(InputKind::Scroll);
                scroll.delta_y = -0.75;
                scroll.scroll_phase = Some(ScrollPhase::Changed);
                input.send(ViewerCommand::Input(scroll)).unwrap();
                if gestures {
                    let smart: RemoteInput = next(&mut from_viewer).await.read_json().unwrap();
                    assert_eq!(smart.kind, InputKind::SmartMagnify);
                }
                let scroll: RemoteInput = next(&mut from_viewer).await.read_json().unwrap();
                assert_eq!((scroll.kind, scroll.delta_y, scroll.scroll_phase), (InputKind::Scroll, -0.75, Some(ScrollPhase::Changed)));
                input.send(ViewerCommand::Disconnect).unwrap();
            };
            let (end, ()) =
                tokio::time::timeout(Duration::from_secs(3), async { tokio::join!(run(viewer, incoming, &mut observer, quality, commands, acks), exchange) })
                    .await
                    .unwrap();
            assert!(end.local_stop);
        }
    }

    #[tokio::test(start_paused = true)]
    async fn cancelled_and_expired_input_status_cannot_be_assigned_to_a_later_press() {
        let (left, right) = tokio::io::duplex(64 * 1024);
        let (host, mut from_viewer) = peer::spawn(left, PeerConfig::default());
        host.order_input_echoes(MessageKind::Ping);
        let (viewer, incoming) = peer::spawn(right, PeerConfig::default());
        let (input, commands) = mpsc::unbounded_channel();
        let (_decoder, acks) = mpsc::unbounded_channel();
        let (notices, mut events) = mpsc::unbounded_channel();
        let mut observer = Observer(notices);
        let quality = StreamSettings::new(1920, 30, 8);
        let session = run(viewer, incoming, &mut observer, quality, commands, acks);
        let exchange = async {
            let hello = serde_json::json!({"version":1,"name":"host","width":1280,"height":720,"settings":quality,"canControl":true,"inputActions":true});
            host.send(&Message::json(MessageKind::Hello, &hello).unwrap()).unwrap();
            assert!(matches!(events.recv().await.unwrap(), ViewerEvent::Connected { input_actions: true, .. }));
            let press = || input.send(ViewerCommand::Input(crate::messages::InputAction::ToggleCapsLock.remote_input())).unwrap();
            let status = |text: &str| {
                let feedback = InputFeedback { message: text.into(), caps_locked: true };
                host.send(&Message::json(MessageKind::InputStatus, &feedback).unwrap()).unwrap();
                feedback
            };
            for expire in [false, true] {
                press();
                assert_eq!(next(&mut from_viewer).await.kind, MessageKind::Input);
                press();
                input.send(ViewerCommand::RequestClipboard).unwrap();
                assert_eq!(next(&mut from_viewer).await.kind, MessageKind::RequestClipboard, "the second action waits for feedback");
                if expire {
                    tokio::time::advance(INPUT_REPLY_TIMEOUT).await;
                    loop {
                        match events.recv().await.unwrap() {
                            ViewerEvent::InputActionTimeout => break,
                            ViewerEvent::RoundTrip(_) => {}
                            other => panic!("expected input timeout, got {other:?}"),
                        }
                    }
                } else {
                    input.send(ViewerCommand::ReleaseInput).unwrap();
                }
                assert_eq!(next(&mut from_viewer).await.kind, MessageKind::ReleaseInput);
                let fence = next(&mut from_viewer).await;
                assert_eq!(fence.kind, MessageKind::Ping);
                press();
                assert_eq!(next(&mut from_viewer).await.kind, MessageKind::Input);
                if expire {
                    host.send(&Message::new(MessageKind::Pong, input_echo(1).to_vec())).unwrap();
                }
                status("过期");
                host.send(&Message::new(MessageKind::Pong, fence.payload)).unwrap();
                let current = status("当前");
                loop {
                    match events.recv().await.unwrap() {
                        ViewerEvent::InputStatus(actual) => {
                            assert_eq!(actual, current);
                            break;
                        }
                        ViewerEvent::RoundTrip(_) => {}
                        other => panic!("unexpected input feedback: {other:?}"),
                    }
                }
            }
            input.send(ViewerCommand::Disconnect).unwrap();
        };
        let (end, ()) = tokio::time::timeout(Duration::from_secs(20), async { tokio::join!(session, exchange) }).await.unwrap();
        assert!(end.local_stop);
    }

    #[tokio::test(start_paused = true)]
    async fn a_display_timeout_keeps_the_session_and_ignores_the_late_result() {
        let (left, right) = tokio::io::duplex(64 * 1024);
        let (host, mut from_viewer) = peer::spawn(left, PeerConfig::default());
        let (viewer, incoming) = peer::spawn(right, PeerConfig::default());
        let (input, commands) = mpsc::unbounded_channel();
        let (_decoder, acks) = mpsc::unbounded_channel();
        let (notices, mut events) = mpsc::unbounded_channel();
        let mut observer = Observer(notices);
        let quality = StreamSettings::new(1920, 30, 8);
        let session = run(viewer, incoming, &mut observer, quality, commands, acks);
        let exchange = async {
            let screens = vec![RemoteDisplayInfo::new(1, "主屏", 1280, 720, true), RemoteDisplayInfo::new(2, "副屏", 720, 1280, false)];
            let hello = serde_json::json!({"version":1,"name":"host","width":1280,"height":720,"settings":quality,
                "canControl":true,"displaySwitchingV1":true,"inputActions":true});
            host.send(&Message::json(MessageKind::Hello, &hello).unwrap()).unwrap();
            assert_eq!(DisplayControl::read(&next(&mut from_viewer).await).unwrap(), DisplayControl::Subscribe);
            let updated = DisplayControl::State {
                displays: screens.clone(),
                selected: 1,
                video_state: Some(VideoStreamState { settings: quality, width: 1280, height: 720 }),
            }
            .message()
            .unwrap();
            host.send(&updated).unwrap();
            while !matches!(events.recv().await.unwrap(), ViewerEvent::Displays { selected: Some(1), revision: 0, .. }) {}
            host.send(&updated).unwrap();
            while !matches!(events.recv().await.unwrap(), ViewerEvent::Displays { selected: Some(1), revision: 1, .. }) {}
            input.send(ViewerCommand::SelectDisplay(2)).unwrap();
            assert_eq!(next(&mut from_viewer).await.kind, MessageKind::ReleaseInput);
            let DisplayControl::Select { id, .. } = DisplayControl::read(&next(&mut from_viewer).await).unwrap() else { panic!("expected a display request") };
            while !matches!(events.recv().await.unwrap(), ViewerEvent::Displays { pending: Some(2), .. }) {}
            input.send(ViewerCommand::Input(crate::messages::InputAction::SwitchInputSource.remote_input())).unwrap();
            input.send(ViewerCommand::Input(RemoteInput::new(crate::messages::InputKind::KeyDown))).unwrap();
            input.send(ViewerCommand::RequestClipboard).unwrap();
            assert_eq!(next(&mut from_viewer).await.kind, MessageKind::RequestClipboard);
            tokio::time::advance(Duration::from_secs(15)).await;
            while !matches!(events.recv().await.unwrap(), ViewerEvent::Displays { selected: Some(1), pending: None, error: Some(_), .. }) {}
            host.send(
                &DisplayControl::Result {
                    id,
                    selected: 2,
                    displays: screens.clone(),
                    video_state: VideoStreamState { settings: quality, width: 720, height: 1280 },
                    error: None,
                }
                .message()
                .unwrap(),
            )
            .unwrap();
            host.send(&DisplayControl::State { displays: screens, selected: 1, video_state: None }.message().unwrap()).unwrap();
            loop {
                match events.recv().await.unwrap() {
                    ViewerEvent::Displays { selected: Some(1), revision: 1, .. } => break,
                    ViewerEvent::RoundTrip(_) => {}
                    unexpected => panic!("late display result changed the viewer: {unexpected:?}"),
                }
            }
            input.send(ViewerCommand::SelectDisplay(2)).unwrap();
            assert_eq!(next(&mut from_viewer).await.kind, MessageKind::ReleaseInput);
            let DisplayControl::Select { id: retry, .. } = DisplayControl::read(&next(&mut from_viewer).await).unwrap() else {
                panic!("expected a second request")
            };
            assert_ne!(id, retry);
            input.send(ViewerCommand::Disconnect).unwrap();
        };
        let (end, ()) = tokio::time::timeout(Duration::from_secs(40), async { tokio::join!(session, exchange) }).await.unwrap();
        assert!(end.local_stop);
    }

    #[tokio::test]
    async fn a_queued_host_ending_survives_a_concurrent_decoder_failure() {
        let (stream, _other) = tokio::io::duplex(4096);
        let (peer, _transport) = peer::spawn(stream, PeerConfig::default());
        let (events, incoming) = mpsc::channel(4);
        let quality = StreamSettings::new(1920, 30, 8);
        let hello = serde_json::json!({"version": 1, "name": "host", "width": 640, "height": 360,
            "settings": quality, "canControl": false, "sessionTerminationV1": true});
        let (_controls, commands) = mpsc::unbounded_channel();
        let (_decoder, acknowledgements) = mpsc::unbounded_channel();
        let termination = SessionTermination { operation: TerminationOperation::Ended };
        events.try_send(PeerEvent::Message(Message::json(MessageKind::Hello, &hello).unwrap())).unwrap();
        let packet = VideoPacket::h264(1, EncodedFrame { sps: vec![0x67], pps: vec![0x68], avcc: vec![0, 0, 0, 1, 0x65] });
        events.try_send(PeerEvent::Message(Message::new(MessageKind::Video, packet.encode().unwrap()))).unwrap();
        events.try_send(PeerEvent::Message(Message::json(MessageKind::SessionTermination, &termination).unwrap())).unwrap();

        struct FailedDecoder;
        impl ViewerPlatform for FailedDecoder {
            fn video(&mut self, _: VideoPacket) -> Result<()> {
                Err(DeskError::platform("解码已停止"))
            }
            fn media_video(&mut self, _: VideoPacket, _: MediaStreamId, _: bool) -> Result<()> {
                unreachable!()
            }
            fn event(&mut self, _: ViewerEvent) {}
        }
        let end = run(peer, incoming, &mut FailedDecoder, quality, commands, acknowledgements).await;
        assert!(end.host_ended);
        assert!(!end.retryable);
        assert_eq!(end.reason, HOST_ENDED_REASON);
    }

    #[tokio::test]
    async fn the_viewer_repairs_a_missing_keyframe_fragment_and_falls_back_when_dtls_stops() {
        use crate::media::HostFrame;
        use crate::media::fragment::RepairCache;

        struct Output(mpsc::UnboundedSender<VideoPacket>);
        impl ViewerPlatform for Output {
            fn video(&mut self, _: VideoPacket) -> Result<()> {
                unreachable!()
            }
            fn media_video(&mut self, packet: VideoPacket, _: MediaStreamId, _: bool) -> Result<()> {
                self.0.send(packet).unwrap();
                Ok(())
            }
            fn event(&mut self, _: ViewerEvent) {}
        }

        async fn feedback(path: &mut DatagramPath, kind: FeedbackKind, frame_id: u64) -> MediaFeedback {
            loop {
                let PathEvent::Record(4, bytes) = path.next().await else { panic!("the verified datagram path closed") };
                let feedback = MediaFeedback::decode(&bytes[1..]).unwrap();
                if feedback.kind == kind && feedback.header.frame_id == frame_id {
                    return feedback;
                }
            }
        }

        let address = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let mut path = DatagramPath::new(Some(address));
        let (left, right) = tokio::io::duplex(64 * 1024);
        let (host, mut messages) = peer::spawn(left, PeerConfig::default());
        let (viewer, incoming) = peer::spawn(right, PeerConfig::default());
        let (commands, queue) = mpsc::unbounded_channel();
        let (decoder, acknowledgements) = mpsc::unbounded_channel();
        let (output, mut pictures) = mpsc::unbounded_channel();
        let mut platform = Output(output);
        let quality = StreamSettings::new(1920, 30, 8);
        let session = Attempt::new(quality, queue).with_datagrams(address).run(viewer, incoming, &mut platform, acknowledgements);
        let exchange = async {
            let hello =
                serde_json::json!({"version":1, "name":"host", "width":640, "height":360, "settings":quality, "canControl":false, "mediaTransportV1":true});
            host.send(&Message::json(MessageKind::Hello, &hello).unwrap()).unwrap();
            let request = MediaControl::read(&next(&mut messages).await).unwrap();
            assert_eq!(request.marked_repairs, Some(true));
            let mut media = HostMedia::default();
            media.set_udp_available(true);
            let Some(HostMediaEvent::Send(offer)) = media.control(&request, false).unwrap().pop() else { panic!("expected offer") };
            assert!(path.offer(&offer, true));
            host.send(&offer.message().unwrap()).unwrap();
            assert!(matches!(path.next().await, PathEvent::Verified));
            media.set_udp_verified(true);
            let prepare = MediaControl::read(&next(&mut messages).await).unwrap();
            assert_eq!(prepare.path.as_deref(), Some("udp"));
            media.control(&prepare, false).unwrap();
            let stream = media.preparing().unwrap();
            host.send(&media.prepared().unwrap().message().unwrap()).unwrap();
            let ready = MediaControl::read(&next(&mut messages).await).unwrap();
            media.control(&ready, false).unwrap();
            let mut avcc = 1500u32.to_be_bytes().to_vec();
            avcc.push(0x65);
            avcc.resize(1504, 7);
            let encoded = EncodedFrame { sps: vec![0x67], pps: vec![0x68], avcc };
            let HostFrame::Datagram(frame) = media.frame(3, encoded).unwrap() else { panic!("expected UDP IDR") };
            let now = Instant::now();
            let mut cache = RepairCache::new(stream);
            let parts = cache.insert(&frame, now, now + Duration::from_secs(2)).unwrap();
            assert_eq!(parts.len(), 2);
            let record = |kind: u8, index: usize| [vec![kind], parts[index].record()].concat();
            assert!(path.send(record(3, 1)));
            let missing = feedback(&mut path, FeedbackKind::Nack, 1).await;
            assert_eq!(missing.missing_ranges(), [crate::media::FragmentRange { first: 0, count: 1 }]);
            assert!(path.send(record(5, 0)));
            assert_eq!(feedback(&mut path, FeedbackKind::Reassembled, 1).await.header, frame.header);
            assert_eq!(pictures.recv().await.unwrap(), frame.packet);
            decoder.send(DecodeReceipt::Media(stream, 3)).unwrap();
            assert_eq!(feedback(&mut path, FeedbackKind::Decoded, 1).await.header, frame.header);
            let decoded_ready = MediaControl::read(&next(&mut messages).await).unwrap();
            assert_eq!(decoded_ready.operation, MediaOperation::DecodedReady);
            let Some(HostMediaEvent::Send(commit)) = media.control(&decoded_ready, false).unwrap().pop() else { panic!("expected commit") };
            host.send(&commit.message().unwrap()).unwrap();
            let committed = MediaControl::read(&next(&mut messages).await).unwrap();
            assert_eq!(committed.operation, MediaOperation::Committed);
            media.control(&committed, false).unwrap();
            let mut buffered = None;
            for sequence in 4..=12 {
                let delta = EncodedFrame { sps: vec![], pps: vec![], avcc: vec![0, 0, 0, 2, 0x41, sequence as u8] };
                let HostFrame::Datagram(source) = media.frame(sequence, delta).unwrap() else { panic!("expected UDP P frame") };
                let now = Instant::now();
                let parts = cache.insert(&source, now, now + Duration::from_secs(2)).unwrap();
                assert!(path.send([vec![3], parts[0].record()].concat()));
                cache.submitted(source.header, 0, now);
                assert_eq!(pictures.recv().await.unwrap(), source.packet);
                // This decoder produces the buffered picture only after receiving the following access unit.
                if let Some(previous) = buffered.replace(sequence) {
                    decoder.send(DecodeReceipt::Media(stream, previous)).unwrap();
                    let ack = feedback(&mut path, FeedbackKind::Decoded, source.header.frame_id - 1).await;
                    cache.feedback(&ack, Instant::now(), path.rtt);
                    assert_eq!(media.feedback(&ack), (1, vec![]));
                }
            }
            path.retire();
            let fallback = MediaControl::read(&next(&mut messages).await).unwrap();
            assert_eq!((fallback.operation, fallback.path.as_deref()), (MediaOperation::Prepare, Some("shared")));
            assert!(fallback.transport_epoch.unwrap() > stream.transport_epoch);
            commands.send(ViewerCommand::Disconnect).unwrap();
        };
        let (end, ()) = tokio::time::timeout(Duration::from_secs(15), async { tokio::join!(session, exchange) }).await.unwrap();
        assert!(end.local_stop);
    }

    #[tokio::test]
    async fn a_refused_udp_transaction_releases_its_probe_while_reliable_video_continues() {
        let address = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let (left, right) = tokio::io::duplex(64 * 1024);
        let (host, mut messages) = peer::spawn(left, PeerConfig::default());
        let (viewer, incoming) = peer::spawn(right, PeerConfig::default());
        let (commands, queue) = mpsc::unbounded_channel();
        let (_decoder, acknowledgements) = mpsc::unbounded_channel();
        let quality = StreamSettings::new(1920, 30, 8);
        let mut decoder = Decoder;
        let session = Attempt::new(quality, queue).with_datagrams(address).run(viewer, incoming, &mut decoder, acknowledgements);
        let exchange = async {
            let hello =
                serde_json::json!({"version":1, "name":"host", "width":640, "height":360, "settings":quality, "canControl":false, "mediaTransportV1":true});
            host.send(&Message::json(MessageKind::Hello, &hello).unwrap()).unwrap();
            let request = MediaControl::read(&next(&mut messages).await).unwrap();
            let mut media = HostMedia::default();
            media.set_udp_available(true);
            let Some(HostMediaEvent::Send(offer)) = media.control(&request, false).unwrap().pop() else { panic!("expected offer") };
            let mut path = DatagramPath::new(Some(address));
            assert!(path.offer(&offer, true));
            host.send(&offer.message().unwrap()).unwrap();
            assert!(matches!(path.next().await, PathEvent::Verified));
            let prepare = MediaControl::read(&next(&mut messages).await).unwrap();
            assert_eq!(prepare.path.as_deref(), Some("udp"));
            host.send(&MediaControl { operation: MediaOperation::Abort, ..prepare }.message().unwrap()).unwrap();
            let fallback = MediaControl::read(&next(&mut messages).await).unwrap();
            assert_eq!((fallback.operation, fallback.path.as_deref()), (MediaOperation::Prepare, Some("shared")));
            assert!(matches!(path.next().await, PathEvent::Lost));
            commands.send(ViewerCommand::Disconnect).unwrap();
        };
        let (end, ()) = tokio::time::timeout(Duration::from_secs(6), async { tokio::join!(session, exchange) }).await.unwrap();
        assert!(end.local_stop);
    }

    #[tokio::test]
    async fn delayed_legacy_decode_cannot_confirm_a_media_keyframe_reusing_its_sequence() {
        let (left, right) = tokio::io::duplex(64 * 1024);
        let (host, mut events) = peer::spawn(left, PeerConfig::default());
        let (viewer, incoming) = peer::spawn(right, PeerConfig::default());
        let (commands, queue) = mpsc::unbounded_channel();
        let (decoder, acknowledgements) = mpsc::unbounded_channel();
        let quality = StreamSettings::new(1920, 30, 8);
        let mut platform = Decoder;
        let session = run(viewer, incoming, &mut platform, quality, queue, acknowledgements);
        let exchange = async {
            let hello = serde_json::json!({"version": 1, "name": "host", "width": 640, "height": 360,
                "settings": quality, "canControl": false, "mediaTransportV1": true});
            host.send(&Message::json(MessageKind::Hello, &hello).unwrap()).unwrap();
            let request = MediaControl::read(&next(&mut events).await).unwrap();
            let packet = VideoPacket::h264(17, EncodedFrame { sps: vec![0x67, 1], pps: vec![0x68, 2], avcc: vec![0, 0, 0, 2, 0x65, 3] });
            host.send(&Message::new(MessageKind::Video, packet.encode().unwrap())).unwrap();
            let mut media = HostMedia::default();
            let Some(HostMediaEvent::Send(offer)) = media.control(&request, false).unwrap().pop() else { panic!("expected offer") };
            host.send(&offer.message().unwrap()).unwrap();
            let prepare = MediaControl::read(&next(&mut events).await).unwrap();
            media.control(&prepare, false).unwrap();
            let stream = media.preparing().unwrap();
            host.send(&media.prepared().unwrap().message().unwrap()).unwrap();
            assert_eq!(MediaControl::read(&next(&mut events).await).unwrap().operation, MediaOperation::Ready);
            host.send(&MediaFrame::new(stream, 1, packet).unwrap().message().unwrap()).unwrap();
            assert_eq!(MediaFeedback::decode(&next(&mut events).await.payload).unwrap().kind, FeedbackKind::Reassembled);

            decoder.send(DecodeReceipt::Legacy(17)).unwrap();
            assert_eq!(next(&mut events).await, Message::new(MessageKind::Acknowledgement, 17u32.to_be_bytes().to_vec()));
            decoder.send(DecodeReceipt::Media(stream, 17)).unwrap();
            assert_eq!(MediaFeedback::decode(&next(&mut events).await.payload).unwrap().kind, FeedbackKind::Decoded);
            assert_eq!(MediaControl::read(&next(&mut events).await).unwrap().operation, MediaOperation::DecodedReady);
            commands.send(ViewerCommand::Disconnect).unwrap();
        };
        let (end, ()) = tokio::time::timeout(Duration::from_secs(5), async { tokio::join!(session, exchange) }).await.unwrap();
        assert!(!end.retryable);
    }
}
