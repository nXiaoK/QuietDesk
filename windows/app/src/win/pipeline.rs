//! The host's capture thread: screen to NV12 to H.264 to the session, paced by the viewer's acknowledgements.

use super::capture::ScreenCapture;
use super::codec::{H264Encoder, MediaFoundation};
use super::displays::{self, Display};
use super::host_cursor::CursorSampler;
use super::util::Com;
use super::{clipboard, inject};
use quietdesk_core::display::{DisplaySwitch, HostDisplays};
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::host::{FrameSink, HostCursorSample, HostPlatform, InputActionOutcome};
use quietdesk_core::input::InjectOp;
use quietdesk_core::messages::{InputAction, StreamSettings, VideoStreamState};
use quietdesk_core::pixel::{Nv12Converter, draw_pointer};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{oneshot, watch};
use windows::Win32::Foundation::RECT;

enum Command {
    Size(Sender<Result<(u32, u32)>>),
    Displays(Sender<Result<HostDisplays>>),
    SwitchDisplay(u32, StreamSettings, FrameSink, oneshot::Sender<Result<DisplaySwitch>>),
    Configure(StreamSettings, FrameSink, oneshot::Sender<Result<VideoStreamState>>),
    Pause(bool, oneshot::Sender<Result<()>>),
    KeyFrame(oneshot::Sender<Result<()>>),
    Cursor(Option<watch::Sender<Option<HostCursorSample>>>, oneshot::Sender<Result<()>>),
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
    /// Repeats of the current picture still to feed, so an encoder that holds frames back lets it out.
    flush: u32,
}

