//! The host's capture thread: screen to NV12 to H.264 to the session, paced by the viewer's acknowledgements.

use super::capture::ScreenCapture;
use super::codec::{H264Encoder, H264HardwareEncoder, MediaFoundation};
use super::displays::{self, Display};
use super::gesture_host::GestureHost;
use super::gpu_video::GpuScaler;
use super::host_cursor::{CursorTarget, CursorWorker};
use super::util::{Com, failed};
use super::video_stats::VideoStats;
use super::{clipboard, inject};
use quietdesk_core::display::{DisplaySwitch, HostDisplays};
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::host::{FrameSink, FrameSubmission, HostCursorSample, HostPlatform, InputActionOutcome};
use quietdesk_core::input::InjectOp;
use quietdesk_core::messages::{InputAction, StreamSettings, VideoStreamState};
use quietdesk_core::pixel::{Nv12Converter, draw_pointer};
use quietdesk_core::video::EncodedFrame;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{oneshot, watch};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_NV12, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::IDXGIDevice;
use windows::core::Interface;

enum Command {
    Size(Sender<Result<(u32, u32)>>),
    Displays(oneshot::Sender<Result<HostDisplays>>),
    SwitchDisplay(u32, StreamSettings, FrameSink, oneshot::Sender<Result<DisplaySwitch>>),
    Configure(StreamSettings, FrameSink, oneshot::Sender<Result<VideoStreamState>>),
    Bitrate(i64, oneshot::Sender<Result<()>>),
    Pause(bool, oneshot::Sender<Result<()>>),
    KeyFrame(oneshot::Sender<Result<()>>),
    Cursor(Option<watch::Sender<Option<HostCursorSample>>>, oneshot::Sender<Result<()>>),
}

struct CaptureCadence {
    interval: Duration,
    due: Instant,
}

impl CaptureCadence {
    fn wait(&self, now: Instant) -> Duration {
        self.due.saturating_duration_since(now)
    }

    fn take_slot(&mut self, now: Instant) -> bool {
        if now < self.due {
            return false;
        }
        // Capture and encoding share the interval. A late start schedules only one capture.
        self.due = now + self.interval;
        true
    }
}

struct PictureConversion {
    cpu: Nv12Converter,
    gpu: Option<GpuScaler>,
    gpu_unavailable: bool,
    gpu_picture: bool,
    size: (u32, u32),
    fps: u32,
    nv12: Vec<u8>,
}

impl PictureConversion {
    fn new(source: (usize, usize), size: (u32, u32), fps: u32) -> Self {
        let cpu = Nv12Converter::new(source, (size.0 as usize, size.1 as usize));
        let nv12 = vec![0; cpu.output_bytes()];
        Self { cpu, gpu: None, gpu_unavailable: false, gpu_picture: false, size, fps, nv12 }
    }

    fn prepare(&mut self, screen: &mut ScreenCapture) -> Result<()> {
        if self.gpu_unavailable || self.gpu.is_some() {
            return Ok(());
        }
        let Some(device) = screen.gpu_scaling_device() else { return Ok(()) };
        let source = (screen.width() as u32, screen.height() as u32);
        match GpuScaler::new(device, source, self.size, self.fps).and_then(|scaler| {
            screen.enable_gpu_capture()?;
            Ok(scaler)
        }) {
            Ok(scaler) => self.gpu = Some(scaler),
            Err(error) => {
                self.gpu_unavailable = true;
                log::info!("GPU scaling is unavailable; using CPU conversion: {error}");
                screen.disable_gpu_capture()?;
            }
        }
        Ok(())
    }

