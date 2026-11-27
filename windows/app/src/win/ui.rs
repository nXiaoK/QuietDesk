//! The workspace owns connection, sharing and update state for the main window.

use super::app::{HostActivity, HostNotice, computer_name, network_runtime, serve_host, start_logging};
use super::canvas::{self, WM_CANVAS_CLOSED, WM_CANVAS_CONNECTED, WM_CAPS_PREFERENCE};
use super::clipboard;
use super::settings::{Connection, QUALITY_LIMITS, Settings, VIEWER_QUALITIES, local_device_id, protect, unprotect};
use super::tailnet::{Panel as TailnetPanel, ViewerTarget};
use super::util::{display_label, from_wide, wide};
use super::workspace::*;
use super::{device_table, displays};
use quietdesk_core::display::RemoteDisplayInfo;
use quietdesk_core::host::{HostCommand, HostEvent, HostOptions};
use quietdesk_core::keymap::{MacModifierMapping, PcModifierMapping};
use quietdesk_core::messages::{DeviceIdentity, device_display_name};
use quietdesk_core::pairing::PairingKey;
use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};
use tokio::sync::watch;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::HDC;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{DRAWITEMSTRUCT, LVN_ITEMACTIVATE, NMHDR};
use windows::Win32::UI::HiDpi::{GetDpiForSystem, GetDpiForWindow};
use windows::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, GetActiveWindow, SetFocus, VK_RETURN};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

const WM_HOST_NOTICE: u32 = WM_APP + 10;
const WM_UPDATE_EVENT: u32 = WM_APP + 40;
const TIMER_UPDATE_TICK: usize = 1;
const TIMER_TAILNET_TICK: usize = 2;

struct Main {
    window: HWND,
    workspace: Rc<Workspace>,
    settings: Settings,
    local_identity: Option<DeviceIdentity>,
    viewer_name: Option<String>,
    session_status: String,
    displays: Vec<RemoteDisplayInfo>,
    active_display: Option<u32>,
    host_activity: Arc<HostActivity>,
    modal_prompt_open: AtomicBool,
    auto_reconnect: watch::Sender<bool>,
    runtime: tokio::runtime::Handle,
    /// Present while this PC is shared; closing it stops the listener and ends the session.
    sharing: Option<UnboundedSender<HostCommand>>,
    notices: Arc<Mutex<VecDeque<HostNotice>>>,
    /// Keep each window registered; consume its history entry on the first connection.
    viewers: Vec<(canvas::ViewerWindow, Option<Connection>)>,
    updater: super::update::WindowUpdater,
    tailnet: TailnetPanel,
}

impl Main {
    fn item(&self, id: usize) -> HWND {
        unsafe { GetDlgItem(Some(self.window), id as i32) }.unwrap_or_default()
    }

    fn text(&self, id: usize) -> String {
        let mut buffer = [0u16; 512];
        let length = unsafe { GetWindowTextW(self.item(id), &mut buffer) };
        from_wide(&buffer[..length.max(0) as usize]).trim().to_string()
    }

    fn set_text(&self, id: usize, text: &str) {
        let _ = unsafe { SetWindowTextW(self.item(id), PCWSTR(wide(text).as_ptr())) };
    }

    fn message(&self, id: usize, message: u32, wparam: usize, lparam: isize) -> isize {
        unsafe { SendMessageW(self.item(id), message, Some(WPARAM(wparam)), Some(LPARAM(lparam))) }.0
    }

    fn alert(&self, text: &str) {
        self.modal_prompt_open.store(true, Ordering::Release);
        unsafe { MessageBoxW(Some(self.window), PCWSTR(wide(text).as_ptr()), w!("QuietDesk"), MB_OK | MB_ICONWARNING) };
        self.modal_prompt_open.store(false, Ordering::Release);
    }

    fn refresh_update_controls(&self) {
        self.set_text(UPDATE_STATUS, &self.updater.status_text);
        self.set_text(UPDATE_ACTION, self.updater.action_button_label(self.host_activity.connected()));
        let enabled = self.updater.config.enabled();
        let can_click_action = enabled && self.updater.state != super::update::UpdaterState::Installing;
        unsafe {
            let _ = EnableWindow(self.item(UPDATE_ACTION), can_click_action);
            let _ = EnableWindow(self.item(AUTO_CHECK_UPDATES), enabled);
            let _ = EnableWindow(self.item(AUTO_INSTALL_UPDATES), enabled);
        }
        self.message(AUTO_CHECK_UPDATES, BM_SETCHECK, usize::from(self.settings.auto_check_updates), 0);
        self.message(AUTO_INSTALL_UPDATES, BM_SETCHECK, usize::from(self.settings.auto_install_updates), 0);
    }

    fn refresh_tailnet_controls(&self) {
        self.set_text(TAILSCALE_STATUS, self.tailnet.status_line());
        if self.text(TAILSCALE_ADDRESS) != self.tailnet.address() {
            self.set_text(TAILSCALE_ADDRESS, self.tailnet.address());
        }
        unsafe {
            let _ = EnableWindow(self.item(TAILSCALE_LOGIN), self.tailnet.can_login());
            let _ = EnableWindow(self.item(TAILSCALE_LOGOUT), self.tailnet.can_logout());
        }
    }

    fn window_is_minimized_or_hidden(&self) -> bool {
        unsafe { IsIconic(self.window).as_bool() || !IsWindowVisible(self.window).as_bool() }
    }

