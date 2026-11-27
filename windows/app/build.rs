//! Gives the executable the product version of `version.json` (or of a release build's environment),
//! build-time signed update feed configuration from `Resources/update-feed.json`, its icon, and the
//! manifest that selects modern controls and per-monitor DPI awareness.

const PRODUCTION_APP_ID: &str = "QuietDesk.Windows";
const MAC_FEED_SUFFIX: &str = "/releases/latest/download/QuietDesk-update.json";
const WIN_FEED_SUFFIX: &str = "/releases/latest/download/QuietDesk-windows-update.json";

fn decode_base64_len(input: &str) -> Option<usize> {
    let bytes = input.as_bytes();
    if bytes.is_empty() || !bytes.len().is_multiple_of(4) {
        return None;
    }
    let chunks = bytes.as_chunks::<4>().0;
    for (idx, chunk) in chunks.iter().enumerate() {
        let last = idx + 1 == chunks.len();
        for (pos, &b) in chunk.iter().enumerate() {
            let valid = b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || (b == b'=' && last && pos >= 2);
            if !valid {
                return None;
            }
        }
        if chunk[2] == b'=' && chunk[3] != b'=' {
            return None;
        }
    }
    let padding = bytes.iter().rev().take_while(|&&b| b == b'=').count();
    Some(bytes.len() / 4 * 3 - padding)
}

fn configure_update_source() -> (String, String, String) {
    let app_id = std::env::var("QUIETDESK_WINDOWS_APP_ID").unwrap_or_else(|_| PRODUCTION_APP_ID.to_string());
    assert!(!app_id.is_empty() && app_id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_')), "Invalid QUIETDESK_WINDOWS_APP_ID");
    let feed_override = std::env::var("QUIETDESK_WINDOWS_UPDATE_FEED_URL").ok();
    let keys_override = std::env::var("QUIETDESK_UPDATE_PUBLIC_KEYS").ok();

    let (feed_url, keys_value) = if app_id == PRODUCTION_APP_ID {
        assert!(feed_override.is_none() && keys_override.is_none(), "Update feed overrides require a non-production QUIETDESK_WINDOWS_APP_ID");
        let raw = std::fs::read_to_string("../../Resources/update-feed.json").expect("read Resources/update-feed.json");
        let parsed: serde_json::Value = serde_json::from_str(&raw).expect("parse Resources/update-feed.json");
        let mac_feed = parsed["feedURL"].as_str().unwrap_or_default();
        let win_feed = if mac_feed.is_empty() {
            String::new()
        } else if let Some(prefix) = mac_feed.strip_suffix(MAC_FEED_SUFFIX) {
            format!("{prefix}{WIN_FEED_SUFFIX}")
        } else if mac_feed.ends_with(WIN_FEED_SUFFIX) {
            mac_feed.to_string()
        } else {
            panic!("Unexpected feedURL in Resources/update-feed.json: {mac_feed}");
        };
        (win_feed, parsed["publicKeys"].clone())
    } else {
        let feed = feed_override.unwrap_or_default();
        let keys = match keys_override {
            Some(text) if !text.trim().is_empty() => serde_json::from_str(&text).expect("parse QUIETDESK_UPDATE_PUBLIC_KEYS"),
            _ => serde_json::Value::Array(Vec::new()),
        };
        (feed, keys)
    };

    let keys_array = keys_value.as_array().expect("update publicKeys must be an array");
    let mut ids = std::collections::HashSet::new();
    for item in keys_array {
        let id = item["id"].as_str().expect("update public key id must be a string");
        let key = item["key"].as_str().expect("update public key must be a string");
        assert!(
            !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_')) && ids.insert(id),
            "Invalid or duplicate update public key ID: {id}"
        );
        assert_eq!(decode_base64_len(key), Some(32), "Update public key {id} must decode to 32 bytes");
    }
    if !keys_array.is_empty() {
        assert!(!feed_url.is_empty(), "Enabled update public keys require a feed URL");
    }
    if !feed_url.is_empty() {
        let loopback = app_id != PRODUCTION_APP_ID && (feed_url.starts_with("http://127.0.0.1") || feed_url.starts_with("http://localhost"));
        let github = feed_url.starts_with("https://github.com/") && feed_url.ends_with(WIN_FEED_SUFFIX) && !feed_url.contains('?') && !feed_url.contains('#');
        assert!(github || loopback, "Unsafe Windows update feed URL: {feed_url}");
    }
    let keys_json = serde_json::to_string(keys_array).expect("serialize update public keys");
    (app_id, feed_url, keys_json)
}

fn main() {
    println!("cargo:rerun-if-changed=resources");
    println!("cargo:rerun-if-changed=../../version.json");
    println!("cargo:rerun-if-changed=../../Resources/update-feed.json");
    println!("cargo:rerun-if-env-changed=QUIETDESK_VERSION");
    println!("cargo:rerun-if-env-changed=QUIETDESK_BUILD_NUMBER");
    println!("cargo:rerun-if-env-changed=QUIETDESK_WINDOWS_APP_ID");
    println!("cargo:rerun-if-env-changed=QUIETDESK_WINDOWS_UPDATE_FEED_URL");
    println!("cargo:rerun-if-env-changed=QUIETDESK_UPDATE_PUBLIC_KEYS");

    let recorded: serde_json::Value = std::fs::read_to_string("../../version.json").ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default();
    let version = std::env::var("QUIETDESK_VERSION").ok().or_else(|| recorded["version"].as_str().map(str::to_string)).unwrap_or_else(|| "0.0.0".to_string());
    let build =
        std::env::var("QUIETDESK_BUILD_NUMBER").ok().or_else(|| recorded["build"].as_u64().map(|build| build.to_string())).unwrap_or_else(|| "0".to_string());
    let (app_id, feed_url, keys_json) = configure_update_source();

    println!("cargo:rustc-env=QUIETDESK_VERSION={version}");
    println!("cargo:rustc-env=QUIETDESK_BUILD_NUMBER={build}");
    println!("cargo:rustc-env=QUIETDESK_WINDOWS_APP_ID={app_id}");
    println!("cargo:rustc-env=QUIETDESK_WINDOWS_UPDATE_FEED_URL={feed_url}");
    println!("cargo:rustc-env=QUIETDESK_UPDATE_PUBLIC_KEYS_JSON={keys_json}");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        println!("cargo:rerun-if-changed=../../tailnet");
        let arch = match std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
            Ok("x86_64") => "amd64",
            Ok("aarch64") => "arm64",
            other => panic!("Unsupported Windows target architecture: {other:?}"),
        };
        let helper = std::path::PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo output directory")).join("QuietDeskTailnet.exe");
        let status = std::process::Command::new("go")
            .current_dir("../../tailnet")
            .env("CGO_ENABLED", "0")
            .env("GOOS", "windows")
            .env("GOARCH", arch)
            .args(["build", "-mod=readonly", "-trimpath", "-buildvcs=false", "-tags", "ts_omit_logtail", "-ldflags=-s -w", "-o"])
            .arg(helper)
            .arg(".")
            .status()
            .expect("building the embedded Tailscale node requires Go");
        assert!(status.success(), "building the embedded Tailscale node failed");
        embed_resource::compile("resources/app.rc", embed_resource::NONE).manifest_required().expect("the application resources compile");
    }
}
