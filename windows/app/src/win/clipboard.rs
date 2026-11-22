//! Manual clipboard text and the native reads used by negotiated clipboard sessions.
use super::clipboard_image;
use super::clipboard_ole::Formats;
use super::util::{failed, wide};
use quietdesk_core::clipboard::{Kind, MAX_FILE_ENTRIES, MAX_PNG_BYTES, MAX_TEXT_BYTES, Payload};
use quietdesk_core::error::Result;
use std::ffi::OsString;
use std::os::windows::ffi::OsStringExt;
use std::path::PathBuf;
use windows::Win32::Foundation::*;
use windows::Win32::Globalization::{CP_ACP, MULTI_BYTE_TO_WIDE_CHAR_FLAGS, MultiByteToWideChar};
use windows::Win32::System::DataExchange::*;
use windows::Win32::System::Memory::*;
use windows::Win32::System::Ole::{CF_DIBV5, CF_HDROP, CF_UNICODETEXT};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, PWSTR, w};

pub(super) const MAX_DROP_BYTES: usize = 64 * 1024 * 1024;

pub(super) fn window() -> windows::core::Result<HWND> {
    unsafe {
        CreateWindowExW(WINDOW_EX_STYLE::default(), w!("STATIC"), PCWSTR::null(), WINDOW_STYLE::default(), 0, 0, 0, 0, Some(HWND_MESSAGE), None, None, None)
    }
}
struct Open;
impl Open {
    fn new(owner: Option<HWND>) -> windows::core::Result<Self> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(100);
        loop {
            match Self::try_open(owner) {
                Err(_) if std::time::Instant::now() < deadline => std::thread::sleep(std::time::Duration::from_millis(5)),
                result => return result,
            }
        }
    }
    fn try_open(owner: Option<HWND>) -> windows::core::Result<Self> {
        unsafe { OpenClipboard(owner) }.map(|()| Self)
    }
    fn data<T>(&self, format: u16, limit: usize, read: impl FnOnce(&[u8], HGLOBAL) -> Option<T>) -> Option<T> {
        unsafe {
            let h = HGLOBAL(GetClipboardData(u32::from(format)).ok()?.0);
            let size = GlobalSize(h);
            if size == 0 || size > limit {
                return None;
            }
            let ptr = GlobalLock(h);
            if ptr.is_null() {
                return None;
            }
            let result = read(std::slice::from_raw_parts(ptr.cast(), size), h);
            let _ = GlobalUnlock(h);
            result
        }
    }
}
impl Drop for Open {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseClipboard();
        }
    }
}
pub(super) fn clear_if(hwnd: HWND, owned: impl FnOnce() -> bool) -> Option<u32> {
    let _open = Open::new(Some(hwnd)).ok()?;
    if !owned() {
        return None;
    }
    let before = unsafe { GetClipboardSequenceNumber() };
    unsafe { EmptyClipboard() }.ok()?;
    Some(before)
}
fn read_text(clip: &Open) -> Option<String> {
    clip.data(CF_UNICODETEXT.0, MAX_TEXT_BYTES * 2 + 16, |bytes, _| {
        let units = bytes.as_chunks::<2>().0;
        let end = units.iter().position(|v| *v == [0, 0])?;
        if end == 0 {
            return None;
        }
        let s = String::from_utf16(&units[..end].iter().map(|u| u16::from_le_bytes(*u)).collect::<Vec<_>>()).ok()?;
        (s.len() <= MAX_TEXT_BYTES).then_some(s)
    })
}
pub fn text() -> Option<String> {
    read_text(&Open::new(None).ok()?)
}

fn store(format: u16, bytes: &[u8]) -> windows::core::Result<()> {
    unsafe {
        let memory = GlobalAlloc(GMEM_MOVEABLE, bytes.len())?;
        let ptr = GlobalLock(memory);
        let result = if ptr.is_null() {
            Err(windows::core::Error::from_thread())
        } else {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr.cast(), bytes.len());
            let _ = GlobalUnlock(memory);
            SetClipboardData(u32::from(format), Some(HANDLE(memory.0))).map(drop)
        };
        if result.is_err() {
            let _ = GlobalFree(Some(memory));
        }
        result
    }
}
pub fn set_text(text: &str) -> Result<()> {
    let units = wide(text);
    let hwnd = window().map_err(failed("创建剪贴板窗口"))?;
    let result = (|| {
        let formats = Formats::new()?;
        let _open = Open::new(Some(hwnd))?;
        unsafe {
            EmptyClipboard()?;
        }
        store(formats.marker, &1u32.to_le_bytes())?;
        store(formats.exclude, &1u32.to_le_bytes())?;
        store(CF_UNICODETEXT.0, unsafe { std::slice::from_raw_parts(units.as_ptr().cast(), std::mem::size_of_val(units.as_slice())) })
    })();
    unsafe {
        let _ = DestroyWindow(hwnd);
    }
    result.map_err(failed("写入剪贴板"))
}