    fn finish_for_update_restart(&mut self) {
        self.tailnet.share(None);
        self.sharing = None;
        unsafe {
            let _ = KillTimer(Some(self.window), TIMER_UPDATE_TICK);
            let _ = PostMessageW(Some(self.window), WM_CLOSE, WPARAM(0), LPARAM(0));
        }
    }

    fn update_context(&self) -> super::update::WindowUpdateContext {
        super::update::WindowUpdateContext {
            has_host_connection: self.host_activity.connected(),
            viewer_count: self.viewers.len(),
            has_blocking_prompt: self.modal_prompt_open.load(Ordering::Acquire),
            is_sharing_enabled: self.sharing.is_some(),
            window_minimized_or_hidden: self.window_is_minimized_or_hidden(),
        }
    }

    fn trigger_manual_install(&mut self) {
        if self.host_activity.connected() {
            return self.alert("这台电脑正被远程控制。为避免远端失联，请先停止共享或等待会话结束后安装更新。");
        }
        if !self.viewers.is_empty() || !self.settings.auto_install_updates {
            let mut prompt = String::from("QuietDesk 将退出、安装更新并自动重新启动。");
            if !self.viewers.is_empty() {
                prompt.push_str("\n当前打开的远程控制窗口将会断开。");
            }
            if self.sharing.is_some() {
                prompt.push_str("\n重启后会自动恢复本机共享。");
            }
            self.modal_prompt_open.store(true, Ordering::Release);
            let choice =
                unsafe { MessageBoxW(Some(self.window), PCWSTR(wide(&prompt).as_ptr()), w!("安装更新并重新启动"), MB_OKCANCEL | MB_ICONQUESTION) };
            self.modal_prompt_open.store(false, Ordering::Release);
            if choice != IDOK {
                return;
            }
        }
        let mut ctx = self.update_context();
        ctx.window_minimized_or_hidden = false;
        match self.updater.execute_install(false, ctx, &self.host_activity) {
            Ok(true) => self.finish_for_update_restart(),
            Ok(false) => self.refresh_update_controls(),
            Err(err) => {
                self.refresh_update_controls();
                self.alert(&err);
            }
        }
    }

    fn show_update_notes(&mut self) {
        if let Some(url) = self.updater.manual_release_url.clone() {
            if let Err(err) = super::update::open_verified_release_url(&url) {
                self.alert(&err);
            }
            return;
        }
        if let Some(manifest) = self.updater.manifest.clone() {
            let notes = manifest.notes.as_deref().filter(|s| !s.trim().is_empty()).unwrap_or("（无详细更新说明）");
            let body = format!(
                "新版本：{}（Build {}）\n发布时间：{}\n\n{}\n\n点击“是”在浏览器查看 GitHub Release，“否”跳过此版本自动提醒，“取消”关闭窗口。",
                manifest.version, manifest.build, manifest.published_at, notes
            );
            self.modal_prompt_open.store(true, Ordering::Release);
            let choice =
                unsafe { MessageBoxW(Some(self.window), PCWSTR(wide(&body).as_ptr()), w!("QuietDesk 更新说明"), MB_YESNOCANCEL | MB_ICONINFORMATION) };
            self.modal_prompt_open.store(false, Ordering::Release);
            if choice == IDYES {
                if let Err(err) = super::update::open_verified_release_url(&manifest.release_notes_url) {
                    self.alert(&err);
                }
            } else if choice == IDNO && !self.updater.busy() {
                self.settings.skipped_update_version = Some(manifest.version);
                self.save();
                self.updater.manifest = None;
                self.updater.state = super::update::UpdaterState::Idle;
                self.updater.status_text = format!("已跳过该版本 · 当前版本 {}", self.updater.config.current_version);
                self.refresh_update_controls();
            }
            return;
        }
        let summary = format!(
            "当前版本：{}（Build {} · {}）\n更新校验：内置 Ed25519 公钥验签 + SHA-256 完整性校验\n自动更新规则：开启“非远程控制空闲时自动下载并安装”后，仅在未控制其他电脑且未被其他电脑控制时后台下载、替换并自动重启（原已开启的本机共享会在重启后自动恢复）。",
            self.updater.config.current_version,
            self.updater.config.current_build,
            self.updater.config.arch.map_or("unknown", |a| a.as_str())
        );
        self.modal_prompt_open.store(true, Ordering::Release);
        unsafe {
            MessageBoxW(Some(self.window), PCWSTR(wide(&summary).as_ptr()), w!("QuietDesk 软件更新说明"), MB_OK | MB_ICONINFORMATION);
        }
        self.modal_prompt_open.store(false, Ordering::Release);
    }

    fn tick_updater(&mut self) {
        let ctx = self.update_context();
        if self.updater.tick(self.window, WM_UPDATE_EVENT, &self.settings, ctx, &self.host_activity) {
            self.finish_for_update_restart();
        } else {
            self.refresh_update_controls();
        }
    }

    fn save(&self) {
        if let Err(error) = self.settings.save() {
            self.alert(&error.to_string());
        }
    }

    fn show_displays(&mut self, displays: Vec<RemoteDisplayInfo>, selected: Option<u32>) {
        self.displays = displays;
        self.active_display = selected;
        self.message(SHARED_DISPLAY, CB_RESETCONTENT, 0, 0);
        if self.displays.is_empty() {
            return;
        }
        self.message(SHARED_DISPLAY, CB_ADDSTRING, 0, wide("跟随主显示器").as_ptr() as isize);
        let mut choice = selected.or(self.settings.shared_display);
        if self.settings.shared_display.is_none() && selected.is_some_and(|id| self.displays.iter().any(|d| d.id == id && d.is_main)) {
            choice = None;
        }
        for display in &self.displays {
            self.message(SHARED_DISPLAY, CB_ADDSTRING, 0, wide(&display_label(display)).as_ptr() as isize);
        }
        let index = self.displays.iter().position(|display| Some(display.id) == choice).map_or(0, |index| index + 1);
        self.message(SHARED_DISPLAY, CB_SETCURSEL, index, 0);
    }

