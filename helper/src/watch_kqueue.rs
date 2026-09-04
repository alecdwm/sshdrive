//! The BSD and macOS watcher: kqueue on directories, plus the periodic sweep
//! (DESIGN.md section 6.4 tier 2).
//!
//! Section 6.4 is blunt about why this is not the same thing as inotify: "kqueue, the
//! only facility FreeBSD offers, reports content changes only through a descriptor held
//! open on each watched *file*, so a recursive watch on a TrueNAS Core share of a hundred
//! thousand files is a hundred thousand open descriptors and does not fit. On `freebsd`
//! the helper watches directories with kqueue for creates, deletes and renames, finds
//! content changes with its own `sweep` every 60 s over the roots it was given … and
//! `status` shows the change-detection line as `helper (kqueue + 60s sweep)` rather than
//! claiming push latency."
//!
//! A kqueue vnode event says only "this directory changed", never what changed in it, so
//! this keeps a name -> (inode, size, mtime) snapshot per watched directory and diffs. An
//! inode that leaves one directory's snapshot and appears in another's inside the same
//! batch is a rename, which is how this build keeps section 6.4's rename promise.

#![cfg(any(
    target_os = "freebsd",
    target_os = "macos",
    target_os = "netbsd",
    target_os = "openbsd",
    target_os = "dragonfly"
))]

use crate::fsmeta;
use crate::paths::{self, RootSet};
use crate::proto::{Coalescer, Meta, Op};
use crate::walk;
use std::collections::HashMap;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::io::RawFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub const MECHANISM: &str = "kqueue + 60s sweep";

/// How often the content sweep runs. Section 6.4 fixes it at 60 s.
pub const SWEEP_INTERVAL: Duration = Duration::from_secs(60);

#[cfg(target_os = "macos")]
const OPEN_FLAGS: libc::c_int = 0x8000 /* O_EVTONLY */ | libc::O_CLOEXEC;
#[cfg(not(target_os = "macos"))]
const OPEN_FLAGS: libc::c_int = libc::O_RDONLY | libc::O_CLOEXEC | libc::O_DIRECTORY;

const FFLAGS: u32 = libc::NOTE_WRITE
    | libc::NOTE_DELETE
    | libc::NOTE_RENAME
    | libc::NOTE_ATTRIB
    | libc::NOTE_EXTEND
    | libc::NOTE_LINK;

#[derive(Clone, PartialEq, Eq)]
struct Entry {
    inode: u64,
    size: u64,
    mtime_ns: i128,
    is_dir: bool,
}

struct Watch {
    relative: Vec<u8>,
    recursive: bool,
    snapshot: HashMap<Vec<u8>, Entry>,
}

pub struct Watcher {
    kq: RawFd,
    root: PathBuf,
    roots: RootSet,
    watches: HashMap<RawFd, Watch>,
    last_sweep: Instant,
    swept_at: i64,
    pub complaint: Option<String>,
}

impl Watcher {
    pub fn new(root: &Path) -> std::io::Result<Watcher> {
        let kq = unsafe { libc::kqueue() };
        if kq < 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(Watcher {
            kq,
            root: root.to_path_buf(),
            roots: RootSet::default(),
            watches: HashMap::new(),
            // The first sweep runs at once: it is what establishes the baseline the
            // agent's own index is diffed against after a restart.
            last_sweep: Instant::now() - SWEEP_INTERVAL,
            swept_at: 0,
            complaint: None,
        })
    }

    #[allow(dead_code)] // the same reporting hook the inotify build has
    pub fn watch_count(&self) -> usize {
        self.watches.len()
    }

