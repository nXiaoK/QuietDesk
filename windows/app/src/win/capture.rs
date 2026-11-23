//! The pixels of one display: desktop duplication where the system offers it, GDI otherwise.

use super::displays::{self, Display};
use super::host_cursor::{CursorIcon, cursor_info, location};
use super::util::failed;
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::pixel::{PointerKind, PointerShape};
use std::ffi::c_void;
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{HMODULE, POINT, RECT};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_MODE_ROTATION_IDENTITY, DXGI_MODE_ROTATION_UNSPECIFIED, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::{CURSOR_SHOWING, CURSORINFO};
use windows::core::Interface;

/// A pointer image and where its top-left corner is on the display.
pub struct Pointer {
    pub shape: PointerShape,
    pub x: i32,
    pub y: i32,
}

struct Duplication {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    duplication: IDXGIOutputDuplication,
    staging: ID3D11Texture2D,
    gpu: Option<GpuCapture>,
    shape: Option<PointerShape>,
    position: Option<POINT>,
    fallback: Option<Gdi>,
    frame_from_gdi: bool,
}

struct GpuCapture {
    texture: ID3D11Texture2D,
    current: bool,
}

impl Duplication {
    fn read_bgra(&self, frame: &mut [u8], row_bytes: usize) -> Result<()> {
        unsafe {
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            self.context.Map(&self.staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).map_err(failed("读取桌面画面"))?;
            let pitch = mapped.RowPitch as usize;
            if pitch < row_bytes || mapped.pData.is_null() {
                self.context.Unmap(&self.staging, 0);
                return Err(DeskError::platform("GPU 返回的 BGRA 布局无效"));
            }
            for (row, target) in frame.chunks_exact_mut(row_bytes).enumerate() {
                let line = std::slice::from_raw_parts(mapped.pData.cast::<u8>().add(row * pitch), row_bytes);
                target.copy_from_slice(line);
            }
            self.context.Unmap(&self.staging, 0);
            Ok(())
        }
    }
}

struct Gdi {
    screen: HDC,
    surface: DibSurface,
}

impl Gdi {
    fn open(bounds: RECT) -> Result<Self> {
        let surface = DibSurface::new(bounds.right - bounds.left, bounds.bottom - bounds.top)?;
        let screen = unsafe { GetDC(None) };
        if screen.is_invalid() {
            return Err(DeskError::platform("无法获取桌面设备上下文"));
        }
        Ok(Self { screen, surface })
    }

    fn grab(&mut self, display: &Display, independent: bool, first: bool, frame: &mut [u8]) -> Result<bool> {
        let bounds = display.bounds;
        unsafe {
            BitBlt(
                self.surface.dc,
                0,
                0,
                bounds.right - bounds.left,
                bounds.bottom - bounds.top,
                Some(self.screen),
                bounds.left,
                bounds.top,
                SRCCOPY | CAPTUREBLT,
            )
            .map_err(failed("复制屏幕"))?;
        }
        if !display.still_at_bounds() {
            return Err(DeskError::platform("共享显示器的位置或尺寸已改变"));
        }
        if !independent {
            CursorIcon::draw_embedded(self.surface.dc, bounds);
        }
        let captured = self.surface.pixels()?;
        if !first && captured == frame {
            return Ok(false);
        }
        frame.copy_from_slice(captured);
        Ok(true)
    }
}

