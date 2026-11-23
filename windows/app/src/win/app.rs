//! The sessions behind the windows: a listener that serves one viewer at a time, and a viewer connection
//! with its decode thread. Both run on the network thread's runtime and report through callbacks.

use super::codec::{H264Decoder, MediaFoundation, Picture};
use super::pipeline::WindowsHost;
use super::util::Com;
use quietdesk_core::clipboard::{Exchange, Role};
use quietdesk_core::clipboard_session::SessionClipboard;
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::host::{self, HostCommand, HostConnections, HostEvent, HostOptions};
use quietdesk_core::media::{DecodeReceipt, MediaStreamId, window};
use quietdesk_core::messages::{DeviceIdentity, StreamSettings};
use quietdesk_core::pairing::PairingKey;
use quietdesk_core::peer::{self, PeerConfig};
use quietdesk_core::pixel::nv12_to_bgra;
use quietdesk_core::reliability::{self, Attempt, RetryStatus, ViewerControl};
use quietdesk_core::tls;
use quietdesk_core::video::VideoPacket;
use quietdesk_core::viewer::{ViewerEnd, ViewerEvent, ViewerPlatform};
use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use tokio::net::TcpListener;
use tokio::sync::mpsc;

#[derive(Clone, Debug)]
pub enum HostNotice {
    Listening(u16),
    /// Sharing could not start or had to stop.
    Failed(String),
    DisplayError(String),
    Connected,
    Session(HostEvent),
    Ended(String),
}

#[derive(Default)]
pub struct HostActivity(Mutex<HostActivityState>);

#[derive(Default, PartialEq, Eq)]
enum HostActivityState {
    #[default]
    Idle,
    Connected,
    Restarting,
}

impl HostActivity {
    pub(super) fn connected(&self) -> bool {
        *self.0.lock().unwrap() == HostActivityState::Connected
    }

    fn start_session(&self) -> Option<HostActivitySession<'_>> {
        self.claim(HostActivityState::Connected).then(|| HostActivitySession(self))
    }

    pub(super) fn begin_restart(&self) -> bool {
        self.claim(HostActivityState::Restarting)
    }

    pub(super) fn cancel_restart(&self) {
        *self.0.lock().unwrap() = HostActivityState::Idle;
    }

    fn claim(&self, next: HostActivityState) -> bool {
        let mut current = self.0.lock().unwrap();
        if *current != HostActivityState::Idle {
            return false;
        }
        *current = next;
        true
    }
}

struct HostActivitySession<'a>(&'a HostActivity);

impl Drop for HostActivitySession<'_> {
    fn drop(&mut self) {
        *self.0.0.lock().unwrap() = HostActivityState::Idle;
    }
}

#[cfg(test)]
#[test]
fn updater_and_incoming_sessions_claim_the_host_exclusively() {
    let activity = HostActivity::default();
    let session = activity.start_session().unwrap();
    assert!(activity.connected());
    assert!(!activity.begin_restart());
    drop(session);

    assert!(activity.begin_restart());
    assert!(activity.start_session().is_none());
    activity.cancel_restart();
    assert!(activity.start_session().is_some());
}

