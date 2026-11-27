//! Native controls and layout for the QuietDesk workspace.

use super::device_table;
use super::util::{from_wide, wide};
use super::workspace_style::{ButtonKind, FontRole, NavigationIcon, Surface, TextTone, Theme};
use std::cell::{Cell, RefCell};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::{BeginPaint, EndPaint, HDC, InvalidateRect, PAINTSTRUCT, RDW_ALLCHILDREN, RDW_INVALIDATE, RedrawWindow};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::SystemServices::{SS_ENDELLIPSIS, SS_NOPREFIX};
use windows::Win32::UI::Controls::{
    DRAWITEMSTRUCT, EM_SETMARGINS, ICC_LISTVIEW_CLASSES, INITCOMMONCONTROLSEX, InitCommonControlsEx, LVS_REPORT, LVS_SHOWSELALWAYS, LVS_SINGLESEL, ODT_LISTBOX,
    WC_LISTVIEWW,
};
use windows::Win32::UI::HiDpi::AdjustWindowRectExForDpi;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetFocus, SetFocus};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

pub(super) const ADDRESS: usize = 1001;
pub(super) const PORT: usize = 1002;
pub(super) const CODE: usize = 1003;
pub(super) const CONNECT: usize = 1004;
pub(super) const RECENT: usize = 1005;
pub(super) const FORGET: usize = 1006;
pub(super) const VIEWER_QUALITY: usize = 1007;
pub(super) const PC_MODIFIERS: usize = 1008;
pub(super) const AUTO_RECONNECT: usize = 1009;
pub(super) const DEVICE_HEADING: usize = 1010;
pub(super) const DEVICE_DETAIL: usize = 1011;
pub(super) const EMPTY_RECENT: usize = 1012;
pub(super) const DEVICE_TABLE: usize = 1013;
pub(super) const EMPTY_DEVICES: usize = 1014;
pub(super) const NEW_CONNECTION_PAGE: usize = 1015;
pub(super) const CONTINUE_CONNECTION: usize = 1016;
pub(super) const HOST_STATUS: usize = 1101;
pub(super) const HOST_PORT: usize = 1102;
pub(super) const SHARE: usize = 1103;
pub(super) const HOST_CODE: usize = 1104;
pub(super) const COPY_CODE: usize = 1105;
pub(super) const NEW_CODE: usize = 1106;
pub(super) const ALLOW_CONTROL: usize = 1107;
pub(super) const ALLOW_CLIPBOARD: usize = 1108;
pub(super) const QUALITY_LIMIT: usize = 1109;
pub(super) const MAC_MODIFIERS: usize = 1110;
pub(super) const SHARED_DISPLAY: usize = 1111;
pub(super) const SHARING_SUMMARY: usize = 1112;
pub(super) const UPDATE_STATUS: usize = 1201;
pub(super) const UPDATE_ACTION: usize = 1202;
pub(super) const UPDATE_NOTES: usize = 1203;
pub(super) const AUTO_CHECK_UPDATES: usize = 1204;
pub(super) const AUTO_INSTALL_UPDATES: usize = 1205;
pub(super) const NEW_CONNECTION: usize = 1301;
pub(super) const NAV_DEVICES: usize = 1302;
pub(super) const NAV_SHARING: usize = 1303;
pub(super) const NAV_SETTINGS: usize = 1304;
pub(super) const TAB_SHARING: usize = 1305;
pub(super) const TAB_HOST_QUALITY: usize = 1306;
pub(super) const TAB_KEYBOARD: usize = 1307;
pub(super) const TAB_DEFAULTS: usize = 1308;
pub(super) const TAB_UPDATES: usize = 1309;
pub(super) const TAB_TAILSCALE: usize = 1310;
pub(super) const TAILSCALE_STATUS: usize = 1311;
pub(super) const TAILSCALE_LOGIN: usize = 1312;
pub(super) const TAILSCALE_LOGOUT: usize = 1313;
pub(super) const TAILSCALE_ADDRESS: usize = 1314;

pub(super) const FRAME_STYLE: WINDOW_STYLE = WINDOW_STYLE(WS_OVERLAPPEDWINDOW.0 | WS_CLIPCHILDREN.0);
const SIDEBAR_WIDTH: i32 = 216;
const PAGE_MARGIN: i32 = 28;
const MAX_PAGE_WIDTH: i32 = 880;

