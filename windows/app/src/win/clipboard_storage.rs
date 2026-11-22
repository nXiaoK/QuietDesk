use quietdesk_core::clipboard::{StorageBackend, validate_filename};
use std::fs::{File, Metadata, OpenOptions};
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::os::windows::io::AsRawHandle;
use std::path::{Component, Path, PathBuf, Prefix};
use windows::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_READ_ATTRIBUTES, FILE_SHARE_READ, FILE_SHARE_WRITE,
    GetDiskFreeSpaceExW, GetDriveTypeW,
};
use windows::core::PCWSTR;

pub struct WindowsStorage;
impl StorageBackend for WindowsStorage {
    fn file_id(&self, path: &Path, _: &Metadata, handle: Option<&File>) -> io::Result<(u64, u64)> {
        use windows::Win32::{
            Foundation::HANDLE,
            Storage::FileSystem::{BY_HANDLE_FILE_INFORMATION, GetFileInformationByHandle},
        };
        let opened;
        let file = match handle {
            Some(f) => f,
            None => {
                opened = OpenOptions::new()
                    .access_mode(FILE_READ_ATTRIBUTES.0)
                    .share_mode(FILE_SHARE_READ.0 | FILE_SHARE_WRITE.0)
                    .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
                    .open(path)?;
                &opened
            }
        };
        let mut info = BY_HANDLE_FILE_INFORMATION::default();
        unsafe { GetFileInformationByHandle(HANDLE(file.as_raw_handle()), &mut info) }.map_err(|e| io::Error::other(e.message()))?;
        if info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0 {
            return Err(io::Error::other("文件已变为重解析点"));
        }
        Ok((u64::from(info.dwVolumeSerialNumber), u64::from(info.nFileIndexHigh) << 32 | u64::from(info.nFileIndexLow)))
    }
    fn finish_directory(&self, path: &Path, modified: std::time::SystemTime, _: u32) -> io::Result<()> {
        let file = OpenOptions::new()
            .access_mode(windows::Win32::Storage::FileSystem::FILE_WRITE_ATTRIBUTES.0 | FILE_READ_ATTRIBUTES.0)
            .share_mode(FILE_SHARE_READ.0 | FILE_SHARE_WRITE.0)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS.0 | FILE_FLAG_OPEN_REPARSE_POINT.0)
            .open(path)?;
        let meta = file.metadata()?;
        if !meta.is_dir() || self.is_link(&meta) {
            return Err(io::Error::other("接收的目录已变化"));
        }
        file.set_modified(modified)
    }
    fn local_path(&self, path: &Path) -> io::Result<()> {
        let denied = || io::Error::other("仅允许本机磁盘上的普通路径");
        let mut components = path.components();
        let Some(Component::Prefix(prefix)) = components.next() else { return Err(denied()) };
        let (Prefix::Disk(letter) | Prefix::VerbatimDisk(letter)) = prefix.kind() else { return Err(denied()) };
        if components.next() != Some(Component::RootDir) {
            return Err(denied());
        }
        let drive = [u16::from(letter), u16::from(b':'), u16::from(b'\\'), 0];
        // Removable, fixed, CD-ROM and RAM disks are local. Reject mapped drives and unknown roots.
        if !matches!(unsafe { GetDriveTypeW(PCWSTR(drive.as_ptr())) }, 2 | 3 | 5 | 6) {
            return Err(denied());
        }
        let mut current = PathBuf::from(prefix.as_os_str());
        current.push("\\");
        for component in components {
            let Component::Normal(name) = component else { return Err(denied()) };
            let name = name.to_str().ok_or_else(denied)?;
            validate_filename(name).map_err(|_| denied())?;
            current.push(name);
            match std::fs::symlink_metadata(&current) {
                Ok(m) if self.is_link(&m) => return Err(denied()),
                Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
                _ => {}
            }
        }
        Ok(())
    }
    fn available_bytes(&self, directory: &Path) -> io::Result<u64> {
        let wide: Vec<u16> = directory.as_os_str().encode_wide().chain(Some(0)).collect();
        let mut bytes = 0;
        unsafe { GetDiskFreeSpaceExW(PCWSTR(wide.as_ptr()), Some(&mut bytes), None, None) }.map_err(|e| io::Error::other(e.message()))?;
        Ok(bytes)
    }
    fn is_link(&self, metadata: &Metadata) -> bool {
        metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0
    }
    fn open_source(&self, path: &Path) -> io::Result<File> {
        OpenOptions::new().read(true).share_mode(FILE_SHARE_READ.0).custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0).open(path)
    }
    fn hold_directory(&self, path: &Path) -> io::Result<Option<File>> {
        let file = OpenOptions::new()
            .access_mode(FILE_READ_ATTRIBUTES.0)
            .share_mode(FILE_SHARE_READ.0 | FILE_SHARE_WRITE.0)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS.0 | FILE_FLAG_OPEN_REPARSE_POINT.0)
            .open(path)?;
        let meta = file.metadata()?;
        if !meta.is_dir() || self.is_link(&meta) {
            return Err(io::Error::other("目录是重解析点或已替换"));
        }
        Ok(Some(file))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{Duration, SystemTime};
    #[test]
    fn only_local_files_are_examined_and_replacements_have_a_distinct_windows_file_id() {
        let backend = WindowsStorage;
        for invalid in [r"\\server\share\file", r"\\?\UNC\server\share\file", r"\\.\pipe\clipboard", r"C:\CON", r"C:\file:stream"] {
            assert!(backend.local_path(Path::new(invalid)).is_err());
        }
        let root = std::env::temp_dir().join(format!("quietdesk-files-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        let path = root.join("picked");
        let stamp = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_001);
        let write = || {
            fs::write(&path, b"a").unwrap();
            File::options().write(true).open(&path).unwrap().set_modified(stamp).unwrap();
        };
        write();
        backend.local_path(&path).unwrap();
        assert!(backend.available_bytes(&root).unwrap() > 0);
        let original = backend.file_id(&path, &fs::symlink_metadata(&path).unwrap(), None).unwrap();
        {
            let file = backend.open_source(&path).unwrap();
            assert_eq!(original, backend.file_id(&path, &file.metadata().unwrap(), Some(&file)).unwrap());
        }
        fs::rename(&path, root.join("previous")).unwrap();
        write();
        assert_ne!(original, backend.file_id(&path, &fs::symlink_metadata(&path).unwrap(), None).unwrap());
        fs::remove_dir_all(root).unwrap();
    }
}