/// Shares this PC on `port` until `commands` closes. One viewer is served at a time.
pub async fn serve_host(
    port: u16,
    key: PairingKey,
    options: Arc<Mutex<HostOptions>>,
    mut commands: mpsc::UnboundedReceiver<HostCommand>,
    activity: Arc<HostActivity>,
    notify: impl Fn(HostNotice) + Clone + Send + 'static,
) {
    let listener = match TcpListener::bind(("0.0.0.0", port)).await {
        Ok(listener) => listener,
        Err(error) => return notify(HostNotice::Failed(format!("无法监听端口 {port}：{error}"))),
    };
    let acceptor = match tls::Acceptor::new(&key) {
        Ok(acceptor) => acceptor,
        Err(error) => return notify(HostNotice::Failed(error.to_string())),
    };
    notify(HostNotice::Listening(listener.local_addr().map_or(port, |address| address.port())));
    let remember = |options: &Mutex<HostOptions>, command: &HostCommand| match command {
        HostCommand::AllowControl(allowed) => options.lock().unwrap().allow_control = *allowed,
        HostCommand::Clipboard(enabled) => options.lock().unwrap().clipboard = *enabled,
        HostCommand::End | HostCommand::SelectDisplay(_) | HostCommand::RefreshDisplays => {}
    };
    loop {
        let mut waiting = tls::PendingHandshakes::new(&acceptor);
        let stream = loop {
            tokio::select! {
                accepted = listener.accept() => { if let Ok((tcp, _)) = accepted { waiting.start(tcp); } }
                command = commands.recv() => match command {
                    Some(command) => {
                        if matches!(command, HostCommand::SelectDisplay(_) | HostCommand::RefreshDisplays) {
                            match super::displays::outputs() {
                                Ok(outputs) => {
                                    let mut preference = options.lock().unwrap().preferred_display;
                                    let mut error = None;
                                    if let HostCommand::SelectDisplay(requested) = command {
                                        if requested.is_none_or(|id| outputs.iter().any(|d| d.info.id == id)) {
                                            preference = requested;
                                            options.lock().unwrap().preferred_display = requested;
                                            notify(HostNotice::Session(HostEvent::LocalDisplaySelected(requested)));
                                        } else {
                                            error = Some("所选显示器当前不可用".into());
                                        }
                                    }
                                    let selected = super::displays::preferred(&outputs, preference).info.id;
                                    let displays = super::displays::directory(outputs, Some(selected));
                                    notify(HostNotice::Session(HostEvent::Displays { displays, selected, error }));
                                }
                                Err(error) => notify(HostNotice::DisplayError(error.to_string())),
                            }
                        } else {
                            remember(&options, &command);
                        }
                        continue
                    }
                    None => return,
                },
                secured = waiting.next() => match secured {
                    Ok((None, stream)) => break stream,
                    Ok((Some(_), _)) => {}
                    Err(error) => log::info!("a connection did not complete the pairing handshake: {error}"),
                },
            }
        };
        drop(waiting);
        let Some(session_activity) = activity.start_session() else { continue };
        let mut active = tls::PendingHandshakes::new(&acceptor);
        let (auxiliary, accepted) = mpsc::channel(4);
        let connections = HostConnections { auxiliary: Some(accepted), datagram: stream.get_ref().local_addr().ok() };
        notify(HostNotice::Connected);
        let (peer, incoming) = peer::spawn(stream, PeerConfig::default());
        let (session_commands, queue) = mpsc::unbounded_channel();
        let current = options.lock().unwrap().clone();
        let rescan = session_commands.clone();
        let mut platform = WindowsHost::start_notifying(current.preferred_display, move || rescan.send(HostCommand::RefreshDisplays).is_ok());
        let report = notify.clone();
        let saved = options.clone();
        let session = host::run_with_auxiliary(
            peer.clone(),
            incoming,
            &mut platform,
            current,
            queue,
            move |event| {
                if let HostEvent::LocalDisplaySelected(preferred) = &event {
                    saved.lock().unwrap().preferred_display = *preferred;
                }
                report(HostNotice::Session(event));
            },
            connections,
        );
        tokio::pin!(session);
        let period = std::time::Duration::from_secs(2);
        let mut display_check = tokio::time::interval_at(tokio::time::Instant::now() + period, period);
        display_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut stopping = false;
        let reason = loop {
            tokio::select! {
                reason = &mut session => break reason,
                connected = listener.accept(), if !stopping => {
                    if let Ok((tcp, _)) = connected { active.start(tcp); }
                }
                secured = active.next(), if !stopping => {
                    if let Ok((Some(role), stream)) = secured { let _ = auxiliary.try_send((role, stream)); }
                }
                // A headless host has no WM_DISPLAYCHANGE for newly connected, unselected outputs.
                _ = display_check.tick(), if !stopping => { let _ = session_commands.send(HostCommand::RefreshDisplays); }
                command = commands.recv(), if !stopping => match command {
                    Some(command) => { remember(&options, &command); let _ = session_commands.send(command); }
                    None => { stopping = true; let _ = session_commands.send(HostCommand::End); }
                },
            }
        };
        drop(active);
        peer.finished().await;
        drop(session_activity);
        notify(HostNotice::Ended(reason.to_string()));
        if stopping {
            return;
        }
    }
}

