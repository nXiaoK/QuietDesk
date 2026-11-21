//! The host's capture thread: screen to NV12 to H.264 to the session, paced by the viewer's acknowledgements.

use super::capture::ScreenCapture;
use super::codec::{H264Encoder, MediaFoundation};
use super::util::Com;
use super::{clipboard, inject};
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::host::{FrameSink, HostPlatform};
use quietdesk_core::input::InjectOp;
use quietdesk_core::messages::{StreamSettings, VideoStreamState};
use quietdesk_core::pixel::{Nv12Converter, draw_pointer};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::oneshot;
use windows::Win32::Foundation::RECT;

enum Command {
    Size(Sender<Result<(u32, u32)>>),
    Configure(StreamSettings, FrameSink, oneshot::Sender<Result<VideoStreamState>>),
    Pause(bool, oneshot::Sender<Result<()>>),
}

struct Stream {
    converter: Nv12Converter,
    encoder: H264Encoder,
    nv12: Vec<u8>,
    sink: FrameSink,
    interval: Duration,
    due: Instant,
    /// The viewer has nothing to predict from: the next frame is a keyframe of the screen as it is.
    fresh: bool,
    /// Frames in a row that were encoded while a keyframe was wanted and were not one.
    refused_key_frames: u32,
    /// Frames given to the encoder since the stream last turned fresh, for the log.
    fed: u32,
}

impl Stream {
    /// After a pause or an interrupted capture the viewer's picture is stale: continue with a keyframe.
    fn restart_from_key_frame(&mut self) {
        self.fresh = true;
        self.refused_key_frames = 0;
        self.fed = 0;
        self.encoder.request_key_frame();
    }
}

/// The stream for these settings, at the largest of the standard sizes the encoder accepts.
fn open_stream(source: (usize, usize), settings: StreamSettings, sink: FrameSink) -> Result<(Stream, VideoStreamState)> {
    let edges = [settings.longest_edge, 3840, 2560, 1920, 1280];
    let mut failure = None;
    for edge in edges.into_iter().enumerate().filter(|(index, edge)| *index == 0 || *edge < settings.longest_edge).map(|(_, edge)| edge) {
        let applied = StreamSettings { longest_edge: edge, ..settings };
        let (width, height) = applied.dimensions(source.0 as u32, source.1 as u32);
        match H264Encoder::new(width, height, applied) {
            Ok(encoder) => {
                let converter = Nv12Converter::new(source, (width as usize, height as usize));
                let nv12 = vec![0; converter.output_bytes()];
                let interval = Duration::from_secs_f64(1.0 / applied.frames_per_second.clamp(1, 60) as f64);
                let stream = Stream { converter, encoder, nv12, sink, interval, due: Instant::now(), fresh: true, refused_key_frames: 0, fed: 0 };
                return Ok((stream, VideoStreamState { settings: applied, width: i64::from(width), height: i64::from(height) }));
            }
            Err(error) => {
                log::warn!("H.264 encoder refused {width}x{height}: {error}");
                failure = Some(error);
            }
        }
    }
    Err(failure.unwrap_or_else(|| DeskError::platform("没有可用的 H.264 编码尺寸")))
}

