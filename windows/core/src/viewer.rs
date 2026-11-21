//! The viewer side of a session: the role of `DeskModel.handleViewer` in the macOS application, for a
//! viewer that receives video over the control connection and uses only what the host advertised.

use crate::error::{DeskError, Result};
use crate::messages::{
    ControlStatus, HOST_ENDED_REASON, Hello, RemoteInput, SessionPauseRequest, SessionPauseResult, SessionTermination, StreamSettings, StreamSettingsRequest,
    StreamSettingsResult, TerminationOperation, VideoCodec, VideoStreamState,
};
use crate::peer::{PeerEvent, PeerHandle};
use crate::video::VideoPacket;
use crate::wire::{self, Message, MessageKind};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::Instant;
use uuid::Uuid;

/// A host that authenticated but never describes its screen is treated as failed.
const HELLO_TIMEOUT: Duration = Duration::from_secs(30);
/// How long a requested clipboard text is still accepted.
const CLIPBOARD_REPLY_TIMEOUT: Duration = Duration::from_secs(5);
/// A host that does not confirm a quality change in this time has stopped responding.
const SETTINGS_REPLY_TIMEOUT: Duration = Duration::from_secs(25);

#[derive(Debug)]
pub enum ViewerCommand {
    Input(RemoteInput),
    /// The window lost the keyboard: the host lets go of every key and button.
    ReleaseInput,
    Quality(StreamSettings),
    SendClipboard(String),
    RequestClipboard,
    /// Stops or resumes the picture while keeping the session, when the host supports it.
    Pause(bool),
    Disconnect,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ViewerEvent {
    Connected {
        name: String,
        can_control: bool,
        stream: VideoStreamState,
        live_settings: bool,
    },
    /// The stream now has this size and quality; `error` says why a requested change was not applied.
    Stream {
        stream: VideoStreamState,
        error: Option<String>,
    },
    Control(bool),
    Paused {
        paused: bool,
        error: Option<String>,
    },
    RoundTrip(f64),
    ClipboardText(String),
}

/// Why a session ended.
#[derive(Debug)]
pub struct ViewerEnd {
    pub reason: String,
    /// The host's user ended the session on purpose; reconnecting would be unwelcome.
    pub host_ended: bool,
    pub retryable: bool,
}

pub trait ViewerPlatform {
    /// A frame to decode. The platform reports its sequence on the acknowledgement channel once the
    /// decoder has taken it; the host sends at most three frames ahead of those reports.
    fn video(&mut self, packet: VideoPacket);
    fn event(&mut self, event: ViewerEvent);
}

struct ViewerSession<'a, P: ViewerPlatform> {
    peer: &'a PeerHandle,
    platform: &'a mut P,
    hello: Option<Hello>,
    stream: Option<VideoStreamState>,
    desired: StreamSettings,
    /// The request in flight: its identifier, when it was sent and what it asked for.
    pending_settings: Option<(Uuid, Instant, StreamSettings)>,
    pending_pause: Option<Uuid>,
    clipboard_requested: Option<Instant>,
    host_ended: bool,
}

