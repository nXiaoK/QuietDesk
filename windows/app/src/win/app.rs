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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
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

/// Shares this PC on `port` until `commands` closes. One viewer is served at a time.
pub async fn serve_host(
    port: u16,
    key: PairingKey,
    options: Arc<Mutex<HostOptions>>,
    mut commands: mpsc::UnboundedReceiver<HostCommand>,
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
        nv12_to_bgra(picture.luma, picture.chroma, self.width, self.height, &mut self.bgra);
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
    packets: SyncSender<DecodeCommand>,
    packet_bytes: Arc<tokio::sync::Semaphore>,
    sink: Arc<S>,
    display: Option<DisplayGeometry>,
    media_display: Option<DisplayGeometry>,
}

enum DecodeCommand {
    Packet { packet: VideoPacket, receipt: DecodeReceipt, first: bool, display: Option<DisplayGeometry>, bytes: tokio::sync::OwnedSemaphorePermit },
    Commit(MediaStreamId),
}

impl<S: ViewerSink> WindowsViewer<S> {
    fn packet(&self, packet: VideoPacket, receipt: DecodeReceipt, first: bool, display: Option<DisplayGeometry>) -> Result<()> {
        let bytes = u32::try_from(packet.encoded_len())
            .ok()
            .and_then(|size| self.packet_bytes.clone().try_acquire_many_owned(size).ok())
            .ok_or_else(|| DeskError::platform("视频解码字节队列已满"))?;
        self.enqueue(DecodeCommand::Packet { packet, receipt, first, display, bytes })
    }

    fn enqueue(&self, command: DecodeCommand) -> Result<()> {
        self.packets.try_send(command).map_err(|error| match error {
            TrySendError::Full(_) => DeskError::platform("视频解码队列已满"),
            TrySendError::Disconnected(_) => DeskError::platform("视频解码已停止"),
        })
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
        self.packet(packet, receipt, false, self.display)
    }

    fn media_video(&mut self, packet: VideoPacket, stream: MediaStreamId, first: bool) -> Result<()> {
        let receipt = DecodeReceipt::Media(stream, packet.sequence);
        if first {
            self.media_display = self.display;
        }
        self.packet(packet, receipt, first, self.media_display)
    }

    fn media_committed(&mut self, stream: MediaStreamId) -> Result<()> {
        self.enqueue(DecodeCommand::Commit(stream))
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

fn decode<S: ViewerSink>(
    packets: std::sync::mpsc::Receiver<DecodeCommand>,
    acknowledgements: mpsc::UnboundedSender<DecodeReceipt>,
    frame: Arc<Mutex<Frame>>,
    sink: Arc<S>,
    stopped: &AtomicBool,
) -> Result<()> {
    let _com = Com::enter();
    let _media = MediaFoundation::start()?;
    let mut legacy_decoder = None;
    let mut legacy_display = None;
    let mut media_decoder = None;
    let mut pending = VecDeque::new();
    let publish = |picture: Picture<'_>, stream, display| {
        {
            let mut visible = frame.lock().unwrap();
            visible.stream = stream;
            visible.display = display;
            visible.update(picture);
            visible.serial += 1;
        }
        sink.frame_ready(stream);
    };
    let mut candidate: Option<(MediaStreamId, Frame)> = None;
    for command in packets {
        if stopped.load(Ordering::Acquire) {
            break;
        }
        let (packet, receipt, first, display, _bytes) = match command {
            DecodeCommand::Packet { packet, receipt, first, display, bytes } => (packet, receipt, first, display, bytes),
            DecodeCommand::Commit(stream) => {
                let Some((_, mut opening)) = candidate.take_if(|(id, _)| *id == stream) else {
                    return Err(DeskError::platform("媒体流缺少已解码的首帧"));
                };
                {
                    let mut visible = frame.lock().unwrap();
                    opening.stream = Some(stream);
                    opening.serial = visible.serial + 1;
                    *visible = opening;
                }
                sink.event(ViewerEvent::MediaCommitted(stream));
                sink.frame_ready(Some(stream));
                continue;
            }
        };
        let annex_b = packet.annex_b()?;
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
                decoder.decode(&annex_b, |picture| publish(picture, None, display))?;
                if acknowledgements.send(receipt).is_err() {
                    break;
                }
                continue;
            }
            DecodeReceipt::Media(stream, _) => stream,
        };