fn run(commands: Receiver<Command>, bounds: Arc<Mutex<RECT>>) {
    let _com = Com::enter();
    let media = MediaFoundation::start();
    let mut capture: Option<ScreenCapture> = None;
    let mut stream: Option<Stream> = None;
    let mut paused = false;
    let open = |capture: &mut Option<ScreenCapture>| -> Result<(usize, usize)> {
        if capture.is_none() {
            let opened = ScreenCapture::open()?;
            *bounds.lock().unwrap() = opened.bounds;
            *capture = Some(opened);
        }
        let capture = capture.as_ref().expect("capture was opened above");
        Ok((capture.width(), capture.height()))
    };
    loop {
        let active = stream.as_ref().filter(|_| !paused);
        // An idle pipeline waits for its next command; a running one only looks for one between frames.
        let command = match active {
            Some(active) if active.sink.has_credit() => commands.recv_timeout(active.due.saturating_duration_since(Instant::now())),
            Some(_) => commands.recv_timeout(Duration::from_millis(2)),
            None => commands.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        match command {
            Ok(Command::Size(reply)) => {
                let _ = reply.send(open(&mut capture).map(|(width, height)| (width as u32, height as u32)));
            }
            Ok(Command::Configure(settings, sink, reply)) => {
                stream = None;
                let opened = match &media {
                    Ok(_) => open(&mut capture).and_then(|source| open_stream(source, settings, sink)),
                    Err(error) => Err(DeskError::platform(error.to_string())),
                };
                let _ = reply.send(opened.map(|(opened, state)| {
                    stream = Some(opened);
                    paused = false;
                    state
                }));
            }
            Ok(Command::Pause(pause, reply)) => {
                paused = pause;
                if let Some(stream) = &mut stream {
                    stream.restart_from_key_frame();
                }
                let _ = reply.send(Ok(()));
            }
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {}
        }
        let (Some(active), Some(screen), false) = (&mut stream, &mut capture, paused) else { continue };
        if !active.sink.has_credit() || Instant::now() < active.due {
            continue;
        }
        let changed = match screen.grab(if active.fresh { 0 } else { 50 }) {
            Ok(changed) => changed,
            Err(error) => {
                // The desktop was switched (lock screen, elevation prompt) or the display mode changed.
                log::warn!("screen capture was interrupted: {error}");
                let size = (screen.width(), screen.height());
                capture = None;
                std::thread::sleep(Duration::from_millis(300));
                match open(&mut capture) {
                    Ok(reopened) if reopened == size => active.restart_from_key_frame(),
                    Ok(_) => {
                        // The session announced another size; ending it lets the viewer connect again.
                        log::warn!("the shared display changed its size, ending the stream");
                        stream = None;
                    }
                    Err(error) => log::warn!("screen capture is not available yet: {error}"),
                }
                continue;
            }
        };
        if !changed && !active.fresh {
            continue;
        }
        let (width, height) = (screen.width(), screen.height());
        let patch = screen.pointer().and_then(|pointer| draw_pointer(&mut screen.frame, width * 4, (width, height), &pointer.shape, pointer.x, pointer.y));
        active.converter.convert(&screen.frame, width * 4, &mut active.nv12);
        if let Some(patch) = patch {
            patch.restore(&mut screen.frame, width * 4);
        }
        let encoded = active.encoder.encode(&active.nv12);
        active.fed += 1;
        // Every attempt uses its frame interval, also one the encoder answers with nothing.
        active.due = Instant::now() + active.interval;
        match encoded {
            Ok(Some(frame)) => {
                // After a pause or a restart only a keyframe may open the stream.
                if !active.fresh || frame.is_key_frame() {
                    if active.fresh {
                        log::info!("the stream opens with a keyframe of {} bytes after {} captured frames", frame.avcc.len(), active.fed);
                    }
                    active.fresh = false;
                    active.refused_key_frames = 0;
                    if !active.sink.submit(frame) {
                        stream = None;
                    }
                } else {
                    // The encoder took the request for a keyframe and still produced a dependent frame.
                    active.refused_key_frames += 1;
                    if active.refused_key_frames >= 3
                        && let Err(error) = active.encoder.restart()
                    {
                        log::error!("the encoder could not be restarted for a keyframe, ending the stream: {error}");
                        stream = None;
                    }
                }
            }
            Ok(None) => {}
            Err(error) => {
                log::error!("encoding failed, ending the stream: {error}");
                stream = None;
            }
        }
    }
}

/// What a host session needs from this PC. Dropping it ends the capture thread.
pub struct WindowsHost {
    commands: Sender<Command>,
    bounds: Arc<Mutex<RECT>>,
}

impl WindowsHost {
    pub fn start() -> Self {
        let (commands, queue) = channel();
        let bounds = Arc::new(Mutex::new(RECT::default()));
        let shared = bounds.clone();
        std::thread::Builder::new().name("capture".to_string()).spawn(move || run(queue, shared)).expect("the capture thread starts");
        Self { commands, bounds }
    }
}

fn stopped() -> DeskError {
    DeskError::platform("屏幕采集线程已停止")
}

impl HostPlatform for WindowsHost {
    fn display_size(&mut self) -> Result<(u32, u32)> {
        let (reply, answer) = channel();
        self.commands.send(Command::Size(reply)).map_err(|_| stopped())?;
        answer.recv_timeout(Duration::from_secs(10)).map_err(|_| stopped())?
    }

    async fn configure(&mut self, settings: StreamSettings, frames: FrameSink) -> Result<VideoStreamState> {
        let (reply, answer) = oneshot::channel();
        self.commands.send(Command::Configure(settings, frames, reply)).map_err(|_| stopped())?;
        answer.await.map_err(|_| stopped())?
    }

    async fn set_paused(&mut self, paused: bool) -> Result<()> {
        let (reply, answer) = oneshot::channel();
        self.commands.send(Command::Pause(paused, reply)).map_err(|_| stopped())?;
        answer.await.map_err(|_| stopped())?
    }

    fn inject(&mut self, operations: &[InjectOp]) {
        inject::inject(operations, *self.bounds.lock().unwrap());
    }

    fn clipboard_text(&mut self) -> Option<String> {
        clipboard::text()
    }

    fn set_clipboard_text(&mut self, text: &str) -> Result<()> {
        clipboard::set_text(text)
    }

    fn stop(&mut self) {}
}