/// Runs a session on an authenticated connection until it ends. `quality` is the viewer's preference;
/// `acknowledgements` carries the sequence numbers of frames the decoder has taken.
pub async fn run<P: ViewerPlatform>(
    peer: PeerHandle,
    mut incoming: mpsc::Receiver<PeerEvent>,
    platform: &mut P,
    quality: StreamSettings,
    mut commands: mpsc::UnboundedReceiver<ViewerCommand>,
    mut acknowledgements: mpsc::UnboundedReceiver<u32>,
) -> ViewerEnd {
    let mut session = ViewerSession {
        peer: &peer,
        platform,
        hello: None,
        stream: None,
        desired: quality,
        pending_settings: None,
        pending_pause: None,
        clipboard_requested: None,
        host_ended: false,
    };
    let hello_by = Instant::now() + HELLO_TIMEOUT;
    let end = loop {
        let settings_by = session.pending_settings.map(|(_, sent, _)| sent + SETTINGS_REPLY_TIMEOUT);
        let outcome = tokio::select! {
            event = incoming.recv() => match event {
                Some(PeerEvent::Message(message)) => session.receive(message),
                Some(PeerEvent::RoundTrip(milliseconds)) => { session.platform.event(ViewerEvent::RoundTrip(milliseconds)); Ok(()) }
                Some(PeerEvent::Closed(reason)) => Err(reason),
                None => Err(DeskError::Network("连接已关闭".to_string())),
            },
            sequence = acknowledgements.recv() => match sequence {
                Some(sequence) => peer.send(&Message::new(MessageKind::Acknowledgement, sequence.to_be_bytes().to_vec())),
                None => Err(DeskError::platform("视频解码已停止")),
            },
            command = commands.recv() => match command {
                Some(ViewerCommand::Disconnect) | None => break ViewerEnd { reason: "已断开连接".to_string(), host_ended: false, retryable: false },
                Some(command) => session.command(command),
            },
            _ = tokio::time::sleep_until(hello_by), if session.hello.is_none() => {
                Err(DeskError::Network("加密连接建立后超过 30 秒未收到共享信息".to_string()))
            }
            _ = tokio::time::sleep_until(settings_by.unwrap_or(hello_by)), if settings_by.is_some() => {
                Err(DeskError::Network("画质调整超过 25 秒未确认".to_string()))
            }
        };
        if let Err(error) = outcome {
            break ViewerEnd { retryable: !session.host_ended && error.is_retryable(), reason: error.to_string(), host_ended: session.host_ended };
        }
    };
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
            MessageKind::Video => self.platform.video(VideoPacket::decode(&message.payload)?),
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
            }
            MessageKind::ControlStatus if hello.control_status_updates == Some(true) => {
                let status: ControlStatus = message.read_json()?;
                self.platform.event(ViewerEvent::Control(status.can_control));
            }
            MessageKind::SessionPauseResult if hello.session_pause == Some(true) => {
                let result: SessionPauseResult = message.read_json()?;
                if self.pending_pause == Some(result.id) {
                    self.pending_pause = None;
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

    fn connected(&mut self, hello: Hello) -> Result<()> {
        hello.validate()?;
        let stream = VideoStreamState { settings: hello.settings, width: hello.width, height: hello.height };
        self.stream = Some(stream);
        let live_settings = hello.live_settings == Some(true);
        self.platform.event(ViewerEvent::Connected { name: hello.name.clone(), can_control: hello.can_control, stream, live_settings });
        if hello.session_termination_v1 == Some(true) {
            self.peer.send(&Message::json(MessageKind::SessionTermination, &SessionTermination { operation: TerminationOperation::Subscribe })?)?;
        }
        if hello.control_status_updates == Some(true) {
            self.peer.send(&Message::empty(MessageKind::ControlStatus))?;
        }
        let confirm = live_settings && hello.initial_stream_negotiation_v1 == Some(true);
        self.hello = Some(hello);
        if confirm && self.supported(self.desired) == stream.settings {
            // The host holds its first frame until it hears the viewer's choice, even an unchanged one.
            return self.send_settings(stream.settings);
        }
        self.request_settings()
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
        let Some(hello) = &self.hello else { return Ok(()) };
        match command {
            ViewerCommand::Input(input) => self.peer.send(&Message::json(MessageKind::Input, &input)?),
            ViewerCommand::ReleaseInput => self.peer.send(&Message::empty(MessageKind::ReleaseInput)),
            ViewerCommand::Quality(settings) => {
                settings.validate_control_values()?;
                self.desired = settings;
                self.request_settings()
            }
            ViewerCommand::SendClipboard(text) => {
                if text.len() > wire::MAXIMUM_CLIPBOARD_BYTES {
                    return Err(DeskError::invalid("文字剪贴板最大支持 1 MB"));
                }
                self.peer.send(&Message::new(MessageKind::Clipboard, text.into_bytes()))
            }
            ViewerCommand::RequestClipboard => {
                self.clipboard_requested = Some(Instant::now());
                self.peer.send(&Message::empty(MessageKind::RequestClipboard))
            }
            ViewerCommand::Pause(paused) => {
                if hello.session_pause != Some(true) || self.pending_pause.is_some() {
                    return Ok(());
                }
                let request = SessionPauseRequest { id: Uuid::new_v4(), paused };
                self.pending_pause = Some(request.id);
                self.peer.send(&Message::json(MessageKind::SessionPauseRequest, &request)?)
            }
            ViewerCommand::Disconnect => Ok(()),
        }
    }
}
