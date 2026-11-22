//! OLE clipboard formats and the object retained by consumers while a paste is pending.
use super::{clipboard_image, util::wide};
use quietdesk_core::clipboard::{Input, Kind, Payload, Revision};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use std::time::{Duration, Instant};
use tokio::sync::mpsc::Sender;
use windows::Win32::Foundation::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::DataExchange::{GetClipboardOwner, RegisterClipboardFormatW};
use windows::Win32::System::Memory::*;
use windows::Win32::System::Ole::{CF_DIBV5, CF_HDROP, CF_UNICODETEXT};
use windows::Win32::System::Threading::{CreateEventW, SetEvent};
use windows::Win32::UI::Shell::SHCreateStdEnumFmtEtc;
use windows::core::{BOOL, HRESULT, Interface, Ref, Result, implement, w};

#[derive(Clone, Copy)]
pub(super) struct Formats {
    pub png: u16,
    pub virtual_files: [u16; 3],
    pub shell_items: u16,
    pub marker: u16,
    pub exclude: u16,
    pub ignore: u16,
    pub cloud: u16,
    pub history: u16,
}

impl Formats {
    pub fn new() -> Result<Self> {
        let register = |name| u16::try_from(unsafe { RegisterClipboardFormatW(name) }).ok().filter(|f| *f != 0).ok_or_else(windows::core::Error::from_thread);
        Ok(Self {
            png: register(w!("PNG"))?,
            virtual_files: [register(w!("FileContents"))?, register(w!("FileGroupDescriptorW"))?, register(w!("FileGroupDescriptor"))?],
            shell_items: register(w!("Shell IDList Array"))?,
            marker: register(w!("local.quietdesk.clipboard-session"))?,
            exclude: register(w!("ExcludeClipboardContentFromMonitorProcessing"))?,
            ignore: register(w!("Clipboard Viewer Ignore"))?,
            cloud: register(w!("CanUploadToCloudClipboard"))?,
            history: register(w!("CanIncludeInClipboardHistory"))?,
        })
    }

    fn offered(self, kind: Kind) -> Vec<u16> {
        let mut formats = match kind {
            Kind::Text => vec![CF_UNICODETEXT.0],
            Kind::Png => vec![self.png, CF_DIBV5.0],
            Kind::Files => vec![CF_HDROP.0],
        };
        formats.extend([self.marker, self.exclude]);
        formats
    }
}

pub(super) enum Rendered {
    Text(Vec<u16>),
    Image { png: Vec<u8>, dib: Vec<u8> },
    Files(Vec<u8>),
}
impl Rendered {
    pub fn build(payload: Payload) -> Option<Self> {
        match payload {
            Payload::Text(text) if !text.contains('\0') => Some(Self::Text(wide(&text))),
            Payload::Text(_) => None,
            Payload::Png(png) => Some(Self::Image { dib: clipboard_image::png_to_dib(&png)?, png }),
            Payload::Files(paths) => {
                if paths.is_empty() {
                    return None;
                }
                let mut drop = vec![0; 20];
                drop[..4].copy_from_slice(&20u32.to_le_bytes());
                drop[16..].copy_from_slice(&1u32.to_le_bytes());
                for path in paths {
                    let units = path.as_os_str().encode_wide();
                    if drop.len() + 2 * (units.clone().count() + 2) > super::clipboard::MAX_DROP_BYTES {
                        return None;
                    }
                    for unit in units.chain(Some(0)) {
                        drop.extend_from_slice(&unit.to_le_bytes());
                    }
                }
                drop.extend_from_slice(&[0, 0]);
                Some(Self::Files(drop))
            }
        }
    }

    fn medium(&self, format: u16, formats: Formats) -> Result<STGMEDIUM> {
        let bytes = match self {
            Self::Text(text) => unsafe { std::slice::from_raw_parts(text.as_ptr().cast(), std::mem::size_of_val(text.as_slice())) },
            Self::Image { png, .. } if format == formats.png => png,
            Self::Image { dib, .. } => dib,
            Self::Files(drop) => drop,
        };
        medium(bytes)
    }
}

