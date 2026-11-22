//! A headless host and viewer built from `quietdesk-core`, driven over standard input and output.
//!
//! The interoperability checks run it against the macOS implementation: the host role replays a recorded
//! H.264 stream where the Windows application would capture and encode, the viewer role reports what it
//! receives where the application would decode and draw. Everything in between is the code that ships.

mod clipboard;

use clipboard::SyntheticClipboard;
use quietdesk_core::clipboard::Role;
use quietdesk_core::clipboard_session::SessionClipboard;
use quietdesk_core::cursor::CursorImage;
use quietdesk_core::display::{DisplaySwitch, HostDisplays, RemoteDisplayInfo};
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::host::{self, FrameSink, HostCommand, HostCursorSample, HostEvent, HostOptions, HostPlatform, InputActionOutcome};
use quietdesk_core::input::{CapsLockPress, DoubleClick, InjectOp, PcKeyEvent, ViewerInputTranslator};
use quietdesk_core::keymap::{MacModifierMapping, PcModifierMapping};
use quietdesk_core::media::{DecodeReceipt, MediaStreamId};
use quietdesk_core::messages::{DeviceIdentity, InputAction, InputFeedback, MomentumPhase, ScrollPhase, StreamSettings, TrackpadGesture, VideoStreamState};
use quietdesk_core::pairing::PairingKey;
use quietdesk_core::peer::{self, PeerConfig};
use quietdesk_core::reliability::{self, RetryStatus};
use quietdesk_core::tls;
use quietdesk_core::video::{EncodedFrame, H264FrameAssembler, VideoPacket};
use quietdesk_core::viewer::{ViewerCommand, ViewerEvent, ViewerPlatform};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::{mpsc, watch};
use uuid::Uuid;

fn emit(event: Value) {
    let mut output = std::io::stdout().lock();
    let _ = writeln!(output, "{event}");
    let _ = output.flush();
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Lines of standard input as JSON values; the channel closes when the input does.
fn input_lines() -> mpsc::UnboundedReceiver<Value> {
    let (sender, receiver) = mpsc::unbounded_channel();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines().map_while(std::result::Result::ok) {
            match serde_json::from_str(&line) {
                Ok(value) => {
                    if sender.send(value).is_err() {
                        break;
                    }
                }
                Err(error) => emit(json!({ "event": "invalidCommand", "error": error.to_string() })),
            }
        }
    });
    receiver
}

fn settings_json(settings: StreamSettings) -> Value {
    json!({ "longestEdge": settings.longest_edge, "framesPerSecond": settings.frames_per_second, "megabits": settings.megabits })
}

fn stream_json(stream: VideoStreamState) -> Value {
    json!({ "settings": settings_json(stream.settings), "width": stream.width, "height": stream.height })
}

fn device_id(arguments: &HashMap<String, String>) -> Result<Option<Uuid>> {
    arguments.get("device-id").map(|value| value.parse().map_err(|_| DeskError::invalid("--device-id 应为 UUID"))).transpose()
}

fn parse_settings(text: &str) -> Result<StreamSettings> {
    let values: Vec<i64> = text.split(',').filter_map(|value| value.parse().ok()).collect();
    match values[..] {
        [edge, rate, megabits] => Ok(StreamSettings::new(edge, rate, megabits)),
        _ => Err(DeskError::invalid("画质参数应为 longestEdge,framesPerSecond,megabits")),
    }
}

struct Replay {
    sink: Option<FrameSink>,
    next: usize,
    paused: bool,
    display_id: u32,
    external_attached: bool,
    reject_next_switch: bool,
    refuse_layout: bool,
}

const EXTERNAL_SIZE: (u32, u32) = (320, 240);

