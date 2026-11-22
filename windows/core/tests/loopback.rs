//! A host session and a viewer session of this crate talking over an in-memory connection, with
//! stand-ins for capture, decoding, input and the clipboard.

use quietdesk_core::audio::{AudioControl, AudioEncoder, AudioPacket, AudioState, INTERLEAVED_SAMPLES};
use quietdesk_core::audio_session::{AudioCapture, AudioPlayback, CaptureEvent, CaptureWorker, PlaybackEvent, PlaybackWorker};
use quietdesk_core::display::{DisplaySwitch, HostDisplays, RemoteDisplayInfo};
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::host::{self, FrameSink, HostCommand, HostEvent, HostOptions, HostPlatform, InputActionOutcome};
use quietdesk_core::input::InjectOp;
use quietdesk_core::keymap::MacModifierMapping;
use quietdesk_core::media::{DecodeReceipt, MediaControl, MediaFrame, MediaOperation, MediaStreamId, ViewerMedia, ViewerMediaEvent};
use quietdesk_core::messages::{DeviceIdentity, Hello, InputAction, InputFeedback, InputKind, RemoteInput, StreamSettings, VideoStreamState};
use quietdesk_core::peer::{self, PeerConfig, PeerEvent};
use quietdesk_core::video::{EncodedFrame, VideoPacket};
use quietdesk_core::viewer::{self, ViewerCommand, ViewerEnd, ViewerEvent, ViewerPlatform};
use quietdesk_core::wire::{Message, MessageKind};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

#[derive(Default)]
struct HostLog {
    audio_input: Option<(std::num::NonZeroU32, CaptureWorker)>,
    supports_sound: bool,
    configured: Vec<StreamSettings>,
    injected: Vec<InjectOp>,
    clipboard: Option<String>,
    paused: bool,
    stopped: bool,
    refuse: Option<StreamSettings>,
    static_desktop: bool,
    stale_frame_on_key_request: bool,
    displays: Vec<RemoteDisplayInfo>,
    selected: u32,
    refused_display: Option<u32>,
    switched: Vec<u32>,
    actions: Vec<(InputAction, tokio::sync::oneshot::Sender<Result<InputActionOutcome>>)>,
    supports_actions: bool,
    supports_gestures: bool,
    gesture_check: Option<tokio::time::Instant>,
    checked_gesture: bool,
    refuse_next_button_down: bool,
}

struct Capture {
    frames: FrameSink,
    key: bool,
    stale: bool,
    produced: usize,
}

struct FakeHost {
    log: Arc<Mutex<HostLog>>,
    sink: Arc<Mutex<Option<Capture>>>,
}

impl HostPlatform for FakeHost {
    fn supports_audio_capture(&self) -> bool {
        self.log.lock().unwrap().supports_sound
    }

    fn start_audio_capture(&mut self, epoch: std::num::NonZeroU32, _redundant: bool, paused: bool) -> Result<AudioCapture> {
        let (input, worker) = AudioCapture::channel(paused);
        self.log.lock().unwrap().audio_input = Some((epoch, worker));
        Ok(input)
    }

    fn supports_trackpad_gestures(&self) -> bool {
        self.log.lock().unwrap().supports_gestures
    }

    fn gesture_check_at(&self) -> Option<tokio::time::Instant> {
        self.log.lock().unwrap().gesture_check
    }

    fn check_gestures(&mut self) {
        let mut log = self.log.lock().unwrap();
        log.checked_gesture = true;
        log.gesture_check = None;
    }
    fn supports_input_actions(&self) -> bool {
        self.log.lock().unwrap().supports_actions
    }

    fn input_action(&mut self, action: InputAction) -> impl Future<Output = Result<InputActionOutcome>> + Send + 'static {
        let (complete, result) = tokio::sync::oneshot::channel();
        self.log.lock().unwrap().actions.push((action, complete));
        async move { result.await.unwrap() }
    }
    fn display_size(&mut self) -> Result<(u32, u32)> {
        let log = self.log.lock().unwrap();
        Ok(log.displays.iter().find(|screen| screen.id == log.selected).map_or((2560, 1440), |screen| (screen.width, screen.height)))
    }

    async fn displays(&mut self) -> Result<Option<HostDisplays>> {
        let log = self.log.lock().unwrap();
        if log.displays.is_empty() {
            return Ok(None);
        }
        let active = log.displays.iter().find(|screen| screen.id == log.selected);
        Ok(Some(HostDisplays { displays: log.displays.clone(), selected_display_id: active.unwrap_or(&log.displays[0]).id, needs_restart: active.is_none() }))
    }

    async fn switch_display(&mut self, id: u32, settings: StreamSettings, frames: FrameSink) -> Result<DisplaySwitch> {
        let mut log = self.log.lock().unwrap();
        if log.refused_display == Some(id) {
            return Ok(DisplaySwitch::Retained("无法切换采集源".into()));
        }
        let screen = log.displays.iter().find(|screen| screen.id == id).unwrap();
        let (width, height) = settings.dimensions(screen.width, screen.height);
        log.selected = id;
        log.switched.push(id);
        drop(log);
        *self.sink.lock().unwrap() = Some(Capture { frames, key: true, stale: false, produced: 0 });
        Ok(DisplaySwitch::Applied(VideoStreamState { settings, width: width.into(), height: height.into() }))
    }

    async fn configure(&mut self, settings: StreamSettings, frames: FrameSink) -> Result<VideoStreamState> {
        *self.sink.lock().unwrap() = None;
        if self.log.lock().unwrap().refuse == Some(settings) {
            return Err(DeskError::platform("编码器不支持该尺寸"));
        }
        {
            let mut log = self.log.lock().unwrap();
            log.configured.push(settings);
            log.paused = false;
        }
        *self.sink.lock().unwrap() = Some(Capture { frames, key: true, stale: false, produced: 0 });
        let (source_width, source_height) = self.display_size()?;
        let (width, height) = settings.dimensions(source_width, source_height);
        Ok(VideoStreamState { settings, width: i64::from(width), height: i64::from(height) })
    }

    async fn set_paused(&mut self, paused: bool) -> Result<()> {
        self.log.lock().unwrap().paused = paused;
        if let Some(capture) = self.sink.lock().unwrap().as_mut() {
            capture.key = true;
        }
        Ok(())
    }

    async fn request_key_frame(&mut self) -> Result<()> {
        let stale = self.log.lock().unwrap().stale_frame_on_key_request;
        let mut slot = self.sink.lock().unwrap();
        let capture = slot.as_mut().expect("keyframe requested before capture started");
        assert!(!capture.frames.has_credit(), "capture must wait until the keyframe request has taken effect");
        capture.key = true;
        capture.stale = stale;
        Ok(())
    }

    fn inject(&mut self, operations: &[InjectOp]) -> bool {
        let mut log = self.log.lock().unwrap();
        if log.refuse_next_button_down && operations.iter().any(|op| matches!(op, InjectOp::Button { down: true, .. })) {
            log.refuse_next_button_down = false;
            return false;
        }
        log.injected.extend_from_slice(operations);
        if operations.iter().any(|op| matches!(op, InjectOp::Gesture { .. })) {
            log.gesture_check = Some(tokio::time::Instant::now() + Duration::from_millis(5));
        }
        if operations.contains(&InjectOp::CancelGestures) {
            log.gesture_check = None;
        }
        true
    }

    fn clipboard_text(&mut self) -> Option<String> {
        self.log.lock().unwrap().clipboard.clone()
    }

    fn set_clipboard_text(&mut self, text: &str) -> Result<()> {
        self.log.lock().unwrap().clipboard = Some(text.to_string());
        Ok(())
    }

    fn stop(&mut self) {
        self.log.lock().unwrap().stopped = true;
        *self.sink.lock().unwrap() = None;
    }
}

