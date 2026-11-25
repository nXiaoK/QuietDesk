use super::super::settings::VIEWER_QUALITIES;
use super::super::util::wide;
use super::super::workspace_style::{ButtonKind, FontRole, Surface, TextTone, Theme};
use quietdesk_core::messages::VideoStreamState;
use std::rc::Rc;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct2D::Common::{D2D_RECT_F, D2D1_COLOR_F};
use windows::Win32::Graphics::Direct2D::{ID2D1HwndRenderTarget, ID2D1SolidColorBrush};
use windows::Win32::Graphics::Gdi::{HBRUSH, HDC, InvalidateRect};
use windows::Win32::UI::Controls::DRAWITEMSTRUCT;
use windows::Win32::UI::Input::KeyboardAndMouse::EnableWindow;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

pub(super) const MENU_FULL_SCREEN: usize = 100;
pub(super) const MENU_SEND_CLIPBOARD: usize = 101;
pub(super) const MENU_REQUEST_CLIPBOARD: usize = 102;
pub(super) const MENU_DISCONNECT: usize = 103;
pub(super) const RETRY_NOW: usize = 104;
pub(super) const CANCEL_RETRY: usize = 105;
pub(super) const MENU_CAPS_ACTIONS: usize = 106;
pub(super) const MENU_RELATIVE_MOUSE: usize = 107;
pub(super) const MENU_AUTO_CLIPBOARD: usize = 108;
pub(super) const MENU_REMOTE_AUDIO: usize = 109;
pub(super) const TOOL_DISPLAY: usize = 110;
const TOOL_QUALITY: usize = 111;
const TOOL_CLIPBOARD: usize = 112;
const TOOL_MORE: usize = 113;
const TOOL_SETTINGS: usize = 114;
pub(super) const MENU_RELEASE: usize = 115;
pub(super) const MENU_QUALITY: usize = 200;
pub(super) const MENU_DISPLAY: usize = 300;

const TOOLBAR_HEIGHT: i32 = 48;
const STATUS_HEIGHT: i32 = 30;
const STATUS_STYLE: WINDOW_STYLE = WINDOW_STYLE(0x0200 | 0x4000); // SS_CENTERIMAGE | SS_ENDELLIPSIS
const STATUS_ALIGN_RIGHT: WINDOW_STYLE = WINDOW_STYLE(2); // SS_RIGHT
const TOOLBAR: [(usize, PCWSTR, i32); 7] = [
    (TOOL_DISPLAY, w!("显示器"), 74),
    (TOOL_QUALITY, w!("画质"), 62),
    (MENU_REMOTE_AUDIO, w!("远端声音"), 100),
    (TOOL_CLIPBOARD, w!("剪贴板"), 78),
    (MENU_FULL_SCREEN, w!("全屏"), 52),
    (TOOL_MORE, w!("更多操作"), 84),
    (TOOL_SETTINGS, w!("会话设置"), 84),
];

pub(super) struct Popup(pub(super) HMENU);

impl Popup {
    pub(super) unsafe fn new() -> windows::core::Result<Self> {
        unsafe { CreatePopupMenu().map(Self) }
    }

    unsafe fn items(items: &[(usize, PCWSTR)]) -> windows::core::Result<Rc<Self>> {
        unsafe {
            let popup = Self::new()?;
            for &(id, title) in items {
                if id == 0 {
                    AppendMenuW(popup.0, MF_SEPARATOR, 0, None)?;
                } else {
                    AppendMenuW(popup.0, MF_STRING, id, title)?;
                }
            }
            Ok(Rc::new(popup))
        }
    }

    pub(super) unsafe fn track(&self, window: HWND, button: HWND) -> Option<usize> {
        unsafe {
            let mut rect = RECT::default();
            GetWindowRect(button, &mut rect).ok()?;
            let command = TrackPopupMenu(self.0, TPM_RETURNCMD | TPM_NONOTIFY, rect.left, rect.bottom, None, window, None).0 as usize;
            (command != 0).then_some(command)
        }
    }