/// Stands in for capture and encoding: replays recorded encoder output from its first keyframe.
struct ReplayHost {
    size: (u32, u32),
    replay: Arc<Mutex<Replay>>,
    clipboard: Option<String>,
    synthetic_clipboard: Option<SyntheticClipboard>,
    refuse_edge: Option<i64>,
    synthetic_cursor: bool,
    cursor_samples: Option<watch::Sender<Option<HostCursorSample>>>,
    synthetic_displays: bool,
    synthetic_keyboard: bool,
    synthetic_relative_mouse: bool,
    synthetic_trackpad: bool,
    caps_locked: bool,
    alternate_layout: bool,
}

impl HostPlatform for ReplayHost {
    fn open_clipboard(&mut self, enabled: bool) -> Option<SessionClipboard> {
        self.synthetic_clipboard.as_ref()?.open(Role::Host, enabled)
    }

    fn display_size(&mut self) -> Result<(u32, u32)> {
        Ok(if self.replay.lock().unwrap().display_id == 2 { EXTERNAL_SIZE } else { self.size })
    }

    fn displays(&mut self) -> Result<Option<HostDisplays>> {
        if !self.synthetic_displays {
            return Ok(None);
        }
        let replay = self.replay.lock().unwrap();
        let mut displays = vec![RemoteDisplayInfo::new(1, "Synthetic primary", self.size.0, self.size.1, true)];
        if replay.external_attached {
            displays.push(RemoteDisplayInfo::new(2, "Synthetic external", EXTERNAL_SIZE.0, EXTERNAL_SIZE.1, false));
        }
        let needs_restart = replay.display_id == 2 && !replay.external_attached;
        Ok(Some(HostDisplays { displays, selected_display_id: if needs_restart { 1 } else { replay.display_id }, needs_restart }))
    }

    async fn switch_display(&mut self, id: u32, settings: StreamSettings, frames: FrameSink) -> Result<DisplaySwitch> {
        emit(json!({ "event": "switchCapture", "display": id }));
        let mut replay = self.replay.lock().unwrap();
        if std::mem::take(&mut replay.reject_next_switch) {
            return Ok(DisplaySwitch::Retained("Synthetic display is busy".into()));
        }
        let size = match id {
            1 => self.size,
            2 if replay.external_attached => EXTERNAL_SIZE,
            _ => return Ok(DisplaySwitch::Retained("Synthetic display is unavailable".into())),
        };
        replay.display_id = id;
        replay.sink = Some(frames);
        replay.next = 0;
        let (width, height) = settings.dimensions(size.0, size.1);
        Ok(DisplaySwitch::Applied(VideoStreamState { settings, width: i64::from(width), height: i64::from(height) }))
    }

    async fn configure(&mut self, settings: StreamSettings, frames: FrameSink) -> Result<VideoStreamState> {
        self.replay.lock().unwrap().sink = None;
        if self.refuse_edge == Some(settings.longest_edge) {
            return Err(DeskError::platform("编码器不支持该尺寸"));
        }
        let size = self.display_size()?;
        let (width, height) = settings.dimensions(size.0, size.1);
        let stream = VideoStreamState { settings, width: i64::from(width), height: i64::from(height) };
        let mut replay = self.replay.lock().unwrap();
        replay.sink = Some(frames);
        replay.next = 0;
        replay.paused = false;
        emit(json!({ "event": "configured", "stream": stream_json(stream) }));
        Ok(stream)
    }

    async fn set_paused(&mut self, paused: bool) -> Result<()> {
        let mut replay = self.replay.lock().unwrap();
        replay.paused = paused;
        replay.next = 0;
        emit(json!({ "event": "paused", "paused": paused }));
        Ok(())
    }

    async fn request_key_frame(&mut self) -> Result<()> {
        self.replay.lock().unwrap().next = 0;
        Ok(())
    }

    fn supports_independent_cursor(&self) -> bool {
        self.synthetic_cursor
    }

