use super::storage::{self, Data, Part, SourceFile, Staging, disk};
use super::{CHUNK, FileOffer, Kind, MAX_FILE_ENTRIES, MAX_PNG_BYTES, MAX_TEXT_BYTES, Payload, Revision, StorageBackend};
use crate::error::{DeskError, Result};
use crate::wire::{MAXIMUM_CONTROL_BYTES, Message, MessageKind as M};
use serde::{Deserialize, Serialize};
use std::collections::{HashSet, VecDeque};
use std::fs::File;
use std::io::{Cursor, Read, Write};
use std::path::Path;
use std::time::{Duration, SystemTime};
use uuid::Uuid;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Begin {
    pub revision: Revision,
    pub sequence: u64,
    #[serde(rename = "type")]
    pub kind: Kind,
    pub count: usize,
    pub bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub names: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_count: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    chunk_window: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    independent_file_lane: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub explicit_drop: Option<bool>,
    #[serde(rename = "pullRequestID", default, with = "uuid::serde::hyphenated::option", skip_serializing_if = "Option::is_none")]
    pub pull_request_id: Option<Uuid>,
}
impl Begin {
    pub fn validate(&self) -> Result<()> {
        if self.sequence != 0 || self.count == 0 || self.count > MAX_FILE_ENTRIES || self.chunk_window == Some(true) || self.independent_file_lane == Some(true)
        {
            return Err(DeskError::invalid("剪贴板传输信息不兼容"));
        }
        if self.kind == Kind::Files {
            if self.root_count.is_some_and(|c| c == 0 || c > self.count)
                || self.names.as_ref().is_some_and(|n| {
                    n.len() > self.root_count.unwrap_or(self.count).min(3)
                        || n.iter().any(|s| s.is_empty() || s.len() > 256 || s.contains(['/', '\\']) || s.chars().any(storage::unsafe_label_char))
                })
            {
                return Err(DeskError::invalid("文件接收预览信息无效"));
            }
        } else if self.count != 1
            || self.root_count.is_some()
            || self.names.is_some()
            || self.bytes > if self.kind == Kind::Text { MAX_TEXT_BYTES as u64 } else { MAX_PNG_BYTES as u64 }
        {
            return Err(DeskError::invalid("剪贴板内容超过大小上限或格式无效"));
        }
        Ok(())
    }
}
#[derive(Deserialize, Serialize)]
pub(super) struct Entry {
    pub revision: Revision,
    pub sequence: u64,
    path: String,
    directory: bool,
    bytes: u64,
    mode: u32,
    modified: f64,
}
#[derive(Clone, Deserialize, Serialize)]
pub(super) struct Receipt {
    pub revision: Revision,
    pub sequence: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}
