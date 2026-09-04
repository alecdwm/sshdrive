//! The Linux watcher: inotify, used directly (DESIGN.md section 6.4 tier 2).
//!
//! Directly rather than through `inotifywait`, which is what section 14 describes and
//! deliberately did not build: the tool is not installed on most NAS boxes, and it does
//! not expose the rename cookie, so it cannot report a rename at all. Reading the
//! descriptor ourselves gives us the cookie, the queue-overflow signal, and one process
//! instead of two.
//!
//! Three details are not optional:
//!
//! - **`IN_DONT_FOLLOW`**, so a directory replaced by a symlink to `/etc` is not watched
//!   through (section 9.1 - the same trap SFTP `opendir` walked into, 2026-09-04).
//! - **`IN_EXCL_UNLINK`**, so an editor holding a deleted file open stops producing
//!   events for a path that no longer exists.
//! - **`IN_MODIFY` is left out.** `IN_CLOSE_WRITE` reports the finished write; watching
//!   `IN_MODIFY` too would turn one `dd` into thousands of events for one path and buy
//!   nothing, since the agent re-`stat`s whatever it is told about.

use crate::fsmeta;
use crate::paths::{self, RootSet};
use crate::proto::{Coalescer, Meta, Op};
use crate::walk;
use std::collections::HashMap;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

const MASK: u32 = libc::IN_CREATE
    | libc::IN_DELETE
    | libc::IN_CLOSE_WRITE
    | libc::IN_MOVED_FROM
    | libc::IN_MOVED_TO
    | libc::IN_ATTRIB
    | libc::IN_MOVE_SELF
    | libc::IN_DELETE_SELF
    | libc::IN_EXCL_UNLINK
    | libc::IN_DONT_FOLLOW
    | libc::IN_ONLYDIR;

pub const MECHANISM: &str = "inotify";

pub struct Watcher {
    fd: i32,
    root: PathBuf,
    roots: RootSet,
    /// watch descriptor -> the relative directory it watches.
    watched: HashMap<i32, Vec<u8>>,
    /// A `MOVED_FROM` waiting for its `MOVED_TO`, by cookie.
    pending_moves: HashMap<u32, Vec<u8>>,
    /// Set when a watch could not be established; the agent's answer is a sweep.
    pub complaint: Option<String>,
}

impl Watcher {
    pub fn new(root: &Path) -> std::io::Result<Watcher> {
        let fd = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(Watcher {
            fd,
            root: root.to_path_buf(),
            roots: RootSet::default(),
            watched: HashMap::new(),
            pending_moves: HashMap::new(),
            complaint: None,
        })
    }

    #[allow(dead_code)] // the shallow-root test is the only caller, and is the point of it
    pub fn watch_count(&self) -> usize {
        self.watched.len()
    }

    /// Replaces the scope. Section 6.4: "When it changes, the helper (tier 2) is sent the
    /// new set on its stdin and applies it live."
    ///
    /// Rebuilt rather than diffed. A root set arrives at most once a cycle, an
    /// `inotify_add_watch` on a path already watched returns the same descriptor rather
    /// than a second watch, and the diff would have to reason about a subtree that is in
    /// one root and out of another - which is where a watch leak would live.
    pub fn set_roots(&mut self, roots: RootSet) {
        for wd in self.watched.keys() {
            unsafe { libc::inotify_rm_watch(self.fd, *wd) };
        }
        self.watched.clear();
        self.pending_moves.clear();
        self.roots = roots;
        let shallow = self.roots.shallow.clone();
        let recursive = self.roots.recursive.clone();
        for root in shallow {
            self.add_tree(&root, false);
        }
        for root in recursive {
            self.add_tree(&root, true);
        }
    }

    fn add_tree(&mut self, start: &[u8], recursive: bool) {
        for directory in walk::directories_under(&self.root, start, &self.roots, recursive) {
            self.add_one(&directory);
        }
    }

    fn add_one(&mut self, relative: &[u8]) {
        if self.roots.is_excluded(relative) {
            return;
        }
        let absolute = paths::absolute(&self.root, relative);
        let Ok(c) = std::ffi::CString::new(absolute.as_os_str().as_bytes()) else { return };
        let wd = unsafe { libc::inotify_add_watch(self.fd, c.as_ptr(), MASK) };
        if wd < 0 {
            let error = std::io::Error::last_os_error();
            // ENOSPC is `max_user_watches`, which is the failure section 6.4 cares about:
            // the location keeps running, but the agent is told to sweep because the
            // watch set is no longer complete.
            if self.complaint.is_none() {
                self.complaint = Some(format!(
                    "could not watch {}: {}",
                    String::from_utf8_lossy(relative),
                    error
                ));
            }
            return;
        }
        self.watched.insert(wd, relative.to_vec());
    }