    async fn configure_cursor(&mut self, samples: Option<watch::Sender<Option<HostCursorSample>>>) -> Result<()> {
        if let Some(sender) = &samples {
            let pixels = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 0, 255];
            let image = CursorImage::from_rgba(3, 2, 1.5, 1.0, 0.5, 0.25, &pixels)?;
            sender.send_replace(Some(HostCursorSample { image: Some(Arc::new(image)), inside_display: true, x: 0.25, y: 0.75 }));
        }
        self.cursor_samples = samples;
        Ok(())
    }

    fn supports_input_actions(&self) -> bool {
        self.synthetic_keyboard
    }

    fn supports_relative_mouse(&self) -> bool {
        self.synthetic_relative_mouse
    }

    fn supports_trackpad_gestures(&self) -> bool {
        self.synthetic_trackpad
    }

    fn input_action(&mut self, action: InputAction) -> impl Future<Output = Result<InputActionOutcome>> + Send + 'static {
        if action == InputAction::SwitchInputSource && !self.caps_locked && self.replay.lock().unwrap().refuse_layout {
            return std::future::ready(Ok(InputActionOutcome::Unconfirmed(InputFeedback {
                message: "Synthetic layout change unconfirmed".into(),
                caps_locked: false,
            })));
        }
        let message = match action {
            InputAction::SwitchInputSource if !self.caps_locked => {
                self.alternate_layout = !self.alternate_layout;
                if self.alternate_layout { "Synthetic layout B" } else { "Synthetic layout A" }
            }
            _ => {
                self.caps_locked = !self.caps_locked;
                if self.caps_locked { "Synthetic Caps Lock on" } else { "Synthetic Caps Lock off" }
            }
        };
        std::future::ready(Ok(InputActionOutcome::Confirmed(InputFeedback { message: message.into(), caps_locked: self.caps_locked })))
    }

    fn inject(&mut self, operations: &[InjectOp]) -> bool {
        for operation in operations {
            if let InjectOp::CapsLock(value) = operation {
                self.caps_locked = *value;
            }
        }
        if !operations.is_empty() {
            let operations: Vec<String> = operations.iter().map(|operation| format!("{operation:?}")).collect();
            emit(json!({ "event": "inject", "operations": operations }));
        }
        true
    }

    fn clipboard_text(&mut self) -> Option<String> {
        self.clipboard.clone()
    }

    fn set_clipboard_text(&mut self, text: &str) -> Result<()> {
        self.clipboard = Some(text.to_string());
        emit(json!({ "event": "clipboard", "text": text }));
        Ok(())
    }

    fn stop(&mut self) {
        self.replay.lock().unwrap().sink = None;
    }
}

/// Reads access units stored as a big-endian length followed by an Annex B byte stream.
fn read_recording(path: &str) -> Result<Vec<EncodedFrame>> {
    let data = std::fs::read(path).map_err(|error| DeskError::platform(format!("无法读取录制的视频流：{error}")))?;
    let mut assembler = H264FrameAssembler::default();
    let mut frames = Vec::new();
    let mut rest = &data[..];
    while let Some((length, tail)) = rest.split_first_chunk::<4>() {
        let length = u32::from_be_bytes(*length) as usize;
        let unit = tail.get(..length).ok_or_else(|| DeskError::platform("录制的视频流被截断"))?;
        frames.extend(assembler.assemble(unit)?);
        rest = &tail[length..];
    }
    if !frames.first().is_some_and(EncodedFrame::is_key_frame) {
        return Err(DeskError::platform("录制的视频流应以关键帧开始"));
    }
    Ok(frames)
}