    pub fn set_roots(&mut self, roots: RootSet) {
        for (fd, _) in self.watches.drain() {
            unsafe { libc::close(fd) };
        }
        self.roots = roots;
        let shallow = self.roots.shallow.clone();
        let recursive = self.roots.recursive.clone();
        for root in shallow {
            for directory in walk::directories_under(&self.root, &root, &self.roots, false) {
                self.add_one(&directory, false);
            }
        }
        for root in recursive {
            for directory in walk::directories_under(&self.root, &root, &self.roots, true) {
                self.add_one(&directory, true);
            }
        }
        // A root-set change resets the sweep clock too: the new roots have never been
        // looked at, and the agent is entitled to their current state now rather than in
        // up to a minute.
        self.last_sweep = Instant::now() - SWEEP_INTERVAL;
    }

    fn add_one(&mut self, relative: &[u8], recursive: bool) {
        if self.roots.is_excluded(relative) || self.watches.values().any(|w| w.relative == relative) {
            return;
        }
        let absolute = paths::absolute(&self.root, relative);
        let Ok(c) = std::ffi::CString::new(absolute.as_os_str().as_bytes()) else { return };
        // O_NOFOLLOW: a directory replaced by a symlink out of the root is not opened
        // (section 9.1), the same rule the inotify build gets from IN_DONT_FOLLOW.
        let fd = unsafe { libc::open(c.as_ptr(), OPEN_FLAGS | libc::O_NOFOLLOW) };
        if fd < 0 {
            if self.complaint.is_none() {
                self.complaint = Some(format!(
                    "could not watch {}: {}",
                    String::from_utf8_lossy(relative),
                    std::io::Error::last_os_error()
                ));
            }
            return;
        }
        let change = new_kevent(fd, libc::EV_ADD | libc::EV_CLEAR, FFLAGS);
        let registered =
            unsafe { libc::kevent(self.kq, &change, 1, std::ptr::null_mut(), 0, std::ptr::null()) };
        if registered < 0 {
            unsafe { libc::close(fd) };
            if self.complaint.is_none() {
                self.complaint = Some(format!(
                    "could not register {}: {}",
                    String::from_utf8_lossy(relative),
                    std::io::Error::last_os_error()
                ));
            }
            return;
        }
        let snapshot = self.snapshot(relative);
        self.watches.insert(fd, Watch { relative: relative.to_vec(), recursive, snapshot });
    }

    fn snapshot(&self, relative: &[u8]) -> HashMap<Vec<u8>, Entry> {
        let mut out = HashMap::new();
        let Ok(entries) = std::fs::read_dir(paths::absolute(&self.root, relative)) else {
            return out;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.as_os_str().as_bytes().to_vec();
            if paths::is_ignored(&name) {
                continue;
            }
            let Ok(metadata) = std::fs::symlink_metadata(entry.path()) else { continue };
            if fsmeta::is_special(&metadata) {
                continue;
            }
            let stat = fsmeta::from_metadata(&metadata);
            out.insert(
                name,
                Entry {
                    inode: stat.meta.inode.unwrap_or(0),
                    size: stat.meta.size.unwrap_or(0),
                    mtime_ns: stat.meta.mtime_ns.unwrap_or(0),
                    is_dir: stat.is_dir,
                },
            );
        }
        out
    }

