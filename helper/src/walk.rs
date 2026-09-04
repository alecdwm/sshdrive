//! The `sweep` subcommand, and the directory walk the watcher uses to establish watches.
//!
//! DESIGN.md section 6.4 tier 2: the helper offers "a `sweep` subcommand that does tier
//! 1's job with size/mtime/inode included so no follow-up `stat`s are needed". It is the
//! whole of what the FreeBSD build does about content changes, and everywhere it is the
//! thing that runs when the agent's exec channel would otherwise have to spawn `find`.
//!
//! Two rules it shares with tier 1 and with everything else here: the window is a
//! **ctime** comparison, because ctime moves on `chmod`, `chown` and on writes that
//! preserve mtime and mtime does not; and a symlink is never followed, so a directory
//! swapped for a link to `/etc` yields the link and nothing under it (section 9.1).

use crate::fsmeta::{self, Stat};
use crate::paths::{self, RootSet};
use crate::proto::{Coalescer, Event, Meta, Op};
use std::path::Path;

pub struct SweepOptions<'a> {
    pub root: &'a Path,
    pub roots: &'a RootSet,
    /// Report only entries whose ctime is at or after this. `None` sweeps everything,
    /// which is the agent's full sweep.
    pub since: Option<i64>,
    /// A ceiling on how many entries one sweep reports, so a pathological tree cannot
    /// make the helper hold the channel for minutes. Reaching it is an overflow, and the
    /// agent's answer to an overflow is a sweep of its own.
    pub limit: usize,
}

impl<'a> SweepOptions<'a> {
    pub fn new(root: &'a Path, roots: &'a RootSet) -> Self {
        SweepOptions { root, roots, since: None, limit: 200_000 }
    }
}

/// One sweep, as a list of events ready to write. The caller wraps them in
/// `sweep_start` / `sweep_end`.
pub fn sweep(options: &SweepOptions) -> Vec<Event> {
    let mut out = Coalescer::new();
    let mut budget = options.limit;
    for root in &options.roots.shallow {
        walk(options, root, false, &mut out, &mut budget);
    }
    for root in &options.roots.recursive {
        walk(options, root, true, &mut out, &mut budget);
    }
    if budget == 0 {
        out.push_overflow("the sweep hit its entry limit");
    }
    out.drain()
}

/// Every directory under `start`, for the watcher to put a watch on. Excluded subtrees
/// are pruned and symlinks are never descended, which is what keeps the watch set inside
/// the root.
pub fn directories_under(root: &Path, start: &[u8], roots: &RootSet, recursive: bool) -> Vec<Vec<u8>> {
    let mut found = Vec::new();
    let mut stack = vec![start.to_vec()];
    while let Some(current) = stack.pop() {
        if roots.is_excluded(&current) {
            continue;
        }
        let absolute = paths::absolute(root, &current);
        match fsmeta::lstat(&absolute) {
            Some(stat) if stat.is_dir && !stat.is_symlink => found.push(current.clone()),
            _ => continue,
        }
        if !recursive && current != start {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(&absolute) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = std::os::unix::ffi::OsStrExt::as_bytes(name.as_os_str()).to_vec();
            if paths::is_ignored(&name) {
                continue;
            }
            let child = paths::join(&current, &name);
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() && !kind.is_symlink() && recursive {
                stack.push(child);
            }
        }
    }
    found
}

fn walk(
    options: &SweepOptions,
    start: &[u8],
    recursive: bool,
    out: &mut Coalescer,
    budget: &mut usize,
) {
    let mut stack = vec![start.to_vec()];
    while let Some(current) = stack.pop() {
        if *budget == 0 {
            return;
        }
        if options.roots.is_excluded(&current) {
            continue;
        }
        let absolute = paths::absolute(options.root, &current);
        let Some(stat) = fsmeta::lstat(&absolute) else { continue };
        if !stat.is_dir || stat.is_symlink {
            continue;
        }
        // The directory itself: its ctime moves on a create, a delete or a rename inside
        // it, which is the only evidence a poll-free tier has that something was removed.
        report(options, &current, &stat, out, budget);
        let Ok(entries) = std::fs::read_dir(&absolute) else { continue };
        for entry in entries.flatten() {
            if *budget == 0 {
                return;
            }
            let name = entry.file_name();
            let name = std::os::unix::ffi::OsStrExt::as_bytes(name.as_os_str()).to_vec();
            if paths::is_ignored(&name) {
                continue;
            }
            let child = paths::join(&current, &name);
            if options.roots.is_excluded(&child) {
                continue;
            }
            let Ok(metadata) = entry.metadata().or_else(|_| std::fs::symlink_metadata(entry.path()))
            else {
                continue;
            };
            let metadata = match std::fs::symlink_metadata(entry.path()) {
                Ok(m) => m,
                Err(_) => metadata,
            };
            if fsmeta::is_special(&metadata) {
                continue;
            }
            let child_stat = fsmeta::from_metadata(&metadata);
            if child_stat.is_dir && !child_stat.is_symlink {
                if recursive {
                    stack.push(child);
                    continue;
                }
                // A shallow root reports its immediate subdirectories but does not
                // descend, which is exactly `find -maxdepth 1` at tier 1.
                report(options, &child, &child_stat, out, budget);
                continue;
            }
            report(options, &child, &child_stat, out, budget);
        }
    }
}

