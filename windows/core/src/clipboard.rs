//! Clipboard negotiation and stop-and-wait transfers, isolated from the session and native pasteboard threads.
mod storage;
#[cfg(test)]
mod tests;
mod transfer;

use crate::error::{DeskError, Result};
use crate::wire::{MAXIMUM_CONTROL_BYTES, Message, MessageKind as M};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::sync::Arc;
use std::time::{Duration, Instant};
use std::{collections::HashSet, path::PathBuf};
pub use storage::{StorageBackend, validate_filename};
use tokio::sync::mpsc;
use transfer::{Begin, Entry, Incoming, Outgoing, Receipt};
use uuid::Uuid;

pub const MAX_TEXT_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_PNG_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_FILE_ENTRIES: usize = 200_000;
pub const MAX_PROMISED_FILE_ROOTS: usize = 4096;
const MAX_NAMED_MANIFEST_BYTES: usize = 2 * 1024 * 1024;
const CHUNK: usize = 32_768;
const STALL: Duration = Duration::from_secs(30);
const OFFER_TIMEOUT: Duration = Duration::from_secs(90);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Viewer,
    Host,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Text,
    Png,
    Files,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Revision {
    pub counter: u64,
    #[serde(with = "uuid::serde::hyphenated")]
    pub origin: Uuid,
}
#[derive(Clone, Debug)]
pub enum Payload {
    Text(String),
    Png(Vec<u8>),
    Files(Vec<PathBuf>),
}
impl Payload {
    fn kind(&self) -> Kind {
        match self {
            Self::Text(_) => Kind::Text,
            Self::Png(_) => Kind::Png,
            Self::Files(_) => Kind::Files,
        }
    }
}
#[derive(Clone, Debug)]
pub struct FileOffer {
    pub revision: Revision,
    pub names: Vec<String>,
    pub roots: usize,
    pub entries: usize,
    pub bytes: u64,
    pub explicit_drop: bool,
}
#[derive(Debug)]
pub enum Input {
    Peer(Message),
    Preferences { enabled: bool, receives: bool },
    LocalChanged { token: u64, kind: Option<Kind> },
    FileRootCount { token: u64, include_names: bool, count: Option<usize>, names: Option<Vec<String>> },
    Paste(Revision),
    Read { token: u64, payload: Option<Payload> },
    Decision { revision: Revision, accept: bool },
    Applied { revision: Revision, success: bool },
    DropFiles(Vec<PathBuf>),
}
#[derive(Debug)]
pub enum Action {
    CountFileRoots { token: u64, include_names: bool },
    Read { token: u64, kind: Kind },
    Advertise { revision: Revision, kind: Kind, file_root_count: Option<usize> },
    Clear,
    FileOffer(FileOffer),
    Apply { revision: Revision, manifest: Option<Revision>, payload: Payload, explicit_drop: bool },
    Status(String),
}
#[derive(Debug)]
pub enum Output {
    Send(Message),
    Native(Action),
    ProtocolError(String),
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Preference {
    enabled: bool,
    #[serde(with = "uuid::serde::hyphenated")]
    session: Uuid,
    file_approval: Option<bool>,
    receives_automatic_updates: Option<bool>,
    chunk_window: Option<bool>,
    decoupled_file_transfer: Option<bool>,
    on_demand_clipboard: Option<bool>,
    physical_file_paste_v1: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    file_root_names_v1: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    provides_file_root_names_v1: Option<bool>,
}
pub fn file_root_names(paths: &[PathBuf]) -> Option<Vec<String>> {
    if !(1..=MAX_PROMISED_FILE_ROOTS).contains(&paths.len()) {
        return None;
    }
    paths.iter().map(|p| p.file_name()?.to_str().map(str::to_owned)).collect()
}

#[derive(Clone, Debug, Serialize)]
#[serde(transparent)]
struct RootNames(Vec<String>);

impl RootNames {
    fn checked(names: Vec<String>) -> Option<Self> {
        let mut unique = HashSet::new();
        ((1..=MAX_PROMISED_FILE_ROOTS).contains(&names.len())
            && names.iter().all(|n| n.len() <= 255 && validate_filename(n).is_ok() && unique.insert(n.to_lowercase())))
        .then_some(Self(names))
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Manifest {
    revision: Revision,
    kind: Kind,
    #[serde(rename = "fileRootCount", skip_serializing_if = "Option::is_none")]
    file_root_count: Option<usize>,
    #[serde(rename = "fileRootNames", skip_deserializing, skip_serializing_if = "Option::is_none")]
    file_root_names: Option<RootNames>,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
struct Pull {
    #[serde(rename = "requestID", with = "uuid::serde::hyphenated")]
    request_id: Uuid,
    revision: Revision,
    kind: Kind,
}

fn read_control<T: DeserializeOwned>(message: &Message) -> Result<T> {
    message.read_json().map_err(|_| DeskError::invalid("剪贴板控制消息过大或格式无效"))
}

pub struct Exchange {
    pub input: mpsc::Sender<Input>,
    pub output: mpsc::Receiver<Output>,
}
impl Exchange {
    pub fn start(role: Role, storage: PathBuf, enabled: bool, receives: bool) -> Result<Self> {
        Self::with_storage(role, storage, enabled, receives, Arc::new(storage::PortableStorage))
    }
    pub fn with_storage(role: Role, storage: PathBuf, enabled: bool, receives: bool, backend: Arc<dyn StorageBackend>) -> Result<Self> {
        let (input, mut requests) = mpsc::channel(16);
        let (events, output) = mpsc::channel(16);
        let runtime = tokio::runtime::Builder::new_current_thread().enable_time().build().map_err(|_| DeskError::platform("无法启动剪贴板定时器"))?;
        std::thread::Builder::new()
            .name("clipboard-transfer".into())
            .spawn(move || {
                runtime.block_on(async move {
                    let mut state = State::new(role, storage, enabled, receives, backend);
                    if role == Role::Viewer {
                        state.greet();
                    }
                    loop {
                        for event in state.effects.drain(..) {
                            if events.send(event).await.is_err() {
                                return;
                            }
                        }
                        let deadline = state.deadline;
                        tokio::select! {
                                _ = events.closed() => break,
                                input = requests.recv() => match input { Some(input) => state.handle(input), None => break },
                                _ = async {
                                    if let Some(deadline) = deadline { tokio::time::sleep_until(deadline.into()).await }
                                    else { std::future::pending::<()>().await }
                        } => {state.cancel("剪贴板传输等待超时",true); state.native(Action::Status("剪贴板传输等待超时".into()));state.flush_deferred();}
                            }
                    }
                })
            })
            .map_err(|_| DeskError::platform("无法启动剪贴板传输线程"))?;
        Ok(Self { input, output })
    }
}

struct Reading {
    token: u64,
    kind: Kind,
    pull: Option<Pull>,
}
struct Applying {
    revision: Revision,
    sequence: u64,
    kind: Kind,
    explicit_drop: bool,
}
struct State {
    role: Role,
    session: Option<Uuid>,
    origin: Uuid,
    clock: u64,
    newest: Option<Revision>,
    enabled: bool,
    receives: bool,
    remote: Option<Preference>,
    storage: PathBuf,
    backend: Arc<dyn StorageBackend>,
    local: Option<(u64, Kind)>,
    counting: Option<(u64, bool)>,
    published_token: Option<u64>,
    deferred_local: bool,
    local_manifest: Option<Manifest>,
    remote_manifest: Option<Manifest>,
    pull: Option<Pull>,
    reading: Option<Reading>,
    outgoing: Option<Outgoing>,
    incoming: Option<Incoming>,
    applying: Option<Applying>,
    requested_file: Option<Revision>,
    deadline: Option<Instant>,
    effects: Vec<Output>,
}
impl State {
    fn new(role: Role, storage: PathBuf, enabled: bool, receives: bool, backend: Arc<dyn StorageBackend>) -> Self {
        Self {
            role,
            session: (role == Role::Viewer).then(Uuid::new_v4),
            origin: Uuid::new_v4(),
            clock: 0,
            newest: None,
            enabled,
            receives,
            remote: None,
            storage,
            backend,
            local: None,
            counting: None,
            published_token: None,
            deferred_local: false,
            local_manifest: None,
            remote_manifest: None,
            pull: None,
            reading: None,
            outgoing: None,
            incoming: None,
            applying: None,
            requested_file: None,
            deadline: None,
            effects: Vec::new(),
        }
    }
    fn active(&self) -> bool {
        self.enabled && self.remote.as_ref().is_some_and(|p| p.enabled)
    }
    fn on_demand(&self) -> bool {
        self.remote.as_ref().is_some_and(|p| p.on_demand_clipboard == Some(true))
    }
    fn physical(&self) -> bool {
        self.on_demand() && self.remote.as_ref().is_some_and(|p| p.file_approval == Some(true) && p.physical_file_paste_v1 == Some(true))
    }
    fn names_negotiated(&self) -> bool {
        self.physical() && self.remote.as_ref().is_some_and(|p| p.file_root_names_v1 == Some(true))
    }
    fn remote_receives(&self) -> bool {
        self.remote.as_ref().is_some_and(|p| p.receives_automatic_updates != Some(false))
    }
    fn native(&mut self, action: Action) {
        self.effects.push(Output::Native(action));
    }
    fn send<T: Serialize>(&mut self, kind: M, value: &T) {
        let limit = if kind == M::ClipboardManifest && self.names_negotiated() { MAX_NAMED_MANIFEST_BYTES } else { MAXIMUM_CONTROL_BYTES };
        match Message::json(kind, value) {
            Ok(msg) if msg.payload.len() <= limit => self.effects.push(Output::Send(msg)),
            _ => self.native(Action::Status("剪贴板控制信息过大".into())),
        }
    }
    fn greet(&mut self) {
        if let Some(session) = self.session {
            self.send(
                M::ClipboardSettings,
                &Preference {
                    session,
                    enabled: self.enabled,
                    file_approval: Some(true),
                    receives_automatic_updates: Some(self.enabled && self.receives),
                    chunk_window: Some(false),
                    decoupled_file_transfer: Some(false),
                    on_demand_clipboard: Some(true),
                    physical_file_paste_v1: Some(true),
                    file_root_names_v1: None,
                    provides_file_root_names_v1: Some(true),
                },
            );
        }
    }
    fn next_revision(&mut self) -> Result<Revision> {
        self.clock = self.clock.checked_add(1).ok_or_else(|| DeskError::invalid("剪贴板修订号已耗尽"))?;
        let revision = Revision { counter: self.clock, origin: self.origin };
        self.newest = Some(revision);
        Ok(revision)
    }
    fn reject(&mut self, revision: Revision, sequence: u64, reason: &str) {
        self.send(M::ClipboardCancel, &Receipt::cancel(revision, sequence, reason));
    }
    fn ack(&mut self, revision: Revision, sequence: u64) {
        self.send(M::ClipboardReceipt, &Receipt::ok(revision, sequence));
    }
    fn cancel(&mut self, reason: &str, notify: bool) {
        self.counting = None;
        let mut pending = Vec::new();
        if let Some(t) = self.incoming.take() {
            pending.push((t.begin.revision, t.sequence));
        }
        if let Some(t) = self.outgoing.take() {
            pending.push((t.revision, t.sequence));
        }
        if let Some(t) = self.applying.take() {
            pending.push((t.revision, t.sequence));
            if t.kind == Kind::Files {
                self.native(Action::Status(if t.explicit_drop { "拖入文件已保存到接收目录" } else { "文件已保存到接收目录，本机剪贴板未更新" }.into()));
            }
        }
        if let Some(p) = self.pull.take()
            && pending.is_empty()
        {
            pending.push((p.revision, 0));
        }
        if let Some(r) = self.reading.take().and_then(|r| r.pull) {
            pending.push((r.revision, 0));
        }
        if notify {
            for (rev, seq) in pending {
                self.reject(rev, seq, reason);
            }
        }
        self.deadline = None;
        self.remote_manifest = None;
        self.native(Action::Clear);
    }
    fn handle(&mut self, input: Input) {
        self.handle_input(input);
        self.flush_deferred();
    }
    fn flush_deferred(&mut self) {
        if self.deferred_local && self.incoming.is_none() && self.applying.is_none() && self.active() {
            self.deferred_local = false;
            if let Err(e) = self.publish_local() {
                self.native(Action::Status(e.to_string()));
            }
        }
    }
    fn saved_after_copy(&mut self, revision: Revision, sequence: u64) {
        self.ack(revision, sequence);
        self.pull = None;
        self.remote_manifest = None;
        self.deadline = None;
        self.native(Action::Clear);
        self.native(Action::Status("文件已保存到接收目录，保留了新的本机复制".into()));
    }
    fn handle_input(&mut self, input: Input) {
        let result = match input {
            Input::Peer(msg) if msg.kind == M::ClipboardSettings => {
                if let Err(e) = self.preference(&msg) {
                    self.effects.push(Output::ProtocolError(e.to_string()));
                }
                return;
            }
            Input::Preferences { enabled, receives } => {
                if (self.enabled, self.receives) != (enabled, receives) {
                    let was_active = self.active();
                    self.enabled = enabled;
                    self.receives = receives;
                    self.greet();
                    if !self.active() {
                        self.cancel("剪贴板同步已关闭", true);
                        self.local_manifest = None;
                        self.published_token = None;
                    } else if !was_active && let Err(e) = self.publish_local() {
                        self.native(Action::Status(e.to_string()));
                    }
                }
                return;
            }
            Input::LocalChanged { token, kind } => {
                if self.local == kind.map(|k| (token, k)) && kind.is_some() {
                    return;
                }
                self.local = kind.map(|k| (token, k));
                self.published_token = None;
                if !self.active() {
                    return;
                }
                if self.incoming.as_ref().is_some_and(|t| t.begin.kind == Kind::Files && !t.waiting)
                    || self.applying.as_ref().is_some_and(|t| t.kind == Kind::Files)
                {
                    self.deferred_local = true;
                    return;
                }
                if let Some(old) = self.local_manifest.take()
                    && (kind.is_none() || old.kind == Kind::Files || !self.remote_receives())
                    && self.reading.as_ref().and_then(|r| r.pull).is_none_or(|p| p.revision != old.revision)
                {
                    self.reject(old.revision, 0, "源剪贴板已更新");
                }
                self.cancel("本机剪贴板已更新", true);
                self.publish_local()
            }
            _ if !self.active() => return,
            Input::FileRootCount { token, include_names, count, names } => {
                if self.counting.take_if(|query| *query == (token, include_names)).is_none() {
                    return;
                }
                if !self.remote_receives() {
                    self.published_token = None;
                    return;
                }
                if count == Some(0) {
                    return;
                }
                if count.is_some_and(|n| n > MAX_PROMISED_FILE_ROOTS) {
                    self.native(Action::Status("所选顶层文件较多，将使用兼容文件接收方式".into()));
                }
                let names = names.filter(|n| self.names_negotiated() && Some(n.len()) == count).and_then(RootNames::checked);
                self.publish_manifest(Kind::Files, count.filter(|n| *n <= MAX_PROMISED_FILE_ROOTS), names)
            }
            Input::Peer(msg) => self.peer(msg),
            Input::Paste(revision) => {
                let Some(m) = self.remote_manifest.as_ref().filter(|m| m.revision == revision) else { return };
                if self.pull.is_some() || self.incoming.is_some() || self.applying.is_some() || (m.kind == Kind::Files && !self.physical()) {
                    return;
                }
                let p = Pull { revision, kind: m.kind, request_id: Uuid::new_v4() };
                self.pull = Some(p);
                self.deadline = Some(Instant::now() + STALL);
                self.send(M::ClipboardPull, &p);
                Ok(())
            }
            Input::Read { token, payload } => {
                let Some(r) = self.reading.take_if(|r| r.token == token) else { return };
                if self.local != Some((token, r.kind)) {
                    return;
                }
                if r.pull.is_none() && !self.remote_receives() {
                    self.published_token = None;
                    self.deadline = None;
                    return;
                }
                match payload.filter(|p| p.kind() == r.kind) {
                    Some(p) => self.start_outgoing(p, r.pull, false),
                    None => {
                        if let Some(p) = r.pull {
                            self.reject(p.revision, 0, "剪贴板内容已更新或不可用");
                        }
                        self.deadline = None;
                        Ok(())
                    }
                }
            }
            Input::DropFiles(paths) => {
                if self.remote.as_ref().is_none_or(|p| p.file_approval != Some(true)) {
                    self.native(Action::Status("对端未启用文件接收确认".into()));
                    return;
                }
                self.cancel("已发起新的文件传输", true);
                self.start_outgoing(Payload::Files(paths), None, self.physical())
            }
            Input::Decision { revision, accept } => {
                let Some(t) = self.incoming.as_mut().filter(|t| t.begin.revision == revision && t.waiting) else { return };
                if !accept {
                    self.cancel("对端选择不接收文件", true);
                    self.native(Action::Status("已拒绝接收文件".into()));
                    return;
                }
                match t.accept(&self.storage, &*self.backend) {
                    Ok(()) => {
                        self.ack(revision, 0);
                        self.native(Action::Status("正在接收文件".into()));
                        self.deadline = Some(Instant::now() + STALL);
                        Ok(())
                    }
                    Err(e) => Err(e),
                }
            }
            Input::Applied { revision, success } => {
                let Some(r) = self.applying.take_if(|r| r.revision == revision) else { return };
                if self.deferred_local && r.kind == Kind::Files {
                    self.saved_after_copy(revision, r.sequence);
                    return;
                }
                if success {
                    self.ack(revision, r.sequence);
                    if r.kind == Kind::Files {
                        let status = if r.explicit_drop {
                            "拖入文件已保存到接收目录"
                        } else if self.pull.is_some() {
                            "文件已交给本机粘贴"
                        } else {
                            "文件已保存到接收目录"
                        };
                        self.native(Action::Status(status.into()));
                    }
                } else {
                    self.reject(revision, r.sequence, "无法写入系统剪贴板");
                    self.native(Action::Clear);
                    self.native(Action::Status(if r.kind == Kind::Files { "文件已保存到接收目录，本机剪贴板未更新" } else { "无法写入系统剪贴板" }.into()));
                }
                self.deadline = None;
                self.pull = None;
                self.remote_manifest = None;
                Ok(())
            }
        };
        if let Err(e) = result {
            self.cancel(&e.to_string(), true);
            self.native(Action::Status(e.to_string()));
        }
    }
    fn preference(&mut self, msg: &Message) -> Result<()> {
        let p: Preference = read_control(msg)?;
        if self.session.is_some_and(|s| s != p.session) {
            return Err(DeskError::invalid("剪贴板会话不匹配"));
        }
        let first = self.remote.is_none();
        let was_active = self.active();
        let allowed = self.remote_receives();
        let changed = self.remote.as_ref().is_some_and(|prior| {
            (prior.on_demand_clipboard, prior.file_approval, prior.physical_file_paste_v1, prior.file_root_names_v1)
                != (p.on_demand_clipboard, p.file_approval, p.physical_file_paste_v1, p.file_root_names_v1)
        });
        self.session = Some(p.session);
        self.remote = Some(p);
        if first && self.role == Role::Host {
            self.greet();
        }
        if (was_active && !self.active()) || changed {
            self.cancel("剪贴板协商状态已更新", true);
            self.local_manifest = None;
            self.published_token = None;
        }
        if self.active() && (!was_active || changed || (!allowed && self.remote_receives())) {
            self.publish_local()?;
        }
        Ok(())
    }
    fn publish_local(&mut self) -> Result<()> {
        if self.deferred_local {
            return Ok(());
        }
        let Some((token, kind)) = self.local else { return Ok(()) };
        if self.published_token == Some(token)
            || !self.remote_receives()
            || (kind == Kind::Files && self.remote.as_ref().is_none_or(|p| p.file_approval != Some(true)))
        {
            return Ok(());
        }
        self.published_token = Some(token);
        if kind == Kind::Files && self.physical() {
            let include_names = self.names_negotiated();
            self.counting = Some((token, include_names));
            self.native(Action::CountFileRoots { token, include_names });
        } else if kind != Kind::Files && self.on_demand() {
            self.publish_manifest(kind, None, None)?;
        } else {
            self.reading = Some(Reading { token, kind, pull: None });
            self.native(Action::Read { token, kind });
        }
        Ok(())
    }
    fn publish_manifest(&mut self, kind: Kind, file_root_count: Option<usize>, file_root_names: Option<RootNames>) -> Result<()> {
        let manifest = Manifest { revision: self.next_revision()?, kind, file_root_count, file_root_names };
        self.send(M::ClipboardManifest, &manifest);
        self.local_manifest = Some(manifest);
        Ok(())
    }
    fn start_outgoing(&mut self, payload: Payload, pull: Option<Pull>, explicit: bool) -> Result<()> {
        if let (Some(p), Payload::Files(paths)) = (pull, &payload)
            && self.local_manifest.as_ref().and_then(|m| m.file_root_count).is_some_and(|n| n != paths.len())
        {
            let reason = "源剪贴板顶层数量已改变";
            self.reject(p.revision, 0, reason);
            return Err(DeskError::invalid(reason));
        }
        if let (Some(p), Payload::Files(paths), Some(names)) = (pull, &payload, self.local_manifest.as_ref().and_then(|m| m.file_root_names.as_ref()))
            && paths.iter().map(|p| p.file_name().and_then(|n| n.to_str())).ne(names.0.iter().map(|n| Some(n.as_str())))
        {
            let reason = "源剪贴板顶层名称已改变";
            self.reject(p.revision, 0, reason);
            return Err(DeskError::invalid(reason));
        }
        let revision = self.next_revision()?;
        match Outgoing::new(payload, revision, pull.map(|p| p.request_id), explicit, &*self.backend) {
            Ok((transfer, begin)) => {
                self.outgoing = Some(transfer);
                self.deadline = Some(Instant::now() + if begin.kind == Kind::Files { OFFER_TIMEOUT } else { STALL });
                self.send(M::ClipboardBegin, &begin);
                Ok(())
            }
            Err(e) => {
                if let Some(p) = pull {
                    self.reject(p.revision, 0, &e.to_string());
                }
                Err(e)
            }
        }
    }
    fn peer(&mut self, msg: Message) -> Result<()> {
        match msg.kind {
            M::ClipboardManifest => {
                // This receiver uses Shell extraction and never requests a named manifest.
                let m: Manifest = read_control(&msg)?;
                if !self.on_demand() {
                    return Err(DeskError::invalid("对端未协商按需剪贴板"));
                }
                self.clock = self.clock.max(m.revision.counter);
                if self.newest.is_some_and(|r| r >= m.revision) {
                    return Ok(());
                }
                self.cancel("对端剪贴板已更新", true);
                self.local_manifest = None;
                self.newest = Some(m.revision);
                if m.file_root_count.is_some_and(|n| m.kind != Kind::Files || !(1..=MAX_PROMISED_FILE_ROOTS).contains(&n)) {
                    self.reject(m.revision, 0, "文件清单顶层数量无效");
                    self.native(Action::Status("文件清单顶层数量无效".into()));
                    return Ok(());
                }
                if self.receives && (m.kind != Kind::Files || self.physical()) {
                    self.native(Action::Advertise { revision: m.revision, kind: m.kind, file_root_count: m.file_root_count });
                    self.remote_manifest = Some(m);
                }
            }
            M::ClipboardPull => {
                let p: Pull = read_control(&msg)?;
                if !self.on_demand()
                    || (p.kind == Kind::Files && !self.physical())
                    || self.local_manifest.as_ref().is_none_or(|m| m.revision != p.revision || m.kind != p.kind)
                {
                    self.reject(p.revision, 0, "剪贴板内容已更新或不可用");
                    return Ok(());
                }
                if self.reading.as_ref().is_some_and(|r| r.pull.is_some_and(|r| r.request_id == p.request_id)) {
                    return Ok(());
                }
                if p.kind == Kind::Files && self.requested_file == Some(p.revision) {
                    return Ok(());
                }
                let Some((token, kind)) = self.local.filter(|(_, k)| *k == p.kind) else {
                    self.reject(p.revision, 0, "剪贴板内容已更新");
                    return Ok(());
                };
                if self.outgoing.is_some() || self.reading.is_some() {
                    self.reject(p.revision, 0, "已有剪贴板传输");
                    return Ok(());
                }
                self.reading = Some(Reading { token, kind, pull: Some(p) });
                if p.kind == Kind::Files {
                    self.requested_file = Some(p.revision);
                }
                self.deadline = Some(Instant::now() + STALL);
                self.native(Action::Read { token, kind });
            }
            M::ClipboardBegin => {
                let b: Begin = read_control(&msg)?;
                if let Err(e) = self.begin(b.clone()) {
                    self.reject(b.revision, 0, &e.to_string());
                    if self.incoming.is_none() && self.applying.is_none() && self.pull.is_some_and(|p| Some(p.request_id) == b.pull_request_id) {
                        self.cancel(&e.to_string(), false);
                    }
                    self.native(Action::Status(e.to_string()));
                }
            }
            M::ClipboardReceipt => {
                let r: Receipt = read_control(&msg)?;
                let Some(t) = self.outgoing.as_mut().filter(|t| t.revision == r.revision) else { return Ok(()) };
                if r.sequence < t.sequence {
                    return Ok(());
                }
                if r.sequence != t.sequence {
                    return Err(DeskError::invalid("剪贴板确认序号无效"));
                }
                if t.ending {
                    let files = t.kind == Kind::Files;
                    self.outgoing = None;
                    self.deadline = None;
                    if files {
                        self.native(Action::Status("对端已完成文件接收".into()));
                    }
                    return Ok(());
                }
                let next = t.advance(&*self.backend)?;
                self.effects.push(Output::Send(next));
                self.deadline = Some(Instant::now() + STALL);
            }
            M::ClipboardCancel => {
                let r: Receipt = read_control(&msg)?;
                if self.remote_manifest.as_ref().is_some_and(|m| m.revision == r.revision)
                    || self.pull.is_some_and(|p| p.revision == r.revision)
                    || self.incoming.as_ref().is_some_and(|t| t.begin.revision == r.revision)
                    || self.outgoing.as_ref().is_some_and(|t| t.revision == r.revision)
                    || self.applying.as_ref().is_some_and(|a| a.revision == r.revision)
                    || self.reading.as_ref().is_some_and(|a| a.pull.is_some_and(|p| p.revision == r.revision))
                {
                    self.cancel("剪贴板传输已取消", false);
                    let reason = match r.reason.as_deref() {
                        Some("对端选择不接收文件") => "对端拒绝了文件接收",
                        Some(text) if text.contains("超时") || text.contains("过期") => "对端等待剪贴板传输超时",
                        Some(text) if text.contains("空间") => "对端接收目录空间不足",
                        _ => "对端取消了剪贴板传输",
                    };
                    self.native(Action::Status(reason.into()));
                }
            }
            M::ClipboardEntry => {
                let e: Entry = read_control(&msg)?;
                let Some(t) = self.incoming.as_mut().filter(|t| t.begin.revision == e.revision) else { return Ok(()) };
                t.entry(&e, &*self.backend)?;
                self.ack(e.revision, e.sequence);
                self.deadline = Some(Instant::now() + STALL);
            }
            M::ClipboardChunk => {
                if msg.payload.len() < 32 {
                    return Err(DeskError::invalid("剪贴板分块长度无效"));
                }
                let r = Revision {
                    counter: u64::from_be_bytes(msg.payload[..8].try_into().unwrap()),
                    origin: Uuid::from_bytes(msg.payload[8..24].try_into().unwrap()),
                };
                let seq = u64::from_be_bytes(msg.payload[24..32].try_into().unwrap());
                let Some(t) = self.incoming.as_mut().filter(|t| t.begin.revision == r) else { return Ok(()) };
                if msg.payload.len() == 32 || msg.payload.len() > 32 + CHUNK {
                    return Err(DeskError::invalid("剪贴板分块长度无效"));
                }
                t.chunk(seq, &msg.payload[32..])?;
                self.ack(r, seq);
                self.deadline = Some(Instant::now() + STALL);
            }
            M::ClipboardEnd => {
                let r: Receipt = read_control(&msg)?;
                let Some(t) = self.incoming.take_if(|t| t.begin.revision == r.revision) else { return Ok(()) };
                let explicit_drop = t.begin.explicit_drop == Some(true);
                let kind = t.begin.kind;
                let payload = match t.finish(r.sequence, &*self.backend) {
                    Ok(p) => p,
                    Err(e) => {
                        self.reject(r.revision, r.sequence, &e.to_string());
                        self.cancel(&e.to_string(), false);
                        self.native(Action::Status(e.to_string()));
                        return Ok(());
                    }
                };
                if kind == Kind::Files && self.deferred_local && self.pull.is_none() {
                    self.saved_after_copy(r.revision, r.sequence);
                    return Ok(());
                }
                self.applying = Some(Applying { revision: r.revision, sequence: r.sequence, kind, explicit_drop });
                self.native(Action::Apply { revision: r.revision, manifest: self.pull.map(|p| p.revision), payload, explicit_drop });
                self.deadline = Some(Instant::now() + STALL);
            }
            _ => return Err(DeskError::invalid("收到不支持的剪贴板消息")),
        }
        Ok(())
    }
    fn begin(&mut self, b: Begin) -> Result<()> {
        b.validate()?;
        if self.incoming.as_ref().is_some_and(|t| t.begin.revision == b.revision) {
            return Ok(());
        }
        if self.newest.is_some_and(|r| r >= b.revision) {
            return Err(DeskError::invalid("已有更新的剪贴板内容"));
        }
        if b.explicit_drop == Some(true) && (!self.physical() || b.kind != Kind::Files) {
            return Err(DeskError::invalid("未协商拖入文件"));
        }
        if let Some(request_id) = b.pull_request_id {
            if self.incoming.is_some() || self.applying.is_some() {
                return Err(DeskError::invalid("按需粘贴请求已绑定传输"));
            }
            if self.pull.is_none_or(|p| p.request_id != request_id || p.kind != b.kind || p.revision.origin != b.revision.origin || p.revision >= b.revision)
                || b.explicit_drop == Some(true)
            {
                return Err(DeskError::invalid("按需粘贴请求已失效"));
            }
            if self.remote_manifest.as_ref().and_then(|m| m.file_root_count).is_some_and(|n| b.root_count != Some(n)) {
                return Err(DeskError::invalid("文件传输顶层数量与粘贴清单不符"));
            }
        } else {
            if self.physical() && b.kind == Kind::Files && b.explicit_drop != Some(true) {
                return Err(DeskError::invalid("文件未经本机粘贴请求"));
            }
            if !self.receives && b.kind != Kind::Files {
                return Err(DeskError::invalid("当前未接收自动更新"));
            }
            self.cancel("对端有新的剪贴板内容", true);
        }
        self.clock = self.clock.max(b.revision.counter);
        self.local_manifest = None;
        self.newest = Some(b.revision);
        let t = Incoming::new(b);
        if t.waiting {
            self.native(Action::FileOffer(t.offer()));
            self.deadline = Some(Instant::now() + OFFER_TIMEOUT);
        } else {
            self.ack(t.begin.revision, 0);
            self.deadline = Some(Instant::now() + STALL);
        }
        self.incoming = Some(t);
        Ok(())
    }
}
