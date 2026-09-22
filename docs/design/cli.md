# The CLI

Built with `swift-argument-parser`. Every command is an XPC request to the
agent; if the agent is not running the mach lookup starts it, and if the
lookup fails because no login item is registered yet (a fresh install
whose postflight did not run) the CLI launches the bundle it lives in
with `open -g` once, as the postflight does
([packaging](packaging.md)), waits for the service, and retries; a
registered but disabled item gets the Login Items instruction of
[the extension page](extension.md) instead. All prompts use a hidden tty
read and can be avoided for scripting with flags or stdin.

A command that changes state prints nothing on success beyond prompts,
warnings and errors. The global `-v` / `--verbose` flag restores the full
report: the `ssh -G` resolution, the attribution of each value against
`~/.ssh/config`, and, for `add`, the capability report. The commands whose
job is to report - `list`, `show`, `status`, `pins`, `logs`, `doctor` -
print their output either way.

```
sshdrive [-v|--verbose] <command> [args]

sshdrive add [user@]host-or-alias[:port] [--nickname NAME] [--remote-path PATH]
             [--user USER] [--port N] [--identity PATH] [-o SSHOPTION]…
             [--jump HOP[,HOP]…] [--permissions mode|none]
             [--password | --password-stdin | --no-password]
             [--cache-ttl 1h] [--trust-first]
sshdrive add <nickname> [user@]host-or-alias[:port] [same flags]
        The same command. A second positional argument makes the first the
        nickname, because `sshdrive add nas alec@nas` is what people write
        and what a script reads better as; `--nickname` still works and
        `--remote-path` is also spelled `--path`.
        The agent runs `ssh -G`; under `-v` the resolution and the
        attribution against `~/.ssh/config` are printed (locations.md).
        Whatever the verbosity, `add` warns when the terminal's `PATH` or
        `SSH_AUTH_SOCK` differs from the login shell snapshot the agent
        will use (secrets.md) and when the resolved `proxycommand` is a
        hand-written `ssh` (ssh.md).
        The agent then connects once with the same command it will use
        later, in its own environment (secrets.md, ssh.md): the host-key
        question and any password or passphrase prompt are relayed to the
        terminal and stored on success. Refuses locations that need a touch
        or a one-time code on every connection, naming the key that asked
        for the touch and the `--identity` that avoids it (secrets.md).
        Then the agent records the location, probes the server, and adds
        the File Provider domain. Under `-v` the capability report is
        printed (below); `sshdrive status` shows it at any time. Says so if
        the helper will be deployed (change-detection.md, tier 2).
        `--password` reads the password from the terminal before connecting
        and `--password-stdin` from stdin, for scripts; `--no-password`
        answers every password prompt with the skip (secrets.md), so the
        location is key-only or is not created.

sshdrive list                     table: name, host, secrets, mounted, TTL, state
sshdrive show <name>              full detail: ssh binary and version, `ssh -G` resolution,
                                  environment snapshot (ssh.md), whether the location runs with
                                  IdentityAgent=none or through the key agent (ssh.md), the
                                  ProxyJump chain the agent built, mount path, last error
sshdrive remove <name> [--keep-files]
                                  removes domain + config, and each keychain item the
                                  location names that no remaining location also names
                                  (secrets.md keys items by user@hostname:port, so two locations
                                  on one host share one); on its last connection removes the
                                  helper binary and its directory from the server when no other
                                  location of this Mac on the same user@hostname:port uses them
                                  (another Mac's helper running from there keeps its inode and
                                  re-uploads on its next connection);
                                  refuses while uploads are pending unless
                                  --force; --keep-files uses the system's
                                  preserve-downloaded-data removal mode so cached files are
                                  kept in the folder the system chooses
sshdrive remove --all             every location; run it before `brew uninstall` (packaging.md)
sshdrive mount <name> / unmount <name>
                                  add/remove the File Provider domain without
                                  forgetting the location
sshdrive set <name> nickname|cache-ttl|remote-path|host|port|user|identity|watch-mode|helper|permissions|create-check <value>
                                  nickname renames the domain **in place**: one
                                  `add(domain)` on the identifier the system already holds,
                                  which renames the mount directory under
                                  `~/Library/CloudStorage` and the sidebar entry, keeps every
                                  cached file and leaves a pending upload pending (macOS 26.4,
                                  2026-09-05), so it is not refused and drops nothing;
                                  remote-path re-creates the domain, since a new root
                                  invalidates every path in the index, so it is refused while
                                  uploads are pending and warns that the cache is dropped
                                  otherwise;
                                  host, user, port and identity change what the stored
                                  secrets are keyed on or which key is offered, so they
                                  re-run the collect connection exactly as passwd does
                                  (secrets.md) before the change is saved;
                                  watch-mode: auto|poll|sweep|helper (change-detection.md);
                                  helper on|off: allow the remote helper (default on);
                                  permissions mode|none: map server mode bits to Finder
                                  capabilities (names-and-attributes.md);
                                  create-check auto|lstat: force the lstat preflight before
                                  every create and rename regardless of the probe (writes.md)
sshdrive set <name> option add|remove <SSHOPTION>
                                  edit the extra -o list
sshdrive passwd <name>            re-run the collect connection through the agent (secrets.md) and
                                  replace stored secrets; an item shared with other
                                  locations is replaced for them too, and passwd names them
sshdrive test <name>              connect + list root, print timing, run the
                                  capability probe and print the report (below)
sshdrive status [<name>] [--json] [--probe]
                                  per-domain state, sync errors, hidden names, and the
                                  capability report (below); --probe re-runs the server
                                  probe instead of using the cached result
sshdrive evict <name> [path] [--all] [--unpin-all]
sshdrive accept-deletions <name> [path]
                                  apply deletions the mass-deletion guard is holding
                                  (change-detection.md)
sshdrive pin <name> <remote-path>
                                  keep a folder or file fully offline (pinning.md); same
                                  effect as Finder's "Keep Downloaded" entry.
                                  `/` or `.` pins the whole location
sshdrive unpin <name> <remote-path>
                                  clears an explicit pin, or excludes the path if it
                                  inherits a pin from a folder above (pinning.md)
sshdrive pins [<name>] [--export | --import FILE]
                                  tree of pins and exclusions with cached size and file counts
sshdrive logs [--follow] [<name>] [--last 1h] [--debug]
                                  our subsystem's unified log, through `/usr/bin/log show` and
                                  `log stream` with a subsystem predicate, since `OSLogStore`'s
                                  local store is not open to a standard user. The predicate is
                                  not only ours: everything the *system* decides about a domain
                                  is logged by `fileproviderd` under Apple's subsystem and never
                                  reaches ours, so the query is
                                  `subsystem == "org.shirls.sshdrive"` **or** a `fileproviderd`
                                  line naming us, and a `<name>` narrows both halves to that
                                  location - ours by the domain identifier or the display name,
                                  since our lines carry one or the other, and fileproviderd's by
                                  the identifier, which is all it knows. `--info` is always
                                  passed, because `log show` hides the info level and most of the
                                  transport's detail is there. The CLI `exec`s `log`, so Ctrl-C
                                  ends a `--follow`; it is the one command that is not a request
                                  to the agent, and it asks the agent only which location a
                                  `<name>` means, falling back to matching that text when the
                                  agent is not running - which is exactly when someone wants the
                                  log
sshdrive doctor                   checks: app in /Applications, quarantine attribute stripped,
                                  extension registered (pluginkit), login item enabled and agent
                                  reachable, app group container writable, CLI on PATH, ssh
                                  version, macOS version, login shell snapshot obtained (ssh.md);
                                  reminds that `remove --all` must precede `brew uninstall`
                                  (packaging.md)
sshdrive agent start|stop|restart
                                  stop asks the agent to exit cleanly; launchd leaves it down
                                  until the next mach lookup, which any CLI command or extension
                                  call causes, so stop is a pause, not a disable (packaging.md).
                                  Disabling is the Login Items switch in System Settings.
                                  **stop shuts every location's master and mux clients down
                                  before exiting**, the same thing `remove` does per location:
                                  exiting without it leaves an `ssh -N` per location holding a
                                  connection to a server, with a control socket the next start
                                  unlinks out from under it, and the sweep then has nothing to
                                  ask (ssh.md). The reply is sent first - the CLI is waiting on
                                  it, and `-O exit` against an unreachable server takes seconds -
                                  and a 20 s backstop exits anyway. A TERM from the cask's
                                  `uninstall` stanza takes the same path and exits 0
                                  (packaging.md).
```