    fn convert(&mut self, screen: &mut ScreenCapture, hardware: bool) -> Result<()> {
        self.gpu_picture = false;
        if let Some(texture) = screen.gpu_frame() {
            let scaler = self.gpu.as_mut().expect("GPU capture follows scaler setup");
            match scaler.convert(texture).and_then(|()| if hardware { Ok(()) } else { scaler.read_nv12(&mut self.nv12) }) {
                Ok(()) => {
                    self.gpu_picture = hardware;
                    return Ok(());
                }
                Err(error) => {
                    log::warn!("GPU scaling failed; using CPU conversion: {error}");
                    self.gpu = None;
                    self.gpu_unavailable = true;
                    screen.disable_gpu_capture()?;
                }
            }
        }
        let (width, height) = (screen.width(), screen.height());
        let patch = screen.pointer().and_then(|pointer| draw_pointer(&mut screen.frame, width * 4, (width, height), &pointer.shape, pointer.x, pointer.y));
        self.cpu.convert(&screen.frame, width * 4, &mut self.nv12);
        if let Some(patch) = patch {
            patch.restore(&mut screen.frame, width * 4);
        }
        Ok(())
    }
}

struct HardwareVideo {
    encoder: H264HardwareEncoder,
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    flush_cpu_upload: bool,
}

impl HardwareVideo {
    fn new(device: &ID3D11Device, width: u32, height: u32, settings: StreamSettings) -> Result<Self> {
        let context = unsafe { device.GetImmediateContext() }.map_err(failed("读取硬件编码设备上下文"))?;
        let adapter = unsafe { device.cast::<IDXGIDevice>().and_then(|device| device.GetAdapter()).and_then(|adapter| adapter.GetDesc()) }
            .map_err(failed("读取硬件编码显卡"))?;
        let encoder = H264HardwareEncoder::new(width, height, settings, device)?;
        Ok(Self { encoder, device: device.clone(), context, flush_cpu_upload: adapter.VendorId == 0x10de })
    }

    fn submit(&mut self, picture: &PictureConversion) -> Result<bool> {
        let size = picture.size;
        let desc = D3D11_TEXTURE2D_DESC {
            Width: size.0,
            Height: size.1,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_NV12,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_VIDEO_ENCODER.0 as u32,
            ..Default::default()
        };
        let initial = D3D11_SUBRESOURCE_DATA { pSysMem: picture.nv12.as_ptr().cast(), SysMemPitch: size.0, ..Default::default() };
        let mut texture = None;
        unsafe { self.device.CreateTexture2D(&desc, (!picture.gpu_picture).then_some(&initial as *const _), Some(&mut texture)) }
            .map_err(failed("创建硬件编码输入纹理"))?;
        let texture = texture.ok_or_else(|| DeskError::platform("没有硬件编码输入纹理"))?;
        if picture.gpu_picture {
            // The transform may still own the submitted texture at the next desktop update.
            let scaled = picture.gpu.as_ref().expect("GPU picture was produced by a scaler").texture();
            unsafe { self.context.CopyResource(&texture, scaled) };
        } else if self.flush_cpu_upload {
            // The NVIDIA transform can access a CPU-initialized texture before its upload is submitted.
            unsafe { self.context.Flush() };
        }
        self.encoder.submit(&texture)
    }
}

enum Encoder {
    Hardware(Box<HardwareVideo>),
    Software(H264Encoder),
}

struct Stream {
    stats: Option<VideoStats>,
    picture: PictureConversion,
    encoder: Encoder,
    settings: StreamSettings,
    sink: FrameSink,
    cadence: CaptureCadence,
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
    fn set_bitrate(&mut self, megabits: i64) -> Result<()> {
        match &mut self.encoder {
            Encoder::Hardware(hardware) => hardware.encoder.set_bitrate(megabits),
            Encoder::Software(software) => software.set_bitrate(megabits),
        }?;
        self.settings.megabits = megabits;
        Ok(())
    }

    fn use_software(&mut self, error: &DeskError) -> Result<()> {
        let (width, height) = self.picture.size;
        log::warn!("H.264 hardware encoding stopped; resuming with software at {width}x{height}: {error}");
        self.encoder = Encoder::Software(H264Encoder::new(width, height, self.settings)?);
        self.cadence.due = Instant::now();
        self.restart_from_key_frame(false)
    }

