//! The viewer's window: draws the host's picture and sends this PC's keyboard and mouse to it.

use super::app::{Frame, ViewerSink, run_viewer};
use super::clipboard;
use super::settings::VIEWER_QUALITIES;
use super::util::wide;
use quietdesk_core::input::{DoubleClick, PcKeyEvent, ViewerInputTranslator};
use quietdesk_core::keymap::PcModifierMapping;
use quietdesk_core::messages::StreamSettings;
use quietdesk_core::pairing::PairingKey;
use quietdesk_core::viewer::{ViewerCommand, ViewerEnd, ViewerEvent};
use std::cell::Cell;
use std::collections::{BTreeSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::{ScreenToClient, ValidateRect};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetDoubleClickTime, ReleaseCapture, SetCapture, VK_ESCAPE, VK_RETURN};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

const WM_SESSION_EVENT: u32 = WM_APP + 1;
const WM_SESSION_FRAME: u32 = WM_APP + 2;
const WM_SESSION_ENDED: u32 = WM_APP + 3;
/// Sent to the owner window when a session reports the host's name: the canvas window and the name's text.
pub const WM_CANVAS_CONNECTED: u32 = WM_APP + 20;
const MOVE_TIMER: usize = 1;
const MOVE_INTERVAL: Duration = Duration::from_millis(8);
const MENU_FULL_SCREEN: usize = 100;
const MENU_SEND_CLIPBOARD: usize = 101;
const MENU_REQUEST_CLIPBOARD: usize = 102;
const MENU_DISCONNECT: usize = 103;
const MENU_QUALITY: usize = 200;

/// What the session threads leave for the window thread.
struct Mailbox {
    window: isize,
    events: Mutex<VecDeque<ViewerEvent>>,
    ended: Mutex<Option<ViewerEnd>>,
    frame_posted: AtomicBool,
}

impl Mailbox {
    fn post(&self, message: u32) {
        let _ = unsafe { PostMessageW(Some(HWND(self.window as _)), message, WPARAM(0), LPARAM(0)) };
    }
}

impl ViewerSink for Mailbox {
    fn event(&self, event: ViewerEvent) {
        self.events.lock().unwrap().push_back(event);
        self.post(WM_SESSION_EVENT);
    }

    fn frame_ready(&self, _stream: Option<quietdesk_core::media::MediaStreamId>) {
        // One pending message is enough: the window always draws the latest picture.
        if !self.frame_posted.swap(true, Ordering::AcqRel) {
            self.post(WM_SESSION_FRAME);
        }
    }
}

struct Canvas {
    window: HWND,
    owner: HWND,
    commands: UnboundedSender<ViewerCommand>,
    mailbox: Arc<Mailbox>,
    frame: Arc<Mutex<Frame>>,
    target: Option<ID2D1HwndRenderTarget>,
    bitmap: Option<(ID2D1Bitmap, usize, usize)>,
    factory: ID2D1Factory,
    translator: ViewerInputTranslator,
    started: Instant,
    name: String,
    connected: bool,
    can_control: bool,
    held: BTreeSet<(u32, bool)>,
    caps_lock: bool,
    hook: Option<HHOOK>,
    pending_move: Option<(f64, f64)>,
    last_move: Instant,
    full_screen: Option<(WINDOW_STYLE, WINDOWPLACEMENT, HMENU)>,
    paused: bool,
    /// The user asked for the session to end, so its ending needs no explanation.
    closing: bool,
}

thread_local! {
    /// The canvas whose window has the keyboard, for the keyboard hook of this thread.
    static FOCUSED: Cell<*mut Canvas> = const { Cell::new(std::ptr::null_mut()) };
}