/// The latest decoded picture, shared between the decode thread and the window that draws it.
#[derive(Default)]
pub struct Frame {
    pub stream: Option<MediaStreamId>,
    pub display: Option<DisplayGeometry>,
    pub width: usize,
    pub height: usize,
    /// Rows of `width * 4` bytes, top down.
    pub bgra: Vec<u8>,
    /// Counts pictures, so a reader can tell whether it has drawn this one.
    pub serial: u64,
}

/// Identifies the displayed coordinate space even when two monitors encode to the same video size.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DisplayGeometry {
    pub id: u32,
    pub revision: u64,
    width: u32,
    height: u32,
}

impl DisplayGeometry {
    pub fn selected(displays: &[quietdesk_core::display::RemoteDisplayInfo], selected: Option<u32>, revision: u64) -> Option<Self> {
        displays.iter().find(|display| Some(display.id) == selected).map(|display| Self {
            id: display.id,
            width: display.width,
            height: display.height,
            revision,
        })
    }
}

impl Frame {
    fn update(&mut self, picture: Picture<'_>) {
        self.width = picture.width;
        self.height = picture.height;
        self.bgra.resize(self.width * self.height * 4, 0);
        nv12_to_bgra(picture.luma, picture.chroma, self.width, self.height, picture.color, &mut self.bgra);
    }

    fn present(&mut self, next: &mut Self) {
        next.serial = self.serial + 1;
        std::mem::swap(self, next);
    }
}

pub(super) fn open_clipboard(role: Role, enabled: bool) -> Option<SessionClipboard> {
    use super::clipboard_session::{NativeClipboard, storage_root};
    use super::clipboard_storage::WindowsStorage;

    let exchange = Exchange::with_storage(role, storage_root().ok()?, enabled, true, Arc::new(WindowsStorage)).ok()?;
    let owner = NativeClipboard::start(exchange.input.clone(), role == Role::Viewer).ok()?;
    Some(SessionClipboard::new(exchange, move |action| owner.action(action)))
}

/// Where a viewer session reports to. Called from the network and decode threads.
pub trait ViewerSink: Send + Sync + 'static {
    fn plays_audio(&self) -> bool {
        false
    }
    fn clipboard_preference(&self) -> Option<bool> {
        None
    }
    fn local_identity(&self) -> Option<&DeviceIdentity> {
        None
    }
    fn event(&self, event: ViewerEvent);
    fn retry(&self, status: RetryStatus);
    /// `frame` holds a new picture.
    fn frame_ready(&self, stream: Option<MediaStreamId>);
}

struct WindowsViewer<S: ViewerSink> {
    packets: Arc<DecodeQueue>,
    sink: Arc<S>,
    display: Option<DisplayGeometry>,
    media_display: Option<DisplayGeometry>,
}

enum DecodeCommand {
    Packet { packet: VideoPacket, receipt: DecodeReceipt, first: bool, display: Option<DisplayGeometry> },
    Commit(MediaStreamId),
}

impl DecodeCommand {
    fn bytes(&self) -> usize {
        match self {
            Self::Packet { packet, .. } => packet.encoded_len(),
            Self::Commit(_) => 0,
        }
    }
}

#[derive(Default)]
struct DecodeQueueState {
    commands: VecDeque<DecodeCommand>,
    in_flight_bytes: usize,
    receiving: Option<MediaStreamId>,
    closed: bool,
}

struct DecodeQueue {
    state: Mutex<DecodeQueueState>,
    ready: Condvar,
    byte_limit: usize,
}

