//! Windows in-app update client and atomic self-installer:
//! fetches `QuietDesk-windows-update.json` over WinHTTP, authenticates Ed25519 signatures,
//! downloads and SHA-256-verifies the matching x64/arm64 package, and performs atomic
//! replacement (or silent Inno Setup upgrade) once active remote sessions have ended.

use super::util::{from_wide, wide};
use quietdesk_core::update::{
    ExtractedPortableUpdate, MAX_ARCHIVE_BYTES, MAX_ENVELOPE_BYTES, PRODUCTION_APP_ID, ParsedHttpUrl, Sha256Digest, TargetArch, UpdateArchive,
    UpdateAvailability, UpdatePublicKey, VerificationResult, WindowsUpdateManifest, allows_redirect, extract_portable_zip, policy, repository_from_feed_url,
    validate_feed_url, validate_package_url, validate_pe_executable, validate_pe_installer, validate_release_notes_url, verify_manifest,
};
use serde::{Deserialize, Serialize};
use std::ffi::c_void;
use std::fs::{self, File};
use std::io::Write;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;
use windows::Win32::Foundation::{CloseHandle, ERROR_INSUFFICIENT_BUFFER, HANDLE, HWND, LPARAM, WAIT_OBJECT_0, WPARAM};
use windows::Win32::Networking::WinHttp::*;
use windows::Win32::Storage::FileSystem::{MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW};
use windows::Win32::System::Threading::{
    CREATE_NO_WINDOW, GetCurrentProcessId, GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, WaitForSingleObject,
};
use windows::Win32::UI::Shell::{SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteExW, ShellExecuteW};
use windows::Win32::UI::WindowsAndMessaging::{PostMessageW, SW_SHOWNORMAL};
use windows::core::{PCWSTR, w};

pub const INSTALL_HELPER_ARG: &str = "--quietdesk-install-update-v1";
pub const POST_UPDATE_ARG: &str = "--quietdesk-post-update";
const MAX_REDIRECTS: usize = 5;
const PLAN_MAX_BYTES: usize = 32 * 1024;

#[derive(Clone, Debug)]
pub struct UpdateConfig {
    pub app_id: String,
    pub feed_url: String,
    pub repository: String,
    pub public_keys: Vec<UpdatePublicKey>,
    pub current_version: String,
    pub current_build: u64,
    pub arch: Option<TargetArch>,
    pub allow_loopback: bool,
}

impl UpdateConfig {
    pub fn compiled() -> Self {
        let app_id = env!("QUIETDESK_WINDOWS_APP_ID").to_string();
        let feed_url = env!("QUIETDESK_WINDOWS_UPDATE_FEED_URL").to_string();
        let public_keys: Vec<UpdatePublicKey> = serde_json::from_str(env!("QUIETDESK_UPDATE_PUBLIC_KEYS_JSON")).unwrap_or_default();
        let current_version = env!("QUIETDESK_VERSION").to_string();
        let current_build = env!("QUIETDESK_BUILD_NUMBER").parse::<u64>().unwrap_or(0);
        let allow_loopback = app_id != PRODUCTION_APP_ID && !app_id.is_empty();
        let repository = repository_from_feed_url(&feed_url).unwrap_or_else(|| "nXiaoK/QuietDesk".to_string());
        Self { app_id, feed_url, repository, public_keys, current_version, current_build, arch: TargetArch::current(), allow_loopback }
    }

    pub fn enabled(&self) -> bool {
        self.arch.is_some()
            && self.current_build > 0
            && !self.public_keys.is_empty()
            && !self.feed_url.is_empty()
            && validate_feed_url(&self.feed_url, &self.app_id, self.allow_loopback).is_ok()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LaunchOptions {
    pub automatic: bool,
    pub resume_host_sharing: bool,
    pub minimize_on_launch: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallationResult {
    pub version: String,
    pub build: u64,
    pub succeeded: bool,
    pub message: String,
    #[serde(default)]
    pub launch_options: LaunchOptions,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum InstallPlanMode {
    Portable { staged_exe: PathBuf, staging_dir: PathBuf, backup_exe: PathBuf },
    InnoSetup { installer_exe: PathBuf, staging_dir: PathBuf, install_dir: PathBuf },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallPlan {
    pub parent_pid: u32,
    pub application_exe: PathBuf,
    pub updates_dir: PathBuf,
    pub mode: InstallPlanMode,
    pub ready_file: PathBuf,
    pub result_file: PathBuf,
    pub ack_file: PathBuf,
    pub version: String,
    pub build: u64,
    pub arch: TargetArch,
    pub reopen_after_install: bool,
    #[serde(default)]
    pub launch_options: LaunchOptions,
}

#[derive(Clone, Debug)]
pub enum PreparedUpdateKind {
    PortableSwap { staged_exe: PathBuf, staging_dir: PathBuf },
    InnoSetupSilent { installer_exe: PathBuf, helper_exe: PathBuf, staging_dir: PathBuf, install_dir: PathBuf },
    ElevatedInstaller { installer_exe: PathBuf, staging_dir: PathBuf, install_dir: PathBuf },
}

#[derive(Clone, Debug)]
pub struct PreparedUpdate {
    pub version: String,
    pub build: u64,
    pub arch: TargetArch,
    pub kind: PreparedUpdateKind,
}

impl PreparedUpdate {
    pub fn requires_elevation(&self) -> bool {
        matches!(self.kind, PreparedUpdateKind::ElevatedInstaller { .. })
    }

    pub fn staging_dir(&self) -> &Path {
        match &self.kind {
            PreparedUpdateKind::PortableSwap { staging_dir, .. }
            | PreparedUpdateKind::InnoSetupSilent { staging_dir, .. }
            | PreparedUpdateKind::ElevatedInstaller { staging_dir, .. } => staging_dir,
        }
    }

    pub fn discard(&self) {
        if let PreparedUpdateKind::InnoSetupSilent { helper_exe, .. } = &self.kind {
            let _ = fs::remove_file(helper_exe);
        }
        let _ = fs::remove_dir_all(self.staging_dir());
    }
}

struct WinHttpHandle(*mut c_void);

impl Drop for WinHttpHandle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                let _ = WinHttpCloseHandle(self.0);
            }
        }
    }
}

struct ProcessHandle(HANDLE);

impl Drop for ProcessHandle {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
}

pub fn updates_directory() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    base.join("QuietDesk").join("Updates")
}

fn wide_path(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

fn atomic_write_json<T: Serialize>(value: &T, destination: &Path) -> Result<(), String> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("无法创建更新目录：{e}"))?;
    }
    let temp = destination.with_extension(format!("tmp-{}", Uuid::new_v4()));
    let bytes = serde_json::to_vec_pretty(value).map_err(|e| format!("无法序列化更新状态：{e}"))?;
    let mut file = File::create(&temp).map_err(|e| format!("无法写入临时更新文件：{e}"))?;
    file.write_all(&bytes).and_then(|_| file.sync_all()).map_err(|e| {
        let _ = fs::remove_file(&temp);
        format!("无法落盘更新文件：{e}")
    })?;
    drop(file);
    move_file_atomic(&temp, destination, true).inspect_err(|_| {
        let _ = fs::remove_file(&temp);
    })
}

fn read_bounded_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T, String> {
    let meta = fs::metadata(path).map_err(|e| format!("无法读取文件元数据：{e}"))?;
    if !meta.is_file() || meta.len() > PLAN_MAX_BYTES as u64 {
        return Err("更新状态文件无效或过大".into());
    }
    let bytes = fs::read(path).map_err(|e| format!("无法读取更新状态文件：{e}"))?;
    if bytes.len() > PLAN_MAX_BYTES {
        return Err("更新状态文件过大".into());
    }
    serde_json::from_slice(&bytes).map_err(|e| format!("更新状态文件解析失败：{e}"))
}

fn move_file_atomic(source: &Path, destination: &Path, replace_existing: bool) -> Result<(), String> {
    let src = wide_path(source);
    let dst = wide_path(destination);
    let mut flags = MOVEFILE_WRITE_THROUGH;
    if replace_existing {
        flags |= MOVEFILE_REPLACE_EXISTING;
    }
    unsafe { MoveFileExW(PCWSTR(src.as_ptr()), PCWSTR(dst.as_ptr()), flags) }
        .map_err(|e| format!("无法替换文件 {}（0x{:08X}）", destination.display(), e.code().0))
}