/// Opens a viewer window and starts its session on `runtime`. `owner` hears `WM_CANVAS_CONNECTED`.
pub fn open(
    runtime: &tokio::runtime::Handle,
    owner: HWND,
    address: String,
    port: u16,
    key: PairingKey,
    quality: StreamSettings,
    mapping: PcModifierMapping,
) -> windows::core::Result<HWND> {
    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None)?.into();
        let class = w!("QuietDeskCanvas");
        let definition = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(window_procedure),
            hInstance: instance,
            hIcon: LoadIconW(Some(instance), PCWSTR(1 as _)).unwrap_or_default(),
            hCursor: LoadCursorW(None, IDC_ARROW)?,
            lpszClassName: class,
            ..Default::default()
        };
        // Registering twice fails harmlessly for the second window.
        RegisterClassExW(&definition);
        let menu = CreateMenu()?;
        let session = CreatePopupMenu()?;
        AppendMenuW(session, MF_STRING, MENU_FULL_SCREEN, w!("全屏\tCtrl+Alt+Enter"))?;
        AppendMenuW(session, MF_STRING, MENU_SEND_CLIPBOARD, w!("发送本机剪贴板文字"))?;
        AppendMenuW(session, MF_STRING, MENU_REQUEST_CLIPBOARD, w!("获取远端剪贴板文字"))?;
        AppendMenuW(session, MF_SEPARATOR, 0, None)?;
        AppendMenuW(session, MF_STRING, MENU_DISCONNECT, w!("断开连接"))?;
        AppendMenuW(menu, MF_POPUP, session.0 as usize, w!("会话"))?;
        let qualities = CreatePopupMenu()?;
        for (index, (label, _)) in VIEWER_QUALITIES.iter().enumerate() {
            AppendMenuW(qualities, MF_STRING, MENU_QUALITY + index, PCWSTR(wide(label).as_ptr()))?;
        }
        AppendMenuW(menu, MF_POPUP, qualities.0 as usize, w!("画质"))?;
        let title = wide(&format!("QuietDesk · 正在连接 {address}…"));
        let window = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            PCWSTR(title.as_ptr()),
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            1280,
            800,
            None,
            Some(menu),
            Some(instance),
            None,
        )?;
        let (commands, queue) = unbounded_channel();
        let mailbox =
            Arc::new(Mailbox { window: window.0 as isize, events: Mutex::new(VecDeque::new()), ended: Mutex::new(None), frame_posted: AtomicBool::new(false) });
        let frame = Arc::new(Mutex::new(Frame::default()));
        let double_click = DoubleClick { interval: Duration::from_millis(u64::from(GetDoubleClickTime())), distance: GetSystemMetrics(SM_CXDOUBLECLK) / 2 };
        let canvas = Box::new(Canvas {
            window,
            owner,
            commands,
            mailbox: mailbox.clone(),
            frame: frame.clone(),
            target: None,
            bitmap: None,
            factory: D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?,
            translator: ViewerInputTranslator::new(mapping, double_click),
            started: Instant::now(),
            name: address.clone(),
            connected: false,
            can_control: false,
            held: BTreeSet::new(),
            caps_lock: false,
            hook: None,
            pending_move: None,
            last_move: Instant::now(),
            full_screen: None,
            paused: false,
            closing: false,
        });
        SetWindowLongPtrW(window, GWLP_USERDATA, Box::into_raw(canvas) as isize);
        let _ = ShowWindow(window, SW_SHOW);
        runtime.spawn(async move {
            let end = run_viewer(address, port, key, quality, queue, frame, mailbox.clone()).await;
            *mailbox.ended.lock().unwrap() = Some(end);
            mailbox.post(WM_SESSION_ENDED);
        });
        Ok(window)
    }
}

fn point(lparam: LPARAM) -> (i32, i32) {
    ((lparam.0 & 0xFFFF) as i16 as i32, ((lparam.0 >> 16) & 0xFFFF) as i16 as i32)
}

impl Canvas {
    fn send(&self, command: ViewerCommand) {
        let _ = self.commands.send(command);
    }

    fn set_title(&self, status: &str) {
        let title = wide(&format!("QuietDesk · {} · {status}", self.name));
        let _ = unsafe { SetWindowTextW(self.window, PCWSTR(title.as_ptr())) };
    }

