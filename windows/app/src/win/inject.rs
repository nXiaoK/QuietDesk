//! Keyboard and mouse input for the shared display, through `SendInput`.

use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::host::InputActionOutcome;
use quietdesk_core::input::{InjectOp, MouseButton};
use quietdesk_core::keymap::PcKey;
use quietdesk_core::messages::{InputAction, InputFeedback};
use std::ffi::OsString;
use std::fs::OpenOptions;
use std::os::windows::{ffi::OsStringExt, fs::OpenOptionsExt, io::AsRawHandle};
use std::sync::mpsc;
use std::time::Duration;
use windows::Win32::Devices::DeviceAndDriverInstallation::*;
use windows::Win32::Devices::HumanInterfaceDevice::{
    GUID_DEVINTERFACE_KEYBOARD, IOCTL_KEYBOARD_QUERY_INDICATORS, KEYBOARD_CAPS_LOCK_ON, KEYBOARD_INDICATOR_PARAMETERS,
};
use windows::Win32::Foundation::{HANDLE, RECT};
use windows::Win32::System::IO::DeviceIoControl;
use windows::Win32::System::RemoteDesktop::{ProcessIdToSessionId, WTSGetActiveConsoleSessionId};
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::{
    GUITHREADINFO, GetForegroundWindow, GetGUIThreadInfo, GetSystemMetrics, GetWindowThreadProcessId, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN,
    SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};
use windows::core::PCWSTR;

const READ_TIMEOUT: Duration = Duration::from_millis(300);
static INDICATOR_READER: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(1);

fn local_console() -> bool {
    let mut session = 0;
    unsafe { ProcessIdToSessionId(std::process::id(), &mut session).is_ok() && WTSGetActiveConsoleSessionId() == session }
}

fn indicators() -> Result<bool> {
    if !local_console() {
        return Err(DeskError::platform("无法读取当前远端会话的大写锁定状态"));
    }
    let flags = CM_GET_DEVICE_INTERFACE_LIST_PRESENT;
    let mut count = 0;
    if unsafe { CM_Get_Device_Interface_List_SizeW(&mut count, &GUID_DEVINTERFACE_KEYBOARD, PCWSTR::null(), flags) } != CR_SUCCESS {
        return Err(DeskError::platform("无法枚举远端键盘"));
    }
    let mut paths = vec![0u16; count as usize];
    if unsafe { CM_Get_Device_Interface_ListW(&GUID_DEVINTERFACE_KEYBOARD, PCWSTR::null(), &mut paths, flags) } != CR_SUCCESS {
        return Err(DeskError::platform("无法读取远端键盘列表，请重试"));
    }
    let mut caps = None;
    for path in paths.split(|unit| *unit == 0).take_while(|p| !p.is_empty()) {
        // Indicator queries need no data access. Keep the system's existing keyboard handles shared.
        let Ok(device) = OpenOptions::new().access_mode(0).open(OsString::from_wide(path)) else { continue };
        let mut state = KEYBOARD_INDICATOR_PARAMETERS::default();
        let mut returned = 0;
        let result = unsafe {
            DeviceIoControl(
                HANDLE(device.as_raw_handle()),
                IOCTL_KEYBOARD_QUERY_INDICATORS,
                None,
                0,
                Some(std::ptr::from_mut(&mut state).cast()),
                size_of_val(&state) as u32,
                Some(&mut returned),
                None,
            )
        };
        if result.is_ok() && returned as usize == size_of_val(&state) {
            let locked = u32::from(state.LedFlags) & KEYBOARD_CAPS_LOCK_ON != 0;
            if caps.replace(locked).is_some_and(|old| old != locked) {
                return Err(DeskError::platform("远端键盘的大写锁定状态不一致"));
            }
        }
    }
    caps.ok_or_else(|| DeskError::platform("当前会话无法读取键盘的大写锁定指示"))
}

fn read_indicators(report: impl FnOnce(Result<bool>) + Send + 'static) -> Result<()> {
    let slot = INDICATOR_READER.try_acquire().map_err(|_| DeskError::platform("远端键盘尚未响应"))?;
    std::thread::Builder::new()
        .name("keyboard-indicators".into())
        .spawn(move || {
            let result = indicators();
            drop(slot);
            report(result);
        })
        .map(|_| ())
        .map_err(|e| DeskError::platform(format!("无法读取远端键盘状态：{e}")))
}

pub(super) fn supports_input_actions() -> bool {
    let (report, result) = mpsc::channel();
    read_indicators(move |read| {
        let _ = report.send(read.is_ok());
    })
    .is_ok()
        && result.recv_timeout(READ_TIMEOUT).unwrap_or(false)
}

