//! `sshdrive-helper` - the remote change-detection helper of DESIGN.md section 6.4 tier 2.
//!
//! One static binary, uploaded to the server over the connection that is already open,
//! started from the same `sh -s` heartbeat wrapper as every other remote command
//! (section 9.2), fed the root set on its stdin and writing NDJSON events back on its
//! stdout. It never listens on a socket, never runs detached, and exits when its stdin
//! closes or its pings stop, so a dropped connection leaves nothing behind (section 9).
//!
//! ```text
//! sshdrive-helper --version
//! sshdrive-helper watch --json --root <root> [--roots-from-stdin]
//!                       [--shallow P]… [--recursive P]… [--exclude P]…
//! sshdrive-helper sweep --root <root> [--since <epoch seconds>]
//!                       [--shallow P]… [--recursive P]… [--exclude P]…
//! ```

mod control;
mod fsmeta;
mod json;
mod paths;
mod proto;
mod sha256;
mod walk;

#[cfg(target_os = "linux")]
mod watch_inotify;
#[cfg(any(
    target_os = "freebsd",
    target_os = "macos",
    target_os = "netbsd",
    target_os = "openbsd",
    target_os = "dragonfly"
))]
mod watch_kqueue;

#[cfg(target_os = "linux")]
use watch_inotify as watcher_impl;
#[cfg(any(
    target_os = "freebsd",
    target_os = "macos",
    target_os = "netbsd",
    target_os = "openbsd",
    target_os = "dragonfly"
))]
use watch_kqueue as watcher_impl;

use crate::paths::RootSet;
use crate::proto::{Coalescer, Event};
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, Instant};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

const OS: &str = std::env::consts::OS;
const ARCH: &str = std::env::consts::ARCH;

/// Section 6.4: "a heartbeat every 15 s", and "the helper exits after 60 s without one".
const HEARTBEAT: Duration = Duration::from_secs(15);
const PING_TIMEOUT: Duration = Duration::from_secs(60);

/// A batch bigger than this is not worth writing one line at a time: the agent's answer
/// to an overflow is a sweep, which is cheaper than a hundred thousand lines through an
/// exec channel that is also carrying the user's files.
const BATCH_CEILING: usize = 5_000;

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let code = run(&arguments);
    std::process::exit(code);
}

fn run(arguments: &[String]) -> i32 {
    match arguments.first().map(String::as_str) {
        Some("--version") | Some("-V") | Some("version") => {
            print!("{}", version_line());
            let _ = std::io::stdout().flush();
            0
        }
        Some("--help") | Some("-h") | Some("help") | None => {
            print!("{}", USAGE);
            0
        }
        Some("watch") => match Options::parse(&arguments[1..]) {
            Ok(options) => watch(options),
            Err(message) => fail(&message),
        },
        Some("sweep") => match Options::parse(&arguments[1..]) {
            Ok(options) => sweep(options),
            Err(message) => fail(&message),
        },
        Some(other) => fail(&format!("unknown subcommand {other}")),
    }
}

const USAGE: &str = "sshdrive-helper - SSH Drive remote change detection (DESIGN.md 6.4 tier 2)\n\
    \n\
    sshdrive-helper --version\n\
    sshdrive-helper watch --json --root <dir> [--roots-from-stdin]\n\
    \x20                      [--shallow P]... [--recursive P]... [--exclude P]...\n\
    sshdrive-helper sweep --root <dir> [--since <epoch>] [--shallow P]...\n";

/// Section 6.4's verification fallback, "by size plus its own `--version` output", needs
/// the version line to identify the exact bytes that are answering. The digest is of the
/// running executable, computed now: a constant compiled in could not be the hash of the
/// file that contains it.
fn version_line() -> String {
    let digest = sha256::own_executable()
        .and_then(|path| sha256::file(&path))
        .unwrap_or_else(|| "unknown".into());
    format!("sshdrive-helper {VERSION} {OS}/{ARCH} sha256={digest}\n")
}

fn fail(message: &str) -> i32 {
    let _ = writeln!(std::io::stderr(), "sshdrive-helper: {message}");
    2
}

struct Options {
    root: PathBuf,
    roots: RootSet,
    from_stdin: bool,
    since: Option<i64>,
    ping_timeout: Duration,
}

impl Options {
    fn parse(arguments: &[String]) -> Result<Options, String> {
        let mut options = Options {
            root: PathBuf::new(),
            roots: RootSet::default(),
            from_stdin: false,
            since: None,
            ping_timeout: PING_TIMEOUT,
        };
        let mut index = 0;
        while index < arguments.len() {
            let argument = arguments[index].as_str();
            let mut value = || -> Result<String, String> {
                index += 1;
                arguments
                    .get(index)
                    .cloned()
                    .ok_or_else(|| format!("{argument} needs a value"))
            };
            match argument {
                // Accepted and ignored: the agent passes it because section 6.4 spells
                // the command line out, and a future non-JSON mode would be a new flag.
                "--json" => {}
                "--roots-from-stdin" => options.from_stdin = true,
                "--root" => options.root = PathBuf::from(value()?),
                "--shallow" => options.roots.shallow.push(value()?.into_bytes()),
                "--recursive" => options.roots.recursive.push(value()?.into_bytes()),
                "--exclude" => options.roots.excluded.push(value()?.into_bytes()),
                "--since" => {
                    options.since = Some(value()?.parse().map_err(|_| "--since wants seconds".to_string())?)
                }
                "--ping-timeout" => {
                    let seconds: u64 =
                        value()?.parse().map_err(|_| "--ping-timeout wants seconds".to_string())?;
                    options.ping_timeout = Duration::from_secs(seconds);
                }
                other => return Err(format!("unknown option {other}")),
            }
            index += 1;
        }
        if options.root.as_os_str().is_empty() {
            return Err("--root is required".into());
        }
        if !options.root.is_absolute() {
            return Err("--root must be absolute".into());
        }
        Ok(options)
    }
}

