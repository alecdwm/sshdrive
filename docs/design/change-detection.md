# Remote change detection

SFTP cannot push changes, but the SSH connection can run commands on the
server when the account has shell (exec) access. Change detection therefore
has three tiers. All tiers produce the same thing: a set of "dirty" remote
paths that the agent re-`stat`s over SFTP (re-`readdir`s, for a
directory, since a deletion is only visible as an absence in its parent's
listing), diffs against the index, and turns into working-set anchors,
followed by `signalEnumerator(for: .workingSet)`. Nothing on the File
Provider side knows which tier is active, and the version format
(`docs/design/item-index.md`) is the same at every tier so that a tier change
is invisible too.

| Tier | Mode | Needs on the server | Latency | Cost per cycle |
|---|---|---|---|---|
| 0 | `poll` | SFTP only | poll interval | one `readdir` per root, over the network |
| 1 | `sweep` | exec + `find` (GNU, BSD or busybox) | poll interval | one command; server walks the tree locally |
| 2 | `helper` | exec + a writable, executable directory + a supported OS/arch | ~1 s | idle stream; server-side batching and filtering |

Applying events and signalling an enumerator are logged at the default
level, both of them: a mount that takes no change is diagnosed by whether
the events arrived, whether applying them changed anything, and whether the
signal went out, and none of those can be reconstructed afterwards.

**Scope** is the root set (`docs/design/root-set.md`). When it changes, the
helper (tier 2) is sent the new set on its stdin and applies it live; the
polling tiers read it at the start of every cycle.

**Selection.** `watchMode: auto` (the default) tries the tiers from the top:
helper first, then sweep, then poll, settling on the first one
that starts successfully. The helper is enabled by default and is skipped only
when the server cannot run it (no exec, no writable directory, directory
mounted `noexec`, unsupported OS/arch, upload or hash check failed, or a
server that will not give it a channel it can *hold*) or the
user has set `helper off` for the location. That last condition is tier
2's alone and is easy to miss: a sweep opens an exec channel, spends half
a second on it and gives it back, while the helper's stream holds one for
the life of the connection. At a `MaxSessions` of 2 there is exactly one
spare channel and the probe, `sshdrive test` and the 30-minute insurance
sweep below all want it, so a helper that never gave it back would cost
the location all three; the channel budget therefore answers "may I hold
one open", not only "may I open one" (`docs/design/ssh.md`). A tier that
fails at runtime drops the location one tier down and records why, which
`sshdrive status` shows - but **for how long depends on what failed**. A
failure that will be just as true on the next connection costs the tier for
the rest of the session: no shell, no exec channel, an unsupported OS or
arch, a `noexec` directory, a hash that did not match after a redeploy, a
`find` that is missing. Everything else is transient and costs the tier for
a bounded backoff only - 2 s, doubling to 60 s - after which the ladder
climbs back, and a connection that comes up clears the hold and the backoff
outright, because the link being back is the evidence the outage is over.
The distinction is not a refinement: the helper's stream dies with **every**
connection, so reading its death as a verdict about the server leaves a
location at the sweep tier after any network blink until something restarts
the agent. `status` says which of the two a downgrade is and, for a
transient one, when the higher tier is tried again. Setting
`watchMode` to a specific tier disables the fallback ladder except to `poll`,
which always works. On reconnect after any outage every tier first runs one
full sweep (tier 1, or tier 0 if exec is unavailable) so changes made while
disconnected are caught, then resumes streaming. **Resuming is part of the
reconnect, not of the next cycle**: the helper's stream runs on an exec
channel of the connection that just went, so it is re-opened by the same path
that re-opens the SFTP channels and immediately after it, since both sit on
the master that path rebuilt. Leaving it to the next poll cycle would be up to
60 s on a location the user has touched and up to 10 minutes on one they have
not. A "full sweep" is the
tier 1 sweep with its window opened back to the last server timestamp
the index recorded, unbounded when there is none (a fresh or rebuilt
index), or at tier 0 a `readdir` of every root with the rotation
(`docs/design/root-set.md`) suspended for that one cycle; the same sweep
serves a fresh working-set anchor (`docs/design/item-index.md`).

