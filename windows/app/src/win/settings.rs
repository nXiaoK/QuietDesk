//! What the application remembers between runs, in `%APPDATA%\QuietDesk\settings.json`. Pairing codes
//! are stored encrypted for the current Windows account (DPAPI).

use super::util::failed;
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::keymap::{MacModifierMapping, PcModifierMapping};
use quietdesk_core::messages::StreamSettings;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use windows::Win32::Foundation::{HLOCAL, LocalFree};
use windows::Win32::Security::Cryptography::{CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData};

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
    /// The pairing code, protected for this account.
    pub code: String,
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
    pub caps_forwarding: bool,
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
            caps_forwarding: false,
            mac_modifiers: MacModifierMapping::default(),
            pc_modifiers: PcModifierMapping::default(),
            connections: Vec::new(),
        }
    }
}

pub fn data_directory() -> PathBuf {
    PathBuf::from(std::env::var_os("APPDATA").unwrap_or_else(|| ".".into())).join("QuietDesk")
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

    /// Puts a connection first in the recent list, replacing an entry for the same address and port.
    pub fn remember(&mut self, connection: Connection) {
        self.connections.retain(|known| !(known.address.eq_ignore_ascii_case(&connection.address) && known.port == connection.port));
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

    #[test]
    fn older_settings_enable_reconnect_and_keep_saved_connections() {
        let json = r#"{"port":49123,"hostCode":"test-host","connections":[{"address":"example.invalid","port":49124,"name":"测试电脑","code":"test-code"}]}"#;
        let mut settings: Settings = serde_json::from_str(json).unwrap();
        assert!(settings.auto_reconnect);
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