pub(super) fn window_frame(dpi: u32, width: i32, height: i32) -> RECT {
    let mut rect = RECT { right: width * dpi as i32 / 96, bottom: height * dpi as i32 / 96, ..Default::default() };
    let _ = unsafe { AdjustWindowRectExForDpi(&mut rect, FRAME_STYLE, false, WINDOW_EX_STYLE(0), dpi) };
    rect
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Page {
    Devices,
    Connection,
    Sharing,
    HostQuality,
    Keyboard,
    Defaults,
    Updates,
    Tailscale,
}

impl Page {
    fn cards(self) -> &'static [(i32, i32)] {
        match self {
            Self::Devices => &[(105, 185)],
            Self::Connection => &[(92, 319)],
            Self::Sharing => &[(101, 292), (306, 432)],
            Self::HostQuality | Self::Keyboard => &[(101, 259)],
            Self::Defaults => &[(101, 240)],
            Self::Updates => &[(101, 269)],
            Self::Tailscale => &[(101, 323)],
        }
    }

    fn is_sharing(self) -> bool {
        matches!(self, Self::Sharing | Self::HostQuality)
    }

    fn is_settings(self) -> bool {
        matches!(self, Self::Keyboard | Self::Defaults | Self::Updates | Self::Tailscale)
    }
}

#[derive(Clone, Copy)]
enum Area {
    Sidebar,
    SharingTabs,
    SettingsTabs,
    Page(Page),
}

impl Area {
    fn shows(self, page: Page) -> bool {
        match self {
            Self::Sidebar => true,
            Self::SharingTabs => page.is_sharing(),
            Self::SettingsTabs => page.is_settings(),
            Self::Page(only) => page == only,
        }
    }
}

#[derive(Clone, Copy)]
enum Kind {
    Label(FontRole, Surface, TextTone),
    Edit { numeric: bool, read_only: bool, code: bool },
    Button,
    Check,
    List,
    Table,
    Combo,
}

impl Kind {
    fn font(self) -> FontRole {
        match self {
            Self::Label(font, ..) => font,
            Self::Edit { code: true, .. } => FontRole::Code,
            _ => FontRole::Body,
        }
    }

    fn native(self) -> (PCWSTR, WINDOW_STYLE, WINDOW_EX_STYLE) {
        let edge = WS_EX_CLIENTEDGE;
        let tab = WS_TABSTOP.0;
        let (class, style, extended) = match self {
            Self::Label(..) => (w!("STATIC"), SS_NOPREFIX.0 | SS_ENDELLIPSIS.0, WINDOW_EX_STYLE(0)),
            Self::Edit { numeric, read_only, .. } => {
                let mut style = tab | ES_AUTOHSCROLL as u32;
                if numeric {
                    style |= ES_NUMBER as u32;
                }
                if read_only {
                    style |= ES_READONLY as u32;
                }
                (w!("EDIT"), style, edge)
            }
            Self::Button => (w!("BUTTON"), tab | BS_OWNERDRAW as u32, WINDOW_EX_STYLE(0)),
            Self::Check => (w!("BUTTON"), tab | BS_AUTOCHECKBOX as u32, WINDOW_EX_STYLE(0)),
            Self::List => (
                w!("LISTBOX"),
                tab | WS_VSCROLL.0 | LBS_NOTIFY as u32 | LBS_OWNERDRAWFIXED as u32 | LBS_HASSTRINGS as u32 | LBS_NOINTEGRALHEIGHT as u32,
                WINDOW_EX_STYLE(0),
            ),
            Self::Table => (WC_LISTVIEWW, tab | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS, edge),
            Self::Combo => (w!("COMBOBOX"), tab | WS_VSCROLL.0 | CBS_DROPDOWNLIST as u32, WINDOW_EX_STYLE(0)),
        };
        (class, WS_CHILD | WINDOW_STYLE(style), extended)
    }
}

type ControlSpec<'a> = (Kind, usize, &'a str, i32, i32, i32, i32);