fn available(format: u16) -> bool {
    unsafe { IsClipboardFormatAvailable(u32::from(format)).is_ok() }
}
fn local_kind(clip: &Open, f: Formats) -> Option<Kind> {
    if [f.marker, f.exclude, f.ignore].into_iter().any(available) {
        return None;
    }
    if [f.cloud, f.history]
        .into_iter()
        .any(|format| available(format) && !clip.data(format, 32, |bytes, _| Some(bytes.get(..4)? == [1, 0, 0, 0])).unwrap_or(false))
    {
        return None;
    }
    if available(CF_HDROP.0) {
        Some(Kind::Files)
    } else if available(f.png) || available(CF_DIBV5.0) {
        Some(Kind::Png)
    } else if available(CF_UNICODETEXT.0) {
        Some(Kind::Text)
    } else {
        None
    }
}
fn owner_pid(window: HWND) -> u32 {
    let mut pid = 0;
    unsafe { GetWindowThreadProcessId(window, Some(&mut pid)) };
    pid
}
fn process_image(pid: u32) -> Option<String> {
    use windows::Win32::System::Threading::{OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW};
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut path = [0u16; 1024];
        let mut len = path.len() as u32;
        let read = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, PWSTR(path.as_mut_ptr()), &mut len);
        let _ = CloseHandle(process);
        read.ok()?;
        String::from_utf16(&path[..len as usize]).ok()
    }
}
fn redirected() -> Option<bool> {
    let pid = owner_pid(unsafe { GetClipboardOwner().ok()? });
    if pid == unsafe { windows::Win32::System::Threading::GetCurrentProcessId() } {
        return Some(false);
    }
    let image = process_image(pid)?;
    let name = image.rsplit('\\').next()?;
    Some(["rdpclip.exe", "mstsc.exe", "msrdc.exe"].iter().any(|rdp| name.eq_ignore_ascii_case(rdp)))
}
fn roaming() -> bool {
    use windows::ApplicationModel::DataTransfer::Clipboard;
    Clipboard::GetContent().and_then(|x| x.Properties()).and_then(|p| p.IsFromRoamingClipboard()).unwrap_or(false)
}
pub(super) fn inspect(f: Formats) -> windows::core::Result<(u64, Option<Kind>)> {
    let before = unsafe { GetClipboardSequenceNumber() };
    let relayed = redirected() == Some(true) || roaming();
    let clip = Open::try_open(None)?;
    let token = unsafe { GetClipboardSequenceNumber() };
    if before != token {
        return Err(ERROR_RETRY.into());
    }
    Ok((u64::from(token), if relayed { None } else { local_kind(&clip, f) }))
}

pub(super) fn file_root_count(token: u64, f: Formats) -> Option<usize> {
    let clip = Open::new(None).ok()?;
    unsafe {
        if u64::from(GetClipboardSequenceNumber()) != token || f.virtual_files.into_iter().any(available) {
            return None;
        }
        // A live owner may implement CF_HDROP by fetching files during WM_RENDERFORMAT.
        // Leave third-party providers untouched until an actual pull.
        if let Ok(owner) = GetClipboardOwner() {
            let source = owner_pid(owner);
            let shell = owner_pid(GetShellWindow());
            if shell == 0 || source != shell && !process_image(source)?.eq_ignore_ascii_case(&process_image(shell)?) {
                return None;
            }
        }
        if available(f.shell_items) {
            // CIDA begins with the number of children followed by parent and child offsets.
            return clip.data(f.shell_items, MAX_DROP_BYTES, |bytes, _| {
                let count = u32::from_le_bytes(bytes.get(..4)?.try_into().ok()?) as usize;
                (count <= (bytes.len() / 4).saturating_sub(2)).then_some(count)
            });
        }
        clip.data(CF_HDROP.0, MAX_DROP_BYTES, |bytes, _| {
            let (names, wide) = drop_names(bytes)?;
            if wide { count_terminated(names.as_chunks::<2>().0, &[0, 0]) } else { count_terminated(names, &0) }
        })
    }
}

pub(super) fn read(token: u64, kind: Kind, f: Formats) -> Option<Payload> {
    let clip = Open::new(None).ok()?;
    if u64::from(unsafe { GetClipboardSequenceNumber() }) != token {
        return None;
    }
    match kind {
        Kind::Text => read_text(&clip).map(Payload::Text),
        Kind::Png => {
            if let Some(png) = clip.data(f.png, MAX_PNG_BYTES, |bytes, _| Some(bytes.to_vec())) {
                return Some(Payload::Png(png));
            }
            let dib = clip.data(CF_DIBV5.0, MAX_PNG_BYTES + 124, |bytes, _| Some(bytes.to_vec()))?;
            drop(clip);
            clipboard_image::dib_to_png(&dib).map(Payload::Png)
        }
        Kind::Files => clip.data(CF_HDROP.0, MAX_DROP_BYTES, |bytes, _| file_roots(bytes).map(Payload::Files)),
    }
}

