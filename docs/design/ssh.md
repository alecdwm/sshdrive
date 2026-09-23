# SSH process management

The agent owns every connection: per location it runs one `ssh -N` master and opens every SFTP and
exec channel as a mux client of it, always through `/usr/bin/ssh`. The rule behind most of this
page is that nothing from the user's `~/.ssh/config` may change the shape of our connection or
attach it to someone else's.

## Command lines

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

Every location has its own master. Two locations on one host are two connections, which keeps
their failures and reconnects independent.

## The master

The master is `-N`: authentication, the TCP connection and the mux socket, nothing else. Every
channel is a mux client with its own process, so a wedged SFTP channel (a protocol error, a stuck
server-side `sftp-server`) is killed and reopened on its own, and the master outlives any one of
them.

- **`ControlPersist=no`, always.** With it set, `ssh` forks the master into the background after
  authentication and the spawned process exits, even under `-N`, leaving the agent no pid, no
  stderr and no exit to watch (SQ-041, gotcha 2). With it off the master is the agent's child for
  the life of the connection, and its exit is the location's disconnect signal.
- **The socket marks authentication.** It is created only once authentication has succeeded, so its
  appearance is the signal the authentication deadline ([secrets](secrets.md)) waits for.
- **`-O check`** asks the master process, over the socket, whether it is alive. It says nothing
  about the server or the TCP connection: it is the cheap "is our child sane" check, and the
  per-request deadline ([sftp](sftp.md#request-deadlines)) is the real liveness probe.
  `sshdrive status` does not use it either; its online/offline word comes from the connection
  gate, which knows without touching the wire.
- **`-O exit`** is the clean shutdown.

## The connection is ours alone

A user's config may set `ControlMaster auto` with a `ControlPath` for the host, so a plain
`ssh nas` would attach to a terminal session's socket, or a terminal would attach to ours. We want
our own TCP connection with keepalive and timeouts tuned for a Finder that must not hang.

Command-line `-o` options take precedence over every config file, so the master's values always
win. A second group fixes the shape of the master and of every `ProxyJump` hop, because a host
block written for interactive use breaks both:

| Override | What the config value would do |
|---|---|
| `RemoteCommand=none` | any `ssh` given a command or subsystem exits with "Cannot execute command-line and remote command" |
| `RequestTTY=no` | `RequestTTY force` puts a pty under the stream |
| `StdinNull=no` | closes the channel's stdin |
| `ForkAfterAuthentication=no` | detaches the master exactly as `ControlPersist` would |
| `BatchMode=no` | disables the prompts askpass answers |
| `UpdateHostKeys=no` | `ask` raises a question nobody is there to answer ([secrets](secrets.md)) |
| `PermitLocalCommand=no`, `ForwardAgent=no`, `ForwardX11=no`, `ClearAllForwardings=yes` | run or expose things the mount has no use for |

Mux clients need none of this, because they read no config at all. The `ControlPath` is namespaced
to us, so no other client finds it either. `sshdrive show` prints any control-socket or
session-shape settings the config would have applied, so the user can see they were overridden.

## Mux clients

A mux client whose socket is missing does not fail. `ssh` notes "Control socket does not exist" at
debug level and makes a direct connection of its own: reading the config files, running
`Match exec`, authenticating from scratch. Only the `-O` commands fatal on a missing socket, and
`ControlMaster=no` does not change it (verified against OpenSSH 9.6; SQ-042, gotcha 3). Under the
agent that would be a second, unsupervised connection, or, since mux clients get no secrets token,
an askpass refusal read as an authentication failure.

So every mux client runs with:

- `-F /dev/null` - drops `/etc/ssh/ssh_config` as well as the user's file. This also stops
  `Match exec` scripts running once per channel and keeps the system file's `SendEnv` off our
  sessions.
- `BatchMode=yes` - it can never prompt.
- `ProxyCommand=/usr/bin/false` - a fallback connection dies before a byte is exchanged.

The mux protocol uses nothing from the config: `<host>` is a placeholder, the command or subsystem
travels over the socket, and the master's session already carries every override. A mux client
never speaks to the server, so it sees no banner and no version (SQ-037).

A mux client that exits before its channel opened is always **master lost**, never an
authentication failure. It costs a reconnect, never the location: the agent runs `-O check`; a
failing check drops the master and reconnects through the breaker ([offline](offline.md)), a
passing one retries the channel once.

## Key agents

**Only `agentDependent` locations consult a key agent** (gotcha 5). A location that passed the
collect connection's first pass ([secrets](secrets.md)) authenticates with key files, stored
passphrases and passwords, and its master and hops carry `IdentityAgent=none` exactly as that pass
did. Without it, `ssh` would find the same key in the 1Password or Secretive agent the config names,
sign through it, raise the agent's approval prompt on every unattended reconnect and hit the 60 s
deadline every morning, while the stored passphrase went unused. `sshdrive show` says which kind a
location is.

For an `agentDependent` location the agent **probes the key agent's socket before every spawn**,
because stderr cannot tell the key-agent states apart (SQ-052, gotcha 40):

- A missing socket (the key agent's app has not launched), a dead socket and a locked agent all
  end in the same bare `Permission denied (publickey,password)` at `LogLevel=ERROR`. OpenSSH's own
  `ssh-agent`, locked, answers that it holds no identities rather than refusing.
- 1Password and Secretive print `agent refused operation` between login and their first unlock.
  The classifier keeps that text as corroboration for the present-but-locked case, not as the test.

The socket probed is the one `ssh -G` resolves as `identityagent`, printed with `~` already
expanded. Only when that is unset or reads `SSH_AUTH_SOCK` does the snapshot's variable apply:
1Password and Secretive document their setup as an `IdentityAgent` line in `~/.ssh/config`, so for
most agent-dependent locations `SSH_AUTH_SOCK` still names Apple's `ssh-agent`, which is always
there and would make the check pass while the agent holding the key was absent.

A missing or refusing socket is a transient failure and `ssh` is not run at all. It is retried on
the network backoff ([offline](offline.md)) with the cap raised from 60 s to 5 minutes, since a
locked key agent stays locked for hours. The mount comes up once the key agent is unlocked, with no
user action.

## Exit classification

stderr is kept for `sshdrive status` in every case.

| What happened | Classified as | What follows |
|---|---|---|
| Connection error | `.serverUnreachable` | Reconnect with jittered backoff on the agent's own schedule, not when something next asks ([offline](offline.md) rule 5) |
| Auth or host-key banner, with keys actually offered | `.notAuthenticated` ([secrets](secrets.md)) | **Reconnection stops** until `sshdrive set` changes the location, `sshdrive agent restart`, or `sshdrive debug breaker <name> --connect` |
| 60 s authentication deadline, `agentDependent` location | as auth | Stops; re-armed for one attempt on screen unlock and on the next File Provider request for its domain arriving while the user is at the keyboard ([secrets](secrets.md)) |
| 60 s authentication deadline, first-pass location | transient | Retried through the breaker: no key agent can be holding it up |
| Key-agent socket missing or refusing (pre-spawn probe), or `agent refused operation` | transient | `ssh` not run; network backoff capped at 5 minutes |
| Mux client exited before its channel opened | master lost | `-O check`, then drop and reconnect, or retry the channel once ([Mux clients](#mux-clients)) |

A stale password retried every minute is a `fail2ban` ban within the hour, and a refused prompt is
never going to succeed unattended; that is why auth failures stop. Only an `agentDependent`
location's deadline is an auth stop.

## Channels and `MaxSessions`

- One SFTP channel carries metadata (`stat`, `readdir`, `rename`, small files); a second carries
  bulk downloads and uploads, so a long transfer never blocks a listing.
- Exec channels are opened per command.
- The agent holds at most five per location: two SFTP, the helper stream, a sweep, a probe or
  delete walk. A server's default `MaxSessions` of 10 usually suffices.

The `-N` master carries no session, so the count is exactly the mux clients. Hardened servers set
`MaxSessions` to 1 or 2.

### The probe

The probe asks **"may I hold three at once"** - metadata, bulk and one exec - not "what is
`MaxSessions`", because three is the smallest budget under which the bulk channel is affordable
(gotcha 44). Two channel opens answer it, and the second *is* the bulk channel, so only the third
is thrown away. A refusal reads `mux_client_request_session: session request failed`.

A channel is proved open by completing the SFTP handshake on it: `ssh` spawns successfully whether
or not the session was granted, and only the refusal on stderr or a handshake that never lands
tells the two apart (SQ-022).

A failed open is evidence about `MaxSessions` only if the master is alive (SQ-079, gotcha 106).
`ssh` fails a channel open just as readily because the master has gone (`Control socket connect:
No such file or directory`, `mux_client_hello_exchange: … Broken pipe`, or nothing at all). So:

- a refusal against a master that is still running counts as a refusal;
- a probe that met a dead connection **records nothing** and fails the connect attempt instead, so
  the breaker ([offline](offline.md)) tries again;
- an abrupt loss of a connection that was up marks the cached answer suspect, so the next connect
  probes again. The values stay in the file for an offline `status` to print.

### The cache

The answer is cached in `capabilities.json`, keyed by the location, and re-probed on
`status --probe`. It cannot be keyed on a server banner because the agent never sees one: masters
run at `LogLevel=ERROR` and mux clients speak to the socket (SQ-023). A cached budget that stops
holding is noticed anyway, because opening the bulk channel is what the answer is used for.

The one `ssh` that can read the server's identification string is the collect connection
([secrets](secrets.md)). It alone runs at `LogLevel=DEBUG1`, reads the string once for the
capability report's "server software" line ([cli](cli.md)), and has its `debug1:` lines stripped
before the exit classifier or `add`'s message sees them (SQ-036, gotcha 101).

### Reduced budgets

| `MaxSessions` | What changes |
|---|---|
| 2 | The bulk SFTP channel is dropped and transfers share the metadata channel under the scheduler ([sftp](sftp.md#transfer-scheduling)). The helper gets the one exec channel; the 30-minute insurance sweep stops it, sweeps on the same channel and restarts it, since the sweep covers what the restart would miss (SQ-021). |
| 1 | No exec channel at all. The location is SFTP-only in every respect (`poll`, no `id`, no helper) and the probe records nothing beyond the SFTP extensions. |

`status` shows the limit and the levels it forced.

## The control socket

`ControlPath` is `$TMPDIR/sshdrive-<id8>`, the first eight hex digits of the location id, never
`%C` (gotcha 2):

- `%C` hashes user, host and port, so two locations on one host ([locations](locations.md)) would
  compute the same path. The second master would print "ControlSocket already exists, disabling
  multiplexing" and its mux clients would attach to the first location's connection.
- Unix socket paths are limited to 104 bytes, macOS's `$TMPDIR` is about 50, and `ssh` binds under
  a temporary `<path>.<pid>` name before renaming it (SQ-085). A 40-character `%C` hash does not
  fit, and the group container path is longer still.

`$TMPDIR` is the directory `confstr(_CS_DARWIN_USER_TEMP_DIR)` returns, read directly rather than
from the environment, since a launchd agent's environment is not guaranteed to carry it.

The location's socket path is unlinked before **every** spawn. A master that died without
`-O exit` leaves its socket behind, and `ssh` moves a new socket into place with `link`, which
fails on an existing path and silently disables multiplexing for that connection.

### Orphans are killed, not adopted

If the agent crashes its `ssh -N` children live on, and `ControlMaster=yes` against an existing
socket disables multiplexing. So before its first connection the agent, for every candidate socket
in `$TMPDIR`:

1. `lstat`s it (never `stat`, so a planted symlink decides nothing) and continues only for
   `S_IFSOCK`. `$TMPDIR` is shared and `sshdrive-` is not ours exclusively: the package's own test
   databases leave `sshdrive-nested-*.sqlite-wal`/`-shm` files there (SQ-074, gotcha 79).
2. Reads the owner's pid from `ssh -O check` (`Master running (pid=NNNN)`), the only route from a
   socket to its process.
3. Runs `-O exit` against it.
4. Unlinks whatever is left.
5. Kills the process: checks it is still named `ssh` (a pid read from a socket left from an earlier
   boot may have been reused), then TERM, and KILL half a second later.

The kill matters because `-O exit` reaches a master only *through* its socket. A master whose
socket has gone, or that stopped serving it, would otherwise hold a TCP connection, its mux clients
and its share of `MaxSessions` for ever (SQ-044). A restarted location can also hold a second master
running with no socket at all, visible only by its command line (SQ-043).

`sshdrive agent stop` shuts every location's masters and mux clients down before the agent exits
([cli](cli.md)), so the ordinary case never reaches the sweep.

## Dead connections

Keepalive alone leaves a 30 s window (`15 s × 2`) in which every request stalls, so a dead
connection is detected three ways:

1. **Keepalive** (`ServerAliveInterval=15`, `ServerAliveCountMax=2`).
2. **The per-request deadline** in the SFTP client ([sftp](sftp.md#request-deadlines)): the request
   fails with `.serverUnreachable` and the channel is killed; after a second consecutive timeout,
   the master too.
3. **Sleep.** At the will-sleep message the agent runs `-O exit` on every master and reconnects on
   wake. A connection that slept through a network change is dead more often than not, and dropping
   it first leaves no request in flight on a connection the Mac is about to abandon.

Sleep and wake come from IOKit (`IORegisterForSystemPower`, `kIOMessageSystemWillSleep`,
`kIOMessageSystemHasPoweredOn`), not `NSWorkspace`, since the agent runs no `NSApplication`. The
constants do not import into Swift (MQ-070, gotcha 64).

## The binary is `/usr/bin/ssh`

Always spawned by absolute path, with `argv[0]` set to that same path (gotcha 1). The login shell's
`PATH` is for what `ssh` runs (`ProxyCommand` tools, `Match exec` scripts), never for choosing
`ssh`. A Homebrew OpenSSH earlier in `PATH` is a different program, with different config keywords
and without Apple's `UseKeychain` patch; picking it would make "works in the terminal" and "works
from the agent" two different questions.

The cost, a config keyword Apple's build rejects, is caught at `add` ([locations](locations.md)).
`sshdrive show` prints the binary and its version.

`argv[0]` matters beyond our own spawn: OpenSSH reuses it for any hop it builds, and falls back to
a `PATH` lookup of `ssh` when it is not an executable path.

## `ProxyJump` chains

When `ssh` sees a `ProxyJump` it spawns the hop itself as `<argv[0]> -W '[%h]:%p' … <jump>`, and
that child reads the config files but receives none of the parent's `-o` options. The bastion hop
would then attach to a `ControlMaster auto` socket from the user's terminal, run with
`StrictHostKeyChecking=ask`, use the key agent during the collect step's `IdentityAgent=none` pass
(so a bastion passphrase is never seen and stored), and keep the config's timeouts.

So the agent never passes a `ProxyJump` through (gotcha 4). When `ssh -G` resolves a `proxyjump`,
it supplies its own hop, recursively for a multi-hop chain:

```
-o ProxyCommand='/usr/bin/ssh -W %h:%p <overrides> -l <jump-user> -p <jump-port> <jump-host>' \
-o ProxyJump=none
```

- **`ProxyCommand` first, `ProxyJump=none` after.** Both keywords write the same field and `ssh`
  takes the first; the reverse order discards the `ProxyCommand` outright and the master resolves a
  hostname that only exists behind the bastion (SQ-038, gotcha 33).
- **Nested `%` is doubled once per level.** `ssh` percent-expands the whole `ProxyCommand` string
  before `/bin/sh -c` sees it, including a nested hop's tokens. Hop *n* carries `-W %h:%p`, hop
  *n-1* `-W %%h:%%p`, hop *n-2* `-W %%%%h:%%%%p`, and any other `%` in a nested value is doubled
  with them. Without that, hop 1 dials the destination and the connection ends at hop 2's host-key
  check (SQ-039).
- **User and port are separate flags.** `user@host:port` is our CLI's sugar, which `ssh` does not
  parse: `ssh -G alec@10.0.0.1:2222` resolves the host to the literal `10.0.0.1:2222`.
- **`<overrides>`** are the master's options with `ControlMaster=no` **and `ControlPath=none`** in
  place of the mux settings, plus the `ForwardAgent=no`, `PermitLocalCommand=no`,
  `ClearAllForwardings=yes` and `RequestTTY=no` that `ssh` itself would have added. `no` alone
  still attaches to the config's socket for the bastion; only `ControlPath=none` clears it
  (SQ-040).
- **Every value is single-quoted** by the rule for remote scripts ([security](security.md)),
  because `ssh` runs the string through `/bin/sh -c`: identity paths, verbatim `sshOptions`, the
  jump host.
- **Every hop is a child of the master** with the askpass environment ([secrets](secrets.md)), so
  a bastion password prompt is answered like any other.

A `ProxyJump` in the location's `sshOptions` is consumed the same way: the options go to `ssh -G`,
it appears in the resolved output like one from the config, and it is never handed to `ssh`.
`sshdrive show` prints the chain the agent built.

!!! warning "Hand-written `ProxyCommand ssh …`"
    The agent cannot fix a user's `ProxyCommand ssh -W %h:%p bastion` (the pre-`ProxyJump` idiom).
    That inner `ssh` is found through `PATH`, reads the config unmodified, attaches to any
    `ControlMaster auto` socket for the bastion, and signs through the key agent during the
    `IdentityAgent=none` collect pass, so a bastion passphrase is never seen and the first reboot
    fails. `add` detects a resolved `proxycommand` whose first word is `ssh` or ends in `/ssh`, says
    so, and recommends rewriting it as `ProxyJump`. The location is still created.

## Environment: the login shell snapshot

Every `ssh` gets launchd's environment, with `HOME` so `~/.ssh/config` is found, the askpass
variables ([secrets](secrets.md)), and **only two** values replaced from a login shell snapshot:
`PATH` and `SSH_AUTH_SOCK`. Nothing else from the shell leaks into `ssh`'s environment.

A launchd agent's `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin` and its `SSH_AUTH_SOCK` is the system
`ssh-agent`'s. A 1Password or Secretive socket exported from `.zshrc`, or a `ProxyCommand` calling
`cloudflared`, `tailscale` or `aws` from `/opt/homebrew/bin`, works in a terminal and is invisible
to launchd.

The agent runs the user's login shell, taken from `getpwuid` rather than `$SHELL`, at agent start
and again on every `add`:

```
<shell> -ilc '/usr/bin/printf "\000"; /usr/bin/printf "%s" "<sentinel>"; /usr/bin/printf "\000"; /usr/bin/env -0; /usr/bin/printf "%s" "<sentinel>"; /usr/bin/printf "\000"'
```

with stdin from `/dev/null`, `TERM=dumb` and a 10 s timeout, and takes `PATH` and `SSH_AUTH_SOCK`
from the NUL-separated records between the two sentinels.

| Choice | Reason |
|---|---|
| `-il`, interactive *and* login | Most people put exports in `.zshrc`, not `.zprofile` |
| `env -0`, not a `printf` of the two variables | The command must be valid in every shell; in fish `"$PATH"` expands to the list joined by spaces |
| Each NUL printed by its own `printf` | `printf` reads `\0` and the octal digits after it as one character, so a sentinel beginning with a digit loses its first bytes (SQ-020, gotcha 34). Remote scripts print their sentinel the same way ([security](security.md)) |
| Opening sentinel (random 128-bit, per run) | rc files write to the same stdout; a "Welcome back" glues onto `env`'s first record, and if that is `PATH` the value is lost. NUL separation alone does nothing about it |
| Closing sentinel | EOF is not a reliable end: an rc file that leaves a background child holding stdout (a version-manager update check, a `(… &)` fetch) keeps the pipe open. The agent stops at the closing sentinel and kills the shell's process group; only a snapshot with no closing sentinel by the timeout has failed |
| Absolute paths, `;`, quoted arguments with no variables | The only syntax every shell parses the same way |
| stdin from `/dev/null` | An rc file that reads input or `exec`s tmux would otherwise hang until the timeout |

csh and tcsh accept `-l` only as the sole flag, so for them the snapshot runs the same commands
under `<shell> -ic`: interactive but not login, which reads `.cshrc`/`.tcshrc` and misses a `PATH`
set only in `.login`. `sshdrive doctor` notes this for a csh or tcsh login shell.

If the shell fails or times out, launchd's values are used and `sshdrive doctor` says so.
`sshdrive show` prints the snapshot in use and its age. Running the user's own login shell as the
user is not a new capability for anything on the Mac.
