//! The NDJSON event protocol of DESIGN.md section 6.4 tier 2, and the server-side
//! coalescing that is one of the things tier 2 buys over the polling tiers.
//!
//! Section 6.4 names the shape:
//! `{"op":"create|modify|delete|rename|overflow","path":…,"from":…,"size":…,
//! "mtime_ns":…,"inode":…}` plus a heartbeat every 15 s. Two lines that section does not
//! name are here as well and are recorded in section 13: a `ready` line, because the
//! ladder settles on "the first tier that starts successfully" and the agent needs one
//! byte that says the binary is running rather than that `sh` printed something; and an
//! `error` line, so a helper that cannot watch says why instead of dying silently.

use crate::json::{write_path_field, write_string};
use std::fmt::Write as _;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    Create,
    Modify,
    Delete,
}

impl Op {
    pub fn name(self) -> &'static str {
        match self {
            Op::Create => "create",
            Op::Modify => "modify",
            Op::Delete => "delete",
        }
    }
}

/// What one changed path is reported with. Everything but the path is optional: a delete
/// has nothing to `stat`, and a watcher that lost the race with a second change reports
/// the path alone and lets the agent re-`stat` it, which is what every tier does anyway.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Meta {
    /// "f" or "d". Absent when the path was gone by the time we looked.
    pub kind: Option<&'static str>,
    pub size: Option<u64>,
    pub mtime_ns: Option<i128>,
    pub inode: Option<u64>,
    /// Octal permission bits, as `%m` gives them to a tier 1 sweep.
    pub mode: Option<u32>,
    pub uid: Option<u32>,
    pub gid: Option<u32>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Ready {
        version: &'static str,
        os: &'static str,
        arch: &'static str,
        mechanism: &'static str,
        roots: usize,
    },
    Change {
        op: Op,
        path: Vec<u8>,
        meta: Meta,
    },
    /// A real rename, with identifiers preserved on the agent's side. `from` and `path`
    /// are both relative to the location root; a rename with one end outside the root
    /// never becomes this (see `watch`).
    Rename {
        from: Vec<u8>,
        path: Vec<u8>,
        meta: Meta,
    },
    /// The kernel queue overflowed, or a watch could not be established. The agent runs a
    /// sweep rather than silently missing changes (section 6.4).
    Overflow {
        reason: String,
    },
    Heartbeat {
        t: i64,
    },
    SweepStart {
        server_time: i64,
    },
    SweepEnd {
        count: usize,
    },
    Error {
        message: String,
    },
}

impl Event {
    /// One NDJSON line, newline included. Parsed by `HelperStream` on the Swift side.
    pub fn line(&self) -> String {
        let mut out = String::with_capacity(96);
        out.push('{');
        match self {
            Event::Ready { version, os, arch, mechanism, roots } => {
                out.push_str("\"op\":\"ready\",\"version\":");
                write_string(&mut out, version);
                out.push_str(",\"os\":");
                write_string(&mut out, os);
                out.push_str(",\"arch\":");
                write_string(&mut out, arch);
                out.push_str(",\"mechanism\":");
                write_string(&mut out, mechanism);
                let _ = write!(&mut out, ",\"roots\":{}", roots);
            }
            Event::Change { op, path, meta } => {
                let _ = write!(&mut out, "\"op\":\"{}\",", op.name());
                write_path_field(&mut out, "path", path);
                meta.append(&mut out);
            }
            Event::Rename { from, path, meta } => {
                out.push_str("\"op\":\"rename\",");
                write_path_field(&mut out, "from", from);
                out.push(',');
                write_path_field(&mut out, "path", path);
                meta.append(&mut out);
            }
            Event::Overflow { reason } => {
                out.push_str("\"op\":\"overflow\",\"reason\":");
                write_string(&mut out, reason);
            }
            Event::Heartbeat { t } => {
                let _ = write!(&mut out, "\"op\":\"heartbeat\",\"t\":{}", t);
            }
            Event::SweepStart { server_time } => {
                let _ = write!(&mut out, "\"op\":\"sweep_start\",\"server_time\":{}", server_time);
            }
            Event::SweepEnd { count } => {
                let _ = write!(&mut out, "\"op\":\"sweep_end\",\"count\":{}", count);
            }
            Event::Error { message } => {
                out.push_str("\"op\":\"error\",\"message\":");
                write_string(&mut out, message);
            }
        }
        out.push('}');
        out.push('\n');
        out
    }
}

