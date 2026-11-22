//! The viewer's window: draws the host's picture and sends this PC's keyboard and mouse to it.

use super::app::{DisplayGeometry, Frame, ViewerSink, run_viewer};
use super::clipboard;
use super::relative_mouse::RelativeMouse;
use super::settings::{Settings, VIEWER_QUALITIES};
use super::util::{display_label, wide};
use super::viewer_cursor::ViewerCursor;
use quietdesk_core::cursor::CursorPresentationState;
use quietdesk_core::display::RemoteDisplayInfo;
use quietdesk_core::input::{CapsLockPress, DoubleClick, PcKeyEvent, ViewerInputTranslator};
use quietdesk_core::media::MediaStreamId;
use quietdesk_core::messages::{InputKind, RemoteInput};
use quietdesk_core::pairing::PairingKey;
use quietdesk_core::reliability::{RetryStatus, ViewerControl};
use quietdesk_core::viewer::{ViewerCommand, ViewerEnd, ViewerEvent};
use std::cell::Cell;
use std::collections::{BTreeSet, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};
use tokio::sync::watch;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::{DEFAULT_GUI_FONT, GetStockObject, ScreenToClient, ValidateRect};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::WM_MOUSELEAVE;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::HRAWINPUT;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    EnableWindow, GetAsyncKeyState, GetCapture, GetDoubleClickTime, GetFocus, MAPVK_VSC_TO_VK_EX, MapVirtualKeyW, ReleaseCapture, SetCapture, SetFocus,
    TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent, VIRTUAL_KEY, VK_CONTROL, VK_ESCAPE, VK_LCONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_MENU, VK_RCONTROL,
    VK_RETURN, VK_RMENU, VK_RSHIFT, VK_RWIN, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

const WM_SESSION_EVENT: u32 = WM_APP + 1;
const WM_SESSION_FRAME: u32 = WM_APP + 2;
const WM_SESSION_ENDED: u32 = WM_APP + 3;
/// Sent to the owner window when a session reports the host's name: the canvas window and the name's text.
pub const WM_CANVAS_CONNECTED: u32 = WM_APP + 20;
pub const WM_CANVAS_CLOSED: u32 = WM_APP + 21;
pub const WM_CAPS_PREFERENCE: u32 = WM_APP + 22;
const MOVE_TIMER: usize = 1;
const RETRY_TIMER: usize = 2;
const IDLE_TIMER: usize = 3;
const IDLE_TIMEOUT: Duration = Duration::from_secs(600);
const MOVE_INTERVAL: Duration = Duration::from_millis(8);
const MENU_FULL_SCREEN: usize = 100;
const MENU_SEND_CLIPBOARD: usize = 101;
const MENU_REQUEST_CLIPBOARD: usize = 102;
const MENU_DISCONNECT: usize = 103;
const RETRY_NOW: usize = 104;
const CANCEL_RETRY: usize = 105;
const MENU_CAPS_ACTIONS: usize = 106;
const MENU_RELATIVE_MOUSE: usize = 107;
const MENU_QUALITY: usize = 200;
const MENU_DISPLAY: usize = 300;

/// What the session threads leave for the window thread.
enum Notice {
    Session(ViewerEvent),
    Retry { status: RetryStatus, serial: u64, generation: u64 },
}

struct Mailbox {
    window: isize,
    events: Mutex<VecDeque<Notice>>,
    frame: Arc<Mutex<Frame>>,
    generation: AtomicU64,
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
        let mut events = self.events.lock().unwrap();
        // A newer snapshot includes the previous shape and position. One pending notification suffices.
        if matches!(event, ViewerEvent::Cursor(_)) && matches!(events.back(), Some(Notice::Session(ViewerEvent::Cursor(_)))) {
            *events.back_mut().unwrap() = Notice::Session(event);
            return;
        }
        events.push_back(Notice::Session(event));
        drop(events);
        self.post(WM_SESSION_EVENT);
    }

    fn retry(&self, status: RetryStatus) {
        // Invalidate input even if the window thread has not yet processed its disconnect.
        let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        let serial = self.frame.lock().unwrap().serial;
        let mut events = self.events.lock().unwrap();
        events.clear();
        events.push_back(Notice::Retry { status, serial, generation });
        drop(events);
        self.post(WM_SESSION_EVENT);
    }

    fn frame_ready(&self, _stream: Option<quietdesk_core::media::MediaStreamId>) {
        // One pending message is enough: the window always draws the latest picture.
        if !self.frame_posted.swap(true, Ordering::AcqRel) {
            self.post(WM_SESSION_FRAME);
        }
    }
}

#[derive(Clone, Copy)]
enum PendingMove {
    Absolute(f64, f64),
    Relative(f64, f64),
}

impl PendingMove {
    fn relative(dx: f64, dy: f64) -> Self {
        let limit = RemoteInput::MAXIMUM_POINTER_DELTA;
        Self::Relative(dx.clamp(-limit, limit), dy.clamp(-limit, limit))
    }

    fn accumulating(self, earlier: Option<Self>) -> Self {
        match (self, earlier) {
            (Self::Relative(x, y), Some(Self::Relative(px, py))) => Self::relative(px + x, py + y),
            (latest, _) => latest,
        }
    }
}

