//! A session's clipboard listener and delayed rendering STA. Approval and preparation run independently
//! of the STA so a shell consumer can wait for a paste while the user approves the incoming files.
use super::clipboard;
use super::clipboard_ole::{DataObject, Formats, Promise, Rendered, current};
use super::util::{failed, wide};
use quietdesk_core::clipboard::{Action, FileOffer, Input, Kind, Payload, Revision};
use quietdesk_core::error::{DeskError, Result};
use std::path::PathBuf;
use std::sync::{
    Arc, Mutex, Weak,
    atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering},
    mpsc,
};
use tokio::sync::mpsc::Sender;
use windows::Win32::Foundation::*;
use windows::Win32::System::Com::IDataObject;
use windows::Win32::System::DataExchange::*;
use windows::Win32::System::Ole::{OleFlushClipboard, OleInitialize, OleSetClipboard, OleUninitialize};
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{HRESULT, PCWSTR, w};

pub fn storage_root() -> Result<PathBuf> {
    let local = std::env::var_os("LOCALAPPDATA").filter(|p| !p.is_empty()).ok_or_else(|| DeskError::platform("无法定位本机用户的文件接收目录"))?;
    Ok(PathBuf::from(local).join("QuietDesk").join("Clipboard"))
}
fn sequence() -> u32 {
    unsafe { GetClipboardSequenceNumber() }
}
const WAKE: u32 = WM_APP + 1;

struct Approval {
    revision: Revision,
    sequence: u32,
    cancelled: AtomicBool,
    accepted: AtomicBool,
    paste: Option<Weak<Promise>>,
}

struct Shared {
    active: Mutex<Option<Arc<Promise>>>,
    approval: Mutex<Option<Arc<Approval>>>,
    generation: AtomicU64,
    baseline: AtomicU32,
    input: Sender<Input>,
}
impl Shared {
    fn reset(&self) {
        self.baseline.store(sequence(), Ordering::Release);
        self.generation.fetch_add(1, Ordering::AcqRel);
        if let Some(p) = self.active.lock().unwrap().take() {
            p.cancel()
        }
        if let Some(a) = self.approval.lock().unwrap().take() {
            a.cancelled.store(true, Ordering::Release);
        }
    }
    fn generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }
    fn applied(&self, revision: Revision, success: bool) {
        let _ = self.input.blocking_send(Input::Applied { revision, success });
    }
}
#[derive(Clone)]
struct StaPort {
    window: usize,
    commands: mpsc::Sender<Command>,
}
impl StaPort {
    fn send(&self, cmd: Command) {
        if self.commands.send(cmd).is_ok() {
            unsafe {
                let _ = PostMessageW(Some(HWND(self.window as _)), WAKE, WPARAM(0), LPARAM(0));
            }
        }
    }
}
enum Command {
    CountFileRoots {
        generation: u64,
        token: u64,
    },
    Read {
        generation: u64,
        token: u64,
        kind: Kind,
    },
    Install(Installation),
    #[cfg(test)]
    RetainInstalled(mpsc::SyncSender<windows::core::AgileReference<IDataObject>>),
    Clear,
    Stop,
}
struct Installation {
    generation: u64,
    sequence: u32,
    promise: Weak<Promise>,
    ack: Option<Revision>,
}
impl Installation {
    fn finish(&self, shared: &Shared, success: bool) {
        if !success && let Some(promise) = self.promise.upgrade() {
            promise.cancel();
            shared.active.lock().unwrap().take_if(|p| Arc::ptr_eq(p, &promise));
        }
        if let Some(revision) = self.ack {
            shared.applied(revision, success);
        }
    }
}
struct Prepare {
    revision: Revision,
    payload: Payload,
    manifest: Option<Revision>,
    explicit: bool,
    generation: u64,
    sequence: u32,
    approval: Option<Arc<Approval>>,
}

