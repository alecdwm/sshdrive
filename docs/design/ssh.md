# SSH process management

The agent owns every connection. It spawns `ssh`, supervises it, opens the
channels the SFTP client and the remote commands run on, and classifies what
happens when one dies.

Per mounted location the agent keeps one master connection and opens
channels on it as needed, all through the system `ssh`:

```
ssh -N -o ControlMaster=yes -o ControlPath=$TMPDIR/sshdrive-<id8> -o ControlPersist=no \
    -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=15 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
    -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR \
    -o RemoteCommand=none -o RequestTTY=no -o StdinNull=no -o ForkAfterAuthentication=no \
    -o BatchMode=no -o PermitLocalCommand=no -o ForwardAgent=no -o ForwardX11=no \
    -o ClearAllForwardings=yes \
    -o IdentityAgent=none \                     # omitted only for agentDependent locations (below)
    <overrides as -o User= / Port= / IdentityFile=> <sshOptions…> <host>
                                                # the master: no session, only the mux socket;
                                                # the same overrides go on every ProxyJump hop (below)

MUX="-F /dev/null -S $TMPDIR/sshdrive-<id8> -o BatchMode=yes -o ProxyCommand=/usr/bin/false"
                                                # mux clients read no config and cannot connect
                                                # on their own (below); <host> is a placeholder
ssh $MUX -s <host> sftp                        # SFTP channel for metadata
ssh $MUX -s <host> sftp                        # SFTP channel for bulk transfers
ssh $MUX <host> sh -s                          # exec channels: probe, sweep, helper
ssh $MUX -O check <host>                       # is the master process alive (local only); -O exit tears it down
```

- **The master carries no session.** It is `-N`: authentication, the TCP
  connection and the mux socket, nothing else. Every SFTP and exec channel
  is a mux client with its own process, so a wedged SFTP channel (a
  protocol error, a stuck server-side `sftp-server`) is killed and
  reopened on its own without touching the connection, and the master
  outlives any one of them. `ControlPersist` is `no`, and must stay so:
  with ControlPersist set, `ssh` forks the master into the background
  after authentication and the process the agent spawned exits, even
  under `-N`, which would leave the agent with no pid to supervise, no
  stderr to read and no exit to watch. With it off, the `-N` master is
  the agent's child for the life of the connection and its exit is the
  disconnect signal for the location. `-O check` asks that process, over
  the socket, whether it is alive; it says nothing about the server or
  the TCP connection, so it is the cheap "is our child sane" check and
  the per-request deadline ([docs/design/sftp.md](sftp.md)) is the real liveness
  probe. `sshdrive status` does not use it either: the online/offline
  word comes from the connection gate, which knows without touching the
  wire. `-O exit` is the clean shutdown. The socket itself is created
  only once authentication has succeeded, so its appearance is the signal
  the authentication deadline ([docs/design/secrets.md](secrets.md)) waits for.
- **The connection is ours alone.** The user's `~/.ssh/config` may set
  `ControlMaster auto` with a `ControlPath` for the host, in which case a
  plain `ssh nas` would silently attach to a terminal session's socket, or
  a terminal would attach to ours. Neither is acceptable: we want our own
  TCP connection with our own keepalive and timeout settings, tuned for a
  Finder that must not hang, and the user's interactive sessions want
  theirs. `ssh` gives command-line `-o` options precedence over every
  config file, so the `ControlMaster`, `ControlPath`, `ControlPersist`,
  `ConnectTimeout`, `ServerAliveInterval` and `ServerAliveCountMax` values
  above always win over whatever the config says for that host. A second
  group of overrides fixes the shape of the master and of every
  `ProxyJump` hop, because a host block written for interactive use
  breaks both: `RemoteCommand` makes any `ssh` given a command or
  subsystem exit with "Cannot execute command-line and remote command",
  `RequestTTY force` puts a pty under the stream, `StdinNull` closes
  the channel's stdin, `ForkAfterAuthentication` detaches the master
  exactly as `ControlPersist` would, `BatchMode` disables the prompts
  askpass answers, `UpdateHostKeys ask` raises a question nobody is
  there to answer ([docs/design/secrets.md](secrets.md)), and `LocalCommand`,
  `ForwardAgent` and the forwardings run or expose things the mount has
  no use for. So the master and every hop also carry `RemoteCommand=none`,
  `RequestTTY=no`, `StdinNull=no`, `ForkAfterAuthentication=no`,
  `BatchMode=no`, `UpdateHostKeys=no`, `PermitLocalCommand=no`,
  `ForwardAgent=no`, `ForwardX11=no` and `ClearAllForwardings=yes`. Mux
  clients need none of this, because they read no config at all (next
  bullet). The `ControlPath` under `$TMPDIR/sshdrive-<id8>` is namespaced
  to us, so no other client will find it either, and `sshdrive show`
  prints any control-socket or session-shape settings the config would
  have applied, so the user can see they were overridden.