    unsafe fn set_item(&self, id: usize, enabled: bool, checked: bool) {
        unsafe {
            let _ = EnableMenuItem(self.0, id as u32, if enabled { MF_ENABLED } else { MF_GRAYED });
            CheckMenuItem(self.0, id as u32, if enabled && checked { MF_CHECKED.0 } else { MF_UNCHECKED.0 });
        }
    }
}

impl Drop for Popup {
    fn drop(&mut self) {
        let _ = unsafe { DestroyMenu(self.0) };
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
pub(super) enum Mode {
    Connecting,
    Reconnecting,
    ViewOnly,
    Ready,
    Controlling,
    RelativeMouse,
    Closing,
}

impl Mode {
    fn label(self) -> &'static str {
        match self {
            Self::Connecting => "正在连接",
            Self::Reconnecting => "正在重连",
            Self::ViewOnly => "仅观看",
            Self::Ready => "已释放控制",
            Self::Controlling => "控制中",
            Self::RelativeMouse => "相对鼠标锁定",
            Self::Closing => "正在断开",
        }
    }

    fn tone(self) -> TextTone {
        match self {
            Self::Controlling | Self::RelativeMouse => TextTone::Emerald,
            Self::Reconnecting => TextTone::Amber,
            _ => TextTone::Secondary,
        }
    }

    fn needs_release_hint(self) -> bool {
        matches!(self, Self::Controlling | Self::RelativeMouse)
    }
}

pub(super) struct Chrome {
    pub(super) theme: Theme,
    buttons: [HWND; TOOLBAR.len()],
    status: HWND,
    metrics: HWND,
    mode: Mode,
    notice: String,
    resolution: String,
    latency: Option<String>,
    quality: Rc<Popup>,
    clipboard: Rc<Popup>,
    more: Rc<Popup>,
    settings: Rc<Popup>,
}

impl Chrome {
    pub(super) unsafe fn new(window: HWND, instance: HINSTANCE, dpi: u32) -> windows::core::Result<Self> {
        unsafe {
            let quality = Popup::new()?;
            for (index, (label, _)) in VIEWER_QUALITIES.iter().enumerate() {
                AppendMenuW(quality.0, MF_STRING, MENU_QUALITY + index, PCWSTR(wide(label).as_ptr()))?;
            }
            let clipboard = Popup::items(&[(MENU_SEND_CLIPBOARD, w!("发送本机剪贴板文字")), (MENU_REQUEST_CLIPBOARD, w!("获取远端剪贴板文字"))])?;
            let more = Popup::items(&[
                (MENU_RELEASE, w!("释放控制\tCtrl+Alt+Esc")),
                (MENU_RELATIVE_MOUSE, w!("相对鼠标")),
                (0, PCWSTR::null()),
                (MENU_DISCONNECT, w!("断开远程连接")),
            ])?;
            let settings = Popup::items(&[
                (MENU_CAPS_ACTIONS, w!("独立转发 Caps Lock（短按切输入法，长按切大写）")),
                (MENU_AUTO_CLIPBOARD, w!("自动同步剪贴板")),
                (0, PCWSTR::null()),
                (MENU_FULL_SCREEN, w!("全屏\tCtrl+Alt+Enter")),
            ])?;
            let control = |class, title, id, style| {
                CreateWindowExW(WINDOW_EX_STYLE(0), class, title, WS_CHILD | style, 0, 0, 0, 0, Some(window), Some(HMENU(id as _)), Some(instance), None)
            };
            let mut buttons = [HWND::default(); TOOLBAR.len()];
            for (button, (id, label, _)) in buttons.iter_mut().zip(TOOLBAR) {
                *button = control(w!("BUTTON"), label, id, WS_TABSTOP | WINDOW_STYLE(BS_OWNERDRAW as u32))?;
            }
            let chrome = Self {
                theme: Theme::new(dpi),
                buttons,
                status: control(w!("STATIC"), w!(""), 0, STATUS_STYLE)?,
                metrics: control(w!("STATIC"), w!(""), 0, STATUS_STYLE | STATUS_ALIGN_RIGHT)?,
                mode: Mode::Connecting,
                notice: String::new(),
                resolution: String::new(),
                latency: None,
                quality: Rc::new(quality),
                clipboard,
                more,
                settings,
            };
            chrome.apply_fonts();
            chrome.update_status_text();
            Ok(chrome)
        }
    }

