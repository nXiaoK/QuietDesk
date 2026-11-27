//! The host side of a session: the role of `DeskModel.accept` and `handleHost` in the macOS application,
//! for a host that streams over the control connection and advertises only what it implements.

use crate::audio_session::{AudioCapture, HostAudio};
use crate::auxiliary::{Accepted, Auxiliary, AuxiliaryEvent};
use crate::clipboard_session::SessionClipboard;
use crate::cursor::{CursorControl, CursorImage, CursorOperation, CursorPosition, CursorReason, CursorShape};
use crate::datagram_frames::{DatagramFrames, LossHistory};
use crate::datagram_path::{DatagramPath, PathEvent};
use crate::display::{DisplayControl, DisplaySwitch, HostDisplays, RemoteDisplayInfo};
use crate::error::{DeskError, Result};
use crate::input::{HostInputTranslator, InjectOp};
use crate::keymap::MacModifierMapping;
use crate::media::window::{self, RoundTrips};
use crate::media::{FeedbackKind, FragmentFeatures, MediaFrameHeader, MediaPath, MediaStreamId};
use crate::media::{Gate, HostFrame, HostMedia, HostMediaEvent, MediaControl, MediaFeedback, MediaOperation};
use crate::messages::{
    ControlStatus, DeviceIdentity, HOST_ENDED_REASON, Hello, InputAction, InputFeedback, InputKind, RemoteInput, SessionPauseRequest, SessionPauseResult,
    SessionTermination, StreamSettings, StreamSettingsRequest, StreamSettingsResult, TerminationOperation, VideoCodec, VideoStreamState, device_display_name,
};
use crate::peer::{PeerEvent, PeerHandle};
use crate::tls::AuxiliaryRole;
use crate::video::EncodedFrame;
use crate::video_pacing::VideoPacer;
use crate::wire::{self, Message, MessageKind};
use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

/// How long a host that announced `initialStreamNegotiationV1` waits for the viewer's first settings
/// before it starts with the ones in its hello.
const INITIAL_SETTINGS_GRACE: Duration = Duration::from_millis(250);

#[derive(Default)]
struct Timing {
    count: u32,
    total: Duration,
    minimum: Option<Duration>,
}

impl Timing {
    fn record(&mut self, sample: Duration) {
        self.count += 1;
        self.total += sample;
        self.minimum = Some(self.minimum.map_or(sample, |minimum| minimum.min(sample)));
    }

    fn mean(&self) -> Option<Duration> {
        (self.count != 0).then(|| self.total / self.count)
    }
}

struct DeliveryProbe {
    header: MediaFrameHeader,
    started: Instant,
    serialization: Duration,
}

#[derive(Default)]
struct DeliverySamples {
    stream: Option<MediaStreamId>,
    pending: VecDeque<DeliveryProbe>,
    timings: Timing,
    floors: VecDeque<(Instant, Duration)>,
}

impl DeliverySamples {
    fn submitted(&mut self, header: MediaFrameHeader, started: Instant, serialization: Duration) {
        if self.stream != Some(header.stream) {
            *self = Self { stream: Some(header.stream), ..Self::default() };
        }
        if !header.is_idr {
            self.pending.push_back(DeliveryProbe { header, started, serialization });
        }
    }

    fn feedback(&mut self, feedback: &MediaFeedback, pristine: bool, now: Instant) {
        if self.stream != Some(feedback.header.stream) || !matches!(feedback.kind, FeedbackKind::Reassembled | FeedbackKind::Decoded) {
            return;
        }
        if let Some(index) = self.pending.iter().position(|probe| probe.header == feedback.header) {
            let probe = self.pending.remove(index).expect("matched a delivery probe");
            if pristine {
                let elapsed = now.saturating_duration_since(probe.started);
                self.timings.record(elapsed.saturating_sub(probe.serialization));
            }
        }
        if feedback.kind == FeedbackKind::Decoded {
            self.pending.retain(|probe| probe.header.frame_id > feedback.header.frame_id);
        }
    }

    fn take_window(&mut self, now: Instant) -> Option<f64> {
        let timings = std::mem::take(&mut self.timings);
        self.floors.retain(|(at, _)| now.saturating_duration_since(*at) <= Duration::from_secs(30));
        if let Some(minimum) = timings.minimum {
            self.floors.push_back((now, minimum));
        }
        if timings.count < 3 {
            return None;
        }
        let floor = self.floors.iter().map(|(_, minimum)| *minimum).min()?;
        Some(timings.mean()?.saturating_sub(floor).as_secs_f64() * 1_000.0)
    }
}

struct CapturedFrame {
    generation: u64,
    frame: EncodedFrame,
    credit: FrameCredit,
}

struct FrameCredit {
    window: Arc<Mutex<FrameWindow>>,
    bytes: usize,
}

impl Drop for FrameCredit {
    fn drop(&mut self) {
        let mut window = self.window.lock().unwrap();
        window.outstanding -= 1;
        window.bytes -= self.bytes;
    }
}

struct FrameWindow {
    outstanding: usize,
    bytes: usize,
    limit: usize,
    gate: Gate,
    generation: u64,
    key_submitted: bool,
    encode_time: Timing,
}

impl FrameWindow {
    fn new(gate: Gate) -> Self {
        Self { outstanding: 0, bytes: 0, limit: FrameSink::WINDOW, gate, generation: 0, key_submitted: false, encode_time: Timing::default() }
    }

    fn set_gate(&mut self, gate: Gate) {
        if self.gate != gate {
            self.gate = gate;
            self.generation = self.generation.wrapping_add(1);
            self.key_submitted = false;
        }
    }

    fn has_credit(&self) -> bool {
        self.available_credit() != 0
    }

    fn available_credit(&self) -> usize {
        if self.bytes >= window::MAX_BUFFERED_BYTES {
            return 0;
        }
        let remaining = self.limit.saturating_sub(self.outstanding);
        match self.gate {
            Gate::Open => remaining,
            Gate::One if !self.key_submitted => remaining.min(1),
            _ => 0,
        }
    }
}

/// Where the capture pipeline delivers encoded frames, and how it learns that the viewer keeps up.
#[derive(Clone)]
pub struct FrameSink {
    frames: mpsc::UnboundedSender<CapturedFrame>,
    window: Arc<Mutex<FrameWindow>>,
}

/// The outcome at the capture queue, before transport or decoding.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameSubmission {
    Queued,
    /// Capture finished after the window filled or the current gate stopped accepting this frame.
    Dropped,
    /// The receiving stream has been replaced or the session has ended.
    Closed,
}

impl FrameSink {
    /// Frames a viewer may have received without acknowledging, as released viewers expect.
    pub const WINDOW: usize = window::LEGACY_FRAMES;

    /// Whether another frame may be encoded. A frame produced without credit only adds delay.
    pub fn has_credit(&self) -> bool {
        self.window.lock().unwrap().has_credit()
    }

    /// Frame slots an asynchronous encoder may account against while pictures are in flight.
    pub fn available_credit(&self) -> usize {
        self.window.lock().unwrap().available_credit()
    }

    /// Maximum frame credits granted by the current media negotiation and measured path.
    pub fn credit_limit(&self) -> usize {
        self.window.lock().unwrap().limit
    }

    /// Frames queued at capture or waiting for the viewer to acknowledge them.
    pub fn outstanding(&self) -> usize {
        self.window.lock().unwrap().outstanding
    }

    pub fn record_encode_time(&self, elapsed: Duration) {
        self.window.lock().unwrap().encode_time.record(elapsed);
    }

    /// Hands over one frame; false once the stream it belongs to has been replaced or the session ended.
    pub fn submit(&self, frame: EncodedFrame) -> bool {
        self.try_submit(frame) != FrameSubmission::Closed
    }

    pub fn try_submit(&self, frame: EncodedFrame) -> FrameSubmission {
        let mut window = self.window.lock().unwrap();
        if self.frames.is_closed() {
            return FrameSubmission::Closed;
        }
        // Capture may have started encoding just before a prepare closed the gate. Only an IDR
        // may consume the single permit; a queued frame from an older gate cannot consume it again.
        let bytes = frame.encoded_len();
        if !window.has_credit() || bytes > window::MAX_BUFFERED_BYTES - window.bytes || (window.gate == Gate::One && !frame.is_key_frame()) {
            return FrameSubmission::Dropped;
        }
        window.outstanding += 1;
        window.bytes += bytes;
        window.key_submitted = window.gate == Gate::One;
        let captured = CapturedFrame { generation: window.generation, frame, credit: FrameCredit { window: self.window.clone(), bytes } };
        let result = self.frames.send(captured);
        drop(window);
        if result.is_ok() { FrameSubmission::Queued } else { FrameSubmission::Closed }
    }
}

#[derive(Clone)]
pub struct HostCursorSample {
    pub image: Option<Arc<CursorImage>>,
    pub inside_display: bool,
    pub x: f64,
    pub y: f64,
}

