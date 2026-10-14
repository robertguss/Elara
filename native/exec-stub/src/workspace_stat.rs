use serde_json::{Value, json};
use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

const MAX_MANIFEST: u64 = 4 * 1024 * 1024;
const MAX_ENTRIES: usize = 32_768;
const MAX_FILE: u64 = 1024 * 1024;
const MAX_TOTAL: u64 = 8 * 1024 * 1024;

fn bounded_input(path: &Path) -> io::Result<Vec<u8>> {
    let mut input = Vec::new();
    File::open(path)?
        .take(MAX_MANIFEST + 1)
        .read_to_end(&mut input)?;
    if input.len() as u64 > MAX_MANIFEST {
        return Err(io::Error::other("inventory too large"));
    }
    Ok(input)
}

fn same_metadata(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
    a.dev() == b.dev()
        && a.ino() == b.ino()
        && a.size() == b.size()
        && a.mode() == b.mode()
        && a.mtime() == b.mtime()
        && a.mtime_nsec() == b.mtime_nsec()
        && a.ctime() == b.ctime()
        && a.ctime_nsec() == b.ctime_nsec()
}

pub fn blobs(manifest: &Path) -> io::Result<()> {
    let entries: Value = serde_json::from_slice(&bounded_input(manifest)?)?;
    let entries = entries
        .as_array()
        .ok_or_else(|| io::Error::other("invalid manifest"))?;
    if entries.len() > MAX_ENTRIES {
        return Err(io::Error::other("inventory too large"));
    }
    let mut total = 0;
    let mut sources = Vec::with_capacity(entries.len());
    for entry in entries {
        let source = entry.get("source").and_then(Value::as_str);
        let size = entry.get("size").and_then(Value::as_u64);
        let root = entry.get("root").and_then(Value::as_str);
        let (Some(source), Some(size), Some(root)) = (source, size, root) else {
            return Err(io::Error::other("invalid manifest entry"));
        };
        if size > MAX_FILE || size > MAX_TOTAL - total {
            return Err(io::Error::other("blob budget exceeded"));
        }
        total += size;
        let root = Path::new(root);
        let source = Path::new(source)
            .strip_prefix(root)
            .map_err(|_| io::Error::other("source outside root"))?;
        sources.push((root, source, size));
    }
    let output_path = manifest.with_extension("blobs");
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&output_path)?;
    let result = (|| {
        for (index, (root, source, size)) in sources.iter().enumerate() {
            let root = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
                .open(root)?;
            let (parent, name) = parent_and_leaf(&root, source)?;
            let fd = unsafe {
                libc::openat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            let mut file = unsafe { File::from_raw_fd(fd) };
            let before = file.metadata()?;
            if !before.is_file() || before.size() != *size {
                return Err(io::Error::other("blob type or size changed"));
            }
            let mut bytes = Vec::with_capacity(*size as usize + 1);
            (&mut file).take(size + 1).read_to_end(&mut bytes)?;
            if bytes.len() as u64 != *size || !same_metadata(&before, &file.metadata()?) {
                return Err(io::Error::other("blob changed during capture"));
            }
            let mut leaf = std::mem::MaybeUninit::<libc::stat>::uninit();
            if unsafe {
                libc::fstatat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    leaf.as_mut_ptr(),
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } != 0
            {
                return Err(io::Error::last_os_error());
            }
            let leaf = unsafe { leaf.assume_init() };
            #[cfg(target_os = "linux")]
            let device = leaf.st_dev;
            #[cfg(not(target_os = "linux"))]
            let device = leaf.st_dev as u64;
            if leaf.st_ino != before.ino()
                || device != before.dev()
                || leaf.st_mode & libc::S_IFMT != libc::S_IFREG
            {
                return Err(io::Error::other("blob path replaced during capture"));
            }
            let mark = index + 1;
            write!(output, "blob\nmark :{mark}\ndata {size}\n")?;
            output.write_all(&bytes)?;
            write!(output, "\nget-mark :{mark}\n")?;
        }
        output.write_all(b"done\n")?;
        output.flush()
    })();
    drop(output);
    if result.is_err() {
        std::fs::remove_file(output_path)?;
    }
    result
}

