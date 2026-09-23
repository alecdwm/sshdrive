# Remote change detection

SFTP cannot push changes, so the agent finds them itself, in one of three tiers chosen per location.
Every tier produces the same output, and nothing on the File Provider side knows which one is
running.

## Tiers and the ladder

| Tier | `watchMode` | Needs on the server | Latency | Cost per cycle |
|---|---|---|---|---|
| 0 | `poll` | SFTP only | poll interval | one `readdir` per root, over the network |
| 1 | `sweep` | exec + `find` (GNU, BSD or busybox) | poll interval | one command; the server walks the tree locally |
| 2 | `helper` | exec + a writable, executable directory + a supported OS/arch + a channel it can hold | ~1 s | idle stream; server-side batching and filtering |

`watchMode: auto` (the default) tries the tiers from the top - helper, sweep, poll - and settles
on the first that starts successfully. For the helper that means its `ready` line
([Tier 2](#tier-2-remote-helper)), not a channel that opened.

| Situation | What happens |
|---|---|
| `watchMode` set to one tier | No ladder, except the fall to `poll`, which always works |
| `helper off` on the location | Tier 2 is skipped; the binary is removed on the next connection |
| A tier fails with a **permanent** reason | The location drops one tier for the rest of the session |
| A tier fails with any other reason | The location drops one tier for a backoff of 2 s doubling to 60 s, then climbs back |
| A connection comes up | Any transient hold and its backoff are cleared outright |

Permanent means a failure that will be just as true on the next connection:

- no shell, or no exec channel
- an unsupported OS or arch
- a `noexec` directory
- a hash that came back and disagreed after a redeploy
- a `find` that is missing

Everything else is transient, and in particular the death of the helper's stream: it dies with
**every** connection (`SQ-077`), so reading it as a verdict about the server would leave a
location at the sweep tier after any network blink until the agent restarted. The loop is woken
when a hold is recorded; otherwise a 2 s hold taken while the detector sleeps out its minute
measures as a 21 s climb back.

`sshdrive status` shows the tier, why a location is below the top, whether the downgrade is
permanent or transient, and for a transient one when the higher tier is tried next.

### What every tier produces

A set of dirty remote paths. The agent re-`stat`s each over SFTP (re-`readdir`s a directory,
since a deletion shows only as an absence in its parent's listing), diffs against the index,
writes working-set anchors and calls `signalEnumerator(for: .workingSet)`. The version format
([item index](item-index.md)) is the same at every tier, so a tier change is invisible too.

Applying events and signalling are both logged at the default level. A mount that takes no change
is diagnosed by whether events arrived, whether applying them changed anything, and whether the
signal went out; none of that can be reconstructed afterwards.

### Scope

The scope is the [root set](root-set.md). When it changes, the helper is sent the new set on its
stdin and applies it live; tiers 0 and 1 read it at the start of every cycle.

### Schedule for tiers 0 and 1

- Every **60 s** while the domain has been touched in the last 10 minutes: a File Provider request
  that was not a system request, or a CLI command naming the location.
- Every **10 min** otherwise.
- Immediately on network-up.
- With the helper running, events replace the schedule, and a sweep still runs every **30 min** as
  insurance against missed events.

A cycle may take at most a third of its own interval. When the last one took longer, the interval
becomes three times that cycle's duration, capped at the 30-minute insurance interval, and
`status` prints the reason on the watch line. Without the cap a slow tree sweeps without pause: a
home directory measured on a real install (2026-09-05) swept in 56.8 s against a 60 s interval,
and the one spare exec channel was never free for anything else.

### Reconnect

After any outage every tier first runs one **full sweep**, so changes made while disconnected are
caught, then resumes:

- At tier 1 (or the helper's tier), a full sweep is the tier 1 sweep with its window opened back
  to the last server timestamp the index recorded, unbounded when there is none (a fresh or
  rebuilt index).
- At tier 0 it is a `readdir` of every root, with the [rotation](root-set.md) suspended for that
  one cycle.

The same full sweep serves a fresh working-set anchor ([item index](item-index.md)).

Resuming the helper's stream is part of the reconnect, not of the next cycle. The stream runs on
an exec channel of the connection that just went, so it is re-opened by the path that re-opens
the SFTP channels, right after them, since both sit on the master that path rebuilt. The order is
`ReconnectSequence`'s (gotcha 103). Left to the next cycle it would cost up to 60 s on a touched
location and up to 10 minutes on an idle one.

## Tier 0: SFTP poll

`readdir` every root and compare name, size and mtime against the index. This is the only tier for
SFTP-only accounts (chrooted `internal-sftp`) and the final fallback for everyone else.

## Tier 1: remote sweep

One `sh -s` exec channel per cycle, fed a script on stdin ([security](security.md)) that runs:

```
find "$@" -maxdepth 1 \( -type d -o -type f \) -cmin -<N> -print0     # working-set roots
find "$@"             \( -type d -o -type f \) -cmin -<N> -print0     # pin roots
                                                                    # (excluded subtrees pruned
                                                                    # with -path … -prune)
```

- **Two invocations** because `-maxdepth` applies to every starting point of one `find`.
- **Batched** at 64 KB of root arguments per invocation: the roots are `find`'s argv, and a few
  thousand `materialized` roots would otherwise approach a kernel's argument limit.
- **Files and directories both.** A directory's ctime moves on create, delete and rename inside
  it, but an in-place edit moves only the file's own.
- **No `-xdev`.** A NAS root routinely holds separate mounts (ZFS datasets, bind mounts).
  Containment comes from not following links ([security](security.md)), not from staying on one
  filesystem.

### `-cmin`, and the busybox fallback

`-cmin` (ctime) rather than `-mmin`: ctime moves whenever mtime does, and also on `chmod`, `chown`
and on writes that preserve mtime (`rsync -t`, `cp -p`, `touch -r`). All of those change our
content or metadata version, and `-mmin` misses them (`SQ-005`). `-cmin` rather than `-newerct`
because GNU and BSD both accept it and only GNU takes an epoch timestamp.

No busybox has `-cmin` (`SQ-001`). The probe checks for it and the sweep falls back to `-mmin`,
losing the ctime-only cases, which `status` reports as a note. That is the ordinary path for every
busybox server, a NAS included, so the note is a normal line and not an alarm. busybox also has no
`-printf` (`SQ-003`), and `SweepPlan` refuses both on a busybox flavour even when the probe claims
them (`SQ-004`).

busybox's `-newer <stamp>` would give second resolution instead of whole minutes, but it is still
an mtime comparison, recovers none of the ctime-only cases, and needs a writable path on the
server that tier 1 otherwise does not. It is not used.

### The window comes from the server's clock

- Every sweep script prints `date +%s` first.
- The agent stores that value only after the sweep's results have been applied to the index.
- The next sweep's `N` is the minutes between the stored value and the new one, rounded up, plus
  one minute of overlap.
- A truncated sweep stores nothing, so the next window still covers what it missed.

Timed on the Mac's clock, a server running a few minutes behind would miss every change until the
30-minute insurance sweep. Duplicates from the overlap are harmless because the result is diffed.

### Spellings that are not optional

- **Every root is passed as `./name`.** `find` has no portable `--`, so a top-level directory
  named `-name` would be read as an option and take the whole sweep with it (`SQ-007`). The prefix
  comes back on every path and is stripped before the `RelativePath` constructor.
- **A root whose bytes are not valid UTF-8 is left out of the argv** and listed at tier 0 in the
  same cycle instead (`SQ-055`). `set --` is a String pipeline end to end
  ([security](security.md)). The root keeps its cadence and loses only the server-side walk.
- **Excluded paths are glob-escaped.** `-path` takes a glob, so `*`, `?`, `[` and `\` in an
  excluded path are backslash-escaped before the pattern is embedded: `-path 't/[x]'` does not
  match a directory named `[x]` (verified on GNU `find`). An exclusion that silently stopped
  applying would put an excluded subtree back under the recursive watch.
- **The output ends with the channel's sentinel printed a second time**, as the login-shell
  snapshot does ([ssh](ssh.md)). The agent stops reading on that closing marker rather than on
  EOF, which an account whose rc file leaves a background child holding stdout never sends.

### `-printf` and cost

On GNU `find` the sweep replaces `-print0` with

```
-printf '%p\0%y\0%s\0%T@\0%i\0%m\0%U\0%G\0'
```

so every hit carries type, size, nanosecond mtime, inode, mode and owner and needs no follow-up
`stat` ([item index](item-index.md)). Elsewhere each returned path is `stat`ed over SFTP, one round
trip each.

The time test and `-printf` each cost a `stat` per entry on the server, which is most of what a
sweep spends (`SQ-006`: over a million files, 204 ms bare, 850-900 ms with `-cmin`, 1.6-3.0 s
with `-printf`). The incremental sweep of that tree is under a second and returns one record; that
is what the 60-second cadence is sized against. A cold NAS is what the 30-minute insurance sweep
is for.

## Lifetime of anything we start on the server

sshd kills a server-side process only when it notices the session is gone, and with
`ClientAliveInterval` unset a connection that died under a sleeping laptop is noticed when TCP
gives up, hours later. Every reconnect would add another helper holding another full set of
watches until `max_user_watches` ran out.

Setting `ClientAliveInterval` does not help: a child that has left the foreground job survives
the session being reaped, on every server measured (`SQ-008`, `SQ-009`). The wrapper below is the
only thing that ever kills what we started, so nothing is started bare.

### The heartbeat wrapper

The stdin script ([security](security.md)):

1. starts the command in the background with stdin from `/dev/null`, so the child cannot consume
   the heartbeat lines;
2. loops reading stdin, where the agent writes a heartbeat line every **15 s**;
3. kills its child and exits when no line has arrived for **60 s**, or stdin hits EOF.

The same wrapper runs the sweep and the helper, so nothing we start outlives the connection by
more than a minute. The helper also stops on its own when its pings stop, so for it the wrapper is
the second line of defence.

`read -t` is used where `sh` supports it (bash, zsh, ksh, busybox) and a `sleep`-and-mtime
watchdog where it does not (dash). The script chooses for itself, in a subshell so that dash's
`read: Illegal option -t` cannot take the shell down, and the probe records which. The watchdog is
the ordinary Linux branch: the exec channel runs `sh`, and `/bin/sh` is dash on Debian and Ubuntu
whatever the login shell is (`SQ-017`).

### Traps in the watchdog branch

Each of these ends with the wrapper dead and the child running, or a healthy child killed about
five seconds in:

- **The stamp file is written with `touch`, not `:`**, and its path is unquoted so `$TMPDIR`
  expands. A redirection failure on a POSIX special builtin ends a non-interactive shell outright.
- **The heartbeat reader reads from a descriptor duplicated in the parent** (`exec 7<&0`). The
  reader runs in the background, and with job control off a background child's fd 0 is replaced
  by `/dev/null`; `<&0` on the child cannot recover it, because the shell substitutes fd 0 in the
  fork before applying that command's redirections.
- **Every subshell clears the `EXIT` trap first.** Subshells inherit the wrapper's cleanup trap
  and run it on exit, so the one-second `read -t` probe would otherwise delete the stamp file the
  moment it finished.

### What the wrapper kills: `-$$`, never `0`

When the wrapper gives up it signals, in order:

- the child, by pid;
- the child's direct children, with `pkill -P` where there is one;
- the process group it leads, spelled `-$$`, which catches anything the child left behind (a
  `( sleep 300 & )`).

`kill … 0` means "whatever group I am in", which is not ours everywhere. OpenSSH gives each
session its own session and process group (`SQ-012`). Tailscale SSH does not: every session of
every client sits in `tailscaled`'s process group (`SQ-010`), so `kill -TERM 0` reaches the
account's other sessions and the connection under them, killing the helper's own exec channel and
dropping the master once a sweep cycle.

`-$$` is the same group wherever sshd gave us one, because a process group's id is its leader's
pid; where it did not, our pid leads no group and the kill is a harmless `ESRCH`. The child is
signalled by pid on both passes, so the helper does not survive on either kind of server.

## Tier 2: remote helper

`sshdrive-helper` is a single static Rust binary built from this repo, embedded in
`SSH Drive.app`, for:

- `linux/x86_64`, `linux/aarch64`, `linux/armv7` (older Synology and QNAP boxes)
- `darwin/arm64`
- `freebsd/x86_64`

A platform outside that list is the one case where a server with shell access stays at the sweep
tier, and `status` asks for an issue with the `uname -sm` output ([cli](cli.md)): adding a target
is cheaper than any other push mechanism.

It is on by default and first in `auto`: it is the only push mechanism, the only tier that reports
renames, and needs nothing installed on the server.

### Deployment

Over the existing connection:

1. **Probe** `uname -sm` and a writable, executable directory: `$XDG_CACHE_HOME/sshdrive`, else
   `~/.cache/sshdrive`, else `/tmp/sshdrive-<uid>`.
    - Created with `mkdir -m 700`, then the mode is asserted with a `setstat`, because `mkdir`'s
      attributes pass through the server's umask and 0700 can land as 0755.
    - Used only if owned by the account. Ours and too open: set back to 0700. Not ours, or will not
      take the mode: refused, not adopted, since `/tmp/sshdrive-<uid>` is a predictable name on a
      shared host.
    - "Executable" is tested by running the uploaded binary with `--version`, which catches
      `noexec` mounts.

2. **Upload** `sshdrive-helper-<version>-<os>-<arch>` over SFTP unless `sha256sum`/`shasum` of the
   remote copy matches the hash embedded in the app.
    - Without either tool, verification is the remote size against the embedded binary plus
      `--version`; any mismatch re-uploads. `--version` prints the SHA-256 the binary computes of
      its own executable at startup - a hash compiled into a file cannot be that file's hash - so
      the fallback makes the same claim `sha256sum` would (gotcha 85).
    - The upload goes to a temp name and is renamed into place ([writes](writes.md)), never written
      over the existing file. A helper of the same version may be running from that path for
      another Mac, writing over a running executable fails `ETXTBSY` (`SQ-032`), and the rename
      leaves the old inode to the process using it.
    - The version is tied to the app release; upgrades take the same path. Other versions whose
      mtime is older than seven days are removed, so two Macs on one account running different
      app versions each keep their own file.
    - This is the one exception to the `RelativePath` chokepoint ([security](security.md)), since
      it writes outside every location root. The SFTP layer exposes a probe-chosen absolute
      directory plus one filename component, no `..` and no nesting, and nothing on the File
      Provider path can build one.

3. **Start** `<path>/sshdrive-helper watch --json --root <root> --roots-from-stdin` from the same
   `sh -s` wrapper as every other remote command ([security](security.md)), path and root
   single-quoted into the script and never on the command line. Feed it the root set and read
   NDJSON events (below). The agent pings every 15 s and the helper exits after 60 s without one.

### The NDJSON protocol

```
{"op":"create|modify|delete|rename|overflow","path":…,"from":…,"size":…,"mtime_ns":…,"inode":…}
```

plus a heartbeat every 15 s, and two more lines:

- **`ready`**, first, carrying the version, the `uname` halves and which facility is watching.
  The ladder settles on the first tier that *starts*, and this is the byte that says the binary is
  running rather than that `sh` printed something (gotcha 87).
- **`error`**, so a helper that cannot establish a watch says why instead of dying quietly.

A path that is valid UTF-8 travels as `path`; one that is not travels as `path_b64`, base64 of the
raw server bytes, because a JSON string is UTF-8 by definition
([names and attributes](names-and-attributes.md)). Tier 1 cannot carry such a path at all.

### How the helper's stdin reaches it

Background children are started `< /dev/null` so they cannot swallow the heartbeat lines, yet the
helper is fed on its stdin, and only one process may read a pipe. So the wrapper stays the only
reader and relays every line into a FIFO it makes in the helper's directory, given to the child as
its stdin (`RemoteScript.stdinRelay`, gotcha 84).

- Where `mkfifo` fails, the helper starts `< /dev/null` with the root set of that moment on its
  argv, and the wrapper is its only kill switch (`SQ-068`).
- The FIFO is swept on every deployment. The wrapper's `EXIT` trap removes its own, but the trap
  does not run when the wrapper is `SIGKILL`ed, which is every abrupt client kill.

### What it adds over the polling tiers

- inotify, FSEvents or kqueue used directly: a change arrives in about a second.
- Root-set changes applied live.
- Real rename events with identifiers preserved; a rename onto an existing path is applied as a
  modify of that path ([item index](item-index.md)).
- Nanosecond mtime and inode in every event.
- Server-side coalescing and a fixed ignore list: our own `.sshdrive-upload-*` and the editor
  scratch names `.*.swp`, `*~`, `.#*`, `4913`. `.git` is not on it: a repository browsed through
  the mount must show a current `.git` or `git status` acts on stale objects. `status` prints the
  list on its change-detection line.
- An `overflow` event, which makes the agent run a sweep rather than miss changes.
- A `sweep` subcommand doing tier 1's job with size, mtime and inode included.

It never listens on a socket, never runs detached, and exits when its stdin closes or its pings
stop. A directory that is itself an NFS or FUSE mount on the server produces no events under any
facility; the insurance and reconnect sweeps cover it.

### FreeBSD: kqueue plus a sweep

kqueue reports content changes only through a descriptor held open on each watched file, so a
recursive watch on a TrueNAS Core share of a hundred thousand files would be a hundred thousand
open descriptors. On `freebsd` the helper watches directories with kqueue for creates, deletes and
renames, and finds content changes with its own `sweep` every 60 s over its roots. `status` shows
`helper (kqueue + 60s sweep)` rather than claiming push latency.

### Telling the user, and failures

- `sshdrive add` says it will upload the helper, naming the directory the probe chose, **before**
  the upload: "SSH Drive will upload a small helper binary to ~/.cache/sshdrive on this server to
  watch for changes; disable with `sshdrive set <name> helper off`".
- `add` then waits, bounded, for that first deployment to settle before printing its capability
  report, so it cannot disagree with a `status` a moment later. A deployment still in flight is
  reported as `deploying`, not as a server that cannot run the helper ([cli](cli.md)).
- `status` shows the exact remote path and version.
- `helper off` stops it and removes the binary on the next connection; `helper on` re-enables it.
- A deployment failure is never fatal: the location continues at the next tier and `status` says
  why.

"The helper could not be uploaded" is two verdicts (`HelperDeployment.uploadFailureIsPermanent`,
gotcha 105):

| What happened | Verdict |
|---|---|
| A hash came back and disagreed | about the file: **permanent** |
| The size matched and nothing could vouch for the contents (an exec channel that will not run `sha256sum` or `--version`) | **transient**: costs the tier only for the ladder's backoff |

## Mass-deletion guard

A directory that lists empty was not necessarily emptied. A ZFS dataset not yet imported after a
NAS reboot, an external drive not yet mounted, an autofs share that timed out: each presents an
empty directory at the same path, and the `realpath` check ([security](security.md)) passes because
the mount point is still there. Reporting that literally deletes everything beneath it from the
replica: the cache goes, with every local xattr and Finder tag; kept subtrees re-download when the
data returns; every item comes back under a new identifier.

### The rule

A diff's deletions are held when they would remove:

- at least half of a directory's known, non-hidden items **and** at least 20 of them, or
- everything in the root, when the root held anything at all.

Held items are recorded in `held` with the time first seen missing and stay visible in Finder.
The directory is re-listed after **5 minutes** and again after **30**:

- still missing after the second re-check: the deletions are applied;
- back: the hold is cleared and nothing was ever reported.

A directory rename rewrites `held.dir` as well as `held.path` ([item index](item-index.md)), or
the re-checks re-list a name that no longer exists and the holds never resolve.

`sshdrive status` shows "14 deletions held in Photos, re-check at 14:32";
`sshdrive accept-deletions <name> [path]` applies them now.

### Opening a held item

The fetch fails as `.cannotSynchronize` carrying the `ENOENT`, never `.noSuchItem`. From
`fetchContents` neither error removes the item (`MQ-012`); they differ in what the reader is told,
and "does not exist" is the wrong thing to tell them while the row, the pin and the hold remain.
(`item(for:)` is where `.noSuchItem` does delete the user's file, [extension](extension.md).)

### What it covers

The guard applies to deletions **inferred from a listing**: a tier 0 poll, the re-`readdir` of a
dirty directory at any tier, the reconnect sweep, and the root's own listing.

It does not apply to the helper's delete events. An `rm -rf Photos` produces one event per item
and is real; a vanished mount produces no events at all. Holding events would only leave thousands
of ghosts in Finder for 35 minutes.

### Pending items are always held

Deletions of items the system lists as pending are held as well. The system does not lose a
pending edit on an item reported deleted: it re-offers it as a **`createItem`**. The path is still
on the server - the deletion was wrong - so the create collides with `.filenameCollision` and is
retried for ever with no alert ([writes](writes.md), `MQ-080`, `MQ-014`). The save never reaches
the server, and since there are no tombstones the item also comes back under a new identifier,
losing any pin or tag even if the create eventually succeeds.
