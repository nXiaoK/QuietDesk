//! The pixels of one display: desktop duplication where the system offers it, GDI otherwise.

use super::displays::{self, Display};
use super::host_cursor::CursorIcon;
use super::util::failed;
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::pixel::{PointerKind, PointerShape};
use std::ffi::c_void;
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{HMODULE, POINT};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_MODE_ROTATION_IDENTITY, DXGI_MODE_ROTATION_UNSPECIFIED, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Graphics::Gdi::*;
use windows::core::Interface;

/// A pointer image and where its top-left corner is on the display.
pub struct Pointer {
    pub shape: PointerShape,
    pub x: i32,
    pub y: i32,
}

struct Duplication {
    context: ID3D11DeviceContext,
    duplication: IDXGIOutputDuplication,
    staging: ID3D11Texture2D,
    shape: Option<PointerShape>,
    position: Option<POINT>,
}

struct Gdi {
    screen: HDC,
    surface: DibSurface,
}

/// A top-down 32-bit DIB selected into its own memory DC.
pub(super) struct DibSurface {
    pub(super) dc: HDC,
    bitmap: HBITMAP,
    bits: *mut c_void,
    bytes: usize,
}

impl DibSurface {
    pub(super) fn new(width: i32, height: i32) -> Result<Self> {
        let pixels = i64::from(width) * i64::from(height);
        if width <= 0 || height <= 0 || pixels > isize::MAX as i64 / 4 {
            return Err(DeskError::platform("位图尺寸无效"));
        }
        let bytes = pixels as usize * 4;
        unsafe {
            let dc = CreateCompatibleDC(None);
            if dc.is_invalid() {
                return Err(DeskError::platform("无法创建内存设备上下文"));
            }
            let mut surface = Self { dc, bitmap: HBITMAP::default(), bits: std::ptr::null_mut(), bytes };
            let header = BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width,
                biHeight: -height,
                biPlanes: 1,
                biBitCount: 32,
                ..Default::default()
            };
            let layout = BITMAPINFO { bmiHeader: header, ..Default::default() };
            surface.bitmap = CreateDIBSection(Some(dc), &layout, DIB_RGB_COLORS, &mut surface.bits, None, 0).map_err(failed("创建位图"))?;
            if surface.bits.is_null() || SelectObject(dc, surface.bitmap.into()).is_invalid() {
                return Err(DeskError::platform("无法选入位图"));
            }
            Ok(surface)
        }
    }

    pub(super) fn pixels(&mut self) -> Result<&mut [u8]> {
        unsafe {
            GdiFlush().ok().map_err(failed("读取位图"))?;
            Ok(std::slice::from_raw_parts_mut(self.bits.cast(), self.bytes))
        }
    }
}

impl Drop for DibSurface {
    fn drop(&mut self) {
        unsafe {
            let _ = DeleteDC(self.dc);
            if !self.bitmap.is_invalid() {
                let _ = DeleteObject(self.bitmap.into());
            }
        }
    }
}

impl Drop for Gdi {
    fn drop(&mut self) {
        unsafe { ReleaseDC(None, self.screen) };
    }
}

enum Source {
    Duplication(Duplication),
    Gdi(Gdi),
}

pub struct ScreenCapture {
    source: Source,
    pub(super) display: Display,
    /// Top-down BGRA rows of `width * 4` bytes.
    pub frame: Vec<u8>,
    has_frame: bool,
    independent: bool,
}

// The capture thread is the only user of these handles and COM objects.
unsafe impl Send for ScreenCapture {}

impl ScreenCapture {
    pub fn width(&self) -> usize {
        (self.display.bounds.right - self.display.bounds.left) as usize
    }

    pub fn height(&self) -> usize {
        (self.display.bounds.bottom - self.display.bounds.top) as usize
    }

    pub fn has_frame(&self) -> bool {
        self.has_frame
    }