- **Mux clients read no config and cannot connect on their own.** A mux
  client asked to open a session does not fail when its socket is
  missing: `ssh` notes "Control socket does not exist" at debug level
  and makes a direct connection of its own, reading the config files,
  running `Match exec`, and authenticating from scratch (verified
  against OpenSSH 9.6, where only the `-O` commands fatal on a missing
  socket, and `ControlMaster=no` does not change it). Under the agent
  that would be a second, unsupervised connection with the config's own
  timeouts, or, since the agent mints no secrets token for mux clients,
  an askpass refusal that the exit classifier below would read as an
  authentication failure and stop the location for. So every mux client
  runs with `-F /dev/null`, which drops `/etc/ssh/ssh_config` as well as
  the user's file, `BatchMode=yes` so it can never prompt, and
  `ProxyCommand=/usr/bin/false` so a fallback connection dies before a byte is
  exchanged. The mux protocol uses nothing from the config: the `<host>`
  argument is a placeholder, the command or subsystem travels over the
  socket, and the master's session already carries every override. A
  mux client that exits before its channel opened is always classified
  as **master lost**, never as an authentication failure: the agent runs
  `-O check`, a failing check drops the master and reconnects through
  the breaker ([docs/design/offline.md](offline.md)), and a passing one retries the
  channel once. Dropping the config also stops `Match exec` scripts
  running once per channel and keeps the system file's `SendEnv` off our
  sessions.
- **Key agents are consulted only by locations that need them.** A
  location that passed the collect connection's first pass
  ([docs/design/secrets.md](secrets.md)) authenticates with key files, stored
  passphrases and passwords, and its runtime spawns, master and hops
  alike, carry `IdentityAgent=none` exactly as that pass did. Without the
  override `ssh` would find the same key in the 1Password or Secretive
  agent the config names, sign through it, raise the agent's approval
  prompt on every unattended reconnect, and hit the 60 s deadline every
  morning, while the passphrase that was stored precisely so the mount
  could come up before any agent is unlocked went unused. Only an
  `agentDependent` location runs without the override, and it is the only
  kind subject to the socket check below and to the deadline re-arm.
  `sshdrive show` says which of the two a location is.
- One SFTP channel is used for metadata (`stat`, `readdir`, `rename`, small
  files) and a second for bulk downloads and uploads, so a long transfer
  never blocks a listing. Exec channels are opened per command. All of them
  are channels on one TCP connection, so a server's `MaxSessions` (default
  10) usually suffices: the agent holds at most five per location (two
  SFTP, the helper stream, a sweep, a probe or delete walk).
  Hardened servers set `MaxSessions` to 1 or 2, and the probe finds the
  limit by opening channels until one is refused
  (`mux_client_request_session: session request failed`). The `-N` master
  carries no session of its own, so the count is exactly the mux clients,
  and the question the probe has to answer is not "what is `MaxSessions`"
  but **"may I hold three at once"** - metadata, bulk, and one exec -
  because three is the smallest budget under which the bulk channel is
  affordable. Two channel opens answer it, and the second of them *is*
  the bulk channel, so nothing is opened twice and nothing is opened that
  is thrown away except the third. A channel is proved open by completing
  the SFTP handshake on it: `ssh` spawns successfully whether or not the
  session was granted, and only the refusal on stderr, or a handshake
  that never lands, tells the two apart. The result is cached in
  `capabilities.json`, keyed by the location, and re-probed on
  `status --probe`. It cannot be keyed on a server banner, because the
  agent never sees one: its `ssh` runs at `LogLevel=ERROR`, which prints
  no remote version, and a mux client speaks to the master's socket
  rather than to the server. A cached answer can be wrong two ways. A
  server changes its mind, which the explicit re-probe covers. And `ssh`
  fails a channel open just as readily because the master it was speaking
  to has gone: a probe that ran in that moment and believed it would
  report "the server allows one channel at a time (MaxSessions 1) ...
  SFTP-only", with no shell and no helper, against a healthy Debian, and
  hold that across every later restart. So the probe tells a refused
  session from a dead connection - the refusal `ssh` actually prints,
  against a master that is still running - and **records nothing at all**
  when the connection is what failed, failing the connect attempt instead
  so the breaker ([docs/design/offline.md](offline.md)) tries again; and an abrupt
  loss of a connection that was up marks the cached answer as no longer
  evidence, so the next connect probes again. The values stay in the file
  for an offline `status` to print. The one `ssh` the agent runs that *is*
  neither a master nor a mux client - the collect connection
  ([docs/design/secrets.md](secrets.md)) - raises `LogLevel` to `DEBUG1` for that
  connection alone and reads the identification string once, which is
  where the capability report's "server software" line comes from
  ([docs/design/cli.md](cli.md)); its debug lines are stripped before the exit
  classifier below or `add`'s own message sees them, so nothing else
  changes. A cached budget that no longer holds is noticed anyway,
  because opening the bulk channel is what the cached answer is used for.
  At 2 the bulk SFTP channel is dropped, transfers share the metadata
  channel under the scheduler ([docs/design/sftp.md](sftp.md)), and the helper gets
  the one exec channel: the 30-minute insurance sweep at that tier stops
  it, sweeps on the same channel and restarts it, since the sweep already
  covers what the restart would miss; at 1 there is no exec channel at
  all, the location is SFTP-only in every respect (`poll`, no `id`, no
  helper) and the probe records nothing beyond the SFTP extensions.
  `status` shows the limit and the levels it forced.