async fn run_host(arguments: &HashMap<String, String>) -> Result<()> {
    let required = |name: &str| arguments.get(name).ok_or_else(|| DeskError::invalid(format!("缺少参数 --{name}")));
    let key = PairingKey::parse(required("code")?)?;
    let frames = read_recording(required("recording")?)?;
    let external = arguments.get("second-recording").map(|path| read_recording(path)).transpose()?;
    let synthetic_displays = external.is_some();
    let size: Vec<u32> = required("size")?.split('x').filter_map(|value| value.parse().ok()).collect();
    let [width, height] = size[..] else { return Err(DeskError::invalid("--size 应为 宽x高")) };
    let options = HostOptions {
        name: arguments.get("name").cloned().unwrap_or_else(|| "QuietDesk Probe".to_string()),
        device_id: device_id(arguments)?,
        allow_control: true,
        clipboard: true,
        preferred_display: None,
        preferred: parse_settings(arguments.get("preferred").map_or("1920,30,8", String::as_str))?,
        limit: parse_settings(arguments.get("limit").map_or("2560,60,30", String::as_str))?,
        modifiers: if arguments.contains_key("standard-modifiers") { MacModifierMapping::Standard } else { MacModifierMapping::CommandAsControl },
    };
    let refuse_edge = arguments.get("refuse-edge").and_then(|value| value.parse().ok());
    let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
    emit(json!({ "event": "listening", "port": listener.local_addr()?.port() }));
    let acceptor = tls::Acceptor::new(&key)?;
    let mut lines = input_lines();

    let replay = Arc::new(Mutex::new(Replay {
        sink: None,
        next: 0,
        paused: false,
        display_id: 1,
        external_attached: synthetic_displays,
        reject_next_switch: false,
        refuse_layout: false,
    }));
    let producer = replay.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_millis(4)).await;
            let mut replay = producer.lock().unwrap();
            let Some(sink) = replay.sink.clone().filter(|sink| !replay.paused && sink.has_credit()) else { continue };
            let frames = if replay.display_id == 2 { external.as_ref().expect("the selected display has a recording") } else { &frames };
            if sink.submit(frames[replay.next].clone()) {
                replay.next = (replay.next + 1) % frames.len();
            }
        }
    });

    loop {
        let (tcp, _) = listener.accept().await?;
        let stream = match acceptor.accept(tcp).await {
            Ok(stream) => stream,
            Err(error) => {
                emit(json!({ "event": "rejected", "reason": error.to_string() }));
                continue;
            }
        };
        emit(json!({ "event": "accepted" }));
        let (peer, incoming) = peer::spawn(stream, PeerConfig::default());
        let (commands, command_queue) = mpsc::unbounded_channel();
        let clipboard = arguments.get("synthetic-clipboard").map(|directory| SyntheticClipboard::new(directory));
        let mut platform = ReplayHost {
            size: (width, height),
            replay: replay.clone(),
            clipboard: Some("probe host clipboard 剪贴板".to_string()),
            synthetic_clipboard: clipboard.clone(),
            refuse_edge,
            synthetic_cursor: arguments.contains_key("synthetic-cursor"),
            cursor_samples: None,
            synthetic_displays,
            synthetic_keyboard: arguments.contains_key("synthetic-keyboard"),
            synthetic_relative_mouse: arguments.contains_key("synthetic-relative-mouse"),
            synthetic_trackpad: arguments.contains_key("synthetic-trackpad"),
            caps_locked: false,
            alternate_layout: false,
        };
        let report = |event: HostEvent| match event {
            HostEvent::Streaming(stream) => emit(json!({ "event": "streaming", "stream": stream_json(stream) })),
            HostEvent::ViewerIdentity(identity) => emit(json!({ "event": "viewerIdentity", "id": identity.id, "name": identity.name })),
            HostEvent::ClipboardStatus(message) => emit(json!({"event":"clipboardStatus","message":message})),
            _ => {}
        };
        let session = host::run(peer.clone(), incoming, &mut platform, options.clone(), command_queue, report);
        tokio::pin!(session);
        let (reason, quit) = loop {
            tokio::select! {
                reason = &mut session => break (reason, false),
                accepted = listener.accept() => drop(accepted?),
                line = lines.recv() => {
                    let Some(line) = line else { let _ = commands.send(HostCommand::End); break ((&mut session).await, true) };
                    if clipboard.as_ref().is_some_and(|copy| copy.command(&line)) { continue; }
                    match line["command"].as_str() {
                        Some("allowControl") => { let _ = commands.send(HostCommand::AllowControl(line["value"].as_bool() == Some(true))); }
                        Some("detachExternal") => {
                            replay.lock().unwrap().external_attached = false;
                            let _ = commands.send(HostCommand::RefreshDisplays);
                        }
                        Some("rejectNextDisplay") => {
                            replay.lock().unwrap().reject_next_switch = true;
                            emit(json!({ "event": "displayFailureArmed" }));
                        }
                        Some("refuseLayout") => {
                            replay.lock().unwrap().refuse_layout = true;
                            emit(json!({ "event": "layoutRefusalArmed" }));
                        }
                        Some("end") => { let _ = commands.send(HostCommand::End); }
                        Some("quit") => { let _ = commands.send(HostCommand::End); break ((&mut session).await, true) }
                        _ => emit(json!({ "event": "invalidCommand", "command": line })),
                    }
                }
            }
        };
        peer.finished().await;
        emit(json!({ "event": "ended", "reason": reason.to_string() }));
        if quit {
            return Ok(());
        }
    }
}