    /// Where the picture lies in the client area: as large as fits, centred.
    fn picture(&self) -> Option<(f32, f32, f32, f32)> {
        let (width, height) = self.bitmap.as_ref().map(|(_, width, height)| (*width as f32, *height as f32))?;
        let mut client = RECT::default();
        unsafe { GetClientRect(self.window, &mut client) }.ok()?;
        let (client_width, client_height) = ((client.right - client.left) as f32, (client.bottom - client.top) as f32);
        if client_width < 1.0 || client_height < 1.0 {
            return None;
        }
        let scale = (client_width / width).min(client_height / height);
        let (shown_width, shown_height) = (width * scale, height * scale);
        Some(((client_width - shown_width) / 2.0, (client_height - shown_height) / 2.0, shown_width, shown_height))
    }

    fn fraction(&self, x: i32, y: i32) -> Option<(f64, f64)> {
        let (left, top, width, height) = self.picture()?;
        Some((f64::from((x as f32 - left) / width), f64::from((y as f32 - top) / height)))
    }

    fn controlling(&self) -> bool {
        self.connected && self.can_control && !self.paused
    }

    fn flush_move(&mut self) {
        if let Some((x, y)) = self.pending_move.take() {
            self.last_move = Instant::now();
            self.send(ViewerCommand::Input(self.translator.pointer_move(x, y)));
        }
    }

