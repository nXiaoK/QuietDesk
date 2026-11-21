//! The clipboard's text.

use super::util::{failed, from_wide, wide};
use quietdesk_core::error::{DeskError, Result};
use windows::Win32::Foundation::{HANDLE, HGLOBAL};
use windows::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData};
use windows::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock};

const CF_UNICODETEXT: u32 = 13;

pub fn text() -> Option<String> {
    unsafe {
        OpenClipboard(None).ok()?;
        let text = GetClipboardData(CF_UNICODETEXT).ok().and_then(|handle| {
            let memory = HGLOBAL(handle.0);
            let data = GlobalLock(memory) as *const u16;
            if data.is_null() {
                return None;
            }
            let text = from_wide(std::slice::from_raw_parts(data, GlobalSize(memory) / 2));
            let _ = GlobalUnlock(memory);
            Some(text)
        });
        let _ = CloseClipboard();
        text.filter(|text| !text.is_empty())
    }
}

pub fn set_text(text: &str) -> Result<()> {
    let units = wide(text);
    unsafe {
        OpenClipboard(None).map_err(failed("打开剪贴板"))?;
        let stored = (|| {
            EmptyClipboard()?;
            let memory = GlobalAlloc(GMEM_MOVEABLE, units.len() * 2)?;
            let data = GlobalLock(memory) as *mut u16;
            if data.is_null() {
                return Err(windows::core::Error::from_thread());
            }
            std::ptr::copy_nonoverlapping(units.as_ptr(), data, units.len());
            let _ = GlobalUnlock(memory);
            // The clipboard owns the memory once it has been handed over.
            SetClipboardData(CF_UNICODETEXT, Some(HANDLE(memory.0))).map(drop)
        })();
        let _ = CloseClipboard();
        stored.map_err(failed("写入剪贴板"))
    }
    .map_err(|error: DeskError| error)
}