// Nanosecond fields alone do not prove equality: the caller must also reject
// timestamps near capture time (the racy-git window), and unsupported mounts.
pub fn run(root: &Path, paths: &Path) -> io::Result<Value> {
    let input = bounded_input(paths)?;
    let root = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(root)?;
    let mut entries = Vec::new();
    let mut remaining = MAX_TOTAL;
    for name in input.split(|b| *b == 0).filter(|name| !name.is_empty()) {
        if entries.len() >= MAX_ENTRIES {
            return Err(io::Error::other("inventory too large"));
        }
        let relative = Path::new(std::ffi::OsStr::from_bytes(name));
        if relative.is_absolute()
            || relative
                .components()
                .any(|c| !matches!(c, std::path::Component::Normal(_)))
        {
            return Err(io::Error::other("unsafe path"));
        }
        let entry = match relative_stat(&root, relative, &mut remaining) {
            Ok(entry) => entry,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Value::Null,
            Err(error) => return Err(error),
        };
        entries.push(entry);
    }
    Ok(Value::Array(entries))
}

fn parent_and_leaf(root: &File, path: &Path) -> io::Result<(File, CString)> {
    if path.is_absolute()
        || path
            .components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
    {
        return Err(io::Error::other("unsafe path"));
    }
    let mut parent = root.try_clone()?;
    let mut components = path.components().peekable();
    while let Some(component) = components.next() {
        let name = CString::new(component.as_os_str().as_bytes())?;
        if components.peek().is_some() {
            let fd = unsafe {
                libc::openat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            parent = unsafe { File::from_raw_fd(fd) };
        } else {
            return Ok((parent, name));
        }
    }
    Err(io::Error::other("unsafe path"))
}

fn relative_stat(root: &File, path: &Path, remaining: &mut u64) -> io::Result<Value> {
    let (parent, name) = parent_and_leaf(root, path)?;
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    let stat = unsafe { stat.assume_init() };
    let size = u64::try_from(stat.st_size).map_err(|_| io::Error::other("invalid size"))?;
    let kind = stat.st_mode & libc::S_IFMT;
    if kind == libc::S_IFDIR || (size <= MAX_FILE && size <= *remaining) {
        if kind != libc::S_IFDIR {
            *remaining -= size;
        }
        return Ok(json!({"mode": stat.st_mode, "size": size, "capture": true}));
    }
    #[cfg(target_os = "linux")]
    let device = stat.st_dev;
    #[cfg(not(target_os = "linux"))]
    let device = stat.st_dev as u64;
    Ok(json!({
        "mode": stat.st_mode, "size": stat.st_size, "inode": stat.st_ino,
        "device": device, "mtime": [stat.st_mtime, stat.st_mtime_nsec],
        "ctime": [stat.st_ctime, stat.st_ctime_nsec],
        "local": device == parent.metadata()?.dev() && local_filesystem(&parent), "capture": false,
    }))
}

fn local_filesystem(directory: &File) -> bool {
    let mut info = std::mem::MaybeUninit::<libc::statfs>::uninit();
    if unsafe { libc::fstatfs(directory.as_raw_fd(), info.as_mut_ptr()) } != 0 {
        return false;
    }
    let info = unsafe { info.assume_init() };
    #[cfg(target_os = "linux")]
    {
        // ext[234], XFS, Btrfs, tmpfs and overlay. Network, FUSE and unknown
        // mounts fail closed rather than assuming server timestamp coherence.
        matches!(
            info.f_type as u64,
            0xef53 | 0x58465342 | 0x9123683e | 0x01021994 | 0x794c7630
        )
    }
    #[cfg(target_os = "macos")]
    {
        let name = unsafe { std::ffi::CStr::from_ptr(info.f_fstypename.as_ptr()) };
        name.to_bytes() == b"apfs" && info.f_flags & libc::MNT_LOCAL as u32 != 0
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = info;
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Sandbox(PathBuf);

    impl Sandbox {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "elara-workspace-stat-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }

        fn manifest(&self, mut entries: Value) -> PathBuf {
            let path = self.0.join("manifest.json");
            if let Some(entries) = entries.as_array_mut() {
                for entry in entries {
                    entry["root"] = json!(self.0);
                }
            }
            std::fs::write(&path, serde_json::to_vec(&entries).unwrap()).unwrap();
            path
        }
    }

    impl Drop for Sandbox {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn blobs_binary_empty_and_exclusive_private_output() {
        let dir = Sandbox::new();
        let binary = dir.0.join("binary");
        let empty = dir.0.join("empty");
        std::fs::write(&binary, b"\0\xff\n").unwrap();
        std::fs::write(&empty, b"").unwrap();
        let manifest = dir.manifest(json!([
            {"source": binary, "size": 3}, {"source": empty, "size": 0}
        ]));
        blobs(&manifest).unwrap();
        let output = manifest.with_extension("blobs");
        let expected = b"blob\nmark :1\ndata 3\n\0\xff\n\nget-mark :1\nblob\nmark :2\ndata 0\n\nget-mark :2\ndone\n";
        assert_eq!(std::fs::read(&output).unwrap(), expected);
        assert_eq!(
            std::fs::metadata(&output).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            blobs(&manifest).unwrap_err().kind(),
            io::ErrorKind::AlreadyExists
        );
        assert_eq!(std::fs::read(output).unwrap(), expected);
    }

    #[test]
    fn blobs_reject_growth_and_shrink_without_partial_output() {
        let dir = Sandbox::new();
        let first = dir.0.join("first");
        let changing = dir.0.join("changing");
        std::fs::write(&first, b"ok").unwrap();
        for content in [b"grown".as_slice(), b"".as_slice()] {
            std::fs::write(&changing, b"old").unwrap();
            let manifest = dir.manifest(json!([
                {"source": first, "size": 2}, {"source": changing, "size": 3}
            ]));
            std::fs::write(&changing, content).unwrap();
            assert!(blobs(&manifest).is_err());
            assert!(!manifest.with_extension("blobs").exists());
        }
    }

    #[test]
    fn blobs_refuse_leaf_fifo_symlink_and_directory() {
        let dir = Sandbox::new();
        let fifo = dir.0.join("fifo");
        let name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        let link = dir.0.join("link");
        let empty = dir.0.join("empty");
        std::fs::write(&empty, b"").unwrap();
        symlink(&empty, &link).unwrap();
        for source in [&fifo, &link, &dir.0] {
            let manifest = dir.manifest(json!([{"source": source, "size": 0}]));
            assert!(blobs(&manifest).is_err());
            assert!(!manifest.with_extension("blobs").exists());
        }
    }

    #[test]
    fn blobs_enforce_manifest_and_byte_budgets() {
        let dir = Sandbox::new();
        for entries in [
            json!([{"source": "unused", "size": MAX_FILE + 1}]),
            json!(vec![json!({"source": "unused", "size": MAX_FILE}); 9]),
            json!(vec![
                json!({"source": "unused", "size": 0});
                MAX_ENTRIES + 1
            ]),
            json!([{"source": "unused", "size": -1}]),
        ] {
            let manifest = dir.manifest(entries);
            assert!(blobs(&manifest).is_err());
            assert!(!manifest.with_extension("blobs").exists());
        }
        let manifest = dir.0.join("manifest.json");
        std::fs::write(&manifest, vec![b' '; MAX_MANIFEST as usize + 1]).unwrap();
        assert!(blobs(&manifest).is_err());
        assert!(!manifest.with_extension("blobs").exists());
    }

    #[test]
    fn stat_refuses_ancestor_symlinks_but_preserves_leaf_evidence() {
        let dir = Sandbox::new();
        let nested = dir.0.join("nested");
        std::fs::create_dir(&nested).unwrap();
        std::fs::write(nested.join("file"), b"ok").unwrap();
        std::fs::write(nested.join("large"), vec![b'x'; MAX_FILE as usize + 1]).unwrap();
        symlink(&nested, dir.0.join("alias")).unwrap();
        let paths = dir.0.join("paths");
        std::fs::write(&paths, b"alias/file\0").unwrap();
        assert!(run(&dir.0, &paths).is_err());
        std::fs::write(&paths, b"nested/file\0alias\0missing\0nested/large\0").unwrap();
        let result = run(&dir.0, &paths).unwrap();
        let metadata = std::fs::metadata(nested.join("file")).unwrap();
        assert_eq!(result[0]["mode"], metadata.mode());
        assert_eq!(result[0]["size"], 2);
        assert_eq!(result[0]["capture"], true);
        assert_eq!(
            result[1]["mode"].as_u64().unwrap() & libc::S_IFMT as u64,
            libc::S_IFLNK as u64
        );
        assert!(result[2].is_null());
        let large = std::fs::metadata(nested.join("large")).unwrap();
        assert_eq!(result[3]["capture"], false);
        assert_eq!(result[3]["inode"], large.ino());
        assert_eq!(result[3]["device"], large.dev());
        assert_eq!(
            result[3]["ctime"],
            json!([large.ctime(), large.ctime_nsec()])
        );
    }
}