fn medium(bytes: &[u8]) -> Result<STGMEDIUM> {
    unsafe {
        let memory = GlobalAlloc(GMEM_MOVEABLE, bytes.len())?;
        let data = GlobalLock(memory);
        if data.is_null() {
            let err = windows::core::Error::from_thread();
            let _ = GlobalFree(Some(memory));
            return Err(err);
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), data.cast(), bytes.len());
        let _ = GlobalUnlock(memory);
        Ok(STGMEDIUM { tymed: TYMED_HGLOBAL.0 as u32, u: STGMEDIUM_0 { hGlobal: memory }, ..Default::default() })
    }
}

enum State {
    Advertised,
    Requested { event: Arc<OwnedHandle>, approved_file: bool },
    Ready(Arc<Rendered>),
    Cancelled,
}
impl State {
    fn finish(&mut self, new: Self) {
        if let Self::Requested { event, .. } = std::mem::replace(self, new) {
            // A manual-reset event wakes every OLE consumer sharing this manifest.
            unsafe {
                let _ = SetEvent(HANDLE(event.as_raw_handle()));
            }
        }
    }
}

pub(super) struct Promise {
    pub revision: Revision,
    pub kind: Kind,
    owner: AtomicUsize,
    #[cfg(test)]
    pub render_calls: AtomicUsize,
    state: Mutex<State>,
    input: Sender<Input>,
}
impl Promise {
    pub fn new(revision: Revision, kind: Kind, input: Sender<Input>, ready: Option<Rendered>) -> Self {
        Self {
            revision,
            kind,
            input,
            owner: AtomicUsize::new(0),
            #[cfg(test)]
            render_calls: AtomicUsize::new(0),
            state: Mutex::new(ready.map_or(State::Advertised, |p| State::Ready(Arc::new(p)))),
        }
    }
    pub fn owned(&self) -> bool {
        let owner = self.owner.load(Ordering::Acquire);
        owner != 0 && unsafe { GetClipboardOwner().is_ok_and(|hwnd| hwnd.0 as usize == owner) }
    }
    pub fn installed(&self) {
        let hwnd = unsafe { GetClipboardOwner() }.map_or(0, |hwnd| hwnd.0 as usize);
        self.owner.store(hwnd, Ordering::Release);
    }
    pub fn materialized(&self) -> bool {
        matches!(*self.state.lock().unwrap(), State::Ready(_))
    }
    pub fn pending_file(&self) -> bool {
        self.kind == Kind::Files && matches!(*self.state.lock().unwrap(), State::Requested { .. })
    }
    pub fn approve_file(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        if let State::Requested { approved_file, .. } = &mut *state
            && self.owned()
        {
            *approved_file = true;
            return true;
        }
        false
    }
    pub fn displaced(&self) {
        self.owner.store(0, Ordering::Release);
        let mut state = self.state.lock().unwrap();
        if matches!(*state, State::Advertised | State::Requested { approved_file: false, .. }) {
            state.finish(State::Cancelled);
        }
    }
    pub fn resolve(&self, data: Rendered) -> bool {
        let mut state = self.state.lock().unwrap();
        if !matches!(*state, State::Requested { approved_file, .. } if approved_file || self.owned()) {
            return false;
        }
        state.finish(State::Ready(Arc::new(data)));
        true
    }
    pub fn cancel(&self) {
        let mut state = self.state.lock().unwrap();
        if !matches!(*state, State::Ready(_)) {
            state.finish(State::Cancelled);
        }
    }
    fn read(&self) -> Result<Arc<Rendered>> {
        #[cfg(test)]
        self.render_calls.fetch_add(1, Ordering::Relaxed);
        let event = {
            let mut state = self.state.lock().unwrap();
            if (self.kind == Kind::Files || !matches!(*state, State::Ready(_))) && !self.owned() {
                return Err(E_ABORT.into());
            }
            match &*state {
                State::Ready(data) => return Ok(data.clone()),
                State::Cancelled => return Err(E_ABORT.into()),
                State::Requested { event, .. } => event.clone(),
                State::Advertised => {
                    let event = unsafe { OwnedHandle::from_raw_handle(CreateEventW(None, true, false, None)?.0) };
                    if self.input.try_send(Input::Paste(self.revision)).is_err() {
                        return Err(E_ABORT.into());
                    }
                    let event = Arc::new(event);
                    *state = State::Requested { event: event.clone(), approved_file: false };
                    event
                }
            }
        };
        let deadline = (self.kind != Kind::Files).then(|| Instant::now() + Duration::from_secs(12));
        loop {
            if !self.owned() {
                self.displaced();
            }
            match &*self.state.lock().unwrap() {
                State::Ready(data) => return Ok(data.clone()),
                State::Requested { .. } => {}
                _ => return Err(E_ABORT.into()),
            }
            if deadline.is_some_and(|end| Instant::now() >= end) {
                return Err(E_ABORT.into());
            }
            // Approval, transfer progress and cancellation run on other threads. Keep this STA
            // available to COM while checking for a local copy that displaced the remote promise.
            let wait = unsafe { CoWaitForMultipleHandles(COWAIT_DEFAULT.0 as u32, 100, &[HANDLE(event.as_raw_handle())]) };
            if let Err(error) = wait
                && error.code() != RPC_S_CALLPENDING
            {
                return Err(error);
            }
        }
    }
}