    /// Waits up to `timeout` for events and drains everything queued, coalesced.
    pub fn poll(&mut self, timeout: Duration, out: &mut Coalescer) {
        let mut fds = libc::pollfd { fd: self.fd, events: libc::POLLIN, revents: 0 };
        let millis = timeout.as_millis().min(i32::MAX as u128) as i32;
        let ready = unsafe { libc::poll(&mut fds, 1, millis) };
        if ready <= 0 {
            self.flush_pending_moves(out);
            return;
        }
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            let read = unsafe {
                libc::read(self.fd, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len())
            };
            if read <= 0 {
                break;
            }
            self.decode(&buffer[..read as usize], out);
        }
        self.flush_pending_moves(out);
        if let Some(complaint) = self.complaint.take() {
            out.push_overflow(complaint);
        }
    }

    /// The inotify record is a fixed header followed by a NUL-padded name. It is read as
    /// bytes: a filename is bytes (section 5.4).
    fn decode(&mut self, mut data: &[u8], out: &mut Coalescer) {
        const HEADER: usize = 16;
        while data.len() >= HEADER {
            let wd = i32::from_ne_bytes([data[0], data[1], data[2], data[3]]);
            let mask = u32::from_ne_bytes([data[4], data[5], data[6], data[7]]);
            let cookie = u32::from_ne_bytes([data[8], data[9], data[10], data[11]]);
            let length = u32::from_ne_bytes([data[12], data[13], data[14], data[15]]) as usize;
            if data.len() < HEADER + length {
                return;
            }
            let name = &data[HEADER..HEADER + length];
            let name = match name.iter().position(|&b| b == 0) {
                Some(end) => &name[..end],
                None => name,
            };
            self.handle(wd, mask, cookie, name, out);
            data = &data[HEADER + length..];
        }
    }

    fn handle(&mut self, wd: i32, mask: u32, cookie: u32, name: &[u8], out: &mut Coalescer) {
        if mask & libc::IN_Q_OVERFLOW != 0 {
            // Section 6.4's `overflow` event: the agent runs a sweep rather than silently
            // missing changes.
            out.push_overflow("the kernel event queue overflowed");
            return;
        }
        if mask & libc::IN_IGNORED != 0 {
            self.watched.remove(&wd);
            return;
        }
        let Some(directory) = self.watched.get(&wd).cloned() else { return };

        if mask & (libc::IN_DELETE_SELF | libc::IN_MOVE_SELF) != 0 {
            // The watched directory itself went. Its parent's own event reports the
            // change; this only takes the watch off the books.
            self.watched.remove(&wd);
            return;
        }
        if name.is_empty() || paths::is_ignored(name) {
            return;
        }
        let relative = paths::join(&directory, name);
        if !paths::is_well_formed(&relative) || self.roots.is_excluded(&relative) {
            return;
        }
        let is_dir = mask & libc::IN_ISDIR != 0;

        if mask & libc::IN_MOVED_FROM != 0 {
            self.pending_moves.insert(cookie, relative);
            return;
        }
        if mask & libc::IN_MOVED_TO != 0 {
            let meta = self.meta_of(&relative);
            match self.pending_moves.remove(&cookie) {
                // Section 6.4: "real rename events with identifiers preserved".
                Some(from) => out.push_rename(from, relative.clone(), meta),
                // A move in from outside the watched set is a create, not a rename: there
                // is no identifier on our side to preserve.
                None => out.push(Op::Create, relative.clone(), meta),
            }
            if is_dir {
                self.rewatch(&relative, out);
            }
            return;
        }
        if mask & libc::IN_CREATE != 0 {
            out.push(Op::Create, relative.clone(), self.meta_of(&relative));
            if is_dir {
                self.rewatch(&relative, out);
            }
            return;
        }
        if mask & libc::IN_DELETE != 0 {
            out.push(Op::Delete, relative, Meta::default());
            return;
        }
        if mask & (libc::IN_CLOSE_WRITE | libc::IN_ATTRIB) != 0 {
            out.push(Op::Modify, relative.clone(), self.meta_of(&relative));
        }
    }

    /// A directory that appeared inside a recursive root has to be watched, and whatever
    /// was put into it between the `mkdir` and the `inotify_add_watch` has to be
    /// reported: the kernel tells us nothing about a window we were not watching.
    fn rewatch(&mut self, relative: &[u8], out: &mut Coalescer) {
        let recursive = self
            .roots
            .recursive
            .iter()
            .any(|root| paths::is_at_or_under(relative, root));
        if !recursive {
            return;
        }
        self.add_tree(relative, true);
        let mut options = walk::SweepOptions::new(&self.root, &self.roots);
        options.limit = 20_000;
        let scoped = RootSet {
            recursive: vec![relative.to_vec()],
            excluded: self.roots.excluded.clone(),
            ..Default::default()
        };
        let mut scoped_options = walk::SweepOptions::new(&self.root, &scoped);
        scoped_options.limit = options.limit;
        for event in walk::sweep(&scoped_options) {
            if let crate::proto::Event::Change { path, meta, .. } = event {
                if path != relative {
                    out.push(Op::Create, path, meta);
                }
            }
        }
    }

    /// A `MOVED_FROM` with no partner in the same drain is a move out of the watched set,
    /// which is a delete as far as the agent is concerned.
    fn flush_pending_moves(&mut self, out: &mut Coalescer) {
        for (_, from) in self.pending_moves.drain() {
            out.push(Op::Delete, from, Meta::default());
        }
    }

    fn meta_of(&self, relative: &[u8]) -> Meta {
        fsmeta::lstat(&paths::absolute(&self.root, relative))
            .map(|s| s.meta)
            .unwrap_or_default()
    }
}