/// Stands in for decoding and display: reports each frame and acknowledges it.
struct ReportingViewer {
    clipboard: Option<SyntheticClipboard>,
    acknowledgements: mpsc::UnboundedSender<DecodeReceipt>,
    feedback: Arc<Mutex<ScriptFeedback>>,
    identity: Option<DeviceIdentity>,
}

#[derive(Default)]
struct ScriptFeedback {
    hold: bool,
    held: Vec<(u32, DecodeReceipt, mpsc::UnboundedSender<DecodeReceipt>)>,
}

impl ReportingViewer {
    fn report(&mut self, packet: VideoPacket, receipt: DecodeReceipt, first_in_media_stream: Option<bool>) -> Result<()> {
        let stream = packet.annex_b()?;
        let mut feedback = self.feedback.lock().unwrap();
        emit(json!({
            "event": "frame", "sequence": packet.sequence, "key": packet.is_key_frame(),
            "annexB": hex(&stream), "firstInMediaStream": first_in_media_stream, "held": feedback.hold
        }));
        if feedback.hold {
            feedback.held.push((packet.sequence, receipt, self.acknowledgements.clone()));
        } else {
            let _ = self.acknowledgements.send(receipt);
        }
        Ok(())
    }
}

impl ViewerPlatform for ReportingViewer {
    fn open_clipboard(&mut self) -> Option<SessionClipboard> {
        self.clipboard.as_ref()?.open(Role::Viewer, true)
    }

    fn local_identity(&self) -> Option<&DeviceIdentity> {
        self.identity.as_ref()
    }

    fn video(&mut self, packet: VideoPacket) -> Result<()> {
        let receipt = DecodeReceipt::Legacy(packet.sequence);
        self.report(packet, receipt, None)
    }

    fn media_video(&mut self, packet: VideoPacket, stream: MediaStreamId, first_in_stream: bool) -> Result<()> {
        let receipt = DecodeReceipt::Media(stream, packet.sequence);
        self.report(packet, receipt, Some(first_in_stream))
    }