impl DecodeQueue {
    fn new(byte_limit: usize) -> Self {
        Self { state: Mutex::default(), ready: Condvar::new(), byte_limit }
    }

    fn receiving(&self, stream: Option<MediaStreamId>) {
        let mut state = self.state.lock().unwrap();
        if state.receiving != stream {
            state.receiving = stream;
            state.commands.retain(|command| matches!(command, DecodeCommand::Packet { receipt: DecodeReceipt::Legacy(_), .. }));
        }
    }

    fn send(&self, command: DecodeCommand) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return Err(DeskError::platform("视频解码已停止"));
        }
        // An opening commit shares the decoder thread with the negotiated frame window.
        if state.commands.len() == window::MAX_DYNAMIC_FRAMES + 1 {
            return Err(DeskError::platform("视频解码队列已满"));
        }
        if state.in_flight_bytes + state.commands.iter().map(DecodeCommand::bytes).sum::<usize>() + command.bytes() > self.byte_limit {
            return Err(DeskError::platform("视频解码字节队列已满"));
        }
        state.commands.push_back(command);
        self.ready.notify_one();
        Ok(())
    }

    fn recv(&self) -> Option<DecodeCommand> {
        let mut state = self.state.lock().unwrap();
        // The decoder finishes and drops the previous command before receiving the next one.
        state.in_flight_bytes = 0;
        let mut state = self.ready.wait_while(state, |state| state.commands.is_empty() && !state.closed).unwrap();
        let command = state.commands.pop_front()?;
        state.in_flight_bytes = command.bytes();
        Some(command)
    }

    /// Keep retirement ordered with the final frame swap and receipt, after decoding outside this lock.
    fn while_current<T>(&self, stream: MediaStreamId, apply: impl FnOnce() -> T) -> Option<T> {
        let state = self.state.lock().unwrap();
        (!state.closed && state.receiving == Some(stream)).then(apply)
    }

    fn close(&self) {
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        state.commands.clear();
        self.ready.notify_one();
    }
}

impl<S: ViewerSink> Drop for WindowsViewer<S> {
    fn drop(&mut self) {
        self.packets.close();
    }
}

impl<S: ViewerSink> ViewerPlatform for WindowsViewer<S> {
    fn supports_audio_playback(&self) -> bool {
        self.sink.plays_audio()
    }
    fn start_audio_playback(&mut self, epoch: std::num::NonZeroU32, paused: bool) -> Result<quietdesk_core::audio_session::AudioPlayback> {
        super::audio::start_playback(epoch, paused)
    }
    fn open_clipboard(&mut self) -> Option<SessionClipboard> {
        open_clipboard(Role::Viewer, self.sink.clipboard_preference()?)
    }
    fn local_identity(&self) -> Option<&DeviceIdentity> {
        self.sink.local_identity()
    }
    fn video(&mut self, packet: VideoPacket) -> Result<()> {
        let receipt = DecodeReceipt::Legacy(packet.sequence);
        self.packets.send(DecodeCommand::Packet { packet, receipt, first: false, display: self.display })
    }

    fn media_receiving(&mut self, stream: Option<MediaStreamId>) {
        self.packets.receiving(stream);
    }

    fn media_video(&mut self, packet: VideoPacket, stream: MediaStreamId, first: bool) -> Result<()> {
        let receipt = DecodeReceipt::Media(stream, packet.sequence);
        if first {
            self.media_display = self.display;
        }
        self.packets.send(DecodeCommand::Packet { packet, receipt, first, display: self.media_display })
    }

    fn media_committed(&mut self, stream: MediaStreamId) -> Result<()> {
        self.packets.send(DecodeCommand::Commit(stream))
    }

    fn event(&mut self, event: ViewerEvent) {
        if let ViewerEvent::Displays { displays, selected, revision, .. } = &event {
            self.display = DisplayGeometry::selected(displays, *selected, *revision);
            if *revision == 0 && self.media_display.is_none() {
                self.media_display = self.display;
            }
        }
        self.sink.event(event);
    }
}