    /// Opens the primary display.
    pub fn open() -> Result<Self> {
        Self::open_display(displays::preferred(&displays::outputs()?, None))
    }

    fn open_display(display: &Display) -> Result<Self> {
        match Self::open_duplication(display) {
            Ok(capture) => Ok(capture),
            Err(error) => {
                log::warn!("desktop duplication is unavailable, capturing with GDI: {error}");
                Self::open_gdi(display, false)
            }
        }
    }

    pub(super) fn for_cursor_mode(display: &Display, independent: bool) -> Result<Self> {
        let mut screen = Self::open_display(display)?;
        if independent {
            if matches!(screen.source, Source::Duplication(_)) {
                screen.grab_source(100, false, &mut Duration::default())?;
            }
            screen.set_cursor_mode(true)?;
        }
        Ok(screen)
    }

    /// A mode switch on a still desktop also needs a fresh surface. BitBlt supplies the clean
    /// opening picture while a duplication that reports a hardware pointer keeps future capture on DXGI.
    pub(super) fn set_cursor_mode(&mut self, independent: bool) -> Result<()> {
        if matches!(self.source, Source::Duplication(_))
            && self.grab_source(0, true, &mut Duration::default())?
            && matches!(&self.source, Source::Duplication(source) if !independent || source.position.is_some())
        {
            self.independent = independent;
            return Ok(());
        }
        let keep_duplication = matches!(&self.source, Source::Duplication(source) if !independent || source.position.is_some());
        if keep_duplication {
            let clean = Self::open_gdi(&self.display, true)?.first_picture()?;
            self.frame = clean.frame;
            self.has_frame = true;
            self.independent = independent;
        } else {
            let next = if independent { Self::open_gdi(&self.display, true)? } else { Self::open_display(&self.display)? };
            *self = next.first_picture()?;
        }
        Ok(())
    }

    fn first_picture(self) -> Result<Self> {
        self.first_picture_timed(&mut Duration::default())
    }

    fn first_picture_timed(mut self, waited: &mut Duration) -> Result<Self> {
        self.grab_source(250, true, waited)?;
        if !self.has_frame {
            return Err(DeskError::platform("尚未收到所选显示器的桌面画面"));
        }
        Ok(self)
    }

    pub(super) fn ready(self) -> Result<Self> {
        if self.has_frame {
            return Ok(self);
        }
        let fallback = matches!(self.source, Source::Duplication(_)).then(|| (self.display.clone(), self.independent));
        match self.first_picture() {
            Err(error) if let Some((display, independent)) = fallback => {
                log::warn!("desktop duplication did not produce an opening picture, trying GDI: {error}");
                Self::open_gdi(&display, independent)?.first_picture()
            }
            result => result,
        }
    }

