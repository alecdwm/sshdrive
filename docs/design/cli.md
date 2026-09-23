# The CLI

`sshdrive` is the only user interface. Every command except `logs` is one XPC request to the agent
and its reply; the CLI runs no `ssh`, touches no keychain and calls no File Provider API. A
command that changes something prints nothing when it works.

## Conventions

- **Starting the agent.** If the agent is not running, the mach lookup starts it. If the lookup
  fails because no login item is registered yet (a fresh install whose postflight did not run),
  the CLI launches the bundle it lives in with `open -g` once, as the postflight does
  ([packaging](packaging.md)), waits for the service and retries. A registered but disabled
  item gets the Login Items instruction from [the extension page](extension.md) instead.
- **Prompts.** Every prompt is a hidden tty read. A script avoids them with flags: `--no-password`
  and `--trust-first` for `add`, `-y` for `remove`.
- **Verbosity.** A command that changes state prints only prompts, warnings and errors on
  success. `-v` / `--verbose` restores the full report: the `ssh -G` resolution, the attribution
  of each value against `~/.ssh/config` and, for `add`, the capability report. The flag belongs
  to each subcommand and is typed after it (`sshdrive add -v nas alec@nas`). The reporting
  commands - `list`, `show`, `status`, `pins`, `logs`, `doctor` - print either way.
- **`<name>`** matches a nickname or a host (the first location in `config.json` order that has
  either), then a prefix of the location id. An id prefix matching several locations is an
  error that names them.
- **A command naming a location is a touch** for the change-detection cadence (gotcha 77).
- **Host-key changes** need no command of ours: `status` prints the `ssh-keygen -R` line to run
  ([host keys](secrets.md)).

```
sshdrive <command> [args] [-v|--verbose]
```

## Commands

| Command | What it does |
|---|---|
| `add` | Create a location: resolve, connect once, probe, add the domain |
| `list [--json]` | Table: name, host, secrets, mounted, TTL, state |
| `show <name> [--json]` | Full detail of one location |
| `remove <name>` / `remove --all` | Remove the domain, config and the keychain items only it names |
| `mount <name>` / `unmount <name>` | Add or remove the File Provider domain without forgetting the location |
| `set <name> <key> <value>` | Change one setting |
| `status [<name>]` | Per-location state and the capability report |
| `evict <name> [path]` | Drop cached content |
| `accept-deletions <name> [path]` | Apply deletions the mass-deletion guard is holding |
| `pin` / `unpin` / `pins` | Keep paths downloaded; list the pin tree |
| `logs [<name>]` | The unified log for us and for fileproviderd about us |
| `doctor [--json]` | Check the install |
| `agent start`, `stop`, `restart` | Control the agent process |
| `debug ...` | Test and diagnosis hooks |

### `add`

```
sshdrive add [user@]host-or-alias[:port] [--nickname NAME] [--remote-path PATH]
             [--user USER] [--port N] [--identity PATH] [-o SSHOPTION]...
             [--jump HOP[,HOP]...] [--permissions mode|none] [--no-password]
             [--cache-ttl 1h] [--trust-first]
sshdrive add <nickname> [user@]host-or-alias[:port] [same flags]
```

The second form is the same command: a second positional argument makes the first the nickname,
because `sshdrive add nas alec@nas` is what people write.

| Flag | Effect |
|---|---|
| `--nickname NAME` | Name for the location and the Finder sidebar; defaults to the host |
| `--remote-path PATH` (also `--path`) | Directory to mount; defaults to the account's home |
| `--user`, `--port` | Used when the destination does not give them |
| `--identity PATH` | Key file to authenticate with; implies `IdentitiesOnly=yes` |
| `-o SSHOPTION` (also `--ssh-option`) | Extra `KEYWORD=VALUE` ssh option; repeatable |
| `--jump HOP[,HOP]...` | `ProxyJump` chain, `[user@]host[:port]` comma separated |
| `--permissions mode` or `none` | Whether server mode bits become Finder capabilities |
| `--cache-ttl` | `15m`, `1h`, `12h`, `1d`, `1w`, `1mo` or `never` |
| `--trust-first` | Accept an unknown host key without asking (`StrictHostKeyChecking=accept-new`) |
| `--no-password` | Answer every password prompt with the skip ([secrets](secrets.md)): the location is key-only or is not created |

In order, `add`:

1. Has the agent run `ssh -G`. Under `-v` the resolution and its attribution against
   `~/.ssh/config` are printed ([locations](locations.md)).
2. Warns, at any verbosity, when the terminal's `PATH` or `SSH_AUTH_SOCK` differs from the login
   shell snapshot the agent will use ([secrets](secrets.md)), and when the resolved
   `proxycommand` is a hand-written `ssh` ([ssh](ssh.md)).
3. Has the agent connect once with the command it will use later, in its own environment (the
   collect connection, [secrets](secrets.md), [ssh](ssh.md)). The host-key question and any
   password or passphrase prompt are relayed to the terminal and stored on success.
4. Refuses a location that needs a touch or a one-time code on every connection, naming the key
   that asked for the touch and the `--identity` that avoids it ([secrets](secrets.md)).
5. Records the location, probes the server and adds the File Provider domain. Under `-v` the
   capability report is printed. It says so if the helper will be deployed
   ([change detection](change-detection.md), tier 2).

### `list`, `show`

`list [--json]` prints one row per location: name, host, secrets, mounted, TTL, state.

`show <name> [--json]` prints the `ssh` binary and version, the `ssh -G` resolution, the
environment snapshot ([ssh](ssh.md)), whether the location runs with `IdentityAgent=none` or
through the key agent ([ssh](ssh.md)), the `ProxyJump` chain the agent built, the mount path and
the last error.

### `remove`

```
sshdrive remove <name> [--keep-files] [--force] [-y|--yes]
sshdrive remove --all
```

- Removes the domain and the config entry.
- Removes each keychain item the location names that no remaining location also names. Items
  are keyed by `user@hostname:port` ([secrets](secrets.md)), so two locations on one host share
  one.
- On the location's last connection, removes the helper binary and its directory from the
  server when no other location of this Mac on the same `user@hostname:port` uses them. Another
  Mac's helper running from there keeps its inode and re-uploads on its next connection.
- Refuses while uploads are pending unless `--force`.
- `--keep-files` uses the system's preserve-downloaded-data removal mode, so cached files are
  kept in a folder the system chooses.
- `--all` removes every location. Run it before `brew uninstall` ([packaging](packaging.md)).

Replacing a stored password or passphrase is `remove`, then `add`.

### `set`

```
sshdrive set <name> <key> <value> [--force]
sshdrive set <name> option add|remove <SSHOPTION>
```

Every change restarts the location's connection, which also clears a stopped breaker
([offline](offline.md)). `option add|remove` edits the extra `-o` list.

| Key | Values | Effect |
|---|---|---|
| `nickname` | text | Renames the domain in place: one `add(domain)` on the identifier the system already holds renames the mount directory under `~/Library/CloudStorage` and the sidebar entry, keeps every cached file and leaves a pending upload pending (gotcha 28). Never refused, drops nothing |
| `cache-ttl` | as for `add` | The eviction TTL ([eviction](eviction.md)) |
| `remote-path` | path | Re-creates the domain, since a new root invalidates every path in the index. Refused while uploads are pending (unless `--force`); otherwise warns that the cache is dropped |
| `host`, `port`, `user`, `identity` | as for `add` | These change what stored secrets are keyed on or which key is offered, so the collect connection runs again, as in `add` ([secrets](secrets.md)), before the change is saved |
| `watch-mode` | `auto`, `poll`, `sweep`, `helper` | Change-detection tier ([change detection](change-detection.md)) |
| `helper` | `on`, `off` | Allow the remote helper (default `on`) |
| `permissions` | `mode`, `none` | Map server mode bits to Finder capabilities ([names and attributes](names-and-attributes.md)) |
| `create-check` | `auto`, `lstat` | `lstat` forces the preflight before every create and rename regardless of the probe ([writes](writes.md)) |

### `mount`, `unmount`

`mount <name>` / `unmount <name>` add or remove the File Provider domain without forgetting the
location.

### `status`

```
sshdrive status [<name>] [--json] [--probe]
```