`<name>` resolves nickname, then host, then id prefix.

A host-key change needs no command of ours: `status` prints the
`ssh-keygen -R` line to run ([host keys](secrets.md)).

**How `status` is built, and what it is never allowed to wait for.**
`status` is the command a user runs *because* something looks wrong, so
the one thing it may not do is join the queue behind whatever is wrong.
Two rules make that true:

- **It reads the index through a read-only reader of its own, never
  through the location's writer.** `LocationRuntime` is an actor because
  the index has a single writer by design ([components](components.md)),
  and a directory listing writes its rows inside one synchronous SQLite
  transaction ([the index](item-index.md)) - so a hop onto that actor waits
  for a whole listing, and a row is about eighteen of them per location:
  the hidden names, the held deletions, the root set, one row read per
  materialized file, the pin tree. The extension opens `index.sqlite`
  read-only in WAL mode ([the extension](extension.md)), and the agent's
  own report does the same. A WAL reader neither blocks the writer nor
  delays it and always sees a consistent snapshot - for a listing in
  flight, the state before it. The agent remains the sole writer. What is
  left on the runtime is taken in **one** entry: the channel budget, the
  identity, the transfer counters, the last error, the hidden-name
  sentences, the last change-detection cycle and the free-space figure.
  While a rebuild is running (`meta.reconciling`) the row says the index is
  being rebuilt and prints the rest of itself, rather than printing zeroes
  that read as facts about the server; a location that has never started
  has no index file, which is the same kind of answer and not an error.