- `ControlPath` is `$TMPDIR/sshdrive-<id8>`, the first eight hex digits
  of the location id, and deliberately not `%C`. `%C` hashes user, host
  and port, so two locations on one host ([docs/design/locations.md](locations.md))
  would compute the same socket path: the second master would find it,
  print "ControlSocket already exists, disabling multiplexing", and its
  mux clients would silently attach to the first location's connection.
  Length is the other reason: Unix socket paths are limited to 104 bytes,
  `$TMPDIR` on macOS is about 50, and `ssh` binds the socket under a
  temporary `<path>.<pid>` name before renaming it, so a 40-character
  `%C` hash does not fit and the group container path is longer still.
  `$TMPDIR` here means the directory `confstr(_CS_DARWIN_USER_TEMP_DIR)`
  returns, read directly rather than from the environment, since a
  launchd agent's environment is not guaranteed to carry it.
- **Orphans are not adopted.** If the agent crashes, its `ssh -N` children
  live on with their sockets in place, and `ControlMaster=yes` against an
  existing socket disables multiplexing and leaves later mux clients
  attaching to the orphan. So before its first connection the agent runs
  `-O exit` against every `sshdrive-*` socket in `$TMPDIR`, unlinks
  whatever is left, **and kills the process that owned it**. The kill is
  not belt and braces: `-O exit` only reaches a master *through* its
  socket, so a master whose socket has already gone - or one that has
  stopped serving it - cannot be asked to leave at all, and unlinking the
  socket merely makes it unreachable while it goes on holding a TCP
  connection to the server, its mux clients and its share of the server's
  `MaxSessions` for ever. The pid comes from `ssh -O check`, which prints
  `Master running (pid=NNNN)` and is the only route there is from a socket
  to its process; the process is checked to still be named `ssh` before it
  is signalled, because a pid read from a socket left behind by an earlier
  boot may have been reused by anything, and then it gets TERM and, half a
  second later, KILL. The sweep matches on the socket **type** as well as
  the name: `$TMPDIR` is a shared directory and `sshdrive-` is not ours
  exclusively there, and a sweep keyed on the prefix alone counts six
  `sshdrive-nested-*.sqlite-wal`/`-shm` files - sidecars of the package's
  own temporary test databases - as orphaned sockets and reports a
  healthy install as failing (measured 2026-09-04). Each candidate is `lstat`ed,
  never `stat`ed, so a symlink planted at that name decides nothing. The
  complementary half is that `sshdrive agent stop` shuts every location's
  masters and mux clients down before the agent exits
  ([docs/design/cli.md](cli.md)), so the ordinary case never reaches the sweep.
  The location's socket path is also unlinked before every spawn, not only
  at startup: a master that died without `-O exit` leaves its socket
  behind, and `ssh` moves a new socket into place with `link`, which fails
  on an existing path and silently disables multiplexing for that
  connection.