// The protocol keeps one incoming transfer. Replacing it drops its queued pixels and obsolete prompt.
struct Worker<T> {
    pending: Arc<Mutex<Option<T>>>,
    wake: mpsc::SyncSender<()>,
}
impl<T: Send + 'static> Worker<T> {
    fn start(name: &str, handle: impl Fn(T) + Send + 'static) -> std::io::Result<Self> {
        let (wake, rx) = mpsc::sync_channel(1);
        let pending = Arc::new(Mutex::new(None));
        let jobs = Arc::clone(&pending);
        std::thread::Builder::new().name(name.into()).spawn(move || {
            while rx.recv().is_ok() {
                let job = jobs.lock().unwrap().take();
                if let Some(job) = job {
                    handle(job);
                }
            }
        })?;
        Ok(Self { pending, wake })
    }
    fn send(&self, value: T) {
        *self.pending.lock().unwrap() = Some(value);
        let _ = self.wake.try_send(());
    }
}
pub struct NativeClipboard {
    sta: StaPort,
    shared: Arc<Shared>,
    prepare: Worker<Prepare>,
    prompts: Worker<(FileOffer, Arc<Approval>)>,
}
impl NativeClipboard {
    pub fn start(input: Sender<Input>, seed_preconnection: bool) -> Result<Self> {
        let shared = Arc::new(Shared {
            active: Mutex::new(None),
            approval: Mutex::new(None),
            generation: AtomicU64::new(0),
            baseline: AtomicU32::new(sequence()),
            input,
        });
        let (commands, rx) = mpsc::channel();
        let (started, init) = mpsc::sync_channel(1);
        let sta_shared = shared.clone();
        std::thread::Builder::new()
            .name("clipboard-ole".into())
            .spawn(move || sta(sta_shared, rx, started, seed_preconnection))
            .map_err(|e| DeskError::platform(e.to_string()))?;
        let window = init.recv().map_err(|_| DeskError::platform("剪贴板线程已关闭"))??;
        let sta = StaPort { window, commands };
        let publisher = sta.clone();
        let prep_shared = shared.clone();
        let start_error = |e: std::io::Error| {
            sta.send(Command::Stop);
            DeskError::platform(e.to_string())
        };
        let prepare = Worker::start("clipboard-publish", move |job| prepare_payload(job, &prep_shared, &publisher)).map_err(&start_error)?;
        let dialog_shared = shared.clone();
        let prompts = Worker::start("clipboard-approval", move |(offer, gate)| show_offer(offer, gate, &dialog_shared)).map_err(start_error)?;
        Ok(Self { sta, shared, prepare, prompts })
    }

    pub fn action(&self, action: Action) {
        match action {
            Action::CountFileRoots { token } => self.sta.send(Command::CountFileRoots { generation: self.shared.generation(), token }),
            Action::Read { token, kind } => self.sta.send(Command::Read { generation: self.shared.generation(), token, kind }),
            Action::Advertise { revision, kind, .. } => {
                self.shared.reset();
                let promise = Arc::new(Promise::new(revision, kind, self.shared.input.clone(), None));
                *self.shared.active.lock().unwrap() = Some(promise.clone());
                self.sta.send(Command::Install(Installation {
                    generation: self.shared.generation(),
                    sequence: sequence(),
                    promise: Arc::downgrade(&promise),
                    ack: None,
                }));
            }
            Action::Clear => {
                self.shared.reset();
                self.sta.send(Command::Clear);
            }
            Action::FileOffer(offer) => {
                let paste = self.shared.active.lock().unwrap().as_ref().filter(|p| !offer.explicit_drop && p.pending_file()).map(Arc::downgrade);
                let gate = Arc::new(Approval {
                    revision: offer.revision,
                    sequence: sequence(),
                    cancelled: AtomicBool::new(false),
                    accepted: AtomicBool::new(false),
                    paste,
                });
                if let Some(old) = self.shared.approval.lock().unwrap().replace(gate.clone()) {
                    old.cancelled.store(true, Ordering::Release);
                }
                self.prompts.send((offer, gate));
            }
            Action::Apply { revision, payload, manifest, explicit_drop } => {
                let approval = self.shared.approval.lock().unwrap().clone().filter(|a| a.revision == revision);
                self.prepare.send(Prepare {
                    revision,
                    payload,
                    manifest,
                    explicit: explicit_drop,
                    generation: self.shared.generation(),
                    sequence: self.shared.baseline.load(Ordering::Acquire),
                    approval,
                });
            }
            Action::Status(_) => {}
        }
    }
}
impl Drop for NativeClipboard {
    fn drop(&mut self) {
        self.shared.reset();
        self.sta.send(Command::Stop);
    }
}