    unsafe fn apply_fonts(&self) {
        unsafe {
            for (controls, role) in [(self.buttons.as_slice(), FontRole::Body), (&[self.status, self.metrics], FontRole::Small)] {
                for &control in controls {
                    SendMessageW(control, WM_SETFONT, Some(WPARAM(self.theme.font(role).0 as usize)), Some(LPARAM(1)));
                }
            }
        }
    }

    pub(super) unsafe fn set_dpi(&mut self, dpi: u32) {
        let previous = std::mem::replace(&mut self.theme, Theme::new(dpi));
        unsafe { self.apply_fonts() };
        drop(previous);
    }

    pub(super) fn viewport(&self, mut client: RECT, full_screen: bool) -> RECT {
        if !full_screen {
            client.top = self.theme.scale(TOOLBAR_HEIGHT).min(client.bottom);
            client.bottom = (client.bottom - self.theme.scale(STATUS_HEIGHT)).max(client.top);
        }
        client
    }

    pub(super) unsafe fn layout(&self, client: RECT, full_screen: bool) {
        unsafe {
            let px = |value| self.theme.scale(value);
            let gap = px(4);
            let gaps = gap * (TOOLBAR.len() as i32 - 1);
            let ideal = TOOLBAR.iter().map(|&(_, _, width)| px(width)).sum::<i32>();
            let available = (client.right - px(16) - gaps).clamp(0, ideal);
            let mut x = (client.right - px(8) - available - gaps).max(px(8));
            let flags = SWP_NOZORDER | SWP_NOACTIVATE | if full_screen { SWP_HIDEWINDOW } else { SWP_SHOWWINDOW };
            for (button, (_, _, width)) in self.buttons.into_iter().zip(TOOLBAR) {
                let width = px(width) * available / ideal;
                let _ = SetWindowPos(button, None, x, px(8), width, px(32), flags);
                x += width + gap;
            }
            let inset = px(14);
            let footer_y = self.viewport(client, full_screen).bottom + px(1);
            let metrics_width = (client.right * 2 / 5).min(px(330));
            let _ = SetWindowPos(self.status, None, inset, footer_y, (client.right - metrics_width - 2 * inset).max(0), px(28), flags);
            let _ = SetWindowPos(self.metrics, None, client.right - metrics_width, footer_y, (metrics_width - inset).max(0), px(28), flags);
        }
    }

    pub(super) unsafe fn paint_bands(&self, target: &ID2D1HwndRenderTarget, brush: &ID2D1SolidColorBrush, client: RECT, viewport: RECT) {
        unsafe {
            let fill = |top, bottom, surface| {
                let color = self.theme.surface_color(surface).0;
                brush.SetColor(&D2D1_COLOR_F {
                    r: (color & 255) as f32 / 255.0,
                    g: ((color >> 8) & 255) as f32 / 255.0,
                    b: ((color >> 16) & 255) as f32 / 255.0,
                    a: 1.0,
                });
                target.FillRectangle(&D2D_RECT_F { left: 0.0, top: top as f32, right: client.right as f32, bottom: bottom as f32 }, brush);
            };
            fill(0, viewport.top, Surface::Canvas);
            fill(viewport.bottom, client.bottom, Surface::Inset);
            fill(viewport.top - 1, viewport.top, Surface::Hairline);
            fill(viewport.bottom, viewport.bottom + 1, Surface::Hairline);
        }
    }

    pub(super) fn popup(&self, id: usize, display: &Rc<Popup>) -> Option<Rc<Popup>> {
        let popup = match id {
            TOOL_DISPLAY => display,
            TOOL_QUALITY => &self.quality,
            TOOL_CLIPBOARD => &self.clipboard,
            TOOL_MORE => &self.more,
            TOOL_SETTINGS => &self.settings,
            _ => return None,
        };
        Some(Rc::clone(popup))
    }