**Schedule for tiers 0 and 1.** Every 60 s while the user has touched the
domain in the last 10 minutes (a File Provider request for it that was
not a system request, or a CLI command naming it), every 10 min
otherwise, and immediately on network-up. The helper replaces the schedule with events; a sweep still
runs every 30 min as insurance against missed events.
**A cycle may take at most a third of its own interval**: where the last one
took longer, the interval becomes three times that cycle's duration, capped at
the 30-minute insurance interval, and `sshdrive status` prints the reason on
the watch line. Measured on a real install, 2026-09-05: a home directory whose
sweep took 56.8 s against a 60 s interval, so the location swept without pause
and the one spare exec channel was never free for anything else.

## Tier 0: SFTP poll

`readdir` every root, compare name/size/mtime against the index. This is the
only tier available to SFTP-only accounts (chrooted `internal-sftp`), and the
final fallback for everyone else.

## Tier 1: remote sweep

One `sh -s` exec channel per cycle, fed a script on stdin
(`docs/design/security.md`) that runs:

```
find "$@" -maxdepth 1 \( -type d -o -type f \) -cmin -<N> -print0     # working-set roots
find "$@"             \( -type d -o -type f \) -cmin -<N> -print0     # pin roots, excluded subtrees pruned with -path … -prune
```