    unsafe fn draw(&mut self) {
        unsafe {
            let mut client = RECT::default();
            let _ = GetClientRect(self.window, &mut client);
            let size = D2D_SIZE_U { width: (client.right - client.left).max(1) as u32, height: (client.bottom - client.top).max(1) as u32 };
            let format = D2D1_PIXEL_FORMAT { format: DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode: D2D1_ALPHA_MODE_IGNORE };
            if self.target.is_none() {
                let properties = D2D1_RENDER_TARGET_PROPERTIES { pixelFormat: format, dpiX: 96.0, dpiY: 96.0, ..Default::default() };
                let window = D2D1_HWND_RENDER_TARGET_PROPERTIES { hwnd: self.window, pixelSize: size, presentOptions: D2D1_PRESENT_OPTIONS_IMMEDIATELY };
                match self.factory.CreateHwndRenderTarget(&properties, &window) {
                    Ok(target) => self.target = Some(target),
                    Err(error) => return log::error!("the picture cannot be drawn: {error}"),
                }
                self.bitmap = None;
            }
            let Some(target) = self.target.clone() else { return };
            {
                let frame = self.frame.lock().unwrap();
                if frame.width > 0 && frame.bgra.len() == frame.width * frame.height * 4 {
                    if self.bitmap.as_ref().is_none_or(|(_, width, height)| (*width, *height) != (frame.width, frame.height)) {
                        let properties = D2D1_BITMAP_PROPERTIES { pixelFormat: format, dpiX: 96.0, dpiY: 96.0 };
                        let created = target.CreateBitmap(D2D_SIZE_U { width: frame.width as u32, height: frame.height as u32 }, None, 0, &properties);
                        self.bitmap = created.ok().map(|bitmap| (bitmap, frame.width, frame.height));
                    }
                    if let Some((bitmap, _, _)) = &self.bitmap {
                        let _ = bitmap.CopyFromMemory(None, frame.bgra.as_ptr().cast(), (frame.width * 4) as u32);
                    }
                }
            }
            let _ = target.Resize(&size);
            target.BeginDraw();
            target.Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 1.0 }));
            if let (Some((bitmap, _, _)), Some((left, top, width, height))) = (&self.bitmap, self.picture()) {
                let area = D2D_RECT_F { left, top, right: left + width, bottom: top + height };
                target.DrawBitmap(bitmap, Some(&area), 1.0, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, None);
            }
            if target.EndDraw(None, None).is_err() {
                // The device was lost; the next draw creates a new target.
                self.target = None;
                self.bitmap = None;
            }
        }
    }

    unsafe fn toggle_full_screen(&mut self) {
        unsafe {
            match self.full_screen.take() {
                Some((style, placement, menu)) => {
                    SetWindowLongPtrW(self.window, GWL_STYLE, style.0 as isize);
                    let _ = SetMenu(self.window, Some(menu));
                    let _ = SetWindowPlacement(self.window, &placement);
                    let _ = SetWindowPos(self.window, None, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
                }
                None => {
                    let style = WINDOW_STYLE(GetWindowLongPtrW(self.window, GWL_STYLE) as u32);
                    let mut placement = WINDOWPLACEMENT { length: size_of::<WINDOWPLACEMENT>() as u32, ..Default::default() };
                    let _ = GetWindowPlacement(self.window, &mut placement);
                    let menu = GetMenu(self.window);
                    let monitor = windows::Win32::Graphics::Gdi::MonitorFromWindow(self.window, windows::Win32::Graphics::Gdi::MONITOR_DEFAULTTONEAREST);
                    let mut info = windows::Win32::Graphics::Gdi::MONITORINFO {
                        cbSize: size_of::<windows::Win32::Graphics::Gdi::MONITORINFO>() as u32,
                        ..Default::default()
                    };
                    if !windows::Win32::Graphics::Gdi::GetMonitorInfoW(monitor, &mut info).as_bool() {
                        return;
                    }
                    self.full_screen = Some((style, placement, menu));
                    SetWindowLongPtrW(self.window, GWL_STYLE, (style & !WS_OVERLAPPEDWINDOW).0 as isize);
                    let _ = SetMenu(self.window, None);
                    let area = info.rcMonitor;
                    let _ = SetWindowPos(self.window, Some(HWND_TOP), area.left, area.top, area.right - area.left, area.bottom - area.top, SWP_FRAMECHANGED);
                }
            }
        }
    }

    /// Stops forwarding keys and tells the host to let go of everything.
    unsafe fn release(&mut self) {
        if let Some(hook) = self.hook.take() {
            let _ = unsafe { UnhookWindowsHookEx(hook) };
        }
        FOCUSED.set(std::ptr::null_mut());
        self.held.clear();
        self.pending_move = None;
        self.translator.release_all();
        if self.connected {
            self.send(ViewerCommand::ReleaseInput);
        }
    }

    /// Takes the keyboard, including the shortcuts Windows would otherwise keep for itself.
    unsafe fn capture_keyboard(&mut self) {
        if self.hook.is_none() && self.controlling() {
            FOCUSED.set(std::ptr::from_mut(self));
            self.hook = unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), None, 0) }.ok();
        }
    }

    /// One key event of this PC: a local shortcut, or input for the host.
    unsafe fn key(&mut self, virtual_key: u32, scan_code: u32, extended: bool, down: bool) {
        let repeat = down && !self.held.insert((scan_code, extended));
        if !down {
            self.held.remove(&(scan_code, extended));
        }
        let (control, alt) =
            (self.held.contains(&(0x1D, false)) || self.held.contains(&(0x1D, true)), self.held.contains(&(0x38, false)) || self.held.contains(&(0x38, true)));
        if control && alt && down && (virtual_key == u32::from(VK_RETURN.0) || virtual_key == u32::from(VK_ESCAPE.0)) {
            self.held.remove(&(scan_code, extended));
            unsafe {
                if virtual_key == u32::from(VK_RETURN.0) {
                    // The host never saw the Enter; the modifiers are released with the rest when focus changes.
                    self.toggle_full_screen();
                } else {
                    self.release();
                    self.set_title("已释放控制，点击画面继续");
                }
            }
            return;
        }
        if scan_code == 0x3A && !extended && down && !repeat {
            self.caps_lock = !self.caps_lock;
        }
        self.flush_move();
        let event = PcKeyEvent { scan_code: scan_code as u16, extended, virtual_key: virtual_key as u16, down, repeat };
        if let Some(input) = self.translator.key(event, self.caps_lock) {
            self.send(ViewerCommand::Input(input));
        }
    }

    unsafe fn session_event(&mut self, event: ViewerEvent) {
        match event {
            ViewerEvent::Connected { name, can_control, .. } => {
                self.name = name;
                self.connected = true;
                self.can_control = can_control;
                self.set_title(if can_control { "已连接，点击画面开始操作" } else { "已连接 · 仅观看" });
                let name = wide(&self.name);
                // The owner copies the text before this call returns.
                unsafe { SendMessageW(self.owner, WM_CANVAS_CONNECTED, Some(WPARAM(self.window.0 as usize)), Some(LPARAM(name.as_ptr() as isize))) };
            }
            ViewerEvent::Stream { stream, error } => match error {
                Some(error) => self.set_title(&format!("画质调整失败：{error}")),
                None => self.set_title(&format!("{} × {} · {}", stream.width, stream.height, stream.settings.summary())),
            },
            ViewerEvent::Control(can_control) => {
                self.can_control = can_control;
                if !can_control {
                    unsafe { self.release() };
                }
                self.set_title(if can_control { "被控端允许控制" } else { "仅观看（被控端已关闭控制）" });
            }
            ViewerEvent::Paused { paused, .. } => self.paused = paused,
            ViewerEvent::RoundTrip(_) | ViewerEvent::MediaCommitted(_) => {}
            ViewerEvent::ClipboardText(text) => match clipboard::set_text(&text) {
                Ok(()) => self.set_title("已接收远端剪贴板文字"),
                Err(error) => self.set_title(&error.to_string()),
            },
        }
    }
}