fn drop_names(bytes: &[u8]) -> Option<(&[u8], bool)> {
    let header = bytes.get(..20)?;
    let offset = u32::from_le_bytes(header[..4].try_into().ok()?) as usize;
    let names = bytes.get(offset..)?;
    let wide = header[16..20] != [0, 0, 0, 0];
    (offset >= 20 && (!wide || offset.is_multiple_of(2))).then_some((names, wide))
}

fn count_terminated<T: PartialEq>(mut names: &[T], nul: &T) -> Option<usize> {
    let mut roots = 0;
    loop {
        let end = names.iter().position(|c| c == nul)?;
        if end == 0 {
            return Some(roots);
        }
        roots += 1;
        names = &names[end + 1..];
    }
}

fn file_roots(bytes: &[u8]) -> Option<Vec<PathBuf>> {
    let (names, wide) = drop_names(bytes)?;
    let mut paths = Vec::new();
    if wide {
        let mut names = names.as_chunks::<2>().0;
        loop {
            let n = names.iter().position(|u| *u == [0, 0])?;
            if n == 0 {
                break;
            }
            if n >= 32768 || paths.len() == MAX_FILE_ENTRIES {
                return None;
            }
            let units: Vec<_> = names[..n].iter().map(|u| u16::from_le_bytes(*u)).collect();
            paths.push(PathBuf::from(OsString::from_wide(&units)));
            names = &names[n + 1..];
        }
    } else {
        let mut names = names;
        loop {
            let n = names.iter().position(|u| *u == 0)?;
            if n == 0 {
                break;
            }
            if n >= 32768 || paths.len() == MAX_FILE_ENTRIES {
                return None;
            }
            let mut units = vec![0; n];
            let count = unsafe { MultiByteToWideChar(CP_ACP, MULTI_BYTE_TO_WIDE_CHAR_FLAGS(0), &names[..n], Some(&mut units)) };
            if count <= 0 {
                return None;
            }
            paths.push(PathBuf::from(OsString::from_wide(&units[..count as usize])));
            names = &names[n + 1..];
        }
    }
    (!paths.is_empty()).then_some(paths)
}
#[cfg(test)]
pub(super) fn external_files(paths: &[PathBuf], virtual_content: bool) {
    unsafe {
        let hwnd = window().unwrap();
        let open = Open::new(Some(hwnd)).unwrap();
        EmptyClipboard().unwrap();
        if !paths.is_empty() {
            let Some(super::clipboard_ole::Rendered::Files(bytes)) = super::clipboard_ole::Rendered::build(Payload::Files(paths.to_vec())) else { panic!() };
            store(CF_HDROP.0, &bytes).unwrap();
        }
        if virtual_content {
            let format = RegisterClipboardFormatW(w!("FileContents"));
            store(u16::try_from(format).unwrap(), b"virtual data").unwrap();
        }
        drop(open);
        DestroyWindow(hwnd).unwrap();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn eager_drop_counts_wide_and_ansi_roots_without_decoding_names() {
        assert_eq!(count_terminated(&[[0, 0xd8], [0, 0], [0xac, 0], [0, 0], [0, 0]], &[0, 0]), Some(2));
        assert_eq!(count_terminated(&[0xff, 0, 80, 0, 0], &0), Some(2));
        assert_eq!(count_terminated(&[b'a', 0], &0), None);
    }
    #[test]
    #[ignore = "requires the disposable Wine/Xvfb clipboard"]
    fn clipboard_native_manual_read_survives_another_listener() {
        assert_eq!(std::env::var("QUIETDESK_ISOLATED_CLIPBOARD_CHECK").as_deref(), Ok("1"));
        set_text("local clipboard observer").unwrap();
        let (locked, gate) = std::sync::mpsc::channel();
        let observer = std::thread::spawn(move || {
            let hwnd = window().unwrap();
            let open = Open::new(Some(hwnd)).unwrap();
            locked.send(()).unwrap();
            std::thread::sleep(std::time::Duration::from_millis(55));
            drop(open);
            unsafe {
                DestroyWindow(hwnd).unwrap();
            }
        });
        gate.recv().unwrap();
        assert!(Open::try_open(None).is_err(), "the competing owner holds the clipboard");
        assert_eq!(text().as_deref(), Some("local clipboard observer"));
        observer.join().unwrap();
    }
}