- **Each location's section is bounded, and the sections run
  concurrently.** With no `<name>` the locations are built at the same
  time and printed in the order `config.json` holds them, and each section
  runs under a 20 s deadline on the agent's clock - the same bound the
  File Provider calls carry, and well inside the CLI's own timeout. A
  location that has stopped answering therefore costs its own row a
  `did not answer within 20 s` note; the other locations are reported in
  full. A report about three good locations is worth having when the
  fourth is the one that has gone.

`status` also does not walk the replica for a set someone else has just
walked. The materialized set feeds the [root set](root-set.md), the
[TTL pass](eviction.md) and this report; the first two take it on their own
schedules and publish it, and every *change* to it arrives as
`materializedItemsDidChange`, so an entry taken within five minutes is the
current set and not merely a recent one. `status` drains
`enumeratorForMaterializedItems()` for itself only when there is no such
entry.

## Capability report in `sshdrive status`

Several features run at different levels depending on what the remote server
offers. The probe runs on every connection and on `sshdrive test` and
`status --probe`; the result is cached in
`domains/<id>/capabilities.json` with a timestamp and the server banner. It
consists of the SFTP `extensions` list from the SFTP init reply, whether
that reply arrived clean or behind rc-file output
([remote command execution](security.md)), whether an exec channel opens and
delivers its sentinel, and one shell script that reports
`uname -sm`, `id -u` and `id -G` (two commands: POSIX `id` accepts only
one of `-u`, `-g`, `-G` per invocation), `$HOME` as the account spells
it, the `find` flavour and whether it takes `-cmin`, the presence of
`sha256sum`/`shasum`, and a writable, executable cache directory. The
flavour comes from the `busybox` banner and from the `-cmin` answer itself,
never from an exit status: a busybox `find --version` prints
`find: unrecognized: --version` and **exits 0** (measured on BusyBox 1.36.1,
2026-09-04), so an exit-status probe calls every busybox server GNU.

The report always renders the extension set recorded with the probe,
including on the cached path, and never an empty default: a line claiming
the server does not advertise an extension has to come from what the server
actually said.

**Which server this is.** Several lines below are claims about the
server rather than about us, so the report names the software when it can,
from two pieces of evidence that are available at different times:

- **The identification string.** `ssh` prints `remote software version
  <x>` at `DEBUG1` and above. The runtime masters run at `LogLevel=ERROR`
  and a mux client never speaks to the server at all
  ([SSH process management](ssh.md)), so the one connection that can read it
  is the **collect connection** ([secrets](secrets.md)) - a real, fresh
  `ssh` the agent makes once per `add`, `passwd` or
  `set host|user|port|identity`. That connection alone runs at `DEBUG1`,
  the version is taken out of its stderr, and the `debug1:`/`debug2:`/
  `debug3:` lines are stripped again before the exit classifier or
  `add`'s own message sees any of it, so raising the level changes no
  decision. The string is kept in `capabilities.json` beside the probe.