async fn caps_locked() -> Result<bool> {
    let (report, reading) = tokio::sync::oneshot::channel();
    read_indicators(move |read| {
        let _ = report.send(read);
    })?;
    tokio::time::timeout(READ_TIMEOUT, reading)
        .await
        .map_err(|_| DeskError::platform("读取远端大写锁定超时"))?
        .map_err(|_| DeskError::platform("远端键盘状态读取已停止"))?
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct Focus {
    window: isize,
    focus: isize,
    thread: u32,
}

impl Focus {
    fn current() -> Option<Self> {
        unsafe {
            let window = GetForegroundWindow();
            if window.is_invalid() {
                return None;
            }
            let thread = GetWindowThreadProcessId(window, None);
            let mut info = GUITHREADINFO { cbSize: size_of::<GUITHREADINFO>() as u32, ..Default::default() };
            if thread == 0 || GetGUIThreadInfo(thread, &mut info).is_err() || info.hwndFocus.is_invalid() || GetForegroundWindow() != window {
                return None;
            }
            Some(Self { window: window.0 as isize, focus: info.hwndFocus.0 as isize, thread })
        }
    }

    fn layout(self) -> Option<isize> {
        let layout = unsafe { GetKeyboardLayout(self.thread) };
        (!layout.is_invalid()).then_some(layout.0 as isize)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Shortcut {
    Caps,
    NextLayout,
}

impl Shortcut {
    fn for_action(action: InputAction, locked: bool) -> Self {
        if action == InputAction::ToggleCapsLock || locked { Self::Caps } else { Self::NextLayout }
    }

    fn events(self) -> &'static [(VIRTUAL_KEY, bool)] {
        match self {
            Self::Caps => &[(VK_CAPITAL, true), (VK_CAPITAL, false)],
            Self::NextLayout => &[(VK_LWIN, true), (VK_SPACE, true), (VK_SPACE, false), (VK_LWIN, false)],
        }
    }

    fn send(self, mut submit: impl FnMut(&[(VIRTUAL_KEY, bool)]) -> usize) -> Result<()> {
        let events = self.events();
        let count = submit(events);
        if count == events.len() {
            return Ok(());
        }
        // Only undo key-downs in the accepted prefix. Never repeat a toggle or the shortcut.
        let mut held = Vec::new();
        for &(key, down) in &events[..count] {
            if down {
                held.push(key);
            } else {
                held.retain(|k| *k != key);
            }
        }
        let releases: Vec<_> = held.into_iter().rev().map(|k| (k, false)).collect();
        let mut pending = &releases[..];
        while !pending.is_empty() {
            let released = submit(pending);
            if released == 0 {
                return Err(DeskError::platform("远端系统未接受快捷键释放，请检查远端键盘"));
            }
            pending = &pending[released..];
        }
        Err(DeskError::platform("远端系统未完整接受快捷键"))
    }
}

fn send_keys(events: &[(VIRTUAL_KEY, bool)]) -> usize {
    let inputs: Vec<_> = events
        .iter()
        .map(|&(k, down)| {
            let pressed = if k == VK_LWIN { quietdesk_core::keymap::pc::LEFT_WINDOWS } else { PcKey::Virtual(k.0) };
            key(pressed, down)
        })
        .collect();
    unsafe { SendInput(&inputs, size_of::<INPUT>() as i32) as usize }
}

fn feedback(message: &str, caps_locked: bool) -> InputFeedback {
    InputFeedback { message: message.into(), caps_locked }
}

fn unconfirmed(reason: &str, caps_locked: bool) -> InputActionOutcome {
    InputActionOutcome::Unconfirmed(InputFeedback { message: format!("{reason}，请点击远端输入位置后继续"), caps_locked })
}

fn observed(shortcut: Shortcut, before: bool, caps: bool, changed_layout: bool, last: bool) -> Option<InputActionOutcome> {
    use InputActionOutcome::Confirmed;
    match shortcut {
        Shortcut::Caps if before != caps => Some(Confirmed(feedback(if caps { "远端大写锁定已开启" } else { "远端大写锁定已关闭" }, caps))),
        Shortcut::NextLayout if before != caps => Some(unconfirmed("切换输入法时远端大写锁定状态发生了变化", caps)),
        Shortcut::NextLayout if changed_layout => Some(Confirmed(feedback("远端键盘布局已切换", caps))),
        Shortcut::Caps if last => Some(unconfirmed("远端大写锁定状态未改变", caps)),
        Shortcut::NextLayout if last => Some(unconfirmed("已发送 Win+Space，无法确认当前输入法", caps)),
        _ => None,
    }
}

pub(super) async fn input_action(action: InputAction, display_available: impl Fn() -> bool + Send) -> Result<InputActionOutcome> {
    let original = Focus::current().ok_or_else(|| DeskError::platform("请先在远端选中输入位置"))?;
    let before = caps_locked().await?;
    if !local_console() {
        return Err(DeskError::platform("远端控制台会话已改变"));
    }
    if Focus::current() != Some(original) || !display_available() {
        return Ok(unconfirmed("远端输入位置已改变", before));
    }
    if [VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN, VK_SPACE, VK_CAPITAL].iter().any(|vk| unsafe { GetAsyncKeyState(i32::from(vk.0)) } < 0) {
        return Ok(unconfirmed("远端键盘有按键尚未松开", before));
    }
    let shortcut = Shortcut::for_action(action, before);
    let original_layout = original.layout();
    if let Err(error) = shortcut.send(send_keys) {
        return Ok(unconfirmed(&error.to_string(), caps_locked().await?));
    }
    let deadline = tokio::time::Instant::now() + Duration::from_millis(280);
    loop {
        tokio::time::sleep(Duration::from_millis(40)).await;
        let caps = caps_locked().await?;
        if Focus::current() != Some(original) || !display_available() {
            return Ok(unconfirmed("远端输入位置已改变", caps));
        }
        let changed_layout = original_layout.zip(original.layout()).is_some_and(|(a, b)| a != b);
        if let Some(outcome) = observed(shortcut, before, caps, changed_layout, tokio::time::Instant::now() >= deadline) {
            return Ok(outcome);
        }
    }
}

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
pub fn inject(operations: &[InjectOp], display: RECT) -> bool {
    let mut inputs = Vec::with_capacity(operations.len() + 1);
    let mut complete = true;
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
                complete &= send(&mut inputs);
                if (unsafe { GetKeyState(i32::from(VK_CAPITAL.0)) } & 1 != 0) != wanted {
                    let caps_lock = PcKey::Scan { code: 0x3A, extended: false };
                    inputs.extend([key(caps_lock, true), key(caps_lock, false)]);
                }
            }
        }
    }
    complete & send(&mut inputs)
}