    fn event(&mut self, event: ViewerEvent) {
        emit(match event {
            ViewerEvent::Connected { name, device_id, can_control, stream, live_settings, input_actions, relative_mouse, trackpad_gestures, .. } => {
                json!({ "event": "connected", "name": name, "canControl": can_control, "stream": stream_json(stream), "liveSettings": live_settings,
                    "inputActions": input_actions, "relativeMouse": relative_mouse, "trackpadGestures": trackpad_gestures, "deviceID": device_id })
            }
            ViewerEvent::InputStatus(feedback) => json!({ "event": "inputStatus", "message": feedback.message, "capsLocked": feedback.caps_locked }),
            ViewerEvent::InputActionTimeout => json!({ "event": "inputActionTimeout" }),
            ViewerEvent::Stream { stream, error } => json!({ "event": "stream", "stream": stream_json(stream), "error": error }),
            ViewerEvent::MediaCommitted(stream) => json!({
                "event": "mediaCommitted", "sessionID": stream.session_id.to_string(),
                "transportEpoch": stream.transport_epoch, "codecEpoch": stream.codec_epoch
            }),
            ViewerEvent::Cursor(cursor) => {
                let image = cursor.image.as_ref().map(|image| match image.rgba() {
                    Ok(bytes) => json!({ "rgba": hex(&bytes), "width": image.pixel_width, "height": image.pixel_height,
                        "logicalWidth": image.logical_width, "logicalHeight": image.logical_height, "hotSpotX": image.hot_spot_x, "hotSpotY": image.hot_spot_y }),
                    Err(error) => json!({ "error": error.to_string() }),
                });
                let position = cursor.position.as_ref().map(|p| json!({ "inside": p.inside_display, "x": p.x, "y": p.y }));
                json!({ "event": "cursor", "enabled": cursor.enabled, "image": image, "position": position })
            }
            ViewerEvent::Displays { displays, selected, pending, error, .. } => json!({
                "event": "displays", "displays": displays, "selected": selected, "pending": pending, "error": error
            }),
            ViewerEvent::Control(can_control) => json!({ "event": "control", "canControl": can_control }),
            ViewerEvent::Paused { paused, error } => json!({ "event": "paused", "paused": paused, "error": error }),
            ViewerEvent::RoundTrip(milliseconds) => json!({ "event": "roundTrip", "milliseconds": milliseconds }),
            ViewerEvent::ClipboardText(text) => json!({ "event": "clipboardText", "text": text }),
            ViewerEvent::ClipboardStatus(message) => json!({"event":"clipboardStatus","message":message}),
        });
    }
}

#[derive(Deserialize)]
#[serde(remote = "TrackpadGesture", rename_all = "camelCase")]
enum ScriptGesture {
    Magnify(f64),
    Rotate(f64),
    SmartMagnify,
}

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "camelCase")]
enum Script {
    #[serde(rename_all = "camelCase")]
    Key {
        scan_code: u16,
        #[serde(default)]
        extended: bool,
        #[serde(default)]
        virtual_key: u16,
        down: bool,
        #[serde(default)]
        repeat: bool,
        #[serde(default)]
        caps_lock: bool,
    },
    #[serde(rename_all = "camelCase")]
    CapsPress {
        down: bool,
        at_milliseconds: u64,
    },
    Move {
        x: f64,
        y: f64,
    },
    RelativeMove {
        dx: f64,
        dy: f64,
    },
    #[serde(rename_all = "camelCase")]
    Button {
        button: i64,
        down: bool,
        x: f64,
        y: f64,
        at_milliseconds: u64,
        pixel: (i32, i32),
        #[serde(default)]
        relative: bool,
    },
    Wheel {
        vertical: f64,
        horizontal: f64,
        x: f64,
        y: f64,
        #[serde(default)]
        relative: bool,
    },
    PreciseScroll {
        dx: f64,
        dy: f64,
        phase: Option<ScrollPhase>,
        momentum: Option<MomentumPhase>,
        x: f64,
        y: f64,
    },
    Gesture {
        #[serde(with = "ScriptGesture")]
        gesture: TrackpadGesture,
        phase: Option<ScrollPhase>,
        x: f64,
        y: f64,
        #[serde(default)]
        relative: bool,
    },
    Release,
    Quality {
        settings: String,
    },
    SendClipboard {
        text: String,
    },
    RequestClipboard,
    SelectDisplay {
        id: u32,
    },
    Pause {
        paused: bool,
    },
    HoldAcknowledgements {
        hold: bool,
    },
    Acknowledge {
        sequence: u32,
    },
    Disconnect,
}