        // A fresh MFT isolates the candidate from buffered pictures and timestamps of retired streams.
        if first {
            media_decoder = Some(H264Decoder::new()?);
            pending.clear();
            candidate = None;
        }
        let decoder = media_decoder.as_mut().expect("the media receiver starts each stream with its opening frame");
        // A buffering transform may need another copy of the same IDR to yield the first picture.
        let copies = if first { 3 } else { 1 };
        for _ in 0..copies {
            pending.push_back((decoder.next_sample_time(), receipt));
            decoder.decode(&annex_b, |picture| {
                let Some(time) = picture.sample_time else { return };
                let Some(position) = pending.iter().position(|(tag, _)| *tag == time) else { return };
                let (_, completed) = pending.remove(position).expect("a picture with this sample time is pending");
                if first {
                    let mut opening = Frame { display, ..Frame::default() };
                    opening.update(picture);
                    candidate = Some((stream, opening));
                    // Later outputs for the same IDR copy have no separate receipt or visible frame.
                    pending.clear();
                } else {
                    publish(picture, Some(stream), display);
                }
                let _ = acknowledgements.send(completed);
            })?;
            if !first || candidate.is_some() {
                break;
            }
        }
        if first && candidate.is_none() {
            return Err(DeskError::platform("H.264 解码器未能输出媒体关键帧"));
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
    // An opening commit shares the decoder thread with the negotiated frame window.
    let (packets, queue) = std::sync::mpsc::sync_channel(window::MAX_DYNAMIC_FRAMES + 1);
    let (acknowledgements, acknowledged) = mpsc::unbounded_channel();
    let (finished, decode_result) = tokio::sync::oneshot::channel();
    let stopped = Arc::new(AtomicBool::new(false));
    let (decode_stop, decode_sink) = (stopped.clone(), sink.clone());
    let decoding = std::thread::Builder::new().name("decode".to_string()).spawn(move || {
        let result = decode(queue, acknowledgements, frame, decode_sink, &decode_stop);
        if let Err(error) = &result {
            log::error!("decoding stopped: {error}");
        }
        let _ = finished.send(result);
    });
    if let Err(error) = decoding {
        return ViewerEnd { reason: format!("无法启动解码线程：{error}"), host_ended: false, retryable: false, local_stop: false };
    }
    let (peer, incoming) = peer::spawn(stream, PeerConfig::default());
    let mut platform =
        WindowsViewer { packets, packet_bytes: Arc::new(tokio::sync::Semaphore::new(window::MAX_BUFFERED_BYTES)), sink, display: None, media_display: None };
    let mut end = attempt.run(peer.clone(), incoming, &mut platform, acknowledged).await;
    stopped.store(true, Ordering::Release);
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
    fn native_decode_queue_limits_encoded_bytes_across_replaced_streams_and_returns_them_on_drop() {
        let (packets, queue) = std::sync::mpsc::sync_channel(window::MAX_DYNAMIC_FRAMES + 1);
        let packet = |sequence| VideoPacket::h264(sequence, EncodedFrame { sps: vec![], pps: vec![], avcc: vec![0; 9] });
        let size = packet(1).encoded_len();
        let packet_bytes = Arc::new(tokio::sync::Semaphore::new(2 * size));
        let mut viewer = WindowsViewer { packets, packet_bytes: packet_bytes.clone(), sink: Arc::new(Silent), display: None, media_display: None };
        let stream = MediaStreamId { session_id: Default::default(), transport_epoch: 1, codec_epoch: 1 };
        viewer.media_video(packet(1), stream, true).unwrap();
        viewer.media_video(packet(2), stream, false).unwrap();
        let next = MediaStreamId { codec_epoch: 2, ..stream };
        assert!(viewer.media_video(packet(3), next, true).is_err());
        drop(queue.recv().unwrap());
        viewer.media_video(packet(3), next, true).unwrap();
        drop(queue);
        assert_eq!(packet_bytes.available_permits(), 2 * size);
        assert!(viewer.media_video(packet(4), next, false).is_err());
        assert_eq!(packet_bytes.available_permits(), 2 * size);
    }

    #[test]
    fn a_late_packet_keeps_the_screen_that_opened_its_stream() {
        let (packets, queue) = std::sync::mpsc::sync_channel(3);
        let mut viewer = WindowsViewer {
            packets,
            packet_bytes: Arc::new(tokio::sync::Semaphore::new(window::MAX_BUFFERED_BYTES)),
            sink: Arc::new(Silent),
            display: None,
            media_display: None,
        };
        let displays = vec![RemoteDisplayInfo::new(8, "左", 1920, 1080, true), RemoteDisplayInfo::new(9, "右", 1920, 1080, false)];
        let selection = |id, revision| ViewerEvent::Displays { displays: displays.clone(), selected: Some(id), pending: None, error: None, revision };
        let packet = |sequence| VideoPacket::h264(sequence, EncodedFrame { sps: vec![], pps: vec![], avcc: vec![] });
        let first = MediaStreamId { session_id: Default::default(), transport_epoch: 1, codec_epoch: 1 };
        viewer.event(selection(8, 0));
        viewer.media_video(packet(1), first, true).unwrap();
        viewer.event(selection(9, 1));
        viewer.media_video(packet(2), first, false).unwrap();
        viewer.media_video(packet(3), MediaStreamId { codec_epoch: 2, ..first }, true).unwrap();
        for expected in [8, 8, 9] {
            let DecodeCommand::Packet { display, .. } = queue.recv().unwrap() else { panic!("expected a packet") };
            assert_eq!(display.unwrap().id, expected);
        }
    }
}
