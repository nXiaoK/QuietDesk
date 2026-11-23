//! Samples the system cursor on the shared display and retains its shape across position updates.

use super::capture::DibSurface;
use super::util::failed;
use quietdesk_core::cursor::CursorImage;
use quietdesk_core::cursor_pixels::from_black_and_white;
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::host::HostCursorSample;
use std::sync::Arc;
use std::sync::mpsc::{self, RecvTimeoutError, Sender, SyncSender};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use tokio::sync::watch;
use windows::Win32::Foundation::{POINT, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::*;

pub(super) fn cursor_info() -> Result<CURSORINFO> {
    let mut info = CURSORINFO { cbSize: size_of::<CURSORINFO>() as u32, ..Default::default() };
    unsafe { GetCursorInfo(&mut info) }.map_err(failed("读取系统光标"))?;
    Ok(info)
}

pub(super) struct CursorIcon(ICONINFO);

fn icon_origin(point: POINT, bounds: RECT, hotspot: (u32, u32)) -> POINT {
    POINT { x: point.x - bounds.left - hotspot.0 as i32, y: point.y - bounds.top - hotspot.1 as i32 }
}

pub(super) fn location(point: POINT, bounds: RECT) -> (bool, f64, f64) {
    let inside = (bounds.left..bounds.right).contains(&point.x) && (bounds.top..bounds.bottom).contains(&point.y);
    let fraction = |pixel: i32, origin: i32, end: i32| ((f64::from(pixel) - f64::from(origin)) / (f64::from(end) - f64::from(origin))).clamp(0.0, 1.0);
    (inside, fraction(point.x, bounds.left, bounds.right), fraction(point.y, bounds.top, bounds.bottom))
}

impl CursorIcon {
    fn new(handle: HCURSOR) -> Result<Self> {
        let mut icon = ICONINFO::default();
        unsafe { GetIconInfo(handle.into(), &mut icon) }.map_err(failed("读取光标位图"))?;
        Ok(Self(icon))
    }

    pub(super) fn draw_embedded(dc: HDC, bounds: RECT) {
        if let Ok(info) = cursor_info()
            && info.flags == CURSOR_SHOWING
            && let Ok(icon) = Self::new(info.hCursor)
        {
            let origin = icon_origin(info.ptScreenPos, bounds, (icon.0.xHotspot, icon.0.yHotspot));
            unsafe {
                let _ = DrawIconEx(dc, origin.x, origin.y, info.hCursor.into(), 0, 0, 0, None, DI_NORMAL);
            }
        }
    }

    pub(super) fn raster(handle: HCURSOR, dpi: (u32, u32)) -> Result<CursorImage> {
        let icon = Self::new(handle)?;
        let monochrome = icon.0.hbmColor.is_invalid();
        let bitmap = if monochrome { icon.0.hbmMask } else { icon.0.hbmColor };
        let mut description = BITMAP::default();
        let read = unsafe { GetObjectW(bitmap.into(), size_of::<BITMAP>() as i32, Some(std::ptr::from_mut(&mut description).cast())) };
        if read != size_of::<BITMAP>() as i32 {
            return Err(DeskError::platform("无法读取光标尺寸"));
        }
        // A monochrome mask stacks its AND and XOR planes vertically.
        let (width, height) = (description.bmWidth, if monochrome { description.bmHeight / 2 } else { description.bmHeight });
        if !(1..=256).contains(&width) || !(1..=256).contains(&height) {
            return Err(DeskError::platform("光标超过支持的像素尺寸"));
        }
        let mut surface = DibSurface::new(width, height)?;
        let mut draw = |background| -> Result<Vec<u8>> {
            surface.pixels()?.fill(background);
            unsafe { DrawIconEx(surface.dc, 0, 0, handle.into(), width, height, 0, None, DI_NORMAL) }.map_err(failed("绘制光标形状"))?;
            Ok(surface.pixels()?.to_vec())
        };
        let black = draw(0)?;
        let white = draw(255)?;
        let rgba = from_black_and_white(width as u16, &black, &white).ok_or_else(|| DeskError::platform("光标像素布局无效"))?;
        let (sx, sy) = (96.0 / f64::from(dpi.0), 96.0 / f64::from(dpi.1));
        CursorImage::from_rgba(
            width as u16,
            height as u16,
            f64::from(width) * sx,
            f64::from(height) * sy,
            f64::from(icon.0.xHotspot) * sx,
            f64::from(icon.0.yHotspot) * sy,
            &rgba,
        )
    }
}

impl Drop for CursorIcon {
    fn drop(&mut self) {
        unsafe {
            let _ = DeleteObject(self.0.hbmMask.into());
            if !self.0.hbmColor.is_invalid() {
                let _ = DeleteObject(self.0.hbmColor.into());
            }
        }
    }
}

struct CachedShape {
    handle: HCURSOR,
    dpi: (u32, u32),
    image: Option<Arc<CursorImage>>,
    retry: Instant,
}

#[derive(Clone, Copy)]
pub(super) enum CursorTarget {
    Active(RECT),
    Paused,
    Unavailable,
}

enum CursorCommand {
    Bind(watch::Sender<Option<HostCursorSample>>, CursorTarget, Sender<Result<()>>),
    Target(CursorTarget, Sender<Result<()>>),
    Stop,
}

/// A session owns a single sampling thread while independent cursor display is enabled.
pub(super) struct CursorWorker {
    commands: SyncSender<CursorCommand>,
    thread: Option<JoinHandle<()>>,
}

impl CursorWorker {
    pub(super) fn start(output: watch::Sender<Option<HostCursorSample>>, target: CursorTarget) -> Result<Self> {
        Self::spawn(output, target, cursor_info)
    }

    fn spawn(
        output: watch::Sender<Option<HostCursorSample>>,
        mut target: CursorTarget,
        read_cursor: impl Fn() -> Result<CURSORINFO> + Send + 'static,
    ) -> Result<Self> {
        let (commands, incoming) = mpsc::sync_channel(0);
        let (started, ready) = mpsc::channel();
        let thread = thread::Builder::new()
            .name("cursor".into())
            .spawn(move || {
                let mut sampler = match CursorSampler::new(output, target, &read_cursor) {
                    Ok(sampler) => sampler,
                    Err(error) => {
                        let _ = started.send(Err(error));
                        return;
                    }
                };
                if started.send(Ok(())).is_err() {
                    return;
                }
                loop {
                    let command = match target {
                        CursorTarget::Active(bounds) => match incoming.recv_timeout(sampler.next_poll.saturating_duration_since(Instant::now())) {
                            Err(RecvTimeoutError::Timeout) => {
                                sampler.sample(bounds, &read_cursor);
                                continue;
                            }
                            result => result,
                        },
                        _ => incoming.recv().map_err(|_| RecvTimeoutError::Disconnected),
                    };
                    match command {
                        Ok(CursorCommand::Bind(output, scope, reply)) => {
                            let result = CursorSampler::new(output, scope, &read_cursor).map(|next| {
                                sampler = next;
                                target = scope;
                            });
                            let _ = reply.send(result);
                        }
                        Ok(CursorCommand::Target(scope, reply)) => {
                            target = scope;
                            match target {
                                CursorTarget::Active(bounds) => sampler.sample(bounds, &read_cursor),
                                CursorTarget::Paused => {}
                                CursorTarget::Unavailable => sampler.publish(None),
                            }
                            let _ = reply.send(Ok(()));
                        }
                        Ok(CursorCommand::Stop) | Err(_) => return,
                    }
                }
            })
            .map_err(|error| DeskError::platform(format!("无法启动光标采集线程：{error}")))?;
        let worker = Self { commands, thread: Some(thread) };
        ready.recv().map_err(|_| stopped())??;
        Ok(worker)
    }

    pub(super) fn set_target(&self, target: CursorTarget) -> Result<()> {
        self.request(|reply| CursorCommand::Target(target, reply))
    }

    pub(super) fn rebind(&self, output: watch::Sender<Option<HostCursorSample>>, target: CursorTarget) -> Result<()> {
        self.request(|reply| CursorCommand::Bind(output, target, reply))
    }

    fn request(&self, command: impl FnOnce(Sender<Result<()>>) -> CursorCommand) -> Result<()> {
        let (reply, answer) = mpsc::channel();
        self.commands.send(command(reply)).map_err(|_| stopped())?;
        answer.recv().map_err(|_| stopped())?
    }
}

impl Drop for CursorWorker {
    fn drop(&mut self) {
        let _ = self.commands.send(CursorCommand::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn stopped() -> DeskError {
    DeskError::platform("光标采集已停止")
}

struct CursorSampler {
    output: watch::Sender<Option<HostCursorSample>>,
    cached: Option<CachedShape>,
    next_poll: Instant,
}

impl CursorSampler {
    fn new(output: watch::Sender<Option<HostCursorSample>>, target: CursorTarget, read_cursor: impl FnOnce() -> Result<CURSORINFO>) -> Result<Self> {
        let info = read_cursor()?;
        let mut sampler = Self { output, cached: None, next_poll: Instant::now() };
        if let CursorTarget::Active(bounds) = target {
            sampler.publish(Some((info, bounds)));
        }
        Ok(sampler)
    }

    fn sample(&mut self, bounds: RECT, read_cursor: impl FnOnce() -> Result<CURSORINFO>) {
        self.publish(read_cursor().ok().map(|info| (info, bounds)));
    }

    fn publish(&mut self, observation: Option<(CURSORINFO, RECT)>) {
        let now = Instant::now();
        self.next_poll = now + Duration::from_nanos(16_666_667);
        let sample = if let Some((info, bounds)) = observation {
            let (inside, x, y) = location(info.ptScreenPos, bounds);
            let inside_display = info.flags == CURSOR_SHOWING && inside;
            let image = if inside_display { self.image(&info, now) } else { None };
            HostCursorSample { image, inside_display, x, y }
        } else {
            HostCursorSample { image: None, inside_display: false, x: 0.0, y: 0.0 }
        };
        self.output.send_if_modified(|slot| {
            if let Some(previous) = slot
                && previous.inside_display == sample.inside_display
                && previous.x == sample.x
                && previous.y == sample.y
                && match (&previous.image, &sample.image) {
                    (Some(a), Some(b)) => Arc::ptr_eq(a, b),
                    (None, None) => true,
                    _ => false,
                }
            {
                return false;
            }
            *slot = Some(sample);
            true
        });
    }

    fn image(&mut self, info: &CURSORINFO, now: Instant) -> Option<Arc<CursorImage>> {
        let monitor = unsafe { MonitorFromPoint(info.ptScreenPos, MONITOR_DEFAULTTONULL) };
        let (mut x, mut y) = (0, 0);
        unsafe { GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut x, &mut y) }.ok()?;
        if x == 0 || y == 0 {
            return None;
        }
        let dpi = (x, y);
        if let Some(cached) = &self.cached
            && cached.handle == info.hCursor
            && cached.dpi == dpi
            && (cached.image.is_some() || now < cached.retry)
        {
            return cached.image.clone();
        }
        let image = CursorIcon::raster(info.hCursor, dpi).ok().map(Arc::new);
        self.cached = Some(CachedShape { handle: info.hCursor, dpi, image: image.clone(), retry: now + Duration::from_secs(1) });
        image
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicI32, Ordering};

    #[test]
    fn cursor_coordinates_follow_a_monitor_left_of_and_above_the_primary() {
        let bounds = RECT { left: -1600, top: -200, right: 0, bottom: 700 };
        let point = POINT { x: -1200, y: 250 };
        assert_eq!(icon_origin(point, bounds, (11, 20)), POINT { x: 389, y: 430 });
        assert_eq!(location(point, bounds), (true, 0.25, 0.5));
        assert_eq!(location(POINT { x: 0, y: -200 }, bounds), (false, 1.0, 0.0));
    }

    #[tokio::test]
    async fn cursor_worker_polls_independently_and_preserves_the_active_binding() {
        let (sender, mut updates) = watch::channel(None);
        let position = Arc::new(AtomicI32::new(10));
        let read_position = position.clone();
        let caller = thread::current().id();
        let bounds = RECT { left: 0, top: 0, right: 100, bottom: 100 };
        let worker = CursorWorker::spawn(sender, CursorTarget::Active(bounds), move || {
            assert_ne!(thread::current().id(), caller);
            let x = read_position.load(Ordering::Relaxed);
            if x < 0 {
                return Err(DeskError::platform("synthetic cursor failure"));
            }
            Ok(CURSORINFO { ptScreenPos: POINT { x, y: 25 }, ..Default::default() })
        })
        .unwrap();

        position.store(25, Ordering::Relaxed);
        let _ = tokio::time::timeout(Duration::from_secs(2), updates.wait_for(|sample| sample.as_ref().is_some_and(|sample| sample.x == 0.25)))
            .await
            .unwrap()
            .unwrap();
        worker.set_target(CursorTarget::Paused).unwrap();
        std::mem::drop(updates.borrow_and_update());
        position.store(50, Ordering::Relaxed);
        assert!(tokio::time::timeout(Duration::from_millis(60), updates.changed()).await.is_err());

        let (replacement, replacement_updates) = watch::channel(None);
        position.store(-1, Ordering::Relaxed);
        assert!(worker.rebind(replacement, CursorTarget::Paused).is_err());
        assert!(replacement_updates.has_changed().is_err());
        position.store(100, Ordering::Relaxed);
        worker.set_target(CursorTarget::Active(RECT { left: 50, right: 150, ..bounds })).unwrap();
        assert_eq!(updates.borrow().as_ref().unwrap().x, 0.5);
        worker.set_target(CursorTarget::Unavailable).unwrap();
        {
            let hidden = updates.borrow();
            let cursor = hidden.as_ref().unwrap();
            assert_eq!((cursor.inside_display, cursor.x, cursor.y), (false, 0.0, 0.0));
        }
        drop(worker);
        assert!(updates.has_changed().is_err());
    }
}