    fn can_capture(&self) -> bool {
        let slots = self.sink.available_credit();
        match &self.encoder {
            Encoder::Software(_) => slots != 0,
            Encoder::Hardware(hardware) => {
                let slots = if self.fresh { slots.min(1) } else { slots };
                hardware.encoder.can_submit() && (hardware.encoder.pending() as usize) < slots
            }
        }
    }

    fn video_wait(&self, now: Instant) -> Duration {
        let mut wait = if self.can_capture() { self.cadence.wait(now) } else { Duration::from_millis(2) };
        if let Encoder::Hardware(hardware) = &self.encoder
            && (hardware.encoder.pending() != 0 || !hardware.encoder.can_submit())
        {
            wait = wait.min(Duration::from_millis(2));
        }
        wait
    }

    fn output(&mut self, outputs: &mut Vec<EncodedFrame>) -> FrameSubmission {
        let stats = self.stats.as_mut().expect("statistics begin before video encoding");
        let mut submission = FrameSubmission::Queued;
        for frame in outputs.drain(..) {
            if submission != FrameSubmission::Queued {
                // A rejected reference frame may be needed by later outputs of this encoding call.
                stats.output(FrameSubmission::Dropped);
                continue;
            }
            if self.fresh && !frame.is_key_frame() {
                stats.output(FrameSubmission::Dropped);
                self.refused_key_frames += 1;
                continue;
            }
            let bytes = frame.avcc.len();
            submission = self.sink.try_submit(frame);
            stats.output(submission);
            if self.fresh && submission == FrameSubmission::Queued {
                log::info!("the stream opens with a keyframe of {bytes} bytes after {} captured frames", self.fed);
                if let Encoder::Software(software) = &self.encoder
                    && software.pending() > 0
                {
                    log::warn!("the encoder holds {} frames back; the picture is repeated after each change to let it out", software.pending());
                }
                self.fresh = false;
                self.refused_key_frames = 0;
            }
        }
        submission
    }

    /// After a pause or an interrupted capture the viewer's picture is stale: continue with a keyframe.
    fn restart_from_key_frame(&mut self, discard_software_pending: bool) -> Result<()> {
        self.fresh = true;
        self.refused_key_frames = 0;
        self.fed = 0;
        self.flush = 0;
        match &mut self.encoder {
            Encoder::Hardware(hardware) => {
                if hardware.encoder.pending() > 0 {
                    // Never let an older in-flight IDR open this gate after a pause or route change.
                    hardware.encoder.restart(self.settings, &hardware.device)?;
                }
                hardware.encoder.request_key_frame();
            }
            Encoder::Software(software) => {
                if discard_software_pending && software.pending() > 0 {
                    software.restart()?;
                }
                software.request_key_frame();
            }
        }
        Ok(())
    }

    fn request_key_frame(&mut self, discard_software_pending: bool, hardware_allowed: &mut bool) -> Result<()> {
        match self.restart_from_key_frame(discard_software_pending) {
            Err(error) if matches!(self.encoder, Encoder::Hardware(_)) => {
                *hardware_allowed = false;
                self.use_software(&error)
            }
            result => result,
        }
    }
}

fn request_stream_key_frame(stream: &mut Option<Stream>, discard_software_pending: bool, hardware_allowed: &mut bool) -> Result<()> {
    let result = stream.as_mut().ok_or_else(stopped)?.request_key_frame(discard_software_pending, hardware_allowed);
    if result.is_err() {
        *stream = None;
    }
    result
}