- **Dead connections are detected three ways**, because keepalive alone
  leaves a 30 s window (`15 s × 2`) in which every request stalls: the
  keepalive itself; a per-request deadline in the SFTP client
  ([docs/design/sftp.md](sftp.md)), after which the request fails with
  `.serverUnreachable` and the channel is killed, and after a second
  consecutive timeout the master too; and sleep, at whose will-sleep
  message the agent does not wait to find out but runs `-O exit` on every
  master, reconnecting on wake, since a connection that slept through a
  network change is dead more often than not and dropping it before the
  sleep leaves no request in flight on a connection the Mac is about to
  abandon. Sleep and wake come from IOKit (`IORegisterForSystemPower`,
  `kIOMessageSystemWillSleep` and `kIOMessageSystemHasPoweredOn`), not
  from `NSWorkspace`, since the agent runs no `NSApplication`.
- `ssh` exiting is classified: connection errors are `.serverUnreachable`
  and the agent reconnects with jittered backoff **on its own schedule,
  not when something next asks** ([docs/design/offline.md](offline.md), rule 5); auth
  and host-key banners are `.notAuthenticated` ([docs/design/secrets.md](secrets.md))
  and **reconnection stops** until a change to the location's settings
  (`sshdrive set`), `sshdrive agent restart`, or
  `sshdrive debug breaker <name> --connect`. A stale password retried every
  minute is a `fail2ban` ban within the hour, and a refused prompt is
  never going to succeed unattended. An authentication that has not
  completed by the 60 s deadline is classified the same way and stops, for
  an `agentDependent` location; for a first-pass location, which no key
  agent can be holding up, the same timeout is a transient failure
  retried through the breaker. The one exception to stopping is a key
  agent that is not ready. `agent refused operation` on stderr
  is what 1Password and Secretive produce between login and their first
  unlock, and a socket that does not exist yet, because the key agent's
  app has not launched, is worse: `ssh` logs that only at debug level,
  so at `LogLevel=ERROR` the failure reads as a plain "Permission denied
  (publickey)", which would stop reconnection on exactly the morning
  this exception exists for. The agent therefore does not rely on stderr
  for this case. Before every spawn for an `agentDependent` location it
  connects to the key agent's socket itself; a missing or refusing
  socket is a **transient** failure without `ssh` being run at all, and
  the `agent refused operation` text covers the present-but-locked case
  once the socket exists. Which socket is the one `ssh -G` resolves as
  `identityagent`, printed with `~` already expanded, and only when that
  is unset or reads `SSH_AUTH_SOCK` does the snapshot's variable apply:
  1Password and Secretive both document their setup as an
  `IdentityAgent` line in `~/.ssh/config`, so for most agent-dependent
  locations `SSH_AUTH_SOCK` still names Apple's `ssh-agent`, which is
  always there and would make the check pass while the agent that
  actually holds the key was absent. Both are retried with the network
  backoff ([docs/design/offline.md](offline.md)), its cap raised from 60 s to 5
  minutes for this one case, since a locked key agent stays locked for
  hours and a socket probe every minute buys nothing, and the mount comes
  up once the key agent is unlocked without the user doing anything. The probe carries more weight than "the socket may not
  exist yet" suggests: measured against OpenSSH's own `ssh-agent` on
  2026-09-04, a **locked** agent does not refuse a signature either, it
  answers that it holds no identities, and `ssh` then exits with the same
  bare `Permission denied (publickey,password)` that a missing socket, a
  dead socket and a genuine refusal all produce at `LogLevel=ERROR`. So
  stderr separates none of the key-agent states and the pre-spawn probe
  is the only signal for all of them; the `agent refused operation` text
  stays because 1Password and Secretive are the two that emit it, and it
  is corroboration rather than the test. Reconnection stops only after
  `ssh` has been refused with its keys actually offered. A location
  stopped by the authentication deadline, as opposed to a refusal, is
  re-armed for one attempt on screen unlock and on the next File Provider
  request for its domain that arrives while the user is at the keyboard
  ([docs/design/secrets.md](secrets.md)). stderr is kept for `sshdrive status` in
  every case.
