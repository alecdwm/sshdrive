//! The agent's half of the stream: the ping line and the root set.
//!
//! DESIGN.md section 6.4 tier 2: "feed it the root set, and read NDJSON events … The
//! agent sends a ping line every 15 s in return and the helper exits after 60 s without
//! one, so it never outlives the connection."
//!
//! That is a second, independent kill switch beside the heartbeat wrapper of section 9.2,
//! and it is the one that works when the wrapper is not there - a helper started by hand,
//! or a `sh` that died without reaping. The wrapper stays the outer guarantee.

use crate::json;
use crate::paths::RootSet;
use std::io::{BufRead, BufReader};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Default)]
struct State {
    last_line: Option<Instant>,
    pending_roots: Option<RootSet>,
    /// A control line we could not read. Reported once and then forgotten; a garbled line
    /// is not a reason to stop watching.
    complaint: Option<String>,
}

pub struct Control {
    state: Mutex<State>,
    closed: AtomicBool,
    woken: Condvar,
    /// Silence for this long and the helper exits.
    pub timeout: Duration,
}

impl Control {
    pub fn new(timeout: Duration) -> Arc<Control> {
        Arc::new(Control {
            state: Mutex::new(State { last_line: Some(Instant::now()), ..Default::default() }),
            closed: AtomicBool::new(false),
            woken: Condvar::new(),
            timeout,
        })
    }

    /// Reads the agent's lines on a thread of its own. Returns immediately.
    ///
    /// `reader` rather than `stdin` directly so the tests can drive it with a pipe: the
    /// framing rules are the whole of what is worth testing here.
    pub fn spawn_reader(self: &Arc<Control>, reader: impl std::io::Read + Send + 'static) {
        let control = Arc::clone(self);
        std::thread::spawn(move || {
            let mut lines = BufReader::new(reader);
            let mut buffer = Vec::new();
            loop {
                buffer.clear();
                match lines.read_until(b'\n', &mut buffer) {
                    Ok(0) | Err(_) => {
                        // EOF is the agent gone. Exactly the same answer as silence.
                        control.closed.store(true, Ordering::SeqCst);
                        control.woken.notify_all();
                        return;
                    }
                    Ok(_) => control.accept(&buffer),
                }
            }
        });
    }

    /// One line from the agent. Anything at all counts as a ping, because a root-set
    /// update is proof of life too; only its *content* decides whether it is more.
    pub fn accept(&self, line: &[u8]) {
        let mut state = self.state.lock().unwrap();
        state.last_line = Some(Instant::now());
        let text = String::from_utf8_lossy(line);
        let trimmed = text.trim();
        if trimmed.is_empty() || trimmed == "." {
            // `RemoteScript.heartbeatLine` is exactly ".\n"; the wrapper relays it to us.
            drop(state);
            self.woken.notify_all();
            return;
        }
        match json::parse(trimmed) {
            Some(value) if value.get("op").and_then(|v| v.as_str()) == Some("roots") => {
                state.pending_roots = Some(RootSet {
                    shallow: value.get("shallow").map(|v| v.as_paths()).unwrap_or_default(),
                    recursive: value.get("recursive").map(|v| v.as_paths()).unwrap_or_default(),
                    excluded: value.get("excluded").map(|v| v.as_paths()).unwrap_or_default(),
                });
            }
            Some(_) => {}
            None => state.complaint = Some("a control line was not JSON and was ignored".into()),
        }
        drop(state);
        self.woken.notify_all();
    }

    /// True when the agent has stopped writing for longer than the timeout, or closed the
    /// stream. Either way the helper exits and leaves nothing behind.
    pub fn expired(&self) -> bool {
        if self.closed.load(Ordering::SeqCst) {
            return true;
        }
        let state = self.state.lock().unwrap();
        match state.last_line {
            Some(at) => at.elapsed() > self.timeout,
            None => true,
        }
    }

    pub fn take_roots(&self) -> Option<RootSet> {
        self.state.lock().unwrap().pending_roots.take()
    }

    pub fn take_complaint(&self) -> Option<String> {
        self.state.lock().unwrap().complaint.take()
    }

    /// Blocks up to `limit`, returning early when a control line arrives. Used by the
    /// kqueue build, whose sweep otherwise sleeps through a root-set change.
    #[allow(dead_code)] // the kqueue build's sweep sleeps on this; the inotify build polls
    pub fn wait(&self, limit: Duration) {
        let state = self.state.lock().unwrap();
        let _ = self.woken.wait_timeout(state, limit);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bare_dot_is_a_ping_and_nothing_else() {
        let control = Control::new(Duration::from_secs(60));
        control.accept(b".\n");
        assert!(!control.expired());
        assert!(control.take_roots().is_none());
        assert!(control.take_complaint().is_none());
    }

    #[test]
    fn a_roots_line_replaces_the_whole_set() {
        let control = Control::new(Duration::from_secs(60));
        control.accept(
            br#"{"op":"roots","shallow":["a"],"recursive":["p"],"excluded":["p/x"]}"#,
        );
        let roots = control.take_roots().expect("a set");
        assert_eq!(roots.shallow, vec![b"a".to_vec()]);
        assert_eq!(roots.recursive, vec![b"p".to_vec()]);
        assert_eq!(roots.excluded, vec![b"p/x".to_vec()]);
        assert!(control.take_roots().is_none(), "taken once");
    }

    #[test]
    fn a_garbled_line_is_a_complaint_and_still_a_ping() {
        let control = Control::new(Duration::from_secs(60));
        control.accept(b"{not json\n");
        assert!(control.take_complaint().is_some());
        assert!(!control.expired());
    }

    #[test]
    fn silence_past_the_timeout_expires() {
        let control = Control::new(Duration::from_millis(20));
        assert!(!control.expired());
        std::thread::sleep(Duration::from_millis(40));
        assert!(control.expired());
        control.accept(b".\n");
        assert!(!control.expired());
    }

    #[test]
    fn eof_expires_at_once_however_recent_the_last_line_was() {
        let control = Control::new(Duration::from_secs(600));
        let (reader, mut writer) = pipe();
        control.spawn_reader(reader);
        use std::io::Write;
        writer.write_all(b".\n").unwrap();
        drop(writer);
        for _ in 0..200 {
            if control.expired() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("EOF did not expire the stream");
    }

    #[test]
    fn lines_are_framed_on_newlines_not_on_reads() {
        let control = Control::new(Duration::from_secs(60));
        let (reader, mut writer) = pipe();
        control.spawn_reader(reader);
        use std::io::Write;
        // Two control lines in one write, and one split across two writes.
        writer.write_all(br#"{"op":"roots","shallow":["a"]}"#).unwrap();
        writer.write_all(b"\n.\n{\"op\":\"roots\",\"shallow\"").unwrap();
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(control.take_roots().map(|r| r.shallow), Some(vec![b"a".to_vec()]));
        writer.write_all(b":[\"b\",\"c\"]}\n").unwrap();
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(
            control.take_roots().map(|r| r.shallow),
            Some(vec![b"b".to_vec(), b"c".to_vec()])
        );
        drop(writer);
    }

    fn pipe() -> (std::fs::File, std::fs::File) {
        use std::os::unix::io::FromRawFd;
        let mut fds = [0i32; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        unsafe { (std::fs::File::from_raw_fd(fds[0]), std::fs::File::from_raw_fd(fds[1])) }
    }
}