fn sweep(options: Options) -> i32 {
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    let mut walk_options = walk::SweepOptions::new(&options.root, &options.roots);
    walk_options.since = options.since;
    let _ = out.write_all(
        Event::SweepStart { server_time: fsmeta::now_seconds() }.line().as_bytes(),
    );
    let events = walk::sweep(&walk_options);
    let mut count = 0;
    for event in &events {
        if matches!(event, Event::Change { .. }) {
            count += 1;
        }
        if out.write_all(event.line().as_bytes()).is_err() {
            return 1;
        }
    }
    let _ = out.write_all(Event::SweepEnd { count }.line().as_bytes());
    let _ = out.flush();
    0
}

fn watch(options: Options) -> i32 {
    let mut watcher = match watcher_impl::Watcher::new(&options.root) {
        Ok(watcher) => watcher,
        Err(error) => {
            emit(&Event::Error { message: format!("could not start the watcher: {error}") });
            return 1;
        }
    };

    let control = control::Control::new(options.ping_timeout);
    if options.from_stdin {
        control.spawn_reader(std::io::stdin());
    }

    watcher.set_roots(RootSet {
        shallow: options.roots.shallow.clone(),
        recursive: options.roots.recursive.clone(),
        excluded: options.roots.excluded.clone(),
    });

    emit(&Event::Ready {
        version: VERSION,
        os: OS,
        arch: ARCH,
        mechanism: watcher_impl::MECHANISM,
        roots: options.roots.len(),
    });

    let mut last_heartbeat = Instant::now();
    loop {
        // Two independent reasons to stop, and both mean the agent is gone: silence past
        // the timeout, and EOF on stdin. Neither depends on sshd noticing anything
        // (section 6.4, "Lifetime of anything we start on the server").
        if options.from_stdin && control.expired() {
            return 0;
        }
        if let Some(roots) = control.take_roots() {
            watcher.set_roots(roots);
        }
        if let Some(complaint) = control.take_complaint() {
            emit(&Event::Error { message: complaint });
        }

        let mut batch = Coalescer::new();
        watcher.poll(Duration::from_millis(250), &mut batch);
        if !batch.is_empty() {
            if batch.len() > BATCH_CEILING {
                let mut replacement = Coalescer::new();
                replacement.push_overflow(format!("{} events in one batch", batch.len()));
                batch = replacement;
            }
            for event in batch.drain() {
                if !write_line(&event.line()) {
                    return 0;
                }
            }
        }

        if last_heartbeat.elapsed() >= HEARTBEAT {
            if !write_line(&Event::Heartbeat { t: fsmeta::now_seconds() }.line()) {
                return 0;
            }
            last_heartbeat = Instant::now();
        }
    }
}

fn emit(event: &Event) {
    write_line(&event.line());
}

/// False when the far end is gone. Every caller then returns rather than looping on a
/// broken pipe: the agent has closed the channel, and there is nothing left to report to.
fn write_line(line: &str) -> bool {
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    out.write_all(line.as_bytes()).is_ok() && out.flush().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_version_line_is_one_line_naming_the_target_and_a_digest() {
        let line = version_line();
        assert_eq!(line.matches('\n').count(), 1);
        assert!(line.starts_with(&format!("sshdrive-helper {VERSION} {OS}/{ARCH} sha256=")), "{line}");
        let digest = line.trim().rsplit('=').next().unwrap();
        assert_eq!(digest.len(), 64, "{line}");
        assert!(digest.chars().all(|c| c.is_ascii_hexdigit()), "{line}");
    }

    #[test]
    fn the_digest_is_of_the_running_binary() {
        let path = sha256::own_executable().unwrap();
        let expected = sha256::file(&path).unwrap();
        assert!(version_line().contains(&expected));
    }

    #[test]
    fn options_require_an_absolute_root() {
        let args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(Options::parse(&args(&["--json"])).is_err());
        assert!(Options::parse(&args(&["--root", "relative"])).is_err());
        let parsed = Options::parse(&args(&[
            "--json",
            "--root",
            "/srv/share",
            "--roots-from-stdin",
            "--shallow",
            "a",
            "--recursive",
            "pin",
            "--exclude",
            "pin/big",
        ]))
        .unwrap();
        assert_eq!(parsed.root, PathBuf::from("/srv/share"));
        assert!(parsed.from_stdin);
        assert_eq!(parsed.roots.shallow, vec![b"a".to_vec()]);
        assert_eq!(parsed.roots.recursive, vec![b"pin".to_vec()]);
        assert_eq!(parsed.roots.excluded, vec![b"pin/big".to_vec()]);
    }

    #[test]
    fn an_unknown_option_is_refused_rather_than_ignored() {
        let args = vec!["--root".to_string(), "/x".to_string(), "--wat".to_string()];
        assert!(Options::parse(&args).is_err());
    }
}