/// Encodes a frame whenever the viewer has credit, like a capture loop on a busy screen.
async fn produce_frames(sink: Arc<Mutex<Option<Capture>>>, log: Arc<Mutex<HostLog>>) {
    loop {
        tokio::time::sleep(Duration::from_millis(1)).await;
        let mut slot = sink.lock().unwrap();
        let log = log.lock().unwrap();
        let Some(capture) = slot.as_mut() else { continue };
        if log.paused || (log.static_desktop && !capture.key) || !capture.frames.has_credit() {
            continue;
        }
        // The encoder may still return one dependent frame that was in flight when the request came in.
        let frame = if capture.key && !capture.stale {
            capture.key = false;
            key_frame()
        } else {
            EncodedFrame { sps: vec![], pps: vec![], avcc: vec![0, 0, 0, 2, 0x41, 4] }
        };
        capture.stale = false;
        capture.frames.submit(frame);
        capture.produced += 1;
    }
}

fn key_frame() -> EncodedFrame {
    EncodedFrame { sps: vec![0x67, 1], pps: vec![0x68, 2], avcc: vec![0, 0, 0, 2, 0x65, 3] }
}

#[derive(Default)]
struct ViewerLog {
    supports_sound: bool,
    audio_output: Option<PlaybackWorker>,
    events: Vec<ViewerEvent>,
    packets: Vec<VideoPacket>,
    /// Packet index of the decoded keyframe at each commit.
    commits: Vec<(MediaStreamId, usize)>,
    held_receipts: Option<Vec<DecodeReceipt>>,
}

struct FakeViewer {
    log: Arc<Mutex<ViewerLog>>,
    acknowledgements: mpsc::UnboundedSender<DecodeReceipt>,
    identity: Option<DeviceIdentity>,
}

impl FakeViewer {
    fn receive(&self, packet: VideoPacket, receipt: DecodeReceipt) {
        let mut log = self.log.lock().unwrap();
        if let Some(held) = &mut log.held_receipts {
            held.push(receipt);
        } else {
            let _ = self.acknowledgements.send(receipt);
        }
        log.packets.push(packet);
    }
}

impl ViewerPlatform for FakeViewer {
    fn supports_audio_playback(&self) -> bool {
        self.log.lock().unwrap().supports_sound
    }

    fn start_audio_playback(&mut self, _epoch: std::num::NonZeroU32, paused: bool) -> Result<AudioPlayback> {
        let (output, worker) = AudioPlayback::channel(paused);
        self.log.lock().unwrap().audio_output = Some(worker);
        Ok(output)
    }

    fn local_identity(&self) -> Option<&DeviceIdentity> {
        self.identity.as_ref()
    }
    fn video(&mut self, packet: VideoPacket) -> Result<()> {
        let receipt = DecodeReceipt::Legacy(packet.sequence);
        self.receive(packet, receipt);
        Ok(())
    }

    fn media_video(&mut self, packet: VideoPacket, stream: MediaStreamId, _: bool) -> Result<()> {
        let receipt = DecodeReceipt::Media(stream, packet.sequence);
        self.receive(packet, receipt);
        Ok(())
    }

    fn event(&mut self, event: ViewerEvent) {
        let mut log = self.log.lock().unwrap();
        if let ViewerEvent::MediaCommitted(stream) = event {
            let index = log.packets.len().checked_sub(1).expect("no decoded frame at commit");
            assert!(log.packets[index].is_key_frame(), "each commit follows its own IDR");
            log.commits.push((stream, index));
        }
        log.events.push(event);
    }
}

