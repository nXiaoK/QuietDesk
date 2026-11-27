//! What the application remembers between runs, in `%APPDATA%\QuietDesk\settings.json`. Pairing codes
//! are stored encrypted for the current Windows account (DPAPI).

use super::util::failed;
use quietdesk_core::PairingKey;
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::keymap::{MacModifierMapping, PcModifierMapping};
use quietdesk_core::messages::StreamSettings;
use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use uuid::Uuid;
use windows::Win32::Foundation::{HLOCAL, LocalFree};
use windows::Win32::Security::Cryptography::{CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData};
use windows::Win32::Storage::FileSystem::{MOVEFILE_WRITE_THROUGH, MoveFileExW};
use windows::core::PCWSTR;

/// The most this PC encodes for a viewer: longest edge, frames per second, megabits per second.
pub const QUALITY_LIMITS: [(&str, StreamSettings); 3] = [
    ("流畅（1920 / 60 fps / 20 Mbps）", StreamSettings::new(1920, 60, 20)),
    ("均衡（2560 / 60 fps / 30 Mbps）", StreamSettings::new(2560, 60, 30)),
    ("高清（3840 / 60 fps / 50 Mbps）", StreamSettings::new(3840, 60, 50)),
];

/// What this PC asks a host for.
pub const VIEWER_QUALITIES: [(&str, StreamSettings); 4] = [
    ("省流（1280 / 30 fps / 3 Mbps）", StreamSettings::new(1280, 30, 3)),
    ("流畅（1920 / 30 fps / 8 Mbps）", StreamSettings::new(1920, 30, 8)),
    ("均衡（1920 / 60 fps / 12 Mbps）", StreamSettings::new(1920, 60, 12)),
    ("高清（2560 / 60 fps / 20 Mbps）", StreamSettings::new(2560, 60, 20)),
];

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Connection {
    pub address: String,
    pub port: u16,
    pub name: String,
    #[serde(rename = "deviceID", default, skip_serializing_if = "Option::is_none")]
    pub device_id: Option<Uuid>,
    /// The pairing code, protected for this account.
    pub code: String,
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub port: u16,
    /// This PC's pairing code, protected for this account.
    pub host_code: Option<String>,
    pub allow_control: bool,
    pub clipboard: bool,
    pub quality_limit: usize,
    pub shared_display: Option<u32>,
    pub viewer_quality: usize,
    pub auto_reconnect: bool,
    pub tailscale_enabled: bool,
    pub caps_forwarding: bool,
    #[serde(default = "default_true")]
    pub auto_check_updates: bool,
    #[serde(default)]
    pub auto_install_updates: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skipped_update_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_update_check: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_failed_update_check: Option<u64>,
    pub mac_modifiers: MacModifierMapping,
    pub pc_modifiers: PcModifierMapping,
    pub connections: Vec<Connection>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            port: 5908,
            host_code: None,
            allow_control: true,
            clipboard: true,
            quality_limit: 1,
            shared_display: None,
            viewer_quality: 2,
            auto_reconnect: true,
            tailscale_enabled: false,
            caps_forwarding: false,
            auto_check_updates: true,
            auto_install_updates: false,
            skipped_update_version: None,
            last_update_check: None,
            last_failed_update_check: None,
            mac_modifiers: MacModifierMapping::default(),
            pc_modifiers: PcModifierMapping::default(),
            connections: Vec::new(),
        }
    }
}

pub fn data_directory() -> PathBuf {
    PathBuf::from(std::env::var_os("APPDATA").unwrap_or_else(|| ".".into())).join("QuietDesk")
}

#[derive(Serialize, Deserialize)]
struct DeviceIdentityFile {
    version: u32,
    id: Uuid,
}

const IDENTITY_FILE: &str = "device-identity.json";
const MAX_IDENTITY_BYTES: u64 = 4096;

fn read_device_id(path: &Path) -> io::Result<Uuid> {
    let mut bytes = Vec::new();
    std::fs::File::open(path)?.take(MAX_IDENTITY_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_IDENTITY_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "设备标识文件过大"));
    }
    let doc: DeviceIdentityFile = serde_json::from_slice(&bytes)?;
    if doc.version != 1 || doc.id.is_nil() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "设备标识文件版本或 UUID 无效"));
    }
    Ok(doc.id)
}

