use quietdesk_core::DeskError;
use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx, CoUninitialize};

/// A NUL-terminated UTF-16 copy for Win32 calls.
pub fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

pub fn from_wide(text: &[u16]) -> String {
    String::from_utf16_lossy(&text[..text.iter().position(|unit| *unit == 0).unwrap_or(text.len())])
}

/// A system failure with the step that hit it, for the user and the log.
pub fn failed(step: &str) -> impl Fn(windows::core::Error) -> DeskError + '_ {
    move |error| DeskError::platform(format!("{step}失败：{}（0x{:08X}）", error.message().trim(), error.code().0))
}

/// COM for the current thread, released when dropped.
pub struct Com;

impl Com {
    pub fn enter() -> Self {
        // A thread already initialised another way keeps working for the free-threaded objects used here.
        let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        Self
    }
}

impl Drop for Com {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}