fn directory_is_writable(dir: &Path) -> bool {
    let probe = dir.join(format!(".quietdesk-write-probe-{}", Uuid::new_v4()));
    match File::create(&probe) {
        Ok(file) => {
            drop(file);
            let _ = fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

fn is_inno_setup_installation(dir: &Path) -> bool {
    dir.join("unins000.exe").is_file() && dir.join("unins000.dat").is_file()
}

fn query_status_code(request: *mut c_void) -> Result<u32, String> {
    let mut code = 0u32;
    let mut size = size_of::<u32>() as u32;
    let mut index = 0u32;
    unsafe {
        WinHttpQueryHeaders(
            request,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            PCWSTR::null(),
            Some(std::ptr::from_mut(&mut code).cast()),
            &mut size,
            &mut index,
        )
    }
    .map_err(|e| format!("读取更新响应状态失败（0x{:08X}）", e.code().0))?;
    Ok(code)
}

fn query_header_string(request: *mut c_void, info_level: u32) -> Option<String> {
    let mut byte_len = 0u32;
    let mut index = 0u32;
    let first = unsafe { WinHttpQueryHeaders(request, info_level, PCWSTR::null(), None, &mut byte_len, &mut index) };
    if first.is_err() {
        let code = first.err().unwrap().code();
        if code != ERROR_INSUFFICIENT_BUFFER.to_hresult() || byte_len == 0 || byte_len > 16_384 {
            return None;
        }
    }
    let mut units = vec![0u16; (byte_len as usize / 2) + 2];
    index = 0;
    unsafe { WinHttpQueryHeaders(request, info_level, PCWSTR::null(), Some(units.as_mut_ptr().cast()), &mut byte_len, &mut index) }.ok()?;
    Some(from_wide(&units).trim().to_string())
}

fn stream_http_get(
    initial_url: ParsedHttpUrl,
    app_id: &str,
    allow_loopback: bool,
    user_agent: &str,
    max_bytes: u64,
    cancel: &AtomicBool,
    mut on_chunk: impl FnMut(&[u8], Option<u64>) -> Result<(), String>,
) -> Result<u32, String> {
    let agent_wide = wide(user_agent);
    let is_loopback = matches!(initial_url.host.as_str(), "127.0.0.1" | "localhost");
    let session_ptr = unsafe {
        let preferred = if is_loopback { WINHTTP_ACCESS_TYPE_NO_PROXY } else { WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY };
        let handle = WinHttpOpen(PCWSTR(agent_wide.as_ptr()), preferred, PCWSTR::null(), PCWSTR::null(), 0);
        if handle.is_null() && !is_loopback {
            WinHttpOpen(PCWSTR(agent_wide.as_ptr()), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, PCWSTR::null(), PCWSTR::null(), 0)
        } else {
            handle
        }
    };
    if session_ptr.is_null() {
        return Err("无法初始化系统 WinHTTP 网络组件".into());
    }
    let session = WinHttpHandle(session_ptr);
    let _ = unsafe { WinHttpSetTimeouts(session.0, 15_000, 15_000, 15_000, 30_000) };

    let mut current = initial_url;
    for _ in 0..=MAX_REDIRECTS {
        if cancel.load(Ordering::Acquire) {
            return Err("已取消".into());
        }
        let host_wide = wide(&current.host);
        let connect_ptr = unsafe { WinHttpConnect(session.0, PCWSTR(host_wide.as_ptr()), current.effective_port(), 0) };
        if connect_ptr.is_null() {
            return Err("无法连接到更新服务器，请检查网络后重试".into());
        }
        let connect = WinHttpHandle(connect_ptr);

        let path_wide = wide(&current.path_and_query());
        let flags = if current.scheme == "https" { WINHTTP_FLAG_SECURE } else { WINHTTP_OPEN_REQUEST_FLAGS(0) };
        let request_ptr =
            unsafe { WinHttpOpenRequest(connect.0, w!("GET"), PCWSTR(path_wide.as_ptr()), PCWSTR::null(), PCWSTR::null(), std::ptr::null(), flags) };
        if request_ptr.is_null() {
            return Err("无法创建更新下载请求".into());
        }
        let request = WinHttpHandle(request_ptr);

        let disabled = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES;
        let _ = unsafe { WinHttpSetOption(Some(request.0), WINHTTP_OPTION_DISABLE_FEATURE, Some(&disabled.to_ne_bytes())) };

        unsafe { WinHttpSendRequest(request.0, None, None, 0, 0, 0) }.map_err(|_| "无法连接更新服务器，请检查网络后重试".to_string())?;
        unsafe { WinHttpReceiveResponse(request.0, std::ptr::null_mut()) }.map_err(|_| "更新服务器未返回有效响应，请稍后重试".to_string())?;

        let status = query_status_code(request.0)?;
        if matches!(status, 301 | 302 | 303 | 307 | 308) {
            let location = query_header_string(request.0, WINHTTP_QUERY_LOCATION).ok_or_else(|| "更新重定向缺少目标地址".to_string())?;
            current = allows_redirect(&location, app_id, allow_loopback).map_err(|_| "更新重定向包含不安全的下载地址".to_string())?;
            continue;
        }
        if status != 200 {
            return Ok(status);
        }

        let declared_total = query_header_string(request.0, WINHTTP_QUERY_CONTENT_LENGTH).and_then(|s| s.parse::<u64>().ok());
        if let Some(total) = declared_total
            && total > max_bytes
        {
            return Err("更新响应超过允许的大小上限".into());
        }

        let mut received: u64 = 0;
        let mut buffer = vec![0u8; 32 * 1024];
        loop {
            if cancel.load(Ordering::Acquire) {
                return Err("已取消".into());
            }
            let mut available = 0u32;
            unsafe { WinHttpQueryDataAvailable(request.0, &mut available) }.map_err(|_| "读取更新数据时连接中断".to_string())?;
            if available == 0 {
                break;
            }
            let to_read = (available as usize).min(buffer.len()) as u32;
            let mut read_now = 0u32;
            unsafe { WinHttpReadData(request.0, buffer.as_mut_ptr().cast(), to_read, &mut read_now) }.map_err(|_| "下载更新数据时连接中断".to_string())?;
            if read_now == 0 {
                break;
            }
            received = received.saturating_add(u64::from(read_now));
            if received > max_bytes {
                return Err("下载内容超过安全大小上限".into());
            }
            on_chunk(&buffer[..read_now as usize], declared_total)?;
        }
        return Ok(200);
    }
    Err("更新下载地址重定向次数过多".into())
}

pub fn fetch_and_verify_manifest(config: &UpdateConfig, cancel: &AtomicBool) -> Result<VerificationResult, String> {
    let url = validate_feed_url(&config.feed_url, &config.app_id, config.allow_loopback).map_err(|e| e.to_string())?;
    let agent = format!("QuietDesk/{} (Windows)", config.current_version);
    let mut bytes = Vec::new();
    let status = stream_http_get(url, &config.app_id, config.allow_loopback, &agent, MAX_ENVELOPE_BYTES as u64, cancel, |chunk, _| {
        bytes.extend_from_slice(chunk);
        Ok(())
    })?;
    if status == 404 {
        return Err("暂无 Windows 更新信息，请稍后重试".into());
    }
    if status != 200 {
        return Err(format!("获取更新信息失败（HTTP {status}）"));
    }
    verify_manifest(&bytes, &config.public_keys, &config.app_id, config.allow_loopback, &config.repository)
        .map_err(|e| format!("{e}，请稍后重试或前往 GitHub 下载"))
}

fn download_verified_file(
    archive: &UpdateArchive,
    config: &UpdateConfig,
    destination: &Path,
    cancel: &AtomicBool,
    mut on_progress: impl FnMut(u64, u64),
) -> Result<(), String> {
    if archive.size == 0 || archive.size > MAX_ARCHIVE_BYTES {
        return Err("更新包大小字段无效".into());
    }
    let url = validate_package_url(&archive.url, &config.app_id, config.allow_loopback, &config.repository).map_err(|e| e.to_string())?;
    let agent = format!("QuietDesk/{} (Windows)", config.current_version);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("无法创建下载暂存目录：{e}"))?;
    }
    let mut file = File::create(destination).map_err(|e| format!("无法创建下载暂存文件：{e}"))?;
    let mut hasher = Sha256Digest::new();
    let mut received = 0u64;

    let download_res = stream_http_get(url, &config.app_id, config.allow_loopback, &agent, archive.size, cancel, |chunk, _| {
        received = received.saturating_add(chunk.len() as u64);
        if received > archive.size {
            return Err("下载文件超出签名清单声明的大小".into());
        }
        hasher.update(chunk);
        file.write_all(chunk).map_err(|e| format!("写入更新文件失败：{e}"))?;
        on_progress(received, archive.size);
        Ok(())
    });

    match download_res {
        Ok(200) => {}
        Ok(status) => {
            let _ = fs::remove_file(destination);
            return Err(format!("下载更新包失败（HTTP {status}）"));
        }
        Err(err) => {
            let _ = fs::remove_file(destination);
            return Err(err);
        }
    }

    if let Err(e) = file.sync_all() {
        let _ = fs::remove_file(destination);
        return Err(format!("刷新更新包缓存失败：{e}"));
    }
    drop(file);

    if received != archive.size {
        let _ = fs::remove_file(destination);
        return Err("下载的更新包大小与签名清单不一致".into());
    }
    let actual_hex = hasher.finish_hex();
    if actual_hex != archive.sha256 {
        let _ = fs::remove_file(destination);
        return Err("更新包 SHA-256 校验失败，已拒绝安装".into());
    }
    Ok(())
}

pub fn stage_update(
    manifest: &WindowsUpdateManifest,
    config: &UpdateConfig,
    application_exe: &Path,
    updates_root: &Path,
    cancel: &AtomicBool,
    mut on_progress: impl FnMut(u64, u64),
    mut on_verifying: impl FnMut(),
) -> Result<PreparedUpdate, String> {
    let arch = config.arch.ok_or_else(|| "当前处理器架构暂不支持自动更新".to_string())?;
    let pkg = manifest.package_for(arch).ok_or_else(|| format!("更新清单未包含 {} 架构安装包", arch.as_str()))?;
    let install_dir = application_exe.parent().ok_or_else(|| "无法确定当前程序所在目录".to_string())?.to_path_buf();

    let writable = directory_is_writable(&install_dir);
    let inno_installed = is_inno_setup_installation(&install_dir);
    fs::create_dir_all(updates_root).map_err(|e| format!("无法创建更新目录：{e}"))?;
    let staging_dir = updates_root.join(format!("QuietDesk-update-{}-{}-{}", manifest.version, manifest.build, Uuid::new_v4()));
    fs::create_dir_all(&staging_dir).map_err(|e| format!("无法创建暂存目录：{e}"))?;

    let cleanup_staging = |dir: &Path| {
        let _ = fs::remove_dir_all(dir);
    };

    if !writable {
        let Some(installer_meta) = &pkg.installer else {
            cleanup_staging(&staging_dir);
            return Err("当前目录需要管理员权限且未提供 Setup 安装器，请手动更新".into());
        };
        let installer_exe = staging_dir.join(format!("QuietDesk-{}-Windows-{}-Setup.exe", manifest.version, arch.as_str()));
        if let Err(err) = download_verified_file(installer_meta, config, &installer_exe, cancel, &mut on_progress) {
            cleanup_staging(&staging_dir);
            return Err(err);
        }
        on_verifying();
        let bytes = fs::read(&installer_exe).map_err(|e| {
            cleanup_staging(&staging_dir);
            format!("读取已下载安装程序失败：{e}")
        })?;
        if let Err(err) = validate_pe_installer(&bytes) {
            cleanup_staging(&staging_dir);
            return Err(err.to_string());
        }
        return Ok(PreparedUpdate {
            version: manifest.version.clone(),
            build: manifest.build,
            arch,
            kind: PreparedUpdateKind::ElevatedInstaller { installer_exe, staging_dir, install_dir },
        });
    }

    if inno_installed && let Some(installer_meta) = &pkg.installer {
        let installer_exe = staging_dir.join(format!("QuietDesk-{}-Windows-{}-Setup.exe", manifest.version, arch.as_str()));
        if let Err(err) = download_verified_file(installer_meta, config, &installer_exe, cancel, &mut on_progress) {
            cleanup_staging(&staging_dir);
            return Err(err);
        }
        on_verifying();
        let bytes = fs::read(&installer_exe).map_err(|e| {
            cleanup_staging(&staging_dir);
            format!("读取已下载安装程序失败：{e}")
        })?;
        if let Err(err) = validate_pe_installer(&bytes) {
            cleanup_staging(&staging_dir);
            return Err(err.to_string());
        }
        let helper_exe = updates_root.join(format!("helper-{}.exe", Uuid::new_v4()));
        if let Err(e) = fs::copy(application_exe, &helper_exe) {
            cleanup_staging(&staging_dir);
            return Err(format!("准备更新辅助进程失败：{e}"));
        }
        return Ok(PreparedUpdate {
            version: manifest.version.clone(),
            build: manifest.build,
            arch,
            kind: PreparedUpdateKind::InnoSetupSilent { installer_exe, helper_exe, staging_dir, install_dir },
        });
    }

    let archive_path = staging_dir.join("portable-update.zip");
    if let Err(err) = download_verified_file(&pkg.portable, config, &archive_path, cancel, &mut on_progress) {
        cleanup_staging(&staging_dir);
        return Err(err);
    }
    if cancel.load(Ordering::Acquire) {
        cleanup_staging(&staging_dir);
        return Err("已取消".into());
    }
    on_verifying();
    let zip_bytes = fs::read(&archive_path).map_err(|e| {
        cleanup_staging(&staging_dir);
        format!("读取更新归档失败：{e}")
    })?;
    let _ = fs::remove_file(&archive_path);
    let ExtractedPortableUpdate { executable, license, third_party_opus } = extract_portable_zip(&zip_bytes, arch).map_err(|e| {
        cleanup_staging(&staging_dir);
        e.to_string()
    })?;
    let staged_exe = staging_dir.join("QuietDesk.exe");
    let write_staged = || -> std::io::Result<()> {
        let mut out = File::create(&staged_exe)?;
        out.write_all(&executable)?;
        out.sync_all()?;
        if let Some(lic) = license {
            fs::write(staging_dir.join("LICENSE"), lic)?;
        }
        if let Some(opus) = third_party_opus {
            fs::write(staging_dir.join("THIRD-PARTY-OPUS.txt"), opus)?;
        }
        Ok(())
    };
    if let Err(e) = write_staged() {
        cleanup_staging(&staging_dir);
        return Err(format!("暂存新版程序失败：{e}"));
    }
    Ok(PreparedUpdate { version: manifest.version.clone(), build: manifest.build, arch, kind: PreparedUpdateKind::PortableSwap { staged_exe, staging_dir } })
}

pub struct PendingInstallerProcess {
    child: Child,
    plan_file: PathBuf,
    ready_file: PathBuf,
}

impl PendingInstallerProcess {
    pub fn abort(mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_file(&self.plan_file);
        let _ = fs::remove_file(&self.ready_file);
    }
}

pub fn launch_detached_installer(
    prepared: &PreparedUpdate,
    application_exe: &Path,
    updates_root: &Path,
    launch_options: LaunchOptions,
    cancel: &AtomicBool,
) -> Result<PendingInstallerProcess, String> {
    if let PreparedUpdateKind::ElevatedInstaller { installer_exe, install_dir, .. } = &prepared.kind {
        run_elevated_setup(installer_exe, install_dir)?;
        return Err("__ELEVATED_HANDOFF__".into());
    }
    fs::create_dir_all(updates_root).map_err(|e| format!("无法创建更新目录：{e}"))?;
    let token = Uuid::new_v4().to_string();
    let parent_pid = unsafe { GetCurrentProcessId() };
    let (helper_binary, mode) = match &prepared.kind {
        PreparedUpdateKind::PortableSwap { staged_exe, staging_dir } => {
            let install_dir = application_exe.parent().ok_or_else(|| "无法解析当前程序目录".to_string())?;
            let backup_exe = install_dir.join(format!(".QuietDesk-update-backup-{token}.exe"));
            (staged_exe.clone(), InstallPlanMode::Portable { staged_exe: staged_exe.clone(), staging_dir: staging_dir.clone(), backup_exe })
        }
        PreparedUpdateKind::InnoSetupSilent { installer_exe, helper_exe, staging_dir, install_dir } => (
            helper_exe.clone(),
            InstallPlanMode::InnoSetup { installer_exe: installer_exe.clone(), staging_dir: staging_dir.clone(), install_dir: install_dir.clone() },
        ),
        PreparedUpdateKind::ElevatedInstaller { .. } => unreachable!(),
    };

    let plan_file = updates_root.join("install-plan.json");
    let ready_file = updates_root.join(format!("installer-{token}.ready"));
    let result_file = updates_root.join("install-result.json");
    let ack_file = updates_root.join(format!("installer-{token}.ack"));
    let _ = fs::remove_file(&result_file);
    let _ = fs::remove_file(&ready_file);
    let _ = fs::remove_file(&ack_file);

    let plan = InstallPlan {
        parent_pid,
        application_exe: application_exe.to_path_buf(),
        updates_dir: updates_root.to_path_buf(),
        mode,
        ready_file: ready_file.clone(),
        result_file,
        ack_file,
        version: prepared.version.clone(),
        build: prepared.build,
        arch: prepared.arch,
        reopen_after_install: true,
        launch_options,
    };
    atomic_write_json(&plan, &plan_file)?;

    let mut child = Command::new(&helper_binary)
        .arg(INSTALL_HELPER_ARG)
        .arg(&plan_file)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW.0)
        .spawn()
        .map_err(|e| {
            let _ = fs::remove_file(&plan_file);
            format!("无法启动更新安装进程：{e}")
        })?;

    for _ in 0..100 {
        if cancel.load(Ordering::Acquire) {
            let _ = child.kill();
            let _ = child.wait();
            let _ = fs::remove_file(&plan_file);
            let _ = fs::remove_file(&ready_file);
            return Err("已取消".into());
        }
        if ready_file.is_file() {
            return Ok(PendingInstallerProcess { child, plan_file, ready_file });
        }
        if let Ok(Some(_)) = child.try_wait() {
            let _ = fs::remove_file(&plan_file);
            let _ = fs::remove_file(&ready_file);
            return Err("更新安装进程意外退出，请重试或手动安装".into());
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    let _ = child.kill();
    let _ = child.wait();
    let _ = fs::remove_file(&plan_file);
    let _ = fs::remove_file(&ready_file);
    Err("更新安装进程未在预期时间内就绪，当前应用将保持运行".into())
}

fn run_elevated_setup(installer_exe: &Path, install_dir: &Path) -> Result<(), String> {
    let file_wide = wide_path(installer_exe);
    let params = format!("/SP- /SILENT /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS /DIR=\"{}\"", install_dir.display());
    let params_wide = wide(&params);
    let mut info = SHELLEXECUTEINFOW {
        cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS,
        lpVerb: w!("runas"),
        lpFile: PCWSTR(file_wide.as_ptr()),
        lpParameters: PCWSTR(params_wide.as_ptr()),
        nShow: SW_SHOWNORMAL.0,
        ..Default::default()
    };
    unsafe { ShellExecuteExW(&mut info) }.map_err(|_| "未授予管理员安装权限，更新已取消".to_string())?;
    if !info.hProcess.is_invalid() {
        let _handle = ProcessHandle(info.hProcess);
    }
    Ok(())
}

pub fn open_verified_release_url(url: &str) -> Result<(), String> {
    validate_release_notes_url(url).map_err(|_| "不允许打开非 GitHub 官方发布链接".to_string())?;
    let url_wide = wide(url);
    let res = unsafe { ShellExecuteW(None, w!("open"), PCWSTR(url_wide.as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL) };
    if (res.0 as isize) <= 32 {
        return Err("无法调用系统浏览器打开发布页面".into());
    }
    Ok(())
}

fn validate_plan(plan: &InstallPlan, plan_path: &Path) -> Result<(), String> {
    if plan_path.file_name().and_then(|n| n.to_str()) != Some("install-plan.json") {
        return Err("安装计划文件名无效".into());
    }
    if plan.parent_pid == 0 || plan.parent_pid == unsafe { GetCurrentProcessId() } {
        return Err("安装计划父进程标识无效".into());
    }
    if plan.ready_file.parent() != Some(&plan.updates_dir)
        || plan.result_file != plan.updates_dir.join("install-result.json")
        || plan.ack_file.parent() != Some(&plan.updates_dir)
    {
        return Err("安装计划状态路径不一致".into());
    }
    quietdesk_core::update::UpdateVersion::parse(&plan.version).map_err(|e| e.to_string())?;
    if plan.build == 0 {
        return Err("安装计划构建号无效".into());
    }
    match &plan.mode {
        InstallPlanMode::Portable { staged_exe, staging_dir, backup_exe } => {
            if staged_exe.parent() != Some(staging_dir.as_path()) || backup_exe.parent() != plan.application_exe.parent() {
                return Err("便携版替换路径校验未通过".into());
            }
        }
        InstallPlanMode::InnoSetup { installer_exe, staging_dir, install_dir } => {
            if installer_exe.parent() != Some(staging_dir.as_path()) || plan.application_exe.parent() != Some(install_dir.as_path()) {
                return Err("安装器升级路径校验未通过".into());
            }
        }
    }
    Ok(())
}

fn wait_for_process_exit(pid: u32, timeout: Duration) -> Result<(), String> {
    let opened = unsafe { OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, false, pid) };
    let Ok(raw_handle) = opened else {
        // Process already exited before OpenProcess.
        return Ok(());
    };
    let handle = ProcessHandle(raw_handle);
    let ms = u32::try_from(timeout.as_millis()).unwrap_or(30_000);
    let waited = unsafe { WaitForSingleObject(handle.0, ms) };
    if waited == WAIT_OBJECT_0 {
        return Ok(());
    }
    let mut exit_code = 0u32;
    if unsafe { GetExitCodeProcess(handle.0, &mut exit_code) }.is_ok() && exit_code != 259 {
        return Ok(());
    }
    Err("等待原 QuietDesk 进程退出超时；更新未安装".into())
}

pub fn perform_installation(plan: &InstallPlan, plan_path: &Path, wait_timeout: Duration, restart_timeout: Duration) -> Result<(), String> {
    validate_plan(plan, plan_path)?;
    wait_for_process_exit(plan.parent_pid, wait_timeout)?;

    match &plan.mode {
        InstallPlanMode::Portable { staged_exe, staging_dir, backup_exe } => {
            let staged_bytes = fs::read(staged_exe).map_err(|e| format!("无法读取暂存的新版程序：{e}"))?;
            validate_pe_executable(&staged_bytes, plan.arch).map_err(|e| e.to_string())?;
            if backup_exe.exists() {
                let _ = fs::remove_file(backup_exe);
            }
            // Retry briefly in case antivirus or shell icon cache still holds a handle right after process exit.
            let mut moved_old = Err(String::new());
            for attempt in 0..20 {
                moved_old = move_file_atomic(&plan.application_exe, backup_exe, true);
                if moved_old.is_ok() {
                    break;
                }
                if attempt < 19 {
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
            moved_old?;

            // Copy instead of moving staged_exe because staged_exe IS the running helper binary in Portable mode.
            let install_new = || -> Result<(), String> {
                let temp_new = plan.application_exe.with_extension(format!("updating-{}", Uuid::new_v4()));
                let mut out = File::create(&temp_new).map_err(|e| format!("无法写入新版可执行文件：{e}"))?;
                out.write_all(&staged_bytes).and_then(|_| out.sync_all()).map_err(|e| {
                    let _ = fs::remove_file(&temp_new);
                    format!("无法落盘新版可执行文件：{e}")
                })?;
                drop(out);
                move_file_atomic(&temp_new, &plan.application_exe, true).inspect_err(|_| {
                    let _ = fs::remove_file(&temp_new);
                })?;
                let verify_bytes = fs::read(&plan.application_exe).map_err(|e| format!("无法校验安装后的程序：{e}"))?;
                validate_pe_executable(&verify_bytes, plan.arch).map_err(|e| e.to_string())
            };

            if let Err(err) = install_new() {
                let _ = move_file_atomic(backup_exe, &plan.application_exe, true);
                return Err(format!("安装新版程序失败，已自动恢复原版本：{err}"));
            }

            if let Some(app_dir) = plan.application_exe.parent() {
                for extra in ["LICENSE", "THIRD-PARTY-OPUS.txt"] {
                    let staged_extra = staging_dir.join(extra);
                    let target_extra = app_dir.join(extra);
                    if staged_extra.is_file() && target_extra.is_file() {
                        let _ = fs::copy(&staged_extra, &target_extra);
                    }
                }
            }
        }
        InstallPlanMode::InnoSetup { installer_exe, install_dir, .. } => {
            let installer_bytes = fs::read(installer_exe).map_err(|e| format!("无法读取暂存安装程序：{e}"))?;
            validate_pe_installer(&installer_bytes).map_err(|e| e.to_string())?;
            let status = Command::new(installer_exe)
                .arg("/SP-")
                .arg("/VERYSILENT")
                .arg("/SUPPRESSMSGBOXES")
                .arg("/NORESTART")
                .arg("/NOCANCEL")
                .arg("/CLOSEAPPLICATIONS")
                .arg(format!("/DIR={}", install_dir.display()))
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .creation_flags(CREATE_NO_WINDOW.0)
                .status()
                .map_err(|e| format!("启动静默安装程序失败：{e}"))?;
            if !status.success() {
                return Err(format!("安装程序返回非零状态（{:?}）", status.code()));
            }
            let installed_bytes = fs::read(&plan.application_exe).map_err(|e| format!("安装完成后找不到 QuietDesk.exe：{e}"))?;
            validate_pe_executable(&installed_bytes, plan.arch).map_err(|e| e.to_string())?;
        }
    }

    let message = if plan.launch_options.automatic { format!("已自动更新到 {}", plan.version) } else { format!("已更新到 {}", plan.version) };
    let result = InstallationResult { version: plan.version.clone(), build: plan.build, succeeded: true, message, launch_options: plan.launch_options };
    atomic_write_json(&result, &plan.result_file)?;

    if !plan.reopen_after_install {
        return Ok(());
    }

    if let Err(e) = Command::new(&plan.application_exe).arg(POST_UPDATE_ARG).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() {
        let fallback =
            InstallationResult {
                succeeded: true, message: format!("已更新到 {}，但自动重启失败（{e}），请手动重新打开 QuietDesk", plan.version), ..result
            };
        let _ = atomic_write_json(&fallback, &plan.result_file);
        return Ok(());
    }

    let deadline = Instant::now() + restart_timeout;
    while Instant::now() < deadline {
        if plan.ack_file.is_file() || !plan_path.is_file() {
            if let InstallPlanMode::Portable { backup_exe, .. } = &plan.mode {
                let _ = fs::remove_file(backup_exe);
            }
            let _ = fs::remove_file(&plan.result_file);
            let _ = fs::remove_file(plan_path);
            let _ = fs::remove_file(&plan.ack_file);
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Ok(())
}

pub fn run_special_mode_if_requested() -> bool {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) != Some(INSTALL_HELPER_ARG) {
        return false;
    }
    let Some(plan_arg) = args.get(2) else {
        return true;
    };
    let plan_path = PathBuf::from(plan_arg);
    let Ok(plan) = read_bounded_json::<InstallPlan>(&plan_path) else {
        return true;
    };
    if validate_plan(&plan, &plan_path).is_err() {
        return true;
    }
    let _ = fs::write(&plan.ready_file, b"ready");
    if let Err(error) = perform_installation(&plan, &plan_path, Duration::from_secs(30), Duration::from_secs(15)) {
        let failed =
            InstallationResult { version: plan.version.clone(), build: plan.build, succeeded: false, message: error, launch_options: plan.launch_options };
        let _ = atomic_write_json(&failed, &plan.result_file);
        // Reopen original app if parent already exited and original exe is still intact.
        if plan.reopen_after_install && plan.application_exe.is_file() {
            let parent_gone = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, plan.parent_pid) }.is_err();
            if parent_gone {
                let _ = Command::new(&plan.application_exe).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
            }
        }
    }
    let _ = fs::remove_file(&plan.ready_file);
    true
}

pub fn consume_startup_result(application_exe: &Path, updates_root: &Path, current_version: &str, current_build: u64) -> Option<InstallationResult> {
    // Best-effort cleanup of stale staging directories or detached Inno helper copies from previous runs.
    if let Ok(entries) = fs::read_dir(updates_root) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            if let Some(s) = name.to_str()
                && s.starts_with("helper-")
                && s.ends_with(".exe")
            {
                let _ = fs::remove_file(entry.path());
            }
        }
    }

    let plan_path = updates_root.join("install-plan.json");
    let plan: InstallPlan = read_bounded_json(&plan_path).ok()?;
    validate_plan(&plan, &plan_path).ok()?;
    if plan.application_exe != application_exe || plan.ack_file.is_file() {
        return None;
    }
    let result: InstallationResult = read_bounded_json(&plan.result_file).ok()?;
    if result.version != plan.version || result.build != plan.build {
        return None;
    }
    if result.succeeded && (current_version != result.version || current_build != result.build) {
        return None;
    }
    fs::write(&plan.ack_file, b"ack").ok()?;

    match &plan.mode {
        InstallPlanMode::Portable { staging_dir, backup_exe, .. } => {
            if result.succeeded {
                let _ = fs::remove_file(backup_exe);
            }
            let _ = fs::remove_dir_all(staging_dir);
        }
        InstallPlanMode::InnoSetup { staging_dir, .. } => {
            let _ = fs::remove_dir_all(staging_dir);
        }
    }
    let _ = fs::remove_file(&plan.result_file);
    let _ = fs::remove_file(&plan_path);
    let _ = fs::remove_file(&plan.ack_file);
    Some(result)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UpdaterState {
    Idle,
    Checking,
    UpToDate,
    Available,
    Downloading,
    Verifying,
    Ready,
    Installing,
    Failed,
}

#[derive(Clone, Copy, Debug)]
pub struct WindowUpdateContext {
    pub has_host_connection: bool,
    pub viewer_count: usize,
    pub has_blocking_prompt: bool,
    pub is_sharing_enabled: bool,
    pub window_minimized_or_hidden: bool,
}

#[derive(Clone, Debug)]
pub enum WorkerEvent {
    CheckFinished { manual: bool, checked_epoch_secs: u64, outcome: Result<VerificationResult, String> },
    DownloadProgress { received: u64, total: u64 },
    Verifying,
    StageFinished { automatic: bool, outcome: Result<PreparedUpdate, String> },
}

pub struct WindowUpdater {
    pub config: UpdateConfig,
    pub state: UpdaterState,
    pub manifest: Option<WindowsUpdateManifest>,
    pub manual_release_url: Option<String>,
    pub status_text: String,
    pub received_bytes: u64,
    pub total_bytes: u64,
    pub completion_notice: Option<String>,
    launched_at: Instant,
    was_remote_active: bool,
    last_remote_ended_at: Option<Instant>,
    deferred_version: Option<String>,
    pending_immediate_install_version: Option<String>,
    current_download_automatic: bool,
    auto_download_failures: u32,
    auto_download_retry_after: Option<Instant>,
    cancel_flag: Option<Arc<AtomicBool>>,
    prepared: Option<PreparedUpdate>,
    installation_handed_off: bool,
    pub events: Arc<Mutex<Vec<WorkerEvent>>>,
}

impl WindowUpdater {
    pub fn new() -> Self {
        let config = UpdateConfig::compiled();
        let status_text = if config.enabled() {
            format!("当前版本 {}（Build {}）", config.current_version, config.current_build)
        } else {
            format!("当前版本 {} · 未配置更新源", config.current_version)
        };
        Self {
            config,
            state: UpdaterState::Idle,
            manifest: None,
            manual_release_url: None,
            status_text,
            received_bytes: 0,
            total_bytes: 0,
            completion_notice: None,
            launched_at: Instant::now(),
            was_remote_active: false,
            last_remote_ended_at: None,
            deferred_version: None,
            pending_immediate_install_version: None,
            current_download_automatic: false,
            auto_download_failures: 0,
            auto_download_retry_after: None,
            cancel_flag: None,
            prepared: None,
            installation_handed_off: false,
            events: Arc::new(Mutex::new(Vec::new())),
        }
    }

    pub fn busy(&self) -> bool {
        self.cancel_flag.is_some() || self.state == UpdaterState::Installing
    }

    pub fn action_button_label(&self, has_host_connection: bool) -> &'static str {
        match self.state {
            UpdaterState::Checking | UpdaterState::Downloading | UpdaterState::Verifying => "取消",
            UpdaterState::Installing => "正在更新…",
            UpdaterState::Ready => {
                if self.prepared.as_ref().is_some_and(PreparedUpdate::requires_elevation) {
                    "授权安装"
                } else {
                    "安装并重启"
                }
            }
            UpdaterState::Available => {
                if self.manual_release_url.is_some() {
                    "前往下载"
                } else if has_host_connection {
                    "先下载更新"
                } else {
                    "立即更新"
                }
            }
            UpdaterState::Idle | UpdaterState::UpToDate | UpdaterState::Failed => "检查更新",
        }
    }

    pub fn apply_startup_result(&mut self) -> Option<LaunchOptions> {
        let exe = std::env::current_exe().ok()?;
        let res = consume_startup_result(&exe, &updates_directory(), &self.config.current_version, self.config.current_build)?;
        self.completion_notice = Some(res.message.clone());
        self.status_text = res.message;
        self.state = if res.succeeded { UpdaterState::UpToDate } else { UpdaterState::Failed };
        res.succeeded.then_some(res.launch_options)
    }

    pub fn observe_remote_sessions(&mut self, has_host_connection: bool, viewer_count: usize) {
        let active_now = policy::is_remote_control_active(has_host_connection, viewer_count);
        if self.was_remote_active && !active_now {
            self.last_remote_ended_at = Some(Instant::now());
        } else if active_now {
            self.last_remote_ended_at = None;
        }
        self.was_remote_active = active_now;

        if active_now && self.current_download_automatic && self.state == UpdaterState::Downloading {
            if let Some(cancel) = self.cancel_flag.take() {
                cancel.store(true, Ordering::Release);
            }
            self.current_download_automatic = false;
            self.state = UpdaterState::Available;
            self.status_text = "检测到远程连接，已暂停后台下载，会话结束后自动继续".into();
        }
    }

    pub fn cancel(&mut self) {
        if self.installation_handed_off {
            return;
        }
        if let Some(version) = self.manifest.as_ref().map(|m| m.version.clone()) {
            self.deferred_version = Some(version);
        }
        self.pending_immediate_install_version = None;
        self.current_download_automatic = false;
        if let Some(cancel) = self.cancel_flag.take() {
            cancel.store(true, Ordering::Release);
        }
        if let Some(prepared) = self.prepared.take() {
            prepared.discard();
        }
        self.state = if self.manifest.is_some() || self.manual_release_url.is_some() { UpdaterState::Available } else { UpdaterState::Idle };
        self.status_text = "已取消当前更新操作".into();
    }

    pub fn shutdown(&mut self) {
        if !self.installation_handed_off {
            if let Some(cancel) = self.cancel_flag.take() {
                cancel.store(true, Ordering::Release);
            }
            if let Some(prepared) = self.prepared.take() {
                prepared.discard();
            }
        }
    }

    pub fn start_check(&mut self, window: HWND, wm_event: u32, manual: bool) {
        if !self.config.enabled() || self.busy() || self.state == UpdaterState::Ready {
            return;
        }
        if manual {
            self.deferred_version = None;
            self.auto_download_failures = 0;
            self.auto_download_retry_after = None;
        }
        let cancel = Arc::new(AtomicBool::new(false));
        self.cancel_flag = Some(cancel.clone());
        self.state = UpdaterState::Checking;
        self.completion_notice = None;
        self.status_text = "正在检查更新…".into();

        let config = self.config.clone();
        let events = self.events.clone();
        let hwnd_val = window.0 as isize;
        let checked_epoch_secs = now_epoch_secs();
        std::thread::spawn(move || {
            let outcome = fetch_and_verify_manifest(&config, &cancel);
            if !cancel.load(Ordering::Acquire) {
                events.lock().unwrap().push(WorkerEvent::CheckFinished { manual, checked_epoch_secs, outcome });
                let _ = unsafe { PostMessageW(Some(HWND(hwnd_val as _)), wm_event, WPARAM(0), LPARAM(0)) };
            }
        });
    }

    pub fn start_download_and_stage(&mut self, window: HWND, wm_event: u32, automatic: bool, immediate_install: bool) {
        let Some(manifest) = self.manifest.clone() else {
            return;
        };
        if self.busy() || self.state == UpdaterState::Ready || self.manual_release_url.is_some() {
            return;
        }
        let Ok(exe) = std::env::current_exe() else {
            self.state = UpdaterState::Failed;
            self.status_text = "无法定位当前程序路径".into();
            return;
        };
        if !automatic {
            self.deferred_version = None;
            self.auto_download_failures = 0;
            self.auto_download_retry_after = None;
        }
        self.pending_immediate_install_version = immediate_install.then(|| manifest.version.clone());
        self.current_download_automatic = automatic;
        self.received_bytes = 0;
        self.total_bytes = 0;
        self.state = UpdaterState::Downloading;
        self.status_text =
            if automatic { format!("正在后台下载更新 {}…", manifest.version) } else { format!("正在下载更新 {}…", manifest.version) };

        let cancel = Arc::new(AtomicBool::new(false));
        self.cancel_flag = Some(cancel.clone());
        let config = self.config.clone();
        let events = self.events.clone();
        let hwnd_val = window.0 as isize;
        let root = updates_directory();

        std::thread::spawn(move || {
            let events_progress = events.clone();
            let events_verify = events.clone();
            let mut last_post = Instant::now() - Duration::from_secs(1);
            let outcome = stage_update(
                &manifest,
                &config,
                &exe,
                &root,
                &cancel,
                move |received, total| {
                    if received == total || last_post.elapsed() >= Duration::from_millis(80) {
                        last_post = Instant::now();
                        events_progress.lock().unwrap().push(WorkerEvent::DownloadProgress { received, total });
                        let _ = unsafe { PostMessageW(Some(HWND(hwnd_val as _)), wm_event, WPARAM(0), LPARAM(0)) };
                    }
                },
                move || {
                    events_verify.lock().unwrap().push(WorkerEvent::Verifying);
                    let _ = unsafe { PostMessageW(Some(HWND(hwnd_val as _)), wm_event, WPARAM(0), LPARAM(0)) };
                },
            );
            if !cancel.load(Ordering::Acquire) {
                events.lock().unwrap().push(WorkerEvent::StageFinished { automatic, outcome });
                let _ = unsafe { PostMessageW(Some(HWND(hwnd_val as _)), wm_event, WPARAM(0), LPARAM(0)) };
            }
        });
    }

    /// Returns `Ok(true)` when the installer process is ready and the main window must exit now.
    pub fn execute_install(&mut self, automatic: bool, ctx: WindowUpdateContext) -> Result<bool, String> {
        if self.state != UpdaterState::Ready || self.busy() {
            return Ok(false);
        }
        let Some(prepared) = self.prepared.as_ref() else {
            return Ok(false);
        };
        if automatic {
            let decision = self.evaluate_auto_decision(true, ctx.has_host_connection, ctx.viewer_count, ctx.has_blocking_prompt);
            if let policy::AutoInstallDecision::Blocked(reason) = decision {
                if let Some(msg) = reason.deferral_message(self.manifest.as_ref().map(|m| m.version.as_str()), true) {
                    self.status_text = msg;
                }
                return Ok(false);
            }
        } else if ctx.has_host_connection {
            let msg = "这台电脑正被远程控制，请先停止共享或等待对方断开后再安装更新";
            self.status_text = msg.into();
            return Err(msg.into());
        }

        let exe = std::env::current_exe().map_err(|e| format!("无法获取当前程序路径：{e}"))?;
        let launch_options =
            LaunchOptions { automatic, resume_host_sharing: ctx.is_sharing_enabled, minimize_on_launch: automatic && ctx.window_minimized_or_hidden };
        self.state = UpdaterState::Installing;
        self.status_text = if automatic {
            format!("正在自动安装 {}，QuietDesk 即将重新启动…", prepared.version)
        } else {
            format!("正在安装 {}，QuietDesk 即将重新启动…", prepared.version)
        };
        let cancel = AtomicBool::new(false);
        match launch_detached_installer(prepared, &exe, &updates_directory(), launch_options, &cancel) {
            Ok(pending) => {
                // Re-verify session remained idle during helper startup.
                if automatic {
                    let recheck = self.evaluate_auto_decision(true, ctx.has_host_connection, ctx.viewer_count, ctx.has_blocking_prompt);
                    if let policy::AutoInstallDecision::Blocked(reason) = recheck {
                        pending.abort();
                        self.state = UpdaterState::Ready;
                        self.status_text = reason
                            .deferral_message(self.manifest.as_ref().map(|m| m.version.as_str()), true)
                            .unwrap_or_else(|| "检测到活动会话，自动安装已推迟".into());
                        return Ok(false);
                    }
                }
                self.installation_handed_off = true;
                Ok(true)
            }
            Err(tag) if tag == "__ELEVATED_HANDOFF__" => {
                self.installation_handed_off = true;
                Ok(true)
            }
            Err(err) => {
                self.state = UpdaterState::Ready;
                self.status_text = err.clone();
                Err(err)
            }
        }
    }

    pub fn handle_worker_event(&mut self, event: WorkerEvent, settings: &mut super::settings::Settings) -> (bool, bool) {
        let mut save_settings = false;
        let mut trigger_immediate_install = false;
        match event {
            WorkerEvent::CheckFinished { manual, checked_epoch_secs, outcome } => {
                self.cancel_flag = None;
                match outcome {
                    Ok(VerificationResult::RequiresManualUpdate { release_notes_url, .. }) => {
                        if !manual {
                            settings.last_update_check = Some(checked_epoch_secs);
                            settings.last_failed_update_check = None;
                            save_settings = true;
                        }
                        self.manifest = None;
                        self.manual_release_url = Some(release_notes_url);
                        self.state = UpdaterState::Available;
                        self.status_text = "新版本需要前往 GitHub 手动下载升级".into();
                    }
                    Ok(VerificationResult::Supported(manifest)) => {
                        if !manual {
                            settings.last_update_check = Some(checked_epoch_secs);
                            settings.last_failed_update_check = None;
                            save_settings = true;
                        }
                        let arch = self.config.arch.unwrap_or(TargetArch::X64);
                        match manifest.assess(&self.config.current_version, self.config.current_build, arch) {
                            Ok(UpdateAvailability::Available) => {
                                if !policy::should_offer(&manifest.version, settings.skipped_update_version.as_deref(), manual) {
                                    self.manifest = None;
                                    self.state = UpdaterState::Idle;
                                    self.status_text = format!("当前版本 {}（已跳过 {}）", self.config.current_version, manifest.version);
                                } else {
                                    if self.manifest.as_ref().map(|m| &m.version) != Some(&manifest.version) {
                                        self.auto_download_failures = 0;
                                        self.auto_download_retry_after = None;
                                    }
                                    let size_mb = manifest.package_for(arch).map(|p| p.portable.size as f64 / (1024.0 * 1024.0)).unwrap_or(0.0);
                                    self.status_text = format!("发现新版本 {}（约 {:.1} MB）", manifest.version, size_mb);
                                    self.manual_release_url = None;
                                    self.manifest = Some(manifest);
                                    self.state = UpdaterState::Available;
                                }
                            }
                            Ok(UpdateAvailability::UpToDate) => {
                                self.manifest = None;
                                self.manual_release_url = None;
                                self.state = UpdaterState::UpToDate;
                                self.status_text = format!("已是最新版本（{}）", self.config.current_version);
                            }
                            Ok(UpdateAvailability::InconsistentBuild) | Err(_) => {
                                self.state = UpdaterState::Failed;
                                self.status_text = "更新版本与构建号校验不一致，请稍后重试".into();
                            }
                        }
                    }
                    Err(err) => {
                        if !manual {
                            settings.last_failed_update_check = Some(checked_epoch_secs);
                            save_settings = true;
                        }
                        self.state = UpdaterState::Failed;
                        self.status_text = err;
                    }
                }
            }
            WorkerEvent::DownloadProgress { received, total } => {
                if self.state == UpdaterState::Downloading {
                    self.received_bytes = received;
                    self.total_bytes = total;
                    let pct = if total > 0 { (received as f64 / total as f64 * 100.0).round() as u32 } else { 0 };
                    let ver = self.manifest.as_ref().map_or("", |m| m.version.as_str());
                    self.status_text = format!("正在下载 {ver}… {pct}%（{:.1} / {:.1} MB）", received as f64 / 1_048_576.0, total as f64 / 1_048_576.0);
                }
            }
            WorkerEvent::Verifying => {
                if self.state == UpdaterState::Downloading {
                    self.state = UpdaterState::Verifying;
                    self.status_text = "正在校验签名包与程序完整性…".into();
                }
            }
            WorkerEvent::StageFinished { automatic, outcome } => {
                self.cancel_flag = None;
                self.current_download_automatic = false;
                match outcome {
                    Ok(prepared) => {
                        let version = prepared.version.clone();
                        let elevated = prepared.requires_elevation();
                        self.prepared = Some(prepared);
                        self.state = UpdaterState::Ready;
                        self.auto_download_failures = 0;
                        self.auto_download_retry_after = None;
                        self.status_text = if elevated {
                            format!("更新 {version} 已校验就绪，点击“授权安装”完成升级")
                        } else {
                            format!("更新 {version} 已校验就绪，可安装并重启")
                        };
                        if self.pending_immediate_install_version.as_deref() == Some(version.as_str()) {
                            self.pending_immediate_install_version = None;
                            trigger_immediate_install = true;
                        }
                    }
                    Err(err) => {
                        self.pending_immediate_install_version = None;
                        self.state = UpdaterState::Failed;
                        if automatic {
                            self.auto_download_failures = self.auto_download_failures.saturating_add(1);
                            self.auto_download_retry_after = Some(Instant::now() + policy::download_retry_delay(self.auto_download_failures));
                        }
                        self.status_text = err;
                    }
                }
            }
        }
        (save_settings, trigger_immediate_install)
    }

    pub fn tick(&mut self, window: HWND, wm_event: u32, settings: &super::settings::Settings, ctx: WindowUpdateContext) -> bool {
        self.observe_remote_sessions(ctx.has_host_connection, ctx.viewer_count);
        if !self.config.enabled() || self.busy() {
            return false;
        }
        let now_secs = now_epoch_secs();
        if self.state != UpdaterState::Ready
            && policy::should_automatically_check(
                self.config.enabled(),
                settings.auto_check_updates,
                self.launched_at.elapsed(),
                now_secs,
                settings.last_update_check,
                settings.last_failed_update_check,
            )
        {
            self.start_check(window, wm_event, false);
            return false;
        }

        if !settings.auto_install_updates {
            return false;
        }
        let can_retry_download =
            self.state == UpdaterState::Failed && self.manifest.is_some() && self.auto_download_retry_after.is_some_and(|t| Instant::now() >= t);
        if self.state != UpdaterState::Ready && !(self.state == UpdaterState::Available && self.manifest.is_some()) && !can_retry_download {
            return false;
        }

        match self.evaluate_auto_decision(settings.auto_install_updates, ctx.has_host_connection, ctx.viewer_count, ctx.has_blocking_prompt) {
            policy::AutoInstallDecision::Proceed => {
                if self.state == UpdaterState::Ready {
                    self.execute_install(true, ctx).unwrap_or(false)
                } else {
                    self.start_download_and_stage(window, wm_event, true, false);
                    false
                }
            }
            policy::AutoInstallDecision::Blocked(reason) => {
                if reason.is_session_deferral()
                    && let Some(note) = reason.deferral_message(self.manifest.as_ref().map(|m| m.version.as_str()), self.state == UpdaterState::Ready)
                {
                    self.status_text = note;
                }
                false
            }
        }
    }

    fn evaluate_auto_decision(
        &self,
        auto_install_enabled: bool,
        has_host_connection: bool,
        viewer_count: usize,
        has_blocking_prompt: bool,
    ) -> policy::AutoInstallDecision {
        let needs_manual_or_elevated = self.manual_release_url.is_some() || self.prepared.as_ref().is_some_and(PreparedUpdate::requires_elevation);
        let deferred = self.manifest.as_ref().is_some_and(|m| self.deferred_version.as_deref() == Some(m.version.as_str()));
        policy::evaluate_auto_install(policy::AutoInstallContext {
            updater_enabled: self.config.enabled(),
            auto_install_enabled,
            has_host_connection,
            viewer_count,
            has_blocking_prompt,
            needs_manual_or_elevated_install: needs_manual_or_elevated,
            deferred_by_user: deferred,
            since_last_remote_session: self.last_remote_ended_at.map(|t| t.elapsed()),
        })
    }
}

impl Default for WindowUpdater {
    fn default() -> Self {
        Self::new()
    }
}

pub fn now_epoch_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;
    use quietdesk_core::update::{IMAGE_SUBSYSTEM_WINDOWS_GUI, WindowsArchPackages, build_portable_zip_for_testing, sha256_hex, sign_manifest_for_testing};
    use std::collections::BTreeMap;
    use std::io::Read;
    use std::net::TcpListener;

    fn synthetic_pe(arch: TargetArch) -> Vec<u8> {
        let mut out = vec![0u8; 0x80];
        out[0..2].copy_from_slice(b"MZ");
        out[0x3C..0x40].copy_from_slice(&(0x80u32).to_le_bytes());
        out.extend_from_slice(b"PE\0\0");
        out.extend_from_slice(&arch.pe_machine().to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&[0u8; 12]);
        out.extend_from_slice(&0x00F0u16.to_le_bytes());
        out.extend_from_slice(&0x0022u16.to_le_bytes());
        let mut opt = vec![0u8; 0xF0];
        opt[0..2].copy_from_slice(&0x020Bu16.to_le_bytes());
        opt[68..70].copy_from_slice(&IMAGE_SUBSYSTEM_WINDOWS_GUI.to_le_bytes());
        out.extend_from_slice(&opt);
        out.extend_from_slice(b"QUIETDESK-SYNTHETIC-V2");
        out
    }

    #[test]
    fn winhttp_stages_signed_loopback_update_and_performs_atomic_swap_with_rollback() {
        let arch = TargetArch::current().expect("supported target arch");
        let work = std::env::temp_dir().join(format!("quietdesk-win-update-test-{}", Uuid::new_v4()));
        fs::create_dir_all(&work).unwrap();

        let v1_exe_bytes = {
            let mut b = synthetic_pe(arch);
            b.extend_from_slice(b"-V1");
            b
        };
        let v2_exe_bytes = {
            let mut b = synthetic_pe(arch);
            b.extend_from_slice(b"-V2-UPDATED");
            b
        };
        let zip_bytes = build_portable_zip_for_testing(&[("QuietDesk.exe", &v2_exe_bytes), ("LICENSE", b"MIT\n"), ("THIRD-PARTY-OPUS.txt", b"Opus\n")]);

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        let mut packages = BTreeMap::new();
        packages.insert(
            arch.as_str().to_string(),
            WindowsArchPackages {
                portable: UpdateArchive {
                    url: format!("http://127.0.0.1:{port}/redirect-portable"),
                    size: zip_bytes.len() as u64,
                    sha256: sha256_hex(&zip_bytes),
                },
                installer: None,
            },
        );
        let manifest = WindowsUpdateManifest {
            schema: 1,
            app_id: "QuietDesk.Windows.Checks".into(),
            version: "0.8.0".into(),
            build: 31,
            published_at: "2026-11-23T09:00:00Z".into(),
            revision: "a".repeat(40),
            release_notes_url: "https://github.com/nXiaoK/QuietDesk/releases/tag/v0.8.0".into(),
            notes: Some("自动化更新检查".into()),
            packages,
        };
        let (pub_key, envelope_bytes) = sign_manifest_for_testing("test-key", &manifest);

        let serve_manifest = envelope_bytes.clone();
        let serve_zip = zip_bytes.clone();
        let stop_server = Arc::new(AtomicBool::new(false));
        let stop_clone = stop_server.clone();
        let server_thread = std::thread::spawn(move || {
            while !stop_clone.load(Ordering::Acquire) {
                let Ok((mut stream, _)) = listener.accept() else {
                    break;
                };
                let mut req = [0u8; 2048];
                let n = stream.read(&mut req).unwrap_or(0);
                let text = String::from_utf8_lossy(&req[..n]);
                let first_line = text.lines().next().unwrap_or("");
                let path = first_line.split_whitespace().nth(1).unwrap_or("/");
                let response = match path {
                    "/QuietDesk-windows-update.json" => format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", serve_manifest.len())
                        .into_bytes()
                        .into_iter()
                        .chain(serve_manifest.iter().copied())
                        .collect::<Vec<_>>(),
                    "/redirect-portable" => format!(
                        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{port}/QuietDesk-0.8.0-Windows.zip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    )
                    .into_bytes(),
                    "/QuietDesk-0.8.0-Windows.zip" => format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", serve_zip.len())
                        .into_bytes()
                        .into_iter()
                        .chain(serve_zip.iter().copied())
                        .collect::<Vec<_>>(),
                    "/unsafe-redirect" => {
                        b"HTTP/1.1 302 Found\r\nLocation: http://192.0.2.1/evil.zip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec()
                    }
                    _ => b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec(),
                };
                let _ = stream.write_all(&response);
            }
        });

        let config = UpdateConfig {
            app_id: "QuietDesk.Windows.Checks".into(),
            feed_url: format!("http://127.0.0.1:{port}/QuietDesk-windows-update.json"),
            repository: "nXiaoK/QuietDesk".into(),
            public_keys: vec![pub_key],
            current_version: "0.7.3".into(),
            current_build: 25,
            arch: Some(arch),
            allow_loopback: true,
        };
        assert!(config.enabled());

        let cancel = AtomicBool::new(false);
        let verified = fetch_and_verify_manifest(&config, &cancel).expect("WinHTTP fetch and Ed25519 verify");
        let VerificationResult::Supported(fetched_manifest) = verified else {
            panic!("expected supported manifest");
        };
        assert_eq!(fetched_manifest.version, "0.8.0");

        // Unsafe redirect to non-loopback HTTP must be refused.
        let unsafe_archive =
            UpdateArchive { url: format!("http://127.0.0.1:{port}/unsafe-redirect"), size: zip_bytes.len() as u64, sha256: sha256_hex(&zip_bytes) };
        assert!(download_verified_file(&unsafe_archive, &config, &work.join("rejected.zip"), &cancel, |_, _| {}).is_err(), "unsafe redirect must be rejected");

        let app_dir = work.join("app");
        fs::create_dir_all(&app_dir).unwrap();
        let app_exe = app_dir.join("QuietDesk.exe");
        fs::write(&app_exe, &v1_exe_bytes).unwrap();
        fs::write(app_dir.join("LICENSE"), b"OLD\n").unwrap();

        let updates_dir = work.join("updates");
        let mut saw_progress = false;
        let mut saw_verifying = false;
        let prepared = stage_update(
            &fetched_manifest,
            &config,
            &app_exe,
            &updates_dir,
            &cancel,
            |received, total| {
                if received == total && total > 0 {
                    saw_progress = true;
                }
            },
            || saw_verifying = true,
        )
        .expect("stage update over WinHTTP with 302 redirect");
        assert!(saw_progress && saw_verifying);

        // Spawn a short-lived dummy process so wait_for_process_exit observes an exited parent PID.
        let mut dummy = Command::new("cmd.exe").args(["/C", "exit", "0"]).creation_flags(CREATE_NO_WINDOW.0).spawn().unwrap();
        let dummy_pid = dummy.id();
        let _ = dummy.wait();

        let PreparedUpdateKind::PortableSwap { staged_exe, staging_dir } = &prepared.kind else {
            panic!("expected portable swap");
        };

        // Corrupt staged file first to verify automatic rollback leaves v1 untouched.
        let good_staged = fs::read(staged_exe).unwrap();
        fs::write(staged_exe, b"corrupt-not-pe").unwrap();
        let bad_plan_path = updates_dir.join("install-plan.json");
        let bad_plan = InstallPlan {
            parent_pid: dummy_pid,
            application_exe: app_exe.clone(),
            updates_dir: updates_dir.clone(),
            mode: InstallPlanMode::Portable {
                staged_exe: staged_exe.clone(),
                staging_dir: staging_dir.clone(),
                backup_exe: app_dir.join(".QuietDesk-update-backup-bad.exe"),
            },
            ready_file: updates_dir.join("installer-bad.ready"),
            result_file: updates_dir.join("install-result.json"),
            ack_file: updates_dir.join("installer-bad.ack"),
            version: "0.8.0".into(),
            build: 31,
            arch,
            reopen_after_install: false,
            launch_options: LaunchOptions { automatic: true, resume_host_sharing: true, minimize_on_launch: false },
        };
        atomic_write_json(&bad_plan, &bad_plan_path).unwrap();
        assert!(perform_installation(&bad_plan, &bad_plan_path, Duration::from_secs(5), Duration::from_secs(1)).is_err());
        assert_eq!(fs::read(&app_exe).unwrap(), v1_exe_bytes);

        // Restore valid staged executable and run full atomic swap + result consumption.
        fs::write(staged_exe, &good_staged).unwrap();
        let plan_path = updates_dir.join("install-plan.json");
        let plan = InstallPlan {
            parent_pid: dummy_pid,
            application_exe: app_exe.clone(),
            updates_dir: updates_dir.clone(),
            mode: InstallPlanMode::Portable {
                staged_exe: staged_exe.clone(),
                staging_dir: staging_dir.clone(),
                backup_exe: app_dir.join(".QuietDesk-update-backup-ok.exe"),
            },
            ready_file: updates_dir.join("installer-ok.ready"),
            result_file: updates_dir.join("install-result.json"),
            ack_file: updates_dir.join("installer-ok.ack"),
            version: "0.8.0".into(),
            build: 31,
            arch,
            reopen_after_install: false,
            launch_options: LaunchOptions { automatic: true, resume_host_sharing: true, minimize_on_launch: true },
        };
        atomic_write_json(&plan, &plan_path).unwrap();
        perform_installation(&plan, &plan_path, Duration::from_secs(5), Duration::from_secs(1)).expect("atomic swap succeeds");
        assert_eq!(fs::read(&app_exe).unwrap(), v2_exe_bytes);
        assert_eq!(fs::read(app_dir.join("LICENSE")).unwrap(), b"MIT\n");

        let consumed = consume_startup_result(&app_exe, &updates_dir, "0.8.0", 31).expect("consume result");
        assert!(consumed.succeeded);
        assert!(consumed.launch_options.resume_host_sharing);
        assert!(consumed.launch_options.minimize_on_launch);
        assert!(!app_dir.join(".QuietDesk-update-backup-ok.exe").exists());
        assert!(!staging_dir.exists());
        assert!(consume_startup_result(&app_exe, &updates_dir, "0.8.0", 31).is_none());

        stop_server.store(true, Ordering::Release);
        let _ = std::net::TcpStream::connect(("127.0.0.1", port));
        let _ = server_thread.join();
        let _ = fs::remove_dir_all(&work);
    }
}
