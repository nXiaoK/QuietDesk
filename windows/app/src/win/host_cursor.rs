//! Samples the system cursor on the shared display and retains its shape across position updates.

use super::capture::DibSurface;
use super::util::failed;
use quietdesk_core::cursor::CursorImage;
use quietdesk_core::cursor_pixels::from_black_and_white;
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::host::HostCursorSample;
use std::sync::Arc;
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

pub(super) struct CursorSampler {
    output: watch::Sender<Option<HostCursorSample>>,
    cached: Option<CachedShape>,
    pub(super) next_poll: Instant,
}

impl CursorSampler {
    pub(super) fn new(output: watch::Sender<Option<HostCursorSample>>, bounds: RECT, paused: bool) -> Result<Self> {
        let info = cursor_info()?;
        let mut sampler = Self { output, cached: None, next_poll: Instant::now() };
        if !paused {
            sampler.publish(Some(info), bounds);
        }
        Ok(sampler)
    }

    pub(super) fn poll(&mut self, bounds: RECT) {
        if Instant::now() >= self.next_poll {
            self.publish(cursor_info().ok(), bounds);
        }
    }

    pub(super) fn display_changed(&mut self, bounds: RECT, paused: bool) {
        self.next_poll = Instant::now();
        if paused {
            self.output.send_replace(None);
        } else {
            self.poll(bounds);
        }
    }

    fn publish(&mut self, info: Option<CURSORINFO>, bounds: RECT) {
        let now = Instant::now();
        self.next_poll = now + Duration::from_nanos(16_666_667);
        let sample = if let Some(info) = info {
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

    #[test]
    fn cursor_coordinates_follow_a_monitor_left_of_and_above_the_primary() {
        let bounds = RECT { left: -1600, top: -200, right: 0, bottom: 700 };
        let point = POINT { x: -1200, y: 250 };
        assert_eq!(icon_origin(point, bounds, (11, 20)), POINT { x: 389, y: 430 });
        assert_eq!(location(point, bounds), (true, 0.25, 0.5));
        assert_eq!(location(POINT { x: 0, y: -200 }, bounds), (false, 1.0, 0.0));
    }
}