impl Meta {
    fn append(&self, out: &mut String) {
        if let Some(kind) = self.kind {
            let _ = write!(out, ",\"type\":\"{}\"", kind);
        }
        if let Some(size) = self.size {
            let _ = write!(out, ",\"size\":{}", size);
        }
        if let Some(mtime) = self.mtime_ns {
            let _ = write!(out, ",\"mtime_ns\":{}", mtime);
        }
        if let Some(inode) = self.inode {
            let _ = write!(out, ",\"inode\":{}", inode);
        }
        if let Some(mode) = self.mode {
            let _ = write!(out, ",\"mode\":{}", mode & 0o7777);
        }
        if let Some(uid) = self.uid {
            let _ = write!(out, ",\"uid\":{}", uid);
        }
        if let Some(gid) = self.gid {
            let _ = write!(out, ",\"gid\":{}", gid);
        }
    }
}

/// Section 6.4's "server-side coalescing": a burst of events on one path leaves the
/// server as one line.
///
/// The merge table is small and every rule in it is a claim about what the agent will do
/// with the result. The agent re-`stat`s whatever it is told about, so the only thing
/// that can be got wrong is telling it about the wrong path or not telling it at all:
///
/// - anything followed by a delete is a delete - the file is gone whatever happened first;
/// - a delete followed by a create is a modify, because the path exists again and the
///   agent's listing of the parent is what mints or rewrites the row either way;
/// - a create absorbs any later modify, because the create is the news;
/// - a rename clears both of its endpoints, since the pair says everything the two
///   separate paths would have.
#[derive(Default)]
pub struct Coalescer {
    order: Vec<Vec<u8>>,
    entries: std::collections::HashMap<Vec<u8>, (Op, Meta)>,
    renames: Vec<(Vec<u8>, Vec<u8>, Meta)>,
    overflow: Option<String>,
}

impl Coalescer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty() && self.renames.is_empty() && self.overflow.is_none()
    }

    pub fn len(&self) -> usize {
        self.entries.len() + self.renames.len() + usize::from(self.overflow.is_some())
    }

    pub fn push(&mut self, op: Op, path: Vec<u8>, meta: Meta) {
        match self.entries.get_mut(&path) {
            Some(existing) => {
                existing.0 = merge(existing.0, op);
                // The later metadata is the truer one; a delete carries none and must not
                // wipe what a create just measured, because the agent prints it.
                if meta != Meta::default() {
                    existing.1 = meta;
                }
            }
            None => {
                self.order.push(path.clone());
                self.entries.insert(path, (op, meta));
            }
        }
    }

    pub fn push_rename(&mut self, from: Vec<u8>, to: Vec<u8>, meta: Meta) {
        self.forget(&from);
        self.forget(&to);
        self.renames.push((from, to, meta));
    }

    pub fn push_overflow(&mut self, reason: impl Into<String>) {
        // One overflow per batch: the agent's answer is a full sweep either way, and
        // twenty identical lines would only make the log harder to read.
        if self.overflow.is_none() {
            self.overflow = Some(reason.into());
        }
    }

    fn forget(&mut self, path: &[u8]) {
        if self.entries.remove(path).is_some() {
            self.order.retain(|p| p.as_slice() != path);
        }
    }

    /// Everything held, in the order it will be written: the overflow first, because it
    /// makes the agent sweep and the sweep subsumes the rest; then renames, whose
    /// endpoints the per-path lines must not contradict; then the paths in arrival order.
    pub fn drain(&mut self) -> Vec<Event> {
        let mut out = Vec::with_capacity(self.len());
        if let Some(reason) = self.overflow.take() {
            out.push(Event::Overflow { reason });
        }
        for (from, path, meta) in self.renames.drain(..) {
            out.push(Event::Rename { from, path, meta });
        }
        for path in self.order.drain(..) {
            if let Some((op, meta)) = self.entries.remove(&path) {
                out.push(Event::Change { op, path, meta });
            }
        }
        out
    }
}