struct HostCursor {
    id: Uuid,
    epoch: u32,
    revision: u64,
    sequence: u64,
    samples: Option<watch::Receiver<Option<HostCursorSample>>>,
    previous: Option<HostCursorSample>,
}

impl HostCursor {
    async fn changed(&mut self) -> Result<Option<HostCursorSample>> {
        let Some(samples) = &mut self.samples else { return std::future::pending().await };
        samples.changed().await.map_err(|_| DeskError::platform("光标采集已停止"))?;
        Ok(samples.borrow_and_update().clone())
    }

    fn send_sample(&mut self, peer: &PeerHandle, path: Option<&DatagramPath>, sample: HostCursorSample) -> Result<()> {
        let previous = self.previous.as_ref();
        if previous.is_none_or(|last| match (&last.image, &sample.image) {
            (Some(a), Some(b)) => !Arc::ptr_eq(a, b) && a != b,
            (None, None) => false,
            _ => true,
        }) {
            self.revision += 1;
            peer.send(&CursorShape { cursor_id: self.id, epoch: self.epoch, revision: self.revision, image: sample.image.clone() }.message()?)?;
        }
        if previous.is_none_or(|last| (last.inside_display, last.x, last.y) != (sample.inside_display, sample.x, sample.y)) {
            self.sequence += 1;
            let position = CursorPosition {
                cursor_id: self.id,
                epoch: self.epoch,
                sequence: self.sequence,
                inside_display: sample.inside_display,
                x: sample.x,
                y: sample.y,
            }
            .message()?;
            if !path.is_some_and(|path| path.send_payload(6, &position.payload)) {
                peer.send(&position)?;
            }
        }
        self.previous = Some(sample);
        Ok(())
    }
}

/// What a host needs from its machine. The session calls these from one task, never concurrently.
pub trait HostPlatform {
    /// Pixel size of the display that will be shared.
    fn display_size(&mut self) -> Result<(u32, u32)>;
    /// Current topology and the actual source (or the available replacement after removal).
    fn displays(&mut self) -> impl Future<Output = Result<Option<HostDisplays>>> + Send {
        std::future::ready(Ok(None))
    }
    /// Atomically replaces the frame sink, capture and input bounds, preserving the current pause and cursor modes.
    fn switch_display(&mut self, _id: u32, _settings: StreamSettings, _frames: FrameSink) -> impl Future<Output = Result<DisplaySwitch>> + Send {
        std::future::ready(Err(DeskError::platform("当前采集方式不支持切换显示器")))
    }
    /// Starts or restarts capture and encoding with these settings, delivering to `frames` from a keyframe on.
    /// Returns the size actually encoded and the settings actually in effect.
    fn configure(&mut self, settings: StreamSettings, frames: FrameSink) -> impl Future<Output = Result<VideoStreamState>> + Send;
    fn supports_adaptive_video(&self) -> bool {
        false
    }
    /// Changes only the running encoder's bitrate, preserving its prediction state.
    fn set_bitrate(&mut self, _megabits: i64) -> impl Future<Output = Result<()>> + Send {
        std::future::ready(Err(DeskError::platform("当前编码器不支持动态码率")))
    }
    /// Finishes any in-progress encode and arms a keyframe of the current screen before the gate opens.
    fn request_key_frame(&mut self) -> impl Future<Output = Result<()>> + Send;
    fn supports_independent_cursor(&self) -> bool {
        false
    }
    /// On failure the platform keeps its previous capture mode and sampler.
    fn configure_cursor(&mut self, _samples: Option<watch::Sender<Option<HostCursorSample>>>) -> impl Future<Output = Result<()>> + Send {
        std::future::ready(Err(DeskError::platform("当前采集方式无法单独传送光标")))
    }
    /// Stops or resumes frame production; a resumed stream continues with a keyframe of the current screen.
    fn set_paused(&mut self, paused: bool) -> impl Future<Output = Result<()>> + Send;
    /// Returns true when the system accepted the complete batch for the shared display.
    fn inject(&mut self, operations: &[InjectOp]) -> bool;
    fn supports_input_actions(&self) -> bool {
        false
    }
    fn supports_relative_mouse(&self) -> bool {
        false
    }
    fn supports_trackpad_gestures(&self) -> bool {
        false
    }
    /// A stable deadline while injected contacts require a target or driver check.
    fn gesture_check_at(&self) -> Option<Instant> {
        None
    }
    fn check_gestures(&mut self) {}
    /// Dropping the future cancels remaining work. Feedback describes the host's observed lock state.
    fn input_action(&mut self, _action: InputAction) -> impl Future<Output = Result<InputActionOutcome>> + Send + 'static {
        std::future::ready(Err(DeskError::platform("当前系统不支持远端键盘动作")))
    }
    fn supports_audio_capture(&self) -> bool {
        false
    }
    fn start_audio_capture(&mut self, _epoch: std::num::NonZeroU32, _redundant: bool, _paused: bool) -> Result<AudioCapture> {
        Err(DeskError::platform("当前系统不支持回传声音"))
    }
    fn open_clipboard(&mut self, _enabled: bool) -> Option<SessionClipboard> {
        None
    }
    fn clipboard_text(&mut self) -> Option<String>;
    fn set_clipboard_text(&mut self, text: &str) -> Result<()>;
    fn stop(&mut self);
}

#[derive(Clone, Debug)]
pub struct HostOptions {
    pub name: String,
    pub device_id: Option<Uuid>,
    pub allow_control: bool,
    /// Whether the viewer may read and write the clipboard text with the manual clipboard messages.
    pub clipboard: bool,
    /// The quality a viewer without a preference of its own receives.
    pub preferred: StreamSettings,
    /// The most this host encodes, whatever a viewer asks for.
    pub limit: StreamSettings,
    pub modifiers: MacModifierMapping,
    pub preferred_display: Option<u32>,
}

#[derive(Debug)]
pub enum HostCommand {
    /// The user ended the session; a subscribed viewer is told so and does not reconnect by itself.
    End,
    AllowControl(bool),
    Clipboard(bool),
    SelectDisplay(Option<u32>),
    RefreshDisplays,
}

#[derive(Clone, Debug, PartialEq)]
pub enum HostEvent {
    ViewerIdentity(DeviceIdentity),
    Streaming(VideoStreamState),
    Paused(bool),
    RoundTrip(f64),
    Displays { displays: Vec<RemoteDisplayInfo>, selected: u32, error: Option<String> },
    LocalDisplaySelected(Option<u32>),
    ClipboardStatus(String),
}

enum DisplayChange {
    Refresh,
    Local(Option<u32>),
    Remote(Uuid, u32),
}

#[derive(Debug)]
pub enum InputActionOutcome {
    Confirmed(InputFeedback),
    /// Caps was observed, but queued keys cannot safely be sent to the original target.
    Unconfirmed(InputFeedback),
}

type PendingInputAction = Pin<Box<dyn Future<Output = Result<InputActionOutcome>> + Send>>;

struct HostSession<'a, P: HostPlatform> {
    peer: &'a PeerHandle,
    platform: &'a mut P,
    options: HostOptions,
    viewer_identity: Option<DeviceIdentity>,
    clipboard: Option<SessionClipboard>,
    audio: HostAudio,
    supports_audio: bool,
    auxiliary: Auxiliary,
    datagrams: DatagramPath,
    udp_frames: Option<DatagramFrames>,
    udp_loss: LossHistory,
    fragment_features: Option<FragmentFeatures>,
    displays: Option<HostDisplays>,
    display_subscribed: bool,
    remote_display: Option<u32>,
    translator: HostInputTranslator,
    input_actions: bool,
    relative_mouse: bool,
    trackpad_gestures: bool,
    input_action: Option<PendingInputAction>,
    queued_input: VecDeque<(RemoteInput, bool)>,
    keyboard_needs_click: bool,
    /// `None` until the stream has started.
    state: Option<VideoStreamState>,
    frames: Option<mpsc::UnboundedReceiver<CapturedFrame>>,
    window: Arc<Mutex<FrameWindow>>,
    media: HostMedia,
    media_prepared: bool,
    cursor: HostCursor,
    recover_after: Instant,
    unacknowledged: VecDeque<(u32, FrameCredit)>,
    media_credits: VecDeque<FrameCredit>,
    round_trips: RoundTrips,
    adaptive_viewer: bool,
    delivery: DeliverySamples,
    sequence: u32,
    paused: bool,
    control_subscribed: bool,
    termination_subscribed: bool,
}

#[derive(Default)]
pub struct HostConnections {
    pub auxiliary: Option<Accepted>,
    pub datagram: Option<std::net::SocketAddr>,
    pub datagram_observer: Option<crate::datagram_transport::HostSocketObserver>,
}

impl From<Option<Accepted>> for HostConnections {
    fn from(auxiliary: Option<Accepted>) -> Self {
        Self { auxiliary, ..Self::default() }
    }
}