async fn until(what: &str, mut condition: impl FnMut() -> bool) {
    for _ in 0..2000 {
        if condition() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    panic!("timed out waiting until {what}");
}

struct Fixture {
    host_log: Arc<Mutex<HostLog>>,
    viewer_log: Arc<Mutex<ViewerLog>>,
    host_events: Arc<Mutex<Vec<HostEvent>>>,
    sink: Arc<Mutex<Option<Capture>>>,
    acknowledgements: mpsc::UnboundedSender<DecodeReceipt>,
    host_commands: mpsc::UnboundedSender<HostCommand>,
    viewer_commands: mpsc::UnboundedSender<ViewerCommand>,
}

impl Fixture {
    fn stream_events(&self) -> Vec<(StreamSettings, (i64, i64), Option<String>)> {
        let log = self.viewer_log.lock().unwrap();
        log.events
            .iter()
            .filter_map(|event| match event {
                ViewerEvent::Stream { stream, error } => Some((stream.settings, (stream.width, stream.height), error.clone())),
                _ => None,
            })
            .collect()
    }

    fn packet_count(&self) -> usize {
        self.viewer_log.lock().unwrap().packets.len()
    }

    fn outstanding(&self) -> usize {
        self.sink.lock().unwrap().as_ref().unwrap().frames.outstanding()
    }

    fn hold_decoder(&self) -> usize {
        let mut log = self.viewer_log.lock().unwrap();
        assert!(log.held_receipts.replace(Vec::new()).is_none());
        log.packets.len()
    }

    fn resume_decoder(&self) {
        let mut log = self.viewer_log.lock().unwrap();
        for receipt in log.held_receipts.take().unwrap() {
            self.acknowledgements.send(receipt).unwrap();
        }
    }

    fn has_event(&self, wanted: &ViewerEvent) -> bool {
        self.viewer_log.lock().unwrap().events.contains(wanted)
    }
}

/// Runs both sessions next to `scenario` and returns how each ended.
async fn run_sessions<S, F>(quality: StreamSettings, refuse: Option<StreamSettings>, scenario: S) -> (DeskError, ViewerEnd, Fixture)
where
    S: FnOnce(Arc<Fixture>) -> F,
    F: Future<Output = ()>,
{
    let config = PeerConfig { heartbeat: Duration::from_millis(50), idle_timeout: Duration::from_secs(5) };
    let (host_stream, viewer_stream) = tokio::io::duplex(256 * 1024);
    let (host_peer, host_incoming) = peer::spawn(host_stream, config);
    let (viewer_peer, viewer_incoming) = peer::spawn(viewer_stream, config);
    let host_log = Arc::new(Mutex::new(HostLog {
        clipboard: Some("来自被控端".to_string()),
        refuse,
        displays: vec![RemoteDisplayInfo::new(1, "横屏", 2560, 1440, true), RemoteDisplayInfo::new(2, "竖屏", 1080, 1920, false)],
        selected: 1,
        supports_actions: true,
        ..HostLog::default()
    }));
    let sink = Arc::new(Mutex::new(None));
    let mut host_platform = FakeHost { log: host_log.clone(), sink: sink.clone() };
    let viewer_log = Arc::new(Mutex::new(ViewerLog::default()));
    let (acknowledgements, acknowledged) = mpsc::unbounded_channel();
    let mut viewer_platform = FakeViewer { log: viewer_log.clone(), acknowledgements: acknowledgements.clone(), identity: None };
    let (host_commands, host_command_queue) = mpsc::unbounded_channel();
    let (viewer_commands, viewer_command_queue) = mpsc::unbounded_channel();
    let host_events = Arc::new(Mutex::new(Vec::new()));
    let fixture = Arc::new(Fixture {
        host_log: host_log.clone(),
        viewer_log,
        host_events: host_events.clone(),
        sink: sink.clone(),
        acknowledgements,
        host_commands,
        viewer_commands,
    });
    let options = host_options();
    let producer = tokio::spawn(produce_frames(sink, host_log));
    let record = move |event| host_events.lock().unwrap().push(event);
    let (host_end, viewer_end, ()) = tokio::join!(
        host::run(host_peer, host_incoming, &mut host_platform, options, host_command_queue, record),
        viewer::run(viewer_peer, viewer_incoming, &mut viewer_platform, quality, viewer_command_queue, acknowledged),
        scenario(fixture.clone()),
    );
    producer.abort();
    let fixture = Arc::try_unwrap(fixture).ok().expect("the scenario returned its fixture");
    (host_end, viewer_end, fixture)
}

fn host_options() -> HostOptions {
    HostOptions {
        name: "检查用电脑".to_string(),
        device_id: None,
        allow_control: true,
        clipboard: true,
        preferred: StreamSettings::new(1920, 30, 8),
        limit: StreamSettings::new(2560, 60, 30),
        modifiers: MacModifierMapping::Standard,
        preferred_display: None,
    }
}

#[tokio::test]
async fn losing_the_capture_producer_ends_the_connected_session() {
    let sessions = run_sessions(StreamSettings::new(1920, 30, 8), None, |fixture| async move {
        until("the viewer commits a stream", || !fixture.viewer_log.lock().unwrap().commits.is_empty()).await;
        *fixture.sink.lock().unwrap() = None;
    });
    let (reason, viewer, _) = tokio::time::timeout(Duration::from_secs(2), sessions).await.expect("capture loss must wake the host");
    assert_eq!(reason.to_string(), "屏幕采集已停止");
    assert!(viewer.retryable && !viewer.host_ended);
}

#[tokio::test]
async fn a_session_negotiates_streams_controls_and_ends_as_the_macos_roles_do() {
    let quality = StreamSettings::new(1920, 60, 20);
    let (host_end, viewer_end, fixture) = run_sessions(quality, None, |fixture| async move {
        // The viewer's first request arrives inside the host's grace period, so the stream starts once, as asked.
        until("the first stream commits", || !fixture.viewer_log.lock().unwrap().commits.is_empty()).await;
        assert_eq!(fixture.host_log.lock().unwrap().configured, [quality]);
        assert_eq!(fixture.stream_events(), [(quality, (1920, 1080), None)]);
        {
            let log = fixture.viewer_log.lock().unwrap();
            let hello_stream = VideoStreamState { settings: StreamSettings::new(1920, 30, 8), width: 1920, height: 1080 };
            assert_eq!(
                log.events[0],
                ViewerEvent::Connected {
                    name: "检查用电脑".to_string(),
                    device_id: None,
                    can_control: true,
                    stream: hello_stream,
                    live_settings: true,
                    session_pause: true,
                    input_actions: true,
                    relative_mouse: false,
                    trackpad_gestures: false,
                    clipboard_sync: false,
                    remote_audio: false,
                }
            );
            assert!(log.events.contains(&ViewerEvent::Control(true)), "the viewer subscribed to control changes");
            assert!(log.packets[0].is_key_frame());
        }
        let first = fixture.viewer_log.lock().unwrap().commits[0].1;
        until("frames keep coming while acknowledged", || fixture.packet_count() > first + 9).await;
        assert!(fixture.viewer_log.lock().unwrap().packets[first + 1..=first + 9].iter().all(|packet| !packet.is_key_frame()));

        let stalled = fixture.hold_decoder() + FrameSink::WINDOW;
        until("the entire window reaches the decoder", || fixture.packet_count() == stalled).await;
        tokio::time::sleep(Duration::from_millis(40)).await;
        assert_eq!(fixture.packet_count(), stalled, "receipt of a frame alone does not return credit");
        assert_eq!(fixture.outstanding(), FrameSink::WINDOW);
        fixture.resume_decoder();
        until("frames resume once acknowledged", || fixture.packet_count() > stalled + 3).await;

        // A request above the host's limit is lowered to it, and the viewer learns what it got.
        fixture.viewer_commands.send(ViewerCommand::Quality(StreamSettings::new(8192, 60, 100))).unwrap();
        let limit = StreamSettings::new(2560, 60, 30);
        until("the lowered quality is confirmed", || fixture.stream_events().len() == 2).await;
        assert_eq!(fixture.stream_events()[1], (limit, (2560, 1440), None));
        until("the quality change commits a new media stream", || fixture.viewer_log.lock().unwrap().commits.len() == 2).await;

        // Input reaches the host as key and pointer operations; a pause releases what is held.
        let mut key = RemoteInput::new(InputKind::KeyDown);
        key.key_code = 0x08;
        fixture.viewer_commands.send(ViewerCommand::Input(key)).unwrap();
        until("the key is injected", || fixture.host_log.lock().unwrap().injected.iter().any(|op| matches!(op, InjectOp::Key { down: true, .. }))).await;
        fixture.viewer_commands.send(ViewerCommand::Pause(true)).unwrap();
        until("the pause is confirmed", || fixture.has_event(&ViewerEvent::Paused { paused: true, error: None })).await;
        assert!(fixture.host_log.lock().unwrap().injected.iter().any(|op| matches!(op, InjectOp::Key { down: false, .. })));
        assert!(fixture.host_events.lock().unwrap().contains(&HostEvent::Paused(true)));
        let paused_at = fixture.packet_count();
        fixture.viewer_commands.send(ViewerCommand::Quality(quality)).unwrap();
        until("a quality change while paused takes effect", || fixture.stream_events().len() == 3).await;
        assert_eq!(fixture.stream_events()[2], (quality, (1920, 1080), None));
        assert!(fixture.host_log.lock().unwrap().paused, "the replacement encoder inherits the session pause");
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert_eq!(fixture.packet_count(), paused_at);
        assert_eq!(fixture.viewer_log.lock().unwrap().commits.len(), 2);
        fixture.viewer_commands.send(ViewerCommand::Pause(false)).unwrap();
        until("the resumed media stream commits", || fixture.viewer_log.lock().unwrap().commits.len() == 3).await;
        {
            let log = fixture.viewer_log.lock().unwrap();
            assert_eq!(log.commits[2].1, paused_at, "the first frame after resuming is the committed keyframe");
            for commits in log.commits.windows(2) {
                let (old, new) = (commits[0].0, commits[1].0);
                assert_eq!(old.session_id, new.session_id);
                assert!(new.transport_epoch > old.transport_epoch && new.codec_epoch > old.codec_epoch);
            }
        }
        fixture.host_log.lock().unwrap().static_desktop = true;
        until("all in-flight frames settle after the two switches", || fixture.outstanding() == 0).await;

        // The host's user withdraws control: the viewer hears it and later input is not injected.
        fixture.host_commands.send(HostCommand::AllowControl(false)).unwrap();
        until("the viewer hears control was withdrawn", || fixture.has_event(&ViewerEvent::Control(false))).await;
        let injected = fixture.host_log.lock().unwrap().injected.len();
        let mut click = RemoteInput::new(InputKind::Down);
        (click.x, click.y) = (0.5, 0.5);
        fixture.viewer_commands.send(ViewerCommand::Input(click)).unwrap();

        // Clipboard text travels only when asked for, in both directions.
        fixture.viewer_commands.send(ViewerCommand::RequestClipboard).unwrap();
        until("the host's clipboard text arrives", || fixture.has_event(&ViewerEvent::ClipboardText("来自被控端".to_string()))).await;
        assert_eq!(fixture.host_log.lock().unwrap().injected.len(), injected);
        fixture.viewer_commands.send(ViewerCommand::SendClipboard("来自控制端".to_string())).unwrap();
        until("the viewer's clipboard text is stored", || fixture.host_log.lock().unwrap().clipboard.as_deref() == Some("来自控制端")).await;

        fixture.host_commands.send(HostCommand::End).unwrap();
    })
    .await;
    assert_eq!(host_end.to_string(), "被控端已结束本次连接");
    assert!(viewer_end.host_ended && !viewer_end.retryable, "{viewer_end:?}");
    assert!(fixture.host_log.lock().unwrap().stopped);
}

#[tokio::test]
async fn a_failed_quality_change_keeps_the_previous_stream_and_reports_why() {
    let refused = StreamSettings::new(2560, 60, 30);
    let (_, viewer_end, fixture) = run_sessions(StreamSettings::new(1920, 30, 8), Some(refused), |fixture| async move {
        until("the first frame arrives", || fixture.packet_count() >= 1).await;
        fixture.viewer_commands.send(ViewerCommand::Quality(refused)).unwrap();
        until("the refusal is reported", || fixture.stream_events().len() == 2).await;
        let (settings, size, error) = fixture.stream_events()[1].clone();
        assert_eq!((settings, size), (StreamSettings::new(1920, 30, 8), (1920, 1080)));
        assert!(error.unwrap().contains("编码器不支持"));
        let resumed = fixture.packet_count();
        until("the previous stream continues", || fixture.packet_count() > resumed + 2).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(fixture.stream_events().len(), 2, "the viewer does not ask again for what was declined");
        fixture.viewer_commands.send(ViewerCommand::Disconnect).unwrap();
    })
    .await;
    assert!(!viewer_end.host_ended);
    assert_eq!(fixture.host_log.lock().unwrap().configured, [StreamSettings::new(1920, 30, 8), StreamSettings::new(1920, 30, 8)]);
}

#[tokio::test]
async fn updating_the_display_list_or_confirming_the_same_local_screen_keeps_the_active_stream() {
    run_sessions(StreamSettings::new(1920, 30, 8), None, |fixture| async move {
        until("the first stream commits", || !fixture.viewer_log.lock().unwrap().commits.is_empty()).await;
        fixture.host_log.lock().unwrap().displays[1].name = "已更名".into();
        fixture.host_commands.send(HostCommand::RefreshDisplays).unwrap();
        until("the viewer receives a topology change", || {
            fixture
                .viewer_log
                .lock()
                .unwrap()
                .events
                .iter()
                .any(|event| matches!(event, ViewerEvent::Displays { displays, revision: 0, .. } if displays[1].name == "已更名"))
        })
        .await;
        fixture.host_commands.send(HostCommand::SelectDisplay(None)).unwrap();
        until("the local preference is confirmed", || fixture.host_events.lock().unwrap().contains(&HostEvent::LocalDisplaySelected(None))).await;
        assert!(fixture.host_log.lock().unwrap().switched.is_empty());
        assert_eq!(fixture.stream_events().len(), 1);
        assert_eq!(fixture.viewer_log.lock().unwrap().commits.len(), 1);
        fixture.viewer_commands.send(ViewerCommand::Disconnect).unwrap();
    })
    .await;
}

#[tokio::test]
async fn keys_wait_for_the_confirmed_input_action_and_revoking_control_cancels_the_next_one() {
    run_sessions(StreamSettings::new(1920, 30, 8), None, |fixture| async move {
        until("the stream is ready", || !fixture.viewer_log.lock().unwrap().commits.is_empty()).await;
        let action = |kind: InputAction| fixture.viewer_commands.send(ViewerCommand::Input(kind.remote_input())).unwrap();
        let mut key = RemoteInput::new(InputKind::KeyDown);
        key.key_code = 8;
        key.independent_caps_lock = Some(true);
        action(InputAction::SwitchInputSource);
        fixture.viewer_commands.send(ViewerCommand::Input(key.clone())).unwrap();
        fixture.viewer_commands.send(ViewerCommand::RequestClipboard).unwrap();
        until("the host processed commands following the input", || fixture.has_event(&ViewerEvent::ClipboardText("来自被控端".into()))).await;
        assert!(fixture.host_log.lock().unwrap().injected.is_empty());
        let (sent, complete) = fixture.host_log.lock().unwrap().actions.pop().unwrap();
        assert_eq!(sent, InputAction::SwitchInputSource);
        let confirmed = InputFeedback { message: "已确认合成输入源".into(), caps_locked: false };
        complete.send(Ok(InputActionOutcome::Confirmed(confirmed.clone()))).unwrap();
        until("the viewer receives actual feedback", || fixture.has_event(&ViewerEvent::InputStatus(confirmed.clone()))).await;
        let pressed = InjectOp::Key { key: quietdesk_core::keymap::PcKey::Scan { code: 0x2E, extended: false }, down: true };
        assert_eq!(fixture.host_log.lock().unwrap().injected, [pressed]);
        action(InputAction::ToggleCapsLock);
        key.key_code = 0;
        fixture.viewer_commands.send(ViewerCommand::Input(key)).unwrap();
        until("the second action started", || !fixture.host_log.lock().unwrap().actions.is_empty()).await;
        let (_, cancelled) = fixture.host_log.lock().unwrap().actions.pop().unwrap();
        fixture.host_commands.send(HostCommand::AllowControl(false)).unwrap();
        until("the viewer learns that control was revoked", || fixture.has_event(&ViewerEvent::Control(false))).await;
        assert!(cancelled.is_closed());
        assert_eq!(fixture.host_log.lock().unwrap().injected.len(), 2, "only the previously held C key was released");
        fixture.viewer_commands.send(ViewerCommand::Disconnect).unwrap();
    })
    .await;
}

#[tokio::test]
async fn an_unconfirmed_action_blocks_keyboard_input_until_a_real_pointer_press() {
    run_sessions(StreamSettings::new(1920, 30, 8), None, |fixture| async move {
        until("the stream is ready", || !fixture.viewer_log.lock().unwrap().commits.is_empty()).await;
        let send = |input| fixture.viewer_commands.send(ViewerCommand::Input(input)).unwrap();
        let mut key = RemoteInput::new(InputKind::KeyDown);
        key.key_code = 8;
        key.independent_caps_lock = Some(true);
        send(InputAction::SwitchInputSource.remote_input());
        send(key.clone());
        fixture.viewer_commands.send(ViewerCommand::RequestClipboard).unwrap();
        until("the host has read the queued key", || fixture.has_event(&ViewerEvent::ClipboardText("来自被控端".into()))).await;
        let (_, complete) = fixture.host_log.lock().unwrap().actions.pop().unwrap();
        let feedback = InputFeedback { message: "请点击远端输入位置后继续".into(), caps_locked: true };
        complete.send(Ok(InputActionOutcome::Unconfirmed(feedback.clone()))).unwrap();
        until("the failure includes the observed Caps state", || fixture.has_event(&ViewerEvent::InputStatus(feedback.clone()))).await;
        fixture.host_log.lock().unwrap().refuse_next_button_down = true;
        send(RemoteInput::new(InputKind::Move));
        send(key.clone());
        let mut flags = RemoteInput::new(InputKind::Flags);
        flags.key_code = quietdesk_core::keymap::mac::SHIFT;
        flags.flags = quietdesk_core::keymap::mac::FLAG_SHIFT;
        send(flags);
        send(InputAction::ToggleCapsLock.remote_input());
        fixture.viewer_commands.send(ViewerCommand::ReleaseInput).unwrap();
        send(key.clone());
        send(RemoteInput::new(InputKind::Down));
        send(RemoteInput::new(InputKind::Up));
        send(key.clone());
        send(RemoteInput::new(InputKind::Down));
        send(RemoteInput::new(InputKind::Up));
        send(key);
        let pressed = InjectOp::Key { key: quietdesk_core::keymap::PcKey::Scan { code: 0x2e, extended: false }, down: true };
        until("typing resumes after the click", || fixture.host_log.lock().unwrap().injected.contains(&pressed)).await;
        {
            use quietdesk_core::input::MouseButton;
            let log = fixture.host_log.lock().unwrap();
            let accepted_click = log.injected.iter().position(|op| *op == InjectOp::Button { button: MouseButton::Left, down: true }).unwrap();
            assert!(log.injected[..accepted_click].iter().all(|op| !matches!(op, InjectOp::Key { .. })));
            assert_eq!(log.injected.iter().filter(|op| matches!(op, InjectOp::Key { .. })).collect::<Vec<_>>(), [&pressed]);
            assert!(log.actions.is_empty());
        }
        fixture.viewer_commands.send(ViewerCommand::Disconnect).unwrap();
    })
    .await;
}

#[tokio::test]
async fn a_forwarded_modifier_cannot_combine_with_the_platform_shortcut() {
    run_sessions(StreamSettings::new(1920, 30, 8), None, |fixture| async move {
        until("the stream is ready", || !fixture.viewer_log.lock().unwrap().commits.is_empty()).await;
        let mut flags = RemoteInput::new(InputKind::Flags);
        flags.key_code = quietdesk_core::keymap::mac::SHIFT;
        flags.flags = quietdesk_core::keymap::mac::FLAG_SHIFT;
        fixture.viewer_commands.send(ViewerCommand::Input(flags)).unwrap();
        fixture.viewer_commands.send(ViewerCommand::Input(InputAction::SwitchInputSource.remote_input())).unwrap();
        fixture.viewer_commands.send(ViewerCommand::RequestClipboard).unwrap();
        until("the host handled the action", || fixture.has_event(&ViewerEvent::ClipboardText("来自被控端".into()))).await;
        {
            let log = fixture.host_log.lock().unwrap();
            assert!(log.actions.is_empty());
            let shift = quietdesk_core::keymap::pc::LEFT_SHIFT;
            assert_eq!(log.injected, [InjectOp::Key { key: shift, down: true }, InjectOp::Key { key: shift, down: false }]);
        }
        fixture.viewer_commands.send(ViewerCommand::Disconnect).unwrap();
    })
    .await;
}

#[tokio::test]
async fn only_a_capable_host_starts_gestures_and_cancels_its_contacts_on_release() {
    use quietdesk_core::messages::{Hello, ScrollPhase, TrackpadGesture};
    for supported in [false, true] {
        let (left, right) = tokio::io::duplex(8192);
        let (host, incoming) = peer::spawn(left, PeerConfig::default());
        let (viewer, mut messages) = peer::spawn(right, PeerConfig::default());
        let log = Arc::new(Mutex::new(HostLog { supports_gestures: supported, ..Default::default() }));
        let mut platform = FakeHost { log: log.clone(), sink: Arc::default() };
        let (commands, queue) = mpsc::unbounded_channel();
        let exchange = async {
            let hello: Hello = next_message(&mut messages).await.read_json().unwrap();
            assert_eq!(hello.trackpad_gestures_v1, supported.then_some(true));
            until("capture starts", || !log.lock().unwrap().configured.is_empty()).await;
            let mut input = RemoteInput::new(InputKind::Magnify);
            (input.x, input.y) = (0.5, 0.2);
            input.magnification = Some(0.15);
            input.gesture_phase = Some(ScrollPhase::Began);
            viewer.send(&Message::json(MessageKind::Input, &input).unwrap()).unwrap();
            if supported {
                until("the platform can check its contacts without another input", || log.lock().unwrap().checked_gesture).await;
            }
            viewer.send(&Message::empty(MessageKind::ReleaseInput)).unwrap();
            viewer.send(&Message::new(MessageKind::Clipboard, b"received".to_vec())).unwrap();
            until("the host passed the release", || log.lock().unwrap().clipboard.as_deref() == Some("received")).await;
            {
                let log = log.lock().unwrap();
                if supported {
                    assert_eq!(
                        log.injected,
                        [
                            InjectOp::Gesture { gesture: TrackpadGesture::Magnify(0.15), phase: Some(ScrollPhase::Began), x: 0.5, y: 0.2, relative: false },
                            InjectOp::CancelGestures
                        ]
                    );
                } else {
                    assert!(log.injected.is_empty());
                }
            }
            commands.send(HostCommand::End).unwrap();
        };
        tokio::time::timeout(Duration::from_secs(3), async { tokio::join!(host::run(host, incoming, &mut platform, host_options(), queue, |_| {}), exchange) })
            .await
            .unwrap();
    }
}

#[tokio::test]
async fn an_unadvertised_relative_mouse_cannot_click_the_absolute_placeholder() {
    use quietdesk_core::messages::Hello;
    let (left, right) = tokio::io::duplex(8192);
    let (host, incoming) = peer::spawn(left, PeerConfig::default());
    let (viewer, mut messages) = peer::spawn(right, PeerConfig::default());
    let log = Arc::new(Mutex::new(HostLog::default()));
    let mut platform = FakeHost { log: log.clone(), sink: Arc::default() };
    let (commands, queue) = mpsc::unbounded_channel();
    let exchange = async {
        let hello: Hello = next_message(&mut messages).await.read_json().unwrap();
        assert!(hello.relative_mouse_v1.is_none());
        until("capture starts", || !log.lock().unwrap().configured.is_empty()).await;
        let mut absolute = RemoteInput::new(InputKind::Move);
        absolute.x = 0.8;
        absolute.y = 0.3;
        for input in [RemoteInput::new(InputKind::Down).at_current_pointer(), absolute] {
            viewer.send(&Message::json(MessageKind::Input, &input).unwrap()).unwrap();
        }
        let moved = InjectOp::Move { x: 0.8, y: 0.3 };
        until("ordinary movement is accepted", || log.lock().unwrap().injected.contains(&moved)).await;
        assert_eq!(log.lock().unwrap().injected, [moved]);
        commands.send(HostCommand::End).unwrap();
    };
    tokio::time::timeout(Duration::from_secs(3), async { tokio::join!(host::run(host, incoming, &mut platform, host_options(), queue, |_| {}), exchange) })
        .await
        .unwrap();
}

#[tokio::test]
async fn an_unavailable_input_action_cannot_disable_legacy_caps_synchronization() {
    use quietdesk_core::messages::Hello;
    let (left, right) = tokio::io::duplex(64 * 1024);
    let (host, incoming) = peer::spawn(left, PeerConfig::default());
    let (viewer, mut messages) = peer::spawn(right, PeerConfig::default());
    let log = Arc::new(Mutex::new(HostLog::default()));
    let mut platform = FakeHost { log: log.clone(), sink: Arc::default() };
    let (commands, queue) = mpsc::unbounded_channel();
    let exchange = async {
        let hello = next_message(&mut messages).await;
        assert_eq!(hello.kind, MessageKind::Hello);
        assert!(hello.read_json::<Hello>().unwrap().input_actions.is_none());
        until("capture starts", || !log.lock().unwrap().configured.is_empty()).await;
        let mut key = RemoteInput::new(InputKind::KeyDown);
        key.key_code = 8;
        key.flags = quietdesk_core::keymap::mac::FLAG_CAPS_LOCK;
        key.independent_caps_lock = Some(true);
        for input in [InputAction::ToggleCapsLock.remote_input(), key] {
            viewer.send(&Message::json(MessageKind::Input, &input).unwrap()).unwrap();
        }
        until("the legacy key is injected", || !log.lock().unwrap().injected.is_empty()).await;
        {
            let log = log.lock().unwrap();
            assert!(log.actions.is_empty());
            assert_eq!(log.injected[0], InjectOp::CapsLock(true));
        }
        commands.send(HostCommand::End).unwrap();
    };
    tokio::time::timeout(Duration::from_secs(3), async { tokio::join!(host::run(host, incoming, &mut platform, host_options(), queue, |_| {}), exchange) })
        .await
        .unwrap();
}

#[tokio::test]
async fn an_older_viewer_reconnects_for_a_new_screen_size_without_receiving_display_messages() {
    let (host_stream, viewer_stream) = tokio::io::duplex(64 * 1024);
    let (host_peer, incoming) = peer::spawn(host_stream, PeerConfig::default());
    let (_viewer, mut from_host) = peer::spawn(viewer_stream, PeerConfig::default());
    let log = HostLog {
        displays: vec![RemoteDisplayInfo::new(1, "主屏", 2560, 1440, true), RemoteDisplayInfo::new(2, "外接屏", 720, 1280, false)],
        selected: 1,
        ..HostLog::default()
    };
    let mut capture = FakeHost { log: Arc::new(Mutex::new(log)), sink: Arc::default() };
    let (commands, queue) = mpsc::unbounded_channel();
    let (notices, mut updates) = mpsc::unbounded_channel();
    let host = host::run(host_peer, incoming, &mut capture, host_options(), queue, |event| {
        let _ = notices.send(event);
    });
    let client = async {
        assert!(matches!(from_host.recv().await.unwrap(), PeerEvent::Message(message) if message.kind == MessageKind::Hello));
        commands.send(HostCommand::SelectDisplay(Some(2))).unwrap();
        while let Some(event) = from_host.recv().await {
            if let PeerEvent::Message(message) = event {
                assert_ne!(message.kind, MessageKind::DisplayControl);
            }
        }
    };
    let (reason, ()) = tokio::time::timeout(Duration::from_secs(3), async { tokio::join!(host, client) }).await.unwrap();
    assert!(reason.is_retryable());
    assert_eq!(capture.log.lock().unwrap().switched, [2]);
    assert!(std::iter::from_fn(|| updates.try_recv().ok()).any(|event| event == HostEvent::LocalDisplaySelected(Some(2))));
}

#[tokio::test]
async fn a_paused_display_switch_resumes_on_the_selected_screen_and_rolls_back_a_failed_switch() {
    run_sessions(StreamSettings::new(1920, 30, 8), None, |fixture| async move {
        until("the first stream commits", || !fixture.viewer_log.lock().unwrap().commits.is_empty()).await;
        fixture.viewer_commands.send(ViewerCommand::Pause(true)).unwrap();
        until("the viewer pauses", || fixture.has_event(&ViewerEvent::Paused { paused: true, error: None })).await;
        fixture.viewer_commands.send(ViewerCommand::SelectDisplay(2)).unwrap();
        until("the second display is selected", || {
            fixture
                .viewer_log
                .lock()
                .unwrap()
                .events
                .iter()
                .any(|event| matches!(event, ViewerEvent::Displays { selected: Some(2), pending: None, error: None, revision: 1, .. }))
        })
        .await;
        assert_eq!(fixture.stream_events().last().unwrap().1, (1080, 1920));
        assert!(fixture.host_log.lock().unwrap().paused);
        assert_eq!(fixture.viewer_log.lock().unwrap().commits.len(), 1);
        fixture.viewer_commands.send(ViewerCommand::Pause(false)).unwrap();
        until("the new screen commits its keyframe", || fixture.viewer_log.lock().unwrap().commits.len() == 2).await;
        fixture.host_log.lock().unwrap().refused_display = Some(1);
        fixture.viewer_commands.send(ViewerCommand::SelectDisplay(1)).unwrap();
        until("the failed selection reports the live screen", || {
            fixture
                .viewer_log
                .lock()
                .unwrap()
                .events
                .iter()
                .any(|event| matches!(event, ViewerEvent::Displays { selected: Some(2), pending: None, error: Some(reason), revision: 1, .. } if reason == "无法切换采集源"))
        })
        .await;
        until("the retained source resumes", || fixture.viewer_log.lock().unwrap().commits.len() == 3).await;
        assert_eq!(fixture.stream_events().last().unwrap().1, (1080, 1920));
        {
            let mut log = fixture.host_log.lock().unwrap();
            log.refused_display = None;
            log.displays.retain(|screen| screen.id != 2);
        }
        fixture.host_commands.send(HostCommand::RefreshDisplays).unwrap();
        until("removal commits the remaining screen", || fixture.viewer_log.lock().unwrap().commits.len() == 4).await;
        assert_eq!(fixture.stream_events().last().unwrap().1, (1920, 1080));
        assert_eq!(fixture.host_log.lock().unwrap().switched, [2, 1]);
        assert!(fixture.viewer_log.lock().unwrap().events.iter().any(|event| matches!(event, ViewerEvent::Displays { selected: Some(1), revision: 2, .. })));
        assert!(!fixture.host_events.lock().unwrap().iter().any(|event| matches!(event, HostEvent::LocalDisplaySelected(_))));
        fixture.viewer_commands.send(ViewerCommand::Disconnect).unwrap();
    })
    .await;
}

#[tokio::test]
async fn resume_retires_the_old_window_and_only_encodes_one_new_idr_until_commit() {
    let (_, viewer_end, _) = run_sessions(StreamSettings::new(1920, 30, 8), None, |fixture| async move {
        until("the first stream commits", || !fixture.viewer_log.lock().unwrap().commits.is_empty()).await;
        fixture.host_log.lock().unwrap().stale_frame_on_key_request = true;
        let stalled = fixture.hold_decoder() + FrameSink::WINDOW;
        until("the previous stream has no credit", || fixture.packet_count() == stalled).await;

        fixture.viewer_commands.send(ViewerCommand::Pause(true)).unwrap();
        until("pause is confirmed", || fixture.has_event(&ViewerEvent::Paused { paused: true, error: None })).await;
        fixture.viewer_commands.send(ViewerCommand::Pause(false)).unwrap();
        until("the new keyframe arrives despite the three outstanding old frames", || fixture.packet_count() == stalled + 1).await;
        assert!(fixture.viewer_log.lock().unwrap().packets[stalled].is_key_frame());
        let encoded = fixture.sink.lock().unwrap().as_ref().unwrap().produced;
        tokio::time::sleep(Duration::from_millis(80)).await;
        assert_eq!(fixture.packet_count(), stalled + 1);
        assert_eq!(fixture.sink.lock().unwrap().as_ref().unwrap().produced, encoded, "the encoder must not advance past an uncommitted keyframe");
        assert_eq!(fixture.outstanding(), 1);
        assert_eq!(fixture.viewer_log.lock().unwrap().commits.len(), 1);

        // These callbacks include old-stream decodes that finished after the host retired that stream.
        fixture.host_log.lock().unwrap().static_desktop = true;
        fixture.resume_decoder();
        until("the held keyframe commits", || fixture.viewer_log.lock().unwrap().commits.len() == 2).await;
        until("every credit is returned exactly once", || fixture.outstanding() == 0).await;
        let next = fixture.hold_decoder() + FrameSink::WINDOW;
        fixture.host_log.lock().unwrap().static_desktop = false;
        until("all three slots are available to the resumed stream", || fixture.packet_count() == next).await;
        assert_eq!(fixture.outstanding(), FrameSink::WINDOW);
        fixture.viewer_commands.send(ViewerCommand::Disconnect).unwrap();
    })
    .await;
    assert!(!viewer_end.retryable);
}

async fn next_message(messages: &mut mpsc::Receiver<PeerEvent>) -> Message {
    loop {
        match messages.recv().await.unwrap() {
            PeerEvent::Message(reply) => return reply,
            PeerEvent::RoundTrip(_) => continue,
            PeerEvent::Closed(reason) => panic!("session closed while waiting for a message: {reason}"),
        }
    }
}

#[tokio::test]
async fn a_host_binds_the_first_viewer_id_and_accepts_a_later_name_without_granting_control() {
    use quietdesk_core::messages::ControlStatus;
    for enabled in [false, true] {
        let (left, right) = tokio::io::duplex(16 * 1024);
        let (host, incoming) = peer::spawn(left, PeerConfig::default());
        let (viewer, mut replies) = peer::spawn(right, PeerConfig::default());
        let mut platform = FakeHost { log: Arc::default(), sink: Arc::default() };
        let (_commands, queue) = mpsc::unbounded_channel();
        let local_id = enabled.then(uuid::Uuid::new_v4);
        let options = HostOptions { device_id: local_id, allow_control: false, ..host_options() };
        let remote_id = uuid::Uuid::new_v4();
        let mut notices = Vec::new();
        let (events, mut observed) = mpsc::unbounded_channel();
        let exchange = async {
            let hello: Hello = next_message(&mut replies).await.read_json().unwrap();
            assert_eq!((hello.device_id, hello.device_identity_exchange), (local_id, enabled.then_some(true)));
            let announce = |id: uuid::Uuid, name: &str| {
                viewer.send(&Message::json(MessageKind::DeviceIdentity, &DeviceIdentity { id, name: name.into() }).unwrap()).unwrap()
            };
            announce(remote_id, "  首个\n设备 ");
            if enabled {
                announce(remote_id, "首个 设备");
                announce(remote_id, "已改名");
                viewer.send(&Message::empty(MessageKind::ControlStatus)).unwrap();
                let status = next_message(&mut replies).await;
                assert_eq!(status.kind, MessageKind::ControlStatus);
                assert!(!status.read_json::<ControlStatus>().unwrap().can_control);
                announce(uuid::Uuid::new_v4(), "冒名设备");
            }
        };
        let (end, ()) = tokio::time::timeout(Duration::from_secs(3), async {
            tokio::join!(
                host::run(host, incoming, &mut platform, options, queue, |notice| {
                    let _ = events.send(notice);
                }),
                exchange
            )
        })
        .await
        .unwrap();
        while let Ok(notice) = observed.try_recv() {
            if let HostEvent::ViewerIdentity(identity) = notice {
                notices.push(identity);
            }
        }
        assert!(!end.is_retryable());
        if enabled {
            assert_eq!(end.to_string(), "连接中的设备标识发生变化");
            assert_eq!(notices, [DeviceIdentity { id: remote_id, name: "首个 设备".into() }, DeviceIdentity { id: remote_id, name: "已改名".into() }]);
        } else {
            assert!(notices.is_empty());
        }
    }
}

#[tokio::test]
async fn a_viewer_exchanges_only_an_available_local_identity_and_treats_the_host_id_as_metadata() {
    let host_id = uuid::Uuid::new_v4();
    let viewer_id = uuid::Uuid::new_v4();
    for (id, exchange_id, local) in
        [(Some(host_id), None, true), (Some(host_id), Some(false), true), (None, Some(true), true), (Some(host_id), Some(true), false)]
    {
        let (left, right) = tokio::io::duplex(16 * 1024);
        let (host, mut replies) = peer::spawn(left, PeerConfig::default());
        let (viewer, incoming) = peer::spawn(right, PeerConfig::default());
        let (commands, queue) = mpsc::unbounded_channel();
        let (acknowledgements, decoded) = mpsc::unbounded_channel();
        let log = Arc::new(Mutex::new(ViewerLog::default()));
        let mut platform =
            FakeViewer { log: log.clone(), acknowledgements, identity: local.then(|| DeviceIdentity { id: viewer_id, name: "本机\r名字".into() }) };
        let quality = StreamSettings::new(1920, 30, 8);
        let exchange = async {
            let mut hello = serde_json::json!({"version":1,"name":"主机\n名字","width":1280,"height":720,"settings":quality,"canControl":false});
            if let Some(id) = id {
                hello["deviceID"] = serde_json::json!(id);
            }
            if let Some(exchange_id) = exchange_id {
                hello["deviceIdentityExchange"] = serde_json::json!(exchange_id);
            }
            host.send(&Message::json(MessageKind::Hello, &hello).unwrap()).unwrap();
            until("the remote display name and optional ID are delivered", || {
                log.lock()
                    .unwrap()
                    .events
                    .iter()
                    .any(|notice| matches!(notice,ViewerEvent::Connected{device_id,name,..} if *device_id==id && name=="主机 名字"))
            })
            .await;
            commands.send(ViewerCommand::ReleaseInput).unwrap();
            if exchange_id == Some(true) && local {
                let identity = next_message(&mut replies).await;
                assert_eq!(identity.kind, MessageKind::DeviceIdentity);
                assert_eq!(identity.read_json::<DeviceIdentity>().unwrap(), DeviceIdentity { id: viewer_id, name: "本机 名字".into() });
            }
            assert_eq!(next_message(&mut replies).await.kind, MessageKind::ReleaseInput);
            // Only viewers send message 21; even a correctly encoded identity from this host is invalid.
            host.send(&Message::json(MessageKind::DeviceIdentity, &DeviceIdentity { id: host_id, name: "主机".into() }).unwrap()).unwrap();
        };
        let (end, ()) = tokio::time::timeout(Duration::from_secs(3), async {
            tokio::join!(viewer::run(viewer, incoming, &mut platform, quality, queue, decoded), exchange)
        })
        .await
        .unwrap();
        assert!(!end.retryable && !end.host_ended && !end.local_stop);
    }
}

#[tokio::test]
async fn a_prepare_before_the_first_settings_keeps_its_transaction_until_capture_starts() {
    let (host_stream, viewer_stream) = tokio::io::duplex(64 * 1024);
    let (host, incoming) = peer::spawn(host_stream, PeerConfig::default());
    let (viewer, mut messages) = peer::spawn(viewer_stream, PeerConfig::default());
    let log = Arc::new(Mutex::new(HostLog::default()));
    let mut platform = FakeHost { log: log.clone(), sink: Arc::new(Mutex::new(None)) };
    let (commands, command_queue) = mpsc::unbounded_channel();
    let ask = async {
        assert_eq!(next_message(&mut messages).await.kind, MessageKind::Hello);
        viewer.send(&ViewerMedia::request().message().unwrap()).unwrap();
        let offer = MediaControl::read(&next_message(&mut messages).await).unwrap();
        let events = ViewerMedia::default().control(&offer, tokio::time::Instant::now()).unwrap();
        let [ViewerMediaEvent::Send(prepare)] = &events[..] else { panic!("missing prepare") };
        viewer.send(prepare).unwrap();

        // This viewer leaves initial settings to the host. Readiness must wait for its capture pipeline.
        let ready = MediaControl::read(&next_message(&mut messages).await).unwrap();
        assert_eq!(ready.operation, MediaOperation::Ready);
        assert_eq!(ready.transaction_id, MediaControl::read(prepare).unwrap().transaction_id);
        assert_eq!(log.lock().unwrap().configured, [host_options().preferred]);
        commands.send(HostCommand::End).unwrap();
    };
    tokio::time::timeout(Duration::from_secs(3), async { tokio::join!(host::run(host, incoming, &mut platform, host_options(), command_queue, |_| {}), ask) })
        .await
        .expect("capture must finish the pending prepare");
}

#[tokio::test]
async fn an_old_host_gets_legacy_acknowledgements_and_cannot_send_unnegotiated_media() {
    for capability in [None, Some(false)] {
        let (host_stream, viewer_stream) = tokio::io::duplex(64 * 1024);
        let (host, mut messages) = peer::spawn(host_stream, PeerConfig::default());
        let (viewer, incoming) = peer::spawn(viewer_stream, PeerConfig::default());
        let log = Arc::new(Mutex::new(ViewerLog::default()));
        let (acknowledgements, decoded) = mpsc::unbounded_channel();
        let (commands, command_queue) = mpsc::unbounded_channel();
        let mut platform = FakeViewer { log: log.clone(), acknowledgements, identity: None };
        let settings = StreamSettings::new(1920, 30, 8);
        let packet = VideoPacket::h264(19, key_frame());
        let old_host = async {
            let mut hello = serde_json::json!({"version":1, "name":"Old host", "width":1920, "height":1080, "settings":settings, "canControl":false});
            hello["displays"] = serde_json::json!([RemoteDisplayInfo::new(1, "主屏", 1920, 1080, true), RemoteDisplayInfo::new(2, "外接屏", 1280, 720, false)]);
            if let Some(value) = capability {
                hello["mediaTransportV1"] = serde_json::json!(value);
                hello["displaySwitchingV1"] = serde_json::json!(value);
            }
            host.send(&Message::json(MessageKind::Hello, &hello).unwrap()).unwrap();
            host.send(&Message::new(MessageKind::Video, packet.encode().unwrap())).unwrap();
            let reply = next_message(&mut messages).await;
            assert_eq!(reply, Message::new(MessageKind::Acknowledgement, packet.sequence.to_be_bytes().to_vec()));
            commands.send(ViewerCommand::SelectDisplay(2)).unwrap();
            until("a local selection learns that display switching is unavailable", || {
                log.lock().unwrap().events.iter().any(|event| matches!(event, ViewerEvent::Displays { selected: None, pending: None, error: Some(_), .. }))
            })
            .await;
            commands.send(ViewerCommand::ReleaseInput).unwrap();
            assert_eq!(next_message(&mut messages).await.kind, MessageKind::ReleaseInput);
            let stream = MediaStreamId { session_id: uuid::Uuid::new_v4(), transport_epoch: 1, codec_epoch: 1 };
            host.send(&MediaFrame::new(stream, 1, packet.clone()).unwrap().message().unwrap()).unwrap();
        };
        let (end, ()) = tokio::time::timeout(Duration::from_secs(3), async {
            tokio::join!(viewer::run(viewer, incoming, &mut platform, settings, command_queue, decoded), old_host)
        })
        .await
        .expect("unnegotiated media should close the session");
        assert!(!end.retryable && !end.host_ended);
        let log = log.lock().unwrap();
        assert_eq!(log.packets, [packet]);
        assert!(log.commits.is_empty());
    }
}

#[tokio::test(start_paused = true)]
async fn an_unanswered_sound_request_releases_capture_and_a_late_status_cannot_start_playback() {
    let (left, right) = tokio::io::duplex(8192);
    let (host, mut messages) = peer::spawn(left, PeerConfig::default());
    let (viewer, incoming) = peer::spawn(right, PeerConfig::default());
    let (commands, queue) = mpsc::unbounded_channel();
    let (acknowledgements, decoded) = mpsc::unbounded_channel();
    let log = Arc::new(Mutex::new(ViewerLog { supports_sound: true, ..Default::default() }));
    let mut platform = FakeViewer { log: log.clone(), acknowledgements, identity: None };
    let settings = StreamSettings::new(1920, 30, 8);
    let exchange = async {
        let hello = serde_json::json!({"version":1,"name":"test","width":640,"height":360,"settings":settings,"canControl":false,"remoteAudioV1":true});
        host.send(&Message::json(MessageKind::Hello, &hello).unwrap()).unwrap();
        until("the viewer can ask for sound", || log.lock().unwrap().events.iter().any(|e| matches!(e, ViewerEvent::Connected { remote_audio: true, .. })))
            .await;
        commands.send(ViewerCommand::RemoteAudio(true)).unwrap();
        commands.send(ViewerCommand::RemoteAudio(true)).unwrap();
        commands.send(ViewerCommand::ReleaseInput).unwrap();
        let AudioControl::Request { request_id, enabled: true, .. } = AudioControl::read(&next_message(&mut messages).await).unwrap() else {
            panic!("missing enable request")
        };
        assert_eq!(next_message(&mut messages).await.kind, MessageKind::ReleaseInput);
        tokio::time::advance(Duration::from_secs(16)).await;
        let release = AudioControl::read(&next_message(&mut messages).await).unwrap();
        assert!(matches!(release, AudioControl::Request { enabled: false, .. }));
        assert!(
            log.lock()
                .unwrap()
                .events
                .iter()
                .any(|e| matches!(e, ViewerEvent::Audio { enabled:false, pending:false, error:Some(error) } if error.contains("超时")))
        );
        let status = |id, epoch| {
            AudioControl::Status { request_id: Some(id), state: AudioState::Enabled { epoch, magic_cookie: None, redundant_opus: true } }.message().unwrap()
        };
        host.send(&status(request_id, 1.try_into().unwrap())).unwrap();
        host.send(&Message::new(MessageKind::Video, VideoPacket::h264(9, key_frame()).encode().unwrap())).unwrap();
        assert_eq!(next_message(&mut messages).await.kind, MessageKind::Acknowledgement);
        assert!(log.lock().unwrap().audio_output.is_none());
        commands.send(ViewerCommand::RemoteAudio(true)).unwrap();
        let AudioControl::Request { request_id: retry_id, enabled: true, .. } = AudioControl::read(&next_message(&mut messages).await).unwrap() else {
            panic!("missing retry")
        };
        assert_ne!(retry_id, request_id);
        host.send(&status(retry_id, 2.try_into().unwrap())).unwrap();
        until("the new epoch opens the local audio worker", || log.lock().unwrap().audio_output.is_some()).await;
        let playing = ViewerEvent::Audio { enabled: true, pending: false, error: None };
        let worker = log.lock().unwrap().audio_output.take().unwrap();
        assert!(!log.lock().unwrap().events.contains(&playing));
        worker.events.send(PlaybackEvent::Ready).await.unwrap();
        until("sound is active after the worker confirms it", || log.lock().unwrap().events.contains(&playing)).await;
        commands.send(ViewerCommand::Disconnect).unwrap();
    };
    let (end, ()) =
        tokio::time::timeout(Duration::from_secs(20), async { tokio::join!(viewer::run(viewer, incoming, &mut platform, settings, queue, decoded), exchange) })
            .await
            .unwrap();
    assert!(end.local_stop);
}

#[tokio::test]
async fn audio_encoded_before_a_pause_cannot_escape_after_the_same_epoch_resumes() {
    use quietdesk_core::messages::{SessionPauseRequest, SessionPauseResult};
    let (left, right) = tokio::io::duplex(8192);
    let (host, incoming) = peer::spawn(left, PeerConfig::default());
    let (viewer, mut messages) = peer::spawn(right, PeerConfig::default());
    let log = Arc::new(Mutex::new(HostLog { supports_sound: true, ..Default::default() }));
    let mut platform = FakeHost { log: log.clone(), sink: Arc::default() };
    let (commands, queue) = mpsc::unbounded_channel();
    let exchange = async {
        let hello: Hello = next_message(&mut messages).await.read_json().unwrap();
        assert_eq!(hello.remote_audio_v1, Some(true));
        let request_id = uuid::Uuid::new_v4();
        viewer.send(&AudioControl::Request { request_id, enabled: true, redundant_opus: false }.message().unwrap()).unwrap();
        until("the host creates its capture worker", || log.lock().unwrap().audio_input.is_some()).await;
        let (epoch, worker) = log.lock().unwrap().audio_input.take().unwrap();
        let original = worker.paused.borrow().revision;
        worker.events.send(CaptureEvent::Ready).await.unwrap();
        let status = AudioControl::read(&next_message(&mut messages).await).unwrap();
        assert!(matches!(status,AudioControl::Status{request_id:Some(id),state:AudioState::Enabled{epoch:current,..}} if id==request_id && current==epoch));
        let mut encoder = AudioEncoder::new(epoch, false).unwrap();
        let pcm = [0.0; INTERLEAVED_SAMPLES];
        let old_packet = encoder.encode(&pcm).unwrap();
        for paused in [true, false] {
            let request = SessionPauseRequest { id: uuid::Uuid::new_v4(), paused };
            viewer.send(&Message::json(MessageKind::SessionPauseRequest, &request).unwrap()).unwrap();
            let result: SessionPauseResult = next_message(&mut messages).await.read_json().unwrap();
            assert_eq!((result.id, result.paused, result.error), (request.id, paused, None));
        }
        let resumed = *worker.paused.borrow();
        assert!(!resumed.paused && resumed.revision > original);
        worker.events.send(CaptureEvent::Packet(old_packet, original)).await.unwrap();
        encoder.reset_after_pause().unwrap();
        let current = encoder.encode(&pcm).unwrap();
        let expected_sequence = current.sequence();
        worker.events.send(CaptureEvent::Packet(current, resumed.revision)).await.unwrap();
        let frame = next_message(&mut messages).await;
        assert_eq!(frame.kind, MessageKind::AudioFrame);
        assert_eq!(AudioPacket::read(&frame.payload).unwrap().sequence(), expected_sequence);
        commands.send(HostCommand::End).unwrap();
    };
    tokio::time::timeout(Duration::from_secs(3), async { tokio::join!(host::run(host, incoming, &mut platform, host_options(), queue, |_| {}), exchange) })
        .await
        .unwrap();
}
