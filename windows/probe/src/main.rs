//! A headless host and viewer built from `quietdesk-core`, driven over standard input and output.
//!
//! The interoperability checks run it against the macOS implementation: the host role replays a recorded
//! H.264 stream where the Windows application would capture and encode, the viewer role reports what it
//! receives where the application would decode and draw. Everything in between is the code that ships.

use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::host::{self, FrameSink, HostCommand, HostEvent, HostOptions, HostPlatform};
use quietdesk_core::input::{DoubleClick, InjectOp, PcKeyEvent, ViewerInputTranslator};
use quietdesk_core::keymap::{MacModifierMapping, PcModifierMapping};
use quietdesk_core::messages::{StreamSettings, VideoStreamState};
use quietdesk_core::pairing::PairingKey;
use quietdesk_core::peer::{self, PeerConfig};
use quietdesk_core::tls;
use quietdesk_core::video::{EncodedFrame, H264FrameAssembler, VideoPacket};
use quietdesk_core::viewer::{self, ViewerCommand, ViewerEvent, ViewerPlatform};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::mpsc;

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
}

/// Stands in for capture and encoding: replays recorded encoder output from its first keyframe.
struct ReplayHost {
    size: (u32, u32),
    replay: Arc<Mutex<Replay>>,
    clipboard: Option<String>,
    refuse_edge: Option<i64>,
}

impl HostPlatform for ReplayHost {
    fn display_size(&mut self) -> Result<(u32, u32)> {
        Ok(self.size)
    }