fn prepare_payload(job: Prepare, shared: &Shared, sta: &StaPort) {
    let kind = match &job.payload {
        Payload::Text(_) => Kind::Text,
        Payload::Png(_) => Kind::Png,
        Payload::Files(_) => Kind::Files,
    };
    let expected = job.approval.as_ref().map_or(job.sequence, |a| a.sequence);
    if shared.generation() != job.generation
        || (kind == Kind::Files && !job.approval.as_ref().is_some_and(|a| a.accepted.load(Ordering::Acquire) && !a.cancelled.load(Ordering::Acquire)))
    {
        shared.applied(job.revision, false);
        return;
    }
    if job.explicit {
        shared.applied(job.revision, true);
        return;
    }
    let Some(data) = Rendered::build(job.payload) else {
        shared.applied(job.revision, false);
        return;
    };
    if let Some(manifest) = job.manifest {
        let active = shared.active.lock().unwrap().clone();
        let accepted = active.is_some_and(|p| p.revision == manifest && p.kind == kind && p.resolve(data));
        shared.applied(job.revision, accepted);
    } else {
        let promise = Arc::new(Promise::new(job.revision, kind, shared.input.clone(), Some(data)));
        let mut slot = shared.active.lock().unwrap();
        if shared.generation() != job.generation {
            drop(slot);
            shared.applied(job.revision, false);
            return;
        }
        if let Some(old) = slot.replace(promise.clone()) {
            old.cancel();
        }
        drop(slot);
        sta.send(Command::Install(Installation { generation: job.generation, sequence: expected, promise: Arc::downgrade(&promise), ack: Some(job.revision) }));
    }
}
fn show_offer(offer: FileOffer, gate: Arc<Approval>, shared: &Shared) {
    if gate.cancelled.load(Ordering::Acquire) {
        return;
    }
    let names = offer.names.join("\n");
    let body = wide(&format!("{} 个顶层项目，共 {} 个条目，{} 字节。\n\n{}", offer.roots, offer.entries, offer.bytes, names));
    let config = TASKDIALOGCONFIG {
        cbSize: std::mem::size_of::<TASKDIALOGCONFIG>() as u32,
        dwFlags: TDF_ALLOW_DIALOG_CANCELLATION | TDF_CALLBACK_TIMER,
        dwCommonButtons: TDCBF_YES_BUTTON | TDCBF_NO_BUTTON,
        pszWindowTitle: w!("QuietDesk · 文件接收"),
        pszMainInstruction: w!("允许对端发送这些文件吗？"),
        pszContent: PCWSTR(body.as_ptr()),
        nDefaultButton: IDNO.0,
        pfCallback: Some(dialog_event),
        lpCallbackData: Arc::as_ptr(&gate) as isize,
        ..Default::default()
    };
    let mut button = 0;
    let mut accept = unsafe { TaskDialogIndirect(&config, Some(&mut button), None, None) }.is_ok()
        && button == IDYES.0
        && (offer.explicit_drop || sequence() == gate.sequence || shared.active.lock().unwrap().as_ref().is_some_and(|p| p.owned()));
    if !gate.cancelled.load(Ordering::Acquire) {
        if let Some(paste) = &gate.paste {
            let pending = paste.upgrade();
            accept = accept && pending.as_ref().is_some_and(|p| p.approve_file());
            if !accept && let Some(p) = pending {
                p.cancel();
            }
        }
        gate.accepted.store(accept, Ordering::Release);
        let _ = shared.input.blocking_send(Input::Decision { revision: offer.revision, accept });
    }
}
unsafe extern "system" fn dialog_event(hwnd: HWND, msg: TASKDIALOG_NOTIFICATIONS, _: WPARAM, _: LPARAM, data: isize) -> HRESULT {
    if msg == TDN_TIMER && unsafe { &*(data as *const Approval) }.cancelled.load(Ordering::Acquire) {
        unsafe {
            let _ = PostMessageW(Some(hwnd), TDM_CLICK_BUTTON.0 as u32, WPARAM(IDNO.0 as usize), LPARAM(0));
        }
    }
    S_OK
}

fn sta(shared: Arc<Shared>, commands: mpsc::Receiver<Command>, started: mpsc::SyncSender<Result<usize>>, seed: bool) {
    if let Err(e) = unsafe { OleInitialize(None) } {
        let _ = started.send(Err(failed("初始化 OLE 剪贴板")(e)));
        return;
    }
    let setup = (|| {
        let formats = Formats::new()?;
        let hwnd = clipboard::window()?;
        if let Err(e) = unsafe { AddClipboardFormatListener(hwnd) } {
            unsafe {
                let _ = DestroyWindow(hwnd);
            }
            return Err(e);
        }
        Ok((hwnd, formats))
    })();
    if let Ok((hwnd, formats)) = setup {
        let mut baseline = sequence();
        if seed {
            baseline = baseline.wrapping_sub(1);
            unsafe {
                let _ = PostMessageW(Some(hwnd), WM_CLIPBOARDUPDATE, WPARAM(0), LPARAM(0));
            }
        }
        if started.send(Ok(hwnd.0 as usize)).is_ok() {
            message_loop(hwnd, formats, &shared, &commands, baseline);
        }
        unsafe {
            let _ = RemoveClipboardFormatListener(hwnd);
            let _ = DestroyWindow(hwnd);
        }
    } else if let Err(e) = setup {
        let _ = started.send(Err(failed("监听系统剪贴板")(e)));
    }
    unsafe {
        OleUninitialize();
    }
}