fn present_opening(
    packets: &DecodeQueue,
    frame: &Mutex<Frame>,
    candidate: &mut Option<MediaStreamId>,
    output: &mut Frame,
    stream: MediaStreamId,
) -> Result<bool> {
    let mut visible = frame.lock().unwrap();
    let applied = packets.while_current(stream, || -> Result<()> {
        candidate.take_if(|opening| *opening == stream).ok_or_else(|| DeskError::platform("媒体流缺少已解码的首帧"))?;
        visible.present(output);
        Ok(())
    });
    Ok(applied.transpose()?.is_some())
}

fn decode<S: ViewerSink>(packets: &DecodeQueue, acknowledgements: mpsc::UnboundedSender<DecodeReceipt>, frame: Arc<Mutex<Frame>>, sink: Arc<S>) -> Result<()> {
    let _com = Com::enter();
    let _media = MediaFoundation::start()?;
    let mut legacy_decoder = None;
    let mut legacy_display = None;
    let mut media_decoder = None;
    let mut pending = VecDeque::new();
    let mut candidate = None;
    let mut output = Frame::default();
    while let Some(command) = packets.recv() {
        let (packet, receipt, first, display) = match command {
            DecodeCommand::Packet { packet, receipt, first, display } => (packet, receipt, first, display),
            DecodeCommand::Commit(stream) => {
                if present_opening(packets, &frame, &mut candidate, &mut output, stream)? {
                    sink.event(ViewerEvent::MediaCommitted(stream));
                    sink.frame_ready(Some(stream));
                }
                continue;
            }
        };
        let stream = match receipt {
            DecodeReceipt::Legacy(_) => {
                if display != legacy_display {
                    legacy_decoder = None;
                    legacy_display = display;
                }
                let decoder = match &mut legacy_decoder {
                    Some(decoder) => decoder,
                    None => legacy_decoder.insert(H264Decoder::new()?),
                };
                decoder.decode(&packet.annex_b()?, &packet.sps, |picture| {
                    {
                        let mut visible = frame.lock().unwrap();
                        visible.stream = None;
                        visible.display = display;
                        visible.update(picture);
                        visible.serial += 1;
                    }
                    sink.frame_ready(None);
                })?;
                if acknowledgements.send(receipt).is_err() {
                    break;
                }
                continue;
            }
            DecodeReceipt::Media(stream, _) => stream,
        };

        let outcome = (|| {
            // A fresh MFT isolates the candidate from buffered pictures and timestamps of retired streams.
            if first {
                media_decoder = Some(H264Decoder::new()?);
                pending.clear();
                candidate = None;
            }
            let annex_b = packet.annex_b()?;
            let decoder = media_decoder.as_mut().expect("the media receiver starts each stream with its opening frame");
            // A buffering transform may need another copy of the same IDR to yield the first picture.
            let copies = if first { 3 } else { 1 };
            for _ in 0..copies {
                if packets.while_current(stream, || ()).is_none() {
                    return Ok(());
                }
                pending.push_back((decoder.next_sample_time(), receipt));
                decoder.decode(&annex_b, &packet.sps, |picture| {
                    let Some(time) = picture.sample_time else { return };
                    let Some(position) = pending.iter().position(|(tag, _)| *tag == time) else { return };
                    let (_, completed) = pending.remove(position).expect("a picture with this sample time is pending");
                    output.stream = Some(stream);
                    output.display = display;
                    output.update(picture);
                    if first {
                        packets.while_current(stream, || {
                            candidate = Some(stream);
                            // Later outputs for the same IDR copy have no separate receipt or visible frame.
                            pending.clear();
                            let _ = acknowledgements.send(completed);
                        });
                    } else {
                        let displayed = {
                            let mut visible = frame.lock().unwrap();
                            packets.while_current(stream, || {
                                visible.present(&mut output);
                                let _ = acknowledgements.send(completed);
                            })
                        };
                        if displayed.is_some() {
                            sink.frame_ready(Some(stream));
                        }
                    }
                })?;
                if !first || candidate.is_some() {
                    break;
                }
            }
            if first && candidate.is_none() { Err(DeskError::platform("H.264 解码器未能输出媒体关键帧")) } else { Ok(()) }
        })();
        if let Err(error) = outcome
            && packets.while_current(stream, || ()).is_some()
        {
            return Err(error);
        }
    }
    Ok(())
}