    fn refresh_displays(&mut self) {
        match displays::available(self.active_display.or(self.settings.shared_display)) {
            Ok(displays) => self.show_displays(displays, self.active_display),
            Err(error) => {
                self.show_displays(Vec::new(), None);
                self.set_text(HOST_STATUS, &format!("无法读取显示器：{error}"));
            }
        }
    }

    fn host_key(&mut self) -> Option<PairingKey> {
        if let Some(key) = self.settings.host_code.as_deref().and_then(unprotect).and_then(|code| PairingKey::parse(&code).ok()) {
            return Some(key);
        }
        if self.settings.host_code.is_some() {
            // A stored code that cannot be read is not replaced silently: other machines still hold it.
            self.alert("已保存的配对码无法读取（可能来自其他 Windows 账户）。点“重新生成”可换用新的配对码。");
            return None;
        }
        self.new_host_key()
    }

    fn new_host_key(&mut self) -> Option<PairingKey> {
        let created = PairingKey::generate().and_then(|key| Ok((protect(&key.code())?, key)));
        match created {
            Ok((stored, key)) => {
                self.settings.host_code = Some(stored);
                self.save();
                self.set_text(HOST_CODE, &key.code());
                Some(key)
            }
            Err(error) => {
                self.alert(&error.to_string());
                None
            }
        }
    }

    fn refresh_recent(&self, selection: Option<&Connection>) {
        let rows = self
            .settings
            .connections
            .iter()
            .map(|connection| (device_display_name(&connection.name), format!("{}:{}", connection.address, connection.port)))
            .collect::<Vec<_>>();
        self.message(RECENT, LB_RESETCONTENT, 0, 0);
        for (name, endpoint) in &rows {
            let label = wide(&format!("{name}  ·  {endpoint}"));
            self.message(RECENT, LB_ADDSTRING, 0, label.as_ptr() as isize);
        }
        let table = self.item(DEVICE_TABLE);
        if let Err(error) = device_table::replace(table, rows.iter().map(|(name, endpoint)| (name.as_str(), endpoint.as_str()))) {
            log::warn!("could not refresh device table: {error}");
        }
        self.workspace.show_devices(rows.len());
        let index = selection.and_then(|selected| {
            self.settings
                .connections
                .iter()
                .position(|connection| connection.port == selected.port && connection.address.eq_ignore_ascii_case(&selected.address))
        });
        self.message(RECENT, LB_SETCURSEL, index.unwrap_or(usize::MAX), 0);
        device_table::select(table, index);
        self.refresh_device_heading();
    }

    fn open_device(&self, index: usize) -> bool {
        let Some(connection) = self.settings.connections.get(index) else { return false };
        self.message(RECENT, LB_SETCURSEL, index, 0);
        device_table::select(self.item(DEVICE_TABLE), Some(index));
        self.set_text(ADDRESS, &connection.address);
        self.set_text(PORT, &connection.port.to_string());
        self.set_text(CODE, &unprotect(&connection.code).unwrap_or_default());
        self.refresh_device_heading();
        self.workspace.select(Page::Connection);
        true
    }

    fn refresh_device_heading(&self) {
        if let Some(index) = self.selected() {
            let connection = &self.settings.connections[index];
            self.set_text(DEVICE_HEADING, &device_display_name(&connection.name));
            self.set_text(DEVICE_DETAIL, &format!("{}:{}", connection.address, connection.port));
            let _ = unsafe { EnableWindow(self.item(FORGET), true) };
        } else {
            self.set_text(DEVICE_HEADING, "新建连接");
            self.set_text(DEVICE_DETAIL, "填写目标设备的连接信息");
            let _ = unsafe { EnableWindow(self.item(FORGET), false) };
        }
    }

    fn new_connection(&self) {
        self.message(RECENT, LB_SETCURSEL, usize::MAX, 0);
        device_table::select(self.item(DEVICE_TABLE), None);
        self.set_text(ADDRESS, "");
        self.set_text(PORT, &self.settings.port.to_string());
        self.set_text(CODE, "");
        self.refresh_device_heading();
        self.workspace.select(Page::Connection);
        let _ = unsafe { SetFocus(Some(self.item(ADDRESS))) };
    }

    fn refresh_sharing_summary(&self) {
        let text = if self.sharing.is_none() {
            "共享未开启"
        } else if self.host_activity.connected() {
            "正在被控制"
        } else {
            "本机共享已开启"
        };
        self.set_text(SHARING_SUMMARY, text);
    }

    fn selected(&self) -> Option<usize> {
        usize::try_from(self.message(RECENT, LB_GETCURSEL, 0, 0)).ok().filter(|index| *index < self.settings.connections.len())
    }