fn merge(existing: Op, new: Op) -> Op {
    match (existing, new) {
        (_, Op::Delete) => Op::Delete,
        (Op::Delete, Op::Create) => Op::Modify,
        (Op::Delete, Op::Modify) => Op::Modify,
        (Op::Create, _) => Op::Create,
        (Op::Modify, Op::Create) => Op::Create,
        (Op::Modify, Op::Modify) => Op::Modify,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta() -> Meta {
        Meta { kind: Some("f"), size: Some(3), mtime_ns: Some(1_700_000_000_123_456_789), inode: Some(42), mode: Some(0o644), uid: Some(1000), gid: Some(1000) }
    }

    #[test]
    fn a_change_line_carries_every_field_section_6_4_names() {
        let line = Event::Change { op: Op::Modify, path: b"a/b.txt".to_vec(), meta: meta() }.line();
        assert_eq!(
            line,
            "{\"op\":\"modify\",\"path\":\"a/b.txt\",\"type\":\"f\",\"size\":3,\
             \"mtime_ns\":1700000000123456789,\"inode\":42,\"mode\":420,\"uid\":1000,\"gid\":1000}\n"
        );
    }

    #[test]
    fn every_line_is_exactly_one_line() {
        let events = [
            Event::Ready { version: "0.1.0", os: "linux", arch: "aarch64", mechanism: "inotify", roots: 3 },
            Event::Change { op: Op::Delete, path: b"we\nird".to_vec(), meta: Meta::default() },
            Event::Rename { from: b"a".to_vec(), path: b"b".to_vec(), meta: meta() },
            Event::Overflow { reason: "queue overflow".into() },
            Event::Heartbeat { t: 1 },
            Event::Error { message: "no watches left".into() },
        ];
        for event in events {
            let line = event.line();
            assert!(line.ends_with('\n'), "{line}");
            assert_eq!(line.matches('\n').count(), 1, "{line}");
            assert!(crate::json::parse(line.trim_end()).is_some(), "{line}");
        }
    }

    #[test]
    fn a_delete_carries_no_metadata_at_all() {
        let line = Event::Change { op: Op::Delete, path: b"gone".to_vec(), meta: Meta::default() }.line();
        assert_eq!(line, "{\"op\":\"delete\",\"path\":\"gone\"}\n");
    }

    #[test]
    fn create_then_modify_is_one_create() {
        let mut c = Coalescer::new();
        c.push(Op::Create, b"f".to_vec(), Meta::default());
        c.push(Op::Modify, b"f".to_vec(), meta());
        let events = c.drain();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0], Event::Change { op: Op::Create, path: b"f".to_vec(), meta: meta() });
    }

    #[test]
    fn anything_then_delete_is_a_delete() {
        for first in [Op::Create, Op::Modify, Op::Delete] {
            let mut c = Coalescer::new();
            c.push(first, b"f".to_vec(), meta());
            c.push(Op::Delete, b"f".to_vec(), Meta::default());
            match &c.drain()[0] {
                Event::Change { op, .. } => assert_eq!(*op, Op::Delete, "{first:?}"),
                other => panic!("{other:?}"),
            }
        }
    }

    #[test]
    fn delete_then_create_is_a_modify_because_the_path_exists_again() {
        let mut c = Coalescer::new();
        c.push(Op::Delete, b"f".to_vec(), Meta::default());
        c.push(Op::Create, b"f".to_vec(), meta());
        match &c.drain()[0] {
            Event::Change { op, meta: m, .. } => {
                assert_eq!(*op, Op::Modify);
                assert_eq!(*m, meta());
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_rename_clears_both_of_its_endpoints() {
        let mut c = Coalescer::new();
        c.push(Op::Create, b"old".to_vec(), meta());
        c.push(Op::Modify, b"new".to_vec(), meta());
        c.push_rename(b"old".to_vec(), b"new".to_vec(), meta());
        let events = c.drain();
        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], Event::Rename { .. }));
    }

    #[test]
    fn a_hundred_writes_to_one_file_leave_one_line() {
        let mut c = Coalescer::new();
        for _ in 0..100 {
            c.push(Op::Modify, b"big.bin".to_vec(), meta());
        }
        assert_eq!(c.len(), 1);
        assert_eq!(c.drain().len(), 1);
    }

    #[test]
    fn the_overflow_is_written_first_and_only_once() {
        let mut c = Coalescer::new();
        c.push(Op::Modify, b"a".to_vec(), meta());
        c.push_overflow("queue overflow");
        c.push_overflow("queue overflow again");
        let events = c.drain();
        assert_eq!(events.len(), 2);
        assert!(matches!(events[0], Event::Overflow { .. }));
    }

    #[test]
    fn arrival_order_is_kept() {
        let mut c = Coalescer::new();
        for name in [b"c".to_vec(), b"a".to_vec(), b"b".to_vec()] {
            c.push(Op::Create, name, Meta::default());
        }
        let paths: Vec<Vec<u8>> = c
            .drain()
            .into_iter()
            .filter_map(|e| match e {
                Event::Change { path, .. } => Some(path),
                _ => None,
            })
            .collect();
        assert_eq!(paths, vec![b"c".to_vec(), b"a".to_vec(), b"b".to_vec()]);
    }
}