- **The SFTP extension fingerprint,** which every connection has for
  free. OpenSSH's `sftp-server` advertises a long list including
  `fsync@openssh.com` and `lsetstat@openssh.com`; Go's `pkg/sftp`
  advertises exactly `hardlink@openssh.com`, `posix-rename@openssh.com`
  and `statvfs@openssh.com` and nothing else, which is what a Tailscale
  SSH node answers.

`status` prints what the two together can say - `Tailscale   SFTP: Go
pkg/sftp` - and nothing at all when they can say nothing, rather than a
line reading "unknown". "Not OpenSSH" and "not identified" are different
answers and are kept apart: only the first changes any wording, because
an unidentified server may well be an old OpenSSH.

The catalogue of server-dependent features:

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

`statvfs@openssh.com` is probed and shown in `status` as "server free
space", but Finder has no way to display it for a third-party domain, so it
is not a capability level.

**It is measured at probe time and cached, and `status` never measures it.**
It is the one line of the report that is a live number rather than a
property of the server, and asking for it from `status` would be a wire call
through the connection gate ([offline behaviour](offline.md)): on a location
whose connection is in progress the call waits behind that attempt, up to
the 60 s authentication deadline, and on a location with no attempt at all
it *starts* one - a status command dialling a server the user has not
touched. So the `statvfs` is made where a connection already exists and a
round trip is already being spent: on every connection, beside the
`realpath` and `lstat` that bring a location up, and again on
`status --probe`, which is the one form that asks the server for anything.
The figure and the wall-clock time it was taken go in `capabilities.json`
beside the probe, `status` renders what is there, and a figure older than an
hour is printed with its age (`1.8 TB of 4.0 TB (as of 3h ago)`) so it is
not read as this minute's. A location that has never connected shows
`unknown`; a `capabilities.json` written before the field existed is one of
those, not an error. The same rule covers the state word beside it:
`online`/`offline (<reason>)` comes from the connection gate and the
breaker, never from an `ssh -O check`, which spawns a process and waits
up to ten seconds for it inside the master's actor.

Every line in the report follows one shape so all permutations read the same
way: a level glyph, the feature name, the level in use, and, whenever the
level is not the best one, an indented `upgrade:` line naming the concrete
requirement. Glyphs: `●` best available level, `◐` a fallback is in use, `○`
the feature is off entirely. A summary counts how many features are at `●`.

```
$ sshdrive status
nas    alec@nas.tail1234.ts.net:22   mounted  online   2 pending uploads   cache 1.2 GB / TTL 1d
       capabilities 7/8 optimal, 1 upgradeable          probed 3m ago
work   alec@build.example.org:22     mounted  offline since 14:02   0 pending   cache 210 MB / TTL 1h
       capabilities poll-only (SFTP-only account), 7 upgradeable   probed 2h ago (cached)

$ sshdrive status nas
SSH Drive - nas
  Server    alec@nas.tail1234.ts.net:22   OpenSSH_9.6   Linux x86_64   shell access: yes
            ssh resolves nas via ~/.ssh/config (user, port, identityfile)
            ssh /usr/bin/ssh (OpenSSH_9.6p1); env: PATH and SSH_AUTH_SOCK from /bin/zsh -il, snapshot 2h ago
  State     mounted at ~/Library/CloudStorage/SSHDrive-nas   online   last change 12s ago
  Auth      passphrase stored for ~/.ssh/id_nas   host key in ~/.ssh/known_hosts
  Sync      2 pending uploads (14.1 MB)   0 conflicts   0 held deletions   last error none
  Cache     1.2 GB materialized (312 files), 480 MB kept   TTL 1d   next eviction sweep in 3m
  Pins      Documents/thesis   Photos/2026
  Not shown 1 name (case collision: build/Makefile vs build/makefile)

  Capabilities  7/8 optimal   probed 3m ago
  ● change detection   helper 1.2.0 at ~/.cache/sshdrive (push, ~1s)   watch-mode auto
        ignores: .sshdrive-upload-*  .*.swp  *~  .#*  4913
  ● rename detection   helper move events
  ● change evidence    ns-mtime + inode
  ● permissions        mapped (uid 1000, groups 1000 100)
  ● atomic overwrite   posix-rename@openssh.com
  ● durable writes     fsync@openssh.com
  ◐ transfer sizing    conservative 32 KB requests
        upgrade: limits@openssh.com (OpenSSH ≥ 8.5) — server does not advertise it
  ● collision-safe create   server-enforced
  Server free space  1.8 TB of 4.0 TB

$ sshdrive status work
SSH Drive - work
  Server    alec@build.example.org:22   OpenSSH_8.2   unknown OS   shell access: no (SFTP-only account)
  …
  Capabilities  1/8 optimal   probed 2h ago (cached; offline)
  ◐ change detection   poll (SFTP readdir every 60s while active)
        upgrade: shell access on the server enables the helper (push); plain shell access enables remote sweep
  ◐ rename detection   delete + create (identifiers not preserved on remote renames)
        upgrade: the helper, which needs shell access
  ◐ change evidence    size + mtime (same-second rewrites of equal size are missed)
        upgrade: shell access
  ◐ permissions        everything shown writable; permission errors appear after upload
        upgrade: shell access
  ◐ atomic overwrite   remove + rename (brief window where the file is absent)
        upgrade: posix-rename@openssh.com (OpenSSH ≥ 4.9) — server did not advertise it
  ◐ durable writes     none; uploads are complete when the server acknowledges the write
        upgrade: fsync@openssh.com (OpenSSH ≥ 6.3)
  ◐ transfer sizing    conservative 32 KB requests
        upgrade: limits@openssh.com (OpenSSH ≥ 8.5)
  ● collision-safe create   server-enforced
```

