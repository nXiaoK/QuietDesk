use super::util::failed;
use quietdesk_core::cursor::CursorImage;
use quietdesk_core::error::{DeskError, Result};
use std::sync::Arc;
use windows::Win32::Graphics::Direct2D::{D2D1_DC_INITIALIZE_MODE_COPY, ID2D1GdiInteropRenderTarget, ID2D1HwndRenderTarget};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::Interface;

struct NativeCursor {
    icon: HICON,
    hotspot: (i32, i32),
}

/// Exercises the viewer's cursor creation and the host's GDI readback without setting the system cursor.
#[doc(hidden)]
pub fn read_back_cursor(image: &CursorImage, dpi: u32) -> Result<CursorImage> {
    let native = NativeCursor::new(image, dpi)?;
    super::host_cursor::CursorIcon::raster(HCURSOR(native.icon.0), (dpi, dpi))
}

impl Drop for NativeCursor {
    fn drop(&mut self) {
        unsafe {
            if GetCursor().0 == self.icon.0 {
                SetCursor(LoadCursorW(None, IDC_ARROW).ok());
            }
            let _ = DestroyIcon(self.icon);
        }
    }
}

impl NativeCursor {
    fn new(image: &CursorImage, dpi: u32) -> Result<Self> {
        let pixels = image.rgba()?;
        let scale = f64::from(dpi) / 96.0;
        let width = (image.logical_width * scale).round().max(1.0) as usize;
        let height = (image.logical_height * scale).round().max(1.0) as usize;
        let hotspot = (((image.hot_spot_x * scale).round() as i32).min(width as i32 - 1), ((image.hot_spot_y * scale).round() as i32).min(height as i32 - 1));
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width as i32,
                biHeight: -(height as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        unsafe {
            let mut data = std::ptr::null_mut();
            let color = CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut data, None, 0).map_err(failed("创建光标位图"))?;
            let bgra = std::slice::from_raw_parts_mut(data.cast::<u8>(), width * height * 4);
            let mask_stride = width.div_ceil(16) * 2;
            let mut mask_bits = vec![0u8; mask_stride * height];
            for y in 0..height {
                let source_y = y * usize::from(image.pixel_height) / height;
                for x in 0..width {
                    let source_x = x * usize::from(image.pixel_width) / width;
                    let offset = (source_y * usize::from(image.pixel_width) + source_x) * 4;
                    let alpha = pixels[offset + 3];
                    let target = (y * width + x) * 4;
                    // CreateIconIndirect takes straight-alpha BGRA and prepares the native blend itself.
                    bgra[target..target + 4].copy_from_slice(&[pixels[offset + 2], pixels[offset + 1], pixels[offset], alpha]);
                    if alpha == 0 {
                        mask_bits[y * mask_stride + x / 8] |= 0x80 >> (x % 8);
                    }
                }
            }
            let mask = CreateBitmap(width as i32, height as i32, 1, 1, Some(mask_bits.as_ptr().cast()));
            let result = if mask.is_invalid() {
                Err(DeskError::platform("创建光标掩码失败"))
            } else {
                let icon = CreateIconIndirect(&ICONINFO {
                    fIcon: false.into(),
                    xHotspot: hotspot.0 as u32,
                    yHotspot: hotspot.1 as u32,
                    hbmMask: mask,
                    hbmColor: color,
                });
                let _ = DeleteObject(mask.into());
                icon.map(|icon| Self { icon, hotspot }).map_err(failed("创建远端光标"))
            };
            let _ = DeleteObject(color.into());
            result
        }
    }
}

#[derive(Default)]
pub(super) struct ViewerCursor {
    source: Option<Arc<CursorImage>>,
    dpi: u32,
    cursor: Option<NativeCursor>,
}

impl ViewerCursor {
    pub fn update(&mut self, source: Option<&Arc<CursorImage>>, dpi: u32) {
        let same_image = match (&self.source, source) {
            (Some(a), Some(b)) => Arc::ptr_eq(a, b),
            (None, None) => true,
            _ => false,
        };
        if self.dpi == dpi && same_image {
            return;
        }
        self.source = source.cloned();
        self.dpi = dpi;
        self.cursor = source.and_then(|image| NativeCursor::new(image, dpi).inspect_err(|e| log::warn!("cursor shape unavailable: {e}")).ok());
    }

    pub fn handle(&self) -> Option<HCURSOR> {
        self.cursor.as_ref().map(|c| HCURSOR(c.icon.0)).or_else(|| unsafe { LoadCursorW(None, IDC_ARROW).ok() })
    }

    pub fn draw(&self, target: &ID2D1HwndRenderTarget, rect: (f32, f32, f32, f32), x: f64, y: f64) -> windows::core::Result<()> {
        let Some(cursor) = self.handle() else { return Ok(()) };
        let (left, top, width, height) = rect;
        let (hx, hy) = self.cursor.as_ref().map_or((0, 0), |cursor| cursor.hotspot);
        unsafe {
            let surface = target.cast::<ID2D1GdiInteropRenderTarget>()?;
            let dc = surface.GetDC(D2D1_DC_INITIALIZE_MODE_COPY)?;
            let saved = SaveDC(dc);
            IntersectClipRect(dc, left.ceil() as i32, top.ceil() as i32, (left + width).ceil() as i32, (top + height).ceil() as i32);
            let result = DrawIconEx(
                dc,
                (left + width * x as f32).round() as i32 - hx,
                (top + height * y as f32).round() as i32 - hy,
                cursor.into(),
                0,
                0,
                0,
                None,
                DI_NORMAL,
            );
            let _ = RestoreDC(dc, saved);
            surface.ReleaseDC(None)?;
            result
        }
    }
}
