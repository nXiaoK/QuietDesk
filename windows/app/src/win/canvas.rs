//! The viewer's window: draws the host's picture and sends this PC's keyboard and mouse to it.

use super::app::{DisplayGeometry, Frame, ViewerSink, ViewerTarget, run_viewer};
use super::clipboard;
use super::relative_mouse::RelativeMouse;
use super::settings::{Settings, VIEWER_QUALITIES};
use super::util::{display_label, wide};
use super::viewer_cursor::ViewerCursor;
use super::viewer_gestures::{TouchGestures, Touchpad};
use super::workspace_style::{ButtonKind, FontRole, Surface, TextTone};
use chrome::*;
use quietdesk_core::cursor::CursorPresentationState;
use quietdesk_core::display::RemoteDisplayInfo;
use quietdesk_core::input::{CapsLockPress, DoubleClick, PcKeyEvent, ViewerInputTranslator};
use quietdesk_core::media::MediaStreamId;
use quietdesk_core::messages::{DeviceIdentity, InputKind, RemoteInput};
use quietdesk_core::pairing::PairingKey;
use quietdesk_core::reliability::{RetryStatus, ViewerControl};
use quietdesk_core::viewer::{ViewerCommand, ViewerEnd, ViewerEvent};
use std::cell::Cell;
use std::collections::{BTreeSet, VecDeque};
use std::rc::{Rc, Weak};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};
use tokio::sync::watch;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::{HDC, ScreenToClient, ValidateRect};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{DRAWITEMSTRUCT, WM_MOUSELEAVE};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::HRAWINPUT;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    EnableWindow, GetAsyncKeyState, GetCapture, GetDoubleClickTime, GetFocus, GetKeyState, MAPVK_VSC_TO_VK_EX, MapVirtualKeyW, ReleaseCapture, SetCapture,
    SetFocus, TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent, VIRTUAL_KEY, VK_CONTROL, VK_ESCAPE, VK_F10, VK_LCONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_MENU,
    VK_RCONTROL, VK_RETURN, VK_RMENU, VK_RSHIFT, VK_RWIN, VK_SHIFT, VK_TAB,
};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

mod chrome;

const CANVAS_CLASS: PCWSTR = w!("QuietDeskCanvas");
const WM_SESSION_EVENT: u32 = WM_APP + 1;
const WM_SESSION_FRAME: u32 = WM_APP + 2;
const WM_SESSION_ENDED: u32 = WM_APP + 3;
/// The owner can now take authenticated host details from its viewer window.
pub const WM_CANVAS_CONNECTED: u32 = WM_APP + 20;
pub const WM_CANVAS_CLOSED: u32 = WM_APP + 21;
pub const WM_CAPS_PREFERENCE: u32 = WM_APP + 22;
const MOVE_TIMER: usize = 1;
const RETRY_TIMER: usize = 2;
const IDLE_TIMER: usize = 3;
const TOUCHPAD_TIMER: usize = 4;
const IDLE_TIMEOUT: Duration = Duration::from_secs(600);
const MOVE_INTERVAL: Duration = Duration::from_millis(8);

/// What the session threads leave for the window thread.
enum Notice {
    Session(ViewerEvent),
    Retry { status: RetryStatus, serial: u64, generation: u64 },
}

struct Mailbox {
    local_identity: Option<DeviceIdentity>,
    window: isize,
    events: Mutex<VecDeque<Notice>>,
    frame: Arc<Mutex<Frame>>,
    generation: AtomicU64,
    ended: Mutex<Option<ViewerEnd>>,
    frame_posted: AtomicBool,
    clipboard_enabled: AtomicBool,
}

impl Mailbox {
    fn post(&self, message: u32) {
        let _ = unsafe { PostMessageW(Some(HWND(self.window as _)), message, WPARAM(0), LPARAM(0)) };
    }
}

impl ViewerSink for Mailbox {
    fn plays_audio(&self) -> bool {
        true
    }