/// Connects to a host and runs the session until it ends. Pictures appear in `frame`.
pub async fn run_viewer<S: ViewerSink>(
    target: (String, u16),
    key: PairingKey,
    quality: StreamSettings,
    auto_reconnect: bool,
    controls: mpsc::UnboundedReceiver<ViewerControl>,
    frame: Arc<Mutex<Frame>>,
    sink: Arc<S>,
) -> ViewerEnd {
    reliability::run(
        quality,
        auto_reconnect,
        controls,
        |status| sink.retry(status),
        || tls::connect(&target.0, target.1, &key),
        |stream, attempt| {
            let attempt = match stream.get_ref().peer_addr() {
                Ok(addr) => attempt.with_auxiliary(addr, key.clone()).with_datagrams(addr),
                Err(_) => attempt,
            };
            viewer_session(stream, attempt, frame.clone(), sink.clone())
        },
    )
    .await
}

async fn viewer_session<S: ViewerSink>(stream: tls::SecureStream, attempt: Attempt, frame: Arc<Mutex<Frame>>, sink: Arc<S>) -> ViewerEnd {
    let packets = Arc::new(DecodeQueue::new(window::MAX_BUFFERED_BYTES));
    let (acknowledgements, acknowledged) = mpsc::unbounded_channel();
    let (finished, decode_result) = tokio::sync::oneshot::channel();
    let (decode_queue, decode_sink) = (packets.clone(), sink.clone());
    let decoding = std::thread::Builder::new().name("decode".to_string()).spawn(move || {
        let result = decode(&decode_queue, acknowledgements, frame, decode_sink);
        decode_queue.close();
        if let Err(error) = &result {
            log::error!("decoding stopped: {error}");
        }
        let _ = finished.send(result);
    });
    if let Err(error) = decoding {
        return ViewerEnd { reason: format!("无法启动解码线程：{error}"), host_ended: false, retryable: false, local_stop: false };
    }
    let (peer, incoming) = peer::spawn(stream, PeerConfig::default());
    let mut platform = WindowsViewer { packets, sink, display: None, media_display: None };
    let mut end = attempt.run(peer.clone(), incoming, &mut platform, acknowledged).await;
    drop(platform);
    let (_, decode_result) = tokio::join!(peer.finished(), decode_result);
    if end.retryable
        && let Ok(Err(error)) = decode_result
    {
        end = error.into();
    }
    end
}

/// The runtime every session of this process runs on, on its own thread.
pub fn network_runtime() -> tokio::runtime::Handle {
    let (ready, started) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("network".to_string())
        .spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("the network runtime starts");
            ready.send(runtime.handle().clone()).expect("the caller waits for the runtime");
            runtime.block_on(std::future::pending::<()>());
        })
        .expect("the network thread starts");
    started.recv().expect("the network thread reports its runtime")
}

/// The name viewers see for this PC.
pub fn computer_name() -> String {
    std::env::var("COMPUTERNAME").ok().filter(|name| !name.is_empty()).unwrap_or_else(|| "Windows 电脑".to_string())
}