fn send(inputs: &mut Vec<INPUT>) -> bool {
    if inputs.is_empty() {
        return true;
    }
    let sent = unsafe { SendInput(inputs, size_of::<INPUT>() as i32) } as usize;
    let complete = sent == inputs.len();
    if !complete {
        log::warn!("{} of {} input events were not accepted, for example because a protected window has the focus", inputs.len() - sent, inputs.len());
    }
    inputs.clear();
    complete
}

#[cfg(test)]
mod tests {
    use super::*;
    use InputAction::{SwitchInputSource, ToggleCapsLock};
    use InputActionOutcome::{Confirmed, Unconfirmed};

    #[test]
    fn short_press_closes_caps_before_it_cycles_the_input_source() {
        assert!(Shortcut::for_action(SwitchInputSource, true) == Shortcut::Caps);
        assert!(Shortcut::for_action(SwitchInputSource, false) == Shortcut::NextLayout);
        assert!(Shortcut::for_action(ToggleCapsLock, false) == Shortcut::Caps);
        assert!(Shortcut::for_action(ToggleCapsLock, true) == Shortcut::Caps);
    }

    #[test]
    fn partial_shortcuts_release_only_the_keys_that_went_down() {
        let events = Shortcut::NextLayout.events();
        for (accepted, remaining) in
            [(0, vec![]), (1, vec![(VK_LWIN, false)]), (2, vec![(VK_SPACE, false), (VK_LWIN, false)]), (3, vec![(VK_LWIN, false)]), (4, vec![])]
        {
            let mut releases = vec![];
            let result = Shortcut::NextLayout.send(|batch| {
                if batch == events {
                    return accepted;
                }
                // The driver accepts just one key-up at a time.
                releases.push(batch[0]);
                1
            });
            assert_eq!(result.is_ok(), accepted == events.len());
            assert_eq!(releases, remaining);
        }
    }

    #[test]
    fn failure_to_release_an_accepted_key_is_reported() {
        let error = Shortcut::Caps.send(|events| usize::from(events == Shortcut::Caps.events())).unwrap_err();
        assert!(error.to_string().contains("未接受快捷键释放"));
    }

    #[test]
    fn input_feedback_requires_an_observed_change() {
        assert!(observed(Shortcut::Caps, true, true, false, false).is_none());
        let Some(Confirmed(caps)) = observed(Shortcut::Caps, true, false, false, false) else { panic!("missing Caps confirmation") };
        assert!(!caps.caps_locked);
        assert!(matches!(observed(Shortcut::Caps, false, false, false, true), Some(Unconfirmed(_))));
        assert!(matches!(observed(Shortcut::NextLayout, false, false, true, false), Some(Confirmed(_))));
        assert!(matches!(observed(Shortcut::NextLayout, false, true, true, false), Some(Unconfirmed(_))));
        let Some(Unconfirmed(status)) = observed(Shortcut::NextLayout, false, false, false, true) else {
            panic!("same HKL cannot confirm TSF profile changes")
        };
        assert!(status.message.contains("已发送 Win+Space"));
        assert!(status.message.ends_with("请点击远端输入位置后继续"));
    }
}