/// The stream for these settings, at the largest of the standard sizes the encoder accepts.
fn open_stream(screen: &ScreenCapture, settings: StreamSettings, sink: FrameSink, hardware_allowed: bool) -> Result<(Stream, VideoStreamState)> {
    let source = (screen.width(), screen.height());
    let edges = [settings.longest_edge, 3840, 2560, 1920, 1280];
    let mut failure = None;
    for edge in edges.into_iter().enumerate().filter(|(index, edge)| *index == 0 || *edge < settings.longest_edge).map(|(_, edge)| edge) {
        let applied = StreamSettings { longest_edge: edge, ..settings };
        let (width, height) = applied.dimensions(source.0 as u32, source.1 as u32);
        match H264Encoder::new(width, height, applied) {
            Ok(encoder) => {
                let mut encoder = Encoder::Software(encoder);
                if let Some(device) = screen.gpu_device().filter(|_| hardware_allowed) {
                    match HardwareVideo::new(device, width, height, applied) {
                        Ok(hardware) => {
                            log::info!("H.264 hardware encoding selected for {width}x{height}");
                            encoder = Encoder::Hardware(Box::new(hardware));
                        }
                        Err(error) => log::info!("H.264 hardware encoding unavailable; using software: {error}"),
                    }
                }
                let picture = PictureConversion::new(source, (width, height), applied.frames_per_second.clamp(1, 60) as u32);
                let interval = Duration::from_secs_f64(1.0 / applied.frames_per_second.clamp(1, 60) as f64);
                let cadence = CaptureCadence { interval, due: Instant::now() };
                let stream = Stream { stats: None, picture, encoder, settings: applied, sink, cadence, fresh: true, refused_key_frames: 0, fed: 0, flush: 0 };
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
    let mut outputs = Vec::new();
    let mut sampler: Option<CursorWorker> = None;
    let mut paused = false;
    let mut selected = None;
    let mut hardware_allowed = true;
    let open = |capture: &mut Option<ScreenCapture>, selected: &mut Option<u32>, cursor: Option<&CursorWorker>, paused: bool| -> Result<(usize, usize)> {
        if capture.is_none() {
            let outputs = displays::outputs()?;
            let target = displays::preferred(&outputs, selected.or(preferred));
            if selected.is_some_and(|id| id != target.info.id) {
                return Err(DeskError::platform("原共享显示器已断开，正在重新选择"));
            }
            let opened = ScreenCapture::for_cursor_mode(target, cursor.is_some())?;
            if let Some(cursor) = cursor
                && !paused
            {
                cursor.set_target(CursorTarget::Active(opened.display.bounds))?;
            }
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
        let video_wait = active.map(|active| active.video_wait(now));
        let command = match video_wait {
            Some(wait) => commands.recv_timeout(wait),
            None => commands.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        match command {
            Ok(Command::Size(reply)) => {
                let _ = reply.send(open(&mut capture, &mut selected, sampler.as_ref(), paused).map(|(width, height)| (width as u32, height as u32)));
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
                        let screen = replacement.as_ref().or(capture.as_ref()).expect("the target capture was opened above");
                        let new_stream = open_stream(screen, settings, sink, hardware_allowed)?;
                        if !display.still_at_bounds() {
                            return Err(DeskError::platform("准备采集期间显示器布局已改变"));
                        }
                        Ok((replacement, new_stream, display.clone()))
                    })();
                    match opened {
                        Ok((replacement, (new_stream, state), display)) => {
                            if let Some(sampler) = &sampler {
                                let target = if paused { CursorTarget::Unavailable } else { CursorTarget::Active(display.bounds) };
                                sampler.set_target(target)?;
                            }
                            if let Some(replacement) = replacement {
                                capture = Some(replacement);
                            }
                            selected = Some(id);
                            stream = Some(new_stream);
                            *input_display.lock().unwrap() = Some(display);
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
                    Ok(_) => open(&mut capture, &mut selected, sampler.as_ref(), paused).and_then(|_| {
                        let screen = capture.as_ref().expect("capture was opened above");
                        open_stream(screen, settings, sink, hardware_allowed)
                    }),
                    Err(error) => Err(DeskError::platform(error.to_string())),
                };
                let _ = reply.send(opened.map(|(opened, state)| {
                    stream = Some(opened);
                    state
                }));
            }
            Ok(Command::Bitrate(megabits, reply)) => {
                let result = stream.as_mut().ok_or_else(stopped).and_then(|stream| stream.set_bitrate(megabits));
                let _ = reply.send(result);
            }
            Ok(Command::Pause(pause, reply)) => {
                let result = (|| {
                    if stream.is_some() {
                        request_stream_key_frame(&mut stream, false, &mut hardware_allowed)?;
                    }
                    if let Some(sampler) = &sampler {
                        let target = match (pause, &capture) {
                            (true, _) => CursorTarget::Paused,
                            (false, Some(screen)) => CursorTarget::Active(screen.display.bounds),
                            (false, None) => CursorTarget::Unavailable,
                        };
                        sampler.set_target(target)?;
                    }
                    paused = pause;
                    Ok(())
                })();
                let _ = reply.send(result);
            }
            Ok(Command::KeyFrame(reply)) => {
                let result = request_stream_key_frame(&mut stream, true, &mut hardware_allowed);
                let _ = reply.send(result);
            }
            Ok(Command::Cursor(output, reply)) => {
                let result = (|| {
                    let screen = capture.as_mut().ok_or_else(stopped)?;
                    let target = if paused { CursorTarget::Paused } else { CursorTarget::Active(screen.display.bounds) };
                    let next_sampler = match (sampler.as_ref(), output) {
                        (Some(sampler), Some(output)) => return sampler.rebind(output, target),
                        (None, Some(output)) => Some(CursorWorker::start(output, target)?),
                        (_, None) => None,
                    };
                    if next_sampler.is_some() != sampler.is_some() {
                        if stream.is_some() {
                            request_stream_key_frame(&mut stream, false, &mut hardware_allowed)?;
                        }
                        screen.set_cursor_mode(next_sampler.is_some())?;
                    }
                    sampler = next_sampler;
                    Ok(())
                })();
                let _ = reply.send(result);
            }
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {}
        }
        let (Some(active), Some(screen), false) = (&mut stream, &mut capture, paused) else {
            if let Some(active) = &mut stream {
                active.stats = None;
            }
            continue;
        };
        let now = Instant::now();
        active.stats.get_or_insert_with(|| VideoStats::new(now, screen.backend())).report_if_due(now, screen.backend());
        if let Encoder::Hardware(hardware) = &mut active.encoder {
            // Poll even when capture has no frame credit or the desktop has stopped changing.
            match hardware.encoder.poll(&mut outputs) {
                Ok(()) => {
                    if let Some(elapsed) = hardware.encoder.take_encode_elapsed() {
                        active.sink.record_encode_time(elapsed);
                    }
                    match active.output(&mut outputs) {
                        FrameSubmission::Closed => {
                            stream = None;
                            continue;
                        }
                        FrameSubmission::Dropped => {
                            if let Err(error) = active.request_key_frame(false, &mut hardware_allowed) {
                                log::error!("the encoder could not restart after backpressure: {error}");
                                stream = None;
                            }
                            continue;
                        }
                        FrameSubmission::Queued => {}
                    }
                }
                Err(error) => {
                    outputs.clear();
                    hardware_allowed = false;
                    if let Err(error) = active.use_software(&error) {
                        log::error!("the software encoder could not resume the stream: {error}");
                        stream = None;
                        continue;
                    }
                }
            }
        }
        if !active.can_capture() || !active.cadence.take_slot(Instant::now()) {
            continue;
        }
        let hardware = matches!(active.encoder, Encoder::Hardware(_));
        let stats = active.stats.as_mut().expect("statistics were started above");
        let current = match active.picture.prepare(screen).and_then(|()| {
            let start = Instant::now();
            let mut waited = Duration::ZERO;
            let captured = screen.grab_timed(0, &mut waited);
            stats.captured(screen.backend(), start.elapsed(), waited, matches!(captured, Ok(true)));
            let changed = captured?;
            if !screen.has_frame() || !(changed || active.fresh) {
                return Ok(false);
            }
            let start = Instant::now();
            active.picture.convert(screen, hardware)?;
            stats.convert.record(start.elapsed());
            Ok(true)
        }) {
            Ok(current) => current,
            Err(error) => {
                // The desktop was switched (lock screen, elevation prompt) or the display mode changed.
                log::warn!("screen capture was interrupted: {error}");
                capture = None;
                *input_display.lock().unwrap() = None;
                if let Some(sampler) = &sampler {
                    let _ = sampler.set_target(CursorTarget::Unavailable);
                }
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
        if !current && active.flush == 0 {
            continue;
        }
        let start = Instant::now();
        if let Encoder::Hardware(hardware) = &mut active.encoder {
            match hardware.submit(&active.picture) {
                Ok(true) => {
                    stats.encoded(start.elapsed(), !current);
                    active.fed += 1;
                }
                Ok(false) => {}
                Err(error) => {
                    hardware_allowed = false;
                    if let Err(error) = active.use_software(&error) {
                        log::error!("the software encoder could not resume the stream: {error}");
                        stream = None;
                    }
                }
            }
            continue;
        }
        let Encoder::Software(software) = &mut active.encoder else { unreachable!() };
        let encoded = software.encode(&active.picture.nv12, &mut outputs);
        let elapsed = start.elapsed();
        stats.encoded(elapsed, !current);
        if encoded.is_ok() {
            active.sink.record_encode_time(elapsed);
        }
        if let Err(error) = encoded {
            log::error!("encoding failed, ending the stream: {error}");
            stream = None;
            continue;
        }
        active.fed += 1;
        // A one-in-one-out encoder holds nothing and needs no repeats. One that delays its output would
        // keep the newest picture, and the pointer in it, until the screen changes again.
        active.flush = if current { software.pending() } else { active.flush - 1 };
        let produced = !outputs.is_empty();
        match active.output(&mut outputs) {
            FrameSubmission::Dropped => {
                if let Err(error) = active.request_key_frame(false, &mut hardware_allowed) {
                    log::error!("the encoder could not restart after backpressure: {error}");
                    stream = None;
                }
            }
            FrameSubmission::Closed => stream = None,
            FrameSubmission::Queued => {
                if produced
                    && active.refused_key_frames >= 3
                    && let Encoder::Software(software) = &mut active.encoder
                    && let Err(error) = software.restart()
                {
                    log::error!("the encoder could not be restarted for a keyframe, ending the stream: {error}");
                    stream = None;
                }
            }
        }
    }
}

/// What a host session needs from this PC. Dropping it ends the capture thread.
pub struct WindowsHost {
    commands: Sender<Command>,
    buttons: inject::MouseButtons,
    gestures: GestureHost,
    input_display: Arc<Mutex<Option<Display>>>,
}

impl WindowsHost {
    fn input_bounds(&self) -> Option<windows::Win32::Foundation::RECT> {
        self.input_display.lock().unwrap().as_ref().filter(|d| d.still_at_bounds()).map(|d| d.bounds)
    }

    pub fn start(preferred: Option<u32>) -> Self {
        Self::start_notifying(preferred, || false)
    }

    pub(super) fn start_notifying(preferred: Option<u32>, capture_lost: impl Fn() -> bool + Send + 'static) -> Self {
        let (commands, queue) = channel();
        let input_display = Arc::new(Mutex::new(None));
        let shared = input_display.clone();
        std::thread::Builder::new().name("capture".to_string()).spawn(move || run(queue, shared, preferred, capture_lost)).expect("the capture thread starts");
        Self { commands, buttons: inject::MouseButtons::default(), gestures: GestureHost::new(), input_display }
    }
}

fn stopped() -> DeskError {
    DeskError::platform("屏幕采集线程已停止")
}

async fn display_topology(commands: &Sender<Command>) -> Result<HostDisplays> {
    let (reply, answer) = oneshot::channel();
    commands.send(Command::Displays(reply)).map_err(|_| stopped())?;
    tokio::time::timeout(Duration::from_secs(10), answer).await.map_err(|_| stopped())?.map_err(|_| stopped())?
}

impl HostPlatform for WindowsHost {
    fn supports_audio_capture(&self) -> bool {
        true
    }
    fn start_audio_capture(&mut self, epoch: std::num::NonZeroU32, redundant: bool, paused: bool) -> Result<quietdesk_core::audio_session::AudioCapture> {
        super::audio::start_capture(epoch, redundant, paused)
    }
    fn open_clipboard(&mut self, enabled: bool) -> Option<quietdesk_core::clipboard_session::SessionClipboard> {
        super::app::open_clipboard(quietdesk_core::clipboard::Role::Host, enabled)
    }

    fn supports_trackpad_gestures(&self) -> bool {
        self.gestures.available()
    }

    fn gesture_check_at(&self) -> Option<tokio::time::Instant> {
        self.gestures.check_at()
    }

    fn check_gestures(&mut self) {
        self.gestures.check(self.input_bounds());
    }

    fn supports_relative_mouse(&self) -> bool {
        true
    }

    fn supports_input_actions(&self) -> bool {
        inject::supports_input_actions()
    }

    fn input_action(&mut self, action: InputAction) -> impl Future<Output = Result<InputActionOutcome>> + Send + 'static {
        let display = self.input_display.clone();
        inject::input_action(action, move || display.lock().unwrap().as_ref().is_some_and(Display::still_at_bounds))
    }

    async fn displays(&mut self) -> Result<Option<HostDisplays>> {
        display_topology(&self.commands).await.map(Some)
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

    fn supports_adaptive_video(&self) -> bool {
        true
    }

    async fn set_bitrate(&mut self, megabits: i64) -> Result<()> {
        let (reply, answer) = oneshot::channel();
        self.commands.send(Command::Bitrate(megabits, reply)).map_err(|_| stopped())?;
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
        inject::inject(operations, self.input_bounds(), &mut self.buttons, &mut self.gestures)
    }

    fn clipboard_text(&mut self) -> Option<String> {
        clipboard::text()
    }

    fn set_clipboard_text(&mut self, text: &str) -> Result<()> {
        clipboard::set_text(text)
    }

    fn stop(&mut self) {
        self.gestures.cancel();
        self.buttons.release_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_cadence_counts_processing_time_and_skips_missed_slots() {
        let start = Instant::now();
        let interval = Duration::from_nanos(16_666_667);
        let work = Duration::from_millis(8);
        let mut cadence = CaptureCadence { interval, due: start };
        assert!(cadence.take_slot(start));
        assert_eq!(cadence.wait(start + work), interval - work);
        assert!(!cadence.take_slot(start + work));
        assert!(cadence.take_slot(start + interval));

        let resumed = start + 4 * interval;
        assert!(cadence.take_slot(resumed));
        assert!(!cadence.take_slot(resumed + work));
        assert!(cadence.take_slot(resumed + interval));
    }

    #[tokio::test]
    async fn slow_display_enumeration_yields_the_network_thread_and_preserves_worker_errors() {
        let (commands, capture) = channel();
        let query = display_topology(&commands);
        tokio::pin!(query);
        tokio::select! {
            biased;
            _ = &mut query => panic!("the capture worker has not replied"),
            () = tokio::task::yield_now() => {}
        }
        let Ok(Command::Displays(reply)) = capture.try_recv() else { panic!("missing topology request") };
        reply.send(Err(DeskError::platform("synthetic display failure"))).unwrap();
        assert!(query.await.unwrap_err().to_string().contains("synthetic display failure"));
    }
}