Two invocations because `-maxdepth` applies to every starting point of one
`find`, and each is run in batches of at most 64 KB of root arguments,
since the roots reach `find` as its argv and a few thousand
`materialized` roots would otherwise brush a kernel's argument limit. `-cmin` (change time) rather than `-mmin`: ctime moves whenever
mtime does, and also on `chmod`, `chown` and on writes that preserve mtime
(`rsync -t`, `cp -p`, `touch -r`), all of which `-mmin` would miss and all
of which change our content or metadata version. `-cmin` rather than
`-newerct` because GNU and BSD accept it and only GNU takes an epoch
timestamp. **busybox has no `-cmin` at all**, in every build measured:
BusyBox v1.36.1 as shipped by current Alpine answers
`find: unrecognized: -cmin`, and its `find` offers `-mmin` and
`-newer FILE` and nothing else of use here (measured on the testbed's `alp`
service, 2026-09-04). The probe checks for `-cmin` and the sweep falls back
to `-mmin`, losing the `chmod`/`chown`/preserved-mtime cases, which `status`
reports as a note. That fallback is the ordinary path for every busybox
server, a NAS included, so the note is a normal `status` line and not an
alarm. `-newer <stamp>` against a stamp file the agent
touches is the one thing busybox offers that `-mmin` does not: second
resolution instead of whole minutes. It is still an mtime comparison, so
it recovers none of the ctime-only cases, and it needs a writable path on
the server, which tier 1 otherwise does not; it is not used. `N` is computed from the
**server's** clock, never the Mac's: every sweep script prints `date +%s`
first, the agent stores it once the sweep's results have been applied
to the index, never before, and the next sweep's `N` is the minutes
between the stored value and the new one, rounded up, plus one minute of
overlap. Measured on the Mac's clock, a server running a few minutes
behind would silently miss every change until the 30-minute insurance
sweep. A truncated sweep stores nothing, so the next window still covers
what the cut-off one missed. Duplicates are harmless because the result is
diffed anyway.
Excluded subtrees are pruned with `-path <path> -prune`, and `-path`
takes a glob, so `*`, `?`, `[` and `\` in an excluded path are
backslash-escaped before the pattern is embedded: `-path 't/[x]'` does
not match a directory named `[x]` (verified on GNU `find`), and an
exclusion that silently stopped applying would put an excluded subtree
back under the recursive watch. Both files and directories are matched: a directory's ctime
changes on create, delete and rename inside it, but an in-place edit
changes only the file's own, so the file test is needed too. There is no `-xdev`: a NAS root routinely contains separate
mounts (ZFS datasets, bind mounts), and containment comes from not following
links (`docs/design/security.md`), not from staying on one filesystem. On
GNU `find` the sweep replaces `-print0` with
`-printf '%p\0%y\0%s\0%T@\0%i\0%m\0%U\0%G\0'`,
so every hit arrives with its type, size, nanosecond mtime, inode, mode
and owner and needs no follow-up `stat` (`docs/design/item-index.md`);
elsewhere the returned paths are `stat`ed over SFTP, one round trip each.
Both time tests and `-printf` cost a `stat` per entry on the server, and
that is most of what a sweep spends: over a million-file tree on Debian,
the same walk is 204 ms with `-print0` and no time test, 850-900 ms with
`-cmin` or `-mmin`, and 1.6-3.0 s with `-printf`, all warm (measured
2026-09-04). The incremental sweep of that tree - `-cmin` over the window,
one file changed - is under a second and returns one record, which is the
number the 60-second cadence is sized against; a cold NAS is the case the
30-minute insurance sweep exists for. Two spellings are not optional.
Every root is passed as `./name` rather than bare, because `find` has
no portable `--` and a top-level directory named `-name` would
otherwise be read as an option and take the whole sweep with it; the
prefix comes back on every path and is stripped before the path
reaches the `RelativePath` constructor. And a root whose bytes are not
valid UTF-8 cannot travel at all: `set --` is a String pipeline end to
end (`docs/design/security.md`), so such a root is left out of the `find`
argv and listed at tier 0 in the same cycle instead, which watches it at
the same cadence and only loses the server-side walk. The sweep's own
output ends with the channel's sentinel printed a second time, exactly as
the login-shell snapshot does (`docs/design/ssh.md`), so the agent stops
reading on the closing marker rather than on EOF - which an account whose
rc file leaves a background child holding stdout never sends.

## Lifetime of anything we start on the server

A server-side process is only killed by sshd when sshd notices the
session is gone, and with `ClientAliveInterval` unset (the default) a
connection that died under a sleeping laptop is noticed only when TCP
gives up, hours later. Every reconnect would then add another helper
holding another full set of watches, until `max_user_watches` is
exhausted. **Setting `ClientAliveInterval` does not fix this**: sshd
reaping the session does not reach a child that has left the foreground
job. A bare `sleep &` started by a session whose client was then
`SIGKILL`ed was still running three minutes later on all three servers
measured - Debian with `ClientAliveInterval` unset, Debian with it set to
15/3, and Alpine with busybox `sh` and it unset (2026-09-04). So the
wrapper below is not a workaround for a common misconfiguration; on every
server there is, it is the only thing that ever kills what we started. So
nothing is ever started bare: the stdin script
(`docs/design/security.md`) starts the command in the background with its
stdin redirected from `/dev/null`, so the child cannot consume the
heartbeat lines, and then loops reading stdin, and the agent writes a
heartbeat line every 15 s. When no line has arrived for 60 s, or stdin
hits EOF, the script kills its child and exits. `read -t` is used where
`sh` supports it (bash, zsh, ksh, busybox) and a `sleep`-and-mtime
watchdog where it does not (dash); the script chooses between them itself,
in a subshell so that dash's `read: Illegal option -t` cannot take the
shell down with it, and the probe records which. The watchdog is not the
rare branch: the exec channel runs `sh`, not the account's login shell,
and `/bin/sh` is dash on Debian and Ubuntu, so most Linux servers take it
however their users log in (measured 2026-09-04). Its stamp file is
written with `touch` rather than `:` and its path is left unquoted so
`$TMPDIR` expands: a redirection failure on a POSIX *special* builtin ends
a non-interactive shell outright, which would leave the wrapper dead and
the child running - the one failure this whole mechanism exists to
prevent. Two more details of that branch are not optional, and both show
up as a wrapper killing a healthy child five seconds in. The reader that
consumes the heartbeat lines runs in the background, and with job control
off a background child's fd 0 is replaced by `/dev/null`; `<&0` on the
child cannot recover it, because the shell substitutes fd 0 in the forked
child and only then applies that command's redirections. The channel's
stdin has to be duplicated onto another descriptor in the *parent*
(`exec 7<&0`) and the reader loop fed from that. And every subshell
inherits the wrapper's cleanup `EXIT` trap and runs it when it exits, so
the one-second `read -t` probe would otherwise delete the stamp file the
moment it finished; each subshell clears the trap first. The same wrapper
runs the sweep and the helper, so nothing we start on a server outlives
our connection by more than a minute. The helper also stops on its own
when its pings stop (below), so for it the wrapper is a second line of
defence rather than the only one.

**What the wrapper kills is `-$$`, never `0`.** When the wrapper gives
up it signals the child by pid, its direct children with `pkill -P`
where there is one, and then the process group *it leads*, spelled
`-$$`. It is the group that catches anything the child started and left
behind - a `( sleep 300 & )` - and the reason it is named rather than
asked for as `0` is that `kill … 0` means "whatever group I happen to be
in", which is not ours everywhere. OpenSSH's sshd gives each session its
own session and process group; **Tailscale SSH does not** - `tailscaled`
serves SSH itself and every session it runs, for every client, sits in
`tailscaled`'s process group. There `kill -TERM 0` reaches the account's
other sessions and the connection carrying them, which kills the helper's
own exec channel and drops the master once a sweep cycle. `-$$` is exactly
the same group wherever sshd gave us one, because a process group's id is
the pid of its leader; where it did not, our pid leads no group and the
kill is a harmless `ESRCH`. The child is signalled by pid on both passes
so that what must not survive - the helper - does not, on either kind of
server.

## Tier 2: remote helper (default where supported)

A single static binary, `sshdrive-helper`, built from this repo in Rust for
`linux/x86_64`, `linux/aarch64`, `linux/armv7` (the older Synology and
QNAP boxes), `darwin/arm64` and `freebsd/x86_64`, embedded
in `SSH Drive.app`. A platform outside that list is the one case where
a server with shell access stays at the sweep tier, and `status` asks
for an issue with the `uname -sm` output (`docs/design/cli.md`), since
adding a target is cheaper than any other push mechanism. Deployment
happens over the existing connection:

1. Probe `uname -sm` and a writable, executable directory:
   `$XDG_CACHE_HOME/sshdrive`, else `~/.cache/sshdrive`, else
   `/tmp/sshdrive-<uid>`. The directory is created with `mkdir -m 700`, and
   the mode is **asserted with a `setstat` afterwards**, because `mkdir`'s
   attributes go through the server's umask and a 0700 that was asked for can
   land as 0755. It is used only if it is owned by the account;
   one that is ours and too open is set back to 0700 rather than refused, since
   we may. A directory that is **not** ours is refused, not adopted, and so is
   one that will not take the mode: `/tmp/sshdrive-<uid>` is a predictable name
   on a shared host.
   "Executable" is tested by actually running the uploaded binary with
   `--version`, which catches `noexec` mounts.
2. Upload `sshdrive-helper-<version>-<os>-<arch>` over SFTP if
   `sha256sum`/`shasum` of the remote copy does not match the hash embedded in
   the app. Where the server has neither tool, verification is the remote
   file's size against the embedded binary plus running it with
   `--version`; any mismatch re-uploads. What `--version` prints is the
   SHA-256 the binary computes of **its own executable** at startup, not a
   constant the build embedded: a hash compiled into a file cannot be the
   hash of that file, and the digest it computes is the same claim
   `sha256sum` would have made, so the fallback is the good path's check
   rather than a weaker one. The upload goes to a temp name and is renamed
   into place like every other upload (`docs/design/writes.md`), never
   written over the existing file: a helper of the same version may be
   running from that path for another Mac, writing over a running executable
   fails with `ETXTBSY` on Linux, and the rename leaves the old inode to the
   process using it. The version is tied to the app release; upgrades happen
   the same way. Versions other than ours whose mtime is older than seven
   days are removed: two Macs sharing one account may run different app
   versions, and each keeps its own file without deleting the other's
   while it is in use.

   This deployment is the one exception to the `RelativePath` chokepoint
   (`docs/design/security.md`), since it writes outside every location root
   by design. What the SFTP layer exposes for it is a probe-chosen absolute
   directory plus one filename component, no `..` and no nesting, and
   nothing on the File Provider path can build one.
3. Start `<path>/sshdrive-helper watch --json --root <root> --roots-from-stdin`
   from the same `sh -s` wrapper script as every other remote command
   (`docs/design/security.md`), its path and root single-quoted into the
   script and never on the command line, feed it the root set, and read
   NDJSON events:
   `{"op":"create|modify|delete|rename|overflow","path":…,"from":…,
   "size":…,"mtime_ns":…,"inode":…}` plus a heartbeat every 15 s. Two
   lines beyond that list are part of the protocol: a `ready` line first,
   carrying the version, the `uname` halves and which facility is
   watching, because the ladder settles on "the first tier that starts
   successfully" and the agent needs one byte that says the *binary* is
   running rather than that `sh` printed something; and an `error` line,
   so a helper that cannot establish a watch says why instead of dying
   quietly. A path that is valid UTF-8 travels as `path`; one that is not
   travels as `path_b64`, base64 of the raw server bytes, because a JSON
   string is UTF-8 by definition and a filename need not be
   (`docs/design/names-and-attributes.md`) - which is the one thing tier 1
   cannot do at all, since `set --` is a String pipeline end to end. The
   agent sends a ping line every 15 s in return and the helper exits after
   60 s without one, so it never outlives the connection (see the
   lifetime rule above on why sshd cannot be relied on for that).

   **How that stdin reaches it.** Background children never share the
   script's stdin - `find` and the helper are started `</dev/null` so they
   cannot swallow the heartbeat lines (`docs/design/security.md`) - and
   this step says the helper is *fed* on its stdin. Both cannot be the
   channel's stdin, and only one process may read a pipe. So the wrapper
   stays the only reader and **relays** every line it reads into a FIFO it
   makes in the helper's own directory, which the child is given as its
   stdin. A server where `mkfifo` fails is not a failure: the helper is
   then started `</dev/null` with the root set of that moment on its own
   argv, watches what it was given, and the wrapper is its only kill
   switch, exactly as for every other remote command. The FIFO is swept on
   every deployment rather than trusted to clean itself up: the wrapper's
   `EXIT` trap removes its own, and the trap does not run when the wrapper
   is `SIGKILL`ed, which is every abrupt client kill and the case the
   wrapper exists for.

What it adds over the polling tiers: inotify/FSEvents/kqueue used
directly, so a change arrives in about a second instead of a poll
interval, root-set changes applied live, real
rename events with identifiers preserved (a rename onto an existing path is
applied as a modify of that path, `docs/design/item-index.md`), nanosecond
mtime and inode in every event, server-side coalescing and a fixed, short
ignore list (our own `.sshdrive-upload-*` and editor scratch names:
`.*.swp`, `*~`, `.#*`, `4913`; `.git` is deliberately not on it, because a
repository browsed through the mount must show a current `.git` or
`git status` inside it acts on stale objects; the list is printed on the
change-detection line of `sshdrive status`), an `overflow` event that makes
the agent run a sweep rather than silently missing changes, and a `sweep`
subcommand that does tier 1's job with size/mtime/inode included so no
follow-up `stat`s are needed. It never listens on a socket, never runs
detached, and exits when its stdin closes or its pings stop, so a dropped
connection leaves nothing behind. A directory that is itself an NFS or FUSE
mount on the server produces no events under any of the three facilities;
the 30-minute insurance sweep and the reconnect sweep cover it.