- **The binary is always `/usr/bin/ssh`**, spawned by absolute path with
  `argv[0]` set to that same path (see `ProxyJump`, below). The
  login shell's `PATH` (below) is for what `ssh` itself runs, `ProxyCommand`
  tools and `Match exec` scripts, never for choosing `ssh`: a Homebrew
  OpenSSH earlier in `PATH` is a different program with a different set
  of config keywords and without Apple's `UseKeychain` patch, and picking
  it silently would make "works in the terminal" and "works from the
  agent" two different questions. The cost, a config keyword Apple's
  build rejects, is caught at `add` ([docs/design/locations.md](locations.md)).
  `sshdrive show` prints the binary and its version.
- **`ProxyJump` chains are built by the agent, not by `ssh`.** When `ssh`
  sees a `ProxyJump`, it spawns the hop itself as
  `<argv[0]> -W '[%h]:%p' … <jump>`, and that child reads the config
  files but receives none of the parent's command-line `-o` options. Left
  alone, the bastion hop would ignore every override above: it would
  attach to a `ControlMaster auto` socket from the user's terminal, run
  with `StrictHostKeyChecking=ask`, use the key agent during the collect
  step's `IdentityAgent=none` pass so a bastion passphrase is never seen
  and stored, and keep the config's timeouts. So the agent never passes a
  `ProxyJump` through. When `ssh -G` resolves a `proxyjump`, the agent
  supplies its own
  `-o ProxyCommand='/usr/bin/ssh -W %h:%p <overrides> -l <jump-user> -p <jump-port> <jump-host>'`
  and cancels the resolved jump with `-o ProxyJump=none` **after** it,
  recursively for a multi-hop chain. The order of those two options is
  not cosmetic: both keywords write the same field, and
  `-o ProxyJump=none` placed ahead of `-o ProxyCommand=` makes `ssh`
  discard the `ProxyCommand` outright, so `ssh -G` prints neither and the
  master resolves the destination hostname itself, which behind a bastion
  does not exist (measured against OpenSSH 10.2p1 on macOS 26.4,
  2026-09-04). Nesting needs a second escape of its own. `ssh`
  percent-expands the **whole** `ProxyCommand` string before handing it
  to `/bin/sh -c`, including the `%h` and `%p` that belong to a hop
  nested inside it, so an inner hop's tokens are doubled once for every
  level it sits below the master: hop *n* carries `-W %h:%p`, hop *n-1*
  carries `-W %%h:%%p`, hop *n-2* `-W %%%%h:%%%%p`, and any other `%` in
  a nested value is doubled with them. Without that, hop 1 dials the
  destination's host and port instead of hop 2's and the connection ends
  at hop 2's host-key check, complaining that the identification of the
  bastion has changed (measured the same day). The user and port are separate
  flags because the `user@host:port` form is sugar of our CLI that `ssh`
  itself does not parse: `ssh -G alec@10.0.0.1:2222` resolves the host to
  the literal `10.0.0.1:2222`. `<overrides>` are the same options as the
  master's with `ControlMaster=no` **and `ControlPath=none`** in place
  of the mux settings, plus the `ForwardAgent=no`,
  `PermitLocalCommand=no`, `ClearAllForwardings=yes` and `RequestTTY=no`
  that `ssh` itself would have added. A hop needs no socket of its own,
  and `ControlMaster=no` alone is not enough to keep it off the user's:
  with `no`, `ssh` still attaches to an existing socket at whatever
  `ControlPath` the config names for the bastion, and `ssh -G` confirms
  it by printing the config's `controlpath` unchanged under
  `-o ControlMaster=no`; only `ControlPath=none` clears it. Every hop is
  a child of the master with the askpass environment
  ([docs/design/secrets.md](secrets.md)), so a bastion password prompt is answered
  like any other, and `sshdrive show` prints the chain it built.
  `argv[0]` is set to `/usr/bin/ssh` on every spawn regardless, because
  OpenSSH reuses `argv[0]` for any hop it does build and falls back to a
  `PATH` lookup of `ssh` when that is not an executable path. A
  `ProxyJump` given in the location's `sshOptions` is consumed the same
  way: the options are passed to `ssh -G`, so it appears in the resolved
  output like one from the config, and it is never handed to `ssh` as an
  option. The `ProxyCommand` string the agent builds is run by `ssh`
  through `/bin/sh -c`, so every value in it, identity paths, verbatim
  `sshOptions`, the jump host, is single-quoted by the rule that applies
  to remote scripts ([docs/design/security.md](security.md)). What the agent cannot
  fix is a `ProxyCommand` the user wrote by hand that itself invokes
  `ssh` (`ProxyCommand ssh -W %h:%p bastion`, the pre-`ProxyJump`
  idiom): that inner `ssh` is found through `PATH`, reads the config
  unmodified, attaches to any `ControlMaster auto` socket for the
  bastion, and signs through the key agent during the
  `IdentityAgent=none` collect pass, so a bastion passphrase is never
  seen and the first reboot fails. `add` detects a resolved
  `proxycommand` whose first word is `ssh` or ends in `/ssh`, says so,
  and recommends rewriting it as `ProxyJump`, which the agent then builds
  correctly; the location is still created.