impl Drop for Watcher {
    fn drop(&mut self) {
        unsafe { libc::close(self.fd) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::Event;
    use std::fs;

    struct Temp(PathBuf);
    impl Temp {
        fn new(name: &str) -> Temp {
            let mut p = std::env::temp_dir();
            p.push(format!("sshdrive-helper-inotify-{}-{}", name, std::process::id()));
            let _ = fs::remove_dir_all(&p);
            fs::create_dir_all(&p).unwrap();
            Temp(p)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// Drains for up to a second, which is far longer than inotify needs and short enough
    /// that a broken watcher fails the test rather than hanging the suite.
    fn drain(watcher: &mut Watcher) -> Vec<Event> {
        let mut out = Coalescer::new();
        for _ in 0..20 {
            watcher.poll(Duration::from_millis(50), &mut out);
            if !out.is_empty() {
                break;
            }
        }
        watcher.poll(Duration::from_millis(50), &mut out);
        out.drain()
    }

    fn ops(events: &[Event]) -> Vec<(String, String)> {
        events
            .iter()
            .filter_map(|e| match e {
                Event::Change { op, path, .. } => {
                    Some((op.name().to_string(), String::from_utf8_lossy(path).into_owned()))
                }
                Event::Rename { from, path, .. } => Some((
                    format!("rename<-{}", String::from_utf8_lossy(from)),
                    String::from_utf8_lossy(path).into_owned(),
                )),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn create_modify_rename_and_delete_all_arrive() {
        let temp = Temp::new("basic");
        let mut watcher = Watcher::new(&temp.0).unwrap();
        watcher.set_roots(RootSet { shallow: vec![Vec::new()], ..Default::default() });

        fs::write(temp.0.join("a.txt"), b"one").unwrap();
        let events = drain(&mut watcher);
        assert!(ops(&events).contains(&("create".into(), "a.txt".into())), "{:?}", ops(&events));

        fs::write(temp.0.join("a.txt"), b"two!").unwrap();
        let events = drain(&mut watcher);
        let seen = ops(&events);
        assert!(seen.iter().any(|(op, p)| p == "a.txt" && (op == "modify" || op == "create")), "{seen:?}");

        fs::rename(temp.0.join("a.txt"), temp.0.join("b.txt")).unwrap();
        let events = drain(&mut watcher);
        assert!(
            ops(&events).contains(&("rename<-a.txt".into(), "b.txt".into())),
            "{:?}",
            ops(&events)
        );

        fs::remove_file(temp.0.join("b.txt")).unwrap();
        let events = drain(&mut watcher);
        assert!(ops(&events).contains(&("delete".into(), "b.txt".into())), "{:?}", ops(&events));
    }

    #[test]
    fn a_chmod_is_reported_which_is_the_case_the_mmin_sweep_misses() {
        let temp = Temp::new("chmod");
        fs::write(temp.0.join("f.txt"), b"x").unwrap();
        let mut watcher = Watcher::new(&temp.0).unwrap();
        watcher.set_roots(RootSet { shallow: vec![Vec::new()], ..Default::default() });
        fs::set_permissions(temp.0.join("f.txt"), std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        let events = drain(&mut watcher);
        assert!(ops(&events).iter().any(|(op, p)| p == "f.txt" && op == "modify"), "{:?}", ops(&events));
    }

    #[test]
    fn a_new_directory_under_a_recursive_root_is_watched_and_its_contents_reported() {
        let temp = Temp::new("recursive");
        let mut watcher = Watcher::new(&temp.0).unwrap();
        watcher.set_roots(RootSet { recursive: vec![Vec::new()], ..Default::default() });

        fs::create_dir(temp.0.join("sub")).unwrap();
        fs::write(temp.0.join("sub/inside.txt"), b"x").unwrap();
        let events = drain(&mut watcher);
        let seen = ops(&events);
        assert!(seen.iter().any(|(_, p)| p == "sub"), "{seen:?}");
        assert!(seen.iter().any(|(_, p)| p == "sub/inside.txt"), "{seen:?}");

        // And the new directory is really watched from now on.
        fs::write(temp.0.join("sub/later.txt"), b"y").unwrap();
        let seen = ops(&drain(&mut watcher));
        assert!(seen.iter().any(|(_, p)| p == "sub/later.txt"), "{seen:?}");
    }

    #[test]
    fn a_shallow_root_does_not_watch_below_itself() {
        let temp = Temp::new("shallow");
        fs::create_dir(temp.0.join("sub")).unwrap();
        let mut watcher = Watcher::new(&temp.0).unwrap();
        watcher.set_roots(RootSet { shallow: vec![Vec::new()], ..Default::default() });
        assert_eq!(watcher.watch_count(), 1);
        fs::write(temp.0.join("sub/deep.txt"), b"x").unwrap();
        assert!(ops(&drain(&mut watcher)).is_empty());
    }

    #[test]
    fn the_ignore_list_and_the_exclusions_are_applied_to_events() {
        let temp = Temp::new("ignored");
        fs::create_dir_all(temp.0.join("pin/big")).unwrap();
        let mut watcher = Watcher::new(&temp.0).unwrap();
        watcher.set_roots(RootSet {
            recursive: vec![b"pin".to_vec()],
            excluded: vec![b"pin/big".to_vec()],
            ..Default::default()
        });
        fs::write(temp.0.join("pin/.sshdrive-upload-aabbccdd-9"), b"x").unwrap();
        fs::write(temp.0.join("pin/big/huge.bin"), b"x").unwrap();
        assert!(ops(&drain(&mut watcher)).is_empty());
        fs::write(temp.0.join("pin/real.txt"), b"x").unwrap();
        assert!(ops(&drain(&mut watcher)).iter().any(|(_, p)| p == "pin/real.txt"));
    }

    #[test]
    fn a_burst_of_writes_to_one_file_is_one_line() {
        let temp = Temp::new("burst");
        let mut watcher = Watcher::new(&temp.0).unwrap();
        watcher.set_roots(RootSet { shallow: vec![Vec::new()], ..Default::default() });
        for i in 0..50 {
            fs::write(temp.0.join("hot.log"), format!("{i}")).unwrap();
        }
        let events = drain(&mut watcher);
        let for_path: Vec<_> = ops(&events).into_iter().filter(|(_, p)| p == "hot.log").collect();
        assert_eq!(for_path.len(), 1, "{for_path:?}");
    }

    #[test]
    fn a_move_out_of_the_watched_set_is_a_delete() {
        let temp = Temp::new("moveout");
        fs::create_dir(temp.0.join("watched")).unwrap();
        fs::create_dir(temp.0.join("elsewhere")).unwrap();
        fs::write(temp.0.join("watched/f.txt"), b"x").unwrap();
        let mut watcher = Watcher::new(&temp.0).unwrap();
        watcher.set_roots(RootSet { shallow: vec![b"watched".to_vec()], ..Default::default() });
        fs::rename(temp.0.join("watched/f.txt"), temp.0.join("elsewhere/f.txt")).unwrap();
        let seen = ops(&drain(&mut watcher));
        assert!(seen.contains(&("delete".into(), "watched/f.txt".into())), "{seen:?}");
    }
}