struct Control {
    window: HWND,
    id: usize,
    area: Area,
    kind: Kind,
    // Negative x/y are right/bottom offsets. Nonpositive width/height fill to that edge.
    bounds: (i32, i32, i32, i32),
}

pub(super) struct Workspace {
    window: HWND,
    dpi: Cell<u32>,
    theme: RefCell<Theme>,
    page: Cell<Page>,
    sharing_page: Cell<Page>,
    settings_page: Cell<Page>,
    device_count: Cell<usize>,
    draft_available: Cell<bool>,
    controls: Vec<Control>,
}

impl Workspace {
    pub(super) fn new(window: HWND, dpi: u32, port: u16, update_status: &str) -> windows::core::Result<Self> {
        use Kind::*;
        use Page::*;
        let common_controls = INITCOMMONCONTROLSEX { dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32, dwICC: ICC_LISTVIEW_CLASSES };
        if !unsafe { InitCommonControlsEx(&common_controls) }.as_bool() {
            return Err(windows::core::Error::from_thread());
        }
        let theme = Theme::new(dpi);
        let instance: HINSTANCE = unsafe { GetModuleHandleW(None)? }.into();
        let mut controls = Vec::new();
        let mut add = |area, specs: &[ControlSpec<'_>]| -> windows::core::Result<()> {
            for &(kind, id, text, x, y, width, height) in specs {
                let (class, style, extended) = kind.native();
                let hwnd = unsafe {
                    CreateWindowExW(extended, class, PCWSTR(wide(text).as_ptr()), style, 0, 0, 0, 0, Some(window), Some(HMENU(id as _)), Some(instance), None)?
                };
                if matches!(kind, Table) {
                    device_table::initialize(hwnd)?;
                }
                controls.push(Control { window: hwnd, id, area, kind, bounds: (x, y, width, height) });
            }
            Ok(())
        };

        let title = Label(FontRole::PageTitle, Surface::Canvas, TextTone::Ink);
        let subtitle = Label(FontRole::Body, Surface::Canvas, TextTone::Muted);
        let section = Label(FontRole::SectionTitle, Surface::Card, TextTone::Ink);
        let label = Label(FontRole::Body, Surface::Card, TextTone::Secondary);
        let sidebar_title = Label(FontRole::Emphasis, Surface::Sidebar, TextTone::Ink);
        let sidebar_hint = Label(FontRole::Small, Surface::Sidebar, TextTone::Muted);
        let entry = Edit { numeric: false, read_only: false, code: false };
        let port_entry = Edit { numeric: true, read_only: false, code: false };
        let code_entry = Edit { numeric: false, read_only: false, code: true };
        let host_code = Edit { numeric: false, read_only: true, code: false };
        let port = port.to_string();

        add(
            Area::Sidebar,
            &[
                (sidebar_title, 0, "QuietDesk", 18, 20, -16, 26),
                (sidebar_hint, 0, "我的设备", 18, 65, -16, 20),
                (Button, NEW_CONNECTION, "新建连接", 10, 88, -10, 34),
                (sidebar_hint, EMPTY_RECENT, "暂无已保存的设备", 18, 133, -12, 22),
                (List, RECENT, "", 10, 128, -10, -158),
                (Button, NAV_DEVICES, "全部设备", 10, -149, -10, 34),
                (Button, NAV_SHARING, "本机共享", 10, -113, -10, 34),
                (Button, NAV_SETTINGS, "设置", 10, -77, -10, 34),
                (sidebar_hint, SHARING_SUMMARY, "共享未开启", 18, -30, -12, 20),
            ],
        )?;
        add(
            Area::Page(Devices),
            &[
                (title, 0, "全部设备", 0, 25, -244, 37),
                (subtitle, 0, "双击已保存的设备查看连接信息。", 0, 67, 0, 23),
                (Button, CONTINUE_CONNECTION, "继续编辑", -224, 31, 104, 32),
                (Button, NEW_CONNECTION_PAGE, "新建连接", -112, 31, 112, 32),
                (Label(FontRole::Body, Surface::Card, TextTone::Muted), EMPTY_DEVICES, "暂无已保存的设备", 18, 135, -18, 24),
                (Table, DEVICE_TABLE, "", 0, 105, 0, -24),
            ],
        )?;
        add(
            Area::Page(Connection),
            &[
                (title, DEVICE_HEADING, "新建连接", 0, 25, 0, 37),
                (subtitle, DEVICE_DETAIL, "填写目标设备的连接信息", 0, 63, 0, 23),
                (label, 0, "地址（普通主机名、IP 或 tailscale:100.x.x.x）", 18, 110, -116, 22),
                (entry, ADDRESS, "", 18, 134, -116, 29),
                (label, 0, "端口", -102, 110, 84, 22),
                (port_entry, PORT, &port, -102, 134, 84, 29),
                (label, 0, "配对码", 18, 181, -18, 22),
                (code_entry, CODE, "", 18, 203, -18, 29),
                (Button, FORGET, "移除设备", 18, 270, 100, 30),
                (Button, CONNECT, "连接", -122, 269, 104, 32),
            ],
        )?;
        add(Area::SharingTabs, &[(Button, TAB_SHARING, "本机共享", 0, 17, 104, 33), (Button, TAB_HOST_QUALITY, "默认画质", 109, 17, 104, 33)])?;
        add(
            Area::Page(Sharing),
            &[
                (title, 0, "本机共享", 0, 59, 0, 36),
                (section, 0, "共享状态", 18, 117, -144, 25),
                (label, HOST_STATUS, "未共享", 18, 148, -18, 22),
                (Button, SHARE, "开始共享", -122, 116, 104, 32),
                (label, 0, "端口", 18, 183, 88, 22),
                (port_entry, HOST_PORT, &port, 18, 205, 88, 29),
                (label, 0, "配对码", 123, 183, -18, 22),
                (host_code, HOST_CODE, "", 123, 205, -18, 29),
                (Button, COPY_CODE, "复制", -192, 247, 76, 30),
                (Button, NEW_CODE, "重新生成", -108, 247, 90, 30),
                (section, 0, "控制与剪贴板", 18, 322, -18, 24),
                (Check, ALLOW_CONTROL, "允许控制端操作键盘和鼠标", 18, 352, -18, 26),
                (Check, ALLOW_CLIPBOARD, "允许同步剪贴板文字、图片和文件", 18, 388, -18, 26),
            ],
        )?;
        add(
            Area::Page(HostQuality),
            &[
                (title, 0, "默认画质", 0, 59, 0, 36),
                (section, 0, "屏幕与画质", 18, 117, -18, 24),
                (label, 0, "共享屏幕", 18, 158, 120, 22),
                (Combo, SHARED_DISPLAY, "", 142, 150, -18, 240),
                (label, 0, "画质上限", 18, 204, 120, 22),
                (Combo, QUALITY_LIMIT, "", 142, 196, -18, 240),
            ],
        )?;
        add(
            Area::SettingsTabs,
            &[
                (Button, TAB_KEYBOARD, "键盘与快捷键", 0, 17, 126, 33),
                (Button, TAB_DEFAULTS, "连接默认项", 131, 17, 112, 33),
                (Button, TAB_UPDATES, "软件更新", 248, 17, 102, 33),
                (Button, TAB_TAILSCALE, "Tailscale", 355, 17, 92, 33),
            ],
        )?;
        add(
            Area::Page(Tailscale),
            &[
                (title, 0, "Tailscale", 0, 59, 0, 36),
                (section, 0, "内置 Tailscale 节点", 18, 117, -18, 26),
                (label, TAILSCALE_STATUS, "未启用", 18, 150, -18, 26),
                (label, 0, "本机连接地址", 18, 186, 110, 26),
                (host_code, TAILSCALE_ADDRESS, "", 132, 181, -18, 29),
                (label, 0, "在控制端输入此地址、共享端口和配对码。", 18, 220, -18, 26),
                (Button, TAILSCALE_LOGIN, "登录 Tailscale", 18, 265, 135, 32),
                (Button, TAILSCALE_LOGOUT, "退出 Tailscale", 162, 265, 135, 32),
            ],
        )?;
        add(
            Area::Page(Keyboard),
            &[
                (title, 0, "键盘与快捷键", 0, 59, 0, 36),
                (section, 0, "修饰键映射", 18, 117, -18, 26),
                (label, 0, "作为控制端", 18, 158, 120, 22),
                (Combo, PC_MODIFIERS, "", 142, 150, -18, 240),
                (label, 0, "被 Mac 控制时", 18, 204, 120, 22),
                (Combo, MAC_MODIFIERS, "", 142, 196, -18, 240),
            ],
        )?;
        add(
            Area::Page(Defaults),
            &[
                (title, 0, "连接默认项", 0, 59, 0, 36),
                (section, 0, "远程控制", 18, 117, -18, 26),
                (label, 0, "默认画质", 18, 158, 120, 22),
                (Combo, VIEWER_QUALITY, "", 142, 150, -18, 240),
                (Check, AUTO_RECONNECT, "断线后自动重连", 18, 192, -18, 26),
            ],
        )?;
        add(
            Area::Page(Updates),
            &[
                (title, 0, "软件更新", 0, 59, 0, 36),
                (section, 0, "更新状态", 18, 117, -235, 26),
                (Button, UPDATE_NOTES, "更新说明", -208, 114, 80, 32),
                (Button, UPDATE_ACTION, "检查更新", -120, 114, 102, 32),
                (label, UPDATE_STATUS, update_status, 18, 152, -18, 24),
                (Check, AUTO_CHECK_UPDATES, "自动检查更新（每天一次）", 18, 190, -18, 26),
                (Check, AUTO_INSTALL_UPDATES, "非远程控制空闲时自动下载并安装", 18, 224, -18, 26),
            ],
        )?;

        let workspace = Self {
            window,
            dpi: Cell::new(dpi),
            theme: RefCell::new(theme),
            page: Cell::new(Connection),
            sharing_page: Cell::new(Sharing),
            settings_page: Cell::new(Keyboard),
            device_count: Cell::new(0),
            draft_available: Cell::new(false),
            controls,
        };
        workspace.update_fonts();
        workspace.layout();
        Ok(workspace)
    }