    fn button(&self, id: usize) -> HWND {
        self.buttons[TOOLBAR.iter().position(|&(action, _, _)| action == id).expect("toolbar action")]
    }

    pub(super) fn enable_button(&self, id: usize, enabled: bool) {
        let _ = unsafe { EnableWindow(self.button(id), enabled) };
    }

    pub(super) fn set_connected(&self, connected: bool) {
        unsafe {
            self.enable_button(TOOL_QUALITY, connected);
            self.enable_button(TOOL_CLIPBOARD, connected);
            self.more.set_item(MENU_RELEASE, connected, false);
        }
    }

    pub(super) fn set_action(&self, id: usize, enabled: bool, selected: bool) {
        unsafe {
            match id {
                MENU_CAPS_ACTIONS | MENU_AUTO_CLIPBOARD => self.settings.set_item(id, enabled, selected),
                MENU_RELATIVE_MOUSE => self.more.set_item(id, enabled, selected),
                MENU_REMOTE_AUDIO => {
                    let button = self.button(id);
                    let label = if selected { w!("关闭声音") } else { w!("开启声音") };
                    let _ = EnableWindow(button, enabled);
                    let _ = SetWindowTextW(button, label);
                }
                _ => unreachable!("session action"),
            }
        }
    }

    pub(super) fn draw_button(&self, item: &DRAWITEMSTRUCT) -> bool {
        if !self.buttons.contains(&item.hwndItem) {
            return false;
        }
        self.theme.draw_button(item, ButtonKind::Tab { selected: false });
        true
    }

    pub(super) fn status_colors(&self, control: HWND, hdc: HDC) -> Option<HBRUSH> {
        let tone = if control == self.status {
            self.mode.tone()
        } else if control == self.metrics {
            TextTone::Muted
        } else {
            return None;
        };
        Some(self.theme.control_colors(hdc, Surface::Inset, tone))
    }

    pub(super) fn set_notice(&mut self, notice: &str) {
        self.notice = notice.replace(char::is_control, " ");
        self.update_status_text();
    }

    pub(super) fn set_mode(&mut self, mode: Mode) {
        if self.mode != mode {
            self.mode = mode;
            self.update_status_text();
            self.update_metrics_text();
        }
    }

    pub(super) fn set_stream(&mut self, stream: VideoStreamState) {
        self.resolution = format!("{} × {}", stream.width, stream.height);
        for (index, (_, settings)) in VIEWER_QUALITIES.iter().enumerate() {
            unsafe { self.quality.set_item(MENU_QUALITY + index, true, stream.settings == *settings) };
        }
        self.update_metrics_text();
    }

    pub(super) fn set_latency(&mut self, milliseconds: f64) {
        let latency = Some(format!("{milliseconds:.0} ms"));
        if latency != self.latency {
            self.latency = latency;
            self.update_metrics_text();
        }
    }

    pub(super) fn reset_metrics(&mut self) {
        self.resolution.clear();
        self.latency = None;
        self.update_metrics_text();
    }

    fn update_status_text(&self) {
        let headline = self.mode.label();
        let detail = if self.notice.is_empty() || self.notice == headline { String::new() } else { format!("   ·   {}", self.notice) };
        let text = wide(&format!("●  {headline}{detail}"));
        let _ = unsafe { SetWindowTextW(self.status, PCWSTR(text.as_ptr())) };
    }

    fn update_metrics_text(&self) {
        let values = [
            Some(self.resolution.as_str()).filter(|value| !value.is_empty()),
            self.latency.as_deref(),
            self.mode.needs_release_hint().then_some("Ctrl+Alt+Esc 释放"),
        ];
        let text = wide(&values.into_iter().flatten().collect::<Vec<_>>().join("   ·   "));
        let _ = unsafe { SetWindowTextW(self.metrics, PCWSTR(text.as_ptr())) };
    }

    pub(super) unsafe fn refresh_palette(&mut self) {
        self.theme.refresh_palette();
        unsafe {
            for control in self.buttons.into_iter().chain([self.status, self.metrics]) {
                let _ = InvalidateRect(Some(control), None, true);
            }
        }
    }
}
