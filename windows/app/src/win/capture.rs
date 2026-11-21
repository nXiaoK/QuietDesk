//! The pixels of one display: desktop duplication where the system offers it, GDI otherwise.

use super::util::failed;
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::pixel::{PointerKind, PointerShape};
use std::ffi::c_void;
use windows::Win32::Foundation::{HMODULE, POINT, RECT};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_MODE_ROTATION_IDENTITY, DXGI_MODE_ROTATION_UNSPECIFIED, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::*;
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
    memory: HDC,
    bitmap: HBITMAP,
    bits: *const u8,
}

enum Source {
    Duplication(Duplication),
    Gdi(Gdi),
}

pub struct ScreenCapture {
    source: Source,
    /// The display's rectangle in virtual-desktop pixels.
    pub bounds: RECT,
    /// Top-down BGRA rows of `width * 4` bytes. With GDI the pointer is already drawn in.
    pub frame: Vec<u8>,
    has_frame: bool,
}

// The capture thread is the only user of these handles and COM objects.
unsafe impl Send for ScreenCapture {}

impl ScreenCapture {
    pub fn width(&self) -> usize {
        (self.bounds.right - self.bounds.left) as usize
    }

    pub fn height(&self) -> usize {
        (self.bounds.bottom - self.bounds.top) as usize
    }

    /// Opens the primary display.
    pub fn open() -> Result<Self> {
        match Self::open_duplication() {
            Ok(capture) => Ok(capture),
            Err(error) => {
                log::warn!("desktop duplication is unavailable, capturing with GDI: {error}");
                Self::open_gdi()
            }
        }
    }

    fn open_duplication() -> Result<Self> {
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
                    // The primary display is the one at the origin of the virtual desktop.
                    if !description.AttachedToDesktop.as_bool() || bounds.left != 0 || bounds.top != 0 {
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
                    return Ok(Self { source, bounds, frame: vec![0; (width * height * 4) as usize], has_frame: false });
                }
            }
        }
        Err(DeskError::platform("没有找到主显示器"))
    }

    fn open_gdi() -> Result<Self> {
        unsafe {
            let (width, height) = (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
            if width <= 0 || height <= 0 {
                return Err(DeskError::platform("无法读取主显示器尺寸"));
            }
            let screen = GetDC(None);
            let memory = CreateCompatibleDC(Some(screen));
            let header = BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width,
                biHeight: -height,
                biPlanes: 1,
                biBitCount: 32,
                ..Default::default()
            };
            let layout = BITMAPINFO { bmiHeader: header, ..Default::default() };
            let mut bits: *mut c_void = std::ptr::null_mut();
            let bitmap = CreateDIBSection(Some(screen), &layout, DIB_RGB_COLORS, &mut bits, None, 0).map_err(failed("创建屏幕位图"))?;
            SelectObject(memory, bitmap.into());
            let source = Source::Gdi(Gdi { screen, memory, bitmap, bits: bits as *const u8 });
            Ok(Self { source, bounds: RECT { left: 0, top: 0, right: width, bottom: height }, frame: vec![0; (width * height * 4) as usize], has_frame: false })
        }
    }

    /// Waits up to `wait_milliseconds` for the screen or pointer to change. `Ok(true)` means `frame` or the
    /// pointer differs from the last call; an error means the capture has to be opened again.
    pub fn grab(&mut self, wait_milliseconds: u32) -> Result<bool> {
        let (width, height) = (self.width(), self.height());
        let first = !std::mem::replace(&mut self.has_frame, true);
        match &mut self.source {
            Source::Duplication(source) => unsafe {
                let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
                let mut resource = None;
                match source.duplication.AcquireNextFrame(wait_milliseconds, &mut info, &mut resource) {
                    Ok(()) => {}
                    Err(error) if error.code() == DXGI_ERROR_WAIT_TIMEOUT => return Ok(false),
                    Err(error) => return Err(failed("获取桌面画面")(error)),
                }
                let mut changed = false;
                if info.LastMouseUpdateTime != 0 {
                    source.position = info.PointerPosition.Visible.as_bool().then_some(info.PointerPosition.Position);
                    changed = true;
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
                    Some(Ok(())) => Ok(true),
                    Some(Err(error)) => Err(failed("读取桌面画面")(error)),
                    None => Ok(changed),
                }
            },
            Source::Gdi(source) => unsafe {
                std::thread::sleep(std::time::Duration::from_millis(u64::from(wait_milliseconds.min(15))));
                BitBlt(source.memory, 0, 0, width as i32, height as i32, Some(source.screen), 0, 0, SRCCOPY | CAPTUREBLT).map_err(failed("复制屏幕"))?;
                let mut cursor = CURSORINFO { cbSize: size_of::<CURSORINFO>() as u32, ..Default::default() };
                if GetCursorInfo(&mut cursor).is_ok() && cursor.flags == CURSOR_SHOWING {
                    let mut icon = ICONINFO::default();
                    if GetIconInfo(cursor.hCursor.into(), &mut icon).is_ok() {
                        let _ = DrawIconEx(
                            source.memory,
                            cursor.ptScreenPos.x - icon.xHotspot as i32,
                            cursor.ptScreenPos.y - icon.yHotspot as i32,
                            cursor.hCursor.into(),
                            0,
                            0,
                            0,
                            None,
                            DI_NORMAL,
                        );
                        let _ = DeleteObject(icon.hbmMask.into());
                        let _ = DeleteObject(icon.hbmColor.into());
                    }
                }
                let _ = GdiFlush();
                let captured = std::slice::from_raw_parts(source.bits, width * height * 4);
                if !first && captured == &self.frame[..] {
                    return Ok(false);
                }
                self.frame.copy_from_slice(captured);
                Ok(true)
            },
        }
    }

    /// The pointer to draw over `frame`, when the capture delivers it separately.
    pub fn pointer(&self) -> Option<Pointer> {
        let Source::Duplication(source) = &self.source else { return None };
        // Desktop duplication reports where the shape's top-left corner is, not where its hot spot is.
        let position = source.position?;
        Some(Pointer { shape: source.shape.clone()?, x: position.x, y: position.y })
    }
}

impl Drop for ScreenCapture {
    fn drop(&mut self) {
        if let Source::Gdi(source) = &self.source {
            unsafe {
                let _ = DeleteDC(source.memory);
                let _ = DeleteObject(source.bitmap.into());
                ReleaseDC(None, source.screen);
            }
        }
    }
}