    pub fn poll(&mut self, timeout: Duration, out: &mut Coalescer) {
        let limit = timeout.min(SWEEP_INTERVAL);
        let mut events: [libc::kevent; 64] = unsafe { std::mem::zeroed() };
        let spec = libc::timespec {
            tv_sec: limit.as_secs() as libc::time_t,
            tv_nsec: limit.subsec_nanos() as _,
        };
        let count = unsafe {
            libc::kevent(self.kq, std::ptr::null(), 0, events.as_mut_ptr(), events.len() as _, &spec)
        };
        let mut removed: Vec<(Vec<u8>, Entry)> = Vec::new();
        let mut added: Vec<(Vec<u8>, Entry)> = Vec::new();
        for index in 0..count.max(0) as usize {
            let fd = events[index].ident as RawFd;
            let Some(watch) = self.watches.get(&fd) else { continue };
            let relative = watch.relative.clone();
            let recursive = watch.recursive;
            if events[index].fflags & (libc::NOTE_DELETE | libc::NOTE_RENAME) != 0 {
                self.watches.remove(&fd);
                unsafe { libc::close(fd) };
                continue;
            }
            let fresh = self.snapshot(&relative);
            let Some(watch) = self.watches.get_mut(&fd) else { continue };
            let previous = std::mem::replace(&mut watch.snapshot, fresh.clone());
            for (name, entry) in &previous {
                match fresh.get(name) {
                    None => removed.push((paths::join(&relative, name), entry.clone())),
                    Some(now) if now.inode != entry.inode => {
                        removed.push((paths::join(&relative, name), entry.clone()));
                        added.push((paths::join(&relative, name), now.clone()));
                    }
                    Some(now) if now.size != entry.size || now.mtime_ns != entry.mtime_ns => {
                        let path = paths::join(&relative, name);
                        out.push(Op::Modify, path.clone(), self.meta_of(&path));
                    }
                    Some(_) => {}
                }
            }
            for (name, entry) in &fresh {
                if !previous.contains_key(name) {
                    added.push((paths::join(&relative, name), entry.clone()));
                }
            }
            if recursive {
                for (path, entry) in &added {
                    if entry.is_dir {
                        let directories =
                            walk::directories_under(&self.root, path, &self.roots, true);
                        for directory in directories {
                            self.add_one(&directory, true);
                        }
                    }
                }
            }
        }

        // An inode that left one name and arrived at another in the same batch is a
        // rename, and section 6.4 wants it reported as one.
        for (from, gone) in &removed {
            // Inode 0 means the snapshot never learned one, and matching on it would pair
            // two unrelated names.
            let position = if gone.inode == 0 {
                None
            } else {
                added.iter().position(|(path, entry)| entry.inode == gone.inode && path != from)
            };
            match position {
                Some(position) => {
                    let (to, _) = added.remove(position);
                    let meta = self.meta_of(&to);
                    out.push_rename(from.clone(), to, meta);
                }
                None => out.push(Op::Delete, from.clone(), Meta::default()),
            }
        }
        for (path, _) in added {
            let meta = self.meta_of(&path);
            out.push(Op::Create, path, meta);
        }

        if self.last_sweep.elapsed() >= SWEEP_INTERVAL {
            self.run_sweep(out);
        }
        if let Some(complaint) = self.complaint.take() {
            out.push_overflow(complaint);
        }
    }

    /// The 60-second content sweep. It is the only thing on this platform that sees an
    /// in-place edit, because kqueue would need a descriptor per file to report one.
    fn run_sweep(&mut self, out: &mut Coalescer) {
        let now = fsmeta::now_seconds();
        let mut options = walk::SweepOptions::new(&self.root, &self.roots);
        // One second of overlap, for the same reason section 6.4's tier 1 window has a
        // minute of it: a change landing in the same second as the last sweep must not
        // fall between two windows.
        options.since = if self.swept_at == 0 { None } else { Some(self.swept_at - 1) };
        for event in walk::sweep(&options) {
            match event {
                crate::proto::Event::Change { op, path, meta } => out.push(op, path, meta),
                crate::proto::Event::Overflow { reason } => out.push_overflow(reason),
                _ => {}
            }
        }
        self.swept_at = now;
        self.last_sweep = Instant::now();
    }

    fn meta_of(&self, relative: &[u8]) -> Meta {
        fsmeta::lstat(&paths::absolute(&self.root, relative))
            .map(|s| s.meta)
            .unwrap_or_default()
    }
}

fn new_kevent(fd: RawFd, flags: u16, fflags: u32) -> libc::kevent {
    let mut event: libc::kevent = unsafe { std::mem::zeroed() };
    event.ident = fd as _;
    event.filter = libc::EVFILT_VNODE;
    event.flags = flags as _;
    event.fflags = fflags;
    event
}

impl Drop for Watcher {
    fn drop(&mut self) {
        for (fd, _) in self.watches.drain() {
            unsafe { libc::close(fd) };
        }
        unsafe { libc::close(self.kq) };
    }
}
