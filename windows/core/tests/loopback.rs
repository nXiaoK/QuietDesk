//! A host session and a viewer session of this crate talking over an in-memory connection, with
//! stand-ins for capture, decoding, input and the clipboard.

use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::host::{self, FrameSink, HostCommand, HostEvent, HostOptions, HostPlatform};
use quietdesk_core::input::InjectOp;
use quietdesk_core::keymap::MacModifierMapping;
use quietdesk_core::messages::{InputKind, RemoteInput, StreamSettings, VideoStreamState};
use quietdesk_core::peer::{self, PeerConfig};
use quietdesk_core::video::{EncodedFrame, VideoPacket};
use quietdesk_core::viewer::{self, ViewerCommand, ViewerEnd, ViewerEvent, ViewerPlatform};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

#[derive(Default)]
struct HostLog {
    configured: Vec<StreamSettings>,
    injected: Vec<InjectOp>,
    clipboard: Option<String>,
    paused: bool,
    stopped: bool,
    refuse: Option<StreamSettings>,
}

struct FakeHost {
    log: Arc<Mutex<HostLog>>,
    sink: Arc<Mutex<Option<(FrameSink, bool)>>>,
}

impl HostPlatform for FakeHost {
    fn display_size(&mut self) -> Result<(u32, u32)> {
        Ok((2560, 1440))
    }

    async fn configure(&mut self, settings: StreamSettings, frames: FrameSink) -> Result<VideoStreamState> {
        *self.sink.lock().unwrap() = None;
        if self.log.lock().unwrap().refuse == Some(settings) {
            return Err(DeskError::platform("编码器不支持该尺寸"));
        }
        self.log.lock().unwrap().configured.push(settings);
        *self.sink.lock().unwrap() = Some((frames, true));
        let (width, height) = settings.dimensions(2560, 1440);
        Ok(VideoStreamState { settings, width: i64::from(width), height: i64::from(height) })
    }

    async fn set_paused(&mut self, paused: bool) -> Result<()> {
        self.log.lock().unwrap().paused = paused;
        if let Some((_, key)) = self.sink.lock().unwrap().as_mut() {
            *key = true;
        }
        Ok(())
    }