fn load_device_id(directory: &Path) -> io::Result<Uuid> {
    match read_device_id(&directory.join(IDENTITY_FILE)) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        result => return result,
    }
    std::fs::create_dir_all(directory)?;
    let directory = directory.canonicalize()?;
    let path = directory.join(IDENTITY_FILE);
    let id = Uuid::new_v4();
    let temporary = directory.join(format!(".device-identity-{id}.tmp"));
    let mut file = std::fs::File::create_new(&temporary)?;
    let publish = || -> io::Result<()> {
        serde_json::to_writer(&mut file, &DeviceIdentityFile { version: 1, id })?;
        file.flush()?;
        file.sync_all()?;
        drop(file);
        let native = |p: &Path| p.as_os_str().encode_wide().chain(Some(0)).collect::<Vec<_>>();
        let (source, destination) = (native(&temporary), native(&path));
        // Without REPLACE_EXISTING, at most one complete document wins concurrent first launches.
        unsafe { MoveFileExW(PCWSTR(source.as_ptr()), PCWSTR(destination.as_ptr()), MOVEFILE_WRITE_THROUGH) }?;
        Ok(())
    };
    match publish() {
        Ok(()) => Ok(id),
        Err(error) => {
            let _ = std::fs::remove_file(&temporary);
            match read_device_id(&path) {
                Err(read) if read.kind() == io::ErrorKind::NotFound => Err(error),
                winner => winner,
            }
        }
    }
}

/// Per-user identity on this PC. Roaming the settings to another PC must not copy its device ID.
pub fn local_device_id() -> Option<Uuid> {
    let directory = PathBuf::from(std::env::var_os("LOCALAPPDATA")?);
    if !directory.is_absolute() {
        return None;
    }
    load_device_id(&directory.join("QuietDesk")).map_err(|error| log::warn!("local device identity unavailable: {error}")).ok()
}

impl Settings {
    fn path() -> PathBuf {
        data_directory().join("settings.json")
    }

    /// The stored settings; a missing file gives the defaults, an unreadable one is kept and reported.
    pub fn load() -> Self {
        match std::fs::read_to_string(Self::path()) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_else(|error| {
                log::error!("settings.json could not be read and is left untouched until settings change: {error}");
                Self::default()
            }),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self) -> Result<()> {
        let path = Self::path();
        let write = || -> std::io::Result<()> {
            std::fs::create_dir_all(data_directory())?;
            let temporary = path.with_extension("json.new");
            std::fs::write(&temporary, serde_json::to_vec_pretty(self)?)?;
            std::fs::rename(&temporary, &path)
        };
        write().map_err(|error| DeskError::platform(format!("无法保存设置：{error}")))
    }

    pub fn quality_limit(&self) -> StreamSettings {
        QUALITY_LIMITS[self.quality_limit.min(QUALITY_LIMITS.len() - 1)].1
    }

    pub fn viewer_quality(&self) -> StreamSettings {
        VIEWER_QUALITIES[self.viewer_quality.min(VIEWER_QUALITIES.len() - 1)].1
    }

    /// Updates an endpoint on connection. Across endpoints, an identity matches only with the same pairing key.
    pub fn remember(&mut self, mut connection: Connection) {
        let read_key = |stored: &str| unprotect(stored).and_then(|code| PairingKey::parse(&code).ok());
        let key = read_key(&connection.code);
        let advertised = connection.device_id;
        let embedded = super::tailnet::ViewerTarget::embedded_host(&connection.address).is_some();
        self.connections.retain(|known| {
            let endpoint = known.address.eq_ignore_ascii_case(&connection.address) && known.port == connection.port;
            let same_route = embedded == super::tailnet::ViewerTarget::embedded_host(&known.address).is_some();
            let same_id = same_route && advertised.is_some() && known.device_id == advertised;
            if !same_id && !endpoint {
                return true;
            }
            let same_key = key.as_ref().is_some_and(|key| read_key(&known.code).as_ref() == Some(key));
            if endpoint && connection.device_id.is_none() && same_key {
                connection.device_id = known.device_id;
            }
            !endpoint && !(same_id && same_key)
        });
        self.connections.insert(0, connection);
        self.connections.truncate(12);
    }
}

unsafe fn transform(input: &[u8], protect: bool) -> windows::core::Result<Vec<u8>> {
    unsafe {
        let source = CRYPT_INTEGER_BLOB { cbData: input.len() as u32, pbData: input.as_ptr().cast_mut() };
        let mut output = CRYPT_INTEGER_BLOB::default();
        if protect {
            CryptProtectData(&source, None, None, None, None, CRYPTPROTECT_UI_FORBIDDEN, &mut output)?;
        } else {
            CryptUnprotectData(&source, None, None, None, None, CRYPTPROTECT_UI_FORBIDDEN, &mut output)?;
        }
        let bytes = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        LocalFree(Some(HLOCAL(output.pbData.cast())));
        Ok(bytes)
    }
}