impl From<Accepted> for HostConnections {
    fn from(auxiliary: Accepted) -> Self {
        Some(auxiliary).into()
    }
}

/// Runs one viewer's session until it ends and returns why. `events` reports state for the user interface.
pub async fn run<P: HostPlatform>(
    peer: PeerHandle,
    incoming: mpsc::Receiver<PeerEvent>,
    platform: &mut P,
    options: HostOptions,
    commands: mpsc::UnboundedReceiver<HostCommand>,
    events: impl Fn(HostEvent),
) -> DeskError {
    run_with_auxiliary(peer, incoming, platform, options, commands, events, None).await
}

/// Accepts additional authenticated media streams during this control session.
pub async fn run_with_auxiliary<P: HostPlatform>(
    peer: PeerHandle,
    mut incoming: mpsc::Receiver<PeerEvent>,
    platform: &mut P,
    options: HostOptions,
    mut commands: mpsc::UnboundedReceiver<HostCommand>,
    events: impl Fn(HostEvent),
    connections: impl Into<HostConnections>,
) -> DeskError {
    let connections = connections.into();
    let translator = HostInputTranslator::new(options.modifiers);
    let input_actions = platform.supports_input_actions();
    let relative_mouse = platform.supports_relative_mouse();
    let trackpad_gestures = platform.supports_trackpad_gestures();
    let clipboard = platform.open_clipboard(options.clipboard);
    let mut session = HostSession {
        supports_audio: platform.supports_audio_capture(),
        audio: HostAudio::default(),
        auxiliary: Auxiliary::host(connections.auxiliary),
        datagrams: DatagramPath::new(connections.datagram),
        udp_frames: None,
        udp_loss: LossHistory::default(),
        fragment_features: None,
        clipboard,
        peer: &peer,
        platform,
        options,
        viewer_identity: None,
        displays: None,
        display_subscribed: false,
        remote_display: None,
        translator,
        input_actions,
        relative_mouse,
        trackpad_gestures,
        input_action: None,
        queued_input: VecDeque::new(),
        keyboard_needs_click: false,
        state: None,
        frames: None,
        window: Arc::new(Mutex::new(FrameWindow::new(Gate::Open))),
        media: HostMedia::default(),
        media_prepared: false,
        cursor: HostCursor { id: Uuid::new_v4(), epoch: 0, revision: 0, sequence: 0, samples: None, previous: None },
        recover_after: Instant::now(),
        unacknowledged: VecDeque::new(),
        media_credits: VecDeque::new(),
        round_trips: RoundTrips::default(),
        adaptive_viewer: false,
        delivery: DeliverySamples::default(),
        sequence: 0,
        paused: false,
        control_subscribed: false,
        termination_subscribed: false,
    };
    session.datagrams.host_observer = connections.datagram_observer;
    let reason = session.serve(&mut incoming, &mut commands, &events).await;
    session.release_input();
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
        let initial = match self.announce(events).await {
            Ok(settings) => settings,
            Err(error) => return error,
        };
        let start_by = Instant::now() + INITIAL_SETTINGS_GRACE;
        let mut statistics = tokio::time::interval(Duration::from_secs(1));
        statistics.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            if self.udp_frames.as_ref().is_some_and(|frames| Some(frames.stream) != self.media.udp_frame_stream()) {
                self.retire_datagram_frames();
            }
            self.datagrams.probe_transaction(self.media.pending_fast_challenge());
            if self.media.take_fast_keyframe() {
                if let Err(error) = self.request_opening_frame().await {
                    return error;
                }
                self.sync_gate();
            }
            let media_deadline = self.media.deadline().into_iter().chain(self.media.recovery().map(|_| self.recover_after)).min();
            let gesture_check = self.platform.gesture_check_at();
            let udp_by = self.udp_frames.as_ref().map(DatagramFrames::deadline);
            let bulk = self.auxiliary.peer(AuxiliaryRole::Bulk).cloned();
            let outcome = tokio::select! {
                event = incoming.recv() => match event {
                    Some(PeerEvent::Message(message)) => self.receive(message, events).await,
                    Some(PeerEvent::RoundTrip(milliseconds)) => {
                        self.round_trips.record_control(Instant::now(), milliseconds);
                        self.sync_gate();
                        events(HostEvent::RoundTrip(milliseconds)); Ok(())
                    }
                    Some(PeerEvent::Closed(reason)) => Err(reason),
                    None => Err(DeskError::Network("连接已关闭".to_string())),
                },
                _ = tokio::time::sleep_until(start_by), if self.state.is_none() => self.start(initial, events).await.map(drop),
                _ = statistics.tick() => self.report_statistics(),
                _ = tokio::time::sleep_until(media_deadline.unwrap_or(start_by)), if !self.paused && media_deadline.is_some() => self.tick_media(),
                _ = tokio::time::sleep_until(gesture_check.unwrap_or(start_by)), if gesture_check.is_some() => { self.platform.check_gestures(); Ok(()) }
                audio = self.audio.next() => self.audio.deliver(audio, self.paused, self.peer, self.media.datagram_audio.then_some(&self.datagrams)),
                event = self.datagrams.next() => self.datagram_event(event).await,
                _ = tokio::time::sleep_until(udp_by.unwrap_or(start_by)), if udp_by.is_some() && !self.paused => {
                    if self.udp_frames.as_mut().is_some_and(|frames| !frames.pump(&self.datagrams, Instant::now())) {
                        self.interrupt_datagram_stream()
                    } else { Ok(()) }
                }
                event = self.auxiliary.next() => self.auxiliary_event(event),
                status = SessionClipboard::next(&mut self.clipboard, self.peer, bulk.as_ref()) => match status {
                    Ok(Some(status)) => { events(HostEvent::ClipboardStatus(status)); Ok(()) }
                    Ok(None) => Ok(()),
                    Err(error) => Err(error),
                },
                frame = next_frame(&mut self.frames) => self.send_frame(frame),
                feedback = async { self.input_action.as_mut().expect("active input action").await }, if self.input_action.is_some() => self.finish_input_action(feedback),
                sample = self.cursor.changed(), if !self.paused => match sample {
                    Ok(Some(sample)) => self.publish_cursor(sample),
                    Ok(None) => Ok(()),
                    Err(error) => Err(error),
                },
                command = commands.recv() => match command {
                    Some(HostCommand::End) | None => Err(self.end()),
                    Some(HostCommand::AllowControl(allowed)) => self.allow_control(allowed),
                    Some(HostCommand::Clipboard(enabled)) => {
                        self.options.clipboard = enabled;
                        self.clipboard.as_ref().map_or(Ok(()), |copy| copy.preferences(enabled, !self.paused))
                    }
                    Some(HostCommand::RefreshDisplays) => self.change_display(DisplayChange::Refresh, events).await,
                    Some(HostCommand::SelectDisplay(id)) => self.change_display(DisplayChange::Local(id), events).await,
                },
            };
            if let Err(reason) = outcome {
                return reason;
            }
        }
    }

    /// Sends the hello. Its settings are the ones the stream starts with unless the viewer asks first.
    async fn announce(&mut self, events: &impl Fn(HostEvent)) -> Result<StreamSettings> {
        if self.input_actions {
            self.peer.order_input_echoes(MessageKind::Ping);
        }
        let (pixel_width, pixel_height) = self.platform.display_size()?;
        self.displays = self.platform.displays().await?;
        if let Some(layout) = &self.displays {
            layout.validate()?;
            events(HostEvent::Displays { displays: layout.displays.clone(), selected: layout.selected_display_id, error: None });
        }
        let preferred = self.options.preferred.limited_to(&self.options.limit);
        let initial = preferred.legacy_compatible();
        let (width, height) = initial.dimensions(pixel_width, pixel_height);
        self.peer.send(&Message::json(
            MessageKind::Hello,
            &Hello {
                version: wire::VERSION,
                name: device_display_name(&self.options.name),
                device_id: self.options.device_id,
                device_identity_exchange: self.options.device_id.map(|_| true),
                width: i64::from(width),
                height: i64::from(height),
                settings: initial,
                can_control: self.options.allow_control,
                input_actions: self.input_actions.then_some(true),
                clipboard_sync: self.clipboard.is_some().then_some(true),
                remote_audio_v1: self.supports_audio.then_some(true),
                physical_file_paste_v1: self.clipboard.is_some().then_some(true),
                relative_mouse_v1: self.relative_mouse.then_some(true),
                trackpad_gestures_v1: self.trackpad_gestures.then_some(true),
                live_settings: Some(true),
                control_status_updates: Some(true),
                extended_video_settings: Some(true),
                preferred_settings: Some(preferred.extended_compatible()),
                high_refresh_video_settings: Some(true),
                preferred_high_refresh_settings: Some(preferred.high_refresh_compatible()),
                adaptive_video_v1: self.platform.supports_adaptive_video().then_some(true),
                session_pause: Some(true),
                media_transport_v1: Some(true),
                independent_cursor_v1: self.platform.supports_independent_cursor().then_some(true),
                session_termination_v1: Some(true),
                initial_stream_negotiation_v1: Some(true),
                display_switching_v1: self.displays.as_ref().map(|_| true),
                displays: self.displays.as_ref().map(|layout| layout.displays.clone()),
                selected_display_id: self.displays.as_ref().map(|layout| layout.selected_display_id),
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
        let result = self.platform.configure(settings, FrameSink { frames: sender, window: self.window.clone() }).await;
        self.audio.configuration_finished(self.peer)?;
        let state = result?;
        if self.paused {
            self.platform.set_paused(true).await?;
        }
        self.frames = Some(receiver);
        self.state = Some(state);
        self.sync_gate();
        self.finish_preparation()?;
        events(HostEvent::Streaming(state));
        Ok(state)
    }

    fn send_frame(&mut self, frame: Option<CapturedFrame>) -> Result<()> {
        let Some(captured) = frame else {
            return Err(DeskError::platform("屏幕采集已停止"));
        };
        if self.paused || captured.generation != self.window.lock().unwrap().generation {
            return Ok(());
        }
        self.sequence = self.sequence.wrapping_add(1);
        match self.media.frame(self.sequence, captured.frame)? {
            HostFrame::Legacy(packet) => {
                self.unacknowledged.push_back((self.sequence, captured.credit));
                self.peer.send(&Message::new(MessageKind::Video, packet.encode()?))?;
            }
            HostFrame::Media(message) => {
                self.media_credits.push_back(captured.credit);
                let path = self.media.frame_path();
                let target = self.state.map_or(self.options.preferred, |state| state.settings).megabits as u32;
                match path {
                    MediaPath::Shared => self.peer.send(&message)?,
                    MediaPath::Udp => return Err(DeskError::platform("UDP 帧被错误地放入可靠通道")),
                    MediaPath::Tcp => {
                        if !self.auxiliary.peer(AuxiliaryRole::Video).is_some_and(|video| video.send_video(&message, target).is_ok()) {
                            self.auxiliary.close(AuxiliaryRole::Video);
                            let update = self.media.set_video_bound(false);
                            self.apply_media_update(update)?;
                            return Ok(());
                        }
                    }
                }
                if self.adaptive_viewer {
                    let header = self.media.last_media_frame().expect("the reliable media frame was recorded");
                    let paced = if path == MediaPath::Tcp { VideoPacer::duration(target, message.payload.len()) } else { Duration::ZERO };
                    self.delivery.submitted(header, Instant::now(), paced);
                }
            }
            HostFrame::Datagram(frame) => {
                self.media_credits.push_back(captured.credit);
                let now = Instant::now();
                if self.udp_frames.is_none() {
                    let settings = self.state.map_or(self.options.preferred, |state| state.settings);
                    let mut queue =
                        DatagramFrames::new(frame.header.stream, settings, self.fragment_features.unwrap_or_default(), now, std::mem::take(&mut self.udp_loss));
                    if self.media.capture_limits.dynamic {
                        queue.set_capacity(window::MAX_DYNAMIC_FRAMES);
                    }
                    self.udp_frames = Some(queue);
                }
                let header = frame.header;
                match self.udp_frames.as_mut().expect("active UDP stream").insert(frame, now, self.datagrams.rtt()) {
                    Ok(serialization) if self.adaptive_viewer => self.delivery.submitted(header, now, serialization),
                    Ok(_) => {}
                    Err(_) => self.interrupt_datagram_stream()?,
                }
            }
            HostFrame::Dropped => {}
        }
        self.sync_gate();
        Ok(())
    }

    fn capture_gate(&self) -> Gate {
        if self.paused { Gate::Closed } else { self.media.gate() }
    }

    fn report_statistics(&mut self) -> Result<()> {
        let encode = std::mem::take(&mut self.window.lock().unwrap().encode_time).mean().map(|time| (time.as_secs_f64() * 1_000.0).min(10_000.0));
        let delivery = self.delivery.take_window(Instant::now()).map(|milliseconds| milliseconds.min(60_000.0));
        if self.adaptive_viewer
            && self.capture_gate() == Gate::Open
            && (encode.is_some() || delivery.is_some())
            && let Some(session) = self.media.session_id()
        {
            self.peer.send(&MediaControl::stats(session, encode, delivery).message()?)?;
        }
        Ok(())
    }

    fn sync_gate(&mut self) {
        let rtt =
            self.round_trips.effective(Instant::now(), self.media.frame_path() == MediaPath::Udp, self.datagrams.verified().then_some(self.datagrams.rtt()));
        let fps = self.state.map_or(self.options.preferred, |state| state.settings).frames_per_second;
        let mut window = self.window.lock().unwrap();
        window.limit = self.media.capture_limits.credits(fps, rtt);
        window.set_gate(self.capture_gate());
    }

    fn settle(&mut self, count: usize) {
        self.media_credits.drain(..count);
    }

    fn retire_datagram_frames(&mut self) {
        if let Some(frames) = self.udp_frames.take() {
            self.udp_loss = frames.into_loss_history();
        }
    }

    fn interrupt_datagram_stream(&mut self) -> Result<()> {
        self.retire_datagram_frames();
        self.interrupt_media()
    }

    fn lose_datagrams(&mut self) -> Result<()> {
        self.datagrams.retire();
        self.udp_frames = None;
        self.udp_loss = LossHistory::default();
        let update = self.media.set_udp_verified(false);
        self.apply_media_update(update)
    }

    async fn datagram_event(&mut self, event: PathEvent) -> Result<()> {
        match event {
            PathEvent::Verified => {
                let update = self.media.set_udp_verified(true);
                self.apply_media_update(update)?;
                if self.media.frame_path() == MediaPath::Udp && self.media.preparing().is_some() {
                    self.prepare_media()?;
                }
            }
            PathEvent::Lost => return self.lose_datagrams(),
            PathEvent::FreshPong(id) => self.media.answered_fast_challenge(id),
            PathEvent::Record(7, mut data)
                if self.datagrams.authenticated()
                    && self.media.interactive_datagrams()
                    && self.options.allow_control
                    && !self.paused
                    && self.state.is_some() =>
            {
                self.receive_input_message(Message::new(MessageKind::Input, data.split_off(1)), true)?;
            }
            PathEvent::Record(11, mut data) if self.media.fast_recovery_negotiated() => {
                let message = Message::new(MessageKind::MediaControl, data.split_off(1));
                if let Ok(control) = MediaControl::read(&message)
                    && self.media.accepts_fast_copy(&control)
                {
                    self.receive_control(control).await?;
                }
            }
            PathEvent::Record(4, data) => {
                let Some(frames) = &mut self.udp_frames else { return Ok(()) };
                let Ok(feedback) = MediaFeedback::decode(&data[1..]) else { return Ok(()) };
                if feedback.header.stream != frames.stream
                    || (matches!(feedback.kind, FeedbackKind::Reassembled | FeedbackKind::Decoded) && !frames.fully_submitted(feedback.header))
                {
                    return Ok(());
                }
                let now = Instant::now();
                self.delivery.feedback(&feedback, frames.needed_no_repair(feedback.header), now);
                if !frames.feedback(&feedback, now, self.datagrams.rtt()) {
                    return self.interrupt_datagram_stream();
                }
                let update = self.media.feedback(&feedback);
                self.apply_media_update(update)?;
            }
            _ => {}
        }
        Ok(())
    }

    fn auxiliary_event(&mut self, event: AuxiliaryEvent) -> Result<()> {
        match event {
            AuxiliaryEvent::Bound(AuxiliaryRole::Video) | AuxiliaryEvent::Lost(AuxiliaryRole::Video) => {
                let update = self.media.set_video_bound(matches!(event, AuxiliaryEvent::Bound(_)));
                self.apply_media_update(update)?;
            }
            AuxiliaryEvent::Message(role, message) => {
                if !self.clipboard.as_ref().is_some_and(|copy| copy.receive(message).is_ok()) {
                    self.auxiliary.close(role);
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn send_control(&mut self, mut control: MediaControl) -> Result<()> {
        if let (Some(path), Some(epoch)) = (&control.path, control.transport_epoch) {
            log::info!("host media {:?} on {path} (epoch {epoch})", control.operation);
        }
        if control.operation == MediaOperation::Offer {
            let udp = self.datagrams.offer(&control, true);
            self.media.set_udp_available(udp);
            if !udp {
                control.datagram_interactive = None;
            }
            control.datagram_audio = (udp && self.supports_audio && self.media.datagram_audio).then_some(true);
            if udp && let Some(features) = self.fragment_features {
                features.advertise(&mut control);
            }
            control.path = Some(if udp { "udp" } else { "tcp" }.into());
            self.auxiliary.offer(&control);
        }
        if control.operation == MediaOperation::Commit
            && control.path.as_deref() == Some("udp")
            && let Some(frames) = &mut self.udp_frames
        {
            // The reliable opening handshake also proves that the first frame was decoded.
            let header = MediaFrameHeader { stream: frames.stream, frame_id: 1, is_idr: true };
            let ack = MediaFeedback::new(FeedbackKind::Decoded, header)?;
            frames.feedback(&ack, Instant::now(), self.datagrams.rtt());
        }
        if control.operation == MediaOperation::Recover {
            self.recover_after = Instant::now() + Duration::from_secs(1);
        }
        self.peer.send(&control.message()?)
    }

    fn finish_preparation(&mut self) -> Result<()> {
        if let Some(stream) = self.media.preparing().filter(|_| self.cursor.epoch > 0) {
            self.peer.send(&CursorControl::binding(self.cursor.id, self.cursor.epoch, self.cursor.samples.is_some(), stream).message()?)?;
        }
        if let Some(ready) = self.media.prepared() {
            self.send_control(ready)?;
            self.media_prepared = true;
        }
        Ok(())
    }

    async fn configure_cursor(&mut self, request: CursorControl) -> Result<()> {
        if request.operation != CursorOperation::Request || !self.platform.supports_independent_cursor() || !self.media_prepared {
            return Err(DeskError::invalid("光标功能未协商"));
        }
        let epoch = self.cursor.epoch.checked_add(1).ok_or_else(|| DeskError::Network("光标模式代次已耗尽，请重新连接".into()))?;
        self.hold_for_configuration()?;
        let (sender, receiver) = watch::channel(None);
        let reason = match self.platform.configure_cursor(request.enabled.then_some(sender)).await {
            Ok(()) => {
                self.cursor.samples = request.enabled.then_some(receiver);
                self.paused.then_some(CursorReason::WaitingForResume)
            }
            Err(error) => {
                log::warn!("cursor capture mode was retained: {error}");
                Some(CursorReason::Unavailable)
            }
        };
        self.cursor.epoch = epoch;
        self.cursor.sequence = 0;
        self.cursor.revision = 0;
        self.cursor.previous = None;
        let id = request.request_id.expect("validated cursor request");
        self.peer.send(&CursorControl::status(id, self.cursor.id, epoch, self.cursor.samples.is_some(), reason).message()?)?;
        if !self.paused {
            self.send_current_cursor()?;
            if let Some(recover) = self.media.recovery() {
                self.send_control(recover)?;
            }
        }
        Ok(())
    }

    fn hold_for_configuration(&mut self) -> Result<()> {
        let (settled, controls) = self.media.interrupted();
        self.window.lock().unwrap().set_gate(Gate::Closed);
        self.settle(settled);
        for control in controls.into_iter().filter(|control| control.operation == MediaOperation::Abort) {
            self.send_control(control)?;
        }
        Ok(())
    }

    async fn change_display(&mut self, change: DisplayChange, events: &impl Fn(HostEvent)) -> Result<()> {
        let Some(previous) = &self.displays else { return Ok(()) };
        let previous_id = previous.selected_display_id;
        let mut next = self.platform.displays().await?.ok_or_else(|| DeskError::platform("当前没有可共享的显示器"))?;
        next.validate()?;
        let main = next.displays.iter().find(|screen| screen.is_main).map(|screen| screen.id).unwrap_or(next.selected_display_id);
        let available = |id: u32| next.displays.iter().any(|display| display.id == id);
        let target = match change {
            DisplayChange::Refresh if !available(previous_id) => self.options.preferred_display.filter(|id| available(*id)).unwrap_or(main),
            DisplayChange::Refresh if self.options.preferred_display.is_none() && self.remote_display.is_none() => main,
            DisplayChange::Refresh => next.selected_display_id,
            DisplayChange::Local(None) => main,
            DisplayChange::Local(Some(id)) | DisplayChange::Remote(_, id) => id,
        };
        let changed = target != previous_id || next.needs_restart;
        if matches!(change, DisplayChange::Refresh) && !changed && previous.displays == next.displays {
            return Ok(());
        }
        let before = match self.state {
            Some(state) => state,
            None => self.start(self.options.preferred.limited_to(&self.options.limit).legacy_compatible(), events).await?,
        };
        let present = available(target);
        let held = present && changed;
        let error = if !present {
            Some("所选显示器当前不可用".into())
        } else if held {
            match self.replace_display(target, before.settings, events).await? {
                Some(reason) if matches!(change, DisplayChange::Refresh) => return Err(DeskError::platform(reason)),
                other => other,
            }
        } else {
            None
        };
        let applied = held && error.is_none();
        let state = self.state.expect("capture started before selecting a display");
        next.selected_display_id = if error.is_some() { previous_id } else { target };
        if error.is_some() && !available(previous_id) {
            return Err(DeskError::platform("显示器切换失败，原共享显示器已断开"));
        }
        next.needs_restart = false;
        let selected = next.selected_display_id;
        events(HostEvent::Displays { displays: next.displays.clone(), selected, error: error.clone() });
        match change {
            DisplayChange::Local(preference) if error.is_none() => {
                self.options.preferred_display = preference;
                self.remote_display = None;
                events(HostEvent::LocalDisplaySelected(preference));
            }
            DisplayChange::Remote(_, _) if error.is_none() => self.remote_display = Some(selected),
            DisplayChange::Refresh if self.remote_display != Some(selected) => self.remote_display = None,
            _ => {}
        }
        let notice = match change {
            DisplayChange::Remote(id, _) => Some(DisplayControl::Result { id, selected, displays: next.displays.clone(), video_state: state, error }),
            _ if self.display_subscribed => Some(DisplayControl::State { displays: next.displays.clone(), selected, video_state: applied.then_some(state) }),
            _ => None,
        };
        self.displays = Some(next);
        if let Some(notice) = notice {
            self.peer.send(&notice.message()?)?;
        } else if applied && (matches!(change, DisplayChange::Local(_)) || (before.width, before.height) != (state.width, state.height)) {
            return Err(DeskError::Network("共享显示器已变化，请重新连接以更新画面尺寸".into()));
        }
        if held {
            if !self.paused {
                if let Some(recover) = self.media.recovery() {
                    self.send_control(recover)?;
                } else if !applied && !self.media.has_stream() {
                    self.platform.request_key_frame().await?;
                }
            }
            self.sync_gate();
        }
        Ok(())
    }

    async fn replace_display(&mut self, target: u32, quality: StreamSettings, events: &impl Fn(HostEvent)) -> Result<Option<String>> {
        self.release_input();
        self.hold_for_configuration()?;
        let (sender, receiver) = mpsc::unbounded_channel();
        let window = Arc::new(Mutex::new(FrameWindow::new(Gate::Closed)));
        let sink = FrameSink { frames: sender, window: window.clone() };
        let result = self.platform.switch_display(target, quality, sink).await;
        self.audio.configuration_finished(self.peer)?;
        match result? {
            DisplaySwitch::Applied(state) => {
                self.window = window;
                self.frames = Some(receiver);
                self.unacknowledged.clear();
                self.state = Some(state);
                self.cursor.previous = None;
                events(HostEvent::Streaming(state));
                Ok(None)
            }
            DisplaySwitch::Retained(reason) => Ok(Some(reason.graphemes(true).take(512).collect())),
        }
    }

    fn publish_cursor(&mut self, sample: HostCursorSample) -> Result<()> {
        let path = (!self.paused && self.media.interactive_datagrams()).then_some(&self.datagrams);
        self.cursor.send_sample(self.peer, path, sample)
    }

    fn send_current_cursor(&mut self) -> Result<()> {
        if let Some(sample) = self.cursor.samples.as_mut().and_then(|rx| rx.borrow_and_update().clone()) {
            self.publish_cursor(sample)?;
        }
        Ok(())
    }

    async fn request_opening_frame(&mut self) -> Result<()> {
        let deadline = self.media.deadline().expect("an opening stream has a transaction deadline");
        match tokio::time::timeout_at(deadline, self.platform.request_key_frame()).await {
            Ok(result) => result,
            Err(_) => self.tick_media(),
        }
    }

    async fn receive_control(&mut self, control: MediaControl) -> Result<()> {
        if let (Some(path), Some(epoch)) = (&control.path, control.transport_epoch) {
            log::info!("viewer media {:?} on {path} (epoch {epoch})", control.operation);
        }
        if control.operation == MediaOperation::Request {
            self.fragment_features.get_or_insert_with(|| FragmentFeatures::from_peer(&control));
        }
        let fast_opening = self.media.fast_opening().filter(|header| {
            control.operation == MediaOperation::Committed
                && control.session_id == Some(header.stream.session_id)
                && control.transport_epoch == Some(header.stream.transport_epoch)
                && control.codec_epoch == Some(header.stream.codec_epoch)
        });
        if (control.operation == MediaOperation::DecodedReady || fast_opening.is_some()) && self.media.frame_path() == MediaPath::Udp {
            let ready =
                self.udp_frames.as_ref().is_some_and(|frames| frames.fully_submitted(MediaFrameHeader { stream: frames.stream, frame_id: 1, is_idr: true }));
            if !ready {
                return Ok(());
            }
        }
        for event in self.media.control_with_datagram(&control, self.paused, self.datagrams.authenticated())? {
            match event {
                HostMediaEvent::Send(reply) => self.send_control(*reply)?,
                HostMediaEvent::Prepare(_) => self.prepare_media()?,
                HostMediaEvent::ProduceKeyFrame => self.request_opening_frame().await?,
                HostMediaEvent::Settled(count) => self.settle(count),
            }
        }
        if self.media.fast_opening().is_none()
            && let Some(header) = fast_opening
            && let Some(frames) = &mut self.udp_frames
        {
            frames.feedback(&MediaFeedback::new(FeedbackKind::Decoded, header)?, Instant::now(), self.datagrams.rtt());
        }
        self.sync_gate();
        Ok(())
    }

    fn prepare_media(&mut self) -> Result<()> {
        self.delivery = DeliverySamples::default();
        self.sync_gate();
        self.unacknowledged.clear();
        if self.state.is_some() {
            self.finish_preparation()?;
        }
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
        self.delivery = DeliverySamples::default();
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
            self.release_input();
        }
        if self.control_subscribed {
            self.peer.send(&Message::json(MessageKind::ControlStatus, &ControlStatus { can_control: allowed })?)?;
        }
        Ok(())
    }

    fn release_input(&mut self) {
        self.input_action = None;
        self.queued_input.clear();
        let mut released = self.translator.release_all();
        if self.trackpad_gestures {
            // The platform may still own contacts if a preceding final frame failed.
            released.push(InjectOp::CancelGestures);
        }
        self.platform.inject(&released);
    }

    fn require_keyboard_refocus(&mut self) {
        self.release_input();
        self.keyboard_needs_click = true;
    }

    fn receive_input_message(&mut self, message: Message, from_datagram: bool) -> Result<()> {
        let mut input: RemoteInput = message.read_json()?;
        input.validate()?;
        if from_datagram && !input.is_sequenced_motion() {
            return Err(DeskError::invalid("交互数据报只能携带有序移动或拖动"));
        }
        if !self.options.allow_control
            || self.paused
            || self.state.is_none()
            || (input.relative_mouse == Some(true) && !self.relative_mouse)
            || (input.kind.is_gesture() && !self.trackpad_gestures)
        {
            return Ok(());
        }
        if !self.input_actions {
            input.independent_caps_lock = None;
        }
        if self.input_action.is_none() {
            self.perform_input(&input, from_datagram);
        } else if self.queued_input.len() < crate::input::INPUT_QUEUE_CAPACITY {
            self.queued_input.push_back((input, from_datagram));
        } else if !from_datagram {
            if let Some(i) = self.queued_input.iter().position(|(_, datagram)| *datagram) {
                self.queued_input.remove(i);
                self.queued_input.push_back((input, false));
            } else {
                self.require_keyboard_refocus();
            }
        }
        Ok(())
    }

    fn perform_input(&mut self, input: &RemoteInput, from_datagram: bool) {
        if from_datagram && !self.translator.permits_datagram_drag(input) {
            return;
        }
        let action = input.kind.action();
        if self.keyboard_needs_click && (action.is_some() || matches!(input.kind, InputKind::KeyDown | InputKind::KeyUp | InputKind::Flags)) {
            return;
        }
        if let Some(action) = action {
            if self.input_actions {
                if self.translator.shortcut_keys_held() {
                    self.require_keyboard_refocus();
                    return;
                }
                let action = self.platform.input_action(action);
                self.input_action = Some(Box::pin(async move {
                    tokio::time::timeout(Duration::from_secs(5), action).await.map_err(|_| DeskError::platform("远端键盘状态确认超时"))?
                }));
            }
        } else {
            let operations = self.translator.translate(input);
            let accepted = self.platform.inject(&operations);
            if accepted && self.keyboard_needs_click && operations.iter().any(|op| matches!(op, InjectOp::Button { down: true, .. })) {
                self.keyboard_needs_click = false;
            }
        }
    }

    fn finish_input_action(&mut self, result: Result<InputActionOutcome>) -> Result<()> {
        self.input_action = None;
        let confirmed = matches!(result, Ok(InputActionOutcome::Confirmed(_)));
        if !confirmed {
            self.require_keyboard_refocus();
        }
        let feedback = match result {
            Ok(InputActionOutcome::Confirmed(feedback) | InputActionOutcome::Unconfirmed(feedback)) => feedback,
            Err(_) => return Ok(()),
        };
        let message = Message::json(MessageKind::InputStatus, &feedback)?;
        if message.payload.len() > wire::MAXIMUM_CONTROL_BYTES {
            self.require_keyboard_refocus();
            return Ok(());
        }
        self.peer.send(&message)?;
        while self.input_action.is_none()
            && let Some((input, from_datagram)) = self.queued_input.pop_front()
        {
            self.perform_input(&input, from_datagram);
        }
        Ok(())
    }

    async fn receive(&mut self, message: Message, events: &impl Fn(HostEvent)) -> Result<()> {
        match message.kind {
            MessageKind::DeviceIdentity if self.options.device_id.is_some() => {
                let mut identity: DeviceIdentity = message.read_json()?;
                if self.viewer_identity.as_ref().is_some_and(|known| known.id != identity.id) {
                    return Err(DeskError::invalid("连接中的设备标识发生变化"));
                }
                identity.name = device_display_name(&identity.name);
                if self.viewer_identity.as_ref() != Some(&identity) {
                    self.viewer_identity = Some(identity.clone());
                    events(HostEvent::ViewerIdentity(identity));
                }
            }
            MessageKind::Ping => self.peer.send(&Message::new(MessageKind::Pong, message.payload))?,
            MessageKind::Input => self.receive_input_message(message, false)?,
            MessageKind::ReleaseInput => {
                self.release_input();
            }
            MessageKind::Acknowledgement => {
                let sequence = u32::from_be_bytes(message.payload[..].try_into().map_err(|_| DeskError::invalid("画面确认无效"))?);
                if let Some(position) = self.unacknowledged.iter().position(|(sent, _)| *sent == sequence) {
                    self.unacknowledged.remove(position);
                }
            }
            MessageKind::MediaControl => self.receive_control(MediaControl::read(&message)?).await?,
            MessageKind::CursorControl => self.configure_cursor(CursorControl::read(&message)?).await?,
            MessageKind::DisplayControl if self.displays.is_some() => match DisplayControl::read(&message)? {
                DisplayControl::Subscribe => {
                    self.display_subscribed = true;
                    let layout = self.displays.as_ref().unwrap();
                    self.peer.send(
                        &DisplayControl::State { displays: layout.displays.clone(), selected: layout.selected_display_id, video_state: None }.message()?,
                    )?;
                }
                DisplayControl::Select { id, display_id } => {
                    self.display_subscribed = true;
                    self.change_display(DisplayChange::Remote(id, display_id), events).await?;
                }
                _ => return Err(DeskError::invalid("显示器控制消息方向无效")),
            },
            MessageKind::MediaFeedback => {
                let feedback = MediaFeedback::decode(&message.payload)?;
                if self.media.frame_path() == MediaPath::Udp {
                    return Ok(());
                }
                self.delivery.feedback(&feedback, true, Instant::now());
                let update = self.media.feedback(&feedback);
                self.apply_media_update(update)?;
            }
            MessageKind::StreamSettingsRequest => {
                let request: StreamSettingsRequest = message.read_json()?;
                self.apply_settings(request, events).await?;
            }
            MessageKind::SessionPauseRequest => {
                let request: SessionPauseRequest = message.read_json()?;
                self.release_input();
                if self.paused && !request.paused {
                    self.interrupt_media()?;
                }
                let error = match self.platform.set_paused(request.paused).await {
                    Ok(()) => {
                        self.paused = request.paused;
                        self.audio.pause(self.paused);
                        self.datagrams.pause(self.paused);
                        if let Some(clipboard) = &self.clipboard {
                            clipboard.preferences(self.options.clipboard, !self.paused)?;
                        }
                        if self.paused
                            && let Some(abort) = self.media.paused()
                        {
                            self.send_control(abort)?;
                        }
                        self.sync_gate();
                        if !self.paused {
                            self.send_current_cursor()?;
                        }
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
            MessageKind::AudioControl if self.supports_audio => self.audio.control(&message, self.platform, self.paused, self.peer)?,
            kind if SessionClipboard::accepts(kind) => {
                self.clipboard.as_ref().ok_or_else(|| DeskError::invalid("尚未协商自动剪贴板"))?.receive(message)?;
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
        let old_window = self.window.clone();
        if self.state.is_some() {
            self.change_display(DisplayChange::Refresh, events).await?;
        }
        let display_restarted = !Arc::ptr_eq(&old_window, &self.window);
        let adaptive = self.platform.supports_adaptive_video();
        let reply = |state: VideoStreamState, error: Option<String>, restarted: bool| StreamSettingsResult {
            id: request.id,
            state,
            error,
            // This host encodes H.264 only; a viewer that named a codec hears which one it gets.
            codec: request.codec.map(|_| VideoCodec::H264),
            chroma_subsampling: request.chroma_subsampling.map(|_| crate::messages::ChromaSubsampling::Yuv420),
            restarts_stream: adaptive.then_some(restarted),
        };
        let requested = match request.settings.validate_control_values() {
            Ok(()) => request.settings.limited_to(&self.options.limit),
            Err(error) => {
                // Before the stream exists there is no state to report; the request is answered once it does.
                let restarted = self.state.is_none() || display_restarted;
                let state = match self.state {
                    Some(state) => state,
                    None => self.start(self.options.preferred.limited_to(&self.options.limit).legacy_compatible(), events).await?,
                };
                return self.peer.send(&Message::json(MessageKind::StreamSettingsResult, &reply(state, Some(error.to_string()), restarted))?);
            }
        };
        let in_place = adaptive && request.in_place_bitrate_v1 == Some(true);
        self.adaptive_viewer |= in_place;
        if let Some(mut state) = self.state
            && in_place
            && !display_restarted
            && self.media.gate() == Gate::Open
            && state.settings.megabits != requested.megabits
            && state.settings.longest_edge == requested.longest_edge
            && state.settings.frames_per_second == requested.frames_per_second
        {
            match self.platform.set_bitrate(requested.megabits).await {
                Ok(()) => {
                    state.settings = requested;
                    self.state = Some(state);
                    if let Some(frames) = &mut self.udp_frames {
                        frames.set_bitrate(requested.megabits, Instant::now());
                    }
                    events(HostEvent::Streaming(state));
                    return self.peer.send(&Message::json(MessageKind::StreamSettingsResult, &reply(state, None, false))?);
                }
                Err(error) => log::info!("encoder could not change bitrate in place: {error}"),
            }
        }
        let result = match self.state {
            Some(state) if state.settings == requested => reply(state, None, display_restarted),
            previous => match self.start(requested, events).await {
                Ok(state) => reply(state, None, true),
                Err(error) => {
                    // The failed attempt stopped the stream. Return to what worked, or end the session.
                    let Some(previous) = previous else { return Err(error) };
                    log::warn!("stream settings {requested:?} failed, restoring {:?}: {error}", previous.settings);
                    reply(self.start(previous.settings, events).await?, Some(error.to_string()), true)
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
    fn delivery_delay_excludes_repaired_frames_and_relearns_the_baseline_on_switch() {
        let now = Instant::now();
        let stream = MediaStreamId { session_id: Uuid::new_v4(), transport_epoch: 1, codec_epoch: 1 };
        let mut samples = DeliverySamples::default();
        let probe = |samples: &mut DeliverySamples, stream, frame_id, delay, pristine| {
            let header = MediaFrameHeader { stream, frame_id, is_idr: false };
            samples.submitted(header, now, Duration::from_millis(5));
            let feedback = MediaFeedback::new(FeedbackKind::Reassembled, header).unwrap();
            samples.feedback(&feedback, pristine, now + Duration::from_millis(delay));
        };
        for frame in 2..=4 {
            probe(&mut samples, stream, frame, 25, true);
        }
        assert_eq!(samples.take_window(now), Some(0.0));
        for frame in 5..=7 {
            probe(&mut samples, stream, frame, 65, true);
        }
        probe(&mut samples, stream, 8, 1_000, false);
        assert_eq!(samples.take_window(now + Duration::from_secs(1)), Some(40.0));
        let replacement = MediaStreamId { transport_epoch: 2, codec_epoch: 2, ..stream };
        for frame in 2..=4 {
            probe(&mut samples, replacement, frame, 80, true);
        }
        assert_eq!(samples.take_window(now + Duration::from_secs(2)), Some(0.0));
    }

    #[test]
    fn a_gate_change_fences_queued_frames_and_only_one_keyframe_consumes_the_permit() {
        let (frames, mut queue) = mpsc::unbounded_channel();
        let window = Arc::new(Mutex::new(FrameWindow::new(Gate::Open)));
        let sink = FrameSink { frames, window: window.clone() };
        let key = EncodedFrame { sps: vec![0x67, 1], pps: vec![0x68, 2], avcc: vec![0, 0, 0, 2, 0x65, 3] };
        let delta = EncodedFrame { sps: vec![], pps: vec![], avcc: vec![0, 0, 0, 2, 0x41, 4] };
        assert_eq!(sink.available_credit(), FrameSink::WINDOW);
        assert_eq!(sink.try_submit(key.clone()), FrameSubmission::Queued);
        window.lock().unwrap().set_gate(Gate::Closed);
        assert!(!sink.has_credit());
        assert_eq!(sink.try_submit(delta.clone()), FrameSubmission::Dropped);
        window.lock().unwrap().set_gate(Gate::One);
        assert_eq!(sink.available_credit(), 1, "the asynchronous encoder has only the opening slot");
        assert_eq!(sink.try_submit(delta.clone()), FrameSubmission::Dropped);
        assert!(sink.has_credit(), "a dependent frame was finishing when capture heard the request");
        assert_eq!(sink.try_submit(key.clone()), FrameSubmission::Queued);
        window.lock().unwrap().set_gate(Gate::One);
        assert!(!sink.has_credit(), "unrelated messages cannot reopen the permit");
        assert_eq!(sink.try_submit(delta), FrameSubmission::Dropped);
        assert_eq!(sink.try_submit(key), FrameSubmission::Dropped);
        let stale = queue.try_recv().unwrap();
        let current = queue.try_recv().unwrap();
        assert_ne!(stale.generation, current.generation);
        assert_eq!(current.generation, window.lock().unwrap().generation);
        assert!(queue.try_recv().is_err());
        assert_eq!(sink.outstanding(), 2);
    }

    #[test]
    fn credits_shrink_without_evicting_frames_and_the_byte_budget_follows_each_receipt() {
        let (frames, mut queue) = mpsc::unbounded_channel();
        let window = Arc::new(Mutex::new(FrameWindow::new(Gate::Open)));
        window.lock().unwrap().limit = window::MAX_DYNAMIC_FRAMES;
        let sink = FrameSink { frames, window: window.clone() };
        let sized = |bytes| EncodedFrame { sps: vec![], pps: vec![], avcc: vec![0; bytes - 8] };
        let cost = window::MAX_BUFFERED_BYTES / 3;
        for _ in 0..3 {
            assert_eq!(sink.try_submit(sized(cost)), FrameSubmission::Queued);
        }
        assert_eq!(sink.try_submit(sized(12)), FrameSubmission::Dropped);
        let oldest = queue.try_recv().unwrap();
        let next = queue.try_recv().unwrap();
        window.lock().unwrap().limit = 2;
        drop(next);
        assert_eq!(sink.outstanding(), 2);
        assert!(!sink.has_credit());
        drop(oldest);
        assert!(sink.has_credit());
        assert_eq!(window.lock().unwrap().bytes, cost);
        assert_eq!(sink.try_submit(sized(12)), FrameSubmission::Queued);
        drop(queue);
        assert_eq!(window.lock().unwrap().bytes, 0);
    }

    #[test]
    fn a_full_window_drops_frames_without_consuming_credit_and_a_closed_receiver_stops_capture() {
        let (frames, queue) = mpsc::unbounded_channel();
        let sink = FrameSink { frames, window: Arc::new(Mutex::new(FrameWindow::new(Gate::Open))) };
        let frame = EncodedFrame { sps: vec![], pps: vec![], avcc: vec![0, 0, 0, 2, 0x41, 1] };
        for _ in 0..FrameSink::WINDOW {
            assert_eq!(sink.try_submit(frame.clone()), FrameSubmission::Queued);
        }
        assert_eq!(sink.try_submit(frame.clone()), FrameSubmission::Dropped);
        assert!(sink.submit(frame.clone()));
        assert_eq!(queue.len(), FrameSink::WINDOW);
        assert_eq!(sink.outstanding(), FrameSink::WINDOW);
        drop(queue);
        assert_eq!(sink.try_submit(frame.clone()), FrameSubmission::Closed);
        assert!(!sink.submit(frame));
        assert_eq!(sink.outstanding(), 0);
    }

    #[tokio::test]
    async fn cursor_shapes_remain_reliable_and_position_uses_one_sequence_across_paths() {
        use crate::peer::{self, PeerConfig};
        let address = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let offer = MediaControl {
            operation: MediaOperation::Offer,
            session_id: Some(Uuid::new_v4()),
            datagram_key: Some(vec![19; 32]),
            path: Some("udp".into()),
            ..crate::media::ViewerMedia::request()
        };
        let mut host = DatagramPath::new(Some(address));
        let mut viewer = DatagramPath::new(Some(address));
        assert!(host.offer(&offer, true));
        assert!(viewer.offer(&offer, false));
        let (left, right) = tokio::io::duplex(8192);
        let (reliable, _reverse) = peer::spawn(left, PeerConfig::default());
        let (_receiver, mut input) = peer::spawn(right, PeerConfig::default());
        let mut cursor = HostCursor { id: Uuid::new_v4(), epoch: 1, revision: 0, sequence: 0, samples: None, previous: None };
        let sample = |x| HostCursorSample { image: None, inside_display: true, x, y: 0.25 };
        tokio::time::timeout(Duration::from_secs(4), async {
            assert!(matches!(host.next().await, PathEvent::Verified));
            assert!(matches!(viewer.next().await, PathEvent::Verified));
            cursor.send_sample(&reliable, Some(&host), sample(0.25)).unwrap();
            async fn control(input: &mut mpsc::Receiver<PeerEvent>) -> Message {
                loop {
                    match input.recv().await.unwrap() {
                        PeerEvent::Message(message) => return message,
                        PeerEvent::Closed(error) => panic!("control ended: {error}"),
                        PeerEvent::RoundTrip(_) => {}
                    }
                }
            }
            let shape = control(&mut input).await;
            assert_eq!(shape.kind, MessageKind::CursorShape);
            assert_eq!(CursorShape::decode(&shape.payload).unwrap().revision, 1);
            let PathEvent::Record(6, record) = viewer.next().await else { panic!("expected cursor datagram") };
            let first = CursorPosition::decode(&record[1..]).unwrap();
            assert_eq!((first.cursor_id, first.epoch, first.sequence, first.x), (cursor.id, 1, 1, 0.25));
            host.retire();
            cursor.send_sample(&reliable, Some(&host), sample(0.5)).unwrap();
            let fallback = control(&mut input).await;
            assert_eq!(fallback.kind, MessageKind::CursorPosition);
            let next = CursorPosition::decode(&fallback.payload).unwrap();
            assert_eq!((next.cursor_id, next.epoch, next.sequence, next.x), (first.cursor_id, first.epoch, 2, 0.5));
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn datagram_drags_require_the_matching_reliable_button_and_never_grant_control() {
        use crate::media::{ViewerMedia, ViewerMediaEvent};
        use crate::messages::StreamSettingsRequest;
        use crate::peer::{self, PeerConfig};
        struct InputOnly {
            ops: mpsc::UnboundedSender<Vec<InjectOp>>,
            sink: Option<FrameSink>,
        }
        impl HostPlatform for InputOnly {
            fn display_size(&mut self) -> Result<(u32, u32)> {
                Ok((640, 360))
            }
            async fn configure(&mut self, settings: StreamSettings, sink: FrameSink) -> Result<VideoStreamState> {
                self.sink = Some(sink);
                Ok(VideoStreamState { width: 640, height: 360, settings })
            }
            async fn request_key_frame(&mut self) -> Result<()> {
                Ok(())
            }
            async fn set_paused(&mut self, _: bool) -> Result<()> {
                Ok(())
            }
            fn inject(&mut self, ops: &[InjectOp]) -> bool {
                if !ops.is_empty() {
                    self.ops.send(ops.to_vec()).unwrap();
                }
                true
            }
            fn clipboard_text(&mut self) -> Option<String> {
                None
            }
            fn set_clipboard_text(&mut self, _: &str) -> Result<()> {
                Ok(())
            }
            fn stop(&mut self) {}
        }
        async fn next(input: &mut mpsc::Receiver<PeerEvent>, kind: MessageKind) -> Message {
            loop {
                match input.recv().await.unwrap() {
                    PeerEvent::Message(message) if message.kind == kind => return message,
                    PeerEvent::Closed(reason) => panic!("host ended early: {reason}"),
                    _ => {}
                }
            }
        }
        fn pointer(kind: InputKind, seq: u64, x: f64) -> Message {
            let mut input = RemoteInput::new(kind);
            input.pointer_sequence = Some(seq);
            input.x = x;
            Message::json(MessageKind::Input, &input).unwrap()
        }
        let address = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let (a, b) = tokio::io::duplex(65536);
        let (host, incoming) = peer::spawn(a, PeerConfig::default());
        let (viewer, mut from_host) = peer::spawn(b, PeerConfig::default());
        let (commands, queue) = mpsc::unbounded_channel();
        let (ops, mut operations) = mpsc::unbounded_channel();
        let mut platform = InputOnly { ops, sink: None };
        let settings = StreamSettings::new(1920, 30, 8);
        let options = HostOptions {
            name: "test".into(),
            device_id: None,
            allow_control: true,
            clipboard: false,
            preferred: settings,
            limit: settings,
            modifiers: MacModifierMapping::Standard,
            preferred_display: None,
        };
        let session =
            run_with_auxiliary(host, incoming, &mut platform, options, queue, |_| {}, HostConnections { datagram: Some(address), ..Default::default() });
        let exchange = async {
            next(&mut from_host, MessageKind::Hello).await;
            viewer.send(&Message::empty(MessageKind::ControlStatus)).unwrap();
            next(&mut from_host, MessageKind::ControlStatus).await;
            viewer.send(&Message::json(MessageKind::StreamSettingsRequest, &StreamSettingsRequest::new(settings)).unwrap()).unwrap();
            next(&mut from_host, MessageKind::StreamSettingsResult).await;
            let mut media = ViewerMedia::default();
            let mut request = ViewerMedia::request();
            media.request_interactive(&mut request);
            media.set_udp_available(true);
            viewer.send(&request.message().unwrap()).unwrap();
            let offer = MediaControl::read(&next(&mut from_host, MessageKind::MediaControl).await).unwrap();
            assert_eq!(offer.datagram_interactive, Some(true));
            let mut path = DatagramPath::new(Some(address));
            assert!(path.offer(&offer, false));
            media.control(&offer, Instant::now()).unwrap();
            assert!(matches!(path.next().await, PathEvent::Verified));
            let [ViewerMediaEvent::Send(prepare)] = &media.set_udp_verified(true, Instant::now()).unwrap()[..] else { panic!("expected prepare") };
            viewer.send(prepare).unwrap();
            let ready = MediaControl::read(&next(&mut from_host, MessageKind::MediaControl).await).unwrap();
            assert_eq!(ready.operation, MediaOperation::Ready);
            // The orphan with the larger sequence must not displace the following legitimate move.
            assert!(path.send_payload(7, &pointer(InputKind::Drag, 90, 0.9).payload));
            assert!(path.send_payload(7, &pointer(InputKind::Move, 1, 0.1).payload));
            assert_eq!(operations.recv().await.unwrap(), vec![InjectOp::Move { x: 0.1, y: 0.0 }]);
            viewer.send(&pointer(InputKind::Down, 2, 0.2)).unwrap();
            assert!(matches!(operations.recv().await.unwrap().as_slice(), [_, InjectOp::Button { down: true, .. }]));
            assert!(path.send_payload(7, &pointer(InputKind::Drag, 3, 0.3).payload));
            assert_eq!(operations.recv().await.unwrap(), vec![InjectOp::Move { x: 0.3, y: 0.0 }]);
            viewer.send(&pointer(InputKind::Up, 4, 0.4)).unwrap();
            assert!(matches!(operations.recv().await.unwrap().as_slice(), [_, InjectOp::Button { down: false, .. }]));
            assert!(path.send_payload(7, &pointer(InputKind::Move, 3, 0.3).payload));
            assert!(path.send_payload(7, &pointer(InputKind::Move, 5, 0.5).payload));
            assert_eq!(operations.recv().await.unwrap(), vec![InjectOp::Move { x: 0.5, y: 0.0 }]);
            commands.send(HostCommand::AllowControl(false)).unwrap();
            assert!(!next(&mut from_host, MessageKind::ControlStatus).await.read_json::<ControlStatus>().unwrap().can_control);
            assert!(path.send_payload(7, &pointer(InputKind::Move, 6, 0.6).payload));
            assert!(tokio::time::timeout(Duration::from_millis(50), operations.recv()).await.is_err());
            commands.send(HostCommand::AllowControl(true)).unwrap();
            assert!(next(&mut from_host, MessageKind::ControlStatus).await.read_json::<ControlStatus>().unwrap().can_control);
            // Edges on this lane are a protocol error and never reach platform input.
            assert!(path.send_payload(7, &pointer(InputKind::Down, 7, 0.7).payload));
            next_closed(&mut from_host).await;
            assert!(operations.try_recv().is_err());
        };
        async fn next_closed(incoming: &mut mpsc::Receiver<PeerEvent>) {
            while let Some(event) = incoming.recv().await {
                if matches!(event, PeerEvent::Closed(_)) {
                    break;
                }
            }
        }
        let (reason, ()) = tokio::time::timeout(Duration::from_secs(6), async { tokio::join!(session, exchange) }).await.unwrap();
        assert!(reason.to_string().contains("有序移动或拖动"));
    }
}