struct Canvas {
    window: HWND,
    owner: HWND,
    commands: UnboundedSender<ViewerControl>,
    mailbox: Arc<Mailbox>,
    generation: u64,
    target: Option<ID2D1HwndRenderTarget>,
    bitmap: Option<(ID2D1Bitmap, usize, usize)>,
    uploaded_serial: Option<u64>,
    uploaded_display: Option<DisplayGeometry>,
    presented_display: Option<DisplayGeometry>,
    displays: DisplayMenu,
    drawn_stream: Option<MediaStreamId>,
    latest_cursor: Arc<CursorPresentationState>,
    shown_cursor: Option<Arc<CursorPresentationState>>,
    cursor: ViewerCursor,
    local_pointer: bool,
    factory: ID2D1Factory,
    translator: ViewerInputTranslator,
    started: Instant,
    name: String,
    connected: bool,
    can_control: bool,
    supports_pause: bool,
    retry: Option<RetryStatus>,
    retry_panel: RetryPanel,
    fresh_after: Option<u64>,
    held: BTreeSet<(u32, bool)>,
    withheld_keys: BTreeSet<u16>,
    caps_lock: bool,
    caps_press: CapsLockPress,
    caps_forwarding: bool,
    supports_input_actions: bool,
    session_menu: HMENU,
    hook: Option<HHOOK>,
    relative_supported: bool,
    relative_enabled: bool,
    relative_mouse: Option<RelativeMouse>,
    pending_move: Option<PendingMove>,
    last_move: Instant,
    full_screen: Option<(WINDOW_STYLE, WINDOWPLACEMENT, HMENU)>,
    paused: bool,
    pending_pause: Option<bool>,
    attention: Attention,
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
    settings: &Settings,
    mut auto_reconnect: watch::Receiver<bool>,
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
        let factory = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;
        let menu = CreateMenu()?;
        let session = CreatePopupMenu()?;
        AppendMenuW(session, MF_STRING, MENU_FULL_SCREEN, w!("全屏\tCtrl+Alt+Enter"))?;
        AppendMenuW(session, MF_STRING | MF_GRAYED, MENU_CAPS_ACTIONS, w!("独立转发 Caps Lock（短按切输入法，长按切大写）"))?;
        AppendMenuW(session, MF_STRING | MF_GRAYED, MENU_RELATIVE_MOUSE, w!("相对鼠标（Ctrl+Alt+Esc 释放）"))?;
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
        let displays = DisplayMenu::new(menu)?;
        let title = wide(&format!("QuietDesk · 正在连接 {address}…"));
        let window = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            PCWSTR(title.as_ptr()),
            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            1280,
            800,
            None,
            Some(menu),
            Some(instance),
            None,
        )?;
        let retry_panel = match RetryPanel::new(window, instance) {
            Ok(panel) => panel,
            Err(error) => {
                let _ = DestroyWindow(window);
                return Err(error);
            }
        };
        let (commands, queue) = unbounded_channel();
        let frame = Arc::new(Mutex::new(Frame::default()));
        let mailbox = Arc::new(Mailbox {
            window: window.0 as isize,
            events: Mutex::new(VecDeque::new()),
            frame: frame.clone(),
            generation: AtomicU64::new(0),
            ended: Mutex::new(None),
            frame_posted: AtomicBool::new(false),
        });
        let double_click = DoubleClick { interval: Duration::from_millis(u64::from(GetDoubleClickTime())), distance: GetSystemMetrics(SM_CXDOUBLECLK) / 2 };
        let quality = settings.viewer_quality();
        let preferences = commands.clone();
        let enabled = *auto_reconnect.borrow_and_update();
        let canvas = Box::new(Canvas {
            window,
            owner,
            commands,
            mailbox: mailbox.clone(),
            generation: 0,
            target: None,
            bitmap: None,
            uploaded_serial: None,
            uploaded_display: None,
            presented_display: None,
            displays,
            drawn_stream: None,
            latest_cursor: Arc::default(),
            shown_cursor: None,
            cursor: ViewerCursor::default(),
            local_pointer: false,
            factory,
            translator: ViewerInputTranslator::new(settings.pc_modifiers, double_click),
            started: Instant::now(),
            name: address.clone(),
            connected: false,
            can_control: false,
            supports_pause: false,
            retry: None,
            retry_panel,
            fresh_after: Some(0),
            held: BTreeSet::new(),
            withheld_keys: BTreeSet::new(),
            caps_lock: false,
            caps_press: CapsLockPress::default(),
            caps_forwarding: settings.caps_forwarding,
            supports_input_actions: false,
            session_menu: session,
            hook: None,
            pending_move: None,
            relative_supported: false,
            relative_enabled: false,
            relative_mouse: None,
            last_move: Instant::now(),
            full_screen: None,
            paused: false,
            pending_pause: None,
            attention: Attention::default(),
            closing: false,
        });
        SetWindowLongPtrW(window, GWLP_USERDATA, Box::into_raw(canvas) as isize);
        let _ = ShowWindow(window, SW_SHOW);
        runtime.spawn(async move {
            let session = run_viewer((address, port), key, quality, enabled, queue, frame, mailbox.clone());
            tokio::pin!(session);
            let end = loop {
                tokio::select! {
                    end = &mut session => break end,
                    changed = auto_reconnect.changed() => {
                        if changed.is_err() { break session.await; }
                        let _ = preferences.send(ViewerControl::AutoReconnect(*auto_reconnect.borrow_and_update()));
                    }
                }
            };
            *mailbox.ended.lock().unwrap() = Some(end);
            mailbox.post(WM_SESSION_ENDED);
        });
        Ok(window)
    }
}

fn point(lparam: LPARAM) -> (i32, i32) {
    ((lparam.0 & 0xFFFF) as i16 as i32, ((lparam.0 >> 16) & 0xFFFF) as i16 as i32)
}

fn local_key(held: &mut BTreeSet<u16>, key: u16, down: bool) -> bool {
    if down && held.iter().any(|&k| matches!(VIRTUAL_KEY(k), VK_LCONTROL | VK_RCONTROL | VK_LSHIFT | VK_RSHIFT | VK_LMENU | VK_RMENU | VK_LWIN | VK_RWIN)) {
        held.insert(key);
    }
    if down { held.contains(&key) } else { held.remove(&key) }
}

#[derive(Default)]
struct Attention {
    away_since: Option<Instant>,
    idle: bool,
}

impl Attention {
    fn update(&mut self, now: Instant, attended: bool, minimized: bool) {
        if attended && !minimized {
            self.away_since = None;
            self.idle = false;
        } else {
            let since = self.away_since.get_or_insert(now);
            self.idle |= minimized || now.duration_since(*since) >= IDLE_TIMEOUT;
        }
    }
}

struct DisplayMenu {
    parent: HMENU,
    popup: HMENU,
    position: u32,
    ids: Vec<u32>,
    selected: Option<DisplayGeometry>,
    pending: bool,
}

impl DisplayMenu {
    fn shows(&self, display: Option<DisplayGeometry>) -> bool {
        // The first topology can arrive after an older host already sent its opening picture.
        !self.pending && (display == self.selected || (display.is_none() && self.selected.is_some_and(|selected| selected.revision == 0)))
    }

    unsafe fn new(parent: HMENU) -> windows::core::Result<Self> {
        unsafe {
            let position = GetMenuItemCount(Some(parent)) as u32;
            let popup = CreatePopupMenu()?;
            AppendMenuW(parent, MF_POPUP | MF_GRAYED, popup.0 as usize, w!("显示器"))?;
            Ok(Self { parent, popup, position, ids: Vec::new(), selected: None, pending: false })
        }
    }