/// Where the log goes, and what the log must never contain: pairing codes, addresses, clipboard text or keys.
pub fn start_logging() {
    use flexi_logger::{Cleanup, Criterion, FileSpec, Logger, Naming};
    let directory = std::path::PathBuf::from(std::env::var_os("LOCALAPPDATA").unwrap_or_else(|| ".".into())).join("QuietDesk").join("logs");
    let started = Logger::try_with_str("info").and_then(|logger| {
        logger
            .log_to_file(FileSpec::default().directory(&directory).basename("quietdesk"))
            .rotate(Criterion::Size(2 * 1024 * 1024), Naming::Numbers, Cleanup::KeepLogFiles(3))
            .format_for_files(flexi_logger::detailed_format)
            .start()
    });
    match started {
        // The handle lives as long as the process; dropping it would stop the logger.
        Ok(handle) => std::mem::forget(handle),
        Err(error) => eprintln!("logging is unavailable: {error}"),
    }
    std::panic::set_hook(Box::new(|panic| log::error!("unexpected failure: {panic}")));
    log::info!("QuietDesk for Windows {} (build {})", env!("QUIETDESK_VERSION"), env!("QUIETDESK_BUILD_NUMBER"));
}

#[cfg(test)]
mod display_tests {
    use super::*;
    use quietdesk_core::display::RemoteDisplayInfo;
    use quietdesk_core::video::EncodedFrame;

    struct Silent;
    impl ViewerSink for Silent {
        fn event(&self, _: ViewerEvent) {}
        fn retry(&self, _: RetryStatus) {}
        fn frame_ready(&self, _: Option<MediaStreamId>) {}
    }

    #[test]
    fn replacing_a_decode_stream_releases_old_packets_and_keeps_the_last_picture_until_commit() {
        let packet = |sequence, len| VideoPacket::h264(sequence, EncodedFrame { sps: vec![], pps: vec![], avcc: vec![0; len] });
        let size = packet(1, 9).encoded_len();
        let queue = Arc::new(DecodeQueue::new(4 * size));
        let mut viewer = WindowsViewer { packets: queue.clone(), sink: Arc::new(Silent), display: None, media_display: None };
        let stream = MediaStreamId { session_id: Default::default(), transport_epoch: 1, codec_epoch: 1 };
        viewer.media_receiving(Some(stream));
        viewer.media_video(packet(1, 9), stream, true).unwrap();
        let in_flight = queue.recv().unwrap();
        viewer.video(packet(2, 9)).unwrap();
        viewer.media_committed(stream).unwrap();
        viewer.media_video(packet(3, 9), stream, false).unwrap();
        viewer.media_video(packet(4, 9), stream, false).unwrap();
        assert!(viewer.media_video(packet(5, 9), stream, false).is_err());

        let next = MediaStreamId { codec_epoch: 2, ..stream };
        viewer.media_receiving(None);
        viewer.media_receiving(Some(next));
        viewer.media_video(packet(6, 9 + size), next, true).unwrap();
        // The retired packet already inside the decoder still occupies memory.
        assert!(viewer.video(packet(7, 9)).is_err());
        let DecodeCommand::Packet { receipt: DecodeReceipt::Media(retired, 1), .. } = &in_flight else { panic!("expected an in-flight old keyframe") };
        let retired = *retired;
        assert!(queue.while_current(retired, || unreachable!("retired decodes cannot publish or acknowledge")).is_none());
        drop(in_flight);
        assert!(matches!(queue.recv(), Some(DecodeCommand::Packet { receipt: DecodeReceipt::Legacy(2), .. })));
        assert!(matches!(queue.recv(), Some(DecodeCommand::Packet { receipt: DecodeReceipt::Media(id, 6), first: true, .. }) if id == next));

        let frame = Mutex::new(Frame { stream: Some(stream), serial: 1, ..Frame::default() });
        let mut candidate = Some(next);
        let mut opening = Frame { stream: Some(next), ..Frame::default() };
        assert!(!present_opening(&queue, &frame, &mut candidate, &mut opening, retired).unwrap());
        {
            let visible = frame.lock().unwrap();
            assert_eq!((visible.stream, visible.serial), (Some(stream), 1));
        }
        viewer.media_committed(next).unwrap();
        let Some(DecodeCommand::Commit(committed)) = queue.recv() else { panic!("expected the current stream's commit") };
        assert!(present_opening(&queue, &frame, &mut candidate, &mut opening, committed).unwrap());
        let visible = frame.lock().unwrap();
        assert_eq!((visible.stream, visible.serial), (Some(next), 2));
    }