    fn clipboard_preference(&self) -> Option<bool> {
        Some(self.clipboard_enabled.load(Ordering::Relaxed))
    }
    fn local_identity(&self) -> Option<&DeviceIdentity> {
        self.local_identity.as_ref()
    }

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

pub(super) struct ConnectedHost {
    pub name: String,
    pub id: Option<uuid::Uuid>,
}

pub(super) struct ViewerWindow {
    pub window: HWND,
    pub connected: Rc<Cell<Option<ConnectedHost>>>,
}

struct Canvas {
    host_details: Weak<Cell<Option<ConnectedHost>>>,
    window: HWND,
    owner: HWND,
    commands: UnboundedSender<ViewerControl>,
    mailbox: Arc<Mailbox>,
    generation: u64,
    target: Option<(ID2D1HwndRenderTarget, ID2D1SolidColorBrush)>,
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
    chrome: Chrome,
    translator: ViewerInputTranslator,
    started: Instant,
    name: String,
    connected: bool,
    can_control: bool,
    supports_pause: bool,
    supports_clipboard: bool,
    supports_audio: bool,
    audio_wanted: bool,
    audio_playing: bool,
    audio_pending: bool,
    last_clipboard_preference: Option<(bool, bool)>,
    retry: Option<RetryStatus>,
    retry_panel: RetryPanel,
    fresh_after: Option<u64>,
    held: BTreeSet<(u32, bool)>,
    withheld_keys: BTreeSet<u16>,
    caps_lock: bool,
    caps_press: CapsLockPress,
    caps_forwarding: bool,
    supports_input_actions: bool,
    hook: Option<HHOOK>,
    relative_supported: bool,
    relative_enabled: bool,
    relative_mouse: Option<RelativeMouse>,
    supports_gestures: bool,
    touchpad: Option<Touchpad>,
    touch_gestures: TouchGestures,
    pending_move: Option<PendingMove>,
    last_move: Instant,
    full_screen: Option<(WINDOW_STYLE, WINDOWPLACEMENT)>,
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
pub(super) fn open(
    runtime: &tokio::runtime::Handle,
    owner: HWND,
    target: ViewerTarget,
    key: PairingKey,
    settings: &Settings,
    local_identity: Option<DeviceIdentity>,
    mut auto_reconnect: watch::Receiver<bool>,
) -> windows::core::Result<ViewerWindow> {
    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None)?.into();
        let definition = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(window_procedure),
            hInstance: instance,
            hIcon: LoadIconW(Some(instance), PCWSTR(1 as _)).unwrap_or_default(),
            hCursor: LoadCursorW(None, IDC_ARROW)?,
            lpszClassName: CANVAS_CLASS,
            ..Default::default()
        };
        // Registering twice fails harmlessly for the second window.
        RegisterClassExW(&definition);
        let factory = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;
        let displays = DisplayMenu::new()?;
        let address = target.address_label();
        let title = wide(&format!("QuietDesk · {address}"));
        let window = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            CANVAS_CLASS,
            PCWSTR(title.as_ptr()),
            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            1280,
            800,
            None,
            None,
            Some(instance),
            None,
        )?;
        let controls = Chrome::new(window, instance, GetDpiForWindow(window).max(96)).and_then(|chrome| {
            let retry = RetryPanel::new(window, instance, &chrome)?;
            Ok((chrome, retry))
        });
        let (chrome, retry_panel) = match controls {
            Ok(controls) => controls,
            Err(error) => {
                let _ = DestroyWindow(window);
                return Err(error);
            }
        };
        let (commands, queue) = unbounded_channel();
        let frame = Arc::new(Mutex::new(Frame::default()));
        let mailbox = Arc::new(Mailbox {
            local_identity,
            window: window.0 as isize,
            events: Mutex::new(VecDeque::new()),
            frame: frame.clone(),
            generation: AtomicU64::new(0),
            ended: Mutex::new(None),
            frame_posted: AtomicBool::new(false),
            clipboard_enabled: AtomicBool::new(settings.clipboard),
        });
        let double_click = DoubleClick { interval: Duration::from_millis(u64::from(GetDoubleClickTime())), distance: GetSystemMetrics(SM_CXDOUBLECLK) / 2 };
        let quality = settings.viewer_quality();
        let preferences = commands.clone();
        let enabled = *auto_reconnect.borrow_and_update();
        let host_details = Rc::new(Cell::new(None));
        let canvas = Box::new(Canvas {
            host_details: Rc::downgrade(&host_details),
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
            chrome,
            translator: ViewerInputTranslator::new(settings.pc_modifiers, double_click),
            started: Instant::now(),
            name: address.clone(),
            connected: false,
            can_control: false,
            supports_pause: false,
            supports_clipboard: false,
            supports_audio: false,
            audio_wanted: false,
            audio_playing: false,
            audio_pending: false,
            last_clipboard_preference: None,
            retry: None,
            retry_panel,
            fresh_after: Some(0),
            held: BTreeSet::new(),
            withheld_keys: BTreeSet::new(),
            caps_lock: false,
            caps_press: CapsLockPress::default(),
            caps_forwarding: settings.caps_forwarding,
            supports_input_actions: false,
            hook: None,
            pending_move: None,
            relative_supported: false,
            relative_enabled: false,
            relative_mouse: None,
            supports_gestures: false,
            touchpad: None,
            touch_gestures: TouchGestures::default(),
            last_move: Instant::now(),
            full_screen: None,
            paused: false,
            pending_pause: None,
            attention: Attention::default(),
            closing: false,
        });
        canvas.chrome.set_connected(false);
        canvas.update_input_menu();
        canvas.chrome.enable_button(TOOL_DISPLAY, false);
        canvas.layout_chrome();
        SetWindowLongPtrW(window, GWLP_USERDATA, Box::into_raw(canvas) as isize);
        let _ = ShowWindow(window, SW_SHOW);
        runtime.spawn(async move {
            let session = run_viewer(target, key, quality, enabled, queue, frame, mailbox.clone());
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
        Ok(ViewerWindow { window, connected: host_details })
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
    popup: Rc<Popup>,
    ids: Vec<u32>,
    selected: Option<DisplayGeometry>,
    pending: bool,
}

impl DisplayMenu {
    fn shows(&self, display: Option<DisplayGeometry>) -> bool {
        // The first topology can arrive after an older host already sent its opening picture.
        !self.pending && (display == self.selected || (display.is_none() && self.selected.is_some_and(|selected| selected.revision == 0)))
    }

    unsafe fn new() -> windows::core::Result<Self> {
        let popup = Rc::new(unsafe { Popup::new()? });
        Ok(Self { popup, ids: Vec::new(), selected: None, pending: false })
    }

    unsafe fn update(&mut self, displays: &[RemoteDisplayInfo], selected: Option<DisplayGeometry>, pending: bool) -> windows::core::Result<()> {
        self.selected = selected;
        self.pending = pending;
        self.ids.clear();
        unsafe {
            let popup = Popup::new()?;
            let mut ids = Vec::with_capacity(displays.len());
            for display in displays {
                let flags = if Some(display.id) == selected.map(|s| s.id) { MF_STRING | MF_CHECKED } else { MF_STRING };
                let label = wide(&display_label(display).replace('&', "&&"));
                AppendMenuW(popup.0, flags, MENU_DISPLAY + ids.len(), PCWSTR(label.as_ptr()))?;
                ids.push(display.id);
            }
            self.popup = Rc::new(popup);
            self.ids = ids;
            Ok(())
        }
    }
}

struct RetryPanel {
    status: HWND,
    retry: HWND,
    cancel: HWND,
}

impl RetryPanel {
    unsafe fn new(window: HWND, instance: HINSTANCE, chrome: &Chrome) -> windows::core::Result<Self> {
        unsafe {
            let control = |class, title, id, style| -> windows::core::Result<HWND> {
                let child =
                    CreateWindowExW(WINDOW_EX_STYLE(0), class, title, WS_CHILD | style, 0, 0, 0, 0, Some(window), Some(HMENU(id as _)), Some(instance), None)?;
                Ok(child)
            };
            let status_style = WINDOW_STYLE(0x0201 | 0x4000); // SS_CENTER | SS_CENTERIMAGE | SS_ENDELLIPSIS
            let button_style = WS_TABSTOP | WINDOW_STYLE(BS_OWNERDRAW as u32);
            let panel = Self {
                status: control(w!("STATIC"), w!(""), 0, status_style)?,
                retry: control(w!("BUTTON"), w!("立即重试"), RETRY_NOW, button_style)?,
                cancel: control(w!("BUTTON"), w!("取消重连"), CANCEL_RETRY, button_style)?,
            };
            panel.apply_font(chrome);
            Ok(panel)
        }
    }

    unsafe fn apply_font(&self, chrome: &Chrome) {
        unsafe {
            let font = WPARAM(chrome.theme.font(FontRole::Body).0 as usize);
            for control in [self.status, self.retry, self.cancel] {
                SendMessageW(control, WM_SETFONT, Some(font), Some(LPARAM(1)));
            }
        }
    }

    unsafe fn layout(&self, viewport: RECT, chrome: &Chrome) {
        unsafe {
            let px = |value| chrome.theme.scale(value);
            let width = px(460).min((viewport.right - px(24)).max(0));
            let left = (viewport.right - width) / 2;
            let y = viewport.top + px(12);
            let button = px(104).min((width - px(4)).max(0) / 2);
            let buttons_left = (viewport.right - button * 2 - px(4)) / 2;
            let flags = SWP_NOZORDER | SWP_NOACTIVATE;
            let _ = SetWindowPos(self.status, None, left, y, width, px(36), flags);
            let _ = SetWindowPos(self.retry, None, buttons_left, y + px(36), button, px(32), flags);
            let _ = SetWindowPos(self.cancel, None, buttons_left + button + px(4), y + px(36), button, px(32), flags);
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
        let input = match &mut command {
            ViewerCommand::Input(input) => Some(input),
            ViewerCommand::FlushPointer(input) => Some(input.as_mut()),
            _ => None,
        };
        if let Some(input) = input {
            if self.uses_caps_actions() {
                input.independent_caps_lock = Some(true);
            }
            if self.relative_mouse.is_some()
                && matches!(input.kind, InputKind::Down | InputKind::Up | InputKind::Scroll | InputKind::Magnify | InputKind::Rotate | InputKind::SmartMagnify)
            {
                *input = input.clone().at_current_pointer();
            }
        }
        if self.current_generation() {
            let _ = self.commands.send(command.into());
        }
    }

    fn uses_caps_actions(&self) -> bool {
        self.caps_forwarding && self.supports_input_actions && self.hook.is_some() && self.controlling() && self.owns_input()
    }

    fn update_clipboard_preference(&mut self) {
        if !self.connected || !self.supports_clipboard || self.closing {
            return;
        }
        let enabled = self.mailbox.clipboard_enabled.load(Ordering::Relaxed);
        let receives = enabled && !self.owns_input() && !self.paused && !self.attention.idle;
        if self.last_clipboard_preference != Some((enabled, receives)) {
            self.last_clipboard_preference = Some((enabled, receives));
            self.send(ViewerCommand::AutomaticClipboard { enabled, receives });
        }
    }

    fn update_input_menu(&self) {
        for (id, supported, selected) in [
            (MENU_CAPS_ACTIONS, self.supports_input_actions, self.caps_forwarding),
            (MENU_RELATIVE_MOUSE, self.relative_supported, self.relative_enabled),
            (MENU_AUTO_CLIPBOARD, self.supports_clipboard, self.mailbox.clipboard_enabled.load(Ordering::Relaxed)),
            (MENU_REMOTE_AUDIO, self.supports_audio && !self.audio_pending, self.audio_playing),
        ] {
            self.chrome.set_action(id, self.connected && supported, selected);
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
                self.set_status("相对鼠标已锁定，Ctrl+Alt+Esc 释放");
            }
            Err(error) => {
                self.relative_enabled = false;
                self.update_input_menu();
                self.set_status(&format!("无法锁定相对鼠标：{error}"));
            }
        }
    }

    fn current_generation(&self) -> bool {
        self.generation == self.mailbox.generation.load(Ordering::Acquire)
    }

    fn set_device_title(&self) {
        let title = wide(&format!("QuietDesk · {}", self.name.replace(char::is_control, " ")));
        let _ = unsafe { SetWindowTextW(self.window, PCWSTR(title.as_ptr())) };
    }

    fn set_status(&mut self, status: &str) {
        self.refresh_status_mode();
        self.chrome.set_notice(status);
    }

    fn refresh_status_mode(&mut self) {
        let mode = if self.closing {
            Mode::Closing
        } else if self.retry.is_some() {
            Mode::Reconnecting
        } else if !self.connected {
            Mode::Connecting
        } else if self.relative_mouse.is_some() {
            Mode::RelativeMouse
        } else if !self.can_control {
            Mode::ViewOnly
        } else if self.controlling() && self.owns_input() {
            Mode::Controlling
        } else {
            Mode::Ready
        };
        self.chrome.set_mode(mode);
    }

    fn viewport(&self) -> Option<RECT> {
        let mut client = RECT::default();
        unsafe { GetClientRect(self.window, &mut client) }.ok()?;
        Some(self.chrome.viewport(client, self.full_screen.is_some()))
    }

    unsafe fn layout_chrome(&self) {
        unsafe {
            let mut client = RECT::default();
            let _ = GetClientRect(self.window, &mut client);
            let full_screen = self.full_screen.is_some();
            self.chrome.layout(client, full_screen);
            if self.retry.is_some() {
                self.retry_panel.layout(self.chrome.viewport(client, full_screen), &self.chrome);
            }
        }
    }

    /// Where the picture lies in the client area: as large as fits, centred.
    fn picture(&self) -> Option<(f32, f32, f32, f32)> {
        self.picture_in(self.viewport()?)
    }

    fn picture_in(&self, viewport: RECT) -> Option<(f32, f32, f32, f32)> {
        let (width, height) = self.bitmap.as_ref().map(|(_, width, height)| (*width as f32, *height as f32))?;
        let (client_width, client_height) = ((viewport.right - viewport.left) as f32, (viewport.bottom - viewport.top) as f32);
        if client_width < 1.0 || client_height < 1.0 {
            return None;
        }
        let scale = (client_width / width).min(client_height / height);
        let (shown_width, shown_height) = (width * scale, height * scale);
        Some((viewport.left as f32 + (client_width - shown_width) / 2.0, viewport.top as f32 + (client_height - shown_height) / 2.0, shown_width, shown_height))
    }

    fn fraction(&self, x: i32, y: i32) -> Option<(f64, f64)> {
        let viewport = self.viewport()?;
        // Preserve edge dragging after capture while leaving the window's own tools and status outside the remote input area.
        if !(viewport.top..viewport.bottom).contains(&y) && unsafe { GetCapture() } != self.window {
            return None;
        }
        let (left, top, width, height) = self.picture_in(viewport)?;
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
            let rect = self.viewport()?;
            ((rect.left..rect.right).contains(&point.x) && (rect.top..rect.bottom).contains(&point.y)).then_some((point.x, point.y))
        }
    }

    fn update_pointer(&mut self) -> bool {
        let position = self.pointer_in_client();
        let owns = self.controlling() && self.owns_input();
        self.local_pointer = self.relative_mouse.is_none() && owns && position.and_then(|(x, y)| self.fraction(x, y)).is_some_and(Self::inside_picture);
        if position.is_none() {
            return false;
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
        true
    }

    fn flush_move(&mut self) {
        self.send_pending_move(true);
    }

    fn send_pending_move(&mut self, flush: bool) {
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
            self.send(if flush { ViewerCommand::FlushPointer(Box::new(input)) } else { ViewerCommand::Input(input) });
        }
    }

    fn pace_move(&mut self, movement: PendingMove) {
        self.pending_move = Some(movement.accumulating(self.pending_move.take()));
        if self.last_move.elapsed() >= MOVE_INTERVAL {
            self.send_pending_move(false);
        } else {
            unsafe { SetTimer(Some(self.window), MOVE_TIMER, MOVE_INTERVAL.as_millis() as u32, None) };
        }
    }

    unsafe fn draw(&mut self) {
        unsafe {
            self.refresh_status_mode();
            let mut client = RECT::default();
            let _ = GetClientRect(self.window, &mut client);
            let viewport = self.chrome.viewport(client, self.full_screen.is_some());
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
                match self.factory.CreateHwndRenderTarget(&properties, &window).and_then(|target| {
                    let fill = target.CreateSolidColorBrush(&D2D1_COLOR_F { a: 1.0, ..Default::default() }, None)?;
                    Ok((target, fill))
                }) {
                    Ok(target) => self.target = Some(target),
                    Err(error) => return log::error!("the picture cannot be drawn: {error}"),
                }
                self.bitmap = None;
                self.uploaded_serial = None;
            }
            let Some((target, chrome_brush)) = self.target.clone() else { return };
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
            if self.full_screen.is_none() {
                self.chrome.paint_bands(&target, &chrome_brush, client, viewport);
            }
            let picture = self.picture_in(viewport);
            let painted = if let (Some((bitmap, _, _)), Some((left, top, width, height))) = (&self.bitmap, picture) {
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
                && let Some(rect) = picture
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

    /// Stops forwarding keys and tells the host to let go of everything.
    unsafe fn release(&mut self) {
        self.caps_press.reset();
        if let Some(pad) = &mut self.touchpad {
            pad.reset();
        }
        self.touch_gestures = TouchGestures::default();
        let _ = unsafe { KillTimer(Some(self.window), TOUCHPAD_TIMER) };
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
            self.update_clipboard_preference();
        }
        self.refresh_status_mode();
    }

    /// Takes the keyboard, including the shortcuts Windows would otherwise keep for itself.
    unsafe fn capture_keyboard(&mut self) {
        if !self.owns_input() && self.controlling() && unsafe { GetFocus() } == self.window {
            // A press that began while the window had no control must finish locally.
            self.withheld_keys = (8..=254).filter(|&key| unsafe { GetAsyncKeyState(i32::from(key)) } < 0).collect();
            FOCUSED.set(std::ptr::from_mut(self));
            self.hook = unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), None, 0) }.ok();
            if self.hook.is_none() && self.caps_forwarding && self.supports_input_actions {
                self.set_status("键盘监听未就绪，Caps Lock 独立转发未启用");
            }
            self.refresh_status_mode();
        }
        self.capture_relative_mouse();
        self.update_clipboard_preference();
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
                    // Defer resizing the window until this keyboard callback has returned.
                    let _ = PostMessageW(Some(self.window), WM_COMMAND, WPARAM(MENU_FULL_SCREEN), LPARAM(0));
                } else {
                    self.release();
                    self.draw();
                    self.set_status("点击画面继续");
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

    unsafe fn update_retry_title(&mut self) {
        if let Some(status) = &self.retry {
            let title = retry_title(status, Instant::now());
            self.set_status(&title);
            let _ = unsafe { SetWindowTextW(self.retry_panel.status, PCWSTR(wide(&title).as_ptr())) };
        }
    }

    unsafe fn retry_event(&mut self, status: RetryStatus, serial: u64) {
        unsafe {
            self.connected = false;
            self.supports_input_actions = false;
            self.supports_clipboard = false;
            self.supports_audio = false;
            self.audio_playing = false;
            self.audio_pending = false;
            self.last_clipboard_preference = None;
            self.supports_gestures = false;
            self.touchpad = None;
            self.relative_enabled = false;
            self.relative_supported = false;
            self.chrome.set_connected(false);
            self.chrome.reset_metrics();
            self.update_input_menu();
            let _ = self.displays.update(&[], None, false);
            self.chrome.enable_button(TOOL_DISPLAY, false);
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
            self.layout_chrome();
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
                self.update_clipboard_preference();
            }
        }
    }

    unsafe fn disconnect(&mut self) {
        if !self.closing {
            self.closing = true;
            unsafe { self.release() };
            self.connected = false;
            self.chrome.set_connected(false);
            self.chrome.enable_button(TOOL_DISPLAY, false);
            self.update_input_menu();
            self.refresh_status_mode();
            self.chrome.set_notice("");
            let _ = self.commands.send(ViewerCommand::Disconnect.into());
        }
    }

    unsafe fn session_event(&mut self, event: ViewerEvent) {
        match event {
            ViewerEvent::Connected {
                name,
                device_id,
                can_control,
                stream,
                session_pause,
                input_actions,
                relative_mouse,
                trackpad_gestures,
                clipboard_sync,
                remote_audio,
                ..
            } => {
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
                self.supports_clipboard = clipboard_sync;
                self.supports_audio = remote_audio;
                self.audio_playing = false;
                self.audio_pending = remote_audio && self.audio_wanted;
                if self.audio_pending {
                    self.send(ViewerCommand::RemoteAudio(true));
                }
                self.update_clipboard_preference();
                self.supports_input_actions = input_actions;
                self.supports_gestures = trackpad_gestures;
                self.touchpad = Touchpad::open(self.window, trackpad_gestures).ok();
                self.relative_supported = relative_mouse;
                self.chrome.set_connected(true);
                self.chrome.set_stream(stream);
                self.update_input_menu();
                self.reconcile_pause();
                self.set_device_title();
                self.set_status(if can_control { "点击画面开始操作" } else { "被控端未开放控制" });
                if let Some(details) = self.host_details.upgrade() {
                    details.set(Some(ConnectedHost { name: self.name.clone(), id: device_id }));
                    unsafe { SendMessageW(self.owner, WM_CANVAS_CONNECTED, Some(WPARAM(self.window.0 as usize)), None) };
                }
                unsafe {
                    self.draw();
                }
            }
            ViewerEvent::Stream { stream, error } => {
                self.chrome.set_stream(stream);
                match error {
                    Some(error) => self.set_status(&format!("画质调整失败：{error}")),
                    None => self.set_status(&stream.settings.summary()),
                }
            }
            ViewerEvent::Displays { displays, selected, pending, error, revision } => unsafe {
                let next = DisplayGeometry::selected(&displays, selected, revision);
                if self.displays.selected != next || pending.is_some() {
                    self.release();
                }
                if let Err(cause) = self.displays.update(&displays, next, pending.is_some()) {
                    log::warn!("could not update the display menu: {cause}");
                }
                self.chrome.enable_button(TOOL_DISPLAY, !self.displays.ids.is_empty() && !self.displays.pending);
                if let Some(error) = error {
                    self.set_status(&format!("显示器切换失败：{error}"));
                } else if pending.is_some() {
                    self.set_status("正在切换显示器…");
                } else if let Some(display) = displays.iter().find(|display| Some(display.id) == selected) {
                    self.set_status(&format!("正在查看 {}", display_label(display)));
                }
                self.draw();
            },
            ViewerEvent::Control(can_control) => {
                self.can_control = can_control;
                if !can_control {
                    unsafe { self.release() };
                }
                self.set_status(if can_control { "被控端允许控制" } else { "被控端已关闭控制" });
                unsafe { self.draw() };
            }
            ViewerEvent::Paused { paused, error } => {
                let request = self.pending_pause.take();
                self.paused = paused;
                self.update_clipboard_preference();
                if paused && self.owns_input() {
                    unsafe { self.release() };
                }
                if let Some(error) = error {
                    self.set_status(&error);
                    if request != Some(self.attention.idle) {
                        self.reconcile_pause();
                    }
                } else {
                    self.set_status(if paused { "已暂停画面传输" } else { "已恢复画面传输" });
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
                    self.set_status(&feedback.message);
                }
            }
            ViewerEvent::InputActionTimeout => {
                if self.uses_caps_actions() {
                    self.set_status("未能确认远端键盘状态，请点击远端输入位置后重试");
                }
            }
            ViewerEvent::RoundTrip(milliseconds) => self.chrome.set_latency(milliseconds),
            ViewerEvent::MediaCommitted(_) => {}
            ViewerEvent::Audio { enabled, pending, error } => {
                self.audio_playing = enabled;
                self.audio_pending = pending;
                if !pending {
                    self.audio_wanted = enabled;
                }
                self.update_input_menu();
                if let Some(error) = error {
                    self.set_status(&format!("远端声音未开启：{error}"));
                } else if pending {
                    self.set_status(if self.audio_wanted { "正在开启远端声音…" } else { "正在关闭远端声音…" });
                } else {
                    self.set_status(if enabled { "远端系统声音已开启" } else { "远端系统声音已关闭" });
                }
            }
            ViewerEvent::ClipboardStatus(status) => self.set_status(&status),
            ViewerEvent::ClipboardText(text) => match clipboard::set_text(&text) {
                Ok(()) => self.set_status("已接收远端剪贴板文字"),
                Err(error) => self.set_status(&error.to_string()),
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

/// Routes local toolbar navigation without consuming keystrokes while remote input is captured.
pub(super) unsafe fn dialog_message(message: &MSG) -> bool {
    let key = VIRTUAL_KEY(message.wParam.0 as u16);
    if !matches!(message.message, WM_KEYDOWN | WM_SYSKEYDOWN) || !matches!(key, VK_TAB | VK_F10 | VK_RETURN) {
        return false;
    }
    unsafe {
        let window = GetAncestor(message.hwnd, GA_ROOT);
        let mut class = [0; 32];
        let len = GetClassNameW(window, &mut class) as usize;
        if class.get(..len) != Some(CANVAS_CLASS.as_wide()) {
            return false;
        }
        let canvas = GetWindowLongPtrW(window, GWLP_USERDATA) as *const Canvas;
        let Some(canvas) = canvas.as_ref() else { return false };
        if canvas.owns_input() {
            return false;
        }
        if key == VK_RETURN && GetKeyState(i32::from(VK_CONTROL.0)) < 0 && GetKeyState(i32::from(VK_MENU.0)) < 0 {
            let _ = PostMessageW(Some(window), WM_COMMAND, WPARAM(MENU_FULL_SCREEN), LPARAM(0));
            return true;
        }
        if message.hwnd != window {
            return IsDialogMessageW(window, message).as_bool();
        }
        if matches!(key, VK_TAB | VK_F10) {
            let reverse = key == VK_TAB && GetKeyState(i32::from(VK_SHIFT.0)) < 0;
            if let Ok(control) = GetNextDlgTabItem(window, None, reverse) {
                let _ = SetFocus(Some(control));
                return true;
            }
        }
        false
    }
}

unsafe fn toggle_full_screen(window: HWND, canvas: *mut Canvas) {
    use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromWindow};
    unsafe {
        if let Some((style, placement)) = (*canvas).full_screen.take() {
            SetWindowLongPtrW(window, GWL_STYLE, style.0 as isize);
            let _ = SetWindowPlacement(window, &placement);
            let _ = SetWindowPos(window, None, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
        } else {
            let style = WINDOW_STYLE(GetWindowLongPtrW(window, GWL_STYLE) as u32);
            let mut placement = WINDOWPLACEMENT { length: size_of::<WINDOWPLACEMENT>() as u32, ..Default::default() };
            let _ = GetWindowPlacement(window, &mut placement);
            let monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
            let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
            if !GetMonitorInfoW(monitor, &mut info).as_bool() {
                return;
            }
            (*canvas).full_screen = Some((style, placement));
            SetWindowLongPtrW(window, GWL_STYLE, (style & !WS_OVERLAPPEDWINDOW).0 as isize);
            let area = info.rcMonitor;
            let _ = SetWindowPos(window, Some(HWND_TOP), area.left, area.top, area.right - area.left, area.bottom - area.top, SWP_FRAMECHANGED);
        }
        (*canvas).layout_chrome();
        (*canvas).draw();
    }
}

unsafe extern "system" fn window_procedure(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        let canvas = GetWindowLongPtrW(window, GWLP_USERDATA) as *mut Canvas;
        if canvas.is_null() {
            return DefWindowProcW(window, message, wparam, lparam);
        }
        if message == WM_COMMAND {
            let id = wparam.0 & 0xFFFF;
            if id == MENU_FULL_SCREEN {
                toggle_full_screen(window, canvas);
                return LRESULT(0);
            }
            if lparam.0 != 0
                && let Some(popup) = (*canvas).chrome.popup(id, &(*canvas).displays.popup)
            {
                if (*canvas).owns_input() {
                    (*canvas).release();
                    (*canvas).draw();
                }
                // Tracking a popup pumps window messages, including a possible session end or display-list change.
                let command = popup.track(window, HWND(lparam.0 as _));
                let current = GetWindowLongPtrW(window, GWLP_USERDATA) as *const Canvas;
                if let Some(command) = command
                    && std::ptr::eq(current, canvas)
                    && (id != TOOL_DISPLAY || Rc::ptr_eq(&popup, &(*current).displays.popup))
                {
                    SendMessageW(window, WM_COMMAND, Some(WPARAM(command)), None);
                }
                return LRESULT(0);
            }
        }
        if message == WM_DPICHANGED {
            (*canvas).chrome.set_dpi(wparam.0 as u16 as u32);
            (*canvas).retry_panel.apply_font(&(*canvas).chrome);
            if (*canvas).full_screen.is_none() {
                let rect = &*(lparam.0 as *const RECT);
                let _ = SetWindowPos(window, None, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            (*canvas).layout_chrome();
            (*canvas).draw();
            return LRESULT(0);
        }
        let canvas = &mut *canvas;
        match message {
            WM_PAINT => {
                canvas.draw();
                let _ = ValidateRect(Some(window), None);
            }
            WM_ERASEBKGND => return LRESULT(1),
            WM_DRAWITEM if lparam.0 != 0 => {
                let item = &*(lparam.0 as *const DRAWITEMSTRUCT);
                if canvas.chrome.draw_button(item) {
                    return LRESULT(1);
                }
                if [canvas.retry_panel.retry, canvas.retry_panel.cancel].contains(&item.hwndItem) {
                    let kind = if item.hwndItem == canvas.retry_panel.retry { ButtonKind::Primary } else { ButtonKind::Secondary };
                    canvas.chrome.theme.draw_button(item, kind);
                    return LRESULT(1);
                }
            }
            WM_CTLCOLORSTATIC => {
                let control = HWND(lparam.0 as _);
                let hdc = HDC(wparam.0 as _);
                if let Some(brush) = canvas.chrome.status_colors(control, hdc) {
                    return LRESULT(brush.0 as isize);
                }
                if control == canvas.retry_panel.status {
                    let brush = canvas.chrome.theme.control_colors(hdc, Surface::Card, TextTone::Ink);
                    return LRESULT(brush.0 as isize);
                }
                return DefWindowProcW(window, message, wparam, lparam);
            }
            WM_GETMINMAXINFO => {
                let limits = &mut *(lparam.0 as *mut MINMAXINFO);
                limits.ptMinTrackSize.x = limits.ptMinTrackSize.x.max(canvas.chrome.theme.scale(600));
                limits.ptMinTrackSize.y = limits.ptMinTrackSize.y.max(canvas.chrome.theme.scale(320));
            }
            WM_SETTINGCHANGE | WM_SYSCOLORCHANGE | WM_THEMECHANGED => {
                canvas.chrome.refresh_palette();
                canvas.draw();
                return DefWindowProcW(window, message, wparam, lparam);
            }
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
                    canvas.set_status(&format!("已结束：{}", end.reason));
                    let text = wide(&end.reason);
                    MessageBoxW(Some(window), PCWSTR(text.as_ptr()), w!("QuietDesk"), MB_OK | MB_ICONINFORMATION);
                }
                let _ = DestroyWindow(window);
            }
            WM_SIZE => {
                if canvas.relative_mouse.is_some() || canvas.touchpad.as_ref().is_some_and(Touchpad::active) || canvas.touch_gestures.active() {
                    canvas.release();
                }
                canvas.update_attention(GetForegroundWindow() == window, IsWindowVisible(window).as_bool(), wparam.0 as u32 == SIZE_MINIMIZED);
                if let Some(pad) = &canvas.touchpad {
                    let _ = pad.resize();
                }
                canvas.layout_chrome();
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
                let updated = canvas.update_pointer();
                if owned != canvas.local_pointer && canvas.independent() {
                    canvas.draw();
                }
                return if updated { LRESULT(1) } else { DefWindowProcW(window, message, wparam, lparam) };
            }
            WM_MOUSELEAVE => canvas.draw(),
            DM_POINTERHITTEST if canvas.controlling() && canvas.owns_input() => {
                if let Some(anchor) = canvas.pointer_in_client().and_then(|(x, y)| canvas.fraction(x, y)).filter(|p| Canvas::inside_picture(*p))
                    && let Some(pad) = &mut canvas.touchpad
                    && pad.hit(wparam.0 as u16 as u32, anchor)
                {
                    if SetTimer(Some(window), TOUCHPAD_TIMER, 12, None) == 0 {
                        pad.reset();
                        return DefWindowProcW(window, message, wparam, lparam);
                    }
                } else {
                    return DefWindowProcW(window, message, wparam, lparam);
                }
            }
            WM_TIMER if wparam.0 == TOUCHPAD_TIMER => {
                if !canvas.controlling() || !canvas.owns_input() {
                    canvas.release();
                    return LRESULT(0);
                }
                let Some(pad) = &mut canvas.touchpad else { return LRESULT(0) };
                let anchor = pad.anchor;
                match pad.poll(GetDpiForWindow(window)) {
                    Ok((motions, active)) => {
                        if !active {
                            let _ = KillTimer(Some(window), TOUCHPAD_TIMER);
                        }
                        for motion in motions {
                            if let Some(input) = motion.input(&canvas.translator, anchor) {
                                canvas.flush_move();
                                canvas.send(ViewerCommand::Input(input));
                            }
                        }
                    }
                    Err(_) => {
                        canvas.release();
                        canvas.touchpad = None;
                    }
                }
            }
            WM_GESTURENOTIFY if canvas.supports_gestures && canvas.controlling() && canvas.owns_input() => {
                TouchGestures::configure(window);
                return DefWindowProcW(window, message, wparam, lparam);
            }
            WM_GESTURE if canvas.supports_gestures && canvas.controlling() && canvas.owns_input() => {
                let handle = windows::Win32::UI::Input::Touch::HGESTUREINFO(lparam.0 as _);
                let Some((motion, mut point)) = canvas.touch_gestures.read(handle) else { return DefWindowProcW(window, message, wparam, lparam) };
                if ScreenToClient(window, &mut point).as_bool()
                    && let Some(anchor) = canvas.fraction(point.x, point.y).filter(|p| Canvas::inside_picture(*p))
                    && let Some(input) = motion.input(&canvas.translator, anchor)
                {
                    canvas.flush_move();
                    canvas.send(ViewerCommand::Input(input));
                } else {
                    canvas.release();
                }
            }
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
                canvas.send_pending_move(false);
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
                MENU_RELEASE if canvas.connected => {
                    canvas.release();
                    canvas.set_status("点击画面继续");
                    canvas.draw();
                }
                MENU_REMOTE_AUDIO if canvas.connected && canvas.current_generation() && canvas.supports_audio && !canvas.audio_pending && !canvas.closing => {
                    if canvas.owns_input() {
                        canvas.release();
                    }
                    canvas.audio_wanted = !canvas.audio_wanted;
                    canvas.audio_pending = true;
                    canvas.update_input_menu();
                    canvas.send(ViewerCommand::RemoteAudio(canvas.audio_wanted));
                }
                MENU_RELATIVE_MOUSE if canvas.connected && canvas.current_generation() && canvas.relative_supported && !canvas.closing => {
                    canvas.release();
                    canvas.relative_enabled = !canvas.relative_enabled;
                    canvas.update_input_menu();
                    canvas.capture_keyboard();
                    if canvas.relative_enabled && canvas.relative_mouse.is_none() {
                        canvas.set_status("点击远端画面锁定相对鼠标，Ctrl+Alt+Esc 释放");
                    }
                }
                MENU_CAPS_ACTIONS if canvas.connected && canvas.current_generation() && canvas.supports_input_actions && !canvas.closing => {
                    canvas.release();
                    canvas.caps_forwarding = !canvas.caps_forwarding;
                    canvas.update_input_menu();
                    SendMessageW(canvas.owner, WM_CAPS_PREFERENCE, Some(WPARAM(usize::from(canvas.caps_forwarding))), None);
                    canvas.capture_keyboard();
                }
                MENU_AUTO_CLIPBOARD if canvas.connected && canvas.supports_clipboard && !canvas.closing => {
                    canvas.mailbox.clipboard_enabled.fetch_xor(true, Ordering::Relaxed);
                    canvas.update_input_menu();
                    canvas.update_clipboard_preference();
                }
                MENU_SEND_CLIPBOARD if canvas.connected && canvas.current_generation() && !canvas.closing => match clipboard::text() {
                    Some(text) => canvas.send(ViewerCommand::SendClipboard(text)),
                    None => canvas.set_status("本机剪贴板中没有文字"),
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
                        canvas.chrome.enable_button(TOOL_DISPLAY, false);
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
