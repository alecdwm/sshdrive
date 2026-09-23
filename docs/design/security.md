# Security

Secrets stay in the keychain behind the one process entitled to it, and nothing SSH Drive does on
the server can reach a path outside the location's `remotePath` or put a filename in front of a
shell. The two mechanisms that matter most are the `RelativePath` chokepoint and the constant
`sh -s` command line.

## Properties

**Processes and entitlements**

- The extension is sandboxed (required): no network entitlement, no keychain access; it can only
  talk to the agent.
- The agent is not sandboxed. It needs `~/.ssh`, `ssh-agent`, the keychain, the user's login
  shell, and the CloudStorage paths for eviction.
- The CLI and askpass are not sandboxed either but need nothing: both are XPC clients that hold
  no entitlement and read no secret.
- The agent's mach service is reachable by every process of the user. The listener admits only
  peers whose audit token satisfies our Developer ID code requirement
  ([the extension](extension.md)); everything else is rejected before any method runs.
- Every executable has the hardened runtime and is notarized.

**Secrets and host keys**

- Private keys are never copied or read by us. `ssh` uses them where they are.
- Passwords and passphrases live only in the keychain, `kSecAttrAccessible = afterFirstUnlock`,
  read and written only by the agent, the one executable carrying `keychain-access-groups`
  ([components and identifiers](components.md)).
- askpass never sees the keychain. It presents a one-time token the agent minted for that `ssh`
  process, and the agent answers only password and passphrase prompts for the location the token
  belongs to; anything else gets a refusal, never a stored secret ([secrets](secrets.md)).
- The CLI collects answers on the terminal during `add` and passes them straight to the agent.
- The login shell snapshot ([SSH process management](ssh.md)) runs the user's own shell as the
  user, takes `PATH` and `SSH_AUTH_SOCK` from it, and passes nothing else on.
- Host keys are the user's `known_hosts`. The agent never accepts a new or changed key on its own
  ([host keys](secrets.md)).

**Logs**

- Logs never contain file content or credentials.
- Hostnames and paths are logged `.public`. The unified log is readable by other processes of the
  same user, but a `sshdrive logs` that printed `<private>` for every path would be useless to the
  one person it exists for, and the same paths are visible under `~/Library/CloudStorage` anyway.
- Prompt text from `ssh` is logged only after the agent has classified it as not a secret.

**The remote helper**

The helper ([change detection](change-detection.md), tier 2) is on by default; `sshdrive add`
says so when a location is created, and `helper off` disables it per location.

- It is verified before every launch: by SHA-256 against a hash embedded in the app where the
  server has `sha256sum` or `shasum`, and otherwise by size plus its own `--version` output.
  `--version` prints the SHA-256 the helper computes of its *own executable* at startup, so the
  fallback is the same check, not a weaker one (gotcha 85).
- It runs as the SSH user with no elevated rights, from a directory it created with mode 0700 and
  verified it owns.
- It opens no sockets, writes only to that directory, and exits within a minute of the connection
  dropping, with or without sshd's help.

## Path containment

Nothing the agent, helper or CLI does on the server may touch a path outside the location's
`remotePath`. The [symlink policy](symlinks.md) is one piece of that; the rest follows.

The boundary this does not cover: the SSH account's own permissions are the real limit on the
server. SSH Drive stays inside `remotePath` by construction, but a user who points `remotePath`
at `/` gets `/`.

### One chokepoint for every remote path

The SFTP layer has no API that takes a string path. Every operation takes a `RelativePath`, a
value type that can only be built from validated components, and the transport joins it to the
canonical root itself.

- Zero components is the root itself ([pinning the root](pinning.md)).
- A component is rejected if it is empty, `.`, `..`, or contains `/` or NUL.
- Filenames from the system (`createItem`, `modifyItem` renames) and paths from the CLI, the sweep
  output and the helper all pass through that constructor before anything else sees them.