- **Environment for every `ssh`:** launchd's, with `HOME` so
  `~/.ssh/config` is found, the askpass variables
  ([docs/design/secrets.md](secrets.md)), and `PATH` and `SSH_AUTH_SOCK` replaced by
  a **login shell snapshot**. A launchd agent's `PATH` is
  `/usr/bin:/bin:/usr/sbin:/sbin` and its `SSH_AUTH_SOCK` is the system
  `ssh-agent`'s; a 1Password or Secretive socket exported from `.zshrc`,
  or a `ProxyCommand` that calls `cloudflared`, `tailscale` or `aws` from
  `/opt/homebrew/bin`, works in a terminal and is invisible to launchd.
  The agent therefore runs the user's login shell, taken from `getpwuid`
  rather than `$SHELL`, as
  `<shell> -ilc '/usr/bin/printf "\000"; /usr/bin/printf "%s" "<sentinel>"; /usr/bin/printf "\000"; /usr/bin/env -0; /usr/bin/printf "%s" "<sentinel>"; /usr/bin/printf "\000"'`
  with stdin from `/dev/null`, `TERM=dumb` and a 10 s timeout, and takes
  `PATH` and `SSH_AUTH_SOCK` from the NUL-separated records between the
  two sentinels, at agent start and again on every `add`. `env -0` rather than a `printf` of the two variables because
  the command has to be valid in every shell: in fish `"$PATH"` expands
  to the list joined by spaces, not colons. Each NUL is printed by a `printf` of
  its own rather than embedded in the sentinel's format string: `printf`
  reads `\0` together with the octal digits that follow it as a single
  character, so `printf "\0<sentinel>"` with a sentinel beginning with a
  digit silently loses its first bytes and the marker is never found
  (measured on macOS 26.4, 2026-09-04: `/usr/bin/printf
  "\0123456789abcdef"` writes a newline and `3456789abcdef`). Remote
  scripts print their opening sentinel the same way
  ([docs/design/security.md](security.md)). The sentinel, a random 128-bit value
  chosen per run exactly as for remote scripts, is
  there because rc files write to the same stdout: a "Welcome back" from
  `.zshrc` lands in front of `env`'s first record and glues onto it, and
  when that record happens to be `PATH` the value is lost, which NUL
  separation alone does nothing about. The closing sentinel is there
  because EOF is not a reliable end: an rc file that leaves a background
  child holding stdout (a version-manager update check, a `(… &)` fetch)
  keeps the pipe open after `env` has finished, and a reader that waited
  for EOF would hit the timeout and throw away a complete answer. The
  agent stops reading at the closing sentinel and kills the shell's
  process group, and only a snapshot with no closing sentinel by the
  timeout counts as failed. The command line uses only what every shell
  parses the same way: absolute-path commands, `;`, and quoted arguments
  that contain no variables. stdin from `/dev/null`
  stops an rc file that reads input or `exec`s tmux from hanging until
  the timeout.
  Interactive *and* login, because most people put exports
  in `.zshrc`, not `.zprofile`. csh and tcsh accept `-l` only when it is
  the sole flag, so for those two the snapshot runs the same three
  commands under `<shell> -ic` instead: interactive but not
  login, which reads `.cshrc`/`.tcshrc` and misses a `PATH` set only in
  `.login`; `sshdrive doctor` notes this when the login shell is csh or
  tcsh. If the shell fails or times out, launchd's
  values are used and `sshdrive doctor` says so. `sshdrive show` prints
  the snapshot in use and its age. Only those two variables are taken;
  nothing else from the shell leaks into `ssh`'s environment. Running the
  user's own login shell as the user is not a new capability for anything
  on the Mac.
- Every location has its own master; two locations on one host are two
  connections, which keeps their failures and reconnects independent.