async fn run_viewer(arguments: &HashMap<String, String>) -> Result<ExitCode> {
    let identity = device_id(arguments)?.map(|id| DeviceIdentity { id, name: arguments.get("name").cloned().unwrap_or_else(|| "QuietDesk Probe".to_string()) });
    let required = |name: &str| arguments.get(name).ok_or_else(|| DeskError::invalid(format!("缺少参数 --{name}")));
    let key = PairingKey::parse(required("code")?)?;
    let port: u16 = required("port")?.parse().map_err(|_| DeskError::invalid("端口无效"))?;
    let quality = parse_settings(arguments.get("quality").map_or("1920,30,8", String::as_str))?;
    let mapping = if arguments.contains_key("control-as-command") { PcModifierMapping::ControlAsCommand } else { PcModifierMapping::Standard };
    let mut lines = input_lines();
    let host = arguments.get("host").map_or("127.0.0.1", String::as_str);
    let (commands, controls) = mpsc::unbounded_channel();
    let feedback = Arc::new(Mutex::new(ScriptFeedback::default()));
    let new_translator = || ViewerInputTranslator::new(mapping, DoubleClick { interval: Duration::from_millis(500), distance: 4 });
    let input = Mutex::new(new_translator());
    let press = Mutex::new(CapsLockPress::default());
    let independent = arguments.contains_key("independent-caps");
    let clipboard = arguments.get("synthetic-clipboard").map(|directory| SyntheticClipboard::new(directory));

    let script = async {
        while let Some(line) = lines.recv().await {
            if clipboard.as_ref().is_some_and(|copy| copy.command(&line)) {
                continue;
            }
            let mut translator = input.lock().unwrap();
            let command = match serde_json::from_value::<Script>(line) {
                Ok(Script::Key { scan_code, extended, virtual_key, down, repeat, caps_lock }) => {
                    let Some(mut input) = translator.key(PcKeyEvent { scan_code, extended, virtual_key, down, repeat }, caps_lock) else { continue };
                    input.independent_caps_lock = independent.then_some(true);
                    ViewerCommand::Input(input)
                }
                Ok(Script::CapsPress { down, at_milliseconds }) => {
                    let Some(action) = press.lock().unwrap().update(down, Duration::from_millis(at_milliseconds)) else { continue };
                    ViewerCommand::Input(action.remote_input())
                }
                Ok(Script::Move { x, y }) => ViewerCommand::Input(translator.pointer_move(x, y)),
                Ok(Script::RelativeMove { dx, dy }) => {
                    let Some(input) = translator.relative_pointer_move(dx, dy) else { continue };
                    ViewerCommand::Input(input)
                }
                Ok(Script::Button { button, down, x, y, at_milliseconds, pixel, relative }) => {
                    let input = translator.button(button, down, x, y, Duration::from_millis(at_milliseconds), pixel);
                    ViewerCommand::Input(if relative { input.at_current_pointer() } else { input })
                }
                Ok(Script::Wheel { vertical, horizontal, x, y, relative }) => {
                    let input = translator.wheel(vertical, horizontal, x, y);
                    ViewerCommand::Input(if relative { input.at_current_pointer() } else { input })
                }
                Ok(Script::PreciseScroll { dx, dy, phase, momentum, x, y }) => {
                    let Some(input) = translator.precise_scroll(dx, dy, phase, momentum, x, y) else { continue };
                    ViewerCommand::Input(input)
                }
                Ok(Script::Gesture { gesture, phase, x, y, relative }) => {
                    let Some(input) = translator.gesture(gesture, phase, x, y) else { continue };
                    ViewerCommand::Input(if relative { input.at_current_pointer() } else { input })
                }
                Ok(Script::Release) => {
                    translator.release_all();
                    press.lock().unwrap().reset();
                    ViewerCommand::ReleaseInput
                }
                Ok(Script::Quality { settings }) => match parse_settings(&settings) {
                    Ok(settings) => ViewerCommand::Quality(settings),
                    Err(error) => {
                        emit(json!({ "event": "invalidCommand", "error": error.to_string() }));
                        continue;
                    }
                },
                Ok(Script::SendClipboard { text }) => ViewerCommand::SendClipboard(text),
                Ok(Script::RequestClipboard) => ViewerCommand::RequestClipboard,
                Ok(Script::SelectDisplay { id }) => ViewerCommand::SelectDisplay(id),
                Ok(Script::Pause { paused }) => ViewerCommand::Pause(paused),
                Ok(Script::HoldAcknowledgements { hold }) => {
                    feedback.lock().unwrap().hold = hold;
                    continue;
                }
                Ok(Script::Acknowledge { sequence }) => {
                    let mut feedback = feedback.lock().unwrap();
                    if let Some(index) = feedback.held.iter().position(|(held_sequence, _, _)| *held_sequence == sequence) {
                        let (_, receipt, acknowledgements) = feedback.held.remove(index);
                        let _ = acknowledgements.send(receipt);
                    }
                    continue;
                }
                Ok(Script::Disconnect) => ViewerCommand::Disconnect,
                Err(error) => {
                    emit(json!({ "event": "invalidCommand", "error": error.to_string() }));
                    continue;
                }
            };
            if commands.send(command.into()).is_err() {
                break;
            }
        }
        // The driver went away: end the session rather than linger without one.
        let _ = commands.send(ViewerCommand::Disconnect.into());
        std::future::pending::<()>().await
    };
    let connect_failure = Mutex::new(None);
    let lifecycle = reliability::run(
        quality,
        arguments.contains_key("reconnect"),
        controls,
        |status| {
            emit(match status {
                RetryStatus::Waiting { attempt, reason, .. } => json!({ "event": "retryWaiting", "attempt": attempt, "reason": reason }),
                RetryStatus::Connecting { attempt } => json!({ "event": "retryConnecting", "attempt": attempt }),
                RetryStatus::Deferred { reason } => json!({ "event": "retryDeferred", "reason": reason }),
            })
        },
        || async {
            let result = tls::connect(host, port, &key).await;
            *connect_failure.lock().unwrap() = result.as_ref().err().map(ToString::to_string);
            result
        },
        |stream, attempt| {
            emit(json!({ "event": "secured" }));
            *input.lock().unwrap() = new_translator();
            press.lock().unwrap().reset();
            *feedback.lock().unwrap() = ScriptFeedback::default();
            let feedback = feedback.clone();
            let identity = identity.clone();
            let clipboard = clipboard.clone();
            async move {
                let (peer, incoming) = peer::spawn(stream, PeerConfig::default());
                let (acknowledgements, acknowledged) = mpsc::unbounded_channel();
                let mut platform = ReportingViewer { acknowledgements, feedback, identity, clipboard };
                let end = attempt.run(peer.clone(), incoming, &mut platform, acknowledged).await;
                peer.finished().await;
                end
            }
        },
    );
    let end = tokio::select! {
        end = lifecycle => end,
        () = script => unreachable!("the script future never completes"),
    };
    if connect_failure.into_inner().unwrap().as_ref() == Some(&end.reason) {
        emit(json!({ "event": "failed", "reason": end.reason }));
        return Ok(ExitCode::FAILURE);
    }
    emit(json!({ "event": "ended", "reason": end.reason, "hostEnded": end.host_ended, "retryable": end.retryable }));
    Ok(ExitCode::SUCCESS)
}

fn main() -> ExitCode {
    let mut arguments = std::env::args().skip(1);
    let role = arguments.next().unwrap_or_default();
    let mut options = HashMap::new();
    let mut name: Option<String> = None;
    for argument in arguments {
        match (argument.strip_prefix("--"), name.take()) {
            (Some(flag), pending) => {
                if let Some(pending) = pending {
                    options.insert(pending, String::new());
                }
                name = Some(flag.to_string());
            }
            (None, Some(pending)) => {
                options.insert(pending, argument);
            }
            (None, None) => {}
        }
    }
    if let Some(pending) = name {
        options.insert(pending, String::new());
    }
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("the runtime starts");
    let result = runtime.block_on(async {
        match role.as_str() {
            "host" => run_host(&options).await.map(|()| ExitCode::SUCCESS),
            "viewer" => run_viewer(&options).await,
            _ => Err(DeskError::invalid("用法：quietdesk-probe host|viewer --code <配对码> …")),
        }
    });
    match result {
        Ok(status) => status,
        Err(error) => {
            emit(json!({ "event": "failed", "reason": error.to_string() }));
            ExitCode::FAILURE
        }
    }
}