    pub(super) fn navigate(&self, id: usize) {
        let page = match id {
            NAV_DEVICES => Page::Devices,
            NAV_SHARING => self.sharing_page.get(),
            NAV_SETTINGS => self.settings_page.get(),
            TAB_SHARING => Page::Sharing,
            TAB_HOST_QUALITY => Page::HostQuality,
            TAB_KEYBOARD => Page::Keyboard,
            TAB_DEFAULTS => Page::Defaults,
            TAB_UPDATES => Page::Updates,
            TAB_TAILSCALE => Page::Tailscale,
            _ => return,
        };
        self.select(page);
    }

    pub(super) fn select(&self, page: Page) {
        if self.page.replace(page) == page {
            return;
        }
        let focus = unsafe { GetFocus() };
        let move_focus = self.controls.iter().any(|control| control.window == focus && !control.area.shows(page));
        if page.is_settings() {
            self.settings_page.set(page);
        } else if page.is_sharing() {
            self.sharing_page.set(page);
        }
        self.layout();
        if move_focus {
            let nav = if matches!(page, Page::Devices | Page::Connection) {
                NAV_DEVICES
            } else if page.is_settings() {
                NAV_SETTINGS
            } else {
                NAV_SHARING
            };
            if let Ok(button) = unsafe { GetDlgItem(Some(self.window), nav as i32) } {
                let _ = unsafe { SetFocus(Some(button)) };
            }
        }
        for control in self.controls.iter().filter(|control| matches!(control.kind, Kind::Button)) {
            let _ = unsafe { InvalidateRect(Some(control.window), None, false) };
        }
    }