    async fn configure(&mut self, settings: StreamSettings, frames: FrameSink) -> Result<VideoStreamState> {
        self.replay.lock().unwrap().sink = None;
        if self.refuse_edge == Some(settings.longest_edge) {
            return Err(DeskError::platform("编码器不支持该尺寸"));
        }
        let (width, height) = settings.dimensions(self.size.0, self.size.1);
        let stream = VideoStreamState { settings, width: i64::from(width), height: i64::from(height) };
        *self.replay.lock().unwrap() = Replay { sink: Some(frames), next: 0, paused: false };
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

    fn inject(&mut self, operations: &[InjectOp]) {
        if !operations.is_empty() {
            let operations: Vec<String> = operations.iter().map(|operation| format!("{operation:?}")).collect();
            emit(json!({ "event": "inject", "operations": operations }));
        }
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
    let frames = Arc::new(read_recording(required("recording")?)?);
    let size: Vec<u32> = required("size")?.split('x').filter_map(|value| value.parse().ok()).collect();
    let [width, height] = size[..] else { return Err(DeskError::invalid("--size 应为 宽x高")) };
    let options = HostOptions {
        name: arguments.get("name").cloned().unwrap_or_else(|| "QuietDesk Probe".to_string()),
        allow_control: true,
        clipboard: true,
        preferred: parse_settings(arguments.get("preferred").map_or("1920,30,8", String::as_str))?,
        limit: parse_settings(arguments.get("limit").map_or("2560,60,30", String::as_str))?,
        modifiers: if arguments.contains_key("standard-modifiers") { MacModifierMapping::Standard } else { MacModifierMapping::CommandAsControl },
    };
    let refuse_edge = arguments.get("refuse-edge").and_then(|value| value.parse().ok());
    let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
    emit(json!({ "event": "listening", "port": listener.local_addr()?.port() }));
    let acceptor = tls::Acceptor::new(&key)?;
    let mut lines = input_lines();

    let replay = Arc::new(Mutex::new(Replay { sink: None, next: 0, paused: false }));
    let producer = replay.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_millis(4)).await;
            let mut replay = producer.lock().unwrap();
            let Some(sink) = replay.sink.clone().filter(|sink| !replay.paused && sink.has_credit()) else { continue };
            sink.submit(frames[replay.next].clone());
            replay.next = (replay.next + 1) % frames.len();
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
        let mut platform =
            ReplayHost { size: (width, height), replay: replay.clone(), clipboard: Some("probe host clipboard 剪贴板".to_string()), refuse_edge };
        let report = |event: HostEvent| {
            if let HostEvent::Streaming(stream) = event {
                emit(json!({ "event": "streaming", "stream": stream_json(stream) }));
            }
        };
        let session = host::run(peer.clone(), incoming, &mut platform, options.clone(), command_queue, report);
        tokio::pin!(session);
        let (reason, quit) = loop {
            tokio::select! {
                reason = &mut session => break (reason, false),
                line = lines.recv() => {
                    let Some(line) = line else { let _ = commands.send(HostCommand::End); break ((&mut session).await, true) };
                    match line["command"].as_str() {
                        Some("allowControl") => { let _ = commands.send(HostCommand::AllowControl(line["value"].as_bool() == Some(true))); }
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
    acknowledgements: mpsc::UnboundedSender<u32>,
    hold_acknowledgements: Arc<Mutex<bool>>,
}

impl ViewerPlatform for ReportingViewer {
    fn video(&mut self, packet: VideoPacket) {
        let stream = packet.annex_b().unwrap_or_default();
        emit(json!({ "event": "frame", "sequence": packet.sequence, "key": packet.is_key_frame(), "annexB": hex(&stream) }));
        if !*self.hold_acknowledgements.lock().unwrap() {
            let _ = self.acknowledgements.send(packet.sequence);
        }
    }

    fn event(&mut self, event: ViewerEvent) {
        emit(match event {
            ViewerEvent::Connected { name, can_control, stream, live_settings } => {
                json!({ "event": "connected", "name": name, "canControl": can_control, "stream": stream_json(stream), "liveSettings": live_settings })
            }
            ViewerEvent::Stream { stream, error } => json!({ "event": "stream", "stream": stream_json(stream), "error": error }),
            ViewerEvent::Control(can_control) => json!({ "event": "control", "canControl": can_control }),
            ViewerEvent::Paused { paused, error } => json!({ "event": "paused", "paused": paused, "error": error }),
            ViewerEvent::RoundTrip(milliseconds) => json!({ "event": "roundTrip", "milliseconds": milliseconds }),
            ViewerEvent::ClipboardText(text) => json!({ "event": "clipboardText", "text": text }),
        });
    }
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
    Move {
        x: f64,
        y: f64,
    },
    #[serde(rename_all = "camelCase")]
    Button {
        button: i64,
        down: bool,
        x: f64,
        y: f64,
        at_milliseconds: u64,
        pixel: (i32, i32),
    },
    Wheel {
        vertical: f64,
        horizontal: f64,
        x: f64,
        y: f64,
    },
    Release,
    Quality {
        settings: String,
    },
    SendClipboard {
        text: String,
    },
    RequestClipboard,
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

async fn run_viewer(arguments: &HashMap<String, String>) -> Result<()> {
    let required = |name: &str| arguments.get(name).ok_or_else(|| DeskError::invalid(format!("缺少参数 --{name}")));
    let key = PairingKey::parse(required("code")?)?;
    let port: u16 = required("port")?.parse().map_err(|_| DeskError::invalid("端口无效"))?;
    let quality = parse_settings(arguments.get("quality").map_or("1920,30,8", String::as_str))?;
    let mapping = if arguments.contains_key("control-as-command") { PcModifierMapping::ControlAsCommand } else { PcModifierMapping::Standard };
    let mut lines = input_lines();
    let stream = tls::connect(arguments.get("host").map_or("127.0.0.1", String::as_str), port, &key).await?;
    emit(json!({ "event": "secured" }));
    let (peer, incoming) = peer::spawn(stream, PeerConfig::default());
    let (commands, command_queue) = mpsc::unbounded_channel();
    let (acknowledgements, acknowledged) = mpsc::unbounded_channel();
    let hold_acknowledgements = Arc::new(Mutex::new(false));
    let mut platform = ReportingViewer { acknowledgements: acknowledgements.clone(), hold_acknowledgements: hold_acknowledgements.clone() };
    let mut translator = ViewerInputTranslator::new(mapping, DoubleClick { interval: Duration::from_millis(500), distance: 4 });

    let script = async {
        while let Some(line) = lines.recv().await {
            let command = match serde_json::from_value::<Script>(line) {
                Ok(Script::Key { scan_code, extended, virtual_key, down, repeat, caps_lock }) => {
                    let Some(input) = translator.key(PcKeyEvent { scan_code, extended, virtual_key, down, repeat }, caps_lock) else { continue };
                    ViewerCommand::Input(input)
                }
                Ok(Script::Move { x, y }) => ViewerCommand::Input(translator.pointer_move(x, y)),
                Ok(Script::Button { button, down, x, y, at_milliseconds, pixel }) => {
                    ViewerCommand::Input(translator.button(button, down, x, y, Duration::from_millis(at_milliseconds), pixel))
                }
                Ok(Script::Wheel { vertical, horizontal, x, y }) => ViewerCommand::Input(translator.wheel(vertical, horizontal, x, y)),
                Ok(Script::Release) => {
                    translator.release_all();
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
                Ok(Script::Pause { paused }) => ViewerCommand::Pause(paused),
                Ok(Script::HoldAcknowledgements { hold }) => {
                    *hold_acknowledgements.lock().unwrap() = hold;
                    continue;
                }
                Ok(Script::Acknowledge { sequence }) => {
                    let _ = acknowledgements.send(sequence);
                    continue;
                }
                Ok(Script::Disconnect) => ViewerCommand::Disconnect,
                Err(error) => {
                    emit(json!({ "event": "invalidCommand", "error": error.to_string() }));
                    continue;
                }
            };
            if commands.send(command).is_err() {
                break;
            }
        }
        // The driver went away: end the session rather than linger without one.
        let _ = commands.send(ViewerCommand::Disconnect);
        std::future::pending::<()>().await
    };
    let end = tokio::select! {
        end = viewer::run(peer.clone(), incoming, &mut platform, quality, command_queue, acknowledged) => end,
        () = script => unreachable!("the script future never completes"),
    };
    peer.finished().await;
    emit(json!({ "event": "ended", "reason": end.reason, "hostEnded": end.host_ended, "retryable": end.retryable }));
    Ok(())
}

fn main() {
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
            "host" => run_host(&options).await,
            "viewer" => run_viewer(&options).await,
            _ => Err(DeskError::invalid("用法：quietdesk-probe host|viewer --code <配对码> …")),
        }
    });
    if let Err(error) = result {
        emit(json!({ "event": "failed", "reason": error.to_string() }));
        std::process::exit(1);
    }
}
