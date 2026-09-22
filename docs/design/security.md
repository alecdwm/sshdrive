# Security

The properties the design holds:

- Sandbox on the extension (required). It has no network entitlement and
  no keychain access; it can only talk to the agent. The agent is not
  sandboxed: it needs `~/.ssh`, `ssh-agent`, the keychain, the user's login
  shell, and the CloudStorage paths for eviction. The CLI and askpass are
  not sandboxed either but need nothing: both are XPC clients that hold no
  entitlement and read no secret.
- The agent's mach service is reachable by every process of the user. The
  listener admits only peers whose audit token satisfies our Developer ID
  code requirement ([the extension](extension.md)); everything else is
  rejected before any method runs.
- Hardened runtime on all executables; notarized.
- Private keys are never copied or read by us. `ssh` uses them where they
  are.
- Passwords and passphrases only in the keychain, `kSecAttrAccessible =
  afterFirstUnlock`, read and written only by the agent, the one executable
  carrying `keychain-access-groups` ([components and
  identifiers](components.md)). The askpass program never sees
  the keychain: it presents a one-time token the agent minted for that
  `ssh` process, and the agent answers only password and passphrase
  prompts for the location the token belongs to; anything else gets a
  refusal, never a stored secret ([secrets](secrets.md)). The CLI collects
  answers on the terminal during `add` and passes them straight to the
  agent.
- The login shell snapshot ([SSH process management](ssh.md)) runs the
  user's own shell as the user, takes `PATH` and `SSH_AUTH_SOCK` from it,
  and passes nothing else on.
- Host keys are the user's `known_hosts`; the agent never accepts a new or
  changed key on its own ([host keys](secrets.md)).
- Logs never contain file content or credentials. Hostnames and paths are
  logged `.public`: the unified log is readable by other processes of the
  same user, but a `sshdrive logs` that printed `<private>` for every path
  would be useless to the one person it exists for, and the same paths are
  visible under `~/Library/CloudStorage` anyway. Prompt text from `ssh` is
  logged only after the agent has classified it as not a secret.
- Remote access never leaves the location root; see Path containment below.
  Remote commands never interpolate filenames; see Remote command
  execution.
- The remote helper ([change detection](change-detection.md), tier 2) is on
  by default; `sshdrive add` says so when a location is created and
  `helper off` disables it per location. It is verified before every launch,
  by SHA-256 against a hash embedded in the app where the server has
  `sha256sum` or `shasum`, and by size plus its own `--version` output
  otherwise - which prints the SHA-256 the helper computes of its *own
  executable* at startup, so the fallback is the same check rather than a
  weaker one. It runs as the SSH user with no elevated rights from a
  directory it created with mode 0700 and verified it owns, opens no
  sockets, writes only to that directory, and exits within a minute of the
  connection dropping, with or without sshd's help.

## Path containment

Nothing the agent, helper or CLI does on the server may touch a path
outside the location's `remotePath`. The [symlink policy](symlinks.md) is
one piece of that; the rest follows.

**One chokepoint for every remote path.** The SFTP layer has no API that
takes a string path. Every operation takes a `RelativePath`, a value type
that can only be constructed from validated components, and the transport
joins it to the canonical root itself. A path may have zero components,
which is the root itself ([pinning the root](pinning.md)); a component is
rejected if it is empty, `.`, `..`, or contains `/` or NUL. Filenames
arriving from the system (`createItem`, `modifyItem` renames) and paths
arriving from the CLI, the sweep output and the helper all pass through that
constructor before anything else sees them, so an escape would have to be a
bug in one function rather than in any of the dozens of call sites.

**The root is canonical and verified.** At `add` time the root is resolved
with SFTP `realpath` and the canonical absolute path is stored. On every
connection the agent calls `realpath` on it again and refuses to operate
if the result differs (root deleted, or replaced by a symlink pointing
elsewhere); the domain goes into an error state that `sshdrive status`
explains rather than quietly serving whatever now sits at that path.