Rules that keep the format stable across permutations:

- A runtime downgrade (for example the helper's stream died with an error
  that was not the network's and the location fell back to sweep) shows the level in use with `◐` and a `note:` line giving the
  reason and time, in addition to the `upgrade:` line.
- A user-forced `watch-mode` below the best available shows `◐` with
  `note: forced by watch-mode <x>` and no `upgrade:` line, since the user
  chose it.
- **While the helper is being deployed** - the tier is chosen and the binary
  is still going up the wire, which is exactly where `sshdrive add` writes its
  one report - the line shows the sweep level with `note: the helper is being
  deployed on this connection; \`sshdrive status\` shows it once it is up` and
  **no `upgrade:` line**: there is nothing for the user to do, and the note a
  server that genuinely cannot run it would carry is a claim about the server
  that is not true yet. `add` waits a few seconds for that first attempt to
  settle before printing at all, so the state is rare; the wait is bounded
  and this is what is printed when it runs out.
- When the helper is not the active tier on a server with shell access, the
  change-detection line carries a `note:` saying why: `helper off (user
  setting)`, `helper unsupported: <os>/<arch>`, `no writable directory for
  helper`, `cache directory is noexec`, `helper upload failed: <reason>`,
  or `the server will not give the helper a channel of its own
  (MaxSessions 2)`. Whatever the deployment actually said is what is
  printed, verbatim, rather than the category it falls into.
  The `upgrade:` line then names the fix, so a user who turned it off sees
  `sshdrive set nas helper on` and a user on an unsupported platform sees
  the request to file an issue with the `uname -sm` output.
- On a server where the probe found ACL evidence and `permissions`
  is `mode`, the permissions line carries `note: ACLs detected (<evidence>);
  mode bits may understate access` and, in place of `upgrade:`,
  `consider: sshdrive set <name> permissions none`. With `permissions none`
  it shows `◐` and `note: forced by permissions none`, like a forced
  watch-mode.
- `--json` emits the same data: an array of `{feature, level, best, glyph,
  upgrade, note}` objects plus the probe timestamp, for scripting, and
  `sftpExtensions`: **every** name the server advertised in `SSH_FXP_VERSION`,
  in the order it sent them, not only the five levels above depend on. A line
  saying the server did not advertise `fsync@openssh.com` is a claim about the
  server, and this is what makes it checkable from the user's own machine
  rather than believed.
- **`fsync@openssh.com` and `limits@openssh.com` are stated as server
  facts, not upgrades, on a server known not to be OpenSSH.** They are
  OpenSSH's own extensions: no version of Go's `pkg/sftp` advertises
  either, so `upgrade: fsync@openssh.com (OpenSSH >= 6.3)` asks that
  user to replace their SSH server. Where the software is identified and
  is not OpenSSH the line keeps its `◐` and its level and carries
  `note: fsync@openssh.com is an OpenSSH extension and <server> does not
  implement it`, with no `upgrade:` line. Where the software is unknown
  nothing changes.
- When offline, the cached probe is shown with "(cached; offline)" and no
  guesses are made about what changed.
