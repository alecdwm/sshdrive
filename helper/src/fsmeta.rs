//! One `lstat` turned into the metadata every event carries.
//!
//! `lstat`, never `stat`: a symlink is a leaf item and is never followed (DESIGN.md
//! sections 5.7 and 9.1). A link's own size and mtime are what the agent stores for it.

use crate::proto::Meta;
use std::fs::Metadata;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

pub struct Stat {
    pub meta: Meta,
    pub is_dir: bool,
    pub is_symlink: bool,
    /// Change time in whole seconds; the sweep's window is a ctime comparison, because
    /// ctime moves on `chmod`, `chown` and on writes that preserve mtime and mtime does
    /// not (section 6.4).
    pub ctime: i64,
}

pub fn lstat(path: &Path) -> Option<Stat> {
    let metadata = std::fs::symlink_metadata(path).ok()?;
    Some(from_metadata(&metadata))
}

pub fn from_metadata(metadata: &Metadata) -> Stat {
    let file_type = metadata.file_type();
    let is_dir = file_type.is_dir();
    let is_symlink = file_type.is_symlink();
    Stat {
        meta: Meta {
            kind: Some(if is_dir { "d" } else { "f" }),
            size: Some(metadata.size()),
            mtime_ns: Some(metadata.mtime() as i128 * 1_000_000_000 + metadata.mtime_nsec() as i128),
            inode: Some(metadata.ino()),
            mode: Some(metadata.mode() & 0o7777),
            uid: Some(metadata.uid()),
            gid: Some(metadata.gid()),
        },
        is_dir,
        is_symlink,
        ctime: metadata.ctime(),
    }
}

/// True for anything that is not a regular file, a directory or a symlink. Section 5.3
/// stores only those three; a fifo the helper reported would make the agent `lstat`
/// something it will then refuse anyway.
pub fn is_special(metadata: &Metadata) -> bool {
    let t = metadata.file_type();
    !(t.is_file() || t.is_dir() || t.is_symlink())
}

pub fn now_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