    unsafe fn update(&mut self, window: HWND, displays: &[RemoteDisplayInfo], selected: Option<DisplayGeometry>, pending: bool) -> windows::core::Result<()> {
        self.selected = selected;
        self.pending = pending;
        self.ids.clear();
        unsafe {
            let _ = EnableMenuItem(self.parent, self.position, MF_BYPOSITION | MF_GRAYED);
            for index in (0..GetMenuItemCount(Some(self.popup))).rev() {
                DeleteMenu(self.popup, index as u32, MF_BYPOSITION)?;
            }
            for display in displays {
                let flags = if Some(display.id) == selected.map(|s| s.id) { MF_STRING | MF_CHECKED } else { MF_STRING };
                let label = wide(&display_label(display).replace('&', "&&"));
                AppendMenuW(self.popup, flags, MENU_DISPLAY + self.ids.len(), PCWSTR(label.as_ptr()))?;
                self.ids.push(display.id);
            }
            if !self.ids.is_empty() && !pending {
                let _ = EnableMenuItem(self.parent, self.position, MF_BYPOSITION | MF_ENABLED);
            }
            DrawMenuBar(window)
        }
    }
}

struct RetryPanel {
    status: HWND,
    retry: HWND,
    cancel: HWND,
}

impl RetryPanel {
    unsafe fn new(window: HWND, instance: HINSTANCE) -> windows::core::Result<Self> {
        unsafe {
            let control = |class, title, id, style| -> windows::core::Result<HWND> {
                let child =
                    CreateWindowExW(WINDOW_EX_STYLE(0), class, title, WS_CHILD | style, 0, 0, 0, 0, Some(window), Some(HMENU(id as _)), Some(instance), None)?;
                SendMessageW(child, WM_SETFONT, Some(WPARAM(GetStockObject(DEFAULT_GUI_FONT).0 as usize)), Some(LPARAM(0)));
                Ok(child)
            };
            Ok(Self {
                status: control(w!("STATIC"), w!(""), 0, WINDOW_STYLE(0))?,
                retry: control(w!("BUTTON"), w!("立即重试"), RETRY_NOW, WS_TABSTOP)?,
                cancel: control(w!("BUTTON"), w!("取消重连"), CANCEL_RETRY, WS_TABSTOP)?,
            })
        }
    }

    unsafe fn layout(&self, window: HWND) {
        unsafe {
            let mut client = RECT::default();
            let _ = GetClientRect(window, &mut client);
            let dpi = GetDpiForWindow(window).max(96) as i32;
            let px = |value| value * dpi / 96;
            let button = px(92).min(client.right / 2);
            let flags = SWP_NOZORDER | SWP_NOACTIVATE;
            let _ = SetWindowPos(self.status, None, 0, 0, client.right, px(30), flags);
            let _ = SetWindowPos(self.retry, None, 0, px(30), button, px(30), flags);
            let _ = SetWindowPos(self.cancel, None, button, px(30), button, px(30), flags);
        }
    }

    unsafe fn visible(&self, visible: bool) {
        unsafe {
            for control in [self.status, self.retry, self.cancel] {
                let _ = ShowWindow(control, if visible { SW_SHOWNA } else { SW_HIDE });
            }
        }
    }
}

fn retry_title(status: &RetryStatus, now: Instant) -> String {
    match status {
        RetryStatus::Waiting { attempt, deadline, reason } => {
            let remaining = deadline.saturating_duration_since(now);
            if remaining.is_zero() {
                format!("第 {attempt} 次重连即将开始 · {reason}")
            } else {
                let seconds = remaining.as_secs() + u64::from(remaining.subsec_nanos() != 0);
                format!("第 {attempt} 次重连，{seconds} 秒后重试 · {reason}")
            }
        }
        RetryStatus::Connecting { attempt } => format!("正在进行第 {attempt} 次重连…"),
        RetryStatus::Deferred { reason } => format!("已暂停重连，返回窗口后继续 · {reason}"),
    }
}

impl Canvas {
    fn send(&self, mut command: ViewerCommand) {
        if let ViewerCommand::Input(mut input) = command {
            if self.uses_caps_actions() {
                input.independent_caps_lock = Some(true);
            }
            if self.relative_mouse.is_some() && matches!(input.kind, InputKind::Down | InputKind::Up | InputKind::Scroll) {
                input = input.at_current_pointer();
            }
            command = ViewerCommand::Input(input);
        }
        if self.current_generation() {
            let _ = self.commands.send(command.into());
        }
    }

    fn uses_caps_actions(&self) -> bool {
        self.caps_forwarding && self.supports_input_actions && self.hook.is_some() && self.controlling() && self.owns_input()
    }

    fn update_input_menu(&self) {
        for (id, supported, selected) in
            [(MENU_CAPS_ACTIONS, self.supports_input_actions, self.caps_forwarding), (MENU_RELATIVE_MOUSE, self.relative_supported, self.relative_enabled)]
        {
            let enabled = self.connected && supported;
            unsafe {
                let _ = EnableMenuItem(self.session_menu, id as u32, if enabled { MF_ENABLED } else { MF_GRAYED });
                CheckMenuItem(self.session_menu, id as u32, if enabled && selected { MF_CHECKED.0 } else { MF_UNCHECKED.0 });
            }
        }
    }

    fn capture_relative_mouse(&mut self) {
        if !self.relative_enabled
            || !self.relative_supported
            || self.relative_mouse.is_some()
            || !self.controlling()
            || !self.owns_input()
            || self.hook.is_none()
        {
            return;
        }
        let Some((x, y, w, h)) = self.picture() else { return };
        self.flush_move();
        match RelativeMouse::capture(self.window, POINT { x: (x + w / 2.0) as i32, y: (y + h / 2.0) as i32 }) {
            Ok(mouse) => {
                self.relative_mouse = Some(mouse);
                self.update_pointer();
                self.set_title("相对鼠标已锁定，Ctrl+Alt+Esc 释放");
            }
            Err(error) => {
                self.relative_enabled = false;
                self.update_input_menu();
                self.set_title(&format!("无法锁定相对鼠标：{error}"));
            }
        }
    }