fn message_loop(hwnd: HWND, formats: Formats, shared: &Shared, commands: &mpsc::Receiver<Command>, mut last: u32) {
    let mut installed: Option<(IDataObject, Arc<Promise>)> = None;
    let mut own_clear = None;
    let mut deferred: Option<(Installation, u8)> = None;
    let mut retry = 0;
    let mut msg = MSG::default();
    let mut running = true;
    while running && unsafe { GetMessageW(&mut msg, None, 0, 0) }.0 > 0 {
        let install_timer = msg.message == WM_TIMER && msg.wParam.0 == 2;
        if msg.hwnd == hwnd && (msg.message == WAKE || install_timer) {
            let due = if install_timer {
                unsafe {
                    let _ = KillTimer(Some(hwnd), 2);
                }
                deferred.take().map(|(job, attempts)| (Command::Install(job), attempts))
            } else {
                None
            };
            for (cmd, attempts) in due.into_iter().chain(commands.try_iter().map(|cmd| (cmd, 0))) {
                match cmd {
                    Command::CountFileRoots { generation, token } => {
                        if shared.generation() == generation && u64::from(last) == token {
                            let count = clipboard::file_root_count(token, formats);
                            if u64::from(sequence()) == token && shared.generation() == generation {
                                let _ = shared.input.blocking_send(Input::FileRootCount { token, count });
                            }
                        }
                    }
                    Command::Read { generation, token, kind } => {
                        let payload = (shared.generation() == generation).then(|| clipboard::read(token, kind, formats)).flatten();
                        let _ = shared.input.blocking_send(Input::Read { token, payload });
                    }
                    Command::Install(job) => {
                        let Some(promise) = job.promise.upgrade().filter(|_| shared.generation() == job.generation) else {
                            job.finish(shared, false);
                            continue;
                        };
                        let observed = sequence();
                        let sequence_matches = observed == job.sequence || own_clear == Some(job.sequence) && unsafe { GetClipboardOwner() == Ok(hwnd) };
                        if !sequence_matches {
                            job.finish(shared, false);
                            continue;
                        }
                        let obj: IDataObject = DataObject { formats, promise: promise.clone() }.into();
                        match unsafe { OleSetClipboard(&obj) } {
                            Ok(()) => {
                                promise.installed();
                                if let Some((_, old)) = installed.replace((obj, promise)) {
                                    old.displaced();
                                }
                                last = sequence();
                                job.finish(shared, true);
                            }
                            Err(e)
                                if matches!(e.code(), CLIPBRD_E_CANT_OPEN | E_ACCESSDENIED)
                                    && attempts < 20
                                    && unsafe { SetTimer(Some(hwnd), 2, 50, None) } != 0 =>
                            {
                                // A consumer may still have the clipboard open while returning the old GetData result.
                                if let Some((old, _)) = deferred.replace((job, attempts + 1)) {
                                    old.finish(shared, false);
                                }
                            }
                            Err(_) => job.finish(shared, false),
                        }
                    }
                    #[cfg(test)]
                    Command::RetainInstalled(reply) => {
                        let (obj, _) = installed.as_ref().unwrap();
                        reply.send(windows::core::AgileReference::new(obj).unwrap()).unwrap();
                    }
                    Command::Clear => {
                        if let Some((obj, p)) = &installed
                            && !p.materialized()
                            && shared.active.lock().unwrap().is_none()
                        {
                            if current(obj)
                                && let Some(transition) = clipboard::clear_if(hwnd, || p.owned())
                            {
                                own_clear = Some(transition);
                            }
                            installed = None;
                        }
                    }
                    Command::Stop => {
                        running = false;
                        break;
                    }
                }
            }
        } else if msg.hwnd == hwnd && (msg.message == WM_CLIPBOARDUPDATE || msg.message == WM_TIMER && msg.wParam.0 == 1) {
            unsafe {
                let _ = KillTimer(Some(hwnd), 1);
            }
            if msg.message == WM_CLIPBOARDUPDATE {
                retry = 0;
            }
            if sequence() == last {
                continue;
            }
            if own_clear.is_some() && unsafe { GetClipboardOwner() == Ok(hwnd) } {
                last = sequence();
                continue;
            }
            if let Some((obj, _)) = &installed
                && current(obj)
            {
                last = sequence();
                continue;
            }
            if let Some((_, p)) = installed.take() {
                p.displaced();
            }
            match clipboard::inspect(formats) {
                Ok((token, kind)) => {
                    last = token as u32;
                    let _ = shared.input.blocking_send(Input::LocalChanged { token, kind });
                }
                Err(_) if retry < 10 => {
                    retry += 1;
                    unsafe {
                        SetTimer(Some(hwnd), 1, 50, None);
                    }
                }
                Err(_) => {
                    last = sequence();
                    let _ = shared.input.blocking_send(Input::LocalChanged { token: u64::from(last), kind: None });
                }
            }
        } else {
            unsafe {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }
    if let Some((obj, p)) = installed
        && current(&obj)
    {
        unsafe {
            if p.materialized() {
                let _ = OleFlushClipboard();
            } else {
                clipboard::clear_if(hwnd, || p.owned());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};
    use tokio::sync::mpsc::{self as async_mpsc, Receiver};
    use uuid::Uuid;
    use windows::Win32::System::Com::{DATADIR_GET, DVASPECT_CONTENT, FORMATETC, TYMED_HGLOBAL};
    use windows::Win32::System::Ole::{CF_HDROP, OleGetClipboard, ReleaseStgMedium};
    use windows::Win32::UI::Shell::{DragQueryFileW, FO_COPY, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT, HDROP, SHFILEOPSTRUCTW, SHFileOperationW};

    fn file_format() -> FORMATETC {
        FORMATETC { cfFormat: CF_HDROP.0, tymed: TYMED_HGLOBAL.0 as u32, dwAspect: DVASPECT_CONTENT.0, lindex: -1, ..Default::default() }
    }
    #[track_caller]
    fn eventually<T>(mut f: impl FnMut() -> Option<T>) -> T {
        let until = Instant::now() + Duration::from_secs(6);
        loop {
            if let Some(value) = f() {
                return value;
            }
            assert!(Instant::now() < until, "timed out");
            std::thread::sleep(Duration::from_millis(15));
        }
    }
    fn input(rx: &mut Receiver<Input>) -> Input {
        eventually(|| rx.try_recv().ok())
    }

    #[test]
    #[ignore = "requires the disposable Wine/Xvfb clipboard"]
    fn clipboard_native_lazy_file_paste() {
        assert_eq!(std::env::var("QUIETDESK_ISOLATED_CLIPBOARD_CHECK").as_deref(), Ok("1"));
        let (tx, mut rx) = async_mpsc::channel(16);
        let broker = NativeClipboard::start(tx, false).unwrap();
        clipboard::set_text("manual local-only text").unwrap();
        assert_eq!(clipboard::text().as_deref(), Some("manual local-only text"));
        assert!(matches!(input(&mut rx), Input::LocalChanged { kind: None, .. }));
        let manifest = Revision { counter: 1, origin: Uuid::new_v4() };
        let stream = Revision { counter: 2, ..manifest };
        let dir = std::env::temp_dir().join(Uuid::new_v4().to_string());
        let received = dir.join("received");
        let destination = dir.join("paste here");
        std::fs::create_dir_all(&destination).unwrap();
        let paths = vec![received.join("one file.txt"), received.join("文档")];
        broker.action(Action::Advertise { revision: manifest, kind: Kind::Files, file_root_count: Some(2) });
        let (probed, format_ok) = std::sync::mpsc::channel();
        let (go, read) = std::sync::mpsc::channel();
        let expected = paths.clone();
        let target = destination.clone();
        let client = std::thread::spawn(move || unsafe {
            OleInitialize(None).unwrap();
            eventually(|| IsClipboardFormatAvailable(u32::from(CF_HDROP.0)).ok());
            let object = OleGetClipboard().unwrap();
            let format = file_format();
            object.EnumFormatEtc(DATADIR_GET.0 as u32).unwrap();
            object.QueryGetData(&format).ok().unwrap();
            probed.send(()).unwrap();
            read.recv().unwrap();
            let mut medium = object.GetData(&format).unwrap();
            let drop = HDROP(medium.u.hGlobal.0);
            assert_eq!(DragQueryFileW(drop, u32::MAX, None), 2);
            let mut sources = Vec::new();
            for (i, expected) in expected.iter().enumerate() {
                let mut path = [0; 512];
                let n = DragQueryFileW(drop, i as u32, Some(&mut path)) as usize;
                let actual = PathBuf::from(String::from_utf16(&path[..n]).unwrap());
                assert_eq!(&actual, expected);
                sources.extend_from_slice(&path[..=n]);
            }
            sources.push(0);
            ReleaseStgMedium(&mut medium);
            let mut to = wide(target.to_str().unwrap());
            to.push(0);
            let mut operation = SHFILEOPSTRUCTW {
                wFunc: FO_COPY,
                pFrom: PCWSTR(sources.as_ptr()),
                pTo: PCWSTR(to.as_ptr()),
                fFlags: (FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT).0 as u16,
                ..Default::default()
            };
            assert_eq!(SHFileOperationW(&mut operation), 0);
            assert!(!operation.fAnyOperationsAborted.as_bool());
            std::mem::drop(object);
            OleUninitialize();
        });
        format_ok.recv_timeout(Duration::from_secs(8)).unwrap();
        assert!(rx.try_recv().is_err());
        assert!(!received.exists());
        go.send(()).unwrap();
        assert!(matches!(input(&mut rx),Input::Paste(r) if r==manifest));
        broker.action(Action::FileOffer(FileOffer {
            revision: stream,
            names: vec!["one file.txt".into(), "文档".into()],
            roots: 2,
            entries: 3,
            bytes: 2,
            explicit_drop: false,
        }));
        let dialog = eventually(|| unsafe { FindWindowW(PCWSTR::null(), w!("QuietDesk · 文件接收")).ok() });
        assert!(!received.exists());
        let pending = broker.shared.active.lock().unwrap().clone().unwrap();
        let responsive = unsafe { SendMessageTimeoutW(HWND(broker.sta.window as _), WM_NULL, WPARAM(0), LPARAM(0), SMTO_ABORTIFHUNG | SMTO_BLOCK, 1500, None) };
        assert_ne!(responsive.0, 0, "the clipboard STA must dispatch synchronous window messages while approval is pending");
        std::thread::sleep(Duration::from_secs(13));
        assert!(!client.is_finished(), "the original paste is still waiting for approval");
        assert_eq!(std::fs::read_dir(&destination).unwrap().count(), 0);
        unsafe {
            PostMessageW(Some(dialog), TDM_CLICK_BUTTON.0 as u32, WPARAM(IDYES.0 as usize), LPARAM(0)).unwrap();
        }
        assert!(matches!(input(&mut rx),Input::Decision{revision,accept:true} if revision==stream));
        std::fs::create_dir_all(&paths[1]).unwrap();
        std::fs::write(&paths[0], [37]).unwrap();
        std::fs::write(paths[1].join("里面.txt"), [82]).unwrap();
        broker.action(Action::Apply { revision: stream, manifest: Some(manifest), payload: Payload::Files(paths.clone()), explicit_drop: false });
        assert!(matches!(input(&mut rx),Input::Applied{revision,success:true} if revision==stream));
        client.join().unwrap();
        assert_eq!(pending.render_calls.load(Ordering::Relaxed), 1, "one provider call must complete the physical paste");
        assert_eq!(std::fs::read(destination.join("one file.txt")).unwrap(), [37]);
        assert_eq!(std::fs::read(destination.join("文档").join("里面.txt")).unwrap(), [82]);
        assert!(rx.try_recv().is_err());

        // A later local copy wins over late remote data, including when the session is detached.
        clipboard::set_text("newer local text").unwrap();
        assert!(matches!(input(&mut rx), Input::LocalChanged { kind: None, .. }));
        broker.action(Action::Apply { revision: stream, manifest: Some(manifest), payload: Payload::Files(paths), explicit_drop: false });
        assert!(matches!(input(&mut rx),Input::Applied{revision,success:false} if revision==stream));
        drop(broker);
        assert_eq!(clipboard::text().as_deref(), Some("newer local text"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    #[ignore = "requires the disposable Wine/Xvfb clipboard"]
    fn clipboard_native_approved_call_survives_a_local_copy_until_completed_or_cancelled() {
        assert_eq!(std::env::var("QUIETDESK_ISOLATED_CLIPBOARD_CHECK").as_deref(), Ok("1"));
        let path = std::env::temp_dir().join(Uuid::new_v4().to_string());
        for cancel in [false, true] {
            let (tx, mut rx) = async_mpsc::channel(16);
            let broker = NativeClipboard::start(tx, false).unwrap();
            let revision = Revision { counter: 1, origin: Uuid::new_v4() };
            let stream = Revision { counter: 2, ..revision };
            broker.action(Action::Advertise { revision, kind: Kind::Files, file_root_count: Some(1) });
            eventually(|| broker.shared.active.lock().unwrap().as_ref().is_some_and(|p| p.owned()).then_some(()));
            // Retain the installed source directly. Wine's clipboard wrapper itself holds OpenClipboard during GetData.
            let (reply, retained) = mpsc::sync_channel(1);
            broker.sta.send(Command::RetainInstalled(reply));
            let source = retained.recv_timeout(Duration::from_secs(3)).unwrap();
            let original = source.clone();
            let expected = path.clone();
            let client = std::thread::spawn(move || unsafe {
                OleInitialize(None).unwrap();
                let obj = original.resolve().unwrap();
                let data = obj.GetData(&file_format());
                if cancel {
                    assert!(data.is_err());
                } else {
                    let mut medium = data.unwrap();
                    let mut name = [0; 512];
                    let n = DragQueryFileW(HDROP(medium.u.hGlobal.0), 0, Some(&mut name)) as usize;
                    assert_eq!(PathBuf::from(String::from_utf16(&name[..n]).unwrap()), expected);
                    assert_eq!(std::fs::read(&expected).unwrap(), b"accepted");
                    ReleaseStgMedium(&mut medium);
                }
                drop(obj);
                drop(original);
                OleUninitialize();
            });
            assert!(matches!(input(&mut rx), Input::Paste(r) if r == revision));
            broker.action(Action::FileOffer(FileOffer { revision: stream, names: vec!["file".into()], roots: 1, entries: 1, bytes: 8, explicit_drop: false }));
            let dialog = eventually(|| unsafe { FindWindowW(PCWSTR::null(), w!("QuietDesk · 文件接收")).ok() });
            unsafe {
                PostMessageW(Some(dialog), TDM_CLICK_BUTTON.0 as u32, WPARAM(IDYES.0 as usize), LPARAM(0)).unwrap();
            }
            assert!(matches!(input(&mut rx), Input::Decision {revision,accept:true} if revision == stream));
            clipboard::set_text("keep my new copy").unwrap();
            let stale = std::thread::spawn(move || unsafe {
                OleInitialize(None).unwrap();
                let obj = source.resolve().unwrap();
                assert!(obj.GetData(&file_format()).is_err(), "a new read on the displaced object must not join an approved download");
                drop(obj);
                drop(source);
                OleUninitialize();
            });
            eventually(|| stale.is_finished().then_some(()));
            stale.join().unwrap();
            assert!(!client.is_finished());
            if cancel {
                broker.action(Action::Clear);
            } else {
                std::fs::write(&path, b"accepted").unwrap();
                broker.action(Action::Apply { revision: stream, manifest: Some(revision), payload: Payload::Files(vec![path.clone()]), explicit_drop: false });
            }
            eventually(|| client.is_finished().then_some(()));
            client.join().unwrap();
            assert_eq!(clipboard::text().as_deref(), Some("keep my new copy"));
            if !cancel {
                loop {
                    match input(&mut rx) {
                        Input::Applied { revision, success: true } if revision == stream => break,
                        Input::LocalChanged { .. } => {}
                        _ => panic!("the displaced object must not request another transfer"),
                    }
                }
                std::fs::remove_file(&path).unwrap();
            }
            let window = HWND(broker.sta.window as _);
            drop(broker);
            eventually(|| (!unsafe { IsWindow(Some(window)) }.as_bool()).then_some(()));
            assert_eq!(clipboard::text().as_deref(), Some("keep my new copy"));
        }
    }

    #[test]
    #[ignore = "requires the disposable Wine/Xvfb clipboard"]
    fn clipboard_native_preconnection_and_cancelled_demand() {
        assert_eq!(std::env::var("QUIETDESK_ISOLATED_CLIPBOARD_CHECK").as_deref(), Ok("1"));
        let absent = std::env::temp_dir().join(Uuid::new_v4().to_string());
        let paths = vec![absent.join("preexisting choice.txt"), absent.join("目录")];
        clipboard::external_files(&paths, false);
        let (tx, mut rx) = async_mpsc::channel(16);
        let host = NativeClipboard::start(tx, false).unwrap();
        std::thread::sleep(Duration::from_millis(100));
        assert!(rx.try_recv().is_err());
        drop(host);
        let (tx, mut rx) = async_mpsc::channel(16);
        let broker = NativeClipboard::start(tx, true).unwrap();
        let Input::LocalChanged { token, kind: Some(Kind::Files) } = input(&mut rx) else { panic!("initial file format") };
        broker.action(Action::CountFileRoots { token });
        assert!(matches!(input(&mut rx),Input::FileRootCount{token:t,count:Some(2)} if t==token));
        assert!(!absent.exists());
        broker.action(Action::Read { token, kind: Kind::Files });
        assert!(matches!(input(&mut rx),Input::Read{payload:Some(Payload::Files(p)),..} if p==paths));

        clipboard::external_files(&[], true);
        assert!(matches!(input(&mut rx), Input::LocalChanged { kind: None, .. }));
        clipboard::external_files(&paths, true);
        let Input::LocalChanged { token, kind: Some(Kind::Files) } = input(&mut rx) else { panic!("mixed file formats") };
        broker.action(Action::CountFileRoots { token });
        assert!(matches!(input(&mut rx),Input::FileRootCount{token:t,count:None} if t==token));
        broker.action(Action::Read { token, kind: Kind::Files });
        assert!(matches!(input(&mut rx),Input::Read{payload:Some(Payload::Files(p)),..} if p==paths));

        let revision = Revision { counter: 2, origin: Uuid::new_v4() };
        broker.action(Action::Advertise { revision, kind: Kind::Files, file_root_count: None });
        let client = std::thread::spawn(move || unsafe {
            OleInitialize(None).unwrap();
            let marker = Formats::new().unwrap().marker;
            eventually(|| IsClipboardFormatAvailable(u32::from(marker)).ok());
            let object = OleGetClipboard().unwrap();
            let f = file_format();
            assert!(object.GetData(&f).is_err());
            drop(object);
            OleUninitialize();
        });
        assert!(matches!(input(&mut rx),Input::Paste(r) if r==revision));
        let offer =
            FileOffer { revision: Revision { counter: 3, ..revision }, names: vec!["one".into()], roots: 1, entries: 1, bytes: 1, explicit_drop: false };
        broker.action(Action::FileOffer(offer.clone()));
        eventually(|| unsafe { FindWindowW(PCWSTR::null(), w!("QuietDesk · 文件接收")).ok() });
        let start = Instant::now();
        broker.action(Action::Clear);
        client.join().unwrap();
        eventually(|| unsafe { FindWindowW(PCWSTR::null(), w!("QuietDesk · 文件接收")).is_err().then_some(()) });
        assert!(start.elapsed() < Duration::from_secs(6), "disable must wake the waiting consumer");
        broker.action(Action::FileOffer(offer.clone()));
        let hwnd = eventually(|| unsafe { FindWindowW(PCWSTR::null(), w!("QuietDesk · 文件接收")).ok() });
        unsafe {
            PostMessageW(Some(hwnd), TDM_CLICK_BUTTON.0 as u32, WPARAM(IDNO.0 as usize), LPARAM(0)).unwrap();
        }
        assert!(matches!(input(&mut rx),Input::Decision{revision,accept:false} if revision==offer.revision));
    }

    #[test]
    #[ignore = "requires the disposable Wine/Xvfb clipboard"]
    fn clipboard_native_pending_file_read_releases_while_the_shell_keeps_its_object() {
        assert_eq!(std::env::var("QUIETDESK_ISOLATED_CLIPBOARD_CHECK").as_deref(), Ok("1"));
        enum Finish {
            Decline,
            Disconnect,
            ReplaceManifest,
        }
        for finish in [Finish::Decline, Finish::Disconnect, Finish::ReplaceManifest] {
            let (tx, mut rx) = async_mpsc::channel(16);
            let broker = NativeClipboard::start(tx, false).unwrap();
            let window = HWND(broker.sta.window as _);
            let revision = Revision { counter: 10, origin: Uuid::new_v4() };
            broker.action(Action::Advertise { revision, kind: Kind::Files, file_root_count: Some(1) });
            eventually(|| broker.shared.active.lock().unwrap().as_ref().is_some_and(|p| p.owned()).then_some(()));
            let (done, returned) = mpsc::channel();
            let (release, retain) = mpsc::channel();
            let client = std::thread::spawn(move || unsafe {
                OleInitialize(None).unwrap();
                let obj = OleGetClipboard().unwrap();
                let format = file_format();
                assert!(obj.GetData(&format).is_err());
                done.send(()).unwrap();
                retain.recv_timeout(Duration::from_secs(8)).unwrap();
                drop(obj);
                OleUninitialize();
            });
            assert!(matches!(input(&mut rx),Input::Paste(r) if r==revision));
            match finish {
                Finish::Decline => {
                    let offer = FileOffer {
                        revision: Revision { counter: 11, ..revision },
                        names: vec!["declined".into()],
                        roots: 1,
                        entries: 1,
                        bytes: 0,
                        explicit_drop: false,
                    };
                    broker.action(Action::FileOffer(offer.clone()));
                    let dialog = eventually(|| unsafe { FindWindowW(PCWSTR::null(), w!("QuietDesk · 文件接收")).ok() });
                    unsafe {
                        PostMessageW(Some(dialog), TDM_CLICK_BUTTON.0 as u32, WPARAM(IDNO.0 as usize), LPARAM(0)).unwrap();
                    }
                    assert!(matches!(input(&mut rx),Input::Decision{revision,accept:false} if revision==offer.revision));
                    returned.recv_timeout(Duration::from_secs(3)).unwrap();
                    drop(broker);
                }
                Finish::Disconnect => {
                    drop(broker);
                    returned.recv_timeout(Duration::from_secs(3)).unwrap();
                }
                Finish::ReplaceManifest => {
                    let next = Revision { counter: 12, ..revision };
                    broker.action(Action::Advertise { revision: next, kind: Kind::Text, file_root_count: None });
                    returned.recv_timeout(Duration::from_secs(3)).unwrap();
                    eventually(|| broker.shared.active.lock().unwrap().as_ref().is_some_and(|p| p.revision == next && p.owned()).then_some(()));
                    clipboard::set_text("new local copy").unwrap();
                    assert!(matches!(input(&mut rx), Input::LocalChanged { kind: None, .. }));
                    assert_eq!(clipboard::text().as_deref(), Some("new local copy"));
                    drop(broker);
                }
            }
            eventually(|| (!unsafe { IsWindow(Some(window)) }.as_bool()).then_some(()));
            release.send(()).unwrap();
            client.join().unwrap();
        }
    }
}