impl Receipt {
    pub fn ok(revision: Revision, sequence: u64) -> Self {
        Self { revision, sequence, reason: None }
    }
    pub fn cancel(revision: Revision, sequence: u64, reason: &str) -> Self {
        Self { revision, sequence, reason: Some(reason.into()) }
    }
}
fn control<T: Serialize>(kind: M, v: &T) -> Result<Message> {
    let m = Message::json(kind, v)?;
    if m.payload.len() > MAXIMUM_CONTROL_BYTES {
        return Err(DeskError::invalid("剪贴板文件信息过大"));
    }
    Ok(m)
}
fn png_info(data: &[u8]) -> Result<()> {
    // Validate a complete PNG frame, with bounded decoder allocation, before accepting it for native use.
    let mut decoder = png::Decoder::new(Cursor::new(data));
    decoder.set_limits(png::Limits { bytes: MAX_PNG_BYTES });
    let invalid = || DeskError::invalid("剪贴板 PNG 格式无效或解码尺寸过大");
    let mut png = decoder.read_info().map_err(|_| invalid())?;
    let size = png.output_buffer_size().filter(|s| *s <= MAX_PNG_BYTES).ok_or_else(invalid)?;
    png.next_frame(&mut vec![0; size]).map_err(|_| invalid())?;
    png.finish().map_err(|_| invalid())?;
    Ok(())
}
enum Reader {
    Memory(Cursor<Vec<u8>>),
    File(File, SourceFile),
}
pub(super) struct Outgoing {
    pub kind: Kind,
    pub revision: Revision,
    pub sequence: u64,
    pub ending: bool,
    parts: VecDeque<Part>,
    reader: Option<Reader>,
    remaining: u64,
}
impl Outgoing {
    pub fn new(payload: Payload, revision: Revision, pull_request_id: Option<Uuid>, explicit: bool, backend: &dyn StorageBackend) -> Result<(Self, Begin)> {
        let kind = payload.kind();
        let (parts, names, root_count) = match payload {
            Payload::Files(paths) => {
                let root_count = paths.len();
                let parts = storage::catalogue(paths, backend)?;
                let names = parts.iter().filter(|p| !p.name.contains('/')).take(3).map(|p| storage::preview(&p.name)).collect();
                (parts, Some(names), Some(root_count))
            }
            content => {
                let bytes = match content {
                    Payload::Text(text) => text.into_bytes(),
                    Payload::Png(b) => b,
                    Payload::Files(_) => unreachable!(),
                };
                if bytes.len() > if kind == Kind::Text { MAX_TEXT_BYTES } else { MAX_PNG_BYTES } {
                    return Err(DeskError::invalid("剪贴板内容超过大小上限"));
                }
                if kind == Kind::Png {
                    png_info(&bytes)?;
                }
                (
                    vec![Part { name: "content".into(), directory: false, bytes: bytes.len() as u64, modified: 0.0, mode: 0o600, data: Data::Memory(bytes) }],
                    None,
                    None,
                )
            }
        };
        let bytes = parts.iter().try_fold(0u64, |a, p| a.checked_add(p.bytes)).ok_or_else(|| DeskError::invalid("文件总大小超出范围"))?;
        let begin = Begin {
            revision,
            sequence: 0,
            kind,
            count: parts.len(),
            bytes,
            names,
            root_count,
            chunk_window: None,
            independent_file_lane: None,
            explicit_drop: explicit.then_some(true),
            pull_request_id,
        };
        Ok((Self { kind, revision, sequence: 0, ending: false, parts: parts.into(), reader: None, remaining: 0 }, begin))
    }
    pub fn advance(&mut self, backend: &dyn StorageBackend) -> Result<Message> {
        self.sequence += 1;
        if self.remaining > 0 {
            let n = self.remaining.min(CHUNK as u64) as usize;
            let mut bytes = Vec::with_capacity(32 + n);
            bytes.extend(self.revision.counter.to_be_bytes());
            bytes.extend(self.revision.origin.as_bytes());
            bytes.extend(self.sequence.to_be_bytes());
            bytes.resize(32 + n, 0);
            let read = match self.reader.as_mut().ok_or_else(|| DeskError::invalid("剪贴板源内容不可用"))? {
                Reader::Memory(c) => c.read_exact(&mut bytes[32..]),
                Reader::File(f, _) => f.read_exact(&mut bytes[32..]),
            };
            disk(read)?;
            self.remaining -= n as u64;
            return Ok(Message::new(M::ClipboardChunk, bytes));
        }
        if let Some(Reader::File(f, p)) = self.reader.take() {
            p.verify(&f, backend)?;
        }
        if let Some(part) = self.parts.pop_front() {
            self.reader = match part.data {
                Data::Memory(bytes) => Some(Reader::Memory(Cursor::new(bytes))),
                Data::File(p) => Some(Reader::File(p.open(backend)?, p)),
                Data::Directory => None,
            };
            self.remaining = part.bytes;
            return control(
                M::ClipboardEntry,
                &Entry {
                    revision: self.revision,
                    sequence: self.sequence,
                    path: part.name,
                    directory: part.directory,
                    bytes: part.bytes,
                    mode: part.mode,
                    modified: part.modified,
                },
            );
        }
        self.ending = true;
        control(M::ClipboardEnd, &Receipt::ok(self.revision, self.sequence))
    }
}