One platform is push in name only. kqueue, the only facility FreeBSD
offers, reports content changes only through a descriptor held open on
each watched *file*, so a recursive watch on a TrueNAS Core share of a
hundred thousand files is a hundred thousand open descriptors and does
not fit. On `freebsd` the helper watches directories with kqueue for
creates, deletes and renames, finds content changes with its own `sweep`
every 60 s over the roots it was given, walking server-side with size,
mtime and inode included, and `status` shows the change-detection line
as `helper (kqueue + 60s sweep)` rather than claiming push latency.

The helper is on by default and is the first thing `auto` tries, because
it is the only push mechanism, the only tier that reports renames, and
needs nothing installed on the server. Since it does place our code on the
remote machine, `sshdrive add` states this plainly in its output, after
the probe has chosen the directory so the message names the real one
("SSH Drive will upload a small helper binary to ~/.cache/sshdrive on this
server to watch for changes; disable with `sshdrive set <name> helper
off`"), and `sshdrive status` shows the exact remote path and version in
use. `add` says it **before** the upload and then waits, bounded, for that
first deployment attempt to settle before it prints its capability report,
so the one report `add` gives and the `status` a moment later cannot
disagree; a deployment still in flight is reported as `deploying` rather
than as a server that cannot run the helper (`docs/design/cli.md`).
`helper off` stops it and removes the binary on the next connection;
`helper on` re-enables it. Deployment failures are never fatal: the
location silently continues at the next tier and the status report says
why the helper is not running. "The helper could not be uploaded" is two
different verdicts and they are not read the same way: a hash that came
back and disagreed is about the file and is permanent, while a size that
matched with nothing able to vouch for the contents - an exec channel that
will not run `sha256sum` or `--version` - is transient and costs the tier
only for the ladder's backoff.

## Mass-deletion guard

A poll that finds a directory empty is not always a directory that was
emptied. A ZFS dataset not yet imported after the NAS rebooted, an external
drive not yet mounted, an autofs share that timed out: all present an empty
directory at the same path, and the `realpath` check
(`docs/design/security.md`) is satisfied because the mount point itself is
still there. Reporting that literally would delete every item beneath it
from the replica: the cache is dropped, every local xattr and Finder tag
with it, kept subtrees are re-downloaded when the data reappears, and every
item comes back under a new identifier.

So deletions are held when they are implausibly large. If one diff would
remove at least half of a directory's known, non-hidden items and at least
20 of them, or would empty the root when the root previously held anything
at all, the missing items are not reported. They are recorded in `held`
with the time first seen missing, stay visible in Finder, and the directory
is re-listed after 5 minutes and again after 30. If they are still missing
after the second re-check, the deletions are applied. If they reappear, the
hold is cleared and nothing was ever reported. A directory rename rewrites
`held.dir` as well as `held.path` (`docs/design/item-index.md`), or those
two re-checks re-list a name that no longer exists and the holds never
resolve. While held, opening one of
the items fetches from the server and fails. The failure is reported as
`.cannotSynchronize` carrying the `ENOENT`, never as `.noSuchItem`: that
error tells the system the item does not exist, and it would remove the
item locally while the row, the pin and the hold remain, which is the
half-applied deletion the guard exists to avoid. Finder shows an error on
that file, which is the honest state. Both were measured on macOS 26.4,
2026-09-04: `.cannotSynchronize` reaches the reader as `ETIMEDOUT` and
`.noSuchItem` as `ESTALE`, and **neither removes the item** - it was still
listed a minute later and after a working-set signal. So the difference is
in what the user is told, not in whether the file survives the answer; the
rule above stands on the honesty of the message rather than on a deletion
that does not happen. (`item(for:)` is the call where `.noSuchItem`
really does delete the user's file, `docs/design/extension.md`.)
`sshdrive status` shows "14 deletions held in Photos, re-check at 14:32",
`sshdrive accept-deletions <name> [path]` applies them now, and
`sshdrive test` re-checks now. The guard applies to deletions **inferred
from a listing**: a tier 0 poll, the re-`readdir` of a dirty directory at
any tier, the reconnect sweep, and the root's own listing. It does not
apply to explicit delete events from the helper: an `rm -rf Photos`
produces one event per item and is real, while a vanished mount produces
no events at all, so holding event-driven deletions would only leave
thousands of ghosts in Finder for 35 minutes.

**The guard also holds deletions of items the system lists as pending.**
Reporting an item with a pending local edit deleted through the working set
does not lose the edit: the system keeps the local content and re-offers
it, but as a **`createItem`** rather than the `modifyItem` it was. Because
the path is still there on the server - the deletion was wrong, which is
the case the guard exists for - that create is answered
`.filenameCollision`, and the system retries a collided create for ever
with no alert (`docs/design/writes.md`; measured on macOS 26.4,
2026-09-04). The user's edit then sits in the mount, never reaches the
server, and nothing ever resolves it. The item also comes back with a new
identifier, since there are no tombstones
(`docs/design/item-index.md`), so any pin or tag on it is lost even when
the create does succeed. Holding is therefore not an optimisation here; it
is what keeps a wrongly-inferred deletion from stranding a save.