    fn current_generation(&self) -> bool {
        self.generation == self.mailbox.generation.load(Ordering::Acquire)
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
        self.connected
            && self.can_control
            && self.current_generation()
            && !self.closing
            && !self.attention.idle
            && !self.paused
            && self.pending_pause.is_none()
            && self.fresh_after.is_none()
            && self.displays.shows(self.presented_display)
    }

    fn independent(&self) -> bool {
        self.shown_cursor.as_ref().is_some_and(|state| state.enabled)
    }

    fn owns_input(&self) -> bool {
        std::ptr::eq(FOCUSED.get(), self)
    }

    fn inside_picture(position: (f64, f64)) -> bool {
        (0.0..1.0).contains(&position.0) && (0.0..1.0).contains(&position.1)
    }

    fn pointer_in_client(&self) -> Option<(i32, i32)> {
        unsafe {
            let mut point = POINT::default();
            GetCursorPos(&mut point).ok()?;
            if WindowFromPoint(point) != self.window || !ScreenToClient(self.window, &mut point).as_bool() {
                return None;
            }
            let mut rect = RECT::default();
            GetClientRect(self.window, &mut rect).ok()?;
            (point.x >= 0 && point.x < rect.right && point.y >= 0 && point.y < rect.bottom).then_some((point.x, point.y))
        }
    }

    fn update_pointer(&mut self) {
        let position = self.pointer_in_client();
        let owns = self.controlling() && self.owns_input();
        self.local_pointer = self.relative_mouse.is_none() && owns && position.and_then(|(x, y)| self.fraction(x, y)).is_some_and(Self::inside_picture);
        if position.is_none() {
            return;
        }
        let independent = self.independent();
        unsafe {
            let handle = if self.relative_mouse.is_some() {
                None
            } else if independent && self.local_pointer {
                self.cursor.handle()
            } else if !independent && self.controlling() && self.hook.is_some() {
                None
            } else {
                LoadCursorW(None, IDC_ARROW).ok()
            };
            SetCursor(handle);
        }
    }

    fn flush_move(&mut self) {
        if let Some(movement) = self.pending_move.take()
            && self.controlling()
            && self.owns_input()
        {
            self.last_move = Instant::now();
            let input = match movement {
                PendingMove::Absolute(x, y) => self.translator.pointer_move(x, y),
                PendingMove::Relative(dx, dy) if self.relative_mouse.is_some() => {
                    let Some(input) = self.translator.relative_pointer_move(dx, dy) else { return };
                    input
                }
                _ => return,
            };
            self.send(ViewerCommand::Input(input));
        }
    }

    fn pace_move(&mut self, movement: PendingMove) {
        self.pending_move = Some(movement.accumulating(self.pending_move.take()));
        if self.last_move.elapsed() >= MOVE_INTERVAL {
            self.flush_move();
        } else {
            unsafe { SetTimer(Some(self.window), MOVE_TIMER, MOVE_INTERVAL.as_millis() as u32, None) };
        }
    }

