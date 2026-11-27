//! Native controls and layout for the QuietDesk workspace.

use super::device_table;
use super::util::{from_wide, wide};
use super::workspace_style::{ButtonKind, FontRole, NavigationIcon, Surface, TextTone, Theme};
use std::cell::{Cell, RefCell};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::{BeginPaint, EndPaint, HDC, InvalidateRect, PAINTSTRUCT, RDW_ALLCHILDREN, RDW_INVALIDATE, RedrawWindow};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::SystemServices::{SS_CENTER, SS_ENDELLIPSIS, SS_NOPREFIX};
use windows::Win32::UI::Controls::{
    DRAWITEMSTRUCT, EM_SETCUEBANNER, EM_SETMARGINS, ICC_LISTVIEW_CLASSES, INITCOMMONCONTROLSEX, InitCommonControlsEx, LVS_REPORT, LVS_SHOWSELALWAYS,
    LVS_SINGLESEL, ODT_LISTBOX, WC_LISTVIEWW,
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
const SIDEBAR_WIDTH: i32 = 176;
const PAGE_MARGIN: i32 = 22;
const INSPECTOR_WIDTH: i32 = 244;
const FORM_RAIL_WIDTH: i32 = 158;
const COLUMN_GAP: i32 = 13;

pub(super) const NAV_NETWORK: usize = 1315;
pub(super) const TAB_BACKGROUND: usize = 1316;
pub(super) const TAB_PRIVACY: usize = 1317;
pub(super) const SEARCH_DEVICES: usize = 1318;
pub(super) const RECENT_SCOPE: usize = 1319;
pub(super) const ALL_SCOPE: usize = 1320;
pub(super) const DEVICES_COUNT: usize = 1321;
pub(super) const OPEN_DEVICE: usize = 1322;
pub(super) const DETAIL_HEADING: usize = 1323;
pub(super) const DETAIL_ENDPOINT: usize = 1324;
pub(super) const DETAIL_INSPECTOR_ENDPOINT: usize = 1347;
pub(super) const DETAIL_ROUTE: usize = 1325;
pub(super) const DETAIL_QUALITY: usize = 1326;
pub(super) const DETAIL_CREDENTIAL: usize = 1327;
pub(super) const DETAIL_CONNECT: usize = 1328;
pub(super) const DETAIL_OPTIONS: usize = 1329;
pub(super) const DETAIL_DISPLAY: usize = 1330;
pub(super) const DETAIL_TRANSPORT: usize = 1331;
pub(super) const DETAIL_SETTINGS: usize = 1332;
pub(super) const DETAIL_OPTIONS_VALUE: usize = 1333;
pub(super) const DETAIL_EDIT: usize = 1334;
pub(super) const DETAIL_MENU: usize = 1335;
pub(super) const PREVIEW_CAPTION: usize = 1336;
pub(super) const DIRECT_MODE: usize = 1337;
pub(super) const TAILNET_MODE: usize = 1338;
pub(super) const CANCEL_CONNECTION: usize = 1339;
pub(super) const NEW_OPTIONS: usize = 1340;
pub(super) const ENDPOINT_LABEL: usize = 1341;
pub(super) const HOST_SHOW_CODE: usize = 1342;
pub(super) const HOST_CODE_INFO: usize = 1343;
pub(super) const PRIVACY_SHARING: usize = 1344;
pub(super) const ABOUT: usize = 1345;
pub(super) const BREADCRUMB: usize = 1346;
pub(super) const MANAGE_RECORDS: usize = 1348;
pub(super) const FINISH_MANAGING: usize = 1349;
pub(super) const DRAFT_DISPLAY: usize = 1350;
pub(super) const DRAFT_TRANSPORT: usize = 1351;
pub(super) const DRAFT_QUALITY: usize = 1352;
pub(super) const DRAFT_RECONNECT: usize = 1353;
pub(super) const RETURN_CONNECTION: usize = 1354;
pub(super) const DETAIL_READY: usize = 1355;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum DetailOptions {
    Overview,
    Display,
    Transport,
}

pub(super) fn window_frame(dpi: u32, width: i32, height: i32) -> RECT {
    let mut rect = RECT { right: width * dpi as i32 / 96, bottom: height * dpi as i32 / 96, ..Default::default() };
    let _ = unsafe { AdjustWindowRectExForDpi(&mut rect, FRAME_STYLE, false, WINDOW_EX_STYLE(0), dpi) };
    rect
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Page {
    Devices,
    ManageRecords,
    Detail,
    Connection,
    DraftDisplay,
    DraftTransport,
    Sharing,
    HostQuality,
    Background,
    Keyboard,
    Defaults,
    Privacy,
    Updates,
    Tailscale,
}

impl Page {
    fn is_sharing(self) -> bool {
        matches!(self, Self::Sharing | Self::HostQuality | Self::Background)
    }

    fn is_settings(self) -> bool {
        matches!(self, Self::Keyboard | Self::Defaults | Self::Privacy | Self::Updates)
    }

    fn crumb(self) -> &'static str {
        match self {
            Self::Devices => "设备记录  /  全部设备",
            Self::ManageRecords => "设备记录  /  管理记录",
            Self::Detail => "设备记录  /  设备详情",
            Self::Connection => "设备记录  /  连接设置",
            Self::DraftDisplay | Self::DraftTransport => "设备记录  /  连接选项",
            Self::Sharing => "本机共享",
            Self::HostQuality => "本机共享  /  默认画质",
            Self::Background => "本机共享  /  后台与传输",
            Self::Keyboard => "设置  /  键盘与快捷键",
            Self::Defaults => "设置  /  连接默认项",
            Self::Privacy => "设置  /  隐私偏好",
            Self::Updates => "设置  /  软件更新",
            Self::Tailscale => "网络与线路  /  Tailscale",
        }
    }
}

#[derive(Clone, Copy)]
enum Area {
    Sidebar,
    Header,
    SharingTabs,
    NetworkTabs,
    SettingsTabs,
    DeviceList,
    DraftOptions,
    Page(Page),
    Left(Page),
    Right(Page),
    Overview,
    Options,
}

impl Area {
    fn shows(self, page: Page, options: DetailOptions) -> bool {
        match self {
            Self::Sidebar | Self::Header => true,
            Self::SharingTabs => page.is_sharing(),
            Self::NetworkTabs => page == Page::Tailscale,
            Self::SettingsTabs => page.is_settings(),
            Self::DeviceList => matches!(page, Page::Devices | Page::ManageRecords),
            Self::DraftOptions => matches!(page, Page::DraftDisplay | Page::DraftTransport),
            Self::Page(only) | Self::Left(only) | Self::Right(only) => page == only,
            Self::Overview => page == Page::Detail && options == DetailOptions::Overview,
            Self::Options => page == Page::Detail && options != DetailOptions::Overview,
        }
    }
}

#[derive(Clone, Copy)]
enum Kind {
    Label(FontRole, Surface, TextTone),
    CenterLabel(FontRole, Surface, TextTone),
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
            Self::Label(font, ..) | Self::CenterLabel(font, ..) => font,
            Self::Edit { code: true, .. } => FontRole::Code,
            _ => FontRole::Body,
        }
    }

    fn native(self) -> (PCWSTR, WINDOW_STYLE, WINDOW_EX_STYLE) {
        let edge = WS_EX_CLIENTEDGE;
        let tab = WS_TABSTOP.0;
        let (class, style, extended) = match self {
            Self::Label(..) => (w!("STATIC"), SS_NOPREFIX.0 | SS_ENDELLIPSIS.0, WINDOW_EX_STYLE(0)),
            Self::CenterLabel(..) => (w!("STATIC"), SS_NOPREFIX.0 | SS_CENTER.0, WINDOW_EX_STYLE(0)),
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
    record_count: Cell<usize>,
    draft_available: Cell<bool>,
    options: Cell<DetailOptions>,
    all_records: Cell<bool>,
    tailscale_mode: Cell<bool>,
    sharing_active: Cell<bool>,
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
        let value = Label(FontRole::Body, Surface::Card, TextTone::Ink);
        let small = Label(FontRole::Small, Surface::Card, TextTone::Muted);
        let code_label = Label(FontRole::Code, Surface::Card, TextTone::Ink);
        let sidebar_title = Label(FontRole::Emphasis, Surface::Sidebar, TextTone::Ink);
        let sidebar_hint = Label(FontRole::Small, Surface::Sidebar, TextTone::Muted);
        let entry = Edit { numeric: false, read_only: false, code: false };
        let port_entry = Edit { numeric: true, read_only: false, code: false };
        let code_entry = Edit { numeric: false, read_only: false, code: true };
        let readonly = Edit { numeric: false, read_only: true, code: false };
        let host_code = Edit { numeric: false, read_only: true, code: true };
        let port = port.to_string();

        add(
            Area::Sidebar,
            &[
                (sidebar_title, 0, "QuietDesk", 46, 17, -12, 27),
                (Button, NEW_CONNECTION, "新建连接", 12, 56, -12, 34),
                (Button, NAV_DEVICES, "全部设备", 8, 109, -8, 33),
                (Button, NAV_SHARING, "本机共享", 8, 145, -8, 33),
                (Button, NAV_NETWORK, "网络与线路", 8, 181, -8, 33),
                (Button, NAV_SETTINGS, "设置", 8, 217, -8, 33),
                (sidebar_hint, 0, "最近设备", 16, 275, -12, 20),
                (sidebar_hint, EMPTY_RECENT, "暂无已保存的设备", 16, 311, -12, 22),
                (List, RECENT, "", 8, 301, -8, 104),
                (sidebar_hint, SHARING_SUMMARY, "共享未开启", 28, -28, -12, 20),
            ],
        )?;
        add(
            Area::Header,
            &[(Label(FontRole::Small, Surface::Card, TextTone::Muted), BREADCRUMB, Devices.crumb(), 0, 10, -39, 20), (Button, ABOUT, "关于", -36, 4, 36, 26)],
        )?;
        add(
            Area::Page(Devices),
            &[
                (title, 0, "全部设备", 0, 54, -225, 36),
                (subtitle, DEVICES_COUNT, "暂无本机连接记录", 0, 95, 0, 22),
                (Button, CONTINUE_CONNECTION, "继续编辑", -218, 59, 101, 32),
                (Button, NEW_CONNECTION_PAGE, "新建连接", -109, 59, 109, 32),
                (entry, SEARCH_DEVICES, "", 0, 128, -169, 32),
                (Button, RECENT_SCOPE, "最近设备", -161, 128, 78, 32),
                (Button, ALL_SCOPE, "全部记录", -79, 128, 79, 32),
                (Button, MANAGE_RECORDS, "管理记录", 0, -56, 91, 31),
            ],
        )?;
        add(
            Area::DeviceList,
            &[
                (label, EMPTY_DEVICES, "暂无匹配的连接记录", 16, 203, -16, 24),
                (Table, DEVICE_TABLE, "", 0, 175, 0, -69),
                (Button, OPEN_DEVICE, "打开选中设备", -126, -56, 126, 31),
            ],
        )?;
        add(
            Area::Page(ManageRecords),
            &[
                (title, 0, "管理连接记录", 0, 54, -110, 36),
                (subtitle, 0, "移除记录时会同时清除本机保存的配对码。", 0, 96, 0, 22),
                (Button, FINISH_MANAGING, "完成", -80, 59, 80, 32),
                (Button, FORGET, "移除选中记录…", 0, -56, 130, 31),
            ],
        )?;
        add(
            Area::Page(Detail),
            &[
                (title, DETAIL_HEADING, "设备详情", 0, 55, -159, 35),
                (subtitle, DETAIL_ENDPOINT, "", 0, 94, 0, 21),
                (Button, DETAIL_CONNECT, "连接设备", -143, 61, 101, 34),
                (Button, DETAIL_MENU, "…", -35, 61, 35, 34),
            ],
        )?;
        add(
            Area::Left(Detail),
            &[
                (section, 0, "远程桌面", 14, 148, -14, 24),
                (CenterLabel(FontRole::Body, Surface::Preview, TextTone::Secondary), PREVIEW_CAPTION, "连接后在会话窗口显示远程桌面", 18, 0, -18, 24),
                (Button, DETAIL_EDIT, "编辑连接", 13, -67, 104, 30),
                (Button, DETAIL_OPTIONS, "连接选项", -117, -67, 103, 30),
            ],
        )?;
        add(
            Area::Overview,
            &[
                (section, 0, "连接概况", 14, 148, -14, 25),
                (small, 0, "连接方式", 14, 188, -14, 19),
                (value, DETAIL_ROUTE, "", 14, 209, -14, 22),
                (small, 0, "连接端点", 14, 246, -14, 19),
                (code_label, DETAIL_INSPECTOR_ENDPOINT, "", 14, 267, -14, 22),
                (small, 0, "请求画质", 14, 304, -14, 19),
                (value, DETAIL_QUALITY, "", 14, 325, -14, 22),
                (small, 0, "配对记录", 14, 362, -14, 19),
                (value, DETAIL_CREDENTIAL, "", 14, 383, -14, 22),
                (Button, DETAIL_READY, "就绪状态", 14, -66, -14, 30),
            ],
        )?;
        add(
            Area::Options,
            &[
                (section, 0, "连接选项", 14, 148, -14, 25),
                (small, 0, "在相关设置中更改连接默认项", 14, 179, -14, 21),
                (Button, DETAIL_DISPLAY, "显示与输入", 10, 210, 103, 31),
                (Button, DETAIL_TRANSPORT, "传输", 117, 210, -10, 31),
                (value, DETAIL_OPTIONS_VALUE, "", 14, 270, -14, 25),
                (Button, DETAIL_SETTINGS, "打开连接默认项", 14, 319, -14, 30),
            ],
        )?;
        add(
            Area::Page(Connection),
            &[
                (title, DEVICE_HEADING, "新建连接", 0, 54, 0, 36),
                (subtitle, DEVICE_DETAIL, "先选连接方式，再填写被控端的连接信息。", 0, 94, 0, 22),
                (Button, NEW_OPTIONS, "连接选项", 14, -67, 104, 31),
                (Button, CANCEL_CONNECTION, "取消", -170, -67, 57, 31),
                (Button, CONNECT, "连接", -104, -67, 89, 31),
            ],
        )?;
        add(
            Area::Left(Connection),
            &[
                (section, 0, "连接方式", 14, 145, -14, 24),
                (Button, DIRECT_MODE, "地址直连", 10, 182, -10, 37),
                (Button, TAILNET_MODE, "Tailscale", 10, 227, -10, 37),
            ],
        )?;
        add(
            Area::Right(Connection),
            &[
                (section, 0, "连接信息", 14, 145, -14, 25),
                (label, ENDPOINT_LABEL, "地址", 14, 192, -112, 20),
                (entry, ADDRESS, "", 14, 217, -112, 31),
                (label, 0, "端口", -96, 192, 80, 20),
                (port_entry, PORT, &port, -96, 217, 80, 31),
                (label, 0, "配对码", 14, 272, -14, 20),
                (code_entry, CODE, "", 14, 296, -14, 31),
            ],
        )?;
        add(
            Area::DraftOptions,
            &[
                (title, 0, "连接选项", 0, 54, 0, 36),
                (subtitle, 0, "连接默认项适用于此电脑发起的连接。", 0, 96, 0, 22),
                (Button, DRAFT_DISPLAY, "显示与输入", 0, 129, 103, 31),
                (Button, DRAFT_TRANSPORT, "传输", 112, 129, 88, 31),
                (Button, RETURN_CONNECTION, "返回连接", -107, -60, 107, 32),
            ],
        )?;
        add(
            Area::Page(DraftDisplay),
            &[
                (section, 0, "画质与输入设置", 14, 191, -14, 24),
                (label, 0, "默认请求画质", 14, 232, -14, 21),
                (Combo, DRAFT_QUALITY, "", 14, 258, -14, 240),
                (small, 0, "修饰键映射可在设置的键盘与快捷键页面调整。", 14, 313, -14, 23),
            ],
        )?;
        add(Area::Page(DraftTransport), &[(section, 0, "远程连接", 14, 191, -14, 24), (Check, DRAFT_RECONNECT, "断线后自动重连", 14, 232, -14, 27)])?;
        add(
            Area::SharingTabs,
            &[
                (Button, TAB_SHARING, "本机共享", 0, 40, 102, 33),
                (Button, TAB_HOST_QUALITY, "默认画质", 105, 40, 102, 33),
                (Button, TAB_BACKGROUND, "后台与传输", 210, 40, 110, 33),
            ],
        )?;
        add(
            Area::Page(Sharing),
            &[
                (title, 0, "本机共享", 0, 88, 0, 36),
                (subtitle, 0, "管理这台电脑的共享端口、配对码和访问能力。", 0, 129, 0, 23),
                (label, HOST_STATUS, "未共享", 14, 175, -134, 24),
                (Button, SHARE, "开始共享", -116, 170, 101, 31),
            ],
        )?;
        add(
            Area::Left(Sharing),
            &[
                (section, 0, "连接信息", 14, 238, -14, 24),
                (label, 0, "监听端口", 14, 274, -14, 21),
                (port_entry, HOST_PORT, &port, 14, 298, 86, 29),
                (label, 0, "本机配对码", 14, 343, -14, 21),
                (host_code, HOST_CODE, "", 14, 367, -70, 29),
                (Button, HOST_SHOW_CODE, "显示", -62, 367, 48, 29),
                (Button, HOST_CODE_INFO, "安全说明", 14, 408, 72, 29),
            ],
        )?;
        add(
            Area::Right(Sharing),
            &[
                (section, 0, "访问与权限", 14, 238, -14, 24),
                (Check, ALLOW_CONTROL, "允许控制端操作键盘和鼠标", 14, 276, -14, 27),
                (small, 0, "关闭后，已连接的控制端仍可查看画面。", 15, 311, -14, 23),
                (Button, COPY_CODE, "复制配对码", 14, 367, 95, 29),
                (Button, NEW_CODE, "重新生成", 116, 367, 83, 29),
            ],
        )?;
        add(Area::Page(HostQuality), &[(title, 0, "默认画质", 0, 88, 0, 36), (subtitle, 0, "设置共享显示器与本机编码上限。", 0, 129, 0, 23)])?;
        add(
            Area::Left(HostQuality),
            &[(section, 0, "共享显示器", 14, 177, -14, 23), (label, 0, "选择要共享的屏幕", 14, 216, -14, 22), (Combo, SHARED_DISPLAY, "", 14, 242, -14, 240)],
        )?;
        add(
            Area::Right(HostQuality),
            &[(section, 0, "编码上限", 14, 177, -14, 23), (label, 0, "共享画质", 14, 216, -14, 22), (Combo, QUALITY_LIMIT, "", 14, 242, -14, 240)],
        )?;
        add(
            Area::Page(Background),
            &[
                (title, 0, "后台与传输", 0, 88, 0, 36),
                (subtitle, 0, "管理共享期间的剪贴板与文件接收。", 0, 129, 0, 23),
                (section, 0, "剪贴板与文件接收", 14, 177, -14, 24),
                (Check, ALLOW_CLIPBOARD, "允许同步剪贴板文字、图片和文件", 14, 217, -14, 27),
            ],
        )?;
        add(Area::NetworkTabs, &[(Button, TAB_TAILSCALE, "Tailscale", 0, 40, 101, 33)])?;
        add(
            Area::SettingsTabs,
            &[
                (Button, TAB_KEYBOARD, "键盘与快捷键", 0, 40, 119, 33),
                (Button, TAB_DEFAULTS, "连接默认项", 121, 40, 111, 33),
                (Button, TAB_PRIVACY, "隐私偏好", 234, 40, 100, 33),
                (Button, TAB_UPDATES, "软件更新", 336, 40, 99, 33),
            ],
        )?;
        add(
            Area::Page(Tailscale),
            &[
                (title, 0, "Tailscale", 0, 88, 0, 36),
                (subtitle, 0, "使用内置节点在同一 Tailscale 网络内建立连接。", 0, 129, 0, 23),
                (section, 0, "本机设备", 14, 177, -14, 24),
                (label, TAILSCALE_STATUS, "未启用", 14, 212, -14, 23),
                (small, 0, "QuietDesk 连接地址", 14, 250, -14, 20),
                (readonly, TAILSCALE_ADDRESS, "", 14, 273, -14, 33),
                (small, 0, "在控制端输入此地址、共享端口和配对码。", 14, 320, -14, 23),
                (Button, TAILSCALE_LOGIN, "登录 Tailscale", 14, 365, 135, 32),
                (Button, TAILSCALE_LOGOUT, "退出 Tailscale", 157, 365, 135, 32),
            ],
        )?;
        add(Area::Page(Keyboard), &[(title, 0, "键盘与快捷键", 0, 88, 0, 36), (subtitle, 0, "按本机在远程连接中的角色设置修饰键。", 0, 129, 0, 23)])?;
        add(
            Area::Left(Keyboard),
            &[(section, 0, "作为控制端", 14, 177, -14, 24), (label, 0, "发往 Mac 的修饰键", 14, 215, -14, 22), (Combo, PC_MODIFIERS, "", 14, 241, -14, 240)],
        )?;
        add(
            Area::Right(Keyboard),
            &[
                (section, 0, "被 Mac 控制时", 14, 177, -14, 24),
                (label, 0, "在 Windows 中使用的修饰键", 14, 215, -14, 22),
                (Combo, MAC_MODIFIERS, "", 14, 241, -14, 240),
            ],
        )?;
        add(Area::Page(Defaults), &[(title, 0, "连接默认项", 0, 88, 0, 36), (subtitle, 0, "管理发起连接时的画质请求和重连方式。", 0, 129, 0, 23)])?;
        add(
            Area::Left(Defaults),
            &[(section, 0, "显示", 14, 177, -14, 24), (label, 0, "默认画质", 14, 215, -14, 22), (Combo, VIEWER_QUALITY, "", 14, 241, -14, 240)],
        )?;
        add(Area::Right(Defaults), &[(section, 0, "传输", 14, 177, -14, 24), (Check, AUTO_RECONNECT, "断线后自动重连", 14, 222, -14, 27)])?;
        add(
            Area::Page(Privacy),
            &[
                (title, 0, "隐私偏好", 0, 88, 0, 36),
                (subtitle, 0, "了解配对码存储方式和本机共享的访问设置。", 0, 129, 0, 23),
                (section, 0, "本机凭据", 14, 177, -14, 24),
                (value, 0, "配对码由当前 Windows 账户加密保护。", 14, 216, -14, 23),
                (Button, PRIVACY_SHARING, "打开本机共享", 14, 263, 123, 31),
            ],
        )?;
        add(
            Area::Page(Updates),
            &[
                (title, 0, "软件更新", 0, 88, 0, 36),
                (subtitle, 0, "查看已安装版本、更新状态和安装策略。", 0, 129, 0, 23),
                (section, 0, concat!("QuietDesk ", env!("QUIETDESK_VERSION")), 14, 177, -223, 24),
                (Button, UPDATE_NOTES, "更新说明", -219, 173, 86, 33),
                (Button, UPDATE_ACTION, "检查更新", -125, 173, 111, 33),
                (label, UPDATE_STATUS, update_status, 14, 219, -14, 24),
                (section, 0, "更新策略", 14, 278, -14, 24),
                (Check, AUTO_CHECK_UPDATES, "自动检查更新（每天一次）", 14, 314, -14, 26),
                (Check, AUTO_INSTALL_UPDATES, "非远程控制空闲时自动下载并安装", 14, 354, -14, 26),
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
            record_count: Cell::new(0),
            draft_available: Cell::new(false),
            options: Cell::new(DetailOptions::Overview),
            all_records: Cell::new(false),
            tailscale_mode: Cell::new(false),
            sharing_active: Cell::new(false),
            controls,
        };
        workspace.update_fonts();
        workspace.set_label(BREADCRUMB, Connection.crumb());
        if let Ok(search) = unsafe { GetDlgItem(Some(window), SEARCH_DEVICES as i32) } {
            unsafe { SendMessageW(search, EM_SETCUEBANNER, Some(WPARAM(1)), Some(LPARAM(w!("搜索设备名、地址或设备 ID").as_ptr() as isize))) };
        }
        workspace.layout();
        Ok(workspace)
    }

    pub(super) fn navigate(&self, id: usize) {
        let page = match id {
            NAV_DEVICES => Page::Devices,
            NAV_SHARING => self.sharing_page.get(),
            NAV_SETTINGS => self.settings_page.get(),
            NAV_NETWORK => Page::Tailscale,
            TAB_SHARING => Page::Sharing,
            TAB_HOST_QUALITY => Page::HostQuality,
            TAB_BACKGROUND => Page::Background,
            TAB_KEYBOARD => Page::Keyboard,
            TAB_DEFAULTS => Page::Defaults,
            TAB_PRIVACY => Page::Privacy,
            TAB_UPDATES => Page::Updates,
            TAB_TAILSCALE => Page::Tailscale,
            _ => return,
        };
        self.select(page);
    }

    fn set_label(&self, id: usize, label: &str) {
        if let Ok(control) = unsafe { GetDlgItem(Some(self.window), id as i32) } {
            let _ = unsafe { SetWindowTextW(control, PCWSTR(wide(label).as_ptr())) };
        }
    }

    pub(super) fn page(&self) -> Page {
        self.page.get()
    }

    pub(super) fn detail_options(&self) -> DetailOptions {
        self.options.get()
    }

    pub(super) fn set_detail_options(&self, options: DetailOptions) {
        if self.options.replace(options) != options {
            let focus = unsafe { GetFocus() };
            if self.controls.iter().any(|control| control.window == focus && !control.area.shows(self.page.get(), options))
                && let Ok(control) = unsafe { GetDlgItem(Some(self.window), DETAIL_OPTIONS as i32) }
            {
                let _ = unsafe { SetFocus(Some(control)) };
            }
            self.layout();
            self.refresh_buttons();
        }
    }

    pub(super) fn all_records(&self) -> bool {
        self.all_records.get()
    }

    pub(super) fn set_all_records(&self, all: bool) {
        if self.all_records.replace(all) != all {
            self.refresh_buttons();
        }
    }

    pub(super) fn tailscale_mode(&self) -> bool {
        self.tailscale_mode.get()
    }

    pub(super) fn set_tailscale_mode(&self, tailscale: bool) {
        self.set_label(ENDPOINT_LABEL, if tailscale { "Tailscale 地址" } else { "地址" });
        if self.tailscale_mode.replace(tailscale) != tailscale {
            self.refresh_buttons();
        }
    }

    pub(super) fn set_sharing_active(&self, active: bool) {
        if self.sharing_active.replace(active) != active {
            self.refresh_buttons();
            let _ = unsafe { InvalidateRect(Some(self.window), None, false) };
        }
    }

    fn refresh_buttons(&self) {
        for control in self.controls.iter().filter(|control| matches!(control.kind, Kind::Button)) {
            let _ = unsafe { InvalidateRect(Some(control.window), None, false) };
        }
    }

    pub(super) fn select(&self, page: Page) {
        if self.page.replace(page) == page {
            return;
        }
        let focus = unsafe { GetFocus() };
        let move_focus = self.controls.iter().any(|control| control.window == focus && !control.area.shows(page, self.options.get()));
        if page.is_settings() {
            self.settings_page.set(page);
        } else if page.is_sharing() {
            self.sharing_page.set(page);
        }
        self.set_label(BREADCRUMB, page.crumb());
        self.layout();
        if move_focus {
            let nav = if matches!(page, Page::Devices | Page::ManageRecords | Page::Detail | Page::Connection | Page::DraftDisplay | Page::DraftTransport) {
                NAV_DEVICES
            } else if page == Page::Tailscale {
                NAV_NETWORK
            } else if page.is_settings() {
                NAV_SETTINGS
            } else {
                NAV_SHARING
            };
            if let Ok(button) = unsafe { GetDlgItem(Some(self.window), nav as i32) } {
                let _ = unsafe { SetFocus(Some(button)) };
            }
        }
        self.refresh_buttons();
    }

    pub(super) fn set_draft_available(&self, available: bool) {
        if self.draft_available.replace(available) != available && self.page.get() == Page::Devices {
            self.layout();
        }
    }

    pub(super) fn show_devices(&self, visible: usize, total: usize) {
        let previous_total = self.record_count.replace(total);
        if self.device_count.replace(visible) != visible || previous_total != total {
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
        let frame = window_frame(self.dpi.get(), 760, 492);
        info.ptMinTrackSize = POINT { x: frame.right - frame.left, y: frame.bottom - frame.top };
    }

    fn client_rect(&self) -> RECT {
        let mut rect = RECT::default();
        let _ = unsafe { GetClientRect(self.window, &mut rect) };
        rect
    }

    fn page_geometry(theme: &Theme, client_width: i32) -> (i32, i32) {
        let left = theme.scale(SIDEBAR_WIDTH + PAGE_MARGIN);
        (left, (client_width - left - theme.scale(PAGE_MARGIN)).max(0))
    }

    fn columns(theme: &Theme, width: i32, page: Page) -> (i32, i32) {
        let gap = theme.scale(COLUMN_GAP);
        let left = match page {
            Page::Connection => theme.scale(FORM_RAIL_WIDTH),
            Page::Detail => width - gap - theme.scale(INSPECTOR_WIDTH),
            _ => (width - gap) / 2,
        }
        .max(0);
        (left, (width - left - gap).max(0))
    }

    fn area_geometry(area: Area, theme: &Theme, client_width: i32) -> (i32, i32) {
        let (left, width) = Self::page_geometry(theme, client_width);
        match area {
            Area::Sidebar => (0, theme.scale(SIDEBAR_WIDTH)),
            Area::Left(page) => (left, Self::columns(theme, width, page).0),
            Area::Right(page) => {
                let (first, second) = Self::columns(theme, width, page);
                (left + first + theme.scale(COLUMN_GAP), second)
            }
            Area::Overview | Area::Options => {
                let (first, second) = Self::columns(theme, width, Page::Detail);
                (left + first + theme.scale(COLUMN_GAP), second)
            }
            _ => (left, width),
        }
    }

    fn preview_rect(theme: &Theme, client: RECT) -> RECT {
        let (left, width) = Self::area_geometry(Area::Left(Page::Detail), theme, client.right);
        let margin = theme.scale(12);
        RECT { left: left + margin, top: theme.scale(180), right: left + width - margin, bottom: client.bottom - theme.scale(86) }
    }

    pub(super) fn layout(&self) {
        let client = self.client_rect();
        let page = self.page.get();
        for control in &self.controls {
            let visible = control.area.shows(page, self.options.get())
                && match control.id {
                    RECENT => self.record_count.get() != 0,
                    DEVICE_TABLE | OPEN_DEVICE => self.device_count.get() != 0,
                    EMPTY_RECENT => self.record_count.get() == 0,
                    EMPTY_DEVICES => self.device_count.get() == 0,
                    CONTINUE_CONNECTION => self.draft_available.get(),
                    _ => true,
                };
            if !visible {
                let _ = unsafe { ShowWindow(control.window, SW_HIDE) };
                continue;
            }
            let (x, y, width, height) = {
                let theme = self.theme.borrow();
                let (left, extent) = Self::area_geometry(control.area, &theme, client.right);
                let (x, y, width, height) = control.bounds;
                let x = if x < 0 { extent + theme.scale(x) } else { theme.scale(x) };
                let y = if control.id == PREVIEW_CAPTION {
                    let preview = Self::preview_rect(&theme, client);
                    (preview.top + preview.bottom) / 2 + theme.scale(48)
                } else if y < 0 {
                    client.bottom + theme.scale(y)
                } else {
                    theme.scale(y)
                };
                let width = if width <= 0 { extent + theme.scale(width) - x } else { theme.scale(width) };
                let height = if height <= 0 { client.bottom + theme.scale(height) - y } else { theme.scale(height) };
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
        theme.app_mark(dc, theme.scale(15), theme.scale(17));
        theme.sharing_indicator(dc, theme.scale(15), client.bottom - theme.scale(24), self.sharing_active.get());
        for line in [theme.scale(261), client.bottom - theme.scale(43)] {
            theme.fill(dc, &RECT { left: theme.scale(13), top: line, right: sidebar - theme.scale(13), bottom: line + 1 }, Surface::Hairline);
        }
        let (left, width) = Self::page_geometry(&theme, client.right);
        let page = self.page.get();
        let header = theme.scale(34);
        theme.fill(dc, &RECT { left: sidebar, right: client.right, bottom: header, ..Default::default() }, Surface::Card);
        theme.fill(dc, &RECT { left: sidebar, top: header, right: client.right, bottom: header + 1 }, Surface::Hairline);
        if page.is_sharing() || page.is_settings() || page == Page::Tailscale {
            let top = theme.scale(73);
            theme.fill(dc, &RECT { left, top, right: left + width, bottom: top + 1 }, Surface::Hairline);
        }
        let box_at = |area, top, bottom| {
            let (left, width) = Self::area_geometry(area, &theme, client.right);
            theme.card(dc, &RECT { left, top, right: left + width, bottom });
        };
        let full = |top, bottom| box_at(Area::Page(page), theme.scale(top), theme.scale(bottom));
        let columns = |top, bottom| {
            for area in [Area::Left(page), Area::Right(page)] {
                box_at(area, theme.scale(top), theme.scale(bottom));
            }
        };
        match page {
            Page::Devices | Page::ManageRecords if self.device_count.get() == 0 => full(175, 248),
            Page::Devices | Page::ManageRecords => {}
            Page::Detail => {
                for area in [Area::Left(page), Area::Right(page)] {
                    box_at(area, theme.scale(132), client.bottom - theme.scale(25));
                }
                theme.device_preview(dc, &Self::preview_rect(&theme, client));
                let (left, width) = Self::area_geometry(Area::Right(page), &theme, client.right);
                for y in [180, 238, 296, 354] {
                    if self.options.get() == DetailOptions::Overview {
                        let top = theme.scale(y);
                        let margin = theme.scale(14);
                        theme.fill(dc, &RECT { left: left + margin, top, right: left + width - margin, bottom: top + 1 }, Surface::Hairline);
                    }
                }
            }
            Page::Connection => {
                for area in [Area::Left(page), Area::Right(page)] {
                    box_at(area, theme.scale(128), client.bottom - theme.scale(85));
                }
                box_at(Area::Page(page), client.bottom - theme.scale(79), client.bottom - theme.scale(23));
            }
            Page::DraftDisplay | Page::DraftTransport => full(175, 349),
            Page::Sharing => {
                full(156, 218);
                columns(223, 449);
            }
            Page::HostQuality | Page::Keyboard | Page::Defaults => columns(160, 305),
            Page::Background => full(160, 263),
            Page::Privacy => full(160, 313),
            Page::Updates => {
                full(160, 252);
                full(261, 397);
            }
            Page::Tailscale => full(160, 415),
        }
        unsafe {
            let _ = EndPaint(self.window, &paint);
        }
    }

    pub(super) fn control_colors(&self, dc: HDC, window: HWND) -> LRESULT {
        let (surface, tone) = match self.controls.iter().find(|control| control.window == window).map(|control| control.kind) {
            Some(Kind::Label(_, surface, tone) | Kind::CenterLabel(_, surface, tone)) => (surface, tone),
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
            NEW_CONNECTION => ButtonKind::SidebarAction,
            NAV_DEVICES => nav(matches!(page, Page::Devices | Page::ManageRecords), Some(NavigationIcon::Devices)),
            NAV_SHARING => nav(page.is_sharing(), Some(NavigationIcon::Sharing)),
            NAV_NETWORK => nav(page == Page::Tailscale, Some(NavigationIcon::Network)),
            NAV_SETTINGS => nav(page.is_settings(), Some(NavigationIcon::Settings)),
            DIRECT_MODE => nav(!self.tailscale_mode.get(), Some(NavigationIcon::Devices)),
            TAILNET_MODE => nav(self.tailscale_mode.get(), Some(NavigationIcon::Network)),
            RECENT_SCOPE => ButtonKind::Tab { selected: !self.all_records.get() },
            ALL_SCOPE => ButtonKind::Tab { selected: self.all_records.get() },
            DRAFT_DISPLAY => ButtonKind::Tab { selected: page == Page::DraftDisplay },
            DRAFT_TRANSPORT => ButtonKind::Tab { selected: page == Page::DraftTransport },
            DETAIL_READY => ButtonKind::Tool { selected: false, icon: Some(NavigationIcon::Ready) },
            DETAIL_DISPLAY => ButtonKind::Tab { selected: self.options.get() == DetailOptions::Display },
            DETAIL_TRANSPORT => ButtonKind::Tab { selected: self.options.get() == DetailOptions::Transport },
            DETAIL_OPTIONS => ButtonKind::Tool { selected: self.options.get() != DetailOptions::Overview, icon: Some(NavigationIcon::Options) },
            NEW_OPTIONS => ButtonKind::Tool { selected: false, icon: Some(NavigationIcon::Options) },
            TAB_SHARING => ButtonKind::Tab { selected: page == Page::Sharing },
            TAB_HOST_QUALITY => ButtonKind::Tab { selected: page == Page::HostQuality },
            TAB_BACKGROUND => ButtonKind::Tab { selected: page == Page::Background },
            TAB_KEYBOARD => ButtonKind::Tab { selected: page == Page::Keyboard },
            TAB_DEFAULTS => ButtonKind::Tab { selected: page == Page::Defaults },
            TAB_PRIVACY => ButtonKind::Tab { selected: page == Page::Privacy },
            TAB_UPDATES => ButtonKind::Tab { selected: page == Page::Updates },
            TAB_TAILSCALE => ButtonKind::Tab { selected: page == Page::Tailscale },
            CONNECT | DETAIL_CONNECT | NEW_CONNECTION_PAGE | UPDATE_ACTION | TAILSCALE_LOGIN | RETURN_CONNECTION | FINISH_MANAGING => ButtonKind::Primary,
            SHARE if self.sharing_active.get() => ButtonKind::Danger,
            SHARE => ButtonKind::Primary,
            FORGET => ButtonKind::Danger,
            COPY_CODE | NEW_CODE | UPDATE_NOTES | TAILSCALE_LOGOUT | CONTINUE_CONNECTION | HOST_SHOW_CODE | HOST_CODE_INFO | CANCEL_CONNECTION
            | DETAIL_EDIT | DETAIL_MENU | DETAIL_SETTINGS | OPEN_DEVICE | PRIVACY_SHARING | ABOUT | MANAGE_RECORDS => ButtonKind::Secondary,
            _ => return false,
        };
        self.theme.borrow().draw_button(item, button);
        true
    }
}
