//! The main window: connect to another machine, or share this PC.

use super::app::{HostNotice, computer_name, network_runtime, serve_host, start_logging};
use super::canvas::{self, WM_CANVAS_CLOSED, WM_CANVAS_CONNECTED, WM_CAPS_PREFERENCE};
use super::clipboard;
use super::displays;
use super::settings::{Connection, QUALITY_LIMITS, Settings, VIEWER_QUALITIES, local_device_id, protect, unprotect};
use super::util::{display_label, from_wide, wide};
use quietdesk_core::display::RemoteDisplayInfo;
use quietdesk_core::host::{HostCommand, HostEvent, HostOptions};
use quietdesk_core::keymap::{MacModifierMapping, PcModifierMapping};
use quietdesk_core::messages::{DeviceIdentity, device_display_name};
use quietdesk_core::pairing::PairingKey;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};
use tokio::sync::watch;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::{COLOR_BTNFACE, CreateFontIndirectW, HBRUSH, HFONT};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::GetDpiForSystem;
use windows::Win32::UI::Input::KeyboardAndMouse::EnableWindow;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

const WM_HOST_NOTICE: u32 = WM_APP + 10;
const WM_UPDATE_EVENT: u32 = WM_APP + 40;
const TIMER_UPDATE_TICK: usize = 1;
const ADDRESS: usize = 1001;
const PORT: usize = 1002;
const CODE: usize = 1003;
const CONNECT: usize = 1004;
const RECENT: usize = 1005;
const FORGET: usize = 1006;
const VIEWER_QUALITY: usize = 1007;
const PC_MODIFIERS: usize = 1008;
const AUTO_RECONNECT: usize = 1009;
const HOST_STATUS: usize = 1101;
const HOST_PORT: usize = 1102;
const SHARE: usize = 1103;
const HOST_CODE: usize = 1104;
const COPY_CODE: usize = 1105;
const NEW_CODE: usize = 1106;
const ALLOW_CONTROL: usize = 1107;
const ALLOW_CLIPBOARD: usize = 1108;
const QUALITY_LIMIT: usize = 1109;
const MAC_MODIFIERS: usize = 1110;
const SHARED_DISPLAY: usize = 1111;
const UPDATE_STATUS: usize = 1201;
const UPDATE_ACTION: usize = 1202;
const UPDATE_NOTES: usize = 1203;
const AUTO_CHECK_UPDATES: usize = 1204;
const AUTO_INSTALL_UPDATES: usize = 1205;

struct Main {
    window: HWND,
    settings: Settings,
    local_identity: Option<DeviceIdentity>,
    viewer_name: Option<String>,
    session_status: String,
    displays: Vec<RemoteDisplayInfo>,
    active_display: Option<u32>,
    has_host_connection: bool,
    modal_prompt_open: AtomicBool,
    auto_reconnect: watch::Sender<bool>,
    runtime: tokio::runtime::Handle,
    /// Present while this PC is shared; closing it stops the listener and ends the session.
    sharing: Option<UnboundedSender<HostCommand>>,
    notices: Arc<Mutex<VecDeque<HostNotice>>>,
    /// Save an explicitly opened connection once. Retrying must not restore a forgotten record.
    viewers: Vec<(canvas::ViewerWindow, Connection)>,
    updater: super::update::WindowUpdater,
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
        self.set_text(UPDATE_ACTION, self.updater.action_button_label(self.has_host_connection));
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

    fn window_is_minimized_or_hidden(&self) -> bool {
        unsafe { IsIconic(self.window).as_bool() || !IsWindowVisible(self.window).as_bool() }
    }

    fn finish_for_update_restart(&mut self) {
        self.sharing = None;
        self.has_host_connection = false;
        unsafe {
            let _ = KillTimer(Some(self.window), TIMER_UPDATE_TICK);
            let _ = DestroyWindow(self.window);
        }
    }

    fn update_context(&self) -> super::update::WindowUpdateContext {
        super::update::WindowUpdateContext {
            has_host_connection: self.has_host_connection,
            viewer_count: self.viewers.len(),
            has_blocking_prompt: self.modal_prompt_open.load(Ordering::Acquire),
            is_sharing_enabled: self.sharing.is_some(),
            window_minimized_or_hidden: self.window_is_minimized_or_hidden(),
        }
    }

