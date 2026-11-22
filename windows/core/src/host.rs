//! The host side of a session: the role of `DeskModel.accept` and `handleHost` in the macOS application,
//! for a host that streams over the control connection and advertises only what it implements.

use crate::cursor::{CursorControl, CursorImage, CursorOperation, CursorPosition, CursorReason, CursorShape};
use crate::display::{DisplayControl, DisplaySwitch, HostDisplays, RemoteDisplayInfo};
use crate::error::{DeskError, Result};
use crate::input::{HostInputTranslator, InjectOp};
use crate::keymap::MacModifierMapping;
use crate::media::{Gate, HostFrame, HostMedia, HostMediaEvent, MediaControl, MediaFeedback, MediaOperation};
use crate::messages::{
    ControlStatus, DeviceIdentity, HOST_ENDED_REASON, Hello, InputAction, InputFeedback, InputKind, RemoteInput, SessionPauseRequest, SessionPauseResult,
    SessionTermination, StreamSettings, StreamSettingsRequest, StreamSettingsResult, TerminationOperation, VideoCodec, VideoStreamState, device_display_name,
};
use crate::peer::{PeerEvent, PeerHandle};
use crate::video::EncodedFrame;
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
        self.try_submit(frame) != FrameSubmission::Closed
    }

    pub fn try_submit(&self, frame: EncodedFrame) -> FrameSubmission {
        let mut window = self.window.lock().unwrap();
        if self.frames.is_closed() {
            return FrameSubmission::Closed;
        }
        // Capture may have started encoding just before a prepare closed the gate. Only an IDR
        // may consume the single permit; a queued frame from an older gate cannot consume it again.
        if !window.has_credit() || (window.gate == Gate::One && !frame.is_key_frame()) {
            return FrameSubmission::Dropped;
        }
        if self.frames.send(CapturedFrame { generation: window.generation, frame }).is_err() {
            return FrameSubmission::Closed;
        }
        window.outstanding += 1;
        window.key_submitted = window.gate == Gate::One;
        FrameSubmission::Queued
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

    fn send_sample(&mut self, peer: &PeerHandle, sample: HostCursorSample) -> Result<()> {
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
            peer.send(
                &CursorPosition {
                    cursor_id: self.id,
                    epoch: self.epoch,
                    sequence: self.sequence,
                    inside_display: sample.inside_display,
                    x: sample.x,
                    y: sample.y,
                }
                .message()?,
            )?;
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
    fn displays(&mut self) -> Result<Option<HostDisplays>> {
        Ok(None)
    }
    /// Atomically replaces the frame sink, capture and input bounds, preserving the current pause and cursor modes.
    fn switch_display(&mut self, _id: u32, _settings: StreamSettings, _frames: FrameSink) -> impl Future<Output = Result<DisplaySwitch>> + Send {
        std::future::ready(Err(DeskError::platform("当前采集方式不支持切换显示器")))
    }
    /// Starts or restarts capture and encoding with these settings, delivering to `frames` from a keyframe on.
    /// Returns the size actually encoded and the settings actually in effect.
    fn configure(&mut self, settings: StreamSettings, frames: FrameSink) -> impl Future<Output = Result<VideoStreamState>> + Send;
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
    displays: Option<HostDisplays>,
    display_subscribed: bool,
    remote_display: Option<u32>,
    translator: HostInputTranslator,
    input_actions: bool,
    relative_mouse: bool,
    trackpad_gestures: bool,
    input_action: Option<PendingInputAction>,
    queued_input: VecDeque<RemoteInput>,
    keyboard_needs_click: bool,
    /// `None` until the stream has started.
    state: Option<VideoStreamState>,
    frames: Option<mpsc::UnboundedReceiver<CapturedFrame>>,
    window: Arc<Mutex<FrameWindow>>,
    media: HostMedia,
    media_prepared: bool,
    cursor: HostCursor,
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
    let input_actions = platform.supports_input_actions();
    let relative_mouse = platform.supports_relative_mouse();
    let trackpad_gestures = platform.supports_trackpad_gestures();
    let mut session = HostSession {
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
        sequence: 0,
        paused: false,
        control_subscribed: false,
        termination_subscribed: false,
    };
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
        let initial = match self.announce(events) {
            Ok(settings) => settings,
            Err(error) => return error,
        };
        let start_by = Instant::now() + INITIAL_SETTINGS_GRACE;
        loop {
            let media_deadline = self.media.deadline().into_iter().chain(self.media.recovery().map(|_| self.recover_after)).min();
            let gesture_check = self.platform.gesture_check_at();
            let outcome = tokio::select! {
                event = incoming.recv() => match event {
                    Some(PeerEvent::Message(message)) => self.receive(message, events).await,
                    Some(PeerEvent::RoundTrip(milliseconds)) => { events(HostEvent::RoundTrip(milliseconds)); Ok(()) }
                    Some(PeerEvent::Closed(reason)) => Err(reason),
                    None => Err(DeskError::Network("连接已关闭".to_string())),
                },
                _ = tokio::time::sleep_until(start_by), if self.state.is_none() => self.start(initial, events).await.map(drop),
                _ = tokio::time::sleep_until(media_deadline.unwrap_or(start_by)), if !self.paused && media_deadline.is_some() => self.tick_media(),
                _ = tokio::time::sleep_until(gesture_check.unwrap_or(start_by)), if gesture_check.is_some() => { self.platform.check_gestures(); Ok(()) }
                frame = next_frame(&mut self.frames) => self.send_frame(frame),
                feedback = async { self.input_action.as_mut().expect("active input action").await }, if self.input_action.is_some() => self.finish_input_action(feedback),
                sample = self.cursor.changed(), if !self.paused => match sample {
                    Ok(Some(sample)) => self.cursor.send_sample(self.peer, sample),
                    Ok(None) => Ok(()),
                    Err(error) => Err(error),
                },
                command = commands.recv() => match command {
                    Some(HostCommand::End) | None => Err(self.end()),
                    Some(HostCommand::AllowControl(allowed)) => self.allow_control(allowed),
                    Some(HostCommand::Clipboard(enabled)) => { self.options.clipboard = enabled; Ok(()) }
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
    fn announce(&mut self, events: &impl Fn(HostEvent)) -> Result<StreamSettings> {
        if self.input_actions {
            self.peer.order_input_echoes(MessageKind::Ping);
        }
        let (pixel_width, pixel_height) = self.platform.display_size()?;
        self.displays = self.platform.displays()?;
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
                relative_mouse_v1: self.relative_mouse.then_some(true),
                trackpad_gestures_v1: self.trackpad_gestures.then_some(true),
                live_settings: Some(true),
                control_status_updates: Some(true),
                extended_video_settings: Some(true),
                preferred_settings: Some(preferred.extended_compatible()),
                high_refresh_video_settings: Some(true),
                preferred_high_refresh_settings: Some(preferred.high_refresh_compatible()),
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
        let mut next = self.platform.displays()?.ok_or_else(|| DeskError::platform("当前没有可共享的显示器"))?;
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
        match self.platform.switch_display(target, quality, sink).await? {
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

    fn send_current_cursor(&mut self) -> Result<()> {
        if let Some(sample) = self.cursor.samples.as_mut().and_then(|rx| rx.borrow_and_update().clone()) {
            self.cursor.send_sample(self.peer, sample)?;
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

    fn perform_input(&mut self, input: &RemoteInput) {
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
            && let Some(input) = self.queued_input.pop_front()
        {
            self.perform_input(&input);
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
            MessageKind::Input => {
                let mut input: RemoteInput = message.read_json()?;
                input.validate()?;
                if input.relative_mouse == Some(true) && !self.relative_mouse {
                    return Ok(());
                }
                if input.kind.is_gesture() && !self.trackpad_gestures {
                    return Ok(());
                }
                if !self.input_actions {
                    input.independent_caps_lock = None;
                }
                if self.options.allow_control && !self.paused && self.state.is_some() {
                    if self.input_action.is_none() {
                        self.perform_input(&input);
                    } else if self.queued_input.len() < crate::input::INPUT_QUEUE_CAPACITY {
                        self.queued_input.push_back(input);
                    } else {
                        self.require_keyboard_refocus();
                    }
                }
            }
            MessageKind::ReleaseInput => {
                self.release_input();
            }
            MessageKind::Acknowledgement => {
                let sequence = u32::from_be_bytes(message.payload[..].try_into().map_err(|_| DeskError::invalid("画面确认无效"))?);
                if let Some(position) = self.unacknowledged.iter().position(|sent| *sent == sequence) {
                    self.unacknowledged.remove(position);
                    self.settle(1);
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
        if self.state.is_some() {
            self.change_display(DisplayChange::Refresh, events).await?;
        }
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
        assert_eq!(sink.try_submit(key.clone()), FrameSubmission::Queued);
        window.lock().unwrap().set_gate(Gate::Closed);
        assert!(!sink.has_credit());
        assert_eq!(sink.try_submit(delta.clone()), FrameSubmission::Dropped);
        window.lock().unwrap().set_gate(Gate::One);
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
        assert_eq!(sink.outstanding(), FrameSink::WINDOW);
    }
}