impl Stream {
    /// After a pause or an interrupted capture the viewer's picture is stale: continue with a keyframe.
    fn restart_from_key_frame(&mut self) {
        self.fresh = true;
        self.refused_key_frames = 0;
        self.fed = 0;
        self.flush = 0;
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
                let stream = Stream { converter, encoder, nv12, sink, interval, due: Instant::now(), fresh: true, refused_key_frames: 0, fed: 0, flush: 0 };
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

fn run(commands: Receiver<Command>, input_display: Arc<Mutex<Option<Display>>>, preferred: Option<u32>, capture_lost: impl Fn() -> bool) {
    let _com = Com::enter();
    let media = MediaFoundation::start();
    let mut capture: Option<ScreenCapture> = None;
    let mut stream: Option<Stream> = None;
    let mut sampler: Option<CursorSampler> = None;
    let mut paused = false;
    let mut selected = None;
    let open = |capture: &mut Option<ScreenCapture>, selected: &mut Option<u32>, independent| -> Result<(usize, usize)> {
        if capture.is_none() {
            let outputs = displays::outputs()?;
            let target = displays::preferred(&outputs, selected.or(preferred));
            if selected.is_some_and(|id| id != target.info.id) {
                return Err(DeskError::platform("原共享显示器已断开，正在重新选择"));
            }
            let opened = ScreenCapture::for_cursor_mode(target, independent)?;
            *selected = Some(target.info.id);
            *input_display.lock().unwrap() = Some(opened.display.clone());
            *capture = Some(opened);
        }
        let capture = capture.as_ref().expect("capture was opened above");
        Ok((capture.width(), capture.height()))
    };
    loop {
        let active = stream.as_ref().filter(|_| !paused && capture.is_some());
        let now = Instant::now();
        let video_wait = active.map(|active| if active.sink.has_credit() { active.due.saturating_duration_since(now) } else { Duration::from_millis(2) });
        let cursor_wait = sampler.as_ref().filter(|_| !paused && capture.is_some()).map(|cursor| cursor.next_poll.saturating_duration_since(now));
        let command = match video_wait.into_iter().chain(cursor_wait).min() {
            Some(wait) => commands.recv_timeout(wait),
            None => commands.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        match command {
            Ok(Command::Size(reply)) => {
                let _ = reply.send(open(&mut capture, &mut selected, sampler.is_some()).map(|(width, height)| (width as u32, height as u32)));
            }
            Ok(Command::Displays(reply)) => {
                let snapshot = displays::outputs().map(|outputs| {
                    let target = displays::preferred(&outputs, selected.or(preferred));
                    let selected_display_id = target.info.id;
                    let needs_restart = match &capture {
                        Some(current) => !current.display.same_surface(target),
                        None => stream.is_some(),
                    };
                    HostDisplays { selected_display_id, needs_restart, displays: displays::directory(outputs, Some(selected_display_id)) }
                });
                let _ = reply.send(snapshot);
            }
            Ok(Command::SwitchDisplay(id, settings, sink, reply)) => {
                let result = (|| {
                    let outputs = displays::outputs()?;
                    let opened: Result<_> = (|| {
                        let display = outputs.iter().find(|d| d.info.id == id).ok_or_else(|| DeskError::platform("所选显示器已断开"))?;
                        let replacement = if capture.as_ref().is_some_and(|s| s.display.same_surface(display)) {
                            None
                        } else {
                            Some(ScreenCapture::for_cursor_mode(display, sampler.is_some())?.ready()?)
                        };
                        let area = display.bounds;
                        let new_stream = open_stream(((area.right - area.left) as usize, (area.bottom - area.top) as usize), settings, sink)?;
                        if !display.still_at_bounds() {
                            return Err(DeskError::platform("准备采集期间显示器布局已改变"));
                        }
                        Ok((replacement, new_stream, display.clone()))
                    })();
                    match opened {
                        Ok((replacement, (new_stream, state), display)) => {
                            if let Some(replacement) = replacement {
                                capture = Some(replacement);
                            }
                            selected = Some(id);
                            stream = Some(new_stream);
                            let area = display.bounds;
                            *input_display.lock().unwrap() = Some(display);
                            if let Some(sampler) = &mut sampler {
                                sampler.display_changed(area, paused);
                            }
                            Ok(DisplaySwitch::Applied(state))
                        }
                        Err(error) if capture.as_ref().is_some_and(|s| s.display.still_at_bounds() && outputs.iter().any(|d| d.same_surface(&s.display))) => {
                            Ok(DisplaySwitch::Retained(error.to_string()))
                        }
                        Err(error) => Err(error),
                    }
                })();
                let _ = reply.send(result);
            }
            Ok(Command::Configure(settings, sink, reply)) => {
                stream = None;
                let opened = match &media {
                    Ok(_) => open(&mut capture, &mut selected, sampler.is_some()).and_then(|source| open_stream(source, settings, sink)),
                    Err(error) => Err(DeskError::platform(error.to_string())),
                };
                let _ = reply.send(opened.map(|(opened, state)| {
                    stream = Some(opened);
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
            Ok(Command::KeyFrame(reply)) => {
                let result = stream.as_mut().ok_or_else(stopped).and_then(|stream| {
                    // A delayed IDR from the old configuration could otherwise open the new stream.
                    if stream.encoder.pending() > 0 {
                        stream.encoder.restart()?;
                    }
                    stream.restart_from_key_frame();
                    Ok(())
                });
                let _ = reply.send(result);
            }
            Ok(Command::Cursor(output, reply)) => {
                let result = (|| {
                    let independent = output.is_some();
                    let screen = capture.as_mut().ok_or_else(stopped)?;
                    let next_sampler = output.map(|tx| CursorSampler::new(tx, screen.display.bounds, paused)).transpose()?;
                    if independent != sampler.is_some() {
                        screen.set_cursor_mode(independent)?;
                        if let Some(stream) = &mut stream {
                            stream.restart_from_key_frame();
                        }
                    }
                    sampler = next_sampler;
                    Ok(())
                })();
                let _ = reply.send(result);
            }
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {}
        }
        if !paused && let (Some(sampler), Some(screen)) = (&mut sampler, &capture) {
            sampler.poll(screen.display.bounds);
        }
        let (Some(active), Some(screen), false) = (&mut stream, &mut capture, paused) else { continue };
        if !active.sink.has_credit() || Instant::now() < active.due {
            continue;
        }
        let use_cached = screen.has_frame() && (active.fresh || active.flush > 0);
        let changed = match screen.grab(if use_cached { 0 } else { 50 }) {
            Ok(changed) => changed,
            Err(error) => {
                // The desktop was switched (lock screen, elevation prompt) or the display mode changed.
                log::warn!("screen capture was interrupted: {error}");
                capture = None;
                *input_display.lock().unwrap() = None;
                // Keep the sink alive while the session reconciles the current display topology.
                if !capture_lost() {
                    stream = None;
                }
                continue;
            }
        };
        // Desktop duplication can time out before delivering the very first surface.
        if !screen.has_frame() {
            continue;
        }
        let current = changed || active.fresh;
        if !current && active.flush == 0 {
            continue;
        }
        if current {
            let (width, height) = (screen.width(), screen.height());
            let patch = screen.pointer().and_then(|pointer| draw_pointer(&mut screen.frame, width * 4, (width, height), &pointer.shape, pointer.x, pointer.y));
            active.converter.convert(&screen.frame, width * 4, &mut active.nv12);
            if let Some(patch) = patch {
                patch.restore(&mut screen.frame, width * 4);
            }
        }
        let encoded = active.encoder.encode(&active.nv12);
        active.fed += 1;
        // A one-in-one-out encoder holds nothing and needs no repeats. One that delays its output would
        // keep the newest picture, and the pointer in it, until the screen changes again.
        active.flush = if current { active.encoder.pending() } else { active.flush - 1 };
        // Every attempt uses its frame interval, also one the encoder answers with nothing.
        active.due = Instant::now() + active.interval;
        match encoded {
            Ok(Some(frame)) => {
                // After a pause or a restart only a keyframe may open the stream.
                if !active.fresh || frame.is_key_frame() {
                    if active.fresh {
                        log::info!("the stream opens with a keyframe of {} bytes after {} captured frames", frame.avcc.len(), active.fed);
                        if active.encoder.pending() > 0 {
                            log::warn!("the encoder holds {} frames back; the picture is repeated after each change to let it out", active.encoder.pending());
                        }
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
    input_display: Arc<Mutex<Option<Display>>>,
}

impl WindowsHost {
    pub fn start(preferred: Option<u32>) -> Self {
        Self::start_notifying(preferred, || false)
    }

    pub(super) fn start_notifying(preferred: Option<u32>, capture_lost: impl Fn() -> bool + Send + 'static) -> Self {
        let (commands, queue) = channel();
        let input_display = Arc::new(Mutex::new(None));
        let shared = input_display.clone();
        std::thread::Builder::new().name("capture".to_string()).spawn(move || run(queue, shared, preferred, capture_lost)).expect("the capture thread starts");
        Self { commands, input_display }
    }
}

fn stopped() -> DeskError {
    DeskError::platform("屏幕采集线程已停止")
}

impl HostPlatform for WindowsHost {
    fn supports_input_actions(&self) -> bool {
        inject::supports_input_actions()
    }

    fn input_action(&mut self, action: InputAction) -> impl Future<Output = Result<InputActionOutcome>> + Send + 'static {
        let display = self.input_display.clone();
        inject::input_action(action, move || display.lock().unwrap().as_ref().is_some_and(Display::still_at_bounds))
    }

    fn displays(&mut self) -> Result<Option<HostDisplays>> {
        let (reply, answer) = channel();
        self.commands.send(Command::Displays(reply)).map_err(|_| stopped())?;
        answer.recv_timeout(Duration::from_secs(10)).map_err(|_| stopped())?.map(Some)
    }

    async fn switch_display(&mut self, id: u32, settings: StreamSettings, sink: FrameSink) -> Result<DisplaySwitch> {
        let (reply, answer) = oneshot::channel();
        self.commands.send(Command::SwitchDisplay(id, settings, sink, reply)).map_err(|_| stopped())?;
        answer.await.map_err(|_| stopped())?
    }

    fn supports_independent_cursor(&self) -> bool {
        true
    }

    async fn configure_cursor(&mut self, samples: Option<watch::Sender<Option<HostCursorSample>>>) -> Result<()> {
        let (reply, answer) = oneshot::channel();
        self.commands.send(Command::Cursor(samples, reply)).map_err(|_| stopped())?;
        answer.await.map_err(|_| stopped())?
    }

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

    async fn request_key_frame(&mut self) -> Result<()> {
        let (reply, answer) = oneshot::channel();
        self.commands.send(Command::KeyFrame(reply)).map_err(|_| stopped())?;
        answer.await.map_err(|_| stopped())?
    }

    fn inject(&mut self, operations: &[InjectOp]) -> bool {
        let area = self.input_display.lock().unwrap().as_ref().filter(|d| d.still_at_bounds()).map(|d| d.bounds);
        if let Some(area) = area {
            inject::inject(operations, area)
        } else {
            // Clearing held inputs still works after the captured monitor disappears.
            for op in operations.iter().filter(|op| matches!(op, InjectOp::Key { down: false, .. } | InjectOp::Button { down: false, .. })) {
                inject::inject(std::slice::from_ref(op), RECT::default());
            }
            false
        }
    }

    fn clipboard_text(&mut self) -> Option<String> {
        clipboard::text()
    }

    fn set_clipboard_text(&mut self, text: &str) -> Result<()> {
        clipboard::set_text(text)
    }

    fn stop(&mut self) {}
}