fn needs_cursorless_capture(independent: bool, dxgi_pointer: Option<POINT>, bounds: RECT, system_cursor: impl FnOnce() -> Option<CURSORINFO>) -> bool {
    independent && dxgi_pointer.is_none() && system_cursor().is_some_and(|info| info.flags == CURSOR_SHOWING && location(info.ptScreenPos, bounds).0)
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
            screen.set_cursor_mode(true)?;
        }
        Ok(screen)
    }

    /// A mode switch on a still desktop also needs a fresh surface.
    pub(super) fn set_cursor_mode(&mut self, independent: bool) -> Result<()> {
        if !independent && matches!(self.source, Source::Gdi(_)) {
            *self = Self::open_display(&self.display)?.ready()?;
        } else {
            self.grab_source(0, true, independent, &mut Duration::default())?;
            self.independent = independent;
        }
        Ok(())
    }

    fn first_picture(self) -> Result<Self> {
        let mut capture = self;
        if !capture.grab_source(250, true, capture.independent, &mut Duration::default())? {
            return Err(DeskError::platform("尚未收到所选显示器的桌面画面"));
        }
        Ok(capture)
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
                    let mut create = |flags| {
                        D3D11CreateDevice(
                            &adapter,
                            D3D_DRIVER_TYPE_UNKNOWN,
                            HMODULE::default(),
                            flags,
                            None,
                            D3D11_SDK_VERSION,
                            Some(&mut device),
                            None,
                            Some(&mut context),
                        )
                    };
                    create(D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT)
                        .or_else(|_| create(D3D11_CREATE_DEVICE_BGRA_SUPPORT))
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
                    let source = Source::Duplication(Duplication {
                        device,
                        context,
                        duplication,
                        staging,
                        gpu: None,
                        shape: None,
                        position: None,
                        fallback: None,
                        frame_from_gdi: false,
                    });
                    return Ok(Self { source, display: display.clone(), frame: vec![0; (width * height * 4) as usize], has_frame: false, independent: false });
                }
            }
        }
        Err(DeskError::platform("没有找到所选显示器的 DXGI 输出"))
    }

    fn open_gdi(display: &Display, independent: bool) -> Result<Self> {
        let gdi = Gdi::open(display.bounds)?;
        let frame = vec![0; gdi.surface.bytes];
        Ok(Self { source: Source::Gdi(gdi), display: display.clone(), frame, has_frame: false, independent })
    }

    /// Waits up to `wait_milliseconds` for the screen or pointer to change. `Ok(true)` means `frame` or the
    /// pointer differs from the last call; an error means the capture has to be opened again.
    pub fn grab(&mut self, wait_milliseconds: u32) -> Result<bool> {
        self.grab_timed(wait_milliseconds, &mut Duration::default())
    }

    pub(super) fn backend(&self) -> &'static str {
        match self.source {
            Source::Duplication(ref source) if !source.frame_from_gdi => "dxgi",
            _ => "gdi",
        }
    }

    pub(super) fn gpu_device(&self) -> Option<&ID3D11Device> {
        let Source::Duplication(source) = &self.source else { return None };
        Some(&source.device)
    }

    pub(super) fn gpu_scaling_device(&self) -> Option<&ID3D11Device> {
        self.gpu_device().filter(|_| self.independent)
    }

    pub(super) fn enable_gpu_capture(&mut self) -> Result<()> {
        let row_bytes = self.width() as u32 * 4;
        let Source::Duplication(source) = &mut self.source else { return Err(DeskError::platform("GPU 处理需要 DXGI 桌面采集")) };
        if source.gpu.is_some() {
            return Ok(());
        }
        unsafe {
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            source.staging.GetDesc(&mut desc);
            desc.Usage = D3D11_USAGE_DEFAULT;
            desc.CPUAccessFlags = 0;
            // Seed a still desktop from the opening picture; DXGI may have nothing newer to give us.
            let initial = D3D11_SUBRESOURCE_DATA { pSysMem: self.frame.as_ptr().cast(), SysMemPitch: row_bytes, ..Default::default() };
            let mut texture = None;
            source.device.CreateTexture2D(&desc, self.has_frame.then_some(&initial as *const _), Some(&mut texture)).map_err(failed("创建设备桌面纹理"))?;
            let texture = texture.ok_or_else(|| DeskError::platform("没有设备桌面纹理"))?;
            source.gpu = Some(GpuCapture { texture, current: self.has_frame });
        }
        Ok(())
    }

    pub(super) fn gpu_frame(&self) -> Option<&ID3D11Texture2D> {
        let Source::Duplication(source) = &self.source else { return None };
        source.gpu.as_ref().filter(|gpu| gpu.current).map(|gpu| &gpu.texture)
    }

    pub(super) fn disable_gpu_capture(&mut self) -> Result<()> {
        let row_bytes = self.width() * 4;
        let Source::Duplication(source) = &mut self.source else { return Ok(()) };
        if let Some(gpu) = source.gpu.take().filter(|gpu| gpu.current) {
            unsafe { source.context.CopyResource(&source.staging, &gpu.texture) };
            if let Err(error) = source.read_bgra(&mut self.frame, row_bytes) {
                self.has_frame = false;
                return Err(error);
            }
        }
        Ok(())
    }

    pub(super) fn grab_timed(&mut self, wait_milliseconds: u32, waited: &mut Duration) -> Result<bool> {
        self.grab_source(wait_milliseconds, false, self.independent, waited)
    }

    fn grab_source(&mut self, wait_milliseconds: u32, refresh_surface: bool, independent: bool, waited: &mut Duration) -> Result<bool> {
        let row_bytes = self.width() * 4;
        let first = !self.has_frame || refresh_surface;
        match &mut self.source {
            Source::Duplication(source) => unsafe {
                let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
                let mut resource = None;
                let start = Instant::now();
                let acquired = source.duplication.AcquireNextFrame(wait_milliseconds, &mut info, &mut resource);
                *waited += start.elapsed();
                let acquired = match acquired {
                    Ok(()) => true,
                    Err(error) if error.code() == DXGI_ERROR_WAIT_TIMEOUT => false,
                    Err(error) => return Err(failed("获取桌面画面")(error)),
                };
                let mut changed = false;
                if acquired && info.LastMouseUpdateTime != 0 {
                    source.position = info.PointerPosition.Visible.as_bool().then_some(info.PointerPosition.Position);
                    changed = !independent;
                }
                if acquired && info.PointerShapeBufferSize > 0 {
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
                // An invisible hardware pointer can be hidden, on another output, or drawn into the surface.
                let cursorless = needs_cursorless_capture(independent, source.position, self.display.bounds, || cursor_info().ok());
                let copied = if acquired && !cursorless && (info.LastPresentTime != 0 || first || source.frame_from_gdi) {
                    resource.and_then(|resource| resource.cast::<ID3D11Texture2D>().ok()).map(|texture| {
                        if let Some(gpu) = source.gpu.as_mut().filter(|_| independent) {
                            source.context.CopyResource(&gpu.texture, &texture);
                            gpu.current = true;
                            return Ok(());
                        }
                        source.context.CopyResource(&source.staging, &texture);
                        source.read_bgra(&mut self.frame, row_bytes)?;
                        if let Some(gpu) = &mut source.gpu {
                            gpu.current = false;
                        }
                        Ok(())
                    })
                } else {
                    None
                };
                if acquired {
                    source.duplication.ReleaseFrame().map_err(failed("释放桌面画面"))?;
                }
                if cursorless || (refresh_surface && copied.is_none()) {
                    let fallback = match &mut source.fallback {
                        Some(fallback) => fallback,
                        None => source.fallback.insert(Gdi::open(self.display.bounds)?),
                    };
                    let changed = fallback.grab(&self.display, independent, first || !source.frame_from_gdi, &mut self.frame)?;
                    source.frame_from_gdi = true;
                    if let Some(gpu) = &mut source.gpu {
                        gpu.current = false;
                    }
                    self.has_frame = true;
                    return Ok(changed);
                }
                match copied {
                    Some(Ok(())) => {
                        source.frame_from_gdi = false;
                        self.has_frame = true;
                        Ok(true)
                    }
                    Some(Err(error)) => Err(error),
                    None => Ok(changed && !refresh_surface),
                }
            },
            Source::Gdi(source) => {
                if wait_milliseconds != 0 {
                    let start = Instant::now();
                    std::thread::sleep(Duration::from_millis(u64::from(wait_milliseconds.min(15))));
                    *waited += start.elapsed();
                }
                let changed = source.grab(&self.display, independent, first, &mut self.frame)?;
                self.has_frame = true;
                Ok(changed)
            }
        }
    }

    /// The pointer to draw over `frame`, when the capture delivers it separately.
    pub fn pointer(&self) -> Option<Pointer> {
        if self.independent {
            return None;
        }
        let Source::Duplication(source) = &self.source else { return None };
        if source.frame_from_gdi {
            return None;
        }
        // Desktop duplication reports where the shape's top-left corner is, not where its hot spot is.
        let position = source.position?;
        Some(Pointer { shape: source.shape.clone()?, x: position.x, y: position.y })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::UI::WindowsAndMessaging::{CURSOR_SUPPRESSED, CURSORINFO_FLAGS};

    #[test]
    fn only_a_shown_cursor_on_the_shared_output_can_require_cursorless_capture() {
        let bounds = RECT { left: -1600, top: -200, right: 0, bottom: 700 };
        let inside = POINT { x: -10, y: 250 };
        let check = |flags, point| needs_cursorless_capture(true, None, bounds, || Some(CURSORINFO { flags, ptScreenPos: point, ..Default::default() }));

        assert!(check(CURSOR_SHOWING, inside));
        assert!(!check(CURSOR_SHOWING, POINT { x: 0, ..inside }));
        assert!(!check(CURSORINFO_FLAGS(0), inside));
        assert!(!check(CURSOR_SUPPRESSED, inside));
        assert!(!needs_cursorless_capture(true, None, bounds, || None));
        assert!(!needs_cursorless_capture(true, Some(inside), bounds, || unreachable!("DXGI reported the hardware pointer")));
    }
}