**Never descend through a link.** Enumeration uses `lstat` semantics, links
are leaf items, and the index never contains a path with a link as an
intermediate component. Recursive operations walk the server with
`readdir`, since the index holds only what Finder has opened, and re-`lstat`
each directory before descending, so a directory replaced by a symlink after
it was enumerated is noticed before anything is done inside it.

**That check belongs to enumeration too, not only to recursive delete.**
SFTP's `opendir` **follows** a symlink: `readdir` on a path that was a
directory yesterday and is a link to `/etc` today returns `/etc`, and
every name in it gets a row. Measured against the testbed on 2026-09-04:
without the check, forcing a listing of a swapped directory put `passwd`,
`shadow` and eighty other names into the index. So every listing
re-`lstat`s its own directory first and refuses to descend when the answer
is no longer `directory`; the row is rewritten from that `lstat`, every row
beneath it is deleted, and the container answers `.noSuchItem`, because as a
container it no longer exists. That is one extra round trip per listing,
which is the same trade the delete already makes and is cheap beside the
`readdir` it guards.

**Server-side tools are told the same root.** The sweep runs `find` without
`-L` (physical walk); the helper takes `--root` and refuses any watch or sweep root
that does not canonicalise to a path under it. Paths reported back by any
of them are validated for the root prefix and passed through the
`RelativePath` constructor before use; anything else is logged and dropped.

**Symlink targets are opaque.** The target string of a link is checked
lexically once ([symlinks](symlinks.md)) and otherwise handed to the Mac
verbatim; it is never joined to a remote path or resolved on the server, so
`..` inside a target cannot steer a remote operation.

**Local side too.** The agent's eviction pass stats materialized files under
`~/Library/CloudStorage` with `AT_SYMLINK_NOFOLLOW`, so a native symlink
inside the mount cannot redirect it to a file elsewhere on the Mac.

What this does not cover, deliberately: the SSH account's own permissions
are the real boundary on the server. SSH Drive stays inside `remotePath` by
construction, but a user who points `remotePath` at `/` gets `/`.

## Remote command execution

An exec channel runs its command line through the account's login shell,
which may be bash, zsh, fish or csh, each with its own quoting rules. A
directory on a shared NAS named `$(rm -rf ~)` must never reach that shell.
So:

- **The command line is constant.** Every exec channel runs exactly
  `sh -s`. Nothing from the user, the config, or the server ever appears on
  the command line, so the login shell has nothing to misinterpret.
- **The script arrives on stdin** and is parsed by POSIX `sh`, whose quoting
  we control. Roots and other values are embedded single-quoted, with `'`
  written as `'\''`, and passed through `set --` so the commands see them as
  `"$@"`. This is the same for the probe, the sweep, the helper
  deployment, the helper itself and every other remote command. The same
  script carries the heartbeat loop that kills its child when the agent
  stops writing to it ([change detection](change-detection.md)).