#[implement(IDataObject)]
pub(super) struct DataObject {
    pub formats: Formats,
    pub promise: Arc<Promise>,
}

impl DataObject_Impl {
    fn format(&self, raw: *const FORMATETC) -> std::result::Result<u16, HRESULT> {
        let f = unsafe { raw.as_ref() }.ok_or(E_POINTER)?;
        if !f.ptd.is_null() {
            return Err(DV_E_DVTARGETDEVICE);
        }
        if f.dwAspect != DVASPECT_CONTENT.0 {
            return Err(DV_E_DVASPECT);
        }
        if f.lindex != -1 {
            return Err(DV_E_LINDEX);
        }
        if f.tymed & TYMED_HGLOBAL.0 as u32 == 0 {
            return Err(DV_E_TYMED);
        }
        self.formats.offered(self.promise.kind).contains(&f.cfFormat).then_some(f.cfFormat).ok_or(DV_E_FORMATETC)
    }
}
impl IDataObject_Impl for DataObject_Impl {
    fn GetData(&self, f: *const FORMATETC) -> Result<STGMEDIUM> {
        let format = self.format(f)?;
        if format == self.formats.marker || format == self.formats.exclude {
            return medium(&[1, 0, 0, 0]);
        }
        self.promise.read()?.medium(format, self.formats)
    }
    fn QueryGetData(&self, f: *const FORMATETC) -> HRESULT {
        self.format(f).map_or_else(|e| e, |_| S_OK)
    }
    fn EnumFormatEtc(&self, direction: u32) -> Result<IEnumFORMATETC> {
        if direction != DATADIR_GET.0 as u32 {
            return Err(E_NOTIMPL.into());
        }
        let formats: Vec<_> = self
            .formats
            .offered(self.promise.kind)
            .into_iter()
            .map(|cf_format| FORMATETC { cfFormat: cf_format, dwAspect: DVASPECT_CONTENT.0, lindex: -1, tymed: TYMED_HGLOBAL.0 as u32, ..Default::default() })
            .collect();
        unsafe { SHCreateStdEnumFmtEtc(&formats) }
    }
    fn GetDataHere(&self, _: *const FORMATETC, _: *mut STGMEDIUM) -> Result<()> {
        Err(E_NOTIMPL.into())
    }
    fn SetData(&self, _: *const FORMATETC, _: *const STGMEDIUM, _: BOOL) -> Result<()> {
        Err(E_NOTIMPL.into())
    }
    fn GetCanonicalFormatEtc(&self, _: *const FORMATETC, out: *mut FORMATETC) -> HRESULT {
        if let Some(out) = unsafe { out.as_mut() } {
            out.ptd = std::ptr::null_mut();
        }
        E_NOTIMPL
    }
    fn DAdvise(&self, _: *const FORMATETC, _: u32, _: Ref<IAdviseSink>) -> Result<u32> {
        Err(OLE_E_ADVISENOTSUPPORTED.into())
    }
    fn DUnadvise(&self, _: u32) -> Result<()> {
        Err(OLE_E_ADVISENOTSUPPORTED.into())
    }
    fn EnumDAdvise(&self) -> Result<IEnumSTATDATA> {
        Err(OLE_E_ADVISENOTSUPPORTED.into())
    }
}

// The windows-rs projection maps both S_OK and S_FALSE to Ok(()).
pub(super) fn current(object: &IDataObject) -> bool {
    #[link(name = "ole32")]
    unsafe extern "system" {
        fn OleIsCurrentClipboard(object: *mut std::ffi::c_void) -> HRESULT;
    }
    unsafe { OleIsCurrentClipboard(object.as_raw()) == S_OK }
}