fn report(options: &SweepOptions, path: &[u8], stat: &Stat, out: &mut Coalescer, budget: &mut usize) {
    if let Some(since) = options.since {
        if stat.ctime < since {
            return;
        }
    }
    if path.is_empty() {
        // The location root has no row of its own to rewrite; a change in it is reported
        // through its children.
        return;
    }
    if !paths::is_well_formed(path) {
        return;
    }
    out.push(Op::Modify, path.to_vec(), stat.meta.clone());
    *budget = budget.saturating_sub(1);
}

/// A sweep hit carries everything, so nothing needs a follow-up `stat`. Kept as a
/// function so the test and the caller agree on what "complete" means.
#[allow(dead_code)] // asserted by the sweep tests; the agent makes the same check in Swift
pub fn is_complete(meta: &Meta) -> bool {
    meta.size.is_some() && meta.mtime_ns.is_some() && meta.inode.is_some() && meta.mode.is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::Event;
    use std::fs;

    struct Temp(std::path::PathBuf);

    impl Temp {
        fn new(name: &str) -> Temp {
            let mut path = std::env::temp_dir();
            path.push(format!("sshdrive-helper-test-{}-{}", name, std::process::id()));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            Temp(path)
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn paths_of(events: &[Event]) -> Vec<String> {
        let mut out: Vec<String> = events
            .iter()
            .filter_map(|e| match e {
                Event::Change { path, .. } => Some(String::from_utf8_lossy(path).into_owned()),
                _ => None,
            })
            .collect();
        out.sort();
        out
    }

    #[test]
    fn a_shallow_root_is_one_level_and_a_recursive_root_is_all_of_it() {
        let temp = Temp::new("depth");
        fs::create_dir_all(temp.path().join("flat/deep")).unwrap();
        fs::write(temp.path().join("flat/a.txt"), b"a").unwrap();
        fs::write(temp.path().join("flat/deep/b.txt"), b"b").unwrap();

        let shallow = RootSet { shallow: vec![b"flat".to_vec()], ..Default::default() };
        let events = sweep(&SweepOptions::new(temp.path(), &shallow));
        assert_eq!(paths_of(&events), vec!["flat", "flat/a.txt", "flat/deep"]);

        let recursive = RootSet { recursive: vec![b"flat".to_vec()], ..Default::default() };
        let events = sweep(&SweepOptions::new(temp.path(), &recursive));
        assert_eq!(
            paths_of(&events),
            vec!["flat", "flat/a.txt", "flat/deep", "flat/deep/b.txt"]
        );
    }

    #[test]
    fn every_hit_carries_size_mtime_and_inode_so_no_stat_follows() {
        let temp = Temp::new("complete");
        fs::write(temp.path().join("f.txt"), b"hello").unwrap();
        let roots = RootSet { shallow: vec![Vec::new()], ..Default::default() };
        let events = sweep(&SweepOptions::new(temp.path(), &roots));
        let hit = events
            .iter()
            .find_map(|e| match e {
                Event::Change { path, meta, .. } if path == b"f.txt" => Some(meta.clone()),
                _ => None,
            })
            .expect("f.txt");
        assert!(is_complete(&hit));
        assert_eq!(hit.size, Some(5));
        assert_eq!(hit.kind, Some("f"));
    }

    #[test]
    fn the_window_is_a_ctime_comparison() {
        let temp = Temp::new("window");
        fs::write(temp.path().join("old.txt"), b"old").unwrap();
        let roots = RootSet { shallow: vec![Vec::new()], ..Default::default() };
        let mut options = SweepOptions::new(temp.path(), &roots);
        options.since = Some(fsmeta::now_seconds() + 60);
        assert!(paths_of(&sweep(&options)).is_empty());
        options.since = Some(0);
        assert!(paths_of(&sweep(&options)).contains(&"old.txt".to_string()));
    }

    #[test]
    fn the_ignore_list_applies_to_the_sweep_too() {
        let temp = Temp::new("ignore");
        fs::write(temp.path().join(".sshdrive-upload-aabbccdd-1"), b"x").unwrap();
        fs::write(temp.path().join("keep.txt"), b"x").unwrap();
        let roots = RootSet { shallow: vec![Vec::new()], ..Default::default() };
        assert_eq!(paths_of(&sweep(&SweepOptions::new(temp.path(), &roots))), vec!["keep.txt"]);
    }

    #[test]
    fn an_excluded_subtree_is_pruned() {
        let temp = Temp::new("excluded");
        fs::create_dir_all(temp.path().join("pin/big")).unwrap();
        fs::write(temp.path().join("pin/big/huge.bin"), b"x").unwrap();
        fs::write(temp.path().join("pin/small.txt"), b"x").unwrap();
        let roots = RootSet {
            recursive: vec![b"pin".to_vec()],
            excluded: vec![b"pin/big".to_vec()],
            ..Default::default()
        };
        assert_eq!(paths_of(&sweep(&SweepOptions::new(temp.path(), &roots))), vec!["pin", "pin/small.txt"]);
    }

    #[test]
    fn a_symlinked_directory_is_a_leaf_and_is_never_descended() {
        let temp = Temp::new("symlink");
        fs::create_dir_all(temp.path().join("real")).unwrap();
        fs::write(temp.path().join("real/secret.txt"), b"x").unwrap();
        std::os::unix::fs::symlink(temp.path().join("real"), temp.path().join("link")).unwrap();
        let roots = RootSet { recursive: vec![Vec::new()], ..Default::default() };
        let listed = paths_of(&sweep(&SweepOptions::new(temp.path(), &roots)));
        assert!(listed.contains(&"link".to_string()));
        assert!(!listed.iter().any(|p| p.starts_with("link/")), "{listed:?}");
        assert!(listed.contains(&"real/secret.txt".to_string()));
    }

    #[test]
    fn a_fifo_is_not_reported_at_all() {
        let temp = Temp::new("special");
        let fifo = temp.path().join("pipe");
        let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        // Skipped where mkfifo is not permitted; the assertion below still holds.
        unsafe { libc::mkfifo(c.as_ptr(), 0o600) };
        fs::write(temp.path().join("f.txt"), b"x").unwrap();
        let roots = RootSet { shallow: vec![Vec::new()], ..Default::default() };
        let listed = paths_of(&sweep(&SweepOptions::new(temp.path(), &roots)));
        assert!(!listed.contains(&"pipe".to_string()), "{listed:?}");
        assert!(listed.contains(&"f.txt".to_string()));
    }

    #[test]
    fn the_entry_limit_becomes_an_overflow_rather_than_a_long_silence() {
        let temp = Temp::new("limit");
        for i in 0..20 {
            fs::write(temp.path().join(format!("f{i}.txt")), b"x").unwrap();
        }
        let roots = RootSet { shallow: vec![Vec::new()], ..Default::default() };
        let mut options = SweepOptions::new(temp.path(), &roots);
        options.limit = 5;
        let events = sweep(&options);
        assert!(events.iter().any(|e| matches!(e, Event::Overflow { .. })));
    }

    #[test]
    fn directories_under_finds_what_the_watcher_must_watch() {
        let temp = Temp::new("dirs");
        fs::create_dir_all(temp.path().join("a/b/c")).unwrap();
        fs::create_dir_all(temp.path().join("a/skip")).unwrap();
        fs::write(temp.path().join("a/f.txt"), b"x").unwrap();
        let roots = RootSet { excluded: vec![b"a/skip".to_vec()], ..Default::default() };
        let mut found = directories_under(temp.path(), b"a", &roots, true)
            .into_iter()
            .map(|p| String::from_utf8_lossy(&p).into_owned())
            .collect::<Vec<_>>();
        found.sort();
        assert_eq!(found, vec!["a", "a/b", "a/b/c"]);

        let flat = directories_under(temp.path(), b"a", &roots, false);
        assert_eq!(flat.len(), 1);
    }
}
