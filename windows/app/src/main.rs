//! QuietDesk for Windows: shares this PC with, or controls, a machine running QuietDesk.
#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
fn main() {
    quietdesk_windows::win::ui::run();
}

#[cfg(not(windows))]
fn main() {
    eprintln!("QuietDesk for Windows only runs on Windows; build it with scripts/build-windows.sh.");
    std::process::exit(1);
}