    fn inject(&mut self, operations: &[InjectOp]) {
        self.log.lock().unwrap().injected.extend_from_slice(operations);
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
async fn produce_frames(sink: Arc<Mutex<Option<(FrameSink, bool)>>>, log: Arc<Mutex<HostLog>>) {
    loop {
        tokio::time::sleep(Duration::from_millis(1)).await;
        let mut slot = sink.lock().unwrap();
        let paused = log.lock().unwrap().paused;
        let Some((frames, key)) = slot.as_mut() else { continue };
        if paused || !frames.has_credit() {
            continue;
        }
        let frame = if *key {
            EncodedFrame { sps: vec![0x67, 1], pps: vec![0x68, 2], avcc: vec![0, 0, 0, 2, 0x65, 3] }
        } else {
            EncodedFrame { sps: vec![], pps: vec![], avcc: vec![0, 0, 0, 2, 0x41, 4] }
        };
        *key = false;
        frames.submit(frame);
    }
}

#[derive(Default)]
struct ViewerLog {
    events: Vec<ViewerEvent>,
    packets: Vec<VideoPacket>,
}

struct FakeViewer {
    log: Arc<Mutex<ViewerLog>>,
    acknowledgements: mpsc::UnboundedSender<u32>,
    acknowledge: Arc<Mutex<bool>>,
}

impl ViewerPlatform for FakeViewer {
    fn video(&mut self, packet: VideoPacket) {
        if *self.acknowledge.lock().unwrap() {
            let _ = self.acknowledgements.send(packet.sequence);
        }
        self.log.lock().unwrap().packets.push(packet);
    }

    fn event(&mut self, event: ViewerEvent) {
        self.log.lock().unwrap().events.push(event);
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
    acknowledge: Arc<Mutex<bool>>,
    acknowledgements: mpsc::UnboundedSender<u32>,
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
    let host_log = Arc::new(Mutex::new(HostLog { clipboard: Some("来自被控端".to_string()), refuse, ..HostLog::default() }));
    let sink = Arc::new(Mutex::new(None));
    let mut host_platform = FakeHost { log: host_log.clone(), sink: sink.clone() };
    let viewer_log = Arc::new(Mutex::new(ViewerLog::default()));
    let acknowledge = Arc::new(Mutex::new(true));
    let (acknowledgements, acknowledged) = mpsc::unbounded_channel();
    let mut viewer_platform = FakeViewer { log: viewer_log.clone(), acknowledgements: acknowledgements.clone(), acknowledge: acknowledge.clone() };
    let (host_commands, host_command_queue) = mpsc::unbounded_channel();
    let (viewer_commands, viewer_command_queue) = mpsc::unbounded_channel();
    let host_events = Arc::new(Mutex::new(Vec::new()));
    let fixture = Arc::new(Fixture {
        host_log: host_log.clone(),
        viewer_log,
        host_events: host_events.clone(),
        acknowledge,
        acknowledgements,
        host_commands,
        viewer_commands,
    });
    let options = HostOptions {
        name: "检查用电脑".to_string(),
        allow_control: true,
        clipboard: true,
        preferred: StreamSettings::new(1920, 30, 8),
        limit: StreamSettings::new(2560, 60, 30),
        modifiers: MacModifierMapping::Standard,
    };
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

#[tokio::test]
async fn a_session_negotiates_streams_controls_and_ends_as_the_macos_roles_do() {
    let quality = StreamSettings::new(1920, 60, 20);
    let (host_end, viewer_end, fixture) = run_sessions(quality, None, |fixture| async move {
        // The viewer's first request arrives inside the host's grace period, so the stream starts once, as asked.
        until("the first frame arrives", || fixture.packet_count() >= 1).await;
        assert_eq!(fixture.host_log.lock().unwrap().configured, [quality]);
        assert_eq!(fixture.stream_events(), [(quality, (1920, 1080), None)]);
        {
            let log = fixture.viewer_log.lock().unwrap();
            let hello_stream = VideoStreamState { settings: StreamSettings::new(1920, 30, 8), width: 1920, height: 1080 };
            assert_eq!(log.events[0], ViewerEvent::Connected { name: "检查用电脑".to_string(), can_control: true, stream: hello_stream, live_settings: true });
            assert!(log.events.contains(&ViewerEvent::Control(true)), "the viewer subscribed to control changes");
            assert!(log.packets[0].is_key_frame() && log.packets[0].sequence == 1);
        }
        until("frames keep coming while acknowledged", || fixture.packet_count() >= 10).await;
        assert!(fixture.viewer_log.lock().unwrap().packets[1..10].iter().all(|packet| !packet.is_key_frame()));

        // Without acknowledgements the host stops three frames after the last one it heard about.
        *fixture.acknowledge.lock().unwrap() = false;
        tokio::time::sleep(Duration::from_millis(60)).await;
        let stalled = fixture.packet_count();
        tokio::time::sleep(Duration::from_millis(60)).await;
        assert_eq!(fixture.packet_count(), stalled);
        let unacknowledged: Vec<u32> = fixture.viewer_log.lock().unwrap().packets[stalled - FrameSink::WINDOW..].iter().map(|packet| packet.sequence).collect();
        *fixture.acknowledge.lock().unwrap() = true;
        for sequence in unacknowledged {
            fixture.acknowledgements.send(sequence).unwrap();
        }
        until("frames resume once acknowledged", || fixture.packet_count() > stalled + 3).await;

        // A request above the host's limit is lowered to it, and the viewer learns what it got.
        fixture.viewer_commands.send(ViewerCommand::Quality(StreamSettings::new(8192, 60, 100))).unwrap();
        let limit = StreamSettings::new(2560, 60, 30);
        until("the lowered quality is confirmed", || fixture.stream_events().len() == 2).await;
        assert_eq!(fixture.stream_events()[1], (limit, (2560, 1440), None));
        let restart = fixture.packet_count();
        until("the restarted stream delivers", || fixture.packet_count() > restart + 3).await;
        {
            let log = fixture.viewer_log.lock().unwrap();
            let first_new = log.packets.iter().rposition(|packet| packet.is_key_frame()).unwrap();
            assert!(first_new >= restart.saturating_sub(3), "the new stream begins with a keyframe");
        }

        // Input reaches the host as key and pointer operations; a pause releases what is held.
        let mut key = RemoteInput::new(InputKind::KeyDown);
        key.key_code = 0x08;
        fixture.viewer_commands.send(ViewerCommand::Input(key)).unwrap();
        until("the key is injected", || fixture.host_log.lock().unwrap().injected.iter().any(|op| matches!(op, InjectOp::Key { down: true, .. }))).await;
        fixture.viewer_commands.send(ViewerCommand::Pause(true)).unwrap();
        until("the pause is confirmed", || fixture.has_event(&ViewerEvent::Paused { paused: true, error: None })).await;
        assert!(fixture.host_log.lock().unwrap().injected.iter().any(|op| matches!(op, InjectOp::Key { down: false, .. })));
        assert!(fixture.host_events.lock().unwrap().contains(&HostEvent::Paused(true)));
        tokio::time::sleep(Duration::from_millis(30)).await;
        let paused_at = fixture.packet_count();
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert_eq!(fixture.packet_count(), paused_at);
        fixture.viewer_commands.send(ViewerCommand::Pause(false)).unwrap();
        until("frames resume after the pause", || fixture.packet_count() > paused_at).await;
        assert!(fixture.viewer_log.lock().unwrap().packets[paused_at].is_key_frame(), "a resumed stream starts from a keyframe");

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