    fn connect(&mut self) {
        let (address, code) = (self.text(ADDRESS), self.text(CODE));
        let Ok(port) = self.text(PORT).parse::<u16>() else { return self.alert("端口应为 1 到 65535 的数字") };
        if address.is_empty() || port == 0 {
            return self.alert("请填写被控端的地址和端口");
        }
        let key = match PairingKey::parse(&code) {
            Ok(key) => key,
            Err(error) => return self.alert(&error.to_string()),
        };
        let stored = match protect(&key.code()) {
            Ok(stored) => stored,
            Err(error) => return self.alert(&error.to_string()),
        };
        let target = match ViewerTarget::parse(&address, port, self.tailnet.client()) {
            Ok(target) => target,
            Err(error) => return self.alert(&error.to_string()),
        };
        match canvas::open(&self.runtime, self.window, target, key, &self.settings, self.local_identity.clone(), self.auto_reconnect.subscribe()) {
            Ok(window) => self.viewers.push((window, Some(Connection { address, port, name: String::new(), code: stored, device_id: None }))),
            Err(error) => self.alert(&format!("无法打开远程窗口：{error}")),
        }
    }

    fn toggle_sharing(&mut self) {
        self.viewer_name = None;
        if self.sharing.take().is_some() {
            self.tailnet.share(None);
            self.active_display = None;
            self.refresh_displays();
            self.set_text(SHARE, "开始共享");
            self.set_text(HOST_STATUS, "未共享");
            self.refresh_sharing_summary();
            self.updater.observe_remote_sessions(self.host_activity.connected(), self.viewers.len());
            self.refresh_update_controls();
            return;
        }
        let Ok(port) = self.text(HOST_PORT).parse::<u16>() else { return self.alert("端口应为 1 到 65535 的数字") };
        let Some(key) = self.host_key() else { return };
        self.settings.port = port;
        self.save();
        let options = HostOptions {
            name: computer_name(),
            device_id: self.local_identity.as_ref().map(|device| device.id),
            allow_control: self.settings.allow_control,
            clipboard: self.settings.clipboard,
            preferred: self.settings.quality_limit(),
            limit: self.settings.quality_limit(),
            modifiers: self.settings.mac_modifiers,
            preferred_display: self.settings.shared_display,
        };
        let (commands, queue) = unbounded_channel();
        self.notices = Arc::default();
        let (notices, window) = (self.notices.clone(), self.window.0 as isize);
        let notify = move |notice: HostNotice| {
            notices.lock().unwrap().push_back(notice);
            let _ = unsafe { PostMessageW(Some(HWND(window as _)), WM_HOST_NOTICE, WPARAM(0), LPARAM(0)) };
        };
        self.runtime.spawn(serve_host(port, key, Arc::new(Mutex::new(options)), queue, self.host_activity.clone(), notify));
        self.sharing = Some(commands);
        self.set_text(SHARE, "停止共享");
        self.set_text(HOST_STATUS, "正在开启共享…");
        self.set_text(SHARING_SUMMARY, "正在准备共享");
    }

    fn host_notice(&mut self, notice: HostNotice) {
        if self.sharing.is_none() {
            return;
        }
        match notice {
            HostNotice::Listening(listener) => {
                let port = listener.local_addr().map_or(self.settings.port, |a| a.port());
                self.tailnet.share(Some(listener));
                self.set_text(HOST_STATUS, &format!("等待连接 · 端口 {port}（首次共享时请在防火墙提示中允许访问）"));
            }
            HostNotice::MediaSocket(active, socket) => self.tailnet.media_socket(active, socket),
            HostNotice::Failed(reason) => {
                self.tailnet.share(None);
                self.sharing = None;
                self.set_text(SHARE, "开始共享");
                self.set_text(HOST_STATUS, &format!("共享未开启：{reason}"));
                self.updater.observe_remote_sessions(self.host_activity.connected(), self.viewers.len());
                self.refresh_update_controls();
            }
            HostNotice::Connected => {
                self.viewer_name = None;
                self.update_session_status("控制端已连接，正在准备画面…".into());
                self.updater.observe_remote_sessions(self.host_activity.connected(), self.viewers.len());
                self.refresh_update_controls();
            }
            HostNotice::Session(HostEvent::ViewerIdentity(device)) => {
                self.viewer_name = Some(device.name);
                self.show_session_status();
            }
            HostNotice::DisplayError(reason) => self.set_text(HOST_STATUS, &format!("无法读取显示器：{reason}")),
            HostNotice::Session(HostEvent::Streaming(stream)) => {
                self.update_session_status(format!("正在共享 · {} × {} · {}", stream.width, stream.height, stream.settings.summary()));
            }
            HostNotice::Session(HostEvent::Displays { displays, selected, error }) => {
                self.show_displays(displays, Some(selected));
                if let Some(error) = error {
                    self.update_session_status(format!("显示器切换失败：{error}"));
                }
            }
            HostNotice::Session(HostEvent::LocalDisplaySelected(preference)) => {
                self.settings.shared_display = preference;
                self.save();
                self.refresh_displays();
            }
            HostNotice::Session(HostEvent::ClipboardStatus(status)) => self.update_session_status(status),
            HostNotice::Session(HostEvent::Paused(true)) => self.update_session_status("控制端已暂停画面，连接保持".into()),
            HostNotice::Session(_) => {}
            HostNotice::Ended(reason) => {
                self.viewer_name = None;
                self.active_display = None;
                self.refresh_displays();
                self.set_text(HOST_STATUS, &format!("等待重新连接 · {reason}"));
                self.updater.observe_remote_sessions(self.host_activity.connected(), self.viewers.len());
                self.refresh_update_controls();
            }
        }
        self.refresh_sharing_summary();
    }

    fn update_session_status(&mut self, text: String) {
        self.session_status = text;
        self.show_session_status();
    }