    #[test]
    fn a_late_packet_keeps_the_screen_that_opened_its_stream() {
        let queue = Arc::new(DecodeQueue::new(window::MAX_BUFFERED_BYTES));
        let mut viewer = WindowsViewer { packets: queue.clone(), sink: Arc::new(Silent), display: None, media_display: None };
        let displays = vec![RemoteDisplayInfo::new(8, "左", 1920, 1080, true), RemoteDisplayInfo::new(9, "右", 1920, 1080, false)];
        let selection = |id, revision| ViewerEvent::Displays { displays: displays.clone(), selected: Some(id), pending: None, error: None, revision };
        let packet = |sequence| VideoPacket::h264(sequence, EncodedFrame { sps: vec![], pps: vec![], avcc: vec![] });
        let first = MediaStreamId { session_id: Default::default(), transport_epoch: 1, codec_epoch: 1 };
        viewer.media_receiving(Some(first));
        viewer.event(selection(8, 0));
        viewer.media_video(packet(1), first, true).unwrap();
        viewer.event(selection(9, 1));
        viewer.media_video(packet(2), first, false).unwrap();
        for expected in [8, 8] {
            let DecodeCommand::Packet { display, .. } = queue.recv().unwrap() else { panic!("expected a packet") };
            assert_eq!(display.unwrap().id, expected);
        }
        let next = MediaStreamId { codec_epoch: 2, ..first };
        viewer.media_receiving(Some(next));
        viewer.media_video(packet(3), next, true).unwrap();
        let DecodeCommand::Packet { display, .. } = queue.recv().unwrap() else { panic!("expected the opening keyframe") };
        assert_eq!(display.unwrap().id, 9);
    }
}

#[cfg(test)]
mod datagram_tests {
    use quietdesk_core::datagram_transport::{DatagramEvent, host, viewer};
    use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
    use std::time::Duration;
    use uuid::Uuid;

    #[test]
    fn viewer_handshakes_after_sending_to_unlistening_local_port() {
        let probe = UdpSocket::bind(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)).unwrap();
        let closed_addr = UdpSocket::bind(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)).unwrap().local_addr().unwrap();
        probe.set_read_timeout(Some(Duration::from_millis(150))).unwrap();
        let _ = probe.send_to(b"\x00", closed_addr);
        let mut buf = [0u8; 64];
        let probe_res = probe.recv_from(&mut buf);
        println!("wine/winsock closed-udp std recv probe: {probe_res:?}");

        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let tokio_probe = tokio::net::UdpSocket::bind(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0)).await.unwrap();
            let _ = tokio_probe.send_to(b"\x00", closed_addr).await;
            let mut tbuf = [0u8; 64];
            let tprobe_res = tokio::time::timeout(Duration::from_millis(150), tokio_probe.recv_from(&mut tbuf)).await;
            println!("wine/winsock closed-udp tokio recv probe: {tprobe_res:?}");

            let key = [0x5Au8; 32];
            let id = Uuid::new_v4();
            let mut completed = false;
            for _ in 0..3 {
                let addr = UdpSocket::bind(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)).unwrap().local_addr().unwrap();
                let mut client = viewer(addr, key, id).unwrap();
                tokio::time::sleep(Duration::from_millis(350)).await;
                let Ok(mut server) = host(addr, key, id) else {
                    continue;
                };
                let (a, b) = tokio::join!(
                    tokio::time::timeout(Duration::from_millis(2500), server.next()),
                    tokio::time::timeout(Duration::from_millis(2500), client.next()),
                );
                assert!(matches!((a, b), (Ok(DatagramEvent::Ready), Ok(DatagramEvent::Ready))));
                assert!(client.try_send(vec![42, 7]));
                let event = tokio::time::timeout(Duration::from_secs(1), server.next()).await.unwrap();
                assert!(matches!(event, DatagramEvent::Data(bytes) if bytes == [42, 7]));
                completed = true;
                break;
            }
            assert!(completed, "could not bind test listener after transient delay");
        });
    }
}
