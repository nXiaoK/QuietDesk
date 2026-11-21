//! Gives the executable the product version of `version.json` (or of a release build's environment),
//! its icon, and the manifest that selects modern controls and per-monitor DPI awareness.

fn main() {
    println!("cargo:rerun-if-changed=resources");
    println!("cargo:rerun-if-changed=../../version.json");
    println!("cargo:rerun-if-env-changed=QUIETDESK_VERSION");
    println!("cargo:rerun-if-env-changed=QUIETDESK_BUILD_NUMBER");
    let recorded: serde_json::Value = std::fs::read_to_string("../../version.json").ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default();
    let version = std::env::var("QUIETDESK_VERSION").ok().or_else(|| recorded["version"].as_str().map(str::to_string)).unwrap_or_else(|| "0.0.0".to_string());
    let build =
        std::env::var("QUIETDESK_BUILD_NUMBER").ok().or_else(|| recorded["build"].as_u64().map(|build| build.to_string())).unwrap_or_else(|| "0".to_string());
    println!("cargo:rustc-env=QUIETDESK_VERSION={version}");
    println!("cargo:rustc-env=QUIETDESK_BUILD_NUMBER={build}");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        embed_resource::compile("resources/app.rc", embed_resource::NONE).manifest_required().expect("the application resources compile");
    }
}