    fn show_session_status(&self) {
        let text = &self.session_status;
        if let Some(name) = &self.viewer_name {
            self.set_text(HOST_STATUS, &format!("{text} · {name}"));
        } else {
            self.set_text(HOST_STATUS, text);
        }
    }

    fn command(&mut self, id: usize, notification: u32) {
        let checked = |main: &Self, id: usize| main.message(id, BM_GETCHECK, 0, 0) == 1;
        let chosen = |main: &Self, id: usize| main.message(id, CB_GETCURSEL, 0, 0).max(0) as usize;
        match (id, notification) {
            (NEW_CONNECTION | NEW_CONNECTION_PAGE, BN_CLICKED) => self.new_connection(),
            (CONTINUE_CONNECTION, BN_CLICKED) => {
                self.workspace.select(Page::Connection);
                let _ = unsafe { SetFocus(Some(self.item(ADDRESS))) };
            }
            (NAV_DEVICES, BN_CLICKED) => {
                let has_entry = unsafe { GetWindowTextLengthW(self.item(ADDRESS)) != 0 || GetWindowTextLengthW(self.item(CODE)) != 0 };
                self.workspace.set_draft_available(has_entry || self.text(PORT) != self.settings.port.to_string());
                self.workspace.navigate(id);
            }
            (NAV_SHARING | NAV_SETTINGS | TAB_SHARING | TAB_HOST_QUALITY | TAB_KEYBOARD | TAB_DEFAULTS | TAB_UPDATES | TAB_TAILSCALE, BN_CLICKED) => {
                self.workspace.navigate(id);
            }
            (CONNECT, BN_CLICKED) => self.connect(),
            (TAILSCALE_LOGIN, BN_CLICKED) => {
                if self.tailnet.enable(true) && !self.settings.tailscale_enabled {
                    self.settings.tailscale_enabled = true;
                    self.save();
                }
                self.refresh_tailnet_controls();
            }
            (TAILSCALE_LOGOUT, BN_CLICKED) => {
                self.tailnet.logout();
                self.refresh_tailnet_controls();
            }
            (SHARED_DISPLAY, CBN_SELCHANGE) => {
                let choice = self.message(id, CB_GETCURSEL, 0, 0);
                let selected = match choice {
                    0 => None,
                    index if index > 0 => {
                        let Some(display) = self.displays.get(index as usize - 1) else { return };
                        Some(display.id)
                    }
                    _ => return,
                };
                if let Some(sharing) = &self.sharing {
                    let _ = sharing.send(HostCommand::SelectDisplay(selected));
                    self.refresh_displays();
                } else {
                    self.settings.shared_display = selected;
                    self.save();
                }
            }
            (AUTO_RECONNECT, BN_CLICKED) => {
                let enabled = checked(self, id);
                self.settings.auto_reconnect = enabled;
                self.auto_reconnect.send_replace(enabled);
                self.save();
            }
            (RECENT, LBN_SELCHANGE | LBN_DBLCLK) => {
                if let Some(index) = self.selected()
                    && self.open_device(index)
                    && notification == LBN_DBLCLK
                {
                    self.connect();
                }
            }
            (DEVICE_TABLE, BN_CLICKED) => {
                if let Some(index) = device_table::selected(self.item(DEVICE_TABLE))
                    && self.open_device(index)
                {
                    let _ = unsafe { SetFocus(Some(self.item(CONNECT))) };
                }
            }
            (FORGET, BN_CLICKED) => {
                if let Some(index) = self.selected() {
                    self.settings.connections.remove(index);
                    self.save();
                    self.refresh_recent(None);
                }
            }
            (SHARE, BN_CLICKED) => self.toggle_sharing(),
            (COPY_CODE, BN_CLICKED) => {
                if let Err(error) = clipboard::set_text(&self.text(HOST_CODE)) {
                    self.alert(&error.to_string());
                }
            }
            (NEW_CODE, BN_CLICKED) => {
                if self.sharing.is_some() {
                    return self.alert("请先停止共享，再重新生成配对码");
                }
                self.modal_prompt_open.store(true, Ordering::Release);
                let confirm = unsafe {
                    MessageBoxW(
                        Some(self.window),
                        w!("重新生成后，原配对码立即失效，其他设备需要改用新的配对码。继续吗？"),
                        w!("QuietDesk"),
                        MB_OKCANCEL | MB_ICONQUESTION,
                    )
                };
                self.modal_prompt_open.store(false, Ordering::Release);
                if confirm == IDOK {
                    self.new_host_key();
                }
            }
            (ALLOW_CONTROL, BN_CLICKED) => {
                self.settings.allow_control = checked(self, id);
                self.save();
                if let Some(sharing) = &self.sharing {
                    let _ = sharing.send(HostCommand::AllowControl(self.settings.allow_control));
                }
            }
            (ALLOW_CLIPBOARD, BN_CLICKED) => {
                self.settings.clipboard = checked(self, id);
                self.save();
                if let Some(sharing) = &self.sharing {
                    let _ = sharing.send(HostCommand::Clipboard(self.settings.clipboard));
                }
            }
            (VIEWER_QUALITY, CBN_SELCHANGE) => {
                self.settings.viewer_quality = chosen(self, id);
                self.save();
            }
            (QUALITY_LIMIT, CBN_SELCHANGE) => {
                self.settings.quality_limit = chosen(self, id);
                self.save();
            }
            (PC_MODIFIERS, CBN_SELCHANGE) => {
                self.settings.pc_modifiers = if chosen(self, id) == 0 { PcModifierMapping::Standard } else { PcModifierMapping::ControlAsCommand };
                self.save();
            }
            (MAC_MODIFIERS, CBN_SELCHANGE) => {
                self.settings.mac_modifiers = if chosen(self, id) == 0 { MacModifierMapping::CommandAsControl } else { MacModifierMapping::Standard };
                self.save();
            }
            (UPDATE_ACTION, BN_CLICKED) => {
                use super::update::UpdaterState;
                match self.updater.state {
                    UpdaterState::Checking | UpdaterState::Downloading | UpdaterState::Verifying => {
                        self.updater.cancel();
                        self.refresh_update_controls();
                    }
                    UpdaterState::Ready => self.trigger_manual_install(),
                    UpdaterState::Available => {
                        if let Some(url) = self.updater.manual_release_url.clone() {
                            if let Err(err) = super::update::open_verified_release_url(&url) {
                                self.alert(&err);
                            }
                        } else {
                            let immediate = !self.host_activity.connected();
                            self.updater.start_download_and_stage(self.window, WM_UPDATE_EVENT, false, immediate);
                            self.refresh_update_controls();
                        }
                    }
                    UpdaterState::Idle | UpdaterState::UpToDate | UpdaterState::Failed => {
                        self.updater.start_check(self.window, WM_UPDATE_EVENT, true);
                        self.refresh_update_controls();
                    }
                    UpdaterState::Installing => {}
                }
            }
            (UPDATE_NOTES, BN_CLICKED) => self.show_update_notes(),
            (AUTO_CHECK_UPDATES, BN_CLICKED) => {
                let enabled = checked(self, id);
                self.settings.auto_check_updates = enabled;
                if !enabled && self.settings.auto_install_updates {
                    self.settings.auto_install_updates = false;
                }
                self.save();
                self.refresh_update_controls();
            }
            (AUTO_INSTALL_UPDATES, BN_CLICKED) => {
                let enabled = checked(self, id);
                self.settings.auto_install_updates = enabled;
                if enabled && !self.settings.auto_check_updates {
                    self.settings.auto_check_updates = true;
                }
                self.save();
                if enabled && self.updater.manifest.is_none() && !self.updater.busy() && !self.host_activity.connected() && self.viewers.is_empty() {
                    self.updater.start_check(self.window, WM_UPDATE_EVENT, false);
                }
                self.tick_updater();
            }
            _ => {}
        }
    }

