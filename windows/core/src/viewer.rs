//! The viewer side of a session: the role of `DeskModel.handleViewer` in the macOS application, for a
//! viewer that receives video over the control connection and uses only what the host advertised.

use crate::cursor::{CursorControl, CursorOperation, CursorPosition, CursorPresentationState, CursorShape};
use crate::error::{DeskError, Result};
use crate::media::{DecodeReceipt, MediaControl, MediaStreamId, ViewerMedia, ViewerMediaEvent};
use crate::messages::{
    ControlStatus, HOST_ENDED_REASON, Hello, RemoteInput, SessionPauseRequest, SessionPauseResult, SessionTermination, StreamSettings, StreamSettingsRequest,
    StreamSettingsResult, TerminationOperation, VideoCodec, VideoStreamState,
};
use crate::peer::{PeerEvent, PeerHandle};
use crate::video::VideoPacket;
use crate::wire::{self, Message, MessageKind};
use std::sync::Arc;
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
    /// The viewer committed this stream after decoding its first keyframe and receiving the host's commit.
    MediaCommitted(MediaStreamId),
    Cursor(Arc<CursorPresentationState>),
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
    /// The request in flight: its identifier, when it was sent and what it asked for.
    pending_settings: Option<(Uuid, Instant, StreamSettings)>,
    pending_pause: Option<Uuid>,
    clipboard_requested: Option<Instant>,
    host_ended: bool,
}

/// Runs a session on an authenticated connection until it ends. `quality` is the viewer's preference;
/// `acknowledgements` reports the sequence numbers completed by the platform as specified by `ViewerPlatform`.
pub async fn run<P: ViewerPlatform>(
    peer: PeerHandle,
    mut incoming: mpsc::Receiver<PeerEvent>,
    platform: &mut P,
    quality: StreamSettings,
    mut commands: mpsc::UnboundedReceiver<ViewerCommand>,
    mut acknowledgements: mpsc::UnboundedReceiver<DecodeReceipt>,
) -> ViewerEnd {
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
        pending_settings: None,
        pending_pause: None,
        clipboard_requested: None,
        host_ended: false,
    };
    let hello_by = Instant::now() + HELLO_TIMEOUT;
    let end = loop {
        let settings_by = session.pending_settings.map(|(_, sent, _)| sent + SETTINGS_REPLY_TIMEOUT);
        let media_by = session.media.as_ref().and_then(ViewerMedia::deadline);
        let cursor_by = session.pending_cursor.map(|(_, deadline)| deadline);
        let outcome = tokio::select! {
            event = incoming.recv() => match event {
                Some(PeerEvent::Message(message)) => session.receive(message),
                Some(PeerEvent::RoundTrip(milliseconds)) => { session.platform.event(ViewerEvent::RoundTrip(milliseconds)); Ok(()) }
                Some(PeerEvent::Closed(reason)) => Err(reason),
                None => Err(DeskError::Network("连接已关闭".to_string())),
            },
            receipt = acknowledgements.recv() => match receipt {
                Some(receipt) => session.decoded(receipt),
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
            _ = tokio::time::sleep_until(media_by.unwrap_or(hello_by)), if media_by.is_some() => {
                session.update_media(|media| media.tick(Instant::now()))
            }
            _ = tokio::time::sleep_until(cursor_by.unwrap_or(hello_by)), if cursor_by.is_some() => {
                Err(DeskError::Network("光标模式切换超时，重新建立会话".into()))
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
            MessageKind::Video => {
                let packet = VideoPacket::decode(&message.payload)?;
                if let Some(media) = &mut self.media {
                    media.legacy(packet.sequence, message.payload.len())?;
                }
                self.platform.video(packet)?;
            }
            MessageKind::MediaControl => self.update_media(|media| media.control(&MediaControl::read(&message)?, Instant::now()))?,
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
                self.platform.event(ViewerEvent::Control(status.can_control));
            }
            MessageKind::SessionPauseResult if hello.session_pause == Some(true) => {
                let result: SessionPauseResult = message.read_json()?;
                if self.pending_pause == Some(result.id) {
                    self.pending_pause = None;
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
        if hello.media_transport_v1 == Some(true) {
            self.media = Some(ViewerMedia::default());
            self.peer.send(&ViewerMedia::request().message()?)?;
        }
        let confirm = live_settings && hello.initial_stream_negotiation_v1 == Some(true);
        self.hello = Some(hello);
        if confirm && self.supported(self.desired) == stream.settings {
            // The host holds its first frame until it hears the viewer's choice, even an unchanged one.
            return self.send_settings(stream.settings);
        }
        self.request_settings()
    }

    fn update_media(&mut self, update: impl FnOnce(&mut ViewerMedia) -> Result<Vec<ViewerMediaEvent>>) -> Result<()> {
        let media = self.media.as_mut().ok_or_else(|| DeskError::invalid("当前连接未协商媒体会话"))?;
        let events = update(media)?;
        self.apply_media_events(events)
    }

    fn apply_media_events(&mut self, events: Vec<ViewerMediaEvent>) -> Result<()> {
        for event in events {
            match event {
                ViewerMediaEvent::Send(message) => self.peer.send(&message)?,
                ViewerMediaEvent::Video(packet, stream, first_in_stream) => self.platform.media_video(packet, stream, first_in_stream)?,
                ViewerMediaEvent::Committed(stream) => {
                    if self.cursor.commit(stream) {
                        self.platform.event(ViewerEvent::Cursor(Arc::new(self.cursor.clone())));
                    }
                    self.platform.media_committed(stream)?;
                }
            }
        }
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