An escape would therefore have to be a bug in one function, not in any of dozens of call sites.
The helper's own deployment is the one exception; see
[Remote command execution](#remote-command-execution).

### The root is canonical and verified

At `add` the root is resolved with SFTP `realpath` and the canonical absolute path is stored. On
every connection the agent calls `realpath` again and refuses to operate if the result differs
(the root was deleted, or replaced by a symlink pointing elsewhere). The domain goes into an error
state that `sshdrive status` explains, rather than quietly serving whatever now sits at that path.

### Never descend through a link

- Enumeration uses `lstat` semantics, links are leaf items, and the index never holds a path with
  a link as an intermediate component.
- Recursive operations walk the server with `readdir`, since the index holds only what Finder has
  opened, and re-`lstat` each directory before descending, so a directory replaced by a symlink
  after it was enumerated is noticed before anything is done inside it.
- **Every listing re-`lstat`s its own directory first**, because SFTP `opendir` follows a symlink
  (SQ-030, gotcha 41): a directory swapped for a link to `/etc` would otherwise be read straight
  through, and every name in `/etc` would get a row. When the answer is no longer `directory`, the
  row is rewritten from that `lstat`, every row beneath it is deleted, and the container answers
  `.noSuchItem`, because as a container it no longer exists. That costs one round trip per
  listing - the trade recursive delete already makes, and cheap beside the `readdir` it guards.

### Server-side tools get the same root

The sweep runs `find` without `-L` (a physical walk). The helper takes `--root` and refuses any
watch or sweep root that does not canonicalise to a path under it. Paths reported back by either
are checked for the root prefix and passed through the `RelativePath` constructor before use;
anything else is logged and dropped.

### Symlink targets are opaque

A link's target string is checked lexically once ([symlinks](symlinks.md)) and otherwise handed
to the Mac verbatim. It is never joined to a remote path or resolved on the server, so `..` inside
a target cannot steer a remote operation.

### The local side

The agent's eviction pass stats materialized files under `~/Library/CloudStorage` with
`AT_SYMLINK_NOFOLLOW`, so a native symlink inside the mount cannot redirect it to a file elsewhere
on the Mac.

## Remote command execution

An exec channel runs its command line through the account's login shell, which may be bash, zsh,
fish or csh, each with its own quoting rules. A directory on a shared NAS named `$(rm -rf ~)`
must never reach that shell.

### The command line is constant

Every exec channel runs exactly `sh -s`. Nothing from the user, the config or the server ever
appears on the command line, so the login shell has nothing to misinterpret.

### The script arrives on stdin

The script is parsed by POSIX `sh`, whose quoting we control. Roots and other values are embedded
single-quoted, with `'` written as `'\''`, and passed through `set --` so the commands see them as
`"$@"`. The probe, the sweep, the helper deployment, the helper itself and every other remote
command are built this way. The same script carries the heartbeat loop that kills its child when
the agent stops writing to it ([change detection](change-detection.md)).

### Output before the sentinel is discarded

rc files print on non-interactive startup in every shell shape (SQ-015), and whatever they write
lands on stdout ahead of the first byte we care about. So every script begins by printing a random
128-bit sentinel the agent chose for that channel, followed by a NUL, and the agent discards
everything up to and including it.

!!! warning "The NUL is printed by a `printf` of its own"
    `printf "\0<sentinel>"` reads the `\0` and the octal digits after it as one character, so a
    sentinel beginning with a digit silently loses its first bytes and is never found (gotcha 34).

| What arrives instead of the sentinel | Report |
|---|---|
| Nothing by the metadata deadline | "shell output unusable"; the location falls to `poll`, and `status` shows the first bytes received so the user can find the rc file |
| SFTP `SSH_FXP_VERSION` framing, or the sentence `This service allows sftp connections only.` (a `ForceCommand internal-sftp` account, SQ-013) | "no shell access (ForceCommand)", never unusable shell output |

The probe ([capability report](cli.md#capability-report)) runs the same check first, so both cases
are diagnosed at `add`.

### The SFTP subsystem behind a noisy rc file

When the server's `Subsystem sftp` names an external `sftp-server` rather than `internal-sftp`,
sshd starts it through the login shell too, and rc output lands in front of the SFTP `VERSION`
reply (SQ-014). `sftp(1)` fails there with "Received message too long"; the [goal](goals.md) is
that whatever `ssh` reaches, `add` reaches.

- The client checks that the first packet is a `VERSION`. When it is not and exec works, it opens
  the SFTP session on an exec channel instead: a `sh -s` script that prints the sentinel and then
  `exec`s the `sftp-server` binary the probe located.
- The probe looks in this order: `/usr/lib/openssh/sftp-server`, `/usr/libexec/sftp-server`,
  `/usr/lib/ssh/sftp-server`, then the path a readable `/etc/ssh/sshd_config` names on its
  `Subsystem sftp` line. `sshd -T` would be authoritative but needs root.
- `status` reports that mode and the first bytes the subsystem produced.
- Without exec the location cannot be added, and `add` says why.

The script is a few lines sent in a single write, and the agent sends no SFTP byte until the
sentinel has arrived. dash reads its stdin in blocks, not a byte at a time: a payload written in
the same pipe write as `printf S; exec cat` is swallowed by dash and reaches `cat` only under bash.
Anything the agent wrote while the shell was still parsing would vanish into that buffer. Once the
sentinel is out, the whole script is already in the buffer and the `exec` follows without another
read.

### Every script is one compound command

The block-buffered read is a hazard for every script the heartbeat wrapper carries, because the
wrapper reads its heartbeat lines off the same stdin the script arrived on. Left as a flat
sequence, a script longer than the shell's read block still has its tail in the pipe when the
reader starts; the reader consumes the rest of the script, and the shell then reads a heartbeat
line as a command. `.` is a POSIX special builtin, so `.` with no argument ends a non-interactive
shell outright (SQ-019).

So every script is a `{ … }` group ending in an `exit` (gotcha 35). A compound command must be
parsed in full before any of it runs, which forces the shell to read the script to its end before
the sentinel is printed, and the `exit` stops it ever reading stdin as script again.

### Background children never share the script's stdin

`find` and the helper start with `< /dev/null`, so the wrapper is the only reader of the heartbeat
lines and a child cannot swallow them and get itself killed for silence. The helper still needs
input - its root set and its pings - and only one process may read a pipe, so the wrapper stays
the reader and relays those lines into a FIFO the helper is given. A server where `mkfifo` fails
runs the helper `< /dev/null` with its roots on its argv (gotcha 84).

### Output is parsed as bytes

Wherever a filename can appear, output is NUL-delimited (`-print0`) or NDJSON from the helper,
and parsed as bytes, never split on newlines.

### Every path coming back is checked

Each is checked for the root prefix and built into a `RelativePath` before use.

The helper's deployment is the one exception (gotcha 88). The binary lives in
`$XDG_CACHE_HOME/sshdrive`, `~/.cache/sshdrive` or `/tmp/sshdrive-<uid>`, outside every location
root by design, so the SFTP layer admits a second kind of path: an absolute directory the *probe*
chose, plus one filename component under it, with no `..` and no nesting. Nothing on the File
Provider path can construct one.