    fn open_duplication(display: &Display) -> Result<Self> {
        unsafe {
            let factory: IDXGIFactory1 = CreateDXGIFactory1().map_err(failed("创建 DXGI 工厂"))?;
            let mut adapter_index = 0;
            while let Ok(adapter) = factory.EnumAdapters1(adapter_index) {
                adapter_index += 1;
                let mut output_index = 0;
                while let Ok(output) = adapter.EnumOutputs(output_index) {
                    output_index += 1;
                    let description = output.GetDesc().map_err(failed("读取显示器信息"))?;
                    let bounds = description.DesktopCoordinates;
                    if !description.AttachedToDesktop.as_bool() || description.Monitor != display.monitor() || bounds != display.bounds {
                        continue;
                    }
                    let (mut device, mut context) = (None, None);
                    D3D11CreateDevice(
                        &adapter,
                        D3D_DRIVER_TYPE_UNKNOWN,
                        HMODULE::default(),
                        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                        None,
                        D3D11_SDK_VERSION,
                        Some(&mut device),
                        None,
                        Some(&mut context),
                    )
                    .map_err(failed("创建 Direct3D 设备"))?;
                    let (device, context) =
                        (device.ok_or_else(|| DeskError::platform("没有 Direct3D 设备"))?, context.ok_or_else(|| DeskError::platform("没有 Direct3D 上下文"))?);
                    let duplication = output.cast::<IDXGIOutput1>().map_err(failed("读取显示器接口"))?.DuplicateOutput(&device).map_err(failed("复制桌面"))?;
                    let mode = duplication.GetDesc();
                    if mode.Rotation != DXGI_MODE_ROTATION_IDENTITY && mode.Rotation != DXGI_MODE_ROTATION_UNSPECIFIED {
                        return Err(DeskError::platform("显示器已旋转，改用 GDI 采集"));
                    }
                    let (width, height) = ((bounds.right - bounds.left) as u32, (bounds.bottom - bounds.top) as u32);
                    if (mode.ModeDesc.Width, mode.ModeDesc.Height) != (width, height) {
                        return Err(DeskError::platform("DXGI 桌面帧尺寸与显示器不符"));
                    }
                    let layout = D3D11_TEXTURE2D_DESC {
                        Width: width,
                        Height: height,
                        MipLevels: 1,
                        ArraySize: 1,
                        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                        Usage: D3D11_USAGE_STAGING,
                        CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                        ..Default::default()
                    };
                    let mut staging = None;
                    device.CreateTexture2D(&layout, None, Some(&mut staging)).map_err(failed("创建回读纹理"))?;
                    let staging = staging.ok_or_else(|| DeskError::platform("没有回读纹理"))?;
                    let source = Source::Duplication(Duplication { context, duplication, staging, shape: None, position: None });
                    return Ok(Self { source, display: display.clone(), frame: vec![0; (width * height * 4) as usize], has_frame: false, independent: false });
                }
            }
        }
        Err(DeskError::platform("没有找到所选显示器的 DXGI 输出"))
    }

    fn open_gdi(display: &Display, independent: bool) -> Result<Self> {
        unsafe {
            let bounds = display.bounds;
            let (width, height) = (bounds.right - bounds.left, bounds.bottom - bounds.top);
            let surface = DibSurface::new(width, height)?;
            let frame = vec![0; surface.bytes];
            let screen = GetDC(None);
            if screen.is_invalid() {
                return Err(DeskError::platform("无法获取桌面设备上下文"));
            }
            let source = Source::Gdi(Gdi { screen, surface });
            Ok(Self { source, display: display.clone(), frame, has_frame: false, independent })
        }
    }

    /// Waits up to `wait_milliseconds` for the screen or pointer to change. `Ok(true)` means `frame` or the
    /// pointer differs from the last call; an error means the capture has to be opened again.
    pub fn grab(&mut self, wait_milliseconds: u32) -> Result<bool> {
        self.grab_timed(wait_milliseconds, &mut Duration::default())
    }

