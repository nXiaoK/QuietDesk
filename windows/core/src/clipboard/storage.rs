use super::MAX_FILE_ENTRIES;
use crate::error::{DeskError, Result};
use std::collections::HashSet;
use std::fs::{self, File, Metadata, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;
use uuid::Uuid;

pub trait StorageBackend: Send + Sync {
    /// Checks an OS-native root before any filesystem lookup, including canonicalization.
    fn local_path(&self, _path: &Path) -> io::Result<()> {
        Ok(())
    }
    fn available_bytes(&self, directory: &Path) -> io::Result<u64>;
    fn is_link(&self, metadata: &Metadata) -> bool;
    fn open_source(&self, path: &Path) -> io::Result<File>;
    fn file_id(&self, _path: &Path, _metadata: &Metadata, _handle: Option<&File>) -> io::Result<(u64, u64)> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// Keeps the verified directory in place while opening a child on systems with share modes.
    fn hold_directory(&self, path: &Path) -> io::Result<Option<File>>;
    fn finish_directory(&self, path: &Path, modified: SystemTime, mode: u32) -> io::Result<()> {
        let file = self.hold_directory(path)?.ok_or(io::ErrorKind::Unsupported)?;
        set_metadata(&file, modified, mode, true)
    }
}
pub(super) fn set_metadata(file: &File, modified: SystemTime, _mode: u32, _directory: bool) -> io::Result<()> {
    file.set_modified(modified)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode((_mode & 0o777) | if _directory { 0o700 } else { 0o600 }))?;
    }
    Ok(())
}
pub(super) struct PortableStorage;
#[cfg(unix)]
impl StorageBackend for PortableStorage {
    fn file_id(&self, _: &Path, m: &Metadata, _: Option<&File>) -> io::Result<(u64, u64)> {
        use std::os::unix::fs::MetadataExt;
        Ok((m.dev(), m.ino()))
    }
    fn available_bytes(&self, directory: &Path) -> io::Result<u64> {
        use std::os::fd::AsRawFd;
        let file = File::open(directory)?;
        let mut info = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        if unsafe { libc::fstatvfs(file.as_raw_fd(), info.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let info = unsafe { info.assume_init() };
        Ok((info.f_bavail as u128 * info.f_frsize as u128).min(u64::MAX as u128) as u64)
    }
    fn is_link(&self, m: &Metadata) -> bool {
        m.is_symlink()
    }
    fn open_source(&self, path: &Path) -> io::Result<File> {
        use std::os::unix::fs::OpenOptionsExt;
        OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK).open(path)
    }
    fn hold_directory(&self, path: &Path) -> io::Result<Option<File>> {
        use std::os::unix::fs::OpenOptionsExt;
        OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY).open(path).map(Some)
    }
}
#[cfg(not(unix))]
impl StorageBackend for PortableStorage {
    fn local_path(&self, _: &Path) -> io::Result<()> {
        Err(io::ErrorKind::Unsupported.into())
    }
    fn available_bytes(&self, _: &Path) -> io::Result<u64> {
        Err(io::ErrorKind::Unsupported.into())
    }
    fn is_link(&self, m: &Metadata) -> bool {
        m.is_symlink()
    }
    fn open_source(&self, _: &Path) -> io::Result<File> {
        Err(io::ErrorKind::Unsupported.into())
    }
    fn hold_directory(&self, _: &Path) -> io::Result<Option<File>> {
        Err(io::ErrorKind::Unsupported.into())
    }
}
pub(super) fn disk<T>(result: io::Result<T>) -> Result<T> {
    result.map_err(|e| DeskError::platform(format!("剪贴板文件操作失败（{}）", e.kind())))
}
fn invalid() -> DeskError {
    DeskError::invalid("剪贴板文件路径无效或存在链接")
}
pub(super) fn validate_path(relative: &str) -> Result<()> {
    if relative.is_empty() || relative.len() > 3072 {
        return Err(invalid());
    }
    for name in relative.split('/') {
        validate_filename(name)?;
    }
    Ok(())
}
pub fn validate_filename(name: &str) -> Result<()> {
    if name.is_empty()
        || name.encode_utf16().count() > 255
        || name.ends_with([' ', '.'])
        || name.chars().any(|c| unsafe_label_char(c) || matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|'))
    {
        return Err(invalid());
    }
    let base = name.split('.').next().unwrap_or("").trim_end_matches(' ').to_uppercase();
    if matches!(&*base, "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$" | "CLOCK$")
        || base
            .strip_prefix("COM")
            .or_else(|| base.strip_prefix("LPT"))
            .is_some_and(|n| matches!(n, "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"))
    {
        return Err(invalid());
    }
    Ok(())
}
pub(super) fn unsafe_label_char(c: char) -> bool {
    c.is_control() || matches!(c,'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}')
}
pub(super) fn preview(s: &str) -> String {
    String::from_utf8_lossy(&s.as_bytes()[..s.len().min(120)]).into_owned()
}
fn folder(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new().mode(0o700).create(path)
    }
    #[cfg(not(unix))]
    {
        fs::create_dir(path)
    }
}
fn directory(backend: &dyn StorageBackend, path: &Path) -> Result<Option<File>> {
    let m = disk(fs::symlink_metadata(path))?;
    if backend.is_link(&m) || !m.is_dir() {
        return Err(invalid());
    }
    disk(backend.hold_directory(path))
}
fn subfolder(base: &Path, name: &str, backend: &dyn StorageBackend) -> Result<PathBuf> {
    let _hold = directory(backend, base)?;
    let path = base.join(name);
    if let Err(e) = folder(&path)
        && e.kind() != io::ErrorKind::AlreadyExists
    {
        return disk(Err(e));
    }
    directory(backend, &path)?;
    Ok(path)
}
#[derive(Clone)]
pub(super) struct SourceFile {
    pub path: PathBuf,
    pub root: PathBuf,
    pub len: u64,
    pub changed: SystemTime,
    id: (u64, u64),
}
impl SourceFile {
    pub fn open(&self, backend: &dyn StorageBackend) -> Result<File> {
        let _holds = parents(&self.root, &self.path, backend)?;
        let file = disk(backend.open_source(&self.path))?;
        self.verify(&file, backend)?;
        Ok(file)
    }
    pub fn verify(&self, file: &File, backend: &dyn StorageBackend) -> Result<()> {
        let m = disk(file.metadata())?;
        if backend.is_link(&m) || !m.is_file() || m.len() != self.len || disk(m.modified())? != self.changed {
            return Err(DeskError::invalid("源文件已变化"));
        }
        if disk(backend.file_id(&self.path, &m, Some(file)))? != self.id {
            return Err(DeskError::invalid("源文件已被替换"));
        }
        Ok(())
    }
}
fn parents(base: &Path, path: &Path, backend: &dyn StorageBackend) -> Result<Vec<Option<File>>> {
    let parent = path.parent().ok_or_else(invalid)?;
    let mut dir = base.to_path_buf();
    let mut held = vec![directory(backend, &dir)?];
    for part in parent.strip_prefix(base).map_err(|_| invalid())?.components() {
        dir.push(part);
        held.push(directory(backend, &dir)?);
    }
    Ok(held)
}
pub(super) struct Part {
    pub name: String,
    pub directory: bool,
    pub bytes: u64,
    pub modified: f64,
    pub mode: u32,
    pub data: Data,
}
pub(super) enum Data {
    Memory(Vec<u8>),
    File(SourceFile),
    Directory,
}
pub(super) fn catalogue(roots: Vec<PathBuf>, backend: &dyn StorageBackend) -> Result<Vec<Part>> {
    if roots.is_empty() || roots.len() > MAX_FILE_ENTRIES {
        return Err(DeskError::invalid("剪贴板文件数量无效"));
    }
    let mut todo = Vec::new();
    for root in roots.into_iter().rev() {
        disk(backend.local_path(&root))?;
        let base = root.parent().filter(|p| p.is_absolute()).ok_or_else(invalid)?;
        let name = root.file_name().and_then(|s| s.to_str()).ok_or_else(invalid)?.to_owned();
        let base = base.to_path_buf();
        todo.push((base.join(&name), base, name));
    }
    let mut parts = Vec::new();
    let mut seen = HashSet::new();
    let mut path_bytes = 0usize;
    while let Some((path, base, name)) = todo.pop() {
        validate_path(&name)?;
        path_bytes += name.len();
        if parts.len() >= MAX_FILE_ENTRIES || path_bytes > 64 * 1024 * 1024 || !seen.insert(name.to_lowercase()) {
            return Err(invalid());
        }
        let _holds = parents(&base, &path, backend)?;
        let m = disk(fs::symlink_metadata(&path))?;
        if backend.is_link(&m) || (!m.is_file() && !m.is_dir()) {
            return Err(invalid());
        }
        let changed = disk(m.modified())?;
        let modified = changed.duration_since(SystemTime::UNIX_EPOCH).map(|s| s.as_secs_f64()).unwrap_or_else(|e| -e.duration().as_secs_f64());
        #[cfg(unix)]
        let mode = {
            use std::os::unix::fs::MetadataExt;
            m.mode() & 0o777
        };
        #[cfg(not(unix))]
        let mode = if m.is_dir() { 0o700 } else { 0o600 };
        let bytes = if m.is_dir() { 0 } else { m.len() };
        let data = if m.is_dir() {
            let _hold = directory(backend, &path)?;
            let mut children = Vec::new();
            for item in disk(fs::read_dir(&path))? {
                if parts.len() + todo.len() + children.len() + 1 >= MAX_FILE_ENTRIES {
                    return Err(DeskError::invalid("文件条目过多"));
                }
                let item = disk(item)?;
                let child = item.file_name().into_string().map_err(|_| invalid())?;
                children.push((item.path(), base.clone(), format!("{name}/{child}")));
            }
            children.sort_by(|a, b| b.2.cmp(&a.2));
            todo.extend(children);
            Data::Directory
        } else {
            Data::File(SourceFile { id: disk(backend.file_id(&path, &m, None))?, path, root: base, len: bytes, changed })
        };
        parts.push(Part { name, directory: m.is_dir(), bytes, modified, mode, data });
    }
    Ok(parts)
}
pub(super) struct Staging {
    root: PathBuf,
    slot: PathBuf,
    complete: PathBuf,
    lease: Option<File>,
    _parents: [Option<File>; 3],
}
fn collect_abandoned(partial: &Path, backend: &dyn StorageBackend) -> Result<()> {
    for entry in disk(fs::read_dir(partial))? {
        let entry = disk(entry)?;
        if entry.file_name().to_str().is_none_or(|s| Uuid::parse_str(s).is_err()) {
            continue;
        }
        let slot = entry.path();
        let Ok(guard) = directory(backend, &slot) else { continue };
        let payload = slot.join("payload");
        let marker = slot.join(".lease");
        if !fs::symlink_metadata(&payload).is_ok_and(|m| m.is_dir() && !backend.is_link(&m))
            || !fs::symlink_metadata(&marker).is_ok_and(|m| m.is_file() && m.len() == 0 && !backend.is_link(&m))
        {
            continue;
        }
        let Ok(lease) = backend.open_source(&marker) else { continue };
        if lease.try_lock().is_err() {
            continue;
        }
        // Only the recorded staging payload is ours. Leave other directory contents alone.
        if fs::remove_dir_all(&payload).is_ok() {
            drop(lease);
            drop(guard);
            let _ = fs::remove_file(marker);
            let _ = fs::remove_dir(slot);
        }
    }
    Ok(())
}
impl Staging {
    pub fn new(storage: &Path, bytes: u64, backend: &dyn StorageBackend) -> Result<Self> {
        disk(backend.local_path(storage))?;
        if !storage.exists() {
            disk(fs::create_dir_all(storage))?;
        }
        let base_guard = directory(backend, storage)?;
        let storage = disk(fs::canonicalize(storage))?;
        let partial = subfolder(&storage, "partial", backend)?;
        let complete = subfolder(&storage, "received", backend)?;
        let parent_guards = [base_guard, directory(backend, &partial)?, directory(backend, &complete)?];
        collect_abandoned(&partial, backend)?;
        if bytes > disk(backend.available_bytes(&partial))? {
            return Err(DeskError::platform("接收目录的可用空间不足"));
        }
        let slot = partial.join(Uuid::new_v4().hyphenated().to_string());
        disk(folder(&slot))?;
        let mut staging = Self { root: slot.join("payload"), slot, complete, lease: None, _parents: parent_guards };
        let lease = disk(File::create_new(staging.slot.join(".lease")))?;
        disk(lease.lock())?;
        staging.lease = Some(lease);
        disk(folder(&staging.root))?;
        Ok(staging)
    }
    pub fn entry(&self, relative: &str, dir: bool, backend: &dyn StorageBackend) -> Result<Option<File>> {
        let path = self.root.join(relative);
        let _hold = parents(&self.root, &path, backend)?;
        if dir {
            disk(folder(&path))?;
            return Ok(None);
        }
        let mut open = OpenOptions::new();
        open.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            open.mode(0o600);
        }
        disk(open.open(path)).map(Some)
    }
    pub fn commit(self, roots: Vec<String>, backend: &dyn StorageBackend) -> Result<Vec<PathBuf>> {
        let _hold = directory(backend, &self.complete)?;
        directory(backend, &self.root)?;
        let dest = self.complete.join(Uuid::new_v4().hyphenated().to_string());
        disk(fs::rename(&self.root, &dest))?;
        Ok(roots.into_iter().map(|r| dest.join(r)).collect())
    }
    pub fn finish_directory(&self, relative: &str, modified: SystemTime, mode: u32, backend: &dyn StorageBackend) -> Result<()> {
        let path = self.root.join(relative);
        let _hold = parents(&self.root, &path, backend)?;
        disk(backend.finish_directory(&path, modified, mode))
    }
}
impl Drop for Staging {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
        self.lease.take();
        let _ = fs::remove_file(self.slot.join(".lease"));
        let _ = fs::remove_dir(&self.slot);
    }
}