    fn trigger_manual_install(&mut self) {
        if self.has_host_connection {
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
        match self.updater.execute_install(false, ctx) {
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
        if self.updater.tick(self.window, WM_UPDATE_EVENT, &self.settings, ctx) {
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

    fn refresh_recent(&self) {
        self.message(RECENT, LB_RESETCONTENT, 0, 0);
        for connection in &self.settings.connections {
            let label = wide(&format!("{}  —  {}:{}", device_display_name(&connection.name), connection.address, connection.port));
            self.message(RECENT, LB_ADDSTRING, 0, label.as_ptr() as isize);
        }
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
        match canvas::open(
            &self.runtime,
            self.window,
            (address.clone(), port),
            key,
            &self.settings,
            self.local_identity.clone(),
            self.auto_reconnect.subscribe(),
        ) {
            Ok(window) => self.viewers.push((window, Connection { address, port, name: String::new(), code: stored, device_id: None })),
            Err(error) => self.alert(&format!("无法打开远程窗口：{error}")),
        }
    }

    fn toggle_sharing(&mut self) {
        self.viewer_name = None;
        if self.sharing.take().is_some() {
            self.has_host_connection = false;
            self.active_display = None;
            self.refresh_displays();
            self.set_text(SHARE, "开始共享");
            self.set_text(HOST_STATUS, "未共享");
            self.updater.observe_remote_sessions(false, self.viewers.len());
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
        self.runtime.spawn(serve_host(port, key, Arc::new(Mutex::new(options)), queue, notify));
        self.sharing = Some(commands);
        self.set_text(SHARE, "停止共享");
        self.set_text(HOST_STATUS, "正在开启共享…");
    }

    fn host_notice(&mut self, notice: HostNotice) {
        if self.sharing.is_none() {
            return;
        }
        match notice {
            HostNotice::Listening(port) => self.set_text(HOST_STATUS, &format!("等待连接 · 端口 {port}（首次共享时请在防火墙提示中允许访问）")),
            HostNotice::Failed(reason) => {
                self.sharing = None;
                self.has_host_connection = false;
                self.set_text(SHARE, "开始共享");
                self.set_text(HOST_STATUS, &format!("共享未开启：{reason}"));
                self.updater.observe_remote_sessions(false, self.viewers.len());
                self.refresh_update_controls();
            }
            HostNotice::Connected => {
                self.has_host_connection = true;
                self.viewer_name = None;
                self.update_session_status("控制端已连接，正在准备画面…".into());
                self.updater.observe_remote_sessions(true, self.viewers.len());
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
                self.has_host_connection = false;
                self.viewer_name = None;
                self.active_display = None;
                self.refresh_displays();
                self.set_text(HOST_STATUS, &format!("等待重新连接 · {reason}"));
                self.updater.observe_remote_sessions(false, self.viewers.len());
                self.refresh_update_controls();
            }
        }
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
            (CONNECT, BN_CLICKED) => self.connect(),
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
                let Some(connection) = self.selected().map(|index| self.settings.connections[index].clone()) else { return };
                self.set_text(ADDRESS, &connection.address);
                self.set_text(PORT, &connection.port.to_string());
                self.set_text(CODE, &unprotect(&connection.code).unwrap_or_default());
                if notification == LBN_DBLCLK {
                    self.connect();
                }
            }
            (FORGET, BN_CLICKED) => {
                if let Some(index) = self.selected() {
                    self.settings.connections.remove(index);
                    self.save();
                    self.refresh_recent();
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
                            let immediate = !self.has_host_connection;
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
                if enabled && self.updater.manifest.is_none() && !self.updater.busy() && !self.has_host_connection && self.viewers.is_empty() {
                    self.updater.start_check(self.window, WM_UPDATE_EVENT, false);
                }
                self.tick_updater();
            }
            _ => {}
        }
    }

    unsafe fn build(&mut self, font: HFONT, scale: f32) -> windows::core::Result<()> {
        unsafe {
            let instance: HINSTANCE = GetModuleHandleW(None)?.into();
            let add = |class: PCWSTR, text: &str, style: u32, edge: bool, x: i32, y: i32, width: i32, height: i32, id: usize| -> windows::core::Result<HWND> {
                let px = |value: i32| (value as f32 * scale).round() as i32;
                let extended = if edge { WS_EX_CLIENTEDGE } else { WINDOW_EX_STYLE(0) };
                let control = CreateWindowExW(
                    extended,
                    class,
                    PCWSTR(wide(text).as_ptr()),
                    WS_CHILD | WS_VISIBLE | WINDOW_STYLE(style),
                    px(x),
                    px(y),
                    px(width),
                    px(height),
                    Some(self.window),
                    Some(HMENU(id as _)),
                    Some(instance),
                    None,
                )?;
                SendMessageW(control, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
                Ok(control)
            };
            let (label, edit, button, list, combo) = (w!("STATIC"), w!("EDIT"), w!("BUTTON"), w!("LISTBOX"), w!("COMBOBOX"));
            let (tab, push, check, group) = (WS_TABSTOP.0, WS_TABSTOP.0 | BS_PUSHBUTTON as u32, WS_TABSTOP.0 | BS_AUTOCHECKBOX as u32, BS_GROUPBOX as u32);
            let (field, drop) = (tab | ES_AUTOHSCROLL as u32, tab | CBS_DROPDOWNLIST as u32 | WS_VSCROLL.0);

            add(button, "控制另一台电脑", group, false, 10, 8, 540, 238, 0)?;
            add(label, "地址", 0, false, 24, 37, 44, 20, 0)?;
            add(edit, "", field, true, 70, 33, 250, 24, ADDRESS)?;
            add(label, "端口", 0, false, 334, 37, 36, 20, 0)?;
            add(edit, &self.settings.port.to_string(), field | ES_NUMBER as u32, true, 372, 33, 72, 24, PORT)?;
            add(label, "配对码", 0, false, 24, 69, 44, 20, 0)?;
            add(edit, "", field, true, 70, 65, 374, 24, CODE)?;
            add(button, "连接", push | BS_DEFPUSHBUTTON as u32, false, 454, 33, 84, 56, CONNECT)?;
            add(label, "最近连接（双击直接连接）", 0, false, 24, 100, 300, 20, 0)?;
            add(button, "断线后自动重连", check, false, 328, 96, 210, 22, AUTO_RECONNECT)?;
            add(list, "", tab | LBS_NOTIFY as u32 | WS_VSCROLL.0, true, 24, 120, 420, 82, RECENT)?;
            add(button, "删除", push, false, 454, 120, 84, 26, FORGET)?;
            add(label, "画质", 0, false, 24, 214, 44, 20, 0)?;
            add(combo, "", drop, false, 70, 210, 210, 240, VIEWER_QUALITY)?;
            add(label, "键盘", 0, false, 292, 214, 36, 20, 0)?;
            add(combo, "", drop, false, 328, 210, 210, 240, PC_MODIFIERS)?;

            add(button, "共享这台电脑", group, false, 10, 254, 540, 276, 0)?;
            add(label, "未共享", 0, false, 24, 280, 514, 20, HOST_STATUS)?;
            add(label, "端口", 0, false, 24, 314, 44, 20, 0)?;
            add(edit, &self.settings.port.to_string(), field | ES_NUMBER as u32, true, 70, 310, 72, 24, HOST_PORT)?;
            add(button, "开始共享", push, false, 454, 306, 84, 30, SHARE)?;
            add(label, "配对码", 0, false, 24, 348, 44, 20, 0)?;
            add(edit, "", field | ES_READONLY as u32, true, 70, 344, 468, 24, HOST_CODE)?;
            add(button, "复制", push, false, 70, 374, 80, 26, COPY_CODE)?;
            add(button, "重新生成", push, false, 158, 374, 90, 26, NEW_CODE)?;
            add(button, "允许控制端操作键盘和鼠标", check, false, 24, 408, 236, 22, ALLOW_CONTROL)?;
            add(button, "允许同步剪贴板文字、图片和文件", check, false, 264, 408, 274, 22, ALLOW_CLIPBOARD)?;
            add(label, "共享屏幕", 0, false, 24, 438, 64, 20, 0)?;
            add(combo, "", drop, false, 92, 434, 446, 240, SHARED_DISPLAY)?;
            add(label, "画质上限", 0, false, 24, 468, 64, 20, 0)?;
            add(combo, "", drop, false, 92, 464, 250, 240, QUALITY_LIMIT)?;
            add(label, "Mac 键盘", 0, false, 24, 500, 64, 20, 0)?;
            add(combo, "", drop, false, 92, 496, 446, 240, MAC_MODIFIERS)?;

            add(button, "软件更新", group, false, 10, 538, 540, 86, 0)?;
            add(label, &self.updater.status_text, 0, false, 24, 564, 326, 20, UPDATE_STATUS)?;
            add(button, "检查更新", push, false, 356, 558, 96, 26, UPDATE_ACTION)?;
            add(button, "更新说明", push, false, 458, 558, 80, 26, UPDATE_NOTES)?;
            add(button, "自动检查更新（每天一次）", check, false, 24, 594, 216, 22, AUTO_CHECK_UPDATES)?;
            add(button, "非远程控制空闲时自动下载并安装", check, false, 248, 594, 290, 22, AUTO_INSTALL_UPDATES)?;

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
            self.refresh_recent();
            self.refresh_update_controls();
            Ok(())
        }
    }
}

unsafe extern "system" fn window_procedure(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        let main = GetWindowLongPtrW(window, GWLP_USERDATA) as *mut Main;
        if main.is_null() {
            return DefWindowProcW(window, message, wparam, lparam);
        }
        let main = &mut *main;
        match message {
            WM_COMMAND => main.command(wparam.0 & 0xFFFF, ((wparam.0 >> 16) & 0xFFFF) as u32),
            WM_HOST_NOTICE => {
                let notices = std::mem::take(&mut *main.notices.lock().unwrap());
                for notice in notices {
                    main.host_notice(notice);
                }
            }
            WM_UPDATE_EVENT => {
                let events = std::mem::take(&mut *main.updater.events.lock().unwrap());
                let mut should_save = false;
                let mut immediate_install = false;
                for event in events {
                    let (save, install_now) = main.updater.handle_worker_event(event, &mut main.settings);
                    should_save |= save;
                    immediate_install |= install_now;
                }
                if should_save {
                    main.save();
                }
                main.refresh_update_controls();
                if immediate_install {
                    main.trigger_manual_install();
                } else {
                    main.tick_updater();
                }
            }
            WM_TIMER if wparam.0 == TIMER_UPDATE_TICK => main.tick_updater(),
            WM_DISPLAYCHANGE => {
                main.refresh_displays();
                if let Some(sharing) = &main.sharing {
                    let _ = sharing.send(HostCommand::RefreshDisplays);
                }
            }
            WM_CANVAS_CONNECTED => {
                if let Some(index) = main.viewers.iter().position(|(viewer, _)| viewer.window.0 as usize == wparam.0)
                    && let Some(host) = main.viewers[index].0.connected.take()
                {
                    let (_, mut connection) = main.viewers.remove(index);
                    connection.name = host.name;
                    connection.device_id = host.id;
                    main.settings.remember(connection);
                    main.save();
                    main.refresh_recent();
                }
            }
            WM_CANVAS_CLOSED => {
                main.viewers.retain(|(viewer, _)| viewer.window.0 as usize != wparam.0);
                main.updater.observe_remote_sessions(main.has_host_connection, main.viewers.len());
                main.refresh_update_controls();
            }
            WM_CAPS_PREFERENCE => {
                main.settings.caps_forwarding = wparam.0 != 0;
                main.save();
            }
            WM_DESTROY => {
                let _ = KillTimer(Some(window), TIMER_UPDATE_TICK);
                main.sharing = None;
                main.updater.shutdown();
                PostQuitMessage(0);
            }
            _ => return DefWindowProcW(window, message, wparam, lparam),
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
            hbrBackground: HBRUSH((COLOR_BTNFACE.0 + 1) as _),
            lpszClassName: class,
            ..Default::default()
        };
        RegisterClassExW(&definition);
        let scale = GetDpiForSystem() as f32 / 96.0;
        let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
        let mut frame = RECT { left: 0, top: 0, right: (560.0 * scale) as i32, bottom: (634.0 * scale) as i32 };
        AdjustWindowRectEx(&mut frame, style, false, WINDOW_EX_STYLE(0))?;
        let title = wide(&format!("QuietDesk {}", env!("QUIETDESK_VERSION")));
        let window = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            PCWSTR(title.as_ptr()),
            style,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            frame.right - frame.left,
            frame.bottom - frame.top,
            None,
            None,
            Some(instance),
            None,
        )?;
        let mut metrics = NONCLIENTMETRICSW { cbSize: size_of::<NONCLIENTMETRICSW>() as u32, ..Default::default() };
        SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, metrics.cbSize, Some(std::ptr::from_mut(&mut metrics).cast()), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0))?;
        let font = CreateFontIndirectW(&metrics.lfMessageFont);
        let settings = Settings::load();
        let mut updater = super::update::WindowUpdater::new();
        let post_update_options = updater.apply_startup_result();
        let main = Box::into_raw(Box::new(Main {
            window,
            local_identity: local_device_id().map(|id| DeviceIdentity { id, name: device_display_name(&computer_name()) }),
            viewer_name: None,
            session_status: String::new(),
            auto_reconnect: watch::Sender::new(settings.auto_reconnect),
            settings,
            displays: Vec::new(),
            active_display: None,
            has_host_connection: false,
            modal_prompt_open: AtomicBool::new(false),
            runtime: network_runtime(),
            sharing: None,
            notices: Arc::new(Mutex::new(VecDeque::new())),
            viewers: Vec::new(),
            updater,
        }));
        (*main).build(font, scale)?;
        SetWindowLongPtrW(window, GWLP_USERDATA, main as isize);
        let _ = SetTimer(Some(window), TIMER_UPDATE_TICK, 5_000, None);
        if let Some(opts) = post_update_options {
            if opts.resume_host_sharing {
                (*main).toggle_sharing();
            }
            let show_cmd = if opts.minimize_on_launch { SW_SHOWMINNOACTIVE } else { SW_SHOW };
            let _ = ShowWindow(window, show_cmd);
        } else {
            let _ = ShowWindow(window, SW_SHOW);
        }
        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).as_bool() {
            // Tab and Enter work in the main window; viewer windows receive their keys untouched.
            if !IsDialogMessageW(window, &message).as_bool() {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        Ok(())
    }
}
