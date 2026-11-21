//! Keyboard and mouse input for the shared display, through `SendInput`.

use quietdesk_core::input::{InjectOp, MouseButton};
use quietdesk_core::keymap::PcKey;
use windows::Win32::Foundation::RECT;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN};

fn key(key: PcKey, down: bool) -> INPUT {
    let release = if down { KEYBD_EVENT_FLAGS(0) } else { KEYEVENTF_KEYUP };
    let input = match key {
        PcKey::Scan { code, extended } => {
            let prefix = if extended { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
            KEYBDINPUT { wScan: code, dwFlags: KEYEVENTF_SCANCODE | prefix | release, ..Default::default() }
        }
        PcKey::Virtual(code) => KEYBDINPUT { wVk: VIRTUAL_KEY(code), dwFlags: release, ..Default::default() },
    };
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: input } }
}

fn mouse(flags: MOUSE_EVENT_FLAGS, data: i32, position: (i32, i32)) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 { mi: MOUSEINPUT { dx: position.0, dy: position.1, mouseData: data as u32, dwFlags: flags, ..Default::default() } },
    }
}

/// Injects operations in order. `display` is the shared display in virtual-desktop pixels.
pub fn inject(operations: &[InjectOp], display: RECT) {
    let mut inputs = Vec::with_capacity(operations.len() + 1);
    for operation in operations {
        match *operation {
            InjectOp::Key { key: pressed, down } => inputs.push(key(pressed, down)),
            InjectOp::Move { x, y } => unsafe {
                let (left, top) = (GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN));
                let (width, height) = (GetSystemMetrics(SM_CXVIRTUALSCREEN).max(2), GetSystemMetrics(SM_CYVIRTUALSCREEN).max(2));
                let pixel_x = f64::from(display.left) + x * f64::from(display.right - display.left - 1);
                let pixel_y = f64::from(display.top) + y * f64::from(display.bottom - display.top - 1);
                // Absolute positions cover the virtual desktop in 65536 steps.
                let scaled = |pixel: f64, origin: i32, extent: i32| ((pixel - f64::from(origin)) * 65535.0 / f64::from(extent - 1)).round() as i32;
                inputs.push(mouse(
                    MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                    0,
                    (scaled(pixel_x, left, width), scaled(pixel_y, top, height)),
                ));
            },
            InjectOp::Button { button, down } => {
                let (flags, data) = match (button, down) {
                    (MouseButton::Left, true) => (MOUSEEVENTF_LEFTDOWN, 0),
                    (MouseButton::Left, false) => (MOUSEEVENTF_LEFTUP, 0),
                    (MouseButton::Right, true) => (MOUSEEVENTF_RIGHTDOWN, 0),
                    (MouseButton::Right, false) => (MOUSEEVENTF_RIGHTUP, 0),
                    (MouseButton::Middle, true) => (MOUSEEVENTF_MIDDLEDOWN, 0),
                    (MouseButton::Middle, false) => (MOUSEEVENTF_MIDDLEUP, 0),
                    (MouseButton::X1, true) => (MOUSEEVENTF_XDOWN, 1),
                    (MouseButton::X1, false) => (MOUSEEVENTF_XUP, 1),
                    (MouseButton::X2, true) => (MOUSEEVENTF_XDOWN, 2),
                    (MouseButton::X2, false) => (MOUSEEVENTF_XUP, 2),
                };
                inputs.push(mouse(flags, data, (0, 0)));
            }
            InjectOp::Wheel { vertical, horizontal } => {
                if vertical != 0 {
                    inputs.push(mouse(MOUSEEVENTF_WHEEL, vertical, (0, 0)));
                }
                if horizontal != 0 {
                    inputs.push(mouse(MOUSEEVENTF_HWHEEL, horizontal, (0, 0)));
                }
            }
            InjectOp::CapsLock(wanted) => {
                // The lock state is read when the events before it have been delivered.
                send(&mut inputs);
                if (unsafe { GetKeyState(i32::from(VK_CAPITAL.0)) } & 1 != 0) != wanted {
                    let caps_lock = PcKey::Scan { code: 0x3A, extended: false };
                    inputs.extend([key(caps_lock, true), key(caps_lock, false)]);
                }
            }
        }
    }
    send(&mut inputs);
}

fn send(inputs: &mut Vec<INPUT>) {
    if !inputs.is_empty() {
        let sent = unsafe { SendInput(inputs, size_of::<INPUT>() as i32) };
        if sent as usize != inputs.len() {
            log::warn!(
                "{} of {} input events were not accepted, for example because a protected window has the focus",
                inputs.len() - sent as usize,
                inputs.len()
            );
        }
        inputs.clear();
    }
}