unsafe extern "system" fn keyboard_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        let canvas = FOCUSED.get();
        if code == HC_ACTION as i32 && !canvas.is_null() {
            let key = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
            let down = wparam.0 as u32 == WM_KEYDOWN || wparam.0 as u32 == WM_SYSKEYDOWN;
            (*canvas).key(key.vkCode, key.scanCode & 0xFF, key.flags.0 & LLKHF_EXTENDED.0 != 0, down);
            // The key belongs to the remote machine, whatever Windows would have done with it.
            return LRESULT(1);
        }
        CallNextHookEx(None, code, wparam, lparam)
    }
}

unsafe extern "system" fn window_procedure(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        let canvas = GetWindowLongPtrW(window, GWLP_USERDATA) as *mut Canvas;
        if canvas.is_null() {
            return DefWindowProcW(window, message, wparam, lparam);
        }
        let canvas = &mut *canvas;
        match message {
            WM_PAINT => {
                canvas.draw();
                let _ = ValidateRect(Some(window), None);
            }
            WM_ERASEBKGND => return LRESULT(1),
            WM_SESSION_FRAME => {
                canvas.mailbox.frame_posted.store(false, Ordering::Release);
                canvas.draw();
            }
            WM_SESSION_EVENT => {
                while let Some(event) = { canvas.mailbox.events.lock().unwrap().pop_front() } {
                    canvas.session_event(event);
                }
            }
            WM_SESSION_ENDED => {
                canvas.release();
                canvas.connected = false;
                let end = canvas.mailbox.ended.lock().unwrap().take();
                if let Some(end) = end.filter(|_| !canvas.closing) {
                    canvas.set_title(&format!("已结束：{}", end.reason));
                    let text = wide(&end.reason);
                    MessageBoxW(Some(window), PCWSTR(text.as_ptr()), w!("QuietDesk"), MB_OK | MB_ICONINFORMATION);
                }
                let _ = DestroyWindow(window);
            }
            WM_SIZE => {
                if canvas.connected {
                    let minimized = wparam.0 as u32 == SIZE_MINIMIZED;
                    if minimized != canvas.paused {
                        canvas.send(ViewerCommand::Pause(minimized));
                    }
                }
                canvas.draw();
            }
            WM_SETFOCUS => canvas.capture_keyboard(),
            WM_KILLFOCUS => canvas.release(),
            WM_SETCURSOR if (lparam.0 & 0xFFFF) as u32 == HTCLIENT && canvas.controlling() && canvas.hook.is_some() => {
                // The host draws its own pointer into the picture.
                SetCursor(None);
                return LRESULT(1);
            }
            WM_MOUSEMOVE if canvas.controlling() => {
                let (x, y) = point(lparam);
                if let Some(position) = canvas.fraction(x, y) {
                    canvas.pending_move = Some(position);
                    if canvas.last_move.elapsed() >= MOVE_INTERVAL {
                        canvas.flush_move();
                    } else {
                        SetTimer(Some(window), MOVE_TIMER, MOVE_INTERVAL.as_millis() as u32, None);
                    }
                }
            }
            WM_TIMER if wparam.0 == MOVE_TIMER => {
                let _ = KillTimer(Some(window), MOVE_TIMER);
                canvas.flush_move();
            }
            WM_LBUTTONDOWN | WM_LBUTTONUP | WM_RBUTTONDOWN | WM_RBUTTONUP | WM_MBUTTONDOWN | WM_MBUTTONUP | WM_XBUTTONDOWN | WM_XBUTTONUP
                if canvas.controlling() =>
            {
                let down = matches!(message, WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN | WM_XBUTTONDOWN);
                let button = match message {
                    WM_LBUTTONDOWN | WM_LBUTTONUP => 0,
                    WM_RBUTTONDOWN | WM_RBUTTONUP => 1,
                    WM_MBUTTONDOWN | WM_MBUTTONUP => 2,
                    _ => 2 + ((wparam.0 >> 16) & 0xFFFF) as i64,
                };
                if down {
                    canvas.capture_keyboard();
                    SetCapture(window);
                } else {
                    let _ = ReleaseCapture();
                }
                let (x, y) = point(lparam);
                if let Some((fraction_x, fraction_y)) = canvas.fraction(x, y) {
                    canvas.flush_move();
                    let input = canvas.translator.button(button, down, fraction_x, fraction_y, canvas.started.elapsed(), (x, y));
                    canvas.send(ViewerCommand::Input(input));
                }
            }
            WM_MOUSEWHEEL | WM_MOUSEHWHEEL if canvas.controlling() => {
                let notches = f64::from(((wparam.0 >> 16) & 0xFFFF) as i16) / 120.0;
                let (x, y) = point(lparam);
                let mut position = POINT { x, y };
                let _ = ScreenToClient(window, &mut position);
                if let Some((fraction_x, fraction_y)) = canvas.fraction(position.x, position.y) {
                    canvas.flush_move();
                    let (vertical, horizontal) = if message == WM_MOUSEWHEEL { (notches, 0.0) } else { (0.0, notches) };
                    canvas.send(ViewerCommand::Input(canvas.translator.wheel(vertical, horizontal, fraction_x, fraction_y)));
                }
            }
            // Without the hook, keys still arrive as messages, minus the ones Windows keeps.
            WM_KEYDOWN | WM_SYSKEYDOWN | WM_KEYUP | WM_SYSKEYUP if canvas.hook.is_none() && canvas.controlling() => {
                let down = matches!(message, WM_KEYDOWN | WM_SYSKEYDOWN);
                canvas.key(wparam.0 as u32, ((lparam.0 >> 16) & 0xFF) as u32, lparam.0 & (1 << 24) != 0, down);
            }
            WM_COMMAND => match wparam.0 & 0xFFFF {
                MENU_FULL_SCREEN => canvas.toggle_full_screen(),
                MENU_SEND_CLIPBOARD => match clipboard::text() {
                    Some(text) => canvas.send(ViewerCommand::SendClipboard(text)),
                    None => canvas.set_title("本机剪贴板中没有文字"),
                },
                MENU_REQUEST_CLIPBOARD => canvas.send(ViewerCommand::RequestClipboard),
                MENU_DISCONNECT => {
                    canvas.closing = true;
                    canvas.send(ViewerCommand::Disconnect);
                }
                id if (MENU_QUALITY..MENU_QUALITY + VIEWER_QUALITIES.len()).contains(&id) => {
                    canvas.send(ViewerCommand::Quality(VIEWER_QUALITIES[id - MENU_QUALITY].1))
                }
                _ => {}
            },
            WM_CLOSE => {
                // The session ends first; its ending closes the window.
                canvas.closing = true;
                if canvas.mailbox.ended.lock().unwrap().is_none() && canvas.commands.send(ViewerCommand::Disconnect).is_ok() {
                    return LRESULT(0);
                }
                let _ = DestroyWindow(window);
            }
            WM_NCDESTROY => {
                canvas.release();
                SetWindowLongPtrW(window, GWLP_USERDATA, 0);
                drop(Box::from_raw(std::ptr::from_mut(canvas)));
                return DefWindowProcW(window, message, wparam, lparam);
            }
            _ => return DefWindowProcW(window, message, wparam, lparam),
        }
        LRESULT(0)
    }
}