    fn dispatch_event(&mut self, message: u32, wparam: WPARAM) {
        match message {
            WM_COMMAND => self.command(wparam.0 & 0xFFFF, ((wparam.0 >> 16) & 0xFFFF) as u32),
            WM_HOST_NOTICE => {
                let notices = std::mem::take(&mut *self.notices.lock().unwrap());
                for notice in notices {
                    self.host_notice(notice);
                }
            }
            WM_UPDATE_EVENT => {
                let events = std::mem::take(&mut *self.updater.events.lock().unwrap());
                let mut should_save = false;
                let mut immediate_install = false;
                for event in events {
                    let (save, install_now) = self.updater.handle_worker_event(event, &mut self.settings);
                    should_save |= save;
                    immediate_install |= install_now;
                }
                if should_save {
                    self.save();
                }
                self.refresh_update_controls();
                if immediate_install {
                    self.trigger_manual_install();
                } else {
                    self.tick_updater();
                }
            }
            WM_TIMER if wparam.0 == TIMER_UPDATE_TICK => self.tick_updater(),
            WM_TIMER if wparam.0 == TIMER_TAILNET_TICK && self.settings.tailscale_enabled => {
                if self.tailnet.tick() {
                    self.settings.tailscale_enabled = false;
                    self.save();
                }
                self.refresh_tailnet_controls();
            }
            WM_DISPLAYCHANGE => {
                self.refresh_displays();
                if let Some(sharing) = &self.sharing {
                    let _ = sharing.send(HostCommand::RefreshDisplays);
                }
            }
            WM_CANVAS_CONNECTED => {
                if let Some((viewer, history)) = self.viewers.iter_mut().find(|(viewer, _)| viewer.window.0 as usize == wparam.0)
                    && let Some(host) = viewer.connected.take()
                    && let Some(mut connection) = history.take()
                {
                    connection.name = host.name;
                    connection.device_id = host.id;
                    let selection = self.selected().map(|index| self.settings.connections[index].clone());
                    self.settings.remember(connection);
                    self.save();
                    self.refresh_recent(selection.as_ref());
                }
            }
            WM_CANVAS_CLOSED => {
                self.viewers.retain(|(viewer, _)| viewer.window.0 as usize != wparam.0);
                self.updater.observe_remote_sessions(self.host_activity.connected(), self.viewers.len());
                self.refresh_update_controls();
            }
            WM_CAPS_PREFERENCE => {
                self.settings.caps_forwarding = wparam.0 != 0;
                self.save();
            }
            _ => {}
        }
    }