    unsafe fn draw(&mut self) {
        unsafe {
            let mut client = RECT::default();
            let _ = GetClientRect(self.window, &mut client);
            let size = D2D_SIZE_U { width: (client.right - client.left).max(1) as u32, height: (client.bottom - client.top).max(1) as u32 };
            let format = D2D1_PIXEL_FORMAT { format: DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode: D2D1_ALPHA_MODE_IGNORE };
            if self.target.is_none() {
                let properties = D2D1_RENDER_TARGET_PROPERTIES {
                    pixelFormat: format,
                    dpiX: 96.0,
                    dpiY: 96.0,
                    usage: D2D1_RENDER_TARGET_USAGE_GDI_COMPATIBLE,
                    ..Default::default()
                };
                let window = D2D1_HWND_RENDER_TARGET_PROPERTIES { hwnd: self.window, pixelSize: size, presentOptions: D2D1_PRESENT_OPTIONS_IMMEDIATELY };
                match self.factory.CreateHwndRenderTarget(&properties, &window) {
                    Ok(target) => self.target = Some(target),
                    Err(error) => return log::error!("the picture cannot be drawn: {error}"),
                }
                self.bitmap = None;
                self.uploaded_serial = None;
            }
            let Some(target) = self.target.clone() else { return };
            {
                let frame = self.mailbox.frame.lock().unwrap();
                if frame.width > 0 && self.uploaded_serial != Some(frame.serial) && frame.bgra.len() == frame.width * frame.height * 4 {
                    let pixels = frame.bgra.as_ptr().cast();
                    let stride = (frame.width * 4) as u32;
                    let copied = if let Some((bitmap, _, _)) = self.bitmap.as_ref().filter(|(_, w, h)| (*w, *h) == (frame.width, frame.height)) {
                        bitmap.CopyFromMemory(None, pixels, stride).is_ok()
                    } else {
                        let properties = D2D1_BITMAP_PROPERTIES { pixelFormat: format, dpiX: 96.0, dpiY: 96.0 };
                        let size = D2D_SIZE_U { width: frame.width as u32, height: frame.height as u32 };
                        target
                            .CreateBitmap(size, Some(pixels), stride, &properties)
                            .map(|bitmap| self.bitmap = Some((bitmap, frame.width, frame.height)))
                            .is_ok()
                    };
                    if copied {
                        self.uploaded_serial = Some(frame.serial);
                        self.uploaded_display = frame.display;
                        self.drawn_stream = frame.stream;
                    }
                }
            }
            let _ = target.Resize(&size);
            target.BeginDraw();
            target.Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 1.0 }));
            let painted = if let (Some((bitmap, _, _)), Some((left, top, width, height))) = (&self.bitmap, self.picture()) {
                let area = D2D_RECT_F { left, top, right: left + width, bottom: top + height };
                target.DrawBitmap(bitmap, Some(&area), 1.0, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, None);
                true
            } else {
                false
            };
            let fresh = painted && self.fresh_after.zip(self.uploaded_serial).is_some_and(|(old, serial)| serial > old);
            if !self.connected || !self.displays.shows(self.uploaded_display) || (self.fresh_after.is_some() && !fresh) {
                self.shown_cursor = None;
            } else if self.latest_cursor.committed_stream() == self.drawn_stream {
                self.shown_cursor = Some(self.latest_cursor.clone());
            } else if self.shown_cursor.as_ref().is_some_and(|s| s.committed_stream() != self.drawn_stream) {
                self.shown_cursor = None;
            }
            let shape = self.shown_cursor.as_ref().filter(|s| s.enabled).and_then(|s| s.image.as_ref());
            self.cursor.update(shape, GetDpiForWindow(self.window).max(96));
            self.update_pointer();
            if !self.local_pointer
                && let Some(pos) = self.shown_cursor.as_ref().filter(|s| s.enabled).and_then(|s| s.position.as_ref()).filter(|p| p.inside_display)
                && let Some(rect) = self.picture()
                && let Err(error) = self.cursor.draw(&target, rect, pos.x, pos.y)
            {
                log::debug!("could not draw the independent cursor: {error}");
            }
            if target.EndDraw(None, None).is_err() {
                self.target = None;
                self.bitmap = None;
            } else if painted {
                let changed_display = self.presented_display != self.uploaded_display;
                self.presented_display = self.uploaded_display;
                if self.connected && fresh {
                    self.fresh_after = None;
                }
                if changed_display || fresh {
                    self.update_pointer();
                }
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
        self.caps_press.reset();
        self.relative_mouse.take();
        if let Some(hook) = self.hook.take() {
            let _ = unsafe { UnhookWindowsHookEx(hook) };
        }
        if self.owns_input() {
            FOCUSED.set(std::ptr::null_mut());
        }
        self.held.clear();
        self.withheld_keys.clear();
        self.pending_move = None;
        self.translator.release_all();
        unsafe {
            let _ = KillTimer(Some(self.window), MOVE_TIMER);
            if GetCapture() == self.window {
                let _ = ReleaseCapture();
            }
        }
        if self.connected {
            self.send(ViewerCommand::ReleaseInput);
        }
    }

    /// Takes the keyboard, including the shortcuts Windows would otherwise keep for itself.
    unsafe fn capture_keyboard(&mut self) {
        if !self.owns_input() && self.controlling() && unsafe { GetFocus() } == self.window {
            // A press that began while the window had no control must finish locally.
            self.withheld_keys = (8..=254).filter(|&key| unsafe { GetAsyncKeyState(i32::from(key)) } < 0).collect();
            FOCUSED.set(std::ptr::from_mut(self));
            self.hook = unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), None, 0) }.ok();
            if self.hook.is_none() && self.caps_forwarding && self.supports_input_actions {
                self.set_title("键盘监听未就绪，Caps Lock 独立转发未启用");
            }
        }
        self.capture_relative_mouse();
    }

    /// One key event of this PC: a local shortcut, or input for the host.
    unsafe fn key(&mut self, virtual_key: u32, scan_code: u32, extended: bool, down: bool) -> bool {
        // WM_KEY messages use generic modifier keys; the hook and the physical snapshot distinguish their sides.
        let physical_key = if matches!(VIRTUAL_KEY(virtual_key as u16), VK_SHIFT | VK_CONTROL | VK_MENU) {
            unsafe { MapVirtualKeyW(scan_code | if extended { 0xe000 } else { 0 }, MAPVK_VSC_TO_VK_EX) as u16 }
        } else {
            virtual_key as u16
        };
        if local_key(&mut self.withheld_keys, physical_key, down) {
            return false;
        }
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
                    self.draw();
                    self.set_title("已释放控制，点击画面继续");
                }
            }
            return true;
        }
        if scan_code == 0x3A && !extended {
            if self.uses_caps_actions() {
                if let Some(action) = self.caps_press.update(down, self.started.elapsed()) {
                    self.flush_move();
                    self.send(ViewerCommand::Input(action.remote_input()));
                }
                return true;
            }
            if down && !repeat {
                self.caps_lock = !self.caps_lock;
            }
        }
        self.flush_move();
        let event = PcKeyEvent { scan_code: scan_code as u16, extended, virtual_key: virtual_key as u16, down, repeat };
        if let Some(input) = self.translator.key(event, self.caps_lock) {
            self.send(ViewerCommand::Input(input));
        }
        true
    }

    unsafe fn update_retry_title(&self) {
        if let Some(status) = &self.retry {
            let title = retry_title(status, Instant::now());
            self.set_title(&title);
            let _ = unsafe { SetWindowTextW(self.retry_panel.status, PCWSTR(wide(&title).as_ptr())) };
        }
    }

    unsafe fn retry_event(&mut self, status: RetryStatus, serial: u64) {
        unsafe {
            self.connected = false;
            self.supports_input_actions = false;
            self.relative_enabled = false;
            self.relative_supported = false;
            self.update_input_menu();
            let _ = self.displays.update(self.window, &[], None, false);
            self.can_control = false;
            self.release();
            self.paused = false;
            self.pending_pause = None;
            self.fresh_after = Some(serial);
            self.latest_cursor = Arc::default();
            self.shown_cursor = None;
            let waiting = matches!(status, RetryStatus::Waiting { .. });
            self.retry = Some(status);
            let _ = KillTimer(Some(self.window), RETRY_TIMER);
            if waiting {
                SetTimer(Some(self.window), RETRY_TIMER, 1000, None);
            }
            let _ = EnableWindow(self.retry_panel.retry, waiting);
            self.update_retry_title();
            self.retry_panel.layout(self.window);
            self.retry_panel.visible(true);
            self.draw();
        }
    }

    fn reconcile_pause(&mut self) {
        if self.connected && self.supports_pause && self.pending_pause.is_none() && self.attention.idle != self.paused {
            self.pending_pause = Some(self.attention.idle);
            if !self.attention.idle {
                self.fresh_after = Some(self.mailbox.frame.lock().unwrap().serial);
            }
            self.send(ViewerCommand::Pause(self.attention.idle));
        }
    }

    unsafe fn update_attention(&mut self, active: bool, visible: bool, minimized: bool) {
        unsafe {
            let now = Instant::now();
            let was_idle = self.attention.idle;
            self.attention.update(now, active && visible, minimized);
            let _ = KillTimer(Some(self.window), IDLE_TIMER);
            if !self.attention.idle
                && let Some(since) = self.attention.away_since
            {
                let remaining = IDLE_TIMEOUT.saturating_sub(now.duration_since(since));
                SetTimer(Some(self.window), IDLE_TIMER, remaining.as_millis().max(1) as u32, None);
            }
            if was_idle != self.attention.idle {
                if self.attention.idle {
                    self.release();
                }
                let _ = self.commands.send(ViewerControl::Idle(self.attention.idle));
                self.reconcile_pause();
            }
        }
    }

    unsafe fn disconnect(&mut self) {
        if !self.closing {
            self.closing = true;
            unsafe { self.release() };
            self.connected = false;
            let _ = self.commands.send(ViewerCommand::Disconnect.into());
        }
    }

    unsafe fn session_event(&mut self, event: ViewerEvent) {
        match event {
            ViewerEvent::Connected { name, can_control, session_pause, input_actions, relative_mouse, .. } => {
                if self.retry.take().is_some() {
                    unsafe {
                        let _ = KillTimer(Some(self.window), RETRY_TIMER);
                        self.retry_panel.visible(false);
                    }
                }
                self.name = name;
                self.connected = true;
                self.can_control = can_control;
                self.supports_pause = session_pause;
                self.supports_input_actions = input_actions;
                self.relative_supported = relative_mouse;
                self.update_input_menu();
                self.reconcile_pause();
                self.set_title(if can_control { "已连接，点击画面开始操作" } else { "已连接 · 仅观看" });
                let name = wide(&self.name);
                // The owner copies the text before this call returns.
                unsafe {
                    SendMessageW(self.owner, WM_CANVAS_CONNECTED, Some(WPARAM(self.window.0 as usize)), Some(LPARAM(name.as_ptr() as isize)));
                    self.draw();
                }
            }
            ViewerEvent::Stream { stream, error } => match error {
                Some(error) => self.set_title(&format!("画质调整失败：{error}")),
                None => self.set_title(&format!("{} × {} · {}", stream.width, stream.height, stream.settings.summary())),
            },
            ViewerEvent::Displays { displays, selected, pending, error, revision } => unsafe {
                let next = DisplayGeometry::selected(&displays, selected, revision);
                if self.displays.selected != next || pending.is_some() {
                    self.release();
                }
                if let Err(cause) = self.displays.update(self.window, &displays, next, pending.is_some()) {
                    log::warn!("could not update the display menu: {cause}");
                }
                if let Some(error) = error {
                    self.set_title(&format!("显示器切换失败：{error}"));
                } else if pending.is_some() {
                    self.set_title("正在切换显示器…");
                } else if let Some(display) = displays.iter().find(|display| Some(display.id) == selected) {
                    self.set_title(&format!("正在查看 {}", display_label(display)));
                }
                self.draw();
            },
            ViewerEvent::Control(can_control) => {
                self.can_control = can_control;
                if !can_control {
                    unsafe { self.release() };
                }
                self.set_title(if can_control { "被控端允许控制" } else { "仅观看（被控端已关闭控制）" });
                unsafe { self.draw() };
            }
            ViewerEvent::Paused { paused, error } => {
                let request = self.pending_pause.take();
                self.paused = paused;
                if paused && self.owns_input() {
                    unsafe { self.release() };
                }
                if let Some(error) = error {
                    self.set_title(&error);
                    if request != Some(self.attention.idle) {
                        self.reconcile_pause();
                    }
                } else {
                    self.set_title(if paused { "已暂停画面传输" } else { "已恢复画面传输" });
                    self.reconcile_pause();
                }
                unsafe { self.draw() };
            }
            ViewerEvent::Cursor(state) => {
                self.latest_cursor = state;
                unsafe { self.draw() };
            }
            ViewerEvent::InputStatus(feedback) => {
                if self.uses_caps_actions() {
                    self.set_title(&feedback.message.replace(char::is_control, " "));
                }
            }
            ViewerEvent::InputActionTimeout => {
                if self.uses_caps_actions() {
                    self.set_title("未能确认远端键盘状态，请点击远端输入位置后重试");
                }
            }
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
            if !(*canvas).controlling() {
                return CallNextHookEx(None, code, wparam, lparam);
            }
            let key = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
            let down = wparam.0 as u32 == WM_KEYDOWN || wparam.0 as u32 == WM_SYSKEYDOWN;
            if (*canvas).key(key.vkCode, key.scanCode & 0xFF, key.flags.0 & LLKHF_EXTENDED.0 != 0, down) {
                return LRESULT(1);
            }
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
                let events = std::mem::take(&mut *canvas.mailbox.events.lock().unwrap());
                if !canvas.closing {
                    for event in events {
                        match event {
                            Notice::Session(event) if canvas.current_generation() => canvas.session_event(event),
                            Notice::Session(_) => {}
                            Notice::Retry { status, serial, generation } => {
                                canvas.generation = generation;
                                canvas.retry_event(status, serial);
                            }
                        }
                    }
                }
            }
            WM_SESSION_ENDED => {
                let Some(end) = canvas.mailbox.ended.lock().unwrap().take() else { return LRESULT(0) };
                canvas.connected = false;
                canvas.release();
                if !canvas.closing && !end.local_stop {
                    canvas.closing = true;
                    let _ = KillTimer(Some(window), RETRY_TIMER);
                    canvas.retry_panel.visible(false);
                    canvas.set_title(&format!("已结束：{}", end.reason));
                    let text = wide(&end.reason);
                    MessageBoxW(Some(window), PCWSTR(text.as_ptr()), w!("QuietDesk"), MB_OK | MB_ICONINFORMATION);
                }
                let _ = DestroyWindow(window);
            }
            WM_SIZE => {
                if canvas.relative_mouse.is_some() {
                    canvas.release();
                }
                canvas.update_attention(GetForegroundWindow() == window, IsWindowVisible(window).as_bool(), wparam.0 as u32 == SIZE_MINIMIZED);
                if canvas.retry.is_some() {
                    canvas.retry_panel.layout(window);
                }
                canvas.draw();
            }
            WM_ACTIVATE => {
                if (wparam.0 & 0xffff) as u32 == WA_INACTIVE && canvas.relative_mouse.is_some() {
                    canvas.release();
                }
                canvas.update_attention((wparam.0 & 0xffff) as u32 != WA_INACTIVE, IsWindowVisible(window).as_bool(), IsIconic(window).as_bool());
                return DefWindowProcW(window, message, wparam, lparam);
            }
            WM_SHOWWINDOW => {
                canvas.update_attention(GetForegroundWindow() == window, wparam.0 != 0, IsIconic(window).as_bool());
                return DefWindowProcW(window, message, wparam, lparam);
            }
            WM_SETFOCUS => {
                canvas.capture_keyboard();
                canvas.draw();
            }
            WM_KILLFOCUS => {
                canvas.release();
                canvas.draw();
            }
            WM_CAPTURECHANGED if !canvas.translator.pressed_buttons().is_empty() => {
                canvas.release();
                canvas.draw();
            }
            WM_SETCURSOR if (lparam.0 & 0xFFFF) as u32 == HTCLIENT => {
                let owned = canvas.local_pointer;
                canvas.update_pointer();
                if owned != canvas.local_pointer && canvas.independent() {
                    canvas.draw();
                }
                return LRESULT(1);
            }
            WM_MOUSELEAVE => canvas.draw(),
            WM_INPUT => {
                if canvas.controlling()
                    && canvas.owns_input()
                    && wparam.0 as u32 == RIM_INPUT
                    && let Some((dx, dy)) = canvas.relative_mouse.as_ref().and_then(|mouse| mouse.delta(HRAWINPUT(lparam.0 as _)))
                    && let Some((_, _, width, height)) = canvas.picture()
                    && let Some((_, video_w, video_h)) = &canvas.bitmap
                {
                    canvas.pace_move(PendingMove::relative(
                        f64::from(dx) * *video_w as f64 / f64::from(width),
                        f64::from(dy) * *video_h as f64 / f64::from(height),
                    ));
                }
                return DefWindowProcW(window, message, wparam, lparam);
            }
            WM_MOVE | WM_ENTERSIZEMOVE | WM_ENTERMENULOOP | WM_CANCELMODE if canvas.relative_mouse.is_some() => {
                canvas.release();
                return DefWindowProcW(window, message, wparam, lparam);
            }
            WM_MOUSEMOVE => {
                if canvas.independent() {
                    let _ = TrackMouseEvent(&mut TRACKMOUSEEVENT {
                        cbSize: size_of::<TRACKMOUSEEVENT>() as u32,
                        dwFlags: TME_LEAVE,
                        hwndTrack: window,
                        dwHoverTime: 0,
                    });
                    let owned = canvas.local_pointer;
                    canvas.update_pointer();
                    if owned != canvas.local_pointer {
                        canvas.draw();
                    }
                }
                if !canvas.controlling() || !canvas.owns_input() || canvas.relative_mouse.is_some() {
                    return LRESULT(0);
                }
                let (x, y) = point(lparam);
                if let Some(position) = canvas.fraction(x, y) {
                    if canvas.independent() && !Canvas::inside_picture(position) && GetCapture() != window {
                        return LRESULT(0);
                    }
                    canvas.pace_move(PendingMove::Absolute(position.0, position.1));
                }
            }
            WM_TIMER if wparam.0 == MOVE_TIMER => {
                let _ = KillTimer(Some(window), MOVE_TIMER);
                canvas.flush_move();
            }
            WM_TIMER if wparam.0 == RETRY_TIMER && !canvas.closing => canvas.update_retry_title(),
            WM_TIMER if wparam.0 == IDLE_TIMER => {
                canvas.update_attention(GetForegroundWindow() == window, IsWindowVisible(window).as_bool(), IsIconic(window).as_bool());
            }
            WM_LBUTTONDOWN | WM_LBUTTONUP | WM_RBUTTONDOWN | WM_RBUTTONUP | WM_MBUTTONDOWN | WM_MBUTTONUP | WM_XBUTTONDOWN | WM_XBUTTONUP
                if canvas.controlling() =>
            {
                let down = matches!(message, WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN | WM_XBUTTONDOWN);
                let (x, y) = point(lparam);
                let Some(position) = canvas.fraction(x, y) else {
                    if !down {
                        canvas.release();
                    }
                    return LRESULT(0);
                };
                if canvas.independent() && down && !Canvas::inside_picture(position) {
                    return LRESULT(0);
                }
                let button = match message {
                    WM_LBUTTONDOWN | WM_LBUTTONUP => 0,
                    WM_RBUTTONDOWN | WM_RBUTTONUP => 1,
                    WM_MBUTTONDOWN | WM_MBUTTONUP => 2,
                    _ => 2 + ((wparam.0 >> 16) & 0xFFFF) as i64,
                };
                if down {
                    let _ = SetFocus(Some(window));
                    canvas.capture_keyboard();
                    if !canvas.owns_input() {
                        return LRESULT(0);
                    }
                } else if !canvas.translator.pressed_buttons().contains(&button) {
                    return LRESULT(0);
                }
                canvas.flush_move();
                let input = canvas.translator.button(button, down, position.0, position.1, canvas.started.elapsed(), (x, y));
                canvas.send(ViewerCommand::Input(input));
                if down {
                    SetCapture(window);
                } else if canvas.translator.pressed_buttons().is_empty() {
                    let _ = ReleaseCapture();
                }
            }
            WM_MOUSEWHEEL | WM_MOUSEHWHEEL if canvas.controlling() && canvas.owns_input() => {
                let notches = f64::from(((wparam.0 >> 16) & 0xFFFF) as i16) / 120.0;
                let (x, y) = point(lparam);
                let mut position = POINT { x, y };
                let _ = ScreenToClient(window, &mut position);
                if let Some((fraction_x, fraction_y)) = canvas.fraction(position.x, position.y) {
                    if canvas.independent() && !Canvas::inside_picture((fraction_x, fraction_y)) {
                        return LRESULT(0);
                    }
                    canvas.flush_move();
                    let (vertical, horizontal) = if message == WM_MOUSEWHEEL { (notches, 0.0) } else { (0.0, notches) };
                    canvas.send(ViewerCommand::Input(canvas.translator.wheel(vertical, horizontal, fraction_x, fraction_y)));
                }
            }
            // Without the hook, keys still arrive as messages, minus the ones Windows keeps.
            WM_KEYDOWN | WM_SYSKEYDOWN | WM_KEYUP | WM_SYSKEYUP if canvas.hook.is_none() && canvas.controlling() && canvas.owns_input() => {
                let down = matches!(message, WM_KEYDOWN | WM_SYSKEYDOWN);
                if !canvas.key(wparam.0 as u32, ((lparam.0 >> 16) & 0xFF) as u32, lparam.0 & (1 << 24) != 0, down) {
                    return DefWindowProcW(window, message, wparam, lparam);
                }
            }
            WM_COMMAND => match wparam.0 & 0xFFFF {
                MENU_FULL_SCREEN => canvas.toggle_full_screen(),
                MENU_RELATIVE_MOUSE if canvas.connected && canvas.current_generation() && canvas.relative_supported && !canvas.closing => {
                    canvas.release();
                    canvas.relative_enabled = !canvas.relative_enabled;
                    canvas.update_input_menu();
                    canvas.capture_keyboard();
                    if canvas.relative_enabled && canvas.relative_mouse.is_none() {
                        canvas.set_title("点击远端画面锁定相对鼠标，Ctrl+Alt+Esc 释放");
                    }
                }
                MENU_CAPS_ACTIONS if canvas.connected && canvas.current_generation() && canvas.supports_input_actions && !canvas.closing => {
                    canvas.release();
                    canvas.caps_forwarding = !canvas.caps_forwarding;
                    canvas.update_input_menu();
                    SendMessageW(canvas.owner, WM_CAPS_PREFERENCE, Some(WPARAM(usize::from(canvas.caps_forwarding))), None);
                    canvas.capture_keyboard();
                }
                MENU_SEND_CLIPBOARD if canvas.connected && canvas.current_generation() && !canvas.closing => match clipboard::text() {
                    Some(text) => canvas.send(ViewerCommand::SendClipboard(text)),
                    None => canvas.set_title("本机剪贴板中没有文字"),
                },
                MENU_REQUEST_CLIPBOARD if canvas.connected && !canvas.closing => canvas.send(ViewerCommand::RequestClipboard),
                RETRY_NOW if matches!(canvas.retry, Some(RetryStatus::Waiting { .. })) && !canvas.closing => {
                    let _ = canvas.commands.send(ViewerControl::RetryNow);
                }
                CANCEL_RETRY | MENU_DISCONNECT => canvas.disconnect(),
                id if id >= MENU_DISPLAY && canvas.connected && canvas.current_generation() && !canvas.closing && !canvas.displays.pending => {
                    if let Some(&target) = canvas.displays.ids.get(id - MENU_DISPLAY)
                        && Some(target) != canvas.displays.selected.map(|display| display.id)
                    {
                        canvas.release();
                        canvas.displays.pending = true;
                        canvas.send(ViewerCommand::SelectDisplay(target));
                    }
                }
                id if canvas.connected && !canvas.closing && (MENU_QUALITY..MENU_QUALITY + VIEWER_QUALITIES.len()).contains(&id) => {
                    canvas.send(ViewerCommand::Quality(VIEWER_QUALITIES[id - MENU_QUALITY].1))
                }
                _ => {}
            },
            WM_CLOSE => {
                // The session ends first; its ending closes the window.
                canvas.disconnect();
                if !canvas.commands.is_closed() || canvas.mailbox.ended.lock().unwrap().is_some() {
                    return LRESULT(0);
                }
                let _ = DestroyWindow(window);
            }
            WM_NCDESTROY => {
                canvas.disconnect();
                canvas.release();
                if let Some((_, _, menu)) = canvas.full_screen.take() {
                    let _ = DestroyMenu(menu);
                }
                SetWindowLongPtrW(window, GWLP_USERDATA, 0);
                SendMessageW(canvas.owner, WM_CANVAS_CLOSED, Some(WPARAM(window.0 as usize)), None);
                drop(Box::from_raw(std::ptr::from_mut(canvas)));
                return DefWindowProcW(window, message, wparam, lparam);
            }
            _ => return DefWindowProcW(window, message, wparam, lparam),
        }
        LRESULT(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pacing_accumulates_relative_motion_and_replaces_absolute_motion() {
        let a = PendingMove::relative(0.75, -2.25);
        let b = PendingMove::relative(1.0, -0.75).accumulating(Some(a));
        assert!(matches!(b, PendingMove::Relative(1.75, -3.0)));
        let at_limit = PendingMove::relative(9999.0, -9999.0).accumulating(Some(b));
        assert!(matches!(at_limit, PendingMove::Relative(10000.0, -10000.0)));
        assert!(matches!(PendingMove::Absolute(0.2, 0.8).accumulating(Some(b)), PendingMove::Absolute(0.2, 0.8)));
        assert!(matches!(a.accumulating(Some(PendingMove::Absolute(0.8, 0.2))), PendingMove::Relative(0.75, -2.25)));
    }

    #[test]
    fn a_modifier_held_before_control_keeps_its_whole_chord_local() {
        let key = u16::from(b'C');
        let mut held = BTreeSet::from([VK_LCONTROL.0]);
        assert!(local_key(&mut held, key, true));
        assert!(local_key(&mut held, VK_LCONTROL.0, false));
        assert!(local_key(&mut held, key, true));
        assert!(local_key(&mut held, key, false));
        assert!(!local_key(&mut held, key, true));
    }

    #[test]
    fn only_continuous_time_away_pauses_an_attended_window() {
        let start = Instant::now();
        let mut state = Attention::default();
        state.update(start, true, false);
        let left = start + IDLE_TIMEOUT * 3;
        state.update(left, true, false);
        assert!(!state.idle);
        state.update(left, false, false);
        state.update(left + IDLE_TIMEOUT - Duration::from_millis(1), true, false);
        let left_again = left + IDLE_TIMEOUT;
        state.update(left_again, false, false);
        state.update(left_again + IDLE_TIMEOUT - Duration::from_millis(1), false, false);
        assert!(!state.idle);
        state.update(left_again + IDLE_TIMEOUT, false, false);
        assert!(state.idle);
        state.update(left_again + IDLE_TIMEOUT, true, false);
        assert!(!state.idle);
    }

    #[test]
    fn minimizing_pauses_immediately_and_restoring_focus_resumes() {
        let now = Instant::now();
        let mut state = Attention::default();
        state.update(now, true, true);
        assert!(state.idle);
        state.update(now, false, false);
        assert!(state.idle);
        state.update(now, true, false);
        assert!(!state.idle);
    }

    #[test]
    fn retry_caption_uses_remaining_time_until_the_actual_attempt_starts() {
        let now = Instant::now();
        let wait = RetryStatus::Waiting { attempt: 2, deadline: now + Duration::from_millis(1001), reason: "连接中断".into() };
        assert_eq!(retry_title(&wait, now), "第 2 次重连，2 秒后重试 · 连接中断");
        assert_eq!(retry_title(&wait, now + Duration::from_secs(2)), "第 2 次重连即将开始 · 连接中断");
        assert_eq!(retry_title(&RetryStatus::Connecting { attempt: 2 }, now), "正在进行第 2 次重连…");
        let defer = RetryStatus::Deferred { reason: "连接中断".into() };
        assert_eq!(retry_title(&defer, now), "已暂停重连，返回窗口后继续 · 连接中断");
    }
}