    pub(super) fn backend(&self) -> &'static str {
        match self.source {
            Source::Duplication(_) => "dxgi",
            Source::Gdi(_) => "gdi",
        }
    }

    pub(super) fn grab_timed(&mut self, wait_milliseconds: u32, waited: &mut Duration) -> Result<bool> {
        let changed = self.grab_source(wait_milliseconds, false, waited)?;
        // An adapter can switch from hardware overlay to a pointer baked into its desktop surface.
        if self.independent && matches!(&self.source, Source::Duplication(source) if source.position.is_none()) {
            *self = Self::open_gdi(&self.display, true)?.first_picture_timed(waited)?;
            return Ok(true);
        }
        Ok(changed)
    }

    fn grab_source(&mut self, wait_milliseconds: u32, refresh_surface: bool, waited: &mut Duration) -> Result<bool> {
        let (width, height) = (self.width(), self.height());
        let first = !self.has_frame || refresh_surface;
        match &mut self.source {
            Source::Duplication(source) => unsafe {
                let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
                let mut resource = None;
                let start = Instant::now();
                let acquired = source.duplication.AcquireNextFrame(wait_milliseconds, &mut info, &mut resource);
                *waited += start.elapsed();
                match acquired {
                    Ok(()) => {}
                    Err(error) if error.code() == DXGI_ERROR_WAIT_TIMEOUT => return Ok(false),
                    Err(error) => return Err(failed("获取桌面画面")(error)),
                }
                let mut changed = false;
                if info.LastMouseUpdateTime != 0 {
                    source.position = info.PointerPosition.Visible.as_bool().then_some(info.PointerPosition.Position);
                    changed = !self.independent;
                }
                if info.PointerShapeBufferSize > 0 {
                    let mut data = vec![0u8; info.PointerShapeBufferSize as usize];
                    let (mut used, mut shape) = (0, DXGI_OUTDUPL_POINTER_SHAPE_INFO::default());
                    if source.duplication.GetFramePointerShape(data.len() as u32, data.as_mut_ptr().cast(), &mut used, &mut shape).is_ok() {
                        let kind = match shape.Type {
                            1 => Some(PointerKind::Monochrome),
                            2 => Some(PointerKind::Color),
                            4 => Some(PointerKind::MaskedColor),
                            _ => None,
                        };
                        let rows = if kind == Some(PointerKind::Monochrome) { shape.Height / 2 } else { shape.Height };
                        let image =
                            kind.map(|kind| PointerShape { kind, width: shape.Width as usize, height: rows as usize, pitch: shape.Pitch as usize, data });
                        source.shape = image.filter(PointerShape::is_complete);
                    }
                }
                let copied = if info.LastPresentTime != 0 || first {
                    resource.and_then(|resource| resource.cast::<ID3D11Texture2D>().ok()).map(|texture| {
                        source.context.CopyResource(&source.staging, &texture);
                        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
                        source.context.Map(&source.staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).map(|()| {
                            for row in 0..height {
                                let line = std::slice::from_raw_parts((mapped.pData as *const u8).add(row * mapped.RowPitch as usize), width * 4);
                                self.frame[row * width * 4..][..width * 4].copy_from_slice(line);
                            }
                            source.context.Unmap(&source.staging, 0);
                        })
                    })
                } else {
                    None
                };
                source.duplication.ReleaseFrame().map_err(failed("释放桌面画面"))?;
                match copied {
                    Some(Ok(())) => {
                        self.has_frame = true;
                        Ok(true)
                    }
                    Some(Err(error)) => Err(failed("读取桌面画面")(error)),
                    None => Ok(changed && !refresh_surface),
                }
            },
            Source::Gdi(source) => unsafe {
                if wait_milliseconds != 0 {
                    let start = Instant::now();
                    std::thread::sleep(Duration::from_millis(u64::from(wait_milliseconds.min(15))));
                    *waited += start.elapsed();
                }
                let bounds = self.display.bounds;
                BitBlt(source.surface.dc, 0, 0, width as i32, height as i32, Some(source.screen), bounds.left, bounds.top, SRCCOPY | CAPTUREBLT)
                    .map_err(failed("复制屏幕"))?;
                if !self.display.still_at_bounds() {
                    return Err(DeskError::platform("共享显示器的位置或尺寸已改变"));
                }
                if !self.independent {
                    CursorIcon::draw_embedded(source.surface.dc, bounds);
                }
                let captured = source.surface.pixels()?;
                if !first && captured == &self.frame[..] {
                    return Ok(false);
                }
                self.frame.copy_from_slice(captured);
                self.has_frame = true;
                Ok(true)
            },
        }
    }

    /// The pointer to draw over `frame`, when the capture delivers it separately.
    pub fn pointer(&self) -> Option<Pointer> {
        if self.independent {
            return None;
        }
        let Source::Duplication(source) = &self.source else { return None };
        // Desktop duplication reports where the shape's top-left corner is, not where its hot spot is.
        let position = source.position?;
        Some(Pointer { shape: source.shape.clone()?, x: position.x, y: position.y })
    }
}