    fn initialize_controls(&mut self) {
        let fill = |id: usize, labels: &[&str], selected: usize| {
            for label in labels {
                self.message(id, CB_ADDSTRING, 0, wide(label).as_ptr() as isize);
            }
            self.message(id, CB_SETCURSEL, selected.min(labels.len() - 1), 0);
        };
        fill(VIEWER_QUALITY, &VIEWER_QUALITIES.map(|(label, _)| label), self.settings.viewer_quality);
        fill(QUALITY_LIMIT, &QUALITY_LIMITS.map(|(label, _)| label), self.settings.quality_limit);
        fill(
            PC_MODIFIERS,
            &["标准：Ctrl=⌃ Alt=⌥ Win=⌘", "左 Ctrl 作为 ⌘，右 Ctrl 仍为 ⌃"],
            usize::from(self.settings.pc_modifiers != PcModifierMapping::Standard),
        );
        fill(
            MAC_MODIFIERS,
            &["⌘ 与 ⌃ 都作为 Ctrl，右 ⌘ 作为 Win 键", "标准：⌃=Ctrl ⌥=Alt ⌘=Win 键"],
            usize::from(self.settings.mac_modifiers != MacModifierMapping::CommandAsControl),
        );
        self.message(ALLOW_CONTROL, BM_SETCHECK, usize::from(self.settings.allow_control), 0);
        self.refresh_displays();
        self.message(AUTO_RECONNECT, BM_SETCHECK, usize::from(self.settings.auto_reconnect), 0);
        self.message(ALLOW_CLIPBOARD, BM_SETCHECK, usize::from(self.settings.clipboard), 0);
        if let Some(code) = self.settings.host_code.as_deref().and_then(unprotect) {
            self.set_text(HOST_CODE, &code);
        } else if self.settings.host_code.is_none() {
            self.set_text(HOST_CODE, "首次开始共享时生成");
        }
        self.refresh_recent(None);
        if !self.settings.connections.is_empty() {
            self.workspace.select(Page::Devices);
        }
        self.refresh_update_controls();
        if self.settings.tailscale_enabled {
            self.tailnet.enable(false);
        }
        self.refresh_tailnet_controls();
    }
}

struct WindowState {
    workspace: Rc<Workspace>,
    main: RefCell<Main>,
    pending: RefCell<VecDeque<(u32, WPARAM)>>,
}

unsafe extern "system" fn window_procedure(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        let state = GetWindowLongPtrW(window, GWLP_USERDATA) as *const WindowState;
        let Some(state) = state.as_ref() else {
            return DefWindowProcW(window, message, wparam, lparam);
        };
        let workspace = &state.workspace;
        match message {
            WM_PAINT => {
                workspace.paint();
                return LRESULT(0);
            }
            WM_ERASEBKGND => return LRESULT(1),
            WM_DRAWITEM if lparam.0 != 0 => {
                if workspace.draw_item(&*(lparam.0 as *const DRAWITEMSTRUCT)) {
                    return LRESULT(1);
                }
                return DefWindowProcW(window, message, wparam, lparam);
            }
            WM_CTLCOLORSTATIC | WM_CTLCOLOREDIT | WM_CTLCOLORLISTBOX | WM_CTLCOLORBTN => {
                return workspace.control_colors(HDC(wparam.0 as _), HWND(lparam.0 as _));
            }
            WM_SIZE if wparam.0 != SIZE_MINIMIZED as usize => {
                workspace.layout();
                return LRESULT(0);
            }
            WM_GETMINMAXINFO => {
                let result = DefWindowProcW(window, message, wparam, lparam);
                workspace.min_size(&mut *(lparam.0 as *mut MINMAXINFO));
                return result;
            }
            WM_DPICHANGED => {
                workspace.dpi_changed((wparam.0 & 0xffff) as u32, &*(lparam.0 as *const RECT));
                return LRESULT(0);
            }
            WM_SETTINGCHANGE | WM_SYSCOLORCHANGE | WM_THEMECHANGED => {
                workspace.refresh_palette();
                return DefWindowProcW(window, message, wparam, lparam);
            }
            WM_NOTIFY if lparam.0 != 0 => {
                let header = &*(lparam.0 as *const NMHDR);
                if header.idFrom == DEVICE_TABLE && header.code == LVN_ITEMACTIVATE {
                    if let Ok(mut main) = state.main.try_borrow_mut() {
                        main.command(DEVICE_TABLE, BN_CLICKED);
                    }
                    return LRESULT(0);
                }
                return DefWindowProcW(window, message, wparam, lparam);
            }
            WM_NCDESTROY => {
                SetWindowLongPtrW(window, GWLP_USERDATA, 0);
                return DefWindowProcW(window, message, wparam, lparam);
            }
            WM_DESTROY => {
                let _ = KillTimer(Some(window), TIMER_UPDATE_TICK);
                let _ = KillTimer(Some(window), TIMER_TAILNET_TICK);
                PostQuitMessage(0);
                return LRESULT(0);
            }
            WM_COMMAND | WM_HOST_NOTICE | WM_UPDATE_EVENT | WM_TIMER | WM_DISPLAYCHANGE | WM_CANVAS_CONNECTED | WM_CANVAS_CLOSED | WM_CAPS_PREFERENCE => {}
            _ => return DefWindowProcW(window, message, wparam, lparam),
        }
        let Ok(mut main) = state.main.try_borrow_mut() else {
            // Native modal prompts pump posted session and update notifications.
            if !matches!(message, WM_COMMAND | WM_TIMER) {
                state.pending.borrow_mut().push_back((message, wparam));
            }
            return LRESULT(0);
        };
        let mut next = Some((message, wparam));
        while let Some((message, wparam)) = next {
            main.dispatch_event(message, wparam);
            next = state.pending.borrow_mut().pop_front();
        }

        LRESULT(0)
    }
}

