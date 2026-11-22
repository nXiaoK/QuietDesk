//! A host session and a viewer session of this crate talking over an in-memory connection, with
//! stand-ins for capture, decoding, input and the clipboard.

use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::host::{self, FrameSink, HostCommand, HostEvent, HostOptions, HostPlatform};
use quietdesk_core::input::InjectOp;
use quietdesk_core::keymap::MacModifierMapping;
use quietdesk_core::media::{DecodeReceipt, MediaControl, MediaFrame, MediaOperation, MediaStreamId, ViewerMedia, ViewerMediaEvent};
use quietdesk_core::messages::{InputKind, RemoteInput, StreamSettings, VideoStreamState};
use quietdesk_core::peer::{self, PeerConfig, PeerEvent};
use quietdesk_core::video::{EncodedFrame, VideoPacket};
use quietdesk_core::viewer::{self, ViewerCommand, ViewerEnd, ViewerEvent, ViewerPlatform};
use quietdesk_core::wire::{Message, MessageKind};
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
    static_desktop: bool,
    stale_frame_on_key_request: bool,
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
    fn display_size(&mut self) -> Result<(u32, u32)> {
        Ok((2560, 1440))
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
        let (width, height) = settings.dimensions(2560, 1440);
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
    events: Vec<ViewerEvent>,
    packets: Vec<VideoPacket>,
    /// Packet index of the decoded keyframe at each commit.
    commits: Vec<(MediaStreamId, usize)>,
    held_receipts: Option<Vec<DecodeReceipt>>,
}

struct FakeViewer {
    log: Arc<Mutex<ViewerLog>>,
    acknowledgements: mpsc::UnboundedSender<DecodeReceipt>,
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
    let host_log = Arc::new(Mutex::new(HostLog { clipboard: Some("来自被控端".to_string()), refuse, ..HostLog::default() }));
    let sink = Arc::new(Mutex::new(None));
    let mut host_platform = FakeHost { log: host_log.clone(), sink: sink.clone() };
    let viewer_log = Arc::new(Mutex::new(ViewerLog::default()));
    let (acknowledgements, acknowledged) = mpsc::unbounded_channel();
    let mut viewer_platform = FakeViewer { log: viewer_log.clone(), acknowledgements: acknowledgements.clone() };
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
        allow_control: true,
        clipboard: true,
        preferred: StreamSettings::new(1920, 30, 8),
        limit: StreamSettings::new(2560, 60, 30),
        modifiers: MacModifierMapping::Standard,
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
            assert_eq!(log.events[0], ViewerEvent::Connected { name: "检查用电脑".to_string(), can_control: true, stream: hello_stream, live_settings: true });
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
        let (_commands, command_queue) = mpsc::unbounded_channel();
        let mut platform = FakeViewer { log: log.clone(), acknowledgements };
        let settings = StreamSettings::new(1920, 30, 8);
        let packet = VideoPacket::h264(19, key_frame());
        let old_host = async {
            let mut hello = serde_json::json!({"version":1, "name":"Old host", "width":1920, "height":1080, "settings":settings, "canControl":false});
            if let Some(value) = capability {
                hello["mediaTransportV1"] = serde_json::json!(value);
            }
            host.send(&Message::json(MessageKind::Hello, &hello).unwrap()).unwrap();
            host.send(&Message::new(MessageKind::Video, packet.encode().unwrap())).unwrap();
            let reply = next_message(&mut messages).await;
            assert_eq!(reply, Message::new(MessageKind::Acknowledgement, packet.sequence.to_be_bytes().to_vec()));
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