Per-location state, the last connection error, held deletions, hidden names and the
[capability report](#capability-report). `--probe` re-runs the server probe instead of using the
cached result. Upload and sync errors are not listed. How it is built is under
[How `status` is built](#how-status-is-built).

### `evict`, `accept-deletions`

```
sshdrive evict <name> [path] [--all] [--unpin-all] [--json]
sshdrive accept-deletions <name> [path]
```

`evict` with no path runs the TTL pass; with a path it drops that path now; `--all` drops
everything the location has cached ([eviction](eviction.md)). `accept-deletions` applies the
deletions the mass-deletion guard is holding ([change detection](change-detection.md)): with no
path, all of them; with one, that path and its subtree.

### `pin`, `unpin`, `pins`

```
sshdrive pin <name> <remote-path> [--json]
sshdrive unpin <name> <remote-path> [--json]
sshdrive pins <name> [--export | --import FILE] [--json]
```

- `pin` keeps a folder or file fully offline ([pinning](pinning.md)), the same effect as the
  Finder context-menu action. `/` or `.` pins the whole location.
- `unpin` clears an explicit pin, or excludes the path if it inherits a pin from a folder above.
- `pins` prints the tree of pins and exclusions with cached size and file counts. `--export`
  prints the markers as JSON; `--import FILE` reads them back.

### `logs`

```
sshdrive logs [<name>] [-f|--follow] [--last 1h] [--debug] [--print-command]
```

`logs` execs `/usr/bin/log show` (or `log stream` for `--follow`) with a subsystem predicate,
because `OSLogStore`'s local store is not open to a standard user. `/usr/bin/log` is spelled
absolutely because zsh has a `log` builtin. Ctrl-C ends a `--follow`.

- **The predicate has two halves:** `subsystem == "org.shirls.sshdrive"`, or a fileproviderd
  line naming us. Everything the system decides about a domain is logged by fileproviderd under
  Apple's subsystem and never reaches ours.
- **A `<name>` narrows both halves.** Ours match on the domain identifier or the display name,
  since our lines carry one or the other; fileproviderd's match on the identifier, which is all
  it knows.
- **`--info` is always passed**, because `log show` hides the info level and most of the
  transport's detail is there. `--debug` adds the debug level. `--last` takes `log show`
  syntax (`1h`, `30m`, `2d`).
- `--print-command` prints the `log` command and its predicate instead of running it.
- `logs` asks the agent only which location a `<name>` means, and falls back to matching the
  text when the agent is not running - which is exactly when someone wants the log.

### `doctor`

`doctor [--json]` checks, in order: app in `/Applications`, quarantine attribute stripped,
extension registered (`pluginkit`), login item enabled and agent reachable, app group container
writable, CLI on `PATH`, `ssh` version, macOS version, login shell snapshot obtained
([ssh](ssh.md)). It reminds that `remove --all` must precede `brew uninstall`
([packaging](packaging.md)). "Agent reachable" and "CLI on PATH" are checked by the CLI itself,
and an agent that accepts the connection but does not answer in time is reported as that, not as
unreachable.

### `agent`

```
sshdrive agent start|stop|restart
```

- **`stop` is a pause, not a disable.** The agent exits cleanly and launchd leaves it down until
  the next mach lookup, which any CLI command or extension call causes ([packaging](packaging.md)).
  Disabling is the Login Items switch in System Settings.
- **`stop` shuts every location's master and mux clients down first,** as `remove` does per
  location. Exiting without that leaves an `ssh -N` per location holding a connection, with a
  control socket the next start unlinks out from under it, and the sweep then has nothing to ask
  ([ssh](ssh.md)).
- The reply is sent before the shutdown, because the CLI is waiting on it and `-O exit` against
  an unreachable server takes seconds. A 20 s backstop exits anyway.
- A TERM from the cask's `uninstall` stanza takes the same path and exits 0
  ([packaging](packaging.md)).
- `restart` also clears every stopped breaker, since the breaker lives in the agent's memory.

### `debug`

Test and diagnosis hooks, grouped under `sshdrive debug` so they stay off the real commands.
The one a user may be told to run: `debug breaker <name> --connect` clears a stopped breaker and
attempts once ([offline](offline.md)).

## How `status` is built

`status` is what a user runs because something looks wrong, so it must never queue behind
whatever is wrong. Two rules guarantee it.

**It reads the index through its own read-only reader, never through the location's writer.**
`LocationRuntime` is an actor because the index has a single writer
([components](components.md)), and a listing writes its rows in one synchronous SQLite
transaction ([the index](item-index.md)). A hop onto that actor waits for a whole listing, and a
status row needs about eighteen reads: hidden names, held deletions, the root set, one read per
materialized file, the pin tree. So `status` opens `index.sqlite` read-only in WAL mode, as the
extension does ([the extension](extension.md)): a WAL reader neither blocks nor delays the
writer and sees a consistent snapshot (for a listing in flight, the state before it).

What is left on the runtime is taken in **one** entry: the channel budget, the identity, the
transfer counters, the last error, the hidden-name sentences, the last change-detection cycle and
the free-space figure.

- While `meta.reconciling` is set the row says the index is being rebuilt and prints the rest,
  rather than zeroes that read as facts about the server.
- A location that has never started has no index file. That is the same kind of answer, not an
  error.

**Each location's section is bounded, and sections run concurrently.** With no `<name>`, all
locations are built at once and printed in `config.json` order. Each section runs under a 20 s
deadline on the agent's clock - the bound the File Provider calls carry, and well inside the
CLI's own timeout. A location that has stopped answering gets a `did not answer within 20 s` note
on its own row; the others are reported in full.

**It does not re-walk the materialized set.** The root set ([root set](root-set.md)) and the TTL
pass ([eviction](eviction.md)) take that set on their own schedules and publish it, and every
change to it arrives as `materializedItemsDidChange`, so an entry taken within five minutes is
the current set. `status` drains `enumeratorForMaterializedItems()` itself only when there is no
such entry.

**It never measures free space or connection state.** Both would be wire calls through the
connection gate ([offline](offline.md)): on a location mid-connect they wait up to the 60 s
authentication deadline, and on an idle one they *start* a connection the user has not asked
for. See [free space](#server-free-space) for where the figure comes from. The `online` /
`offline (<reason>)` word comes from the connection gate and the breaker, never from
`ssh -O check`, which spawns a process and waits up to ten seconds inside the master's actor.

### Layout

`status` prints one section per location; `status <name>` prints only that one, in the same
form. The first line is name, destination, mounted, state word and cache TTL. Below it, in order:

1. transfer counters
2. identity mode, with the `permissions` and `watch-mode` settings
3. channel budget
4. the identity the probe found
5. names not shown
6. change-detection tier with cadence, cycle and root counts, and its last cycle
7. cache and the next eviction pass
8. pins
9. held deletions
10. last connection error
11. `ssh-keygen -R` advice
12. the capability report

A line with nothing to say is left out, except held deletions, which reads `0 held deletions`.
The transfer, identity-probe, cache and pin lines need the location's runtime and are absent
until it has started. Pending uploads and conflicts are not part of the report.

```
$ sshdrive status
nas   alec@nas.example.net   mounted   online   TTL 1h
       transfers 0 running, 0 waiting, 0 admitted
       identity IdentityAgent=none   permissions mode   watch-mode auto
       channels 3 at a time, bulk channel, shell
       server sees us as uid=1000(alec) gid=1000 groups=27,100,1000
       not shown  lib/current (a symbolic link whose target is outside this location)
       watch helper   every 60s (active)   212 cycle(s)   9 root(s)
         last cycle 41s ago: 3 changed, 0 deleted, 0 held, 1 listed, 0.04s
       cache 1.2 GB materialized (312 files), 480 MB kept   TTL 1h   next eviction pass in 3m
       pins  Documents/thesis   (a leading ! is an exclusion; sshdrive pins nas shows the tree)
       0 held deletions
       Capabilities  8/8 optimal   probed 3m ago
         server software  OpenSSH_9.2p1 Debian-2+deb12u3   SFTP: OpenSSH sftp-server
       ● change detection     helper 0.1.4 at /home/alec/.cache/sshdrive (push, ~1s)
             note: ignores: .sshdrive-upload-*  .*.swp  *~  .#*  4913
       ● rename detection     helper move events
       ● change evidence      ns-mtime + inode
       ● permissions          mapped (uid=1000(alec) gid=1000 groups=27,100,1000)
       ● atomic overwrite     posix-rename@openssh.com
       ● durable writes       fsync@openssh.com
       ● transfer sizing      limits@openssh.com
       ● collision-safe create server-enforced
       Server free space  1.8 TB of 4.0 TB

work   backup@files.example.org   mounted   online   TTL 1h
       transfers 0 running, 0 waiting, 0 admitted
       identity IdentityAgent=none   permissions mode   watch-mode auto
       channels 3 at a time, bulk channel, shell
       watch poll   every 60s (active)   38 cycle(s)   4 root(s)
         note: the server cannot run the remote helper; the account has no shell access
         last cycle 22s ago: 0 changed, 0 deleted, 0 held, 4 listed, 0.31s
       cache 210 MB materialized (48 files)   TTL 1h   next eviction pass in 3m
       0 held deletions
       Capabilities  4/8 optimal   probed 2h ago
         server software  OpenSSH_8.9p1 Ubuntu-3ubuntu0.10   SFTP: OpenSSH sftp-server
       ◐ change detection     poll (SFTP readdir every 60s while active)
             note: the server cannot run the remote helper
             upgrade: shell access on the server enables the helper (push); plain shell access enables remote sweep
       ◐ rename detection     delete + create (identifiers not preserved on remote renames)
             upgrade: the helper, which needs shell access
       ◐ change evidence      size + mtime (same-second rewrites of equal size are missed)
             upgrade: shell access
       ◐ permissions          everything shown writable; permission errors appear after upload
             upgrade: shell access
       ● atomic overwrite     posix-rename@openssh.com
       ● durable writes       fsync@openssh.com
       ● transfer sizing      limits@openssh.com
       ● collision-safe create server-enforced
       Server free space  610 GB of 2 TB (as of 2h ago)
```

## Capability report

Several features run at a level that depends on what the server offers. The report says which
level each is at and what would raise it.

### The probe

The probe runs on every connection and on `status --probe`. Its result is cached in
`domains/<id>/capabilities.json` with a timestamp and the server banner. It records:

- the SFTP `extensions` list from the init reply, and whether that reply arrived clean or behind
  rc-file output ([remote command execution](security.md#remote-command-execution))
- whether an exec channel opens and delivers its sentinel
- from one shell script: `uname -sm`; `id -u` and `id -G` (two commands, because POSIX `id`
  accepts only one of `-u`, `-g`, `-G` per invocation); `$HOME` as the account spells it; the
  `find` flavour and whether it takes `-cmin`; whether `sha256sum`/`shasum` exist; a writable,
  executable cache directory

The `find` flavour comes from the `busybox` banner and the `-cmin` answer, never from an exit
status: busybox `find --version` exits 0 (SQ-002).

The report always renders the extension set recorded with the probe, including on the cached
path, never an empty default. A line saying the server does not advertise an extension has to
come from what the server said.

### Server software

Several lines are claims about the server, so the report names its software when it can. Two
pieces of evidence exist:

- **The identification string.** `ssh` prints `remote software version <x>` only at `DEBUG1` and
  above (SQ-036). Masters run at `LogLevel=ERROR` and mux clients never speak to the server
  ([ssh](ssh.md)), so only the collect connection ([secrets](secrets.md)) - a fresh `ssh` made
  once per `add` or `set host|user|port|identity` - can read it. That connection alone runs at
  `DEBUG1`; the version is taken from its stderr and the `debug1:`/`debug2:`/`debug3:` lines are
  stripped before the exit classifier or `add`'s message sees them, so the higher level changes
  no decision. The string is kept in `capabilities.json` beside the probe.
- **The SFTP extension fingerprint**, free on every connection. OpenSSH's `sftp-server`
  advertises a long list including `fsync@openssh.com` and `lsetstat@openssh.com` (SQ-025).
  Go's `pkg/sftp`, which is what a Tailscale SSH node answers with, advertises exactly
  `hardlink@openssh.com`, `posix-rename@openssh.com` and `statvfs@openssh.com` (SQ-024).

`status` prints what the two can say on a `server software` line (`Tailscale   SFTP: Go
pkg/sftp`), and no line at all when they can say nothing, rather than "unknown". "Not OpenSSH"
and "not identified" stay apart: only the first changes any wording, because an unidentified
server may well be an old OpenSSH.

### Features

| Feature | Levels (best first) | What unlocks the next level |
|---|---|---|
| Change detection | helper · sweep · poll | shell access plus a writable, executable directory and a supported OS/arch for the helper; plain shell access for the sweep |
| Rename detection | rename events (helper) · delete+create | the helper |
| Change evidence | ns-mtime + inode (helper or GNU sweep) · size + mtime | shell access |
| Permissions | mapped to Finder capabilities (`id` available) · everything writable | shell access; `permissions none` turns the mapping off where ACLs make mode bits misleading ([names and attributes](names-and-attributes.md)) |
| Atomic overwrite | `posix-rename@openssh.com` · remove+rename | OpenSSH ≥ 4.9 or a server that offers the extension |
| Durable writes | `fsync@openssh.com` · none | OpenSSH ≥ 6.3 |
| Transfer sizing | `limits@openssh.com` · conservative 32 KB requests | OpenSSH ≥ 8.5 |
| Collision-safe create | server-enforced (non-overwriting `rename` fails on an existing name) · `lstat` preflight, one extra round trip per create/rename | a server whose plain `rename` refuses to overwrite, as OpenSSH does |

### Server free space

`statvfs@openssh.com` is probed and shown as "Server free space". Finder cannot display it for a
third-party domain, so it is not a capability level.

It is measured where a connection already exists and a round trip is already being spent: on
every connection, beside the `realpath` and `lstat` that bring a location up, and on
`status --probe`, the one form of `status` that asks the server anything. `status` itself never
measures it (see [How `status` is built](#how-status-is-built)).

- The figure and the wall-clock time it was taken go in `capabilities.json` beside the probe.
- A figure older than an hour is printed with its age: `1.8 TB of 4.0 TB (as of 3h ago)`.
- A location that has never connected shows `unknown`. A `capabilities.json` without the field
  is one of those, not an error.

### Line format

Every line has the same shape: a level glyph, the feature name, the level in use and, whenever
that is not the best level, an indented `upgrade:` line naming the concrete requirement. A
summary counts how many features are at `●`.

| Glyph | Meaning |
|---|---|
| `●` | best available level |
| `◐` | a fallback is in use |
| `○` | the feature is off entirely |

Rules that keep the format stable:

- **Runtime downgrade** (for example the helper's stream died with an error that was not the
  network's and the location fell back to sweep): `◐`, the level in use, a `note:` with the
  reason and time, and the `upgrade:` line.
- **User-forced `watch-mode`** below the best available: `◐` with `note: forced by watch-mode
  <x>` and no `upgrade:` line, since the user chose it.
- **`permissions none`**: `◐`, level `everything shown writable`, `note: forced by permissions
  none`, no `upgrade:` line. `set create-check lstat` does the same to the collision-safe-create
  line (`note: forced by create-check lstat`).
- **Helper being deployed** - the tier is chosen and the binary is still going up the wire,
  which is where `add` writes its one report: the sweep level with ``note: the helper is being
  deployed on this connection; `sshdrive status` shows it once it is up`` and no `upgrade:`
  line. There is nothing for the user to do, and the note a server that cannot run the helper
  would carry is not true yet. `add` waits a bounded few seconds for the first attempt to settle
  before printing, so this state is rare.
- **Helper not active on a server with shell access**: the change-detection line carries a
  `note:` saying why, and `upgrade: the remote helper (push events, real renames)`. The note is
  whatever the deployment said, verbatim, not its category. The cases:
    - `helper off (user setting)`, followed by the `sshdrive set <name> helper on` that turns it
      back on
    - `helper unsupported: <uname -sm>`
    - `no writable directory for helper`
    - `cache directory is noexec`
    - `helper upload failed: <reason>`
    - `the server will not give the helper a channel of its own (MaxSessions 2)`
- **`fsync@openssh.com` and `limits@openssh.com` on a server known not to be OpenSSH** are stated
  as server facts, not upgrades. They are OpenSSH's own extensions and no version of Go's
  `pkg/sftp` advertises either (SQ-024), so `upgrade: fsync@openssh.com (OpenSSH >= 6.3)` would
  ask the user to replace their SSH server. The line keeps its `◐` and level and carries `note:
  fsync@openssh.com is an OpenSSH extension and <server> does not implement it`, with no
  `upgrade:` line. Where the software is unknown nothing changes.
- **Runtime not up**: the report shows the probe cached in `capabilities.json`, marked `probed
  <age> (cached)`, and guesses nothing about what changed since.

### `--json`

`--json` emits the same data: an array of `{feature, level, best, glyph, upgrade, note}` objects,
the probe timestamp, the optimal and total counts, whether the probe was cached, the server
software, and `sftpExtensions`. `sftpExtensions` is **every** name the server advertised in
`SSH_FXP_VERSION`, in the order sent, not only the five the levels depend on - so a line saying
the server did not advertise `fsync@openssh.com` can be checked from the user's own machine.