/// A pairing code encrypted for the current account, as hexadecimal text.
pub fn protect(code: &str) -> Result<String> {
    let protected = unsafe { transform(code.as_bytes(), true) }.map_err(failed("加密配对码"))?;
    Ok(protected.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub fn unprotect(stored: &str) -> Option<String> {
    let bytes: Option<Vec<u8>> = stored.as_bytes().chunks(2).map(|pair| u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok()).collect();
    String::from_utf8(unsafe { transform(&bytes?, false) }.ok()?).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TemporaryDirectory(PathBuf);

    impl TemporaryDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("quietdesk-identity-test-{}", Uuid::new_v4()));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TemporaryDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn concurrent_first_launches_publish_one_reloadable_identity() {
        let directory = TemporaryDirectory::new();
        let start = std::sync::Barrier::new(8);
        let ids = std::thread::scope(|scope| {
            let readers: Vec<_> = (0..8)
                .map(|_| {
                    scope.spawn(|| {
                        start.wait();
                        load_device_id(&directory.0).unwrap()
                    })
                })
                .collect();
            readers.into_iter().map(|t| t.join().unwrap()).collect::<Vec<_>>()
        });
        let saved = load_device_id(&directory.0).unwrap();
        assert!(ids.iter().all(|id| *id == saved));
        assert!(!saved.is_nil());
        assert_eq!(std::fs::read_dir(&directory.0).unwrap().count(), 1);
    }

    #[test]
    fn damaged_unknown_and_oversized_identity_files_are_preserved() {
        let directory = TemporaryDirectory::new();
        let path = directory.0.join(IDENTITY_FILE);
        let document = serde_json::to_vec(&DeviceIdentityFile { version: 2, id: Uuid::new_v4() }).unwrap();
        let mut oversized = serde_json::to_vec(&DeviceIdentityFile { version: 1, id: Uuid::new_v4() }).unwrap();
        oversized.resize(MAX_IDENTITY_BYTES as usize + 1, b' ');
        for bytes in [b"{".to_vec(), document, oversized] {
            std::fs::write(&path, &bytes).unwrap();
            assert!(load_device_id(&directory.0).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
        }
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert!(load_device_id(&directory.0).is_err());
        assert!(path.is_dir());
    }

    fn connection(address: &str, id: Option<Uuid>, key: u8) -> Connection {
        let pairing = PairingKey::from_bytes([key; 32]);
        Connection { address: address.into(), port: 5908, name: "测试".into(), device_id: id, code: protect(&pairing.code()).unwrap() }
    }

    #[test]
    fn an_authenticated_identity_deduplicates_only_records_with_its_pairing_key() {
        let id = Some(Uuid::new_v4());
        let mut settings = Settings::default();
        settings.connections.extend([
            connection("moved.example", id, 1),
            connection("tailscale:100.68.2.3", id, 1),
            connection("old-address.example", id, 1),
            connection("copied-id.example", id, 2),
            connection("different-id.example", Some(Uuid::new_v4()), 1),
        ]);
        let mut unreadable = connection("unreadable.example", id, 1);
        unreadable.code = "damaged".into();
        settings.connections.push(unreadable);
        settings.remember(connection("new.example", id, 1));
        let addresses: Vec<_> = settings.connections.iter().map(|c| c.address.as_str()).collect();
        assert_eq!(addresses, ["new.example", "tailscale:100.68.2.3", "copied-id.example", "different-id.example", "unreadable.example"]);
    }

    #[test]
    fn legacy_endpoint_retains_identity_only_when_its_credentials_match() {
        let id = Some(Uuid::new_v4());
        let mut settings = Settings::default();
        settings.remember(connection("HOST.example", id, 1));
        settings.remember(connection("host.example", None, 1));
        assert_eq!(settings.connections.len(), 1);
        assert_eq!(settings.connections[0].device_id, id);
        settings.remember(connection("host.example", None, 2));
        assert_eq!(settings.connections.len(), 1);
        assert_eq!(settings.connections[0].device_id, None);
    }

    #[test]
    fn older_settings_enable_reconnect_and_keep_saved_connections() {
        let json = r#"{"port":49123,"hostCode":"test-host","connections":[{"address":"example.invalid","port":49124,"name":"测试电脑","code":"test-code"}]}"#;
        let mut settings: Settings = serde_json::from_str(json).unwrap();
        assert!(settings.auto_reconnect);
        assert!(!settings.tailscale_enabled);
        assert!(!settings.caps_forwarding);
        assert_eq!(settings.port, 49123);
        settings.auto_reconnect = false;
        settings.caps_forwarding = true;
        let saved: Settings = serde_json::from_str(&serde_json::to_string(&settings).unwrap()).unwrap();
        assert!(!saved.auto_reconnect);
        assert!(saved.caps_forwarding);
        assert_eq!(saved.host_code.as_deref(), Some("test-host"));
        assert_eq!(saved.connections.len(), 1);
        assert_eq!(saved.connections[0].port, 49124);
        assert_eq!(saved.connections[0].code, "test-code");
    }
}
