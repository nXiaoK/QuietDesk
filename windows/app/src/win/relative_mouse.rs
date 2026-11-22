use windows::Win32::Foundation::{ERROR_ACCESS_DENIED, ERROR_BUSY, HWND, POINT, RECT};
use windows::Win32::Graphics::Gdi::ClientToScreen;
use windows::Win32::UI::Input::*;
use windows::Win32::UI::WindowsAndMessaging::{
    ClipCursor, GetClipCursor, GetForegroundWindow, GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};
use windows::core::{Error, Result};

/// Scoped to the foreground canvas. Raw mouse registration is shared by all windows in this process.
pub(super) struct RelativeMouse {
    clip: RECT,
}

fn register(window: HWND, flags: RAWINPUTDEVICE_FLAGS) -> Result<()> {
    let mouse = RAWINPUTDEVICE { usUsagePage: 1, usUsage: 2, dwFlags: flags, hwndTarget: window };
    unsafe { RegisterRawInputDevices(&[mouse], size_of::<RAWINPUTDEVICE>() as u32) }
}

fn relative_counts(mouse: RAWMOUSE) -> Option<(i32, i32)> {
    (mouse.usFlags.0 & MOUSE_MOVE_ABSOLUTE.0 == 0 && (mouse.lLastX != 0 || mouse.lLastY != 0)).then_some((mouse.lLastX, mouse.lLastY))
}

impl RelativeMouse {
    pub(super) fn capture(window: HWND, mut center: POINT) -> Result<Self> {
        unsafe {
            if GetForegroundWindow() != window {
                return Err(Error::new(ERROR_ACCESS_DENIED.to_hresult(), "远程窗口没有前台焦点"));
            }
            let mut previous = RECT::default();
            GetClipCursor(&mut previous)?;
            let left = GetSystemMetrics(SM_XVIRTUALSCREEN);
            let top = GetSystemMetrics(SM_YVIRTUALSCREEN);
            let desktop = RECT { left, top, right: left + GetSystemMetrics(SM_CXVIRTUALSCREEN), bottom: top + GetSystemMetrics(SM_CYVIRTUALSCREEN) };
            if previous != desktop {
                return Err(Error::new(ERROR_BUSY.to_hresult(), "系统指针已被其他窗口限制"));
            }
            ClientToScreen(window, &mut center).ok()?;
            let clip = RECT { left: center.x, top: center.y, right: center.x + 1, bottom: center.y + 1 };
            register(window, RAWINPUTDEVICE_FLAGS(0))?;
            if let Err(error) = ClipCursor(Some(&clip)) {
                let _ = register(HWND::default(), RIDEV_REMOVE);
                return Err(error);
            }
            Ok(Self { clip })
        }
    }

    pub(super) fn delta(&self, raw: HRAWINPUT) -> Option<(i32, i32)> {
        let mut data = RAWINPUT::default();
        let mut len = size_of::<RAWINPUT>() as u32;
        let bytes = unsafe { GetRawInputData(raw, RID_INPUT, Some(std::ptr::from_mut(&mut data).cast()), &mut len, size_of::<RAWINPUTHEADER>() as u32) };
        if bytes != (size_of::<RAWINPUTHEADER>() + size_of::<RAWMOUSE>()) as u32 || data.header.dwType != RIM_TYPEMOUSE.0 {
            return None;
        }
        relative_counts(unsafe { data.data.mouse })
    }
}

impl Drop for RelativeMouse {
    fn drop(&mut self) {
        let mut current = RECT::default();
        unsafe {
            if GetClipCursor(&mut current).is_ok() && current == self.clip {
                let _ = ClipCursor(None);
            }
        }
        let _ = register(HWND::default(), RIDEV_REMOVE);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absolute_tablet_coordinates_and_stationary_wheel_reports_do_not_move_the_mouse() {
        let mut mouse = RAWMOUSE::default();
        assert_eq!(relative_counts(mouse), None);
        mouse.lLastX = 20;
        mouse.lLastY = -8;
        assert_eq!(relative_counts(mouse), Some((20, -8)));
        mouse.usFlags = MOUSE_MOVE_ABSOLUTE;
        assert_eq!(relative_counts(mouse), None);
    }
}