- **Output that precedes the script's own is discarded.** sshd runs the
  command through the account's login shell, and rc files print things:
  bash sources `.bashrc` when started by sshd, zsh reads `.zshenv` for
  every invocation, fish runs `config.fish` for `fish -c`. Whatever they
  write lands on stdout ahead of the first byte we care about, and
  "parsed as bytes" does not help with a garbage prefix. So every script
  begins by printing a random 128-bit sentinel the agent chose for that
  channel, followed by a NUL, and the agent discards everything up to and
  including it. **The NUL is printed by a `printf` of its own:**
  `printf "\0<sentinel>"` reads the `\0` and the octal digits that follow
  it as one character, so a sentinel beginning with a digit silently loses
  its first bytes and the marker is never found. A channel whose sentinel
  has not arrived by the metadata deadline is reported as "shell output
  unusable", the location falls to `poll`, and `status` shows the first
  bytes received so the user can find the rc file; the probe
  ([capability report](cli.md)) runs the same check first, so the case is
  diagnosed at `add`. One more case wears the same symptom: an account under
  `ForceCommand internal-sftp` opens the exec channel and answers with
  something that is not the sentinel. Which something depends on the server:
  it may be SFTP bytes, and it may be a plain-text refusal, `This service
  allows sftp connections only.`, which is what OpenSSH 9.2 writes when a
  `ForceCommand internal-sftp` account is asked to exec (measured on the
  testbed's `forcesftp` account, 2026-09-04). The probe recognises both -
  the `SSH_FXP_VERSION` framing and that sentence - and reports "no shell
  access (ForceCommand)", not unusable shell output.
- **The SFTP subsystem has no sentinel to hide behind.** When the server's
  `Subsystem sftp` names an external `sftp-server` rather than
  `internal-sftp`, sshd starts it through the login shell too, and the
  same rc output lands in front of the SFTP `VERSION` reply; `sftp(1)`
  fails there with "Received message too long", and so would the
  [goal](goals.md) that whatever `ssh` reaches, `add` reaches. The client
  checks that the first packet is a `VERSION` and, when it is not and exec
  works, opens the SFTP session on an exec channel instead: a `sh -s` script
  that prints the sentinel and then `exec`s the `sftp-server` binary the
  probe located (`/usr/lib/openssh/sftp-server`,
  `/usr/libexec/sftp-server`, `/usr/lib/ssh/sftp-server`, or the path a
  readable `/etc/ssh/sshd_config` names on its `Subsystem sftp` line, in
  that order; `sshd -T` would be authoritative but needs root). `status`
  reports that mode and the first bytes the subsystem produced so the user
  can find the rc file. Without exec the location cannot be added, and `add`
  says why. That script is kept to a few lines, sent in a single write, and
  the agent sends no SFTP byte until the sentinel has arrived: dash reads
  its stdin in blocks rather than a byte at a time (verified: a payload
  written in the same pipe write as `printf S; exec cat` is swallowed by
  dash and reaches `cat` only under bash), so anything the agent wrote
  while the shell was still parsing would vanish into its buffer. Once
  the sentinel is out, the whole script is already in that buffer and
  the `exec` follows without another read.
- **The script is one compound command.** That block-buffered read is a
  hazard for every script the heartbeat wrapper carries, not only
  the `sftp-server` one, because the wrapper reads its heartbeat lines
  off the same stdin the script arrived on: left as a flat sequence of
  commands, a script longer than the shell's read block still has its
  tail in the pipe when the wrapper's reader starts, the reader consumes
  the rest of the script, and the shell then reads a heartbeat line as a
  command - and `.` is a POSIX *special* builtin, so `.` with no argument
  ends a non-interactive shell outright. So every script is wrapped in a
  `{ … }` group ending in an `exit`: a compound command must be parsed in
  full before any of it runs, which forces the shell to read the script
  to its end before the sentinel is printed, and the `exit` stops it ever
  reading stdin as script again.
- **Background children never share the script's stdin.** `find` and the
  helper are started with `< /dev/null`, so the wrapper is the only reader
  of the heartbeat lines and a child cannot swallow them and get itself
  killed for silence. The helper still needs input of its own - its root
  set and its pings - and only one process may read a pipe, so the wrapper
  stays the reader and **relays** those lines into a FIFO the helper is
  given instead; a server where `mkfifo` fails runs it `< /dev/null` with
  its roots on its argv.
- **Output is NUL-delimited** wherever a filename can appear (`-print0`,
  NDJSON from the helper) and parsed as
  bytes, never split on newlines.
- **Every path coming back** is checked for the root prefix and built into a
  `RelativePath` (above) before use. The helper's own deployment is the one
  exception, and it is a narrow one: the binary lives in
  `$XDG_CACHE_HOME/sshdrive`, `~/.cache/sshdrive` or `/tmp/sshdrive-<uid>`,
  which are outside every location root by design, so the SFTP
  layer admits a second kind of path - an absolute directory the *probe*
  chose, plus one filename component under it, with no `..` and no
  nesting. Nothing on the File Provider path can construct one.