pub(super) struct Incoming {
    pub begin: Begin,
    pub sequence: u64,
    pub waiting: bool,
    file: Option<File>,
    file_metadata: Option<(SystemTime, u32)>,
    directories: Vec<(String, SystemTime, u32)>,
    stage: Option<Staging>,
    memory: Vec<u8>,
    paths: HashSet<String>,
    roots: Vec<String>,
    path_bytes: usize,
    received: u64,
    remaining: u64,
}
impl Incoming {
    pub fn new(begin: Begin) -> Self {
        Self {
            waiting: begin.kind == Kind::Files,
            begin,
            sequence: 0,
            stage: None,
            file: None,
            file_metadata: None,
            directories: Vec::new(),
            memory: Vec::new(),
            paths: HashSet::new(),
            roots: Vec::new(),
            path_bytes: 0,
            received: 0,
            remaining: 0,
        }
    }
    pub fn offer(&self) -> FileOffer {
        FileOffer {
            revision: self.begin.revision,
            names: self.begin.names.clone().unwrap_or_default(),
            roots: self.begin.root_count.unwrap_or(self.begin.count),
            entries: self.begin.count,
            bytes: self.begin.bytes,
            explicit_drop: self.begin.explicit_drop == Some(true),
        }
    }
    pub fn accept(&mut self, storage: &Path, backend: &dyn StorageBackend) -> Result<()> {
        self.stage = Some(Staging::new(storage, self.begin.bytes, backend)?);
        self.waiting = false;
        Ok(())
    }
    fn next(&self, seq: u64) -> Result<()> {
        if self.waiting || self.sequence.checked_add(1) != Some(seq) {
            return Err(DeskError::invalid("文件尚未确认或剪贴板传输序号无效"));
        }
        Ok(())
    }
    pub fn entry(&mut self, e: &Entry, backend: &dyn StorageBackend) -> Result<()> {
        self.next(e.sequence)?;
        if self.remaining != 0
            || self.paths.len() >= self.begin.count
            || e.mode > 0o7777
            || !e.modified.is_finite()
            || e.bytes > self.begin.bytes - self.received
            || (e.directory && e.bytes != 0)
            || (self.begin.kind != Kind::Files && (e.path != "content" || e.directory || e.bytes != self.begin.bytes))
        {
            return Err(DeskError::invalid("剪贴板条目与传输清单不符"));
        }
        storage::validate_path(&e.path)?;
        self.path_bytes += e.path.len();
        if self.path_bytes > 64 * 1024 * 1024 || !self.paths.insert(e.path.to_lowercase()) {
            return Err(DeskError::invalid("剪贴板文件重复或路径信息过大"));
        }
        if let Some(stage) = &self.stage {
            let root = e.path.split('/').next().unwrap();
            if self.roots.last().is_none_or(|r| r != root) {
                if root != e.path
                    || self.begin.root_count.is_some_and(|n| self.roots.len() >= n)
                    || self.begin.names.as_ref().and_then(|names| names.get(self.roots.len())).is_some_and(|n| n != &storage::preview(root))
                {
                    return Err(DeskError::invalid("文件内容与确认信息不一致"));
                }
                self.roots.push(root.to_string());
            }
            let delta = Duration::try_from_secs_f64(e.modified.abs()).map_err(|_| DeskError::invalid("文件修改时间无效"))?;
            let modified = if e.modified < 0.0 { SystemTime::UNIX_EPOCH.checked_sub(delta) } else { SystemTime::UNIX_EPOCH.checked_add(delta) }
                .ok_or_else(|| DeskError::invalid("文件修改时间无效"))?;
            if let (Some(file), Some((time, mode))) = (self.file.take(), self.file_metadata.take()) {
                disk(storage::set_metadata(&file, time, mode, false))?;
            }
            self.file = stage.entry(&e.path, e.directory, backend)?;
            if e.directory {
                self.directories.push((e.path.clone(), modified, e.mode));
            } else {
                self.file_metadata = Some((modified, e.mode));
            }
        }
        self.sequence = e.sequence;
        self.remaining = e.bytes;
        Ok(())
    }
    pub fn chunk(&mut self, seq: u64, data: &[u8]) -> Result<()> {
        self.next(seq)?;
        if data.len() as u64 > self.remaining {
            return Err(DeskError::invalid("剪贴板分块超出声明大小"));
        }
        if let Some(file) = &mut self.file {
            disk(file.write_all(data))?;
        } else if self.stage.is_none() {
            self.memory.extend(data)
        } else {
            return Err(DeskError::invalid("剪贴板文件未打开"));
        }
        self.received += data.len() as u64;
        self.remaining -= data.len() as u64;
        self.sequence = seq;
        Ok(())
    }
    pub fn finish(mut self, seq: u64, backend: &dyn StorageBackend) -> Result<Payload> {
        self.next(seq)?;
        if self.remaining != 0
            || self.received != self.begin.bytes
            || self.paths.len() != self.begin.count
            || self.begin.root_count.is_some_and(|n| n != self.roots.len())
        {
            return Err(DeskError::invalid("剪贴板传输尚未完整结束"));
        }
        if let (Some(file), Some((time, mode))) = (self.file.take(), self.file_metadata.take()) {
            disk(storage::set_metadata(&file, time, mode, false))?;
        }
        match self.begin.kind {
            Kind::Text => String::from_utf8(self.memory).map(Payload::Text).map_err(|_| DeskError::invalid("文字编码无效")),
            Kind::Png => {
                png_info(&self.memory)?;
                Ok(Payload::Png(self.memory))
            }
            Kind::Files => {
                let stage = self.stage.take().ok_or_else(|| DeskError::invalid("未确认接收文件"))?;
                for (relative, time, mode) in self.directories.into_iter().rev() {
                    stage.finish_directory(&relative, time, mode, backend)?;
                }
                stage.commit(self.roots, backend).map(Payload::Files)
            }
        }
    }
}