    pub(super) fn set_draft_available(&self, available: bool) {
        if self.draft_available.replace(available) != available && self.page.get() == Page::Devices {
            self.layout();
        }
    }

    pub(super) fn show_devices(&self, count: usize) {
        if self.device_count.replace(count) != count {
            self.layout();
        }
    }

    fn update_fonts(&self) {
        for control in &self.controls {
            let font = self.theme.borrow().font(control.kind.font());
            unsafe { SendMessageW(control.window, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1))) };
            if matches!(control.kind, Kind::List) {
                let height = self.theme.borrow().scale(34);
                unsafe { SendMessageW(control.window, LB_SETITEMHEIGHT, Some(WPARAM(0)), Some(LPARAM(height as isize))) };
            }
            if matches!(control.kind, Kind::Edit { .. }) {
                let margin = self.theme.borrow().scale(7) as isize;
                unsafe { SendMessageW(control.window, EM_SETMARGINS, Some(WPARAM(3)), Some(LPARAM(margin | (margin << 16)))) };
            }
        }
    }

    pub(super) fn dpi_changed(&self, dpi: u32, suggested: &RECT) {
        self.dpi.set(dpi);
        let old = self.theme.replace(Theme::new(dpi));
        self.update_fonts();
        drop(old);
        unsafe {
            let _ = SetWindowPos(
                self.window,
                None,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                SWP_NOACTIVATE | SWP_NOZORDER,
            );
        }
        self.layout();
    }

    pub(super) fn min_size(&self, info: &mut MINMAXINFO) {
        let frame = window_frame(self.dpi.get(), 760, 454);
        info.ptMinTrackSize = POINT { x: frame.right - frame.left, y: frame.bottom - frame.top };
    }

    fn client_rect(&self) -> RECT {
        let mut rect = RECT::default();
        let _ = unsafe { GetClientRect(self.window, &mut rect) };
        rect
    }

    fn page_geometry(theme: &Theme, client_width: i32) -> (i32, i32) {
        let left = theme.scale(SIDEBAR_WIDTH + PAGE_MARGIN);
        let width = (client_width - left - theme.scale(PAGE_MARGIN)).min(theme.scale(MAX_PAGE_WIDTH));
        (left, width)
    }

    pub(super) fn layout(&self) {
        let client = self.client_rect();
        let page = self.page.get();
        for control in &self.controls {
            let visible = control.area.shows(page)
                && match control.id {
                    RECENT | DEVICE_TABLE => self.device_count.get() != 0,
                    EMPTY_RECENT | EMPTY_DEVICES => self.device_count.get() == 0,
                    CONTINUE_CONNECTION => self.draft_available.get(),
                    _ => true,
                };
            if !visible {
                let _ = unsafe { ShowWindow(control.window, SW_HIDE) };
                continue;
            }
            let (x, y, width, height) = {
                let theme = self.theme.borrow();
                let (left, extent) =
                    if matches!(control.area, Area::Sidebar) { (0, theme.scale(SIDEBAR_WIDTH)) } else { Self::page_geometry(&theme, client.right) };
                let (x, y, width, height) = control.bounds;
                let x = if x < 0 { extent + theme.scale(x) } else { theme.scale(x) };
                let y = if y < 0 { client.bottom + theme.scale(y) } else { theme.scale(y) };
                let width = if width <= 0 { extent + theme.scale(width) - x } else { theme.scale(width) };
                let height = if height <= 0 { client.bottom + theme.scale(height) - y } else { theme.scale(height) };
                let height = if matches!(control.kind, Kind::Table) { height.min(theme.scale(28 + 24 * self.device_count.get() as i32)) } else { height };
                (left + x, y, width.max(0), height.max(0))
            };
            unsafe {
                let _ = SetWindowPos(control.window, None, x, y, width, height, SWP_NOACTIVATE | SWP_NOZORDER | SWP_SHOWWINDOW);
            }
            if matches!(control.kind, Kind::Table) {
                device_table::resize(control.window, width, self.dpi.get());
            }
        }
        let _ = unsafe { InvalidateRect(Some(self.window), None, false) };
    }

    pub(super) fn refresh_palette(&self) {
        self.theme.borrow_mut().refresh_palette();
        unsafe {
            let _ = RedrawWindow(Some(self.window), None, None, RDW_INVALIDATE | RDW_ALLCHILDREN);
        }
    }

    pub(super) fn paint(&self) {
        let mut paint = PAINTSTRUCT::default();
        let dc = unsafe { BeginPaint(self.window, &mut paint) };
        let theme = self.theme.borrow();
        let client = self.client_rect();
        theme.fill(dc, &client, Surface::Canvas);
        let sidebar = theme.scale(SIDEBAR_WIDTH);
        theme.fill(dc, &RECT { right: sidebar, bottom: client.bottom, ..Default::default() }, Surface::Sidebar);
        theme.fill(dc, &RECT { left: sidebar - 1, right: sidebar, bottom: client.bottom, ..Default::default() }, Surface::Hairline);
        let footer = client.bottom - theme.scale(40);
        theme.fill(dc, &RECT { left: theme.scale(18), top: footer, right: sidebar - theme.scale(18), bottom: footer + 1 }, Surface::Hairline);
        let (left, width) = Self::page_geometry(&theme, client.right);
        let page = self.page.get();
        if page != Page::Devices || self.device_count.get() == 0 {
            for &(top, bottom) in page.cards() {
                theme.card(dc, &RECT { left, top: theme.scale(top), right: left + width, bottom: theme.scale(bottom) });
            }
        }
        if page.is_sharing() || page.is_settings() {
            let top = theme.scale(53);
            theme.fill(dc, &RECT { left, top, right: left + width, bottom: top + 1 }, Surface::Hairline);
        }
        unsafe {
            let _ = EndPaint(self.window, &paint);
        }
    }

    pub(super) fn control_colors(&self, dc: HDC, window: HWND) -> LRESULT {
        let (surface, tone) = match self.controls.iter().find(|control| control.window == window).map(|control| control.kind) {
            Some(Kind::Label(_, surface, tone)) => (surface, tone),
            Some(Kind::List) => (Surface::Sidebar, TextTone::Ink),
            Some(Kind::Edit { read_only: true, .. }) => (Surface::Inset, TextTone::Ink),
            _ => (Surface::Card, TextTone::Ink),
        };
        LRESULT(self.theme.borrow().control_colors(dc, surface, tone).0 as isize)
    }

    pub(super) fn draw_item(&self, item: &DRAWITEMSTRUCT) -> bool {
        if item.CtlType == ODT_LISTBOX && item.CtlID as usize == RECENT {
            let label = if item.itemID == u32::MAX {
                String::new()
            } else {
                let index = WPARAM(item.itemID as usize);
                let length = unsafe { SendMessageW(item.hwndItem, LB_GETTEXTLEN, Some(index), None) }.0;
                if length < 0 {
                    return false;
                }
                let mut buffer = vec![0; length as usize + 1];
                unsafe { SendMessageW(item.hwndItem, LB_GETTEXT, Some(index), Some(LPARAM(buffer.as_mut_ptr() as isize))) };
                from_wide(&buffer[..length as usize])
            };
            self.theme.borrow().draw_device(item, &label);
            return true;
        }

        let page = self.page.get();
        let nav = |selected, icon| ButtonKind::Navigation { selected, icon };
        let button = match item.CtlID as usize {
            NEW_CONNECTION => nav(false, Some(NavigationIcon::Add)),
            NAV_DEVICES => nav(page == Page::Devices, Some(NavigationIcon::Devices)),
            NAV_SHARING => nav(page.is_sharing(), Some(NavigationIcon::Sharing)),
            NAV_SETTINGS => nav(page.is_settings(), Some(NavigationIcon::Settings)),
            TAB_SHARING => ButtonKind::Tab { selected: page == Page::Sharing },
            TAB_HOST_QUALITY => ButtonKind::Tab { selected: page == Page::HostQuality },
            TAB_KEYBOARD => ButtonKind::Tab { selected: page == Page::Keyboard },
            TAB_DEFAULTS => ButtonKind::Tab { selected: page == Page::Defaults },
            TAB_UPDATES => ButtonKind::Tab { selected: page == Page::Updates },
            TAB_TAILSCALE => ButtonKind::Tab { selected: page == Page::Tailscale },
            CONNECT | SHARE | UPDATE_ACTION | TAILSCALE_LOGIN => ButtonKind::Primary,
            NEW_CONNECTION_PAGE => ButtonKind::CanvasAction,
            CONTINUE_CONNECTION => ButtonKind::Tab { selected: true },
            FORGET => ButtonKind::Danger,
            COPY_CODE | NEW_CODE | UPDATE_NOTES | TAILSCALE_LOGOUT => ButtonKind::Secondary,
            _ => return false,
        };
        self.theme.borrow().draw_button(item, button);
        true
    }
}