/// Runs the application until its main window closes.
pub fn run() {
    start_logging();
    let apartment = unsafe { windows::Win32::System::Ole::OleInitialize(None) };
    if let Err(error) = unsafe { run_window() } {
        log::error!("the main window could not be created: {error}");
        unsafe { MessageBoxW(None, PCWSTR(wide(&format!("QuietDesk 无法启动：{error}")).as_ptr()), w!("QuietDesk"), MB_OK | MB_ICONERROR) };
    }
    if apartment.is_ok() {
        unsafe { windows::Win32::System::Ole::OleUninitialize() };
    }
}

unsafe fn run_window() -> windows::core::Result<()> {
    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None)?.into();
        let class = w!("QuietDeskMain");
        let definition = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(window_procedure),
            hInstance: instance,
            hIcon: LoadIconW(Some(instance), PCWSTR(1 as _)).unwrap_or_default(),
            hCursor: LoadCursorW(None, IDC_ARROW)?,
            lpszClassName: class,
            ..Default::default()
        };
        RegisterClassExW(&definition);
        let dpi = GetDpiForSystem();
        let frame = window_frame(dpi, 980, 630);
        let title = wide(&format!("QuietDesk {}", env!("QUIETDESK_VERSION")));
        let window = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            PCWSTR(title.as_ptr()),
            FRAME_STYLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            frame.right - frame.left,
            frame.bottom - frame.top,
            None,
            None,
            Some(instance),
            None,
        )?;
        let settings = Settings::load();
        let mut updater = super::update::WindowUpdater::new();
        let post_update_options = updater.apply_startup_result();
        let dpi = GetDpiForWindow(window);
        let workspace = match Workspace::new(window, dpi, settings.port, &updater.status_text) {
            Ok(workspace) => Rc::new(workspace),
            Err(error) => {
                let _ = DestroyWindow(window);
                return Err(error);
            }
        };
        let mut main = Main {
            window,
            workspace: workspace.clone(),
            local_identity: local_device_id().map(|id| DeviceIdentity { id, name: device_display_name(&computer_name()) }),
            viewer_name: None,
            session_status: String::new(),
            auto_reconnect: watch::Sender::new(settings.auto_reconnect),
            settings,
            displays: Vec::new(),
            active_display: None,
            host_activity: Arc::default(),
            modal_prompt_open: AtomicBool::new(false),
            runtime: network_runtime(),
            sharing: None,
            notices: Arc::new(Mutex::new(VecDeque::new())),
            viewers: Vec::new(),
            updater,
            tailnet: TailnetPanel::default(),
        };
        main.initialize_controls();
        if post_update_options.as_ref().is_some_and(|options| options.resume_host_sharing) {
            main.toggle_sharing();
        }
        let state = Box::new(WindowState { workspace, main: RefCell::new(main), pending: RefCell::default() });
        SetWindowLongPtrW(window, GWLP_USERDATA, std::ptr::from_ref(state.as_ref()) as isize);
        let _ = SetTimer(Some(window), TIMER_UPDATE_TICK, 5_000, None);
        let _ = SetTimer(Some(window), TIMER_TAILNET_TICK, 750, None);
        let minimize = post_update_options.is_some_and(|options| options.minimize_on_launch);
        let _ = ShowWindow(window, if minimize { SW_SHOWMINNOACTIVE } else { SW_SHOW });
        if !minimize && GetActiveWindow() == window {
            let main = state.main.borrow();
            let initial_focus = if main.settings.connections.is_empty() { ADDRESS } else { DEVICE_TABLE };
            let _ = SetFocus(Some(main.item(initial_focus)));
        }
        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).0 > 0 {
            if workspace_enter(window, &message) || IsDialogMessageW(window, &message).as_bool() || canvas::dialog_message(&message) {
                continue;
            }
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if IsWindow(Some(window)).as_bool() {
            let _ = DestroyWindow(window);
        }
        let mut main = state.main.into_inner();
        main.tailnet.share(None);
        main.sharing = None;
        main.updater.shutdown();
        Ok(())
    }
}

fn workspace_enter(window: HWND, message: &MSG) -> bool {
    if message.message != WM_KEYDOWN || message.wParam.0 != VK_RETURN.0 as usize || unsafe { GetParent(message.hwnd) }.ok() != Some(window) {
        return false;
    }
    unsafe {
        let id = GetDlgCtrlID(message.hwnd) as usize;
        match id {
            ADDRESS | PORT | CODE => {
                SendMessageW(window, WM_COMMAND, Some(WPARAM(CONNECT)), Some(LPARAM(0)));
            }
            RECENT => {
                SendMessageW(window, WM_COMMAND, Some(WPARAM(RECENT | (LBN_DBLCLK as usize) << 16)), Some(LPARAM(0)));
            }
            DEVICE_TABLE => {
                SendMessageW(window, WM_COMMAND, Some(WPARAM(DEVICE_TABLE)), Some(LPARAM(0)));
            }
            NEW_CONNECTION | NEW_CONNECTION_PAGE | NAV_DEVICES | NAV_SHARING | NAV_SETTINGS | TAB_SHARING | TAB_HOST_QUALITY | TAB_KEYBOARD | TAB_DEFAULTS
            | TAB_UPDATES | TAB_TAILSCALE | TAILSCALE_LOGIN | TAILSCALE_LOGOUT | CONTINUE_CONNECTION | CONNECT | FORGET | SHARE | COPY_CODE | NEW_CODE
            | UPDATE_ACTION | UPDATE_NOTES => {
                SendMessageW(message.hwnd, BM_CLICK, None, None);
            }
            _ => return false,
        }
    }
    true
}
