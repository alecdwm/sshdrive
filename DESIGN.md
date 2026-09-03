# SSH Drive — design document

SSH Drive mounts remote SFTP locations into Finder using Apple's File Provider
framework (the same mechanism iCloud Drive, Google Drive, OneDrive and Dropbox
use on modern macOS). It has no GUI; everything is driven by the `sshdrive` CLI.

This document is the plan: what we build, how the pieces fit, the decisions
already made, the questions still open, and the order of work.

Two words are used strictly throughout. **The agent** is SSH Drive's own
background process (§3). A **key agent** is `ssh-agent`, 1Password,
Secretive, or anything else that answers on `SSH_AUTH_SOCK`; the literal
`ssh` message `agent refused operation` refers to one of those.

---

## 1. Goals and non-goals

**Goals**

- SFTP-only remote locations, each shown as its own Finder sidebar entry named
  `SSH Drive - <nickname, else hostname>`.
- Zero GUI. Add / remove / configure / inspect via `sshdrive`.
- Files are placeholders ("dataless") until opened; opening downloads on demand.
- Locally cached content is evicted after a per-location TTL (15m … 1 month)
  measured from the last time the file was read, where the filesystem
  records reads; where S4 finds it does not, from the last fetch or save
  (§7), and `sshdrive show` says which meaning is in force.
- Mounts survive reboots and network loss without user intervention. Offline,
  already-downloaded files stay readable and previously browsed folders stay
  listable. Writes queue and flush when the network returns.
- Auth is whatever the user's `ssh` already does: passwords, keys with or
  without passphrases, keys held by `ssh-agent`, 1Password or Secretive,
  FIDO keys, certificates, `ProxyJump`, or no credential at all (Tailscale
  SSH and similar). If `ssh nas` works in a terminal, `sshdrive add nas`
  works, with one class of exception: anything that needs a human on every
  connection (a touch-required FIDO key, a one-time code) cannot run
  unattended. `add` refuses the ones `ssh` itself reports, with an
  explanation, rather than mounting something that breaks on the first
  reconnect; prompts raised inside a key agent (Secretive, 1Password, a
  FIDO key held by `ssh-agent`) are invisible to `add` and are caught by
  the authentication deadline instead (§4.2). The agent always runs
  `/usr/bin/ssh`, with the `PATH` and `SSH_AUTH_SOCK` of the user's login
  shell rather than launchd's, so key agents and `ProxyCommand` tools set
  up in a shell rc file work too (§6.1). "Works in a terminal" means
  "works in a fresh login shell"; `add` says so when the terminal it is
  run from carries a different `PATH` or `SSH_AUTH_SOCK` than the agent
  will use (§4.2). One more exception is rarer than the human-on-every-
  connection one: a shell rc file that prints on non-interactive startup
  corrupts an external `sftp-server` exactly as it corrupts `sftp(1)`,
  and `add` diagnoses it and works around it where the account has shell
  access (§9.2).
- Remote changes appear in Finder without the user doing anything. How fast
  depends on the server: near-instant where the SSH account has shell access
  and can run our helper, polled otherwise. `sshdrive status` always
  shows which level is active and what would improve it.
- Pinning: any folder or file can be marked "keep offline", from the CLI or
  from a "Keep Downloaded" entry in Finder's context menu. Kept content is
  downloaded eagerly, never TTL-evicted, and new remote files appearing
  inside a kept folder are pulled down automatically.

**Non-goals (v1)**

- Any protocol other than SFTP.
- A menu-bar item, preference pane, windows, or notification UI. Finder
  context-menu entries provided through the File Provider action mechanism are
  allowed: they are menu items handled by the extension, not a UI of our own.
- Multi-user / system-wide installs. One user, one login session.
- A Trash. Deleting in Finder deletes on the server, after Finder's own
  "will be deleted immediately" confirmation (§5.4).
- Recognising renames made on the server as moves when only polling is
  available. They appear as delete + create (§6.4); the helper reports real
  renames.

---

## 2. Platform facts the design depends on

| Fact | Consequence for us |
|---|---|
| A File Provider extension must ship inside an `.app` bundle and is loaded by the system from `Contents/PlugIns/*.appex`. | We need an app bundle even with no windows. The app is an agent app (`LSUIElement = true`): no Dock icon, no menu bar, no windows. |
| The extension runs in its own sandboxed process, launched by the system on demand and killed when idle. It cannot reach `~/.ssh`, `ssh-agent`'s socket, or spawn `ssh`. | The extension does no networking at all. Every SSH connection, every SFTP request and every long-running watch stream lives in the background agent; the extension is an XPC client of the agent (§5.2). |
| Each `NSFileProviderDomain` gets its own Finder sidebar entry (under "Locations") and is mounted under `~/Library/CloudStorage/`. Domains persist across reboots. The exact sidebar label and folder name the system derives from the app name and `displayName` is what spike S3 records. | One domain per location. Whether `displayName` should be `SSH Drive - nas` or just `nas` is decided by S3, so that the sidebar does not read "SSH Drive - SSH Drive - nas". |
| `NSFileProviderReplicatedExtension` (macOS 11+) keeps a system-side copy of the tree, calls us to fetch content, and marks items dataless until fetched. `item(for:)` is called constantly and must be answered from local state. | On-demand download and offline browsing of already-seen folders are provided by the system, not by us. Items are always served from our index (§5.3), never by a network `stat`. |
| The system handles retry/backoff when we throw `NSFileProviderError.serverUnreachable`. Pending local changes are held by the system and re-offered later; `enumeratorForPendingItems()` lists them and the system refuses to evict an item with unsynced changes. | Offline writes "just queue" if we fail fast and correctly. "Pending uploads" in `status` comes from the system, not from a flag of ours. |
| `NSFileProviderManager.evictItem(identifier:)` and `enumeratorForMaterializedItems()` exist for the containing app. Reports show eviction fails for folders and for some files (`.nonEvictable`). | Evict files only, tolerate per-item failures, retry next cycle. |
| Finder gives third-party domains "Download Now" and "Remove Download" for free. Those are one-off actions; the downloaded copy is still evictable. Permanent "keep offline" is not a Finder feature for third-party providers: the extension declares it per item through `contentPolicy` (`.downloadEagerlyAndKeepDownloaded`, macOS 13+). An item whose `capabilities` omit `allowsEvicting` is not offered "Remove Download" at all. | Pinning is ours to implement (§7.1): store pin markers, return the policy for kept items, drop `allowsEvicting` from them so Finder's own menu cannot undo the pin, keep kept subtrees polled, and skip kept items in TTL eviction. |
| An extension can add its own Finder context-menu entries (`NSExtensionFileProviderActions` in the appex Info.plist, handled by `NSFileProviderCustomAction.performAction`). Each entry has a label and an `NSPredicate` activation rule evaluated over the selected items, including their `userInfo`. Finder's own "Remove Download" cannot be intercepted. | Pin/unpin get their own menu entries, shown conditionally on pin state (§7.2). |
| Items declare `capabilities` (`allowsWriting`, `allowsRenaming`, `allowsDeleting`, `allowsTrashing`, `allowsAddingSubItems`, …). Without `allowsTrashing`, Finder deletes immediately after a confirmation dialog. A Finder copy arrives as a plain `createItem` with content; there is no copy callback and no API for reporting remote free space. | No trash (§5.4). Permissions map to capabilities (§5.4). "Server-side copy" and "free space in Finder" are not features we can offer. |
| SFTP has no change notifications and no stable file IDs. The SSH connection that carries it can also run commands on the server when the account has shell access. | Change detection is tiered (§6.4): SFTP polling always works; an exec channel unlocks a remote `find` sweep or our own helper. We keep our own path → identifier index (§5.3). |
| Servers differ in which SFTP extensions they offer (`posix-rename`, `fsync`, `statvfs`, `limits`) and whether exec is allowed. | Every server-dependent feature has a fallback, and `sshdrive status` shows which tier each feature is running at and what would upgrade it (§8.1). |
| SFTP v3 has nine status codes and OpenSSH folds errno onto them through a fixed table: `ENOENT`, `ENOTDIR` and `ELOOP` become `NO_SUCH_FILE`, `EPERM` and `EACCES` become `PERMISSION_DENIED`, and everything else, `ENOSPC`, `EDQUOT`, `EEXIST`, `ENOTEMPTY` and `EXDEV` included, becomes `FAILURE` with the literal message "Failure". | The agent never learns *why* a request failed beyond those classes. A collision is confirmed with an `lstat`, a full disk is inferred from `statvfs@openssh.com`, and no error mapping in this document assumes an errno the wire cannot carry (§6.2). |
| macOS ships OpenSSH (9.x on macOS 14+). `ssh -s host sftp` opens the SFTP subsystem on stdio, `ControlMaster` multiplexes further channels over one connection, and `SSH_ASKPASS_REQUIRE=force` (OpenSSH ≥ 8.4) routes *every* prompt, including host-key confirmations and user-presence notices, to a program of ours with no tty, tagging each with `SSH_ASKPASS_PROMPT` (`confirm` for yes/no questions, `none` for notifications, unset for secrets). | The transport is the system's `/usr/bin/ssh`, spawned by absolute path and never resolved through `PATH` (§6.1). We implement the SFTP wire protocol ourselves (§6.2), which is small and gives us every extension and every request type. Our askpass program handles all three prompt kinds (§4.2). |
| `ssh` builds `ProxyJump` hops itself, as `<argv[0]> -W '[%h]:%p' … <jump>`: the hop reads the config files but receives none of the parent's command-line `-o` options, and when `argv[0]` is not an executable path the hop is found through `PATH`. | The agent never lets `ssh` build the chain. A `proxyjump` from `ssh -G` becomes a `ProxyCommand` of the agent's own with the same overrides on every hop, and every `ssh` is spawned with `argv[0]` set to `/usr/bin/ssh` (§6.1). |
| A mux client asked to open a session (`ssh -S <socket> … <host> <command>`) does not fail when the socket is missing: it logs that at debug level and makes a direct connection of its own, reading the config files as usual. Only the `-O` control commands fail on a missing socket. | Mux clients never read a config file, never prompt and cannot connect on their own: they run with `-F /dev/null`, `BatchMode=yes` and `ProxyCommand=/usr/bin/false`, so a lost master shows up as an immediate, recognisable exit rather than as a second, unsupervised connection (§6.1). |
| A launchd agent does not get the user's shell environment: `PATH` is the system default and `SSH_AUTH_SOCK` is the system `ssh-agent`'s. An `export SSH_AUTH_SOCK=…` for 1Password in `.zshrc`, or a `ProxyCommand` that calls a Homebrew tool, is invisible to it. | The agent takes `PATH` and `SSH_AUTH_SOCK` from a snapshot of the user's login shell (§6.1), and `add` verifies the location through the agent, never from the terminal's own environment (§4.2). |
| `keychain-access-groups` is a restricted entitlement on macOS: it needs a provisioning profile, and only a bundle can embed one. A bare executable in `Contents/MacOS` cannot. | The agent, as the bundle's main executable, is the only process that touches the keychain. The CLI and askpass hold no secrets and no restricted entitlements; they are XPC clients (§3.1, §4.2). |
| App groups, keychain sharing, and File Provider entitlements require a real Team ID; Developer ID + notarization for installs outside the App Store. `SMAppService.agent` registers a login agent from the calling app's own bundle. | Team `RWGDZAYBM8` is already in place. All identifiers derive from it and `org.shirls` (§3.1). Registration is done by the app itself, launched once (§10). |

**Minimum macOS:** 14 Sonoma. Everything the design needs exists on 13
(`SMAppService`, `contentPolicy`, an OpenSSH new enough for
`SSH_ASKPASS_REQUIRE`), but File Provider behaviour changed enough between
13 and 14 that supporting 13 would mean a separate 13 VM in every spike and
release test, for a user base that is now small. Develop and test on 14/15.

---

## 3. Components

```
SSH Drive.app                          (LSUIElement agent app, Developer ID signed, notarized)
├── Contents/MacOS/SSH Drive           host process: the background agent (SSH, SFTP, index,
│                                      change detection, eviction, XPC server)
├── Contents/MacOS/sshdrive            the CLI (symlinked into PATH by the Homebrew cask)
├── Contents/MacOS/sshdrive-askpass    SSH_ASKPASS program: relays ssh's prompts to the agent (§4.2)
├── Contents/PlugIns/SSHDriveFileProvider.appex
│                                      File Provider extension: a thin XPC client of the agent
├── Contents/Resources/helper/sshdrive-helper-<ver>-<os>-<arch>
│                                      static remote helper binaries + sha256 manifest (§6.4 tier 2)
└── Contents/Library/LaunchAgents/org.shirls.sshdrive.agent.plist
                                       registered via SMAppService.agent

Shared Swift package: SSHDriveCore
├── Config        location model, JSON store in the app-group container
├── Secrets       keychain wrapper (shared access group, data-protection keychain)
├── SFTP          SFTP v3 wire-protocol client over a byte stream, plus OpenSSH extensions
├── SSHProcess    spawns and supervises `ssh`, ControlMaster, exec channels
├── Index         SQLite path <-> item identifier index, per domain
├── XPCProtocols  the agent's interfaces for the extension and the CLI
└── Logging       os.Logger subsystems, shared by all processes
```

Why the agent owns everything:

- **Extension** — mandatory, sandboxed, ephemeral. Answers `item(for:)`
  and the working-set change stream from the domain's index, which it
  opens read-only (§5.2), and translates every other system call (list,
  fetch, create, modify, delete) into one XPC call to the agent and the
  reply back. It holds no state of its own, opens no sockets and never
  writes the index. Its only other file I/O is the index it reads and the
  temp file the system gives it for fetched content, whose handle it
  passes to the agent to fill.
- **Agent** — a `SMAppService` login agent whose plist sets `RunAtLoad`
  and `KeepAlive` with `SuccessfulExit` false, so it runs from login
  rather than from the first mach lookup, comes back after a crash, and
  stays down after a deliberate exit until the next lookup (§10): the
  poll schedule, the eviction loop, the kept-subtree refresh and the wake
  handler are timers of its own and would otherwise not run until Finder
  touched a domain. Invisible. Owns the
  `ssh` processes, the SFTP sessions, the per-domain index, the change
  detection streams, the eviction loop, and the File Provider domain
  lifecycle (`add`, `remove`, `signalEnumerator`, `evictItem`). It is the
  only writer of the index and, with one exception, the only process that
  changes domain state through `NSFileProviderManager`: the extension
  calls `disconnect(reason:)` and `reconnect()` on its own domain when
  the agent cannot be reached (§5.2), the one case where the agent is not
  there to do it (its other uses of the manager, the temp directory and
  `signalEnumerator`, change nothing).
- **CLI** — the only user interface. A pure XPC client of the agent: every
  command is a request to the agent, so the CLI never touches the network,
  the keychain or File Provider. It can therefore be invoked through any
  path, including the Homebrew symlink. Even `sshdrive add` does not run
  `ssh`: the agent makes the verification connection in its own
  environment and the CLI only relays prompts to the terminal (§4.2).
- **askpass** — the program `ssh` calls for every prompt. Also a pure XPC
  client: it forwards the prompt to the agent with a one-time token and
  prints whatever the agent answers. It reads nothing itself (§4.2).

Putting SSH in the agent rather than the extension is what makes the auth
goal in §1 true: the agent is not sandboxed, so `ssh` reads `~/.ssh/config`,
talks to `ssh-agent`, runs `ProxyCommand`, and uses FIDO keys exactly as it
does in a terminal. It also puts the long-running watch streams (§6.4) in
the one process that is allowed to be long-running, and gives the index a
single writer. The cost is that the mount depends on the login agent being
enabled (§5.2).

Shared state lives in the app-group container
`~/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive/`:

```
config.json                  schema version, the install's macId (§5.5), locations (no secrets)
domains/<location-id>/
    index.sqlite             path <-> identifier map, versions, last-fetch times, pins, xattrs
                             (written only by the agent; read by the agent and the extension, §5.2)
    capabilities.json        cached server probe (§8.1)
```

Secrets (passwords, key passphrases) go in the keychain under access group
`RWGDZAYBM8.org.shirls.sshdrive`, keyed by the prompt's identity,
`password:<user>@<hostname>:<port>` or `passphrase:<keypath>`, and shared by
every location that names the same one (§4.2); never in `config.json`,
and read and written only by the agent.

### 3.1 Identifiers

| Thing | Value |
|---|---|
| Apple Developer Team ID | `RWGDZAYBM8` |
| App bundle (`SSH Drive.app`) | `org.shirls.sshdrive` |
| File Provider extension (`.appex`) | `org.shirls.sshdrive.fileprovider` |
| Background agent launchd label | `org.shirls.sshdrive.agent` |
| CLI and askpass executables | `sshdrive`, `sshdrive-askpass`, signed as part of the app with the explicit signing identifiers `org.shirls.sshdrive.cli` and `org.shirls.sshdrive.askpass`; a bare tool's default identifier is its product name, which would fail the agent's code requirement (§5.2) |
| App group | `RWGDZAYBM8.org.shirls.sshdrive` (macOS app groups are Team-ID prefixed) |
| Keychain access group | `RWGDZAYBM8.org.shirls.sshdrive` (same string, listed under `keychain-access-groups`) |
| XPC mach service (agent ↔ extension, agent ↔ CLI) | `RWGDZAYBM8.org.shirls.sshdrive.agent` (app-group prefixed so the sandboxed extension may connect) |
| `os.Logger` subsystem | `org.shirls.sshdrive`, categories `extension`, `agent`, `cli`, `sftp`, `ssh` |
| Finder mount root | `~/Library/CloudStorage/<derived by the system, see S3>` |
| Homebrew cask | `ssh-drive`, in the tap `alecdwm/tap` (repo `alecdwm/homebrew-tap`, see §10.1) |
| Source repository | `https://github.com/alecdwm/sshdrive` |
| Domain identifier | the location's UUID (§4) |

Entitlements per target:

- Extension: `com.apple.security.app-sandbox`,
  `com.apple.security.application-groups` (required to connect to the
  group-prefixed mach service),
  `com.apple.developer.fileprovider.testing-mode` (debug builds only). No
  network entitlement: the extension never opens a socket.
- App/agent: hardened runtime, `com.apple.security.application-groups`,
  `keychain-access-groups`. The latter is a restricted entitlement on
  macOS and needs a Developer ID provisioning profile, which only a bundle
  can embed; the app bundle carries one, and the agent, as the bundle's
  main executable, is therefore the only process with keychain access. Not
  sandboxed (§9).
- CLI and askpass: hardened runtime only. They are bare executables in
  `Contents/MacOS`, cannot embed a profile, and need no entitlement: both
  are pure XPC clients of the agent (§4.2).

---

## 4. Location model

```jsonc
{
  "id": "6f1c…",                     // UUID, doubles as the File Provider domain identifier
  "nickname": "homelab",             // optional
  "host": "nas",                     // exactly what the user typed: an ssh_config alias or a hostname
  "user": "alec",                    // optional override, passed as -o User=
  "port": 22,                        // optional override, passed as -o Port=
  "identityFile": "~/.ssh/id_nas",   // optional override, passed as -o IdentityFile= -o IdentitiesOnly=yes
  "sshOptions": ["Ciphers=aes256-gcm@openssh.com"],
                                     // optional extra -o options, verbatim; a ProxyJump here is
                                     // consumed by the agent like one from the config (§6.1)
  "remotePath": "/srv/media",        // optional; default is the SFTP realpath of "." (the user's home)
  "secrets": ["password:alec@nas.tail1234.ts.net:22"],
                                     // which keychain items exist: password:<user>@<hostname>:<port>, passphrase:<keypath>;
                                     // user, hostname and port as resolved by `ssh -G`, never the alias (§4.2);
                                     // an item is shared by every location naming it and deleted with the last one (§8)
  "agentDependent": false,           // set by add when only the key agent could authenticate (§4.2)
  "cacheTTL": "1h",                  // 15m | 1h | 12h | 1d | 1w | 1mo | never
  "permissions": "mode",             // mode | none: whether server mode bits become Finder capabilities (§5.4)
  "watchMode": "auto",               // auto | poll | sweep | helper (§6.4)
  "helper": true,                    // default on: deploy the remote helper where the server supports it (§6.4, tier 2)
  "mounted": true                    // whether a File Provider domain currently exists for it
}
```

Display name = nickname ?? host, prefixed with `"SSH Drive - "` only if S3
shows the system does not add the app name itself.

Notes on the spec:

- The spec lists hostname/IP + port but SSH also needs a username. `ssh`
  resolves it the usual way (`~/.ssh/config`, then the local user); we
  accept `user@host:port` syntax and store the parts as overrides.
- `remotePath` is an addition: without it every mount is the user's home
  directory, which is rarely what people want for a NAS.
- "No password" and "no key" together needs nothing from us: `ssh` offers
  `none` first, and if the server accepts (Tailscale SSH does) we're in.
- Pins are not in `config.json`. They live in the domain's index (§7.1).
- There is no stored host key. `ssh` uses the user's `known_hosts` (§4.3).
- A macOS server exposes `~/Documents`, `~/Desktop` and `~/Downloads` over
  SFTP only when "Allow full disk access for remote users" is enabled in
  its Remote Login settings; otherwise they list as empty or refuse with
  `PERMISSION_DENIED`, which `add` cannot tell from an ordinary
  permission problem. The user docs say so under "macOS as a server".

### 4.1 Reusing `~/.ssh/config`

Nothing to do: the agent runs the system `ssh`, which reads
`~/.ssh/config` on every connection, so `Include`, `Match`, wildcards,
`ProxyJump`, `ProxyCommand`, `IdentityAgent`, `CertificateFile` and
everything else behave exactly as they do for `ssh`. Edits to the config
take effect on the next reconnect, with no snapshot to keep honest. The one
deliberate exception is the fixed set of keywords the agent always
overrides (§6.1): connection sharing and timeouts, so it never shares a
TCP connection with the user's terminal sessions; `UpdateHostKeys`, so an
`ask` in the config cannot raise a question on an unattended connection;
and the session-shape keywords (`RemoteCommand`, `RequestTTY`,
`StdinNull`, `ForkAfterAuthentication`, `BatchMode`,
`PermitLocalCommand`, `ForwardAgent`) that would detach the master or
break a `ProxyJump` hop. One more keyword is overridden for most
locations: `IdentityAgent` is forced to `none` on every runtime
connection of a location that authenticated without a key agent at
`add`, so that a 1Password or Secretive agent named in the config is
never asked to sign for a mount that has its own stored passphrase
(§4.2, §6.1); a location that needed the agent at `add` keeps the
config's value. Mux clients read no config at all (§6.1).

The agent runs `ssh -G <host>` at `add` time and for `sshdrive show`, so
the user can see what the location resolves to ("user: alec, port: 2222,
identity: ~/.ssh/id_nas (from ssh config)"). `ssh -G` prints resolved
values only, with no indication of where each came from, and lists the
default identity files whether or not the config named one; the "from
~/.ssh/config" attribution comes from diffing `ssh -G <host>` against
`ssh -F /dev/null -G <host>`, since a value that differs between the two
came from a config file. `-F` silences `/etc/ssh/ssh_config` as well as
the user's file, so the label reads "from ssh config" and `show` names
both paths rather than crediting `~/.ssh/config` with a value Apple's
system file set. A `proxyjump` in the resolved output is not handed back
to `ssh`: the agent builds the hop chain itself (§6.1). Explicit flags on `add`
become overrides stored in the location and passed as `-o` options, which
take precedence over the config file, as they do for `ssh`. The
environment `ssh` sees is described in §6.1: launchd's, with `PATH` and
`SSH_AUTH_SOCK` replaced by the login shell's. The binary is always
`/usr/bin/ssh` (§6.1), so a config written for a newer Homebrew OpenSSH
may use a keyword Apple's build rejects; `ssh -G` then fails with
`Bad configuration option`, and `add` reports it together with
`/usr/bin/ssh -V`, so the mismatch is found at `add` rather than at the
first reconnect.

### 4.2 Secrets: how `ssh` gets passwords and passphrases

The agent runs `ssh` with no tty. Anything `ssh` would normally ask for on
the terminal is routed to our askpass program:

```
SSH_ASKPASS=<bundle>/Contents/MacOS/sshdrive-askpass      (path taken from the running bundle)
SSH_ASKPASS_REQUIRE=force
SSHDRIVE_ASKPASS_TOKEN=<one-time token minted by the agent for this ssh process>
```

`ssh` invokes the program with the prompt text as its argument, sets
`SSH_ASKPASS_PROMPT` to `confirm` for yes/no questions and `none` for
notifications (unset for secrets), and reads the answer from its stdout.
The program itself knows nothing: it opens an XPC connection to the agent
and sends the token, the prompt text, `SSH_ASKPASS_PROMPT`, and the argv of
its parent `ssh` process (read with `sysctl KERN_PROCARGS2`), then prints
the agent's reply. `ProxyJump` runs the jump hop as a child `ssh -W`
process with the same environment, so the parent argv is how the agent
tells which host is asking.

The token is what authorises the request. The agent mints one for every
master it spawns and for every collect connection; mux clients run with
`BatchMode=yes` and get none. A `ProxyJump` hop is not spawned by the
agent but by the master, through the `ProxyCommand` the agent built
(§6.1), and inherits the master's environment, token included; the
agent never sees a hop start or exit, so hops share the master's token
and are told apart from it by the parent argv the askpass sends. The
agent remembers which location and which purpose the token belongs to,
and retires it when the master exits, which ends every hop too, since a
hop's `-W` pipe closes with it. An askpass invocation with no token, a
retired one, or one whose caller is not a descendant of the `ssh` it was
issued to gets no answer. Environment variables are not a secret, but a
token that only ever exists in one short-lived process tree and is useless
once it exits is enough: another process on the Mac would have to read our
child's environment during the connection, which already requires the
user's privileges over our processes, and with those it could simply run
`ssh` with the user's keys. An askpass that read the keychain itself and
trusted a location id from its environment would be a password oracle for
any local process; this one holds nothing.

The agent classifies the prompt:

| Prompt from `ssh` | Keychain item | Answer |
|---|---|---|
| `Enter passphrase for key '<path>':` | `passphrase:<path>` | the stored passphrase |
| `<user>@<hostname>'s password:` | `password:<user>@<hostname>:<port>`, the port from the `ssh -G` resolution of the asking `ssh` (below) | the stored password |
| a keyboard-interactive password prompt, which `ssh` presents as `(<user>@<host>) Password:` with `<host>` replaced by `HostKeyAlias` when the config sets one | `password:<user>@<hostname>:<port>` for the destination of the asking `ssh`, identified by its argv and resolved with `ssh -G`; nothing is parsed out of the prompt text | the stored password |
| `SSH_ASKPASS_PROMPT=confirm` (the host-key question, §4.3) | none | during `add`: relayed to the terminal; otherwise refused |
| `SSH_ASKPASS_PROMPT=none` (`Confirm user presence for key …`) | none | acknowledged; during `add` this marks the key as touch-required (below) |
| `Enter PIN for … key`, a one-time code, anything else | none | refused |

Keying passwords by `<user>@<hostname>:<port>` rather than by location is
what makes `ProxyJump` work with password auth on both hops: each hop's
prompt names its own host and gets its own item. `<hostname>` is the
resolved `hostname` from `ssh -G`, lowercased as `ssh` itself prints it
in the prompt; the alias the user typed never appears in a key, so `nas`
and `nas.tail1234.ts.net` share one item. The port is in the key because
one hostname routinely fronts several machines on different ports, the
usual NAT layout, and `known_hosts` keys its entries as `[host]:port`
for the same reason; `ssh` puts no port in any prompt, so the agent adds
it from the resolution of the `ssh` that is asking, which the askpass
identifies by that process's argv (a hop carries its `-p` there, §6.1).
A refused PIN, one-time code or
`confirm` makes `ssh` fail; the domain shows `.notAuthenticated`,
reconnection stops (§6.1), and `sshdrive status` prints the prompt text
so the user knows what the server wanted. A passphrase prompt for a key
file that has no stored item is different. `ssh` offers every
`identityfile` in order without decrypting any of them, since the
OpenSSH key format keeps the public half in the clear (verified: an
encrypted key with no `.pub` beside it is still offered with no
passphrase asked), and decrypts a key only once the server has accepted
it. So the prompt arises for a key the location never stored only when
the server accepts that key as well as the one that was stored, which a
personal and a work key on the same account can produce, or for a key
in the old PEM format, which has to be decrypted before it can be
offered at all. Either way the agent answers with an empty passphrase;
`ssh` gives up on that key after its single attempt
(`NumberOfPasswordPrompts=1` bounds passphrase attempts as well) and
moves on to the next, and nothing is stopped. If no key works, the
"Permission denied" that follows is classified on exit like any other. A password prompt with no stored item
is answered the same way, and since `ssh` gets one password attempt the
exit that follows stops reconnection with the prompt text in `status`,
which is the right outcome for a server that has started asking for a
credential the location does not have.

**Collecting secrets** happens once, in `sshdrive add` (and again in
`sshdrive passwd`). The CLI does not run `ssh`. It asks the agent to make
the verification connection, and the agent runs the exact command it will
use later, in its own environment (§6.1), with the token marked *collect*.
For every prompt the agent has no stored answer for, it calls back to the
CLI over the same XPC connection; the CLI shows the prompt on the terminal,
reads the answer (hidden for secrets, visible for the host-key question),
and returns it. The agent hands it to `ssh` and keeps it in memory. When
the connection succeeds, every answer that was actually used is written to
the keychain; a wrong password is never stored, and the CLI never holds a
secret beyond the prompt. Because the test connection is the agent's, not
the terminal's, a location that passes `add` works from the agent: there
is no second environment for it to fail in. `list` and `show` report
which items exist ("password stored for alec@nas", "passphrase stored for
~/.ssh/id_nas"). Passphrases are always stored, even when `ssh-agent` also
holds the key, so the mount works at login before any key agent has been
unlocked. An unencrypted key or a key that lives only in a key agent needs
nothing stored. A stored answer can also be stale: a second location on
a host whose password has since changed finds the shared
`password:<user>@<hostname>:<port>` item (§4), `ssh` uses it for its single
prompt (`NumberOfPasswordPrompts=1`, §6.1) and is refused. `add` then
repeats the collect connection with the stored items for that host
masked, so every prompt reaches the terminal, and on success replaces
the item for every location that names it, saying so exactly as
`passwd` does.

The terminal the user is typing in can still differ from the snapshot: a
tmux session, a forwarded agent socket or a directory-scoped environment
gives it a different `SSH_AUTH_SOCK` or `PATH`, and a key reachable only
through those passes `ssh nas` there and fails from the agent. So `add`
compares the CLI's own two values with the snapshot before connecting
and, when they differ, prints both and says which the agent will use.
"Works in a terminal" means "works in a fresh login shell", and this is
where the user finds that out.

A key agent that already holds the key would defeat that: `ssh` signs through
the agent, never opens the key file, never asks for the passphrase, and
`add` would store nothing, only for the first reboot to find an empty
agent, fall back to the file, and fail on the refused prompt. So the
collect connection is made twice at most. The first attempt runs with
`-o IdentityAgent=none`, so `ssh` can use only key files, passphrases
Apple's `UseKeychain` finds in the login keychain, and passwords, and every
passphrase it needs is seen and stored. When that attempt falls through
to a password prompt, the CLI says so ("your key files did not
authenticate and the server accepts passwords; press Enter to skip this
and try your key agent instead"), because a user whose only key lives in
1Password and whose server also accepts passwords would otherwise type a
password and end up with a location that quietly authenticates by
password. An empty answer is a refusal of that prompt: nothing is stored,
and the attempt fails over. The same Enter-to-skip applies to a
passphrase prompt for a key the user does not mean to use for this
location: `ssh` moves to the next identity, exactly as it will at
runtime (above). If that attempt fails to
authenticate, the second runs with the agent socket, so agent-only keys
(1Password, Secretive, a FIDO key loaded into `ssh-agent`) still work. A
location that passes only the second attempt is recorded as
`agentDependent`; `show` says "authenticates through the key agent only;
the mount waits for it after login", and its reconnects use the transient
retry of §6.1 while the agent is unavailable. `passwd` repeats the same
two steps. Whichever pass succeeded is how the location connects from
then on: a first-pass location runs with `IdentityAgent=none` for good
(§6.1), so no key agent is ever consulted for it and none can prompt.

**Prompts that need a human every time are refused at `add`.** If the
collect connection sees a user-presence notice (a FIDO key that requires a
touch), a PIN prompt, or a keyboard-interactive prompt that is not a
password (a one-time code), the location is not created. `add` explains
which prompt it saw and what works unattended: a key held by a key agent
(1Password, Secretive and `ssh-agent` show their own prompt or none), a
FIDO key generated with `no-touch-required`, or a password. Mounting such a
location would succeed once and then fail into `.notAuthenticated` on the
first unattended reconnect, with nobody watching for the touch; refusing up
front is kinder. `sshdrive unlock` for one-time codes is future work (§14).

The refusal names the key. `ssh` offers identities in the order `ssh -G`
lists them, and the default list includes `~/.ssh/id_ecdsa_sk` and
`~/.ssh/id_ed25519_sk`, so a touch-required FIDO key that happens to sit
in `~/.ssh` and that the server also accepts is used, and asks for its
touch, before the passphrase key or password that would have worked
unattended ever gets its turn (a key the server does not accept is
offered and passed over without a prompt, as above). The user-presence notice carries the key type and
fingerprint (`Confirm user presence for key ED25519-SK SHA256:…`); the
agent matches that fingerprint against `ssh-keygen -lf` of every
`identityfile` in the `ssh -G` output and `add` says which file it was
and how to skip it: "`~/.ssh/id_ed25519_sk` needs a touch on every
connection; run `sshdrive add --identity ~/.ssh/id_nas nas` to
authenticate with a different key". `--identity` stores the override with
`IdentitiesOnly=yes` (§4), so the touch key is never offered again for
that location. Nothing is stored unless the user asks for it: a location
added without `--identity` keeps following `~/.ssh/config`, and a key
added to the config later is picked up on the next connection.

**What `add` cannot see, and the authentication deadline.** A key held by
an agent is signed by the agent, and any prompt for a touch or a
biometric comes from the agent's own UI, never through `ssh`'s askpass:
Secretive keys configured to require Touch ID, 1Password's per-session
authorisation, and a FIDO key loaded into `ssh-agent` all pass the collect
connection while the user is at the keyboard and then wait for a human on
every unattended reconnect. `add` cannot detect these, and `ConnectTimeout`
does not cover the authentication phase. So every connection carries an
**authentication deadline** of the agent's own: if the master's control
socket has not appeared 60 s after `ssh` was started, which `ssh` does
only once authentication has succeeded (§6.1), the agent kills it. The
60 s run from the spawn and contain the 15 s `ConnectTimeout` of the TCP
and banner phase (§6.3), because the agent has no signal for when that
phase ended; a `ProxyCommand` that takes ten seconds to hand over a
connection leaves fifty for authentication. For
an `agentDependent` location that is treated as an authentication
failure for the purpose of the reconnect loop; for any other location
nothing on the Mac can be waiting for a human, since it runs with
`IdentityAgent=none` (§6.1), so the same timeout is a slow or wedged
server and is retried with the network backoff (§6.3) like any other
connection failure. For the agent-dependent case reconnection stops
(§6.1) and `sshdrive status` says
"authentication did not complete within 60 s; a key agent may be waiting
for a touch or approval", with the fix: use a stored passphrase, a
key-agent key that does not prompt, or a password, then `sshdrive test`.

A deadline stop is not final, though, because its commonest cause is a
1Password or Secretive key agent that only wants its approval given while
somebody is at the keyboard: after every sleep the master is dropped
(§6.1), the reconnect blocks on a prompt nobody is there to answer, and
the deadline fires. Leaving it stopped until `sshdrive test` would make
the mount die every morning for exactly the key agents §1 names as supported.
So a location stopped by the deadline is **re-armed for one attempt**
when a human is demonstrably present. A File Provider request on its own
is not that evidence: Spotlight, Quick Look, Finder's background
refreshes and the working-set enumerator issue requests on an unattended
Mac all day, and each would re-arm an attempt, block for 60 s, raise the
key agent's prompt with nobody there, time out, and hand the trigger to
the next request, which is exactly the loop this rule exists to prevent.
Presence is therefore measured directly: the time since the last
keyboard, mouse or trackpad event, from
`CGEventSource.secondsSinceLastEventType` over the combined session
state, which needs no permission, must be under 30 s, and the screen must
be unlocked, read from `CGSSessionScreenIsLocked` in
`CGSessionCopyCurrentDictionary()`. Two things re-arm the attempt: the
`com.apple.screenIsUnlocked` distributed notification, and a File
Provider request for that domain that arrives while the presence test
passes, evaluated at most once a minute so the test itself costs nothing.
The domain is not disconnected for a deadline stop (§5.6), so those
requests keep arriving. An `agentDependent` location also makes no
attempt at all while the screen is locked, on wake included: its first
attempt after a sleep is the one the unlock re-arms, so it never spends
60 s prompting a key agent at a locked screen only to stop. The attempt
runs with the same 60 s deadline; if
it times out again the location is stopped again until the next trigger,
so an unattended Mac never retries and the prompt appears only when the
user is there to see it. Refused prompts (a PIN, a one-time code, a
`confirm` outside `add`) are never re-armed: they cannot succeed attended
or unattended. The first unattended reconnect is therefore what tells the
user, once, and the next time they touch the mount it tries again.

### 4.3 Host keys

`ssh` checks the server against `~/.ssh/known_hosts` as it always does.

- The `add` connection (§4.2) runs with `ssh`'s default
  `StrictHostKeyChecking=ask`. An unknown host produces `ssh`'s own
  fingerprint question, which arrives at askpass with
  `SSH_ASKPASS_PROMPT=confirm`; the agent relays it to the CLI, the user
  answers on the terminal, and `ssh` writes the answer to the user's
  `known_hosts` exactly as it would have from a tty. `--trust-first`
  passes `StrictHostKeyChecking=accept-new` instead and no question is
  asked.
- Every other connection runs with `StrictHostKeyChecking=yes` and
  `UpdateHostKeys=no`, and the agent refuses any `confirm` prompt that
  reaches it. The second override matters because `UpdateHostKeys ask` in
  the user's config passes straight through `ssh -G` and would raise a
  `confirm` on a perfectly healthy server, which the refusal rule would
  then turn into a stopped location. A changed key makes
  `ssh` exit with its "REMOTE HOST IDENTIFICATION HAS CHANGED" banner; the
  agent recognises that on stderr, marks the domain `.notAuthenticated`,
  stops reconnecting (§6.1), and `sshdrive status` shows the fingerprint
  `ssh` reported and the fix: `ssh-keygen -R <host>` followed by
  `sshdrive test <name>`.

We keep no host-key state of our own, so `ssh`, `sftp` and SSH Drive can
never disagree about a server.

---

## 5. The File Provider extension

### 5.1 Responsibilities

Implements `NSFileProviderReplicatedExtension`. One instance per domain; the
system may host several instances in one process, so nothing is global.
Every call that touches the network or changes anything is forwarded to
the agent (§5.2); `item(for:)` and the working-set change stream are
answered from the index by the extension itself:

| System call | What the agent does |
|---|---|
| `enumerator(for: container)` → `enumerateItems` | `opendir/readdir` the mapped path over SFTP, reconcile with the index, return items. Records the folder as recently viewed (§6.5). |
| `enumerator(for: container)` → `enumerateChanges(from:)` | Same, diffed against the index; this is how a folder refreshes when Finder shows it (verify in S3). |
| `enumerator(for: .workingSet)` → `enumerateChanges(from:)` | Read the anchors recorded by change detection (§6.4) from the index, in the extension (§5.2). Never touches the network, and touches the agent only on the schema-mismatch fallback (§5.2) and to say that it has answered `.syncAnchorExpired` and handed out a fresh anchor (§5.3). |
| `item(for: identifier)` | Read the index row, in the extension (§5.2). Never touches the network, and touches the agent only on the schema-mismatch fallback (§5.2). |
| `fetchContents(for:)` / `fetchPartialContents` | Download through the file handle the extension opened on its temp file (§5.2); the extension then returns that URL. Partial fetches serve range requests for large media. The `Progress` the extension returns is fed by byte counts from the agent, and cancelling it cancels the transfer (§5.2). The agent `lstat`s before and after the download; if size or mtime moved in between, the file changed under the transfer and the download is made again, once, after which a still-moving file fails the fetch as `.serverUnreachable` so the system retries later rather than keeping a torn copy. The item returned carries the version the final `lstat` read. |
| `createItem` | `mkdir`, `symlink` (§5.7), or upload-to-temp + non-overwriting `rename` into place (§5.5). |
| `modifyItem` | Depending on `changedFields`: rename/move (non-overwriting `rename`, with every descendant's path rewritten in the index, §5.3), content (upload + `posix-rename`, then a post-upload `lstat` that records the new version, §5.5), attributes (`setstat` mtime; execute bits from `fileSystemFlags`, §5.4), extended attributes (stored locally, §5.4). |
| `deleteItem` | `remove`, or `rmdir` after a server-side depth-first walk when the recursive option is set (§5.5). |
| `materializedItemsDidChange` | Forwarded so the agent can refresh its root set (§6.5) and the pin safety net (§7.2). |
| `performAction` | Pin / unpin (§7.2). |

Every item carries: `contentPolicy` (§7.1.1), `capabilities` and
`fileSystemFlags` (§5.4), `userInfo.kept` (§7.2), `contentVersion` and `metadataVersion` (§5.3), and
`extendedAttributes` from the index.

Every SFTP failure classified as network-related (connect timeout, EOF,
`ENETUNREACH`, DNS, `ssh` exiting with a connection error) becomes
`NSFileProviderError(.serverUnreachable)` so the system queues and retries.
Auth and host-key failures become `.notAuthenticated`; the domain then shows
as needing attention and `sshdrive status` explains why. A name held by a
hidden symlink or by a collision (§5.4, §5.7) becomes `.filenameCollision`.
A write that fails with a bare `FAILURE` is followed by
`statvfs@openssh.com` on its directory where the server offers it; a full
or over-quota filesystem then becomes `.insufficientQuota`, and otherwise
the failure is an ordinary sync error, since the wire carries no errno
(§6.2).

### 5.2 Talking to the agent

The extension connects to the agent's mach service
(`RWGDZAYBM8.org.shirls.sshdrive.agent`) on first use. launchd starts the
agent on demand if it is registered, so the extension does not care whether
the agent was already running.

If the connection cannot be made, which in practice means the user disabled
the login item in System Settings › General › Login Items, the extension
calls `NSFileProviderManager.disconnect(reason:)` on its domain with the
message "SSH Drive's background agent is not running. Enable it in Login
Items or run `sshdrive doctor`." and every call returns
`.serverUnreachable`. It reconnects, and lifts the disconnect, the next time
the XPC connection succeeds. `sshdrive doctor` checks the login item and
prints the same instruction.

Fetched content crosses the boundary without copying, as an open file
descriptor rather than a path: the extension creates the target file in
its own temp directory (`NSFileProviderManager.temporaryDirectoryURL()`),
opens it for writing and sends the `FileHandle`; the agent writes through
it and never needs to resolve, or be allowed to reach, a path inside the
extension's container. Uploads go the other way: the system gives the
extension a URL for the new content, the extension opens it for reading
and sends the handle, and the agent reads it. NSXPC carries file
descriptors natively. This keeps working if a future macOS tightens what
an unsandboxed process may touch under another process's container, and
it means the agent never opens a file the extension did not hand it.
Directory listings travel as XPC values, paged for directories with tens
of thousands of entries.

**The extension reads the index itself.** `item(for:)` is issued in bulk
by the system and must be answered from local state (§2); a round trip to
the agent for each one would put an XPC call on the hottest path in the
extension. So the extension opens `domains/<id>/index.sqlite` read-only,
in WAL mode, from the group container, and answers `item(for:)` and the
working-set change enumerator from it directly, with no agent involved,
which also means they keep working while the agent is restarting. The
agent remains the only writer, and that is what makes this safe: WAL
readers never block the writer and always see a consistent snapshot. A
read-only WAL connection still has to open the `-shm` file for writing,
because readers publish their read marks through it; the group
container is writable by the sandboxed extension, which is what makes a
read-only reader there possible at all. The
extension never opens the database for writing, never touches
`capabilities.json` or `config.json`, and every mutation and every
network operation still goes through the agent.

**A row is a finished item.** Everything an item carries that is derived
rather than observed is computed by the agent when it writes the row and
stored on it: the `capabilities` and `fileSystemFlags` bitmasks from
mode, owner and the probe's identity (§5.4), the effective `kept` state from the markers at and above
the path (§7.1.1), and the Mac-side `link_target` of a symlink after the
relative rewrite (§5.7). `item(for:)` in the extension is therefore a
row read and a field-by-field copy, with no ancestor walk, no access to
`capabilities.json` and no second copy of the rules in §5.4, §5.7 or §7.
The cost is that a change to an ancestor's marker rewrites every known
descendant row, which §7.1 pays once per pin change; the alternative,
an extension that re-implements those rules against a moving index, was
judged worse.

The `meta` table carries three things the reader checks on every call:
the schema version, a `reconciling` flag, and a `generation` counter.
An extension that finds a schema version newer than it understands falls
back to asking the agent for items, which it can always do, so a
mid-upgrade mismatch degrades to the slow path rather than failing.
While `reconciling` is set (§5.3) the extension answers `item(for:)` and
the working-set enumerator with `.serverUnreachable` rather than reading
rows that are still being rebuilt, since a missing row answered with
`.noSuchItem` would delete the user's file. `generation` is bumped by
the agent whenever it has replaced the database's contents wholesale (a
restore, §5.3); the reader re-reads its cached prepared statements and
schema on a change. The database file itself is never replaced under the
reader, so the inode is stable and no re-`stat` is needed. S3 confirms
the reader works from inside the sandbox while the agent writes, that it
sees the flag and the counter promptly, and measures both paths. The
reader is kept only if the measurement earns it: the XPC path is the
fallback anyway, and the reader is what brings `reconciling`,
`generation`, the ready check and the close-and-reopen protocol of §5.3
into the design. If S3 finds the XPC path serves the 50,000 `item(for:)`
calls of that listing within twice the reader's time and under two
seconds in all, with no visible lag in Finder, the reader goes, the
agent becomes the only process that opens the index, and those four
mechanisms go with it.

**Transfers report progress and can be cancelled.** A fetch or upload is
one long XPC call with a reply block. While it runs, the agent sends byte
counts through a callback on the extension's exported object, and the
extension forwards them to the `Progress` it returned to the system.
Cancelling that `Progress` (the user clicking the × in Finder, or the
system abandoning a fetch) sends a cancel for that transfer's id over the
same connection; the agent abandons the SFTP requests in flight and
removes any temp file it had started on the server (§5.5). A transfer
whose extension process disappears mid-way, because the system killed it
as idle, is cancelled the same way when the XPC connection invalidates.

The agent's listener accepts a connection only from a peer that
satisfies a code requirement, set with `setCodeSigningRequirement` on
the connection before it is resumed: signed through Apple's Developer
ID chain for team `RWGDZAYBM8` and carrying one of the four identifiers
in §3.1, listed explicitly, since the requirement language matches
identifiers exactly and has no prefix form. Debug builds are signed with an Apple Development
certificate, so the requirement is generated at build time from the
build's own signing chain, Developer ID in release and Apple Development
for the same team in debug, and a release agent never admits a debug
client. Every process of the user can look the service up;
only ours get past the delegate. The CLI and askpass are signed with
explicit identifiers from that list (§3.1), since a bare tool's
default identifier is its product name and would be refused. This matters because the interface can
remove locations and evict caches, and because the askpass path (§4.2)
hands out secrets.

The XPC interface is versioned. A mismatched agent and extension (mid
upgrade) is reported as `.serverUnreachable` until the agent restarts.

### 5.3 Item identifiers and the index

SFTP gives us paths, not IDs. The File Provider system needs identifiers that
stay stable across renames. The agent keeps a per-domain SQLite index, the
only copy of everything we know about the remote tree:

```
items(identifier TEXT PK, path BLOB UNIQUE, parent TEXT, type, size, mtime,
      -- path is BLOB: server names are bytes and need not be UTF-8 (§5.4)
      mtime_ns INTEGER, inode INTEGER,  -- when the helper or a GNU sweep reports them (§6.4)
      uid INTEGER, gid INTEGER, mode INTEGER,
      generation INTEGER DEFAULT 0,  -- bumped when ns-mtime or inode evidence shows a change SFTP cannot (below)
      content_version TEXT, last_fetch REAL,
      pin_state INTEGER DEFAULT 0,   -- 0 inherit, 1 pinned, -1 excluded (§7.1.1): the marker
      kept INTEGER DEFAULT 0,        -- effective state, derived by the agent from the markers at and above (§5.2, §7.1.1)
      capabilities INTEGER,          -- NSFileProviderItemCapabilities bitmask, derived by the agent (§5.4)
      fs_flags INTEGER,              -- NSFileProviderFileSystemFlags bitmask, derived by the agent (§5.4)
      link_target BLOB,              -- Mac-side symlink target after the relative rewrite (§5.7); null for non-links
      hidden INTEGER DEFAULT 0,      -- 1 symlink omitted (§5.7), 2 name collision (§5.4), 3 local-only (§5.4)
      xattrs BLOB,                   -- Finder tags and other extended attributes, local only (§5.4)
      local_content BLOB)            -- bytes of a local-only item such as .DS_Store (§5.4)
anchors(seq INTEGER PK, changed_identifier TEXT, change_kind TEXT)
roots(path BLOB, reason TEXT, last_seen REAL, PRIMARY KEY (path, reason))
                                   -- change-detection root set (§6.5); one directory may carry
                                   -- several reasons, and leaves the set only when the last one goes
held(path BLOB PK, dir BLOB, first_missing REAL, recheck_at REAL)   -- mass-deletion guard (§6.4)
meta(key TEXT PK, value TEXT)       -- schema version, reconciling flag, generation counter (§5.2)
```

- Identifier = UUID minted the first time we see a path. The root is the
  one exception: it is a permanent row with the empty path and the
  identifier `NSFileProviderItemIdentifier.rootContainer`, created when the
  domain is, so it can carry a pin state and xattrs like any other item.
- Rename/move initiated by the user (via `modifyItem`) updates `path` and keeps
  the identifier. Moving a directory rewrites `path` on every descendant
  row, and on the matching rows of `roots` and `held`, in one transaction;
  pin markers need nothing extra because `pin_state` lives on the same
  rows. That is O(subtree) per directory rename and is the price of
  path-keyed tables; `parent` is kept alongside `path` so the rewrite can
  walk by identifier rather than by string prefix. A rename reported by
  the helper (tier 2) is applied the same way.
- Renames done remotely (outside Finder) appear as delete + create at the
  polling tiers; the helper tier reports real renames and the identifier is
  kept.
- `content_version` = `"\(size)-\(mtime)-\(generation)"` at every tier,
  with mtime in the whole seconds SFTP v3 reports. The size and mtime
  fields must be reproducible from a plain SFTP `lstat`, because that is
  all the conflict check in §5.5 has in hand, and because a location can
  change tier mid-session (§6.4): a version whose format depended on the
  tier would turn every tier change into a modification of every item and
  every save on a helper-tier location into a conflict. So the nanosecond
  mtime and inode that the helper or a GNU `find` sweep report are stored
  in their own columns and used only by change detection: when either
  differs from the stored value while size and second-mtime do not (two
  writes of equal size within one second, a `cp -p` that preserved mtime),
  the agent bumps the row's `generation`, which changes the version and
  makes the system re-fetch. Both columns are nullable, and null means
  "unknown: record whatever comes next without comparing". They are null
  on a fresh row and are **reset to null after every upload of the
  agent's own** (§5.5): a temp-file-plus-rename upload gives the path a
  new inode and a new ns-mtime that SFTP `lstat` cannot read back, so the
  stored values are stale the moment the upload lands, and comparing
  against them would bump the generation on the next helper event or GNU
  sweep and make the system re-fetch the file it just wrote. The conflict
  check (§5.5) compares all three fields, but from two sources: size and
  mtime from the `lstat` it has just made, and generation from the row,
  since the wire cannot carry it. Comparing only the `lstat` fields would
  let a save land on top of exactly the same-size, same-second remote
  change that the generation exists to catch. Metadata version = content
  version plus mode, uid, gid, the derived `capabilities` and `fs_flags`
  (a change of the `permissions` setting or of the probed identity
  recomputes those without touching the mode, §5.4, and the system
  re-reads an item only when its version moves), the effective `kept`
  state (not the
  marker: a child's kept state changes when an ancestor is pinned, and
  the system re-reads an item only when its own version moves, §7.1),
  and a hash of the stored `xattrs` blob, so that accepting a tag change
  (§5.4) always returns a new metadata version and the system never
  re-offers a change it already made (the S10 question).
- A rename reported by the helper (§6.4 tier 2) whose destination path
  already has a row is applied as a *modify* of the destination's
  identifier, and the source row is deleted. Editors save by writing a
  temp file and renaming it over the original; applying that rename
  literally would give the original's path the temp file's identifier and
  lose its Finder tags and cached content. The helper's ignore rules
  suppress events *about* temp names but still report a rename *out of*
  one, so a save through `.file.swp` or `file~` reaches the index as one
  content change to `file`.
- **Deleted rows are deleted.** When an item is reported deleted, whether
  by a Finder `deleteItem`, a listing diff, a delete event from the
  helper, or the mass-deletion guard applying a held deletion (§6.4), its
  row is removed in the same transaction that writes the deletion anchor,
  and its `pin_state` and `xattrs` go with it. There are no tombstones: a
  path that is re-created later is a new item with a new identifier, and
  the system drops the old cache and Finder tags exactly as it does for
  any deleted item. That is the price of the simplest rule, and it is
  paid in two places: a remote rename-and-back at the polling tiers, and
  any Mac app whose atomic save reaches the extension as a `createItem`
  plus `deleteItem` rather than a content modification, which loses an
  explicit pin or tag placed on that one file (S3 records which apps the
  system reports that way). A pin marker on a path that vanishes vanishes
  with it, so `sshdrive pins` never shows a dangling pin; the only pin
  that outlives its item is one on a directory whose deletion the guard
  is currently holding.
- `anchors` is pruned to the newest 30 days and to the newest 1,000,000
  rows, both limits applying. The row cap is deliberately generous: a pin change writes
  an anchor per known descendant (§7.1), so a cap in the tens of
  thousands would let one pin of a large tree push the anchor the
  system last saw out of the table and force the expiry path below on a
  system that was merely a few seconds behind. Anchor rows are a few
  dozen bytes, so a million of them cost less than the index they
  describe. If the system presents an anchor the index no longer knows
  (older than the oldest kept row, or the index was rebuilt), the reader
  answers `.syncAnchorExpired`; pruning and rebuilds are the only two
  sources of that error. That reader is the extension (§5.2), which
  sees nothing of the agent's schedule, so when it then hands out a
  fresh anchor it tells the agent so over XPC, one call per expiry, and
  the sweep below is the agent's response. `enumerateItems` on the working set returns no
  items and the current sequence number as the anchor: the working set
  is only ever a change stream, never a listing. A container enumerator
  hands out the same sequence number and its `enumerateChanges` never
  expires it: a folder refresh is a fresh listing diffed against the
  index (§5.1), whatever anchor the system holds. That makes expiry
  lossy on its own: whatever changed between the pruned anchor and the
  fresh one is in no listing the system will ask for, unless it re-walks
  every container, which S3 records but the design does not rely on. So
  the agent treats handing out a fresh working-set anchor exactly as it
  treats a reconnect (§6.4): it runs one full sweep of the root set at
  once, and every difference from the index becomes an anchor after the
  fresh one, so the system catches up through the ordinary change
  stream whatever else it does. An anchor whose identifier no longer has
  a row is reported as a deletion: only a deletion removes a row, so a
  `modified` anchor followed by a vanished row means the item went
  after the anchor was written, and the deletion anchor that removed it
  is further along the same stream.
- The index is the only copy of the identifiers that we hold, but not
  the only copy that exists: the system's replica holds every identifier
  it has been given, keyed by the file it shows the user. So the index
  runs in WAL mode, the agent takes a `VACUUM INTO
  domains/<id>/index.sqlite.bak` once a day, after a reconcile, and after
  pin changes,
  debounced to at most one per minute so a Finder multi-select that pins
  hundreds of items produces one backup rather than hundreds, and a
  corrupt index is restored from the backup, with the anchors since then
  expired. The restore goes **into the live database, never over it**:
  the agent opens the corrupt file and copies the backup in with the
  online backup API (`sqlite3_backup_init` with the live connection as
  destination) in one write transaction, and bumps `meta.generation`.
  When SQLite cannot open the file at all, the agent first asks the
  extension, through the callback interface it already uses for
  transfer progress (§5.2), to close its reader and answer
  `.serverUnreachable` until told to reopen; then it truncates the
  database and its `-wal` and `-shm` sidecars to zero length under their
  own inodes, restores as above, and asks the extension to reopen.
  The close comes first because the reader has the `-shm` mapped, and
  truncating a mapped file under a live process faults it on its next
  access; the sidecars go because a zero-length database with a
  surviving WAL would have that WAL replayed into it. An extension
  instance that the system launches between the close and the truncate
  is covered by one rule at reader open: before an instance opens the
  index for the first time it asks the agent whether the index is
  ready, one XPC call per instance launch rather than per item, and an
  agent mid-restore answers no, so the instance serves
  `.serverUnreachable` and opens nothing until the reopen callback
  arrives. An agent that cannot be reached at all leaves the instance
  free to open the reader, since a missing agent is the case the direct
  reader exists for. The reader's side of this is one rule: any SQLite
  error, a corrupt page, a not-a-database header during the truncate
  window, a missing table, is answered as `.serverUnreachable`, never as
  `.noSuchItem`, so a rebuild in progress can never look like a
  deletion. Replacing the file at the path was rejected twice
  over: the `-wal` and `-shm` sidecars belong to the old inode and a
  stale WAL would be replayed into the new file on first open, and the
  extension's reader (§5.2), which holds the database open across calls,
  would keep reading the unlinked file. Then, and also when there is no
  backup at all, the index is **reconciled against the replica** before
  anything is re-enumerated, with `meta.reconciling` set for the whole
  walk so the extension's own reads stall too (§5.2): the agent walks
  the mount under
  `~/Library/CloudStorage` with `readdir` and `lstat` only, never opening
  a file since that would materialize it, calls
  `NSFileProviderManager.getIdentifierForUserVisibleFile(at:)` for each
  entry, and for every path without a row creates one with the identifier
  the system already knows, the name and type, and a content version
  rebuilt from the same `lstat`: the replica file's size and mtime are
  the values the system was given for the item, dataless or not, and the
  version format is size, second-mtime and generation, so the row gets
  `"\(size)-\(mtime)-0"`. An item whose generation was never bumped
  therefore comes back with exactly the version the system holds and is
  not re-fetched; only an item whose generation had moved, which the
  walk cannot know, changes version and is fetched again. Leaving every
  version null instead would move every materialized item's version on
  the next listing, make the system re-download the whole cache, and
  turn every pending edit into a conflict. An item the
  system lists in `enumeratorForPendingItems()` is the exception: its
  replica file holds the pending edit, so its size and mtime are the
  edit's, not the server's, and its version is left null and comes back
  through its own `modifyItem`, whose post-upload `lstat` sets it (S5
  records what the system does with a pending edit whose item reports a
  version it cannot match). A path whose backup row carries a different
  identifier from the one the replica returns (the item was deleted and
  re-created after the backup was taken) takes the replica's, since
  that is what the user's file is keyed by, and the row's pin marker and
  xattrs go with the old identifier as they would for any deletion.
  The metadata version does
  move for every row, since mode, owner and the xattr hash are not in
  the replica, and that costs a metadata re-read, not a transfer. Items
  created since the backup therefore keep
  their identifiers and their cache instead of coming back as a delete
  plus a create. What the walk cannot recover is what only the index held:
  pin markers, which `pins.json` beside the index restores (it is written
  on every change as a second, human-readable copy), and local xattrs,
  which come back only from the backup. Only an item the replica has never
  seen is minted fresh. The walk would defeat itself if the agent kept
  serving requests during it: reading a directory the system considers
  stale triggers `enumerateItems` through the extension, and an agent
  with an empty index would mint fresh identifiers for everything in it
  before the walk arrived. So while a reconcile runs, every enumeration
  and fetch for that domain is answered with `.serverUnreachable` by the
  agent, and `item(for:)` and the working-set stream are answered the
  same way by the extension, which sees `meta.reconciling` (§5.2); the
  system serves the walk from the replica (S5 confirms it does), and
  normal service resumes when the flag is cleared, followed by
  `signalEnumerator` for the working set so the system re-asks for what
  it was refused. The flag is what
  makes the stall complete: the agent-side stall alone would leave the
  extension answering `item(for:)` from a half-built index, and a row
  that is not there yet reads as `.noSuchItem`, which deletes the file.
  The flag also outlives a crash: an agent that starts and finds
  `reconciling` set redoes the walk before serving anything, since the
  extension is stalled on that flag and nothing else will clear it.

### 5.4 Names, permissions, attributes

**Case and normalisation.** The server is byte-exact and usually
case-sensitive; the local replica is case-insensitive and
normalisation-insensitive. When two server names in one directory map to
the same local name (`Makefile` and `makefile`; NFC and NFD `é.txt`), the
one already visible in the index keeps its slot, and among newcomers the
byte-wise lowest name is shown; the rest are recorded with `hidden = 2`.
`readdir` order is not stable across polls on hash-ordered directories, so
it cannot be the tie-breaker: the visible name must not flip from one cycle
to the next. Names that are not valid UTF-8 are hidden the same way, which is why
the index stores names as bytes (§5.3). Hidden
names hold their slot: a create or rename to one of them fails with
`.filenameCollision`. `sshdrive status` lists hidden names under "not
shown" with the reason, so the user can rename them server-side. Names are
sent to the server exactly as the system provides them; we never
normalise.

**Permissions become capabilities.** The capability probe (§8.1) runs
`id -u` and `id -G` where exec is available, and every item's `capabilities` are
computed by the agent from its `mode`, `uid`, `gid` and that identity,
and stored on the row (§5.3) so the extension never needs the identity
itself; a change to the `permissions` setting or to the probed identity
recomputes every row. A file loses
`allowsWriting` when the account cannot write it **or cannot write its
directory**, because replacing content goes through a temp file in that
directory (§5.5), so a writable file in a read-only directory is shown
locked rather than failing at save time; a directory the account cannot
write loses `allowsAddingSubItems`; `allowsRenaming` and `allowsDeleting`
follow the parent's write bit, and when the parent carries the sticky
bit (a `1777` drop directory) they additionally require the item or the
parent to be owned by the account, which is what the kernel requires.
Finder then shows a lock and refuses the
edit up front instead of failing the upload later. SFTP-only accounts, where the
identity is unknown, get full capabilities and learn about permission
errors from the sync error list. Owner and mode are shown in Finder's Get
Info as far as the system displays them.

**Execute bits become `fileSystemFlags`.** The mode also decides the
local file's own permission bits, which the system takes from the
item's `fileSystemFlags`: `.userExecutable` is set when the mode has
an execute bit the account can exercise (the owner's bit when the file
is the account's, the group's when the account is in the group,
otherwise the world bit, and any execute bit at all where the identity
is unknown; a directory always carries it, since there it is the search
bit), `.userReadable` is always set, and `.userWritable` follows
`allowsWriting`. Without the first, a script or binary fetched from the
server arrives non-executable, which the upload side (§5.5) would then
faithfully send back as `0644`. The flags are stored on the row like
`capabilities` (§5.3). In the other direction, a `modifyItem` whose
`changedFields` contains `.fileSystemFlags` (a `chmod +x` inside the
mount) sets or clears the execute bits with `setstat` and re-records
the mode; the read and write bits are never changed that way, since
`allowsWriting` already expresses them.

Mode bits are not the whole truth on NAS boxes. Synology, TrueNAS and
Samba-backed shares commonly carry NFSv4 or POSIX ACLs that grant the
account write access to files whose mode reads `0644 root`; mapping by mode
would lock those files in Finder with nothing the user can do about it. So
the mapping is a per-location setting, `permissions`: `mode` (the default,
as above) or `none` (everything writable, errors after upload, as for
SFTP-only accounts). The probe looks for ACL evidence, a `+` in `ls -ld` of
the root, `getfacl` or `nfs4_getfacl` present, or a Synology, TrueNAS or
QNAP release string in `uname -a`, and when it finds any, `sshdrive status`
recommends `sshdrive set <name> permissions none` on the permissions line
(§8.1). It does not switch by itself, since a plain Linux box with `acl`
installed is still mode-governed.

**No trash.** `allowsTrashing` is never set. Finder asks "will be deleted
immediately, are you sure?" and then calls `deleteItem`, which removes the
item on the server. This is honest for a remote filesystem and avoids
inventing a server-side trash that other SFTP clients would not understand.
`allowsTrashing` alone is not enough, because it governs only whether an
*item* may be trashed: the domain is also added with
`supportsSyncingTrash = false` (it defaults to YES), and the extension's
`enumerator(for: .trashContainer)` answers `NSFeatureUnsupportedError` from
`NSCocoaErrorDomain`, which is what the header prescribes for a provider
without a trash - answering `.noSuchItem` instead tells the system its own
trash container was deleted, and it then re-materializes and re-asks about
once a second for ever, hanging anything that `stat`s `.Trash` in the mount.

**Extended attributes stay local.** Finder tags, colours, `FinderInfo` and
any other xattr the system sends in `modifyItem` (`changedFields` contains
`.extendedAttributes`) are stored in the index row and returned on every
item, so tagging works, and nothing is ever sent to the server. They are
lost if the remote item is deleted or the index is rebuilt, which `sshdrive
status` does not need to mention.

**`.DS_Store` is swallowed.** A `createItem` or `modifyItem` for a
`.DS_Store` succeeds locally with an item the agent records as local-only
(`hidden = 3`) but never uploads; a `.DS_Store` on the server is never
enumerated. Local-only items have no remote content, so the
eviction loop (§7) skips them, and their bytes (a few KB for a
`.DS_Store`) are kept in the row's `local_content` column so that a
`fetchContents` for one, after Finder's "Remove Download" or a
system-side eviction, returns what Finder wrote rather than an empty
file that would reset the folder's view settings. They are lost on an
index rebuild, which costs little: Finder recreates them. Finder keeps working, the server stays clean.

**Our own temp files** (`.sshdrive-upload-*`, §5.5) are never enumerated
and are ignored by every change-detection tier.

**Only files, directories and symlinks exist.** Sockets, FIFOs and device
nodes that a `readdir` reports are never enumerated and never get a row,
since File Provider has no item type for them; tier 1's `find` already
drops them with its type test.

### 5.5 Writes, conflicts, atomicity

- **New files:** upload to `<dir>/.sshdrive-upload-<mac8>-<uuid>` (below), opened with the
  Mac file's permission bits in the `open` attributes (`0644` for an
  ordinary file, `0755` when the local file is executable; the server's
  umask still applies), as `sftp put` does, then the plain,
  non-overwriting SFTP `rename` into place. OpenSSH's `process_rename`
  implements that as `link` + `unlink`, so it fails atomically if
  anything now holds the name (a hidden link, a collision, a file
  created meanwhile); on a filesystem without hard links it falls back
  to `stat` + `rename`, which still refuses an existing name, only with
  a race between the two calls. Either way the refusal arrives as a
  bare `FAILURE` status (§6.2), so the agent confirms it with an `lstat`
  of the destination before reporting `.filenameCollision`, and reports
  an ordinary sync error when nothing is there. Servers that are not
  OpenSSH may overwrite on a plain `rename`; the probe tests this once,
  in the location root, and where it overwrites every create and rename
  gets an `lstat` preflight instead, with `status` showing the cost
  (§8.1). `sshdrive set <name> create-check lstat` forces the preflight
  on a server the user does not trust on this point.
- **Existing files:** upload to the temp name, `lstat` the target, then
  `posix-rename@openssh.com` over it so the replacement is atomic, then
  `setstat` the old mode back onto the new file. The `lstat` comes after
  the upload and immediately before the rename, so the conflict window
  (below) is one round trip rather than the length of the upload. Owner and group cannot be
  restored (that needs root) and hard links to the old inode are broken;
  both are documented. Servers without `posix-rename` do `remove` + `rename`,
  a non-atomic window that `status` reports as a degraded capability.
  Creating the temp file needs write permission on the directory, so a
  file the account can write inside a directory it cannot is **not
  saveable through SSH Drive**: the upload fails with `PERMISSION_DENIED`,
  which becomes a sync error, and where the identity is known the capability
  mapping (§5.4) already shows such files locked. Writing in place was
  considered and rejected: it would preserve the inode, owner, ACLs and
  hard links, but leaves a truncated file if the connection drops
  mid-upload and a partial-file window on every save.
- **Case-only renames.** A Finder rename that changes only case
  (`Makefile` to `makefile`) is an ordinary non-overwriting `rename` on a
  case-sensitive server. On a case-insensitive one, a macOS server or a
  Samba-backed share, OpenSSH's `link` fails with `EEXIST`, the
  confirming `lstat` finds a file at the destination, and the rule above
  would report a collision for a legitimate rename. So when the `lstat`
  confirms a destination and the two names differ only by case or by
  Unicode normalisation (APFS is insensitive to both), the agent asks
  SFTP `realpath` for both; if they agree, the names are one
  file and the rename is redone with `posix-rename@openssh.com`, which
  is `rename(2)` and changes case in place. Where the server lacks
  `posix-rename` the rename goes through a temporary third name.
- **After every upload,** create or modify, the agent `setstat`s the mode
  back, sets the mtime to the `contentModificationDate` the system passed
  in, truncated to whole seconds since SFTP v3 carries no more, `lstat`s
  the result, records that size and mtime as the item's
  `content_version`, and resets the row's `inode` and `mtime_ns` to null
  (§5.3), because the rename gave the path a new inode that `lstat`
  cannot report. The item `createItem` / `modifyItem` return carries the
  date the `lstat` read back, which is the truncated date when the
  `setstat` was honoured and the server's own write time when an account
  is not allowed to set times, so the system's copy and the server's
  agree either way. The next
  poll, sweep or helper event for that path then finds a version the
  index already holds, records the fresh inode and ns-mtime, and reports
  nothing, so the agent's own writes never come back as remote changes or
  as conflicts against themselves. That holds only if the differ cannot
  look between the rename landing and that `lstat`: in that window a
  helper event or a concurrent poll sees the path with its new inode
  and a version the index does not hold yet, and would report the agent's
  own write as a remote change and make the system re-fetch the file it
  just wrote. So every path with an upload in flight sits in a
  per-location **in-flight set**: the differ skips dirty paths in it, the
  coalescer holds their events, and both are released after the
  post-upload row is written, at which point the held events find a
  version the index already holds and report nothing. The same set
  serialises two saves of one file in quick succession, so the second
  `modifyItem`'s conflict check runs against the first's result rather
  than racing it.
- **Conflicts:** if the `lstat`'s size or mtime, or the row's
  `generation`, differs from the corresponding field of the `baseVersion`
  the system passed us, the remote changed underneath the user. The
  generation comes from the index rather than the wire (§5.3): a remote
  rewrite of equal size within the same second is visible only through
  the inode or nanosecond evidence that bumped it, and a check that read
  the `lstat` alone would let this save overwrite that change. Policy:
  rename the temp file, which already holds the local
  content, to `<name> (conflicted copy from <Mac name> <date>).<ext>`
  beside it, `<Mac name>` being this Mac's
  `LocalHostName` since it is the Mac's content that is being set aside,
  return the remote item as current, record a working-set anchor for the
  new sibling so Finder shows it at once, and log. This mirrors
  Dropbox/OneDrive behaviour and never loses data. It rests on the system
  treating a `modifyItem` that returns an item with a different version
  as "the server won": re-fetching that content and not re-offering the
  local edit. S3 records that this is what happens; if the system keeps
  re-offering instead, the fallback is to accept the modification (return
  the uploaded version) and make the conflict copy from the *remote*
  content, which keeps the same no-data-loss property with the names
  swapped. The check-then-rename is not atomic; a write landing in that
  one round trip is lost the same way it would be with any two SFTP
  clients.
- **Durability:** `fsync@openssh.com` after each upload when the server
  offers it.
- **Stale temp files:** the temp name is
  `.sshdrive-upload-<mac8>-<uuid>`, `<mac8>` being the first eight hex
  digits of an identifier minted once per install and kept at the top
  level of `config.json`, so every temp file says which Mac made it. A
  temp file carrying this Mac's `<mac8>` that is not in the in-flight set
  is stale by definition (the upload it belonged to died with a
  connection or an agent) and is removed as soon as the agent lists its
  directory, however new it is. A temp file from another Mac is left
  alone until it is 30 days old: another Mac's upload may legitimately
  take longer than a day over a slow link, and its own agent removes it
  the moment it lists the directory again. The ignore patterns everywhere
  else (§5.4, §6.4) match `.sshdrive-upload-*` and need no change.
- **Deletes** of non-empty directories: refuse with `.deletionRejected`
  unless the system passed the recursive option; then walk the directory
  on the server with `readdir`,
  depth first, re-`lstat`ing each directory before descending (§9.1). The
  walk cannot come from the index: folders Finder never opened have no
  rows, and an index-driven `rmdir` would fail with `ENOTEMPTY` on the
  first unexplored subfolder.
- **Deleting something already gone** succeeds: `ENOENT` from `remove` or
  `rmdir` is reported as success and the row is removed, so a user who
  deletes a ghost the mass-deletion guard (§6.4) is still showing gets
  what they asked for rather than an error.

### 5.6 Offline behaviour, end to end

| Situation | What happens |
|---|---|
| Open a file already downloaded, network down | Reads served by the system from local storage. We are not called. |
| Browse a folder listed before, network down | Served from the system's replica; the refresh request gets `.serverUnreachable` and Finder shows the cached listing. |
| Browse a never-listed folder, network down | `.serverUnreachable` at once; Finder shows the folder as unavailable. |
| Save a file, network down | System stores it locally, marks it "waiting to upload", calls `modifyItem` again on retry. The agent fails fast until it can connect, then the flush goes through. |
| Network returns | Agent's `NWPathMonitor` fires → connection attempt → on success `signalErrorResolved(.serverUnreachable)` on every domain, which is the system's cue to retry pending uploads and fetches, then `signalEnumerator` for the working set, and `reconnect()` if `disconnect(reason:)` had been used. S5 confirms `signalErrorResolved` wakes the flush; `signalEnumerator` alone is the fallback. |
| Laptop wakes from sleep | Same path as network returns; the masters were already dropped at the will-sleep message (§6.1). |
| Agent not running | Domain shows a disconnect message (§5.2); everything already cached keeps working. |

We deliberately do not use `disconnect(reason:)` for network outages;
throwing `.serverUnreachable` is enough and keeps the domain writable. The
agent calls `disconnect` with a human message only for refused prompts,
host-key changes, a root that no longer canonicalises to what `add`
recorded (§9.1) and the agent-missing case, where retrying is pointless
until the user acts. A stop caused by the authentication deadline (§4.2)
does not disconnect the domain: requests keep arriving, fail fast with
`.serverUnreachable` while the location is stopped, and the first one
that arrives while the user is present (§4.2) is what re-arms the
attempt, so the domain has to stay connected for that trigger to exist. `sshdrive status` carries the explanation in that case.

### 5.7 Symlinks

File Provider can represent symbolic links directly: an item whose
`contentType` is `.symbolicLink` and whose `symlinkTargetPath` is set becomes
a real symlink in the mounted folder, and Finder draws it with the same arrow
badge it uses for aliases. That is the only representation used. Remote
symlinks are never followed: presenting a link as a copy of whatever it points
at would silently turn `~/all -> /` into a download of the entire server, and
would make edits, pins and change detection act on paths the user never saw.
Finder alias files are not used either: they are ordinary files containing
bookmark data that references a local volume, meaningless on the server.

A remote symlink is shown only if it **stays inside the share**. The check
is lexical, done once per link at enumeration time, and never touches the
server: resolve the target string against the link's own directory
(relative targets) or take it as is (absolute targets), collapse `.` and
`..`, and require the result to remain at or below the location's root.
"The root" here has two spellings, and the check accepts either: the
canonical path `realpath` returned at `add` (§9.1), and the path as the
user typed it, or, for the default root, the `$HOME` the probe (§8.1)
reads where exec is available, which is the spelling links under a home
directory usually carry; the agent stores that beside the canonical one. On a host where `/home` is itself a
symlink (Fedora Silverblue's `/home -> /var/home`, or a NAS that keeps
homes on a linked volume) the canonical root is `/var/home/alec` while
every absolute link the user ever made says `/home/alec/…`; checked
against the canonical spelling alone, all of them would be hidden. Both
spellings are prefix-matched lexically, and the rewrite to a relative
target (below) uses whichever matched. Links that pass are native
symlinks on the Mac, and the rewritten target is stored on the row
(`link_target`, §5.3) so the extension serves it without repeating the
check.
Links that fail are **omitted from enumeration entirely**, logged at debug
level, and otherwise ignored. A link that leaves the share has no meaning
inside a File Provider mount, and a broken link in Finder would only
invite questions.

An absolute target that lands inside the root is as safe as a relative one
and is common on NAS home directories (`media -> /volume1/media` under a
root of `/volume1`), so it is shown, with the target **rewritten as the
relative path** from the link's directory to the resolved location. The
server keeps the absolute string; only the Mac-side symlink carries the
rewritten one. If such a link is later moved from the Mac, the agent
recomputes the relative form for its new directory and bumps its metadata
version, since the same absolute target now needs a different relative
spelling.

| Remote link | On the Mac |
|---|---|
| relative, target resolves lexically inside the root | native symlink, same target string. Resolves inside the mount; dangling if the target does not exist yet, which is fine, it may appear later |
| absolute, target lexically inside the root | native symlink, target rewritten relative to the link's directory |
| relative, target climbs above the root | not listed |
| absolute, target outside the root | not listed |

The check is per link, not per chain: `a -> b` is judged on `b`'s location,
not on where `b` itself points. If `b` is then hidden because it escapes,
`a` shows up on the Mac as a dangling link. Resolving chains would require
following links, which §9.1 forbids; the dangling `a` is the honest result.

**Name collisions with hidden links.** A hidden link still occupies its name
on the server, so a Mac-side create or rename to that name has to be handled
rather than silently replacing the link:

- Hidden links are recorded in the index when their directory is enumerated
  (`hidden = 1`), and the parent of any new item has necessarily been
  enumerated, so a `createItem` or a rename/move first consults the index.
  If the name is held by a hidden link, the operation fails immediately with
  `.filenameCollision`. The system keeps the new item local with an error
  badge and Finder's usual "name already in use" message; `sshdrive status`
  lists it under sync errors as "name taken by a hidden symlink on the
  server", and the user renames it or fixes the link server-side.
- A hidden link that appeared *after* the last enumeration is caught by the
  server instead, through the non-overwriting `rename` that every create and
  move ends with (§5.5). The `modifyItem` content path uses an `lstat`
  before uploading, so a known file that has since turned into a link is
  noticed by the same call.
- The reverse direction needs nothing special. The visible set is "items
  that are not hidden", so a hidden link replaced on the server by a real
  file or directory simply appears as a new item on the next poll, a real
  item replaced by a hidden link appears as a deletion, and a link whose
  target changes across the boundary appears as a deletion or creation.

Rules:

- A symlink is a single small item. Kept state, eviction, polling and the
  index all stop at it; `sshdrive pins` counts links but never descends.
- Enumeration uses `lstat` semantics (SFTP `readdir` reports the link
  itself), so a link to a directory is listed as a link, not a folder.
- **Creating symlinks from the Mac.** `ln -s` inside the mount arrives as a
  `createItem` with `.symbolicLink` and a target. It is accepted only if the
  target passes the same lexical inside-the-share check, in which case the
  agent issues an SFTP `symlink` with the string unchanged. Otherwise it is
  refused with `EINVAL` and a message saying the target must be a relative
  path inside the share, since the resulting link would be hidden the moment
  it was created. An absolute target from the Mac is a Mac path
  (`/Users/…/CloudStorage/…`), meaningless on the server, and is refused
  with the same message even when it points inside the mount. Finder itself cannot create symlinks; it creates alias
  files, which upload as regular files. Converting those into remote
  symlinks is listed in §14.
- Renaming or moving a link moves the link only; the server's target
  string is not rewritten, matching `mv` on the server (the Mac-side
  spelling of an absolute-inside-root target is recomputed as above).
  Before the move, a relative target is re-checked from the *destination*
  directory; an absolute target inside the root stays inside wherever the
  link lives. If it would escape the root
  there, the `modifyItem` is refused with `EINVAL` and the same message as
  for creation, and the system puts the link back where it was. Allowing the
  move and then hiding the result would be a way to plant an escaping link
  on the server through the mount, which creation already forbids. The same
  check applies to copies, since Finder copies a link by creating a new one.

---

## 6. The background agent

### 6.1 SSH process management

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
    -o IdentityAgent=none \                     # omitted only for agentDependent locations (below, §4.2)
    <overrides as -o User= / Port= / IdentityFile=> <sshOptions…> <host>
                                                # the master: no session, only the mux socket;
                                                # the same overrides go on every ProxyJump hop (below)

MUX="-F /dev/null -S $TMPDIR/sshdrive-<id8> -o BatchMode=yes -o ProxyCommand=/usr/bin/false"
                                                # mux clients read no config and cannot connect
                                                # on their own (below); <host> is a placeholder
ssh $MUX -s <host> sftp                        # SFTP channel for metadata
ssh $MUX -s <host> sftp                        # SFTP channel for bulk transfers
ssh $MUX <host> sh -s                          # exec channels: probe, sweep, helper (§9.2)
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
  the per-request deadline (§6.2) is the real liveness probe. `-O exit`
  is the clean shutdown. The socket itself is created only once
  authentication has succeeded, so its appearance is the signal the
  authentication deadline (§4.2) waits for.
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
  there to answer (§4.3), and `LocalCommand`, `ForwardAgent` and the
  forwardings run or expose things the mount has no use for. So the
  master and every hop also carry `RemoteCommand=none`, `RequestTTY=no`,
  `StdinNull=no`, `ForkAfterAuthentication=no`, `BatchMode=no`,
  `UpdateHostKeys=no`, `PermitLocalCommand=no`, `ForwardAgent=no`,
  `ForwardX11=no` and `ClearAllForwardings=yes`. Mux clients need none
  of this, because they read no config at all (next bullet). The
  `ControlPath` under `$TMPDIR/sshdrive-<id8>` is namespaced to us, so no
  other client will find it either, and `sshdrive show` prints any
  control-socket or session-shape settings the config would have
  applied, so the user can see they were overridden.
- **Mux clients read no config and cannot connect on their own.** A mux
  client asked to open a session does not fail when its socket is
  missing: `ssh` notes "Control socket does not exist" at debug level
  and makes a direct connection of its own, reading the config files,
  running `Match exec`, and authenticating from scratch (§2; verified
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
  the breaker (§6.3), and a passing one retries the channel once.
  Dropping the config also stops `Match exec` scripts running once per
  channel and keeps the system file's `SendEnv` off our sessions.
- **Key agents are consulted only by locations that need them.** A
  location that passed the collect connection's first pass (§4.2)
  authenticates with key files, stored passphrases and passwords, and
  its runtime spawns, master and hops alike, carry `IdentityAgent=none`
  exactly as that pass did. Without the override `ssh` would find the
  same key in the 1Password or Secretive agent the config names, sign
  through it, raise the agent's approval prompt on every unattended
  reconnect, and hit the 60 s deadline every morning, while the
  passphrase that was stored precisely so the mount could come up before
  any agent is unlocked went unused. Only an `agentDependent` location
  runs without the override, and it is the only kind subject to the
  socket check below and to the deadline re-arm of §4.2. `sshdrive show`
  says which of the two a location is.
- One SFTP channel is used for metadata (`stat`, `readdir`, `rename`, small
  files) and a second for bulk downloads and uploads, so a long transfer
  never blocks a listing. Exec channels are opened per command. All of them
  are channels on one TCP connection, so a server's `MaxSessions` (default
  10) usually suffices: the agent holds at most five per location (two
  SFTP, the helper stream, a sweep, a probe or delete walk).
  Hardened servers set `MaxSessions` to 1 or 2, and the probe finds the
  limit by opening channels until one is refused
  (`mux_client_request_session: session request failed`), once per
  server banner: the result is cached in `capabilities.json` and
  re-probed only when the banner changes or on `status --probe`, since
  ten channel opens on every wake would be a poor trade for a limit that
  never changes. At 2 the bulk
  SFTP channel is dropped, transfers share the metadata channel under the
  scheduler of §6.2, and the helper gets the one exec channel: the
  30-minute insurance sweep at that tier stops it, sweeps on the same
  channel and restarts it, since the sweep already covers what the
  restart would miss; at 1
  there is no exec channel at all, the location is SFTP-only in every
  respect (`poll`, no `id`, no helper) and the probe records nothing
  beyond the SFTP extensions. `status` shows the limit and the levels it
  forced.
- `ControlPath` is `$TMPDIR/sshdrive-<id8>`, the first eight hex digits
  of the location id, and deliberately not `%C`. `%C` hashes user, host
  and port, so two locations on one host (§13) would compute the same
  socket path: the second master would find it, print "ControlSocket
  already exists, disabling multiplexing", and its mux clients would
  silently attach to the first location's connection. Length is the other
  reason: Unix socket paths are limited to 104 bytes, `$TMPDIR` on macOS
  is about 50, and `ssh` binds the socket under a temporary `<path>.<pid>`
  name before renaming it, so a 40-character `%C` hash does not fit and
  the group container path is longer still. `$TMPDIR` here means the
  directory `confstr(_CS_DARWIN_USER_TEMP_DIR)` returns, read directly
  rather than from the environment, since a launchd agent's environment
  is not guaranteed to carry it.
- **Orphans are not adopted.** If the agent crashes, its `ssh -N` children
  live on with their sockets in place, and `ControlMaster=yes` against an
  existing socket disables multiplexing and leaves later mux clients
  attaching to the orphan. So before its first connection the agent runs
  `-O exit` against every `sshdrive-*` socket in `$TMPDIR` and unlinks
  whatever is left. The location's socket path is also unlinked before
  every spawn, not only at startup: a master that died without `-O exit`
  leaves its socket behind, and `ssh` moves a new socket into place with
  `link`, which fails on an existing path and silently disables
  multiplexing for that connection.
- **Dead connections are detected three ways**, because keepalive alone
  leaves a 30 s window (`15 s × 2`) in which every request stalls: the
  keepalive itself; a per-request deadline in the SFTP client (§6.2), after
  which the request fails with `.serverUnreachable` and the channel is
  killed, and after a second consecutive timeout the master too; and
  sleep, at whose will-sleep message the agent does not wait to find out
  but runs `-O exit` on every master, reconnecting on wake, since a
  connection that slept through a network change is dead more often than
  not and dropping it before the sleep leaves no request in flight on a
  connection the Mac is about to abandon. Sleep and wake come from IOKit
  (`IORegisterForSystemPower`, `kIOMessageSystemWillSleep` and
  `kIOMessageSystemHasPoweredOn`), not from `NSWorkspace`, since the
  agent runs no `NSApplication`.
- `ssh` exiting is classified: connection errors are `.serverUnreachable`
  and the agent reconnects with jittered backoff (§6.3); auth and host-key
  banners are `.notAuthenticated` (§4.3) and **reconnection stops** until
  `sshdrive test`, `sshdrive passwd`, or a change to the location's
  settings. A stale password retried every minute is a `fail2ban` ban
  within the hour, and a refused prompt (§4.2) is never going to succeed
  unattended. An authentication that has not completed by the 60 s
  deadline (§4.2) is classified the same way and stops, for an
  `agentDependent` location; for a first-pass location, which no key
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
  backoff of §6.3, its cap raised from 60 s to 5 minutes for this one
  case, since a locked key agent stays locked for hours and a socket
  probe every minute buys nothing, and the mount comes up once the key
  agent is unlocked without the user running `sshdrive test`.
  Reconnection stops only after `ssh` has been refused with its keys
  actually offered. A location stopped by
  the authentication deadline, as opposed to a refusal, is re-armed for
  one attempt on screen unlock and on the next File Provider request for
  its domain that arrives while the user is at the keyboard (§4.2). stderr is kept for `sshdrive status` in every case.
- **The binary is always `/usr/bin/ssh`**, spawned by absolute path with
  `argv[0]` set to that same path (see `ProxyJump`, below). The
  login shell's `PATH` (below) is for what `ssh` itself runs, `ProxyCommand`
  tools and `Match exec` scripts, never for choosing `ssh`: a Homebrew
  OpenSSH earlier in `PATH` is a different program with a different set
  of config keywords and without Apple's `UseKeychain` patch, and picking
  it silently would make "works in the terminal" and "works from the
  agent" two different questions. The cost, a config keyword Apple's
  build rejects, is caught at `add` (§4.1). `sshdrive show` prints the
  binary and its version.
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
  cancels it with `-o ProxyJump=none` and supplies its own
  `-o ProxyCommand='/usr/bin/ssh -W %h:%p <overrides> -l <jump-user> -p <jump-port> <jump-host>'`,
  recursively for a multi-hop chain. The user and port are separate
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
  `-o ControlMaster=no`; only `ControlPath=none` clears it. Every hop is a child of the master
  with the askpass environment (§4.2), so a bastion password prompt is
  answered like any other, and `sshdrive show` prints the chain it built.
  `argv[0]` is set to `/usr/bin/ssh` on every spawn regardless, because
  OpenSSH reuses `argv[0]` for any hop it does build and falls back to a
  `PATH` lookup of `ssh` when that is not an executable path. A
  `ProxyJump` given in the location's `sshOptions` is consumed the same
  way: the options are passed to `ssh -G`, so it appears in the resolved
  output like one from the config, and it is never handed to `ssh` as an
  option. The `ProxyCommand` string the agent builds is run by `ssh`
  through `/bin/sh -c`, so every value in it, identity paths, verbatim
  `sshOptions`, the jump host, is single-quoted by the rule §9.2 applies
  to remote scripts. What the agent cannot fix is a `ProxyCommand` the
  user wrote by hand that itself invokes `ssh` (`ProxyCommand ssh -W
  %h:%p bastion`, the pre-`ProxyJump` idiom): that inner `ssh` is found
  through `PATH`, reads the config unmodified, attaches to any
  `ControlMaster auto` socket for the bastion, and signs through the key
  agent during the `IdentityAgent=none` collect pass, so a bastion
  passphrase is never seen and the first reboot fails. `add` detects a
  resolved `proxycommand` whose first word is `ssh` or ends in `/ssh`,
  says so, and recommends rewriting it as `ProxyJump`, which the agent
  then builds correctly; the location is still created.
- **Environment for every `ssh`:** launchd's, with `HOME` so
  `~/.ssh/config` is found, the askpass variables (§4.2), and `PATH` and
  `SSH_AUTH_SOCK` replaced by a **login shell snapshot**. A launchd agent's
  `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin` and its `SSH_AUTH_SOCK` is the
  system `ssh-agent`'s; a 1Password or Secretive socket exported from
  `.zshrc`, or a `ProxyCommand` that calls `cloudflared`, `tailscale` or
  `aws` from `/opt/homebrew/bin`, works in a terminal and is invisible to
  launchd. The agent therefore runs the user's login shell, taken from
  `getpwuid` rather than `$SHELL`, as
  `<shell> -ilc '/usr/bin/printf "\0<sentinel>\0"; /usr/bin/env -0; /usr/bin/printf "<sentinel>\0"'`
  with stdin from `/dev/null`, `TERM=dumb` and a 10 s timeout, and takes
  `PATH` and `SSH_AUTH_SOCK` from the NUL-separated records between the
  two sentinels, at agent start and again on every `add`, `test` and
  `passwd`. `env -0` rather than a `printf` of the two variables because
  the command has to be valid in every shell: in fish `"$PATH"` expands
  to the list joined by spaces, not colons. The sentinel, a random
  128-bit value chosen per run exactly as for remote scripts (§9.2), is
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

### 6.2 SFTP client

We implement the SFTP v3 wire protocol in Swift over the `ssh` process's
stdio: a length-prefixed packet framing, the twenty request types, and the
OpenSSH extensions we use (`posix-rename@openssh.com`, `statvfs@openssh.com`,
`fsync@openssh.com`, `limits@openssh.com`, `lsetstat@openssh.com`). It
is a few thousand lines, has no dependencies,
and is tested against OpenSSH's `sftp-server` directly on stdio without any
network.

Requests are pipelined: reads and writes keep up to the server-advertised
`limits@openssh.com` window in flight (or a conservative 32 KB × 16 without
it), which is what gives `sftp(1)`-class throughput. `readdir` pages are
requested back to back. The client exposes a `protocol SFTPTransport` whose
methods take `RelativePath` values only (§9.1).

**Transfers are scheduled, not queued.** Every transfer of a location
runs on the bulk channel, and SFTP requests are independent per handle,
so transfers interleave: the agent runs at most four at once per
location, splits the pipelined window between them, and holds the rest
with their XPC calls open. The four are chosen from two classes.
Foreground transfers come first: a `fetchContents` whose
`NSFileProviderRequest` is a file-viewer request or is not a system
request (an app or the user opening the file; the extension passes the
two flags with the call), every `createItem` and
`modifyItem` upload, and every `fetchPartialContents`. Background
transfers, the eager downloads of a kept subtree (§7.1) and anything
else the system issues on its own, start only while no foreground
transfer is waiting, and a running one is never pre-empted, so a
double-click during a 50 GB pin waits for at most one background
transfer's share of the window rather than for the pin. At a
`MaxSessions` of 2 (§6.1) the same scheduler runs on the metadata
channel and metadata requests are served ahead of both classes. S6
records how many `fetchContents` calls the system keeps open at once
for an eager subtree, which bounds what the agent is holding.

Three details worth writing down before the first bug report. OpenSSH's
`SSH2_FXP_SYMLINK` takes its two path arguments in the opposite order from
the draft that defines it (`targetpath` first, then `linkpath`), and a
client that talks to `sftp-server` has to match OpenSSH, not the draft.
And every request carries a deadline (20 s for metadata, scaled by size
for transfers and extended while bytes keep arriving); a request that
misses it fails as `.serverUnreachable` and reports its channel dead
(§6.1). And the status reply carries no errno. OpenSSH's
`errno_to_portable` folds `ENOENT`, `ENOTDIR` and `ELOOP` into
`NO_SUCH_FILE`, `EPERM` and `EACCES` into `PERMISSION_DENIED`, `EINVAL`
and `ENAMETOOLONG` into `BAD_MESSAGE`, `ENOSYS` into `OP_UNSUPPORTED`,
and everything else, `ENOSPC`, `EDQUOT`, `EEXIST`, `ENOTEMPTY` and
`EXDEV` included, into `FAILURE` with the literal message "Failure". The
client exposes exactly those classes and nothing finer, and every place
this document wants to know more (a collision, a full disk, a directory
that is not empty) asks a second question, an `lstat`, a `statvfs`, a
`readdir`, rather than reading an errno that is not there.

Why this rather than a library:

- OpenSSH is the only implementation that supports every auth mechanism,
  `ProxyJump`, key agents, certificates and FIDO keys, and it is already on every
  Mac. Reusing it is what makes §1's auth goal a one-liner.
- The libraries on offer each fall short somewhere: `swift-nio-ssh` has no
  SFTP; Citadel does not document encrypted OpenSSH keys and has RSA in a
  fork; libssh2 chooses `posix-rename` for you whenever the server has it,
  which breaks the non-overwriting rename §5.5 relies on, has no
  `limits@openssh.com`, needs its own crypto backend built into an
  XCFramework for notarization, and its SFTP throughput is well below
  OpenSSH's.
- The protocol itself is small. The client is the easiest part of this
  project to test exhaustively.

### 6.3 Fail fast when offline

Waiting for a TCP timeout freezes Finder, so every remote call is gated:

1. `NWPathMonitor` says no path at all → `.serverUnreachable` immediately.
   This covers Wi-Fi off, but not a powered-down NAS or a tailnet that is
   down while the Mac is online.
2. A per-location **circuit breaker** covers the rest: after a failed
   connection attempt the location is marked down for a backoff interval
   (2 s, doubling to 60 s), during which every call fails fast without
   touching the network. A path change, wake from sleep, or `sshdrive test`
   resets the breaker. **While an attempt is in progress, calls wait for
   it**, bounded by the attempt's own remaining deadline: at most the 60 s
   authentication deadline (§4.2), measured from the spawn of `ssh`, which
   already contains the 15 s `ConnectTimeout` of the TCP and banner phase
   (never the two added together). When the attempt
   succeeds the waiting calls run; when it fails they all get
   `.serverUnreachable` at once and the breaker opens. Failing them fast
   instead was considered and rejected: the first enumeration after login
   or wake would arrive during the connect, fail immediately, and Finder
   would show the folder as unavailable until the user clicked again,
   since the system does not retry an enumeration on its own. A spinner
   for the length of one connect is the better of the two.
3. `ConnectTimeout=15` bounds the TCP and banner phase of the one attempt
   that does go out. 15 rather than 5 because `ProxyCommand` tunnels such
   as `cloudflared access ssh` routinely take longer than 5 s to hand over
   a connection. The 60 s authentication deadline (§4.2) runs from the same
   spawn and bounds the whole attempt.
4. A connection that died silently is found by the per-request deadline
   (§6.2) and, after sleep, by dropping the master outright (§6.1), so the
   breaker opens within seconds rather than after the keepalive window.
5. Auth and host-key failures do not go through the breaker at all: they
   stop reconnection until the user acts (§6.1), or, for a deadline stop,
   until screen unlock, or a request arriving with the user present,
   re-arms one attempt (§4.2).

### 6.4 Remote change detection

SFTP cannot push changes, but the SSH connection can run commands on the
server when the account has shell (exec) access. Change detection therefore
has three tiers. All tiers produce the same thing: a set of "dirty" remote
paths that the agent re-`stat`s over SFTP (re-`readdir`s, for a
directory, since a deletion is only visible as an absence in its parent's
listing), diffs against the index, and turns into working-set anchors,
followed by `signalEnumerator(for: .workingSet)`. Nothing on the File
Provider side knows which tier is active, and the version format (§5.3)
is the same at every tier so that a tier change is invisible too.

| Tier | Mode | Needs on the server | Latency | Cost per cycle |
|---|---|---|---|---|
| 0 | `poll` | SFTP only | poll interval | one `readdir` per root, over the network |
| 1 | `sweep` | exec + `find` (GNU, BSD or busybox) | poll interval | one command; server walks the tree locally |
| 2 | `helper` | exec + a writable, executable directory + a supported OS/arch | ~1 s | idle stream; server-side batching and filtering |

**Scope** is the root set of §6.5. When it changes, the helper (tier 2)
is sent the new set on its stdin and applies it live; the polling tiers
read it at the start of every cycle.

**Selection.** `watchMode: auto` (the default) tries the tiers from the top:
helper first, then sweep, then poll, settling on the first one
that starts successfully. The helper is enabled by default and is skipped only
when the server cannot run it (no exec, no writable directory, directory
mounted `noexec`, unsupported OS/arch, upload or hash check failed) or the
user has set `helper off` for the location. A tier that fails at runtime
(the helper's stream dies with a non-network error, `find` is missing)
drops the location one tier down for the
rest of the session and records why, which `sshdrive status` shows. Setting
`watchMode` to a specific tier disables the fallback ladder except to `poll`,
which always works. On reconnect after any outage every tier first runs one
full sweep (tier 1, or tier 0 if exec is unavailable) so changes made while
disconnected are caught, then resumes streaming. A "full sweep" is the
tier 1 sweep with its window opened back to the last server timestamp
the index recorded, unbounded when there is none (a fresh or rebuilt
index), or at tier 0 a `readdir` of every root with the rotation of
§6.5 suspended for that one cycle; the same sweep serves a fresh
working-set anchor (§5.3).

**Schedule for tiers 0 and 1.** Every 60 s while the user has touched the
domain in the last 10 minutes (a File Provider request for it that was
not a system request, or a CLI command naming it), every 10 min
otherwise, and immediately on network-up. The helper replaces the schedule with events; a sweep still
runs every 30 min as insurance against missed events.

#### Tier 0: SFTP poll

`readdir` every root, compare name/size/mtime against the index. This is the
only tier available to SFTP-only accounts (chrooted `internal-sftp`), and the
final fallback for everyone else.

#### Tier 1: remote sweep

One `sh -s` exec channel per cycle, fed a script on stdin (§9.2) that runs:

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
`-newerct` because GNU, BSD and current busybox all accept it and only GNU
takes an epoch timestamp; busybox builds older than 1.34, which some
Synology DSM releases ship, lack `-cmin`, so the probe checks for it and
the sweep falls back to `-mmin`, losing the `chmod`/`chown`/preserved-mtime
cases, which `status` reports as a note. `N` is computed from the
**server's** clock, never the Mac's: every sweep script prints `date +%s`
first, the agent stores it once the sweep's results have been applied
to the index, never before, and the next sweep's `N` is the minutes
between the stored value and the new one, rounded up, plus one minute of
overlap. Measured on the Mac's clock, a server running a few minutes
behind would silently miss every change until the 30-minute insurance
sweep. Duplicates are harmless because the result is diffed anyway.
Excluded subtrees are pruned with `-path <path> -prune`, and `-path`
takes a glob, so `*`, `?`, `[` and `\` in an excluded path are
backslash-escaped before the pattern is embedded: `-path 't/[x]'` does
not match a directory named `[x]` (verified on GNU `find`), and an
exclusion that silently stopped applying would put an excluded subtree
back under the recursive watch. Both files and directories are matched: a directory's ctime
changes on create, delete and rename inside it, but an in-place edit
changes only the file's own, so the file test is needed too. There is no `-xdev`: a NAS root routinely contains separate
mounts (ZFS datasets, bind mounts), and containment comes from not following
links (§9.1), not from staying on one filesystem. On GNU `find` the sweep
replaces `-print0` with `-printf '%p\0%y\0%s\0%T@\0%i\0%m\0%U\0%G\0'`,
so every hit arrives with its type, size, nanosecond mtime, inode, mode
and owner and needs no follow-up `stat` (§5.3); elsewhere the returned
paths are `stat`ed over SFTP, one round trip each.

#### Lifetime of anything we start on the server

A server-side process is only killed by sshd when sshd notices the
session is gone, and with `ClientAliveInterval` unset (the default) a
connection that died under a sleeping laptop is noticed only when TCP
gives up, hours later. Every reconnect would then add another helper
holding another full set of watches, until `max_user_watches` is
exhausted. So nothing is ever started bare: the stdin script (§9.2)
starts the command in the background with its stdin redirected from
`/dev/null`, so the child cannot consume the heartbeat lines, and then
loops reading stdin, and the agent writes a heartbeat line every 15 s.
When no line has arrived for 60 s, or stdin hits EOF, the script kills
its child and exits. `read -t` is used where `sh` supports it (bash,
zsh, ksh, busybox) and a `sleep`-and-mtime watchdog where it does not
(dash); the probe records which. The same wrapper runs the sweep and the
helper, so nothing we start on a server outlives our connection by more
than a minute. The helper also stops on its own when its pings stop
(below), so for it the wrapper is a second line of defence rather than
the only one.

#### Tier 2: remote helper (default where supported)

A single static binary, `sshdrive-helper`, built from this repo in Rust for
`linux/x86_64`, `linux/aarch64`, `linux/armv7` (the older Synology and
QNAP boxes), `darwin/arm64` and `freebsd/x86_64`, embedded
in `SSH Drive.app`. A platform outside that list is the one case where
a server with shell access stays at the sweep tier, and `status` asks
for an issue with the `uname -sm` output (§8.1), since adding a target
is cheaper than any other push mechanism. Deployment happens over the existing connection:

1. Probe `uname -sm` and a writable, executable directory:
   `$XDG_CACHE_HOME/sshdrive`, else `~/.cache/sshdrive`, else
   `/tmp/sshdrive-<uid>`. The directory is created with `mkdir -m 700` and
   used only if it is owned by the account and writable by nobody else;
   `/tmp/sshdrive-<uid>` is a predictable name on a shared host, and a
   directory someone else pre-created there is refused, not adopted.
   "Executable" is tested by actually running the uploaded binary with
   `--version`, which catches `noexec` mounts.
2. Upload `sshdrive-helper-<version>-<os>-<arch>` over SFTP if
   `sha256sum`/`shasum` of the remote copy does not match the hash embedded in
   the app. Where the server has neither tool, verification is the remote
   file's size against the embedded binary plus running it with
   `--version`, which prints its version and its own embedded build hash;
   any mismatch re-uploads. The upload goes to a temp name and is renamed
   into place like every other upload (§5.5), never written over the
   existing file: a helper of the same version may be running from that
   path for another Mac, writing over a running executable fails with
   `ETXTBSY` on Linux, and the rename leaves the old inode to the process
   using it. The version is tied to the app release; upgrades happen the
   same way. Versions other than ours whose mtime is older than seven
   days are removed: two Macs sharing one account may run different app
   versions, and each keeps its own file without deleting the other's
   while it is in use.
3. Start `<path>/sshdrive-helper watch --json --root <root> --roots-from-stdin`
   from the same `sh -s` wrapper script as every other remote command
   (§9.2), its path and root single-quoted into the script and never on
   the command line, feed it the root set, and read NDJSON events:
   `{"op":"create|modify|delete|rename|overflow","path":…,"from":…,
   "size":…,"mtime_ns":…,"inode":…}` plus a heartbeat every 15 s. The
   agent sends a ping line every 15 s in return and the helper exits after
   60 s without one, so it never outlives the connection (see the
   lifetime rule above on why sshd cannot be relied on for that).

What it adds over the polling tiers: inotify/FSEvents/kqueue used
directly, so a change arrives in about a second instead of a poll
interval, root-set changes applied live, real
rename events with identifiers preserved (a rename onto an existing path is
applied as a modify of that path, §5.3), nanosecond mtime and inode in every
event, server-side coalescing and a fixed, short ignore list (our own
`.sshdrive-upload-*` and editor scratch names: `.*.swp`, `*~`, `.#*`,
`4913`; `.git` is deliberately not on it, because a repository browsed
through the mount must show a current `.git` or `git status` inside it
acts on stale objects; the list is printed on the change-detection line
of `sshdrive status`), an `overflow` event that makes the agent run a
sweep rather than silently missing changes, and a `sweep` subcommand that does
tier 1's job with size/mtime/inode included so no follow-up `stat`s are
needed. It never listens on a socket, never runs detached, and exits when its
stdin closes or its pings stop, so a dropped connection leaves nothing
behind. A directory that is itself an NFS or FUSE mount on the server
produces no events under any of the three facilities; the 30-minute
insurance sweep and the reconnect sweep cover it.

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
needs nothing installed on the server. Since it does place our code on the remote machine, `sshdrive add`
states this plainly in its output, after the probe has chosen the
directory so the message names the real one ("SSH Drive will upload a
small helper binary to ~/.cache/sshdrive on this server to watch for
changes; disable with `sshdrive set <name> helper off`"), and `sshdrive
status` shows the
exact remote path and version in use. `helper off` stops it and removes the
binary on the next connection; `helper on` re-enables it. Deployment
failures are never fatal: the location silently continues at the next tier
and the status report says why the helper is not running.

#### Mass-deletion guard

A poll that finds a directory empty is not always a directory that was
emptied. A ZFS dataset not yet imported after the NAS rebooted, an external
drive not yet mounted, an autofs share that timed out: all present an empty
directory at the same path, and the `realpath` check (§9.1) is satisfied
because the mount point itself is still there. Reporting that literally
would delete every item beneath it from the replica: the cache is dropped,
every local xattr and Finder tag with it, kept subtrees are re-downloaded
when the data reappears, and every item comes back under a new identifier.

So deletions are held when they are implausibly large. If one diff would
remove at least half of a directory's known, non-hidden items and at least
20 of them, or would empty the root when the root previously held anything
at all, the missing items are not reported. They are recorded in `held`
with the time first seen missing, stay visible in Finder, and the directory
is re-listed after 5 minutes and again after 30. If they are still missing
after the second re-check, the deletions are applied. If they reappear, the
hold is cleared and nothing was ever reported. While held, opening one of
the items fetches from the server and fails. The failure is reported as
`.cannotSynchronize` carrying the `ENOENT`, never as `.noSuchItem`: that
error tells the system the item does not exist, and it would remove the
item locally while the row, the pin and the hold remain, which is the
half-applied deletion the guard exists to avoid. Finder shows an error on
that file, which is the honest state; S5 records what the system does
with each of the two errors.
`sshdrive status` shows "14 deletions held in Photos, re-check at 14:32",
`sshdrive accept-deletions <name> [path]` applies them now, and
`sshdrive test` re-checks now. The guard applies to deletions **inferred
from a listing**: a tier 0 poll, the re-`readdir` of a dirty directory at
any tier, the reconnect sweep, and the root's own listing. It does not
apply to explicit delete events from the helper: an `rm -rf Photos`
produces one event per item and is real, while a vanished mount produces
no events at all, so holding event-driven deletions would only leave
thousands of ghosts in Finder for 35 minutes. S5 records what the system
does with a pending local edit on an item we report deleted, which decides
whether the guard also needs to hold deletions of items the system lists
as pending.

### 6.5 The root set

Every tier watches the same bounded set of directories, kept in the
`roots` table:

| Reason | Directories | Leaves when |
|---|---|---|
| `materialized` | every directory that contains at least one materialized file, from `enumeratorForMaterializedItems()` refreshed on `materializedItemsDidChange` | the last materialized file in it is evicted |
| `pinned` | every pin root, watched recursively, excluded subtrees pruned | the pin is removed |
| `viewed` | every directory Finder has enumerated in the last 30 minutes | 30 minutes after the last enumeration |

Directories never listed, or listed long ago and holding nothing
downloaded, are not polled by anyone. They refresh when Finder next shows
them, through the per-folder `enumerateChanges` request (§5.1; S3 confirms
the system issues it). That keeps tier 0's cost proportional to what the
user is actually looking at or holding, not to everything they ever
browsed.

That per-folder request is the one File Provider behaviour this section
depends on, and S3 is what confirms it, so the fallback is decided now
rather than after the spike. If the system creates a container
enumerator when Finder shows a folder but never asks it for changes,
the enumerator's creation is the view signal instead: the agent lists
the directory then, diffs it against the index, and reports the
differences through the working set, which the system does honour, and
the `viewed` reason is recorded from the same event. If S3 finds that no
enumerator is created on a revisit either, the replica alone is shown
and the only refresh a folder with nothing downloaded can get is a
poll, so in that case the `viewed` reason keeps its directories for the
rest of the session, still capped at 256, rather than for 30 minutes.

The `viewed` reason is bounded, because "Finder has enumerated" is not
the same as "the user has looked at": `ls -R`, a Spotlight pass,
`grep -r`, or the eager download of a freshly pinned subtree enumerates
every directory it touches, and each would otherwise become a polled root
for the next 30 minutes, one `readdir` per minute per directory at tier
0. So the viewed set holds at most 256 directories per location, evicting
the least recently enumerated, and a directory under a recursive pin root
is never added to it, since the pin's recursive watch already covers it.
The `materialized` reason is not capped, since dropping a directory from
it would leave cached files in it unwatched, but it is **rotated** at
tier 0: a photo library browsed under a one-month TTL leaves thousands
of directories holding one downloaded file each, and a `readdir` of
every one per cycle is not proportional to anything the user is looking
at. So each tier 0 cycle lists every `viewed` and `pinned` root and at
most 64 `materialized`-only roots, taken round-robin in order of least
recent listing, so a directory holding only cached files is refreshed
every `ceil(M / 64)` cycles rather than every cycle, and the cost per
cycle is bounded whatever `M` is. Tier 1 passes the whole set to one
`find`, whose cost is the server's, and the helper watches it all, so
the rotation applies to tier 0 only; `status` shows the rotation period
when it exceeds one cycle. The `materialized` reason too skips
directories under a pin root.

A remote rename of a directory reaches tiers 0 and 1 as delete + create of
the whole subtree. Cached content under it is discarded and, if pinned,
re-downloaded. The helper reports the rename and keeps identifiers and
content. Recognising moves heuristically at the polling tiers is future
work (§14).

### 6.6 Eviction and pin maintenance

The eviction loop (§7) and the kept-subtree walk (§7.1) run here on timers.
The agent is not sandboxed, so it can `stat` files under
`~/Library/CloudStorage/…` directly for their access time.

---

## 7. Cache eviction (TTL)

Requirement: content downloaded to the Mac is dropped after the location's
TTL unless it has been used again.

1. Every 5 minutes, for each mounted domain with `cacheTTL != never`:
   `NSFileProviderManager(for: domain).enumeratorForMaterializedItems()`.
2. For each materialized **file** (skip directories; folder eviction is known
   to fail; skip local-only items, §5.4, which have nothing to fetch back):
   last use = max(atime and mtime of the user-visible file, `last_fetch`
   from the index). mtime counts because a file the user saved but never
   re-read was used. atime is read with `AT_SYMLINK_NOFOLLOW` (§9.1). Spike S4
   verifies atime advances on read on the target macOS versions;
   `last_fetch` is the fallback and is always present. That decides
   which of two meanings the TTL has, and the docs and `sshdrive show`
   state the one in force: where atime advances on every read it is
   time since the file was last read; where it advances only when older
   than the mtime (Linux's `relatime` rule) or not at all, atime cannot
   see a second read, and the TTL becomes time since the last fetch or
   save. Watching opens precisely would need Endpoint Security, which a
   login agent cannot hold, so there is no third option. S4 also records
   whether these `stat`s under `~/Library/CloudStorage` draw a TCC prompt
   on 14 or 15: a prompt a launchd agent cannot answer would come back as
   a silent `EPERM`, and the loop then runs on `last_fetch` alone and
   `sshdrive doctor` says so. atime is not
   filtered: Spotlight indexing, Quick Look and Finder thumbnails also read
   files and will extend a file's life, which we accept as "used" rather
   than try to distinguish.
3. If `now - lastUse > TTL`, call `evictItem`. The system refuses to evict
   an item with unsynced local changes, so pending uploads need no check of
   ours. Ignore `.nonEvictable`; log and move on.
4. `sshdrive evict <location> [path]` triggers the same routine on demand,
   with `--all` to drop everything cached.

TTL values map to seconds: `15m`, `1h`, `12h`, `1d`, `1w`, `1mo` (30 days),
`never`. Default: `1d`.

Kept items (§7.1.1) are never evicted: the agent reads each item's
`kept` column (§5.3), which it maintains from the markers on the item
and its ancestors, before evicting. A file the user fetched with Finder's built-in "Download Now" is
treated like any other cached file and falls under the TTL; use `sshdrive
pin` to keep it.

**Anything that opens files downloads them.** A dataless file is
materialized by whichever process opens it, not only Finder: `grep -r` in
the mount, an antivirus scanner, a backup tool other than Time Machine
(which excludes `~/Library/CloudStorage`), or a build that reads a whole
tree will download everything it touches, and the TTL is the only thing
that later frees the space. This is true of every File Provider domain.
v1 adds no mechanism against it: no download budget, no size cap on
unsolicited fetches. The user docs say it plainly, and `sshdrive status`
shows the materialized total so an unexpected download is at least
visible.

### 7.1 Pinning: keep a folder fully offline

Two words are used strictly throughout this document:

- **pinned** / **excluded** are *markers* the user places on a path with
  `sshdrive pin` / `sshdrive unpin` (or the Finder entries). They are what
  gets stored.
- **kept** is the *effect* on an item: whether the nearest marker at or above
  it is a pin. Kept is what the system, the eviction loop, the badge and the
  Finder menu act on. Every pinned item is kept; most kept items are not
  pinned, they inherit it.

Markers live in the index (`pin_state`), and the index is the only
authority; `pins.json` beside it (§5.3) is a write-only copy for
recovery, never read while the index is healthy. The index is the
agent's, and every pin change, from the CLI or from Finder, is one XPC call
to the agent, so there is one writer and no second store to keep in sync.
`sshdrive pins --export` writes the marker list as JSON and `--import` reads
it back, for anyone who rebuilds an index or moves to a new Mac.

What Finder provides on its own for a third-party domain is limited to
"Download Now" (materialize once) and "Remove Download" (evict once). There is
no built-in "always keep on this Mac" for third-party providers; OneDrive,
Google Drive and Nextcloud each implement their own. We do too, through the
framework's declarative `contentPolicy`:

1. **Store the pin.** `sshdrive pin <location> <remote-path>`, or the Finder
   "Keep Downloaded" entry (§7.2), sets `pin_state = 1` on the matching row.
   From Finder the row always exists. From the CLI the path may never have
   been enumerated, and the system cannot apply a policy to an item whose
   ancestors it has never seen, so `pin` first `lstat`s the path over
   SFTP, refuses if it does not exist or is a symlink, then `readdir`s
   each missing ancestor into the index from the nearest known one and
   reports those rows through the working set, so that by the time the
   pinned row is signalled the system has a complete chain down to it.
   Pins are on paths, so a re-enumeration keeps them; deleting the path
   removes them (§5.3).
2. **Declare the policy.** Items are returned with
   `contentPolicy = .downloadEagerlyAndKeepDownloaded` when their effective
   state (§7.1.1) is kept, `.downloadLazily` when excluded, and `.inherited`
   otherwise. On any pin-state change the agent recomputes `kept` and
   `capabilities` on the affected row **and on every known descendant
   row**, in one transaction, which moves each row's metadata version
   since that is derived from those fields (§5.3), writes an anchor for
   each, and signals the working-set enumerator so the system re-reads
   them and applies the new policy. The descendants are not optional:
   `contentPolicy` is inherited by the system, but `userInfo.kept`, the
   badge and `allowsEvicting` (§7.2) are per item and cached by the
   system until that item's own metadata version moves, so bumping the
   pinned folder alone would leave every file inside it offering "Keep
   Downloaded" and "Remove Download" as if nothing had happened.
   Descendants the index has never seen need nothing: their rows are
   created with the right state when they are first listed. The cost is
   O(subtree) rows and anchors per pin change, the same order as a
   directory rename (§5.3). The system then downloads the subtree eagerly
   (through our normal `fetchContents`), shows it as downloaded in
   Finder, and refuses to evict it.
3. **Keep it current.** Pin roots are always in the change-detection root
   set (§6.5), watched recursively. New or changed remote files show up in
   the working-set diff, the system sees the eager policy, and fetches them.
4. **Unpin.** `sshdrive unpin` on an explicitly pinned item clears it and
   every explicit state beneath it; on an item that merely inherits a pin it
   records an exclusion instead (§7.1.1). Either way the content stays on disk
   and becomes subject to the location's TTL from that moment.
5. **Eviction skips kept items** (§7 step 3) and so does `sshdrive evict
   --all`, unless `--unpin-all` is passed, which removes every pin first.

#### 7.1.1 Nested items: one rule

A pin applies to a whole subtree, but users will still right-click a file
inside a kept folder, and "that file's 4 GB of raw video can stay on the
server" is a reasonable thing to want. Rather than ignoring children or
unpinning the whole folder from a child, each path can carry one of three
explicit states, and the **effective state of any item is the nearest explicit
state at or above it in the tree**:

| Explicit state | Meaning | `contentPolicy` returned |
|---|---|---|
| `pinned` | keep this subtree downloaded | `.downloadEagerlyAndKeepDownloaded` |
| `excluded` | inside a kept subtree, but leave this subtree lazy | `.downloadLazily` |
| (none) | inherit from the nearest ancestor | `.inherited` |

Three invariants govern every change:

1. `pin` and `unpin` act on exactly the path named, never on an ancestor.
2. **Any change to a path's explicit state, whether setting `pinned`, setting
   `excluded`, or removing either, first deletes every explicit state beneath
   that path.** A subtree's state is therefore always "whatever the changed
   ancestor says", as if nothing below it had ever been pinned or excluded.
   Toggling the top folder off and on is the way to reset a complicated
   pin/exclusion structure: two commands, or two Finder clicks, and the
   subtree is clean.
3. **Minimal markers.** A request is "make this kept" or "make this not
   kept", and the handler writes the smallest explicit state that produces
   that effective result: removing an exclusion rather than adding a pin
   inside an already-kept subtree, removing a pin rather than adding an
   exclusion when nothing above is kept. Invariant 2 makes this safe: a pin
   nested inside a kept subtree with no exclusion in between can
   never behave differently from inheriting, because any change to the
   ancestor wipes it. So such redundant markers are never created. One
   case needs spelling out: markers move with their paths (below), so an
   exclusion can end up with no pin above it. "Make this kept" on such an
   item removes the exclusion *and* writes `pinned`, since removing the
   exclusion alone would leave it inheriting nothing.

Because of invariant 3 there are only two user-facing operations, `pin`
("keep downloaded") and `unpin` ("don't keep downloaded"), and each item is
in exactly one of five situations:

| Situation | Nearest marker at or above | Kept? | `pin` / Keep Downloaded | `unpin` / Don't Keep Downloaded |
|---|---|---|---|---|
| A. plain | none | no | writes `pinned` here; subtree cleared | no-op (CLI says so; Finder hides the entry) |
| B. pin root | `pinned`, on this item | yes | CLI only: re-asserts the pin, clearing the subtree (the one-command reset). Finder hides the entry. | removes the pin; subtree cleared; content stays and goes under the TTL |
| C. inheriting a pin | `pinned`, on an ancestor | yes | no-op (CLI names the covering ancestor; Finder hides the entry) | writes `excluded` here; subtree cleared; ancestor and siblings untouched |
| D. exclusion | `excluded`, on this item | no | removes the exclusion, so the item is kept by the ancestor's pin again, or writes `pinned` in its place when no ancestor is pinned (an exclusion moved out of its kept tree); subtree cleared | no-op |
| E. inheriting an exclusion | `excluded`, on an ancestor | no | writes `pinned` here (re-include below the exclusion); subtree cleared | no-op |

Finder always shows exactly the one entry that changes the item's effective
state, so the user never has to know which of the five situations applies.

Consequences that follow from the one rule, listed so nobody has to derive
them:

- A new file appearing remotely inside a kept folder is downloaded; one
  appearing inside an excluded subfolder is not.
- Unpinning the top folder forgets its exclusions too, so a later re-pin
  starts clean. Both `pin` and `unpin` print how many nested states they
  cleared, so a reset is visible: "Pinned Projects (cleared 3 nested
  exclusions and 1 nested pin)". Finder has no output channel, so the
  same clearing is silent there: "Don't Keep Downloaded" followed by
  "Keep Downloaded" on a pin root discards every exclusion under it and
  starts downloading whatever they held. This is accepted. A Finder path
  that cleared nothing would make the same two clicks mean different
  things in Finder and in the CLI, which was judged worse than the
  occasional surprise; `sshdrive pins` shows what is left, and the badge
  on a previously excluded folder reappears, which is the only feedback
  Finder gives.
- Exclusions can nest: pin `Projects`, exclude `Projects/archive`, re-pin
  `Projects/archive/2026`. Each level wins over the one above it.
- The recursive watch of kept subtrees (§6.5) skips excluded subtrees.
- The eviction loop (§7) uses the kept state, so an excluded file inside a
  kept folder is evicted like any other cached file.
- `userInfo.kept` (used by the Finder menu predicates, §7.2) and the badge
  reflect the kept state. An excluded folder inside a kept one shows no
  badge; its kept parent still does.
- Moving an item in Finder keeps whatever explicit state its path carried and
  re-evaluates the effective state at the new location, since states are keyed
  by path and `modifyItem` updates the path. Moving a file out of a kept
  folder therefore stops it being kept, and moving one in makes it kept,
  which is what the folder's badge already suggests.
- Unreadable subtrees inside a pin are skipped and reported by
  `sshdrive pins`, not treated as errors. Symlinks follow §5.7.

`sshdrive pins` renders the states as a tree so the layering is visible:

```
$ sshdrive pins nas
Documents/thesis                 pinned    2.1 GB, 412 files downloaded
  raw-video                      excluded  (14.8 GB on server, not downloaded)
Photos/2026                      pinned    480 MB, 1,203 files downloaded
```

Behaviour offline: a kept folder is fully readable and listable with no
network, including subfolders never opened, because the eager download already
materialized them. Edits inside it queue exactly like any other offline write.

Costs to be aware of: a kept folder is downloaded in full, and at tier 0 each
poll cycle `readdir`s every directory in it over SFTP. Deeply nested pins on
slow links without shell access are the main performance risk; `sshdrive
pins` reports subtree size and file count so the user can see what they've
signed up for.

#### 7.1.2 Pinning the root

"Keep this whole location offline" is a legitimate request and must not be
a special case that falls through somewhere. The root is an item like any
other in every mechanism above, and the places where it could have been
different are pinned down here:

- **It has a row.** The index holds a permanent root row (§5.3) whose
  `pin_state` works exactly like a folder's. Pinning the root is situation
  A of §7.1.1 with no ancestor; every other item becomes situation C and can
  be excluded individually; unpinning the root is situation B and, by
  invariant 2, clears every marker in the location.
- **It has a path.** `RelativePath` allows zero components (§9.1); that
  value is the root and is what the transport joins to `remotePath`
  unchanged. `sshdrive pin <name> /` and `sshdrive pin <name> .` both name
  it, `sshdrive pins` renders it as `/`, and `pin` prints the location's
  total size and file count from the last probe before starting, since
  "keep everything" on a home directory or a media share is a large
  decision.
- **It gets the policy.** `item(for: .rootContainer)` returns the root row
  with `contentPolicy = .downloadEagerlyAndKeepDownloaded` when pinned.
  Whether the system honours the eager policy on the root container the
  same way it does on a folder is recorded by S6; if it does not, the agent
  applies the pin to every top-level item instead (situation A on each,
  written as one operation and reported as one root pin), which produces
  the same effective state.
- **It is a watch root.** A pinned root puts the whole location into the
  recursive part of the root set (§6.5): `find` from the root, the
  helper watching its own `--root`. At tier 0 that is a
  `readdir` of every directory in the location per cycle, which `pin`
  warns about along with the size.
- **It is reachable from Finder.** The root has no parent to right-click in
  Finder's list. What Finder offers when the user right-clicks the
  background of the location's top-level window, or its sidebar entry, is
  recorded by S6; if the custom actions are shown there with the root
  container as the selected item, "Keep Downloaded" works on it unchanged.
  The CLI is the guaranteed path either way.
- **Excluding under a pinned root** is how a user keeps "everything except
  `Videos`", and moving items around inside the location never changes
  their kept state, since every path in it inherits from the root.

### 7.2 Pinning from Finder's context menu

The CLI is the source of truth, but the natural place to pin a folder is the
folder itself. Two custom File Provider actions provide that, declared in the
extension's Info.plist and handled in the extension by
`performAction(identifier:onItemsWithIdentifiers:)`, which forwards to the
agent. No window, no UI extension: Finder renders the menu items and calls us.

Every item the extension returns carries `userInfo = ["kept": 0|1]`, its
kept state from §7.1.1 (1 when the nearest marker at or above it is a
pin), copied from the row's `kept` column (§5.3) rather than derived in
the extension. The activation rules read it:

| Menu label | Shown when | Handler |
|---|---|---|
| **Keep Downloaded** | at least one selected item is not kept: `SUBQUERY(FILEPROVIDER_ITEMS, $item, $item.userInfo.kept == 0).@count > 0` | `sshdrive pin` semantics (§7.1.1, situations A, D, E) for each selected item that is not kept; kept items in the selection are skipped. Bump metadata versions, signal the working set; the system then eagerly downloads. |
| **Don't Keep Downloaded** | at least one selected item is kept: `SUBQUERY(FILEPROVIDER_ITEMS, $item, $item.userInfo.kept == 1).@count > 0` | `sshdrive unpin` semantics (situations B, C) for each selected kept item: remove the pin if it is the pin root, otherwise record an exclusion. Not-kept items are skipped. No eviction. |

Two labels, one concept. The entries are worded as a policy ("keep" / "don't
keep") rather than an action on the current download, so they read as a pair
and never collide with Finder's built-in "Download Now" / "Remove Download",
which we leave entirely to Finder. The division of labour is:

- **Our entries set policy.** "Keep Downloaded" makes the item and its
  subtree eager and non-evictable. "Don't Keep Downloaded" returns it to
  lazy; the content stays on disk and falls under the location's TTL.
- **Finder's entries act now.** "Download Now" materializes an unkept item
  once; "Remove Download" evicts an unkept item immediately. A kept item
  is returned without `allowsEvicting` in its capabilities, so Finder
  does not offer "Remove Download" on it at all; a user who wants space
  back chooses "Don't Keep Downloaded" first, which brings the capability
  back with the next metadata version, and then Finder's "Remove
  Download", or waits for the TTL.

Mixed selections show both entries, and each acts only on the items it
applies to, so selecting a kept folder together with a plain file and
choosing "Keep Downloaded" pins the file and leaves the folder alone. An item
inside a kept folder shows only "Don't Keep Downloaded", which excludes just
that item (§7.1.1 situation C); the folder keeps its badge, the excluded item
loses it, and "Keep Downloaded" on it later removes the exclusion (situation
D). Whether an item's kept state is its own pin or inherited is deliberately
not visible in Finder, since by invariant 3 the two never behave differently;
`sshdrive pins` shows the markers for anyone who wants them.

Spike S6 records what Finder actually shows for kept and unkept items, in
particular that dropping `allowsEvicting` removes "Remove Download" from
the menu. `materializedItemsDidChange` is the safety net for any other
route: a kept file turning dataless without our handler having run is
**re-asserted**, not read as intent. The agent bumps the item's metadata
version and signals the working set so the system re-applies the eager
policy and fetches it again, logs the event, and `sshdrive status`
carries a note ("3 kept files were evicted outside SSH Drive and
re-downloaded"). An eviction the user did not ask for, from a system
that misbehaved or was short of disk, must not silently rewrite a pin;
if it recurs, the status note is what tells the user, and `unpin` is one
command away. The one case where the opposite is right is a route the
user can take deliberately: if S6 finds a Finder or system menu that
still evicts a kept item, that route is the user's intent and the net
treats every such eviction as "Don't Keep Downloaded" instead, debounced
per pin root so a folder eviction arriving one child at a time results
in a single change. S6 decides which of the two the net does, and it
does the same one for every eviction, since the agent cannot tell routes
apart. "Turning" is the operative word either way: a freshly pinned tree is full of kept files that are dataless
because their eager download has not reached them yet, so only a file
the agent had seen as materialized in an earlier
`enumeratorForMaterializedItems` pass (§7) counts, and the agent keeps
that set per domain for the purpose. Otherwise that code path stays
dormant.

Kept items also get a **decoration**: a small pin badge declared under
`NSFileProviderDecorations` in the extension's `NSExtension` dictionary
and attached via `decorations` on the item (`NSFileProviderItemDecorating`),
so kept folders are visibly different in Finder.

---

## 8. The CLI: `sshdrive`

Built with `swift-argument-parser`. Every command is an XPC request to the
agent; if the agent is not running the mach lookup starts it, and if the
lookup fails because no login item is registered yet (a fresh install
whose postflight did not run) the CLI launches the bundle it lives in
with `open -g` once, as the postflight does (§10), waits for the
service, and retries; a registered but disabled item gets the Login
Items instruction of §5.2 instead. All
prompts use a hidden tty read and can be avoided for scripting with flags or
stdin.

```
sshdrive add [user@]host-or-alias[:port] [--nickname NAME] [--remote-path PATH]
             [--user USER] [--port N] [--identity PATH] [-o SSHOPTION]…
             [--password | --password-stdin | --no-password]
             [--cache-ttl 1h] [--trust-first]
        Asks the agent to run `ssh -G` and shows what the host resolves to,
        warns when the terminal's `PATH` or `SSH_AUTH_SOCK` differs from the
        login shell snapshot the agent will use (§4.2) and when the resolved
        `proxycommand` is a hand-written `ssh` (§6.1),
        then to connect once with the same command it will use later, in
        its own environment (§4.2, §6.1): the host-key question and any
        password or passphrase prompt are relayed to the terminal and
        stored on success. Refuses locations that need a touch or a
        one-time code on every connection, naming the key that asked for
        the touch and the `--identity` that avoids it (§4.2). Then the agent records
        the location, probes the server (§8.1), and adds the File Provider
        domain. Says so if the helper will be deployed (§6.4 tier 2).
        `--password` reads the password from the terminal before connecting
        and `--password-stdin` from stdin, for scripts; `--no-password`
        answers every password prompt with the skip (§4.2), so the location
        is key-only or is not created.

sshdrive list                     table: name, host, secrets, mounted, TTL, state
sshdrive show <name>              full detail: ssh binary and version, `ssh -G` resolution,
                                  environment snapshot (§6.1), whether the location runs with
                                  IdentityAgent=none or through the key agent (§6.1), the
                                  ProxyJump chain the agent built, mount path, last error
sshdrive remove <name> [--keep-files]
                                  removes domain + config, and each keychain item the
                                  location names that no remaining location also names
                                  (§4.2 keys items by user@hostname:port, so two locations on
                                  one host share one); on its last connection removes the
                                  helper binary and its directory from the server when no other
                                  location of this Mac on the same user@hostname:port uses them
                                  (another Mac's helper running from there keeps its inode and
                                  re-uploads on its next connection);
                                  refuses while uploads are pending unless
                                  --force; --keep-files uses the system's
                                  preserve-downloaded-data removal mode so cached files are
                                  kept in the folder the system chooses (S1 records where)
sshdrive remove --all             every location; run it before `brew uninstall` (§10)
sshdrive mount <name> / unmount <name>
                                  add/remove the File Provider domain without
                                  forgetting the location
sshdrive set <name> nickname|cache-ttl|remote-path|host|port|user|identity|watch-mode|helper|permissions|create-check <value>
                                  nickname and remote-path re-create the domain (the
                                  sidebar name is fixed at domain creation unless S9 says
                                  otherwise; a new root invalidates every path in the index),
                                  so they are refused while uploads are pending and warn
                                  that the cache is dropped otherwise;
                                  host, user, port and identity change what the stored
                                  secrets are keyed on or which key is offered, so they
                                  re-run the collect connection exactly as passwd does
                                  (§4.2) before the change is saved;
                                  watch-mode: auto|poll|sweep|helper (§6.4);
                                  helper on|off: allow the remote helper (default on);
                                  permissions mode|none: map server mode bits to Finder
                                  capabilities (§5.4);
                                  create-check auto|lstat: force the lstat preflight before
                                  every create and rename regardless of the probe (§5.5)
sshdrive set <name> option add|remove <SSHOPTION>
                                  edit the extra -o list
sshdrive passwd <name>            re-run the collect connection through the agent (§4.2) and
                                  replace stored secrets; an item shared with other
                                  locations is replaced for them too, and passwd names them
sshdrive test <name>              connect + list root, print timing, run the
                                  capability probe and print the report (§8.1)
sshdrive status [<name>] [--json] [--probe]
                                  per-domain state, sync errors, hidden names, and the
                                  capability report (§8.1); --probe re-runs the server
                                  probe instead of using the cached result
sshdrive evict <name> [path] [--all] [--unpin-all]
sshdrive accept-deletions <name> [path]
                                  apply deletions the mass-deletion guard is holding (§6.4)
sshdrive pin <name> <remote-path>
                                  keep a folder or file fully offline (§7.1); same
                                  effect as Finder's "Keep Downloaded" entry (§7.2).
                                  `/` or `.` pins the whole location (§7.1.2)
sshdrive unpin <name> <remote-path>
                                  clears an explicit pin, or excludes the path if it
                                  inherits a pin from a folder above (§7.1.1)
sshdrive pins [<name>] [--export | --import FILE]
                                  tree of pins and exclusions with cached size and file counts
sshdrive logs [--follow]          our subsystem's unified log, through `/usr/bin/log show` and
                                  `log stream` with a subsystem predicate, since `OSLogStore`'s
                                  local store is not open to a standard user
sshdrive doctor                   checks: app in /Applications, extension registered
                                  (pluginkit), login item enabled and agent reachable,
                                  app group container writable, CLI on PATH, ssh version,
                                  macOS version, login shell snapshot obtained (§6.1);
                                  reminds that `remove --all` must precede `brew uninstall` (§10)
sshdrive agent start|stop|restart
                                  stop asks the agent to exit cleanly; launchd leaves it down
                                  until the next mach lookup, which any CLI command or extension
                                  call causes, so stop is a pause, not a disable (§10). Disabling
                                  is the Login Items switch in System Settings.
```

`<name>` resolves nickname, then host, then id prefix.

A host-key change needs no command of ours: `status` prints the
`ssh-keygen -R` line to run (§4.3).

### 8.1 Capability report in `sshdrive status`

Several features run at different levels depending on what the remote server
offers. The probe runs on every connection and on `sshdrive test` and
`status --probe`; the result is cached in
`domains/<id>/capabilities.json` with a timestamp and the server banner. It
consists of the SFTP `extensions` list from the SFTP init reply, whether
that reply arrived clean or behind rc-file output (§9.2), whether an exec
channel opens and delivers its sentinel, and one shell script (§9.2) that
reports
`uname -sm`, `id -u` and `id -G` (two commands: POSIX `id` accepts only
one of `-u`, `-g`, `-G` per invocation), `$HOME` as the account spells
it (§5.7), the `find` flavour and whether
it takes `-cmin`, the presence of `sha256sum`/`shasum`, and a writable,
executable cache directory.

The catalogue of server-dependent features:

| Feature | Levels (best first) | What unlocks the next level |
|---|---|---|
| Change detection | helper · sweep · poll | shell access plus a writable, executable directory and a supported OS/arch for the helper; plain shell access for the sweep |
| Rename detection | rename events (helper) · delete+create | the helper |
| Change evidence | ns-mtime + inode (helper or GNU sweep) · size + mtime | shell access |
| Permissions | mapped to Finder capabilities (`id` available) · everything writable | shell access; `permissions none` turns the mapping off where ACLs make mode bits misleading (§5.4) |
| Atomic overwrite | `posix-rename@openssh.com` · remove+rename | OpenSSH ≥ 4.9 or a server that offers the extension |
| Durable writes | `fsync@openssh.com` · none | OpenSSH ≥ 6.3 |
| Transfer sizing | `limits@openssh.com` · conservative 32 KB requests | OpenSSH ≥ 8.5 |
| Collision-safe create | server-enforced (non-overwriting `rename` fails on an existing name) · `lstat` preflight, one extra round trip per create/rename | a server whose plain `rename` refuses to overwrite, as OpenSSH does |

`statvfs@openssh.com` is probed and shown in `status` as "server free
space", but Finder has no way to display it for a third-party domain, so it
is not a capability level.

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
- When the helper is not the active tier on a server with shell access, the
  change-detection line carries a `note:` saying why: `helper off (user
  setting)`, `helper unsupported: <os>/<arch>`, `no writable directory for
  helper`, `cache directory is noexec`, or `helper upload failed: <reason>`.
  The `upgrade:` line then names the fix, so a user who turned it off sees
  `sshdrive set nas helper on` and a user on an unsupported platform sees
  the request to file an issue with the `uname -sm` output.
- On a server where the probe found ACL evidence (§5.4) and `permissions`
  is `mode`, the permissions line carries `note: ACLs detected (<evidence>);
  mode bits may understate access` and, in place of `upgrade:`,
  `consider: sshdrive set <name> permissions none`. With `permissions none`
  it shows `◐` and `note: forced by permissions none`, like a forced
  watch-mode.
- `--json` emits the same data: an array of `{feature, level, best, glyph,
  upgrade, note}` objects plus the probe timestamp, for scripting.
- When offline, the cached probe is shown with "(cached; offline)" and no
  guesses are made about what changed.

---

## 9. Security

- Sandbox on the extension (required). It has no network entitlement and
  no keychain access; it can only talk to the agent. The agent is not
  sandboxed: it needs `~/.ssh`, `ssh-agent`, the keychain, the user's login
  shell, and the CloudStorage paths for eviction. The CLI and askpass are
  not sandboxed either but need nothing: both are XPC clients that hold no
  entitlement and read no secret.
- The agent's mach service is reachable by every process of the user. The
  listener admits only peers whose audit token satisfies our Developer ID
  code requirement (§5.2); everything else is rejected before any method
  runs.
- Hardened runtime on all executables; notarized.
- Private keys are never copied or read by us. `ssh` uses them where they
  are.
- Passwords and passphrases only in the keychain, `kSecAttrAccessible =
  afterFirstUnlock`, read and written only by the agent, the one executable
  carrying `keychain-access-groups` (§3.1). The askpass program never sees
  the keychain: it presents a one-time token the agent minted for that
  `ssh` process, and the agent answers only password and passphrase
  prompts for the location the token belongs to; anything else gets a
  refusal, never a stored secret (§4.2). The CLI collects answers on the
  terminal during `add` and passes them straight to the agent.
- The login shell snapshot (§6.1) runs the user's own shell as the user,
  takes `PATH` and `SSH_AUTH_SOCK` from it, and passes nothing else on.
- Host keys are the user's `known_hosts`; the agent never accepts a new or
  changed key on its own (§4.3).
- Logs never contain file content or credentials. Hostnames and paths are
  logged `.public`: the unified log is readable by other processes of the
  same user, but a `sshdrive logs` that printed `<private>` for every path
  would be useless to the one person it exists for, and the same paths are
  visible under `~/Library/CloudStorage` anyway. Prompt text from `ssh` is
  logged only after the agent has classified it as not a secret.
- Remote access never leaves the location root; see §9.1. Remote commands
  never interpolate filenames; see §9.2.
- The remote helper (§6.4 tier 2) is on by default; `sshdrive add` says so
  when a location is created and `helper off` disables it per location. It is
  verified before every launch, by SHA-256 against a hash embedded in the
  app where the server has `sha256sum` or `shasum` and by size plus its
  own `--version` output otherwise (§6.4 tier 2), runs as the SSH user with no elevated rights from a directory it created
  with mode 0700 and verified it owns, opens no sockets, writes only to that
  directory, and exits within a minute of the connection dropping, with or
  without sshd's help.

### 9.1 Path containment

Nothing the agent, helper or CLI does on the server may touch a path
outside the location's `remotePath`. Symlink policy (§5.7) is one piece of
that; the rest follows.

**One chokepoint for every remote path.** The SFTP layer has no API that
takes a string path. Every operation takes a `RelativePath`, a value type
that can only be constructed from validated components, and the transport
joins it to the canonical root itself. A path may have zero components,
which is the root itself (§7.1.2); a component is rejected if it is
empty, `.`, `..`, or contains `/` or NUL. Filenames arriving from the system
(`createItem`, `modifyItem` renames) and paths arriving from the CLI, the
sweep output and the helper all pass through that constructor
before anything else sees them, so an escape would have to be a bug in one
function rather than in any of the dozens of call sites.

**The root is canonical and verified.** At `add` time the root is resolved
with SFTP `realpath` and the canonical absolute path is stored. On every
connection the agent calls `realpath` on it again and refuses to operate
if the result differs (root deleted, or replaced by a symlink pointing
elsewhere); the domain goes into an error state that `sshdrive status`
explains rather than quietly serving whatever now sits at that path.

**Never descend through a link.** Enumeration uses `lstat` semantics, links
are leaf items, and the index never contains a path with a link as an
intermediate component. Recursive operations walk the server with
`readdir`, since the index holds only what Finder has opened (§5.5),
and re-`lstat` each directory before descending, so a directory replaced
by a symlink after it was enumerated is noticed before anything is done
inside it. That check is mandatory for recursive delete, the one operation where
following a link would be destructive, and is one extra round trip per
directory, which is acceptable for a delete.

**Server-side tools are told the same root.** The sweep runs `find` without
`-L` (physical walk); the helper takes `--root` and refuses any watch or sweep root
that does not canonicalise to a path under it. Paths reported back by any
of them are validated for the root prefix and passed through the
`RelativePath` constructor before use; anything else is logged and dropped.

**Symlink targets are opaque.** The target string of a link is checked
lexically once (§5.7) and otherwise handed to the Mac verbatim; it is never
joined to a remote path or resolved on the server, so `..` inside a target
cannot steer a remote operation.

**Local side too.** The agent's eviction pass stats materialized files under
`~/Library/CloudStorage` with `AT_SYMLINK_NOFOLLOW`, so a native symlink
inside the mount cannot redirect it to a file elsewhere on the Mac.

What this does not cover, deliberately: the SSH account's own permissions
are the real boundary on the server. SSH Drive stays inside `remotePath` by
construction, but a user who points `remotePath` at `/` gets `/`.

### 9.2 Remote command execution

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
  stops writing to it (§6.4).
- **Output that precedes the script's own is discarded.** sshd runs the
  command through the account's login shell, and rc files print things:
  bash sources `.bashrc` when started by sshd, zsh reads `.zshenv` for
  every invocation, fish runs `config.fish` for `fish -c`. Whatever they
  write lands on stdout ahead of the first byte we care about, and
  "parsed as bytes" does not help with a garbage prefix. So every script
  begins by printing a random 128-bit sentinel the agent chose for that
  channel, followed by a NUL, and the agent discards everything up to and
  including it. A channel whose sentinel has not arrived by the metadata
  deadline is reported as "shell output unusable", the location falls to
  `poll`, and `status` shows the first bytes received so the user can
  find the rc file; the probe (§8.1) runs the same check first, so the
  case is diagnosed at `add`. One more case wears the same symptom: an
  account under `ForceCommand internal-sftp` opens the exec channel and
  answers with SFTP bytes instead of the sentinel. The probe recognises
  the `SSH_FXP_VERSION` framing and reports "no shell access
  (ForceCommand)", not unusable shell output.
- **The SFTP subsystem has no sentinel to hide behind.** When the server's
  `Subsystem sftp` names an external `sftp-server` rather than
  `internal-sftp`, sshd starts it through the login shell too, and the
  same rc output lands in front of the SFTP `VERSION` reply; `sftp(1)`
  fails there with "Received message too long", and so would the goal in
  §1 that whatever `ssh` reaches, `add` reaches. The client checks that
  the first packet is a `VERSION` and, when it is not and exec works,
  opens the SFTP session on an exec channel instead: a `sh -s` script
  that prints the sentinel and then `exec`s the `sftp-server` binary the
  probe located (`/usr/lib/openssh/sftp-server`,
  `/usr/libexec/sftp-server`, `/usr/lib/ssh/sftp-server`, or the path a
  readable `/etc/ssh/sshd_config` names on its `Subsystem sftp` line, in
  that order; `sshd -T` would be authoritative but needs root). `status` reports that mode and the
  first bytes the subsystem produced so the user can find the rc file.
  Without exec the location cannot be added, and `add` says why. That
  script is kept to a few lines, sent in a single write, and the agent
  sends no SFTP byte until the sentinel has arrived: dash reads its
  stdin in blocks rather than a byte at a time (verified: a payload
  written in the same pipe write as `printf S; exec cat` is swallowed by
  dash and reaches `cat` only under bash), so anything the agent wrote
  while the shell was still parsing would vanish into its buffer. Once
  the sentinel is out, the whole script is already in that buffer and
  the `exec` follows without another read.
- **Background children never share the script's stdin.** `find` and the
  helper are started with `</dev/null`, so the
  wrapper is the only reader of the heartbeat lines and a child cannot
  swallow them and get itself killed for silence.
- **Output is NUL-delimited** wherever a filename can appear (`-print0`,
  NDJSON from the helper) and parsed as
  bytes, never split on newlines.
- **Every path coming back** is checked for the root prefix and built into a
  `RelativePath` (§9.1) before use.

---

## 10. Packaging and install

- Xcode project with four targets (app/agent, extension, CLI, askpass) plus
  the `SSHDriveCore` local package, and a Rust crate for the helper.
- CI: `xcodebuild archive`, Developer ID sign, `notarytool`, staple, DMG.
  The app bundle embeds a Developer ID provisioning profile because
  `keychain-access-groups` on the agent is a restricted entitlement (§3.1);
  the CLI and askpass are signed with the hardened runtime and no
  restricted entitlements, so their being bare executables reached through
  a symlink is fine.
- Homebrew cask: installs `SSH Drive.app` and links `sshdrive` from inside the
  bundle via the cask `binary` stanza. The cask's `postflight`, and
  `sshdrive doctor`, run `open -g -a "SSH Drive"` once. Launching the app is
  what registers both the extension with PlugInKit and the login item
  through `SMAppService`, and both must be done from the app's own bundle,
  which a symlinked CLI cannot do. The app, on launch, registers its login
  item (unconditionally, below), notices the launchd-managed instance
  already holds the mach service, and exits. macOS posts a notification that a background
  item was added, with the item already enabled and a switch to turn it
  off under Login Items, and Gatekeeper shows its one-time "downloaded
  from the internet" dialog when the postflight opens the quarantined
  bundle; that notification and that dialog are the only "UI" the user
  ever sees.
- Homebrew runs a cask's `uninstall` directives on `brew upgrade` and
  `brew reinstall` as well as on `brew uninstall`, so nothing destructive
  may live there. The `uninstall` stanza only stops the agent, with
  `signal: ["TERM", "org.shirls.sshdrive.agent"]` — the launchd **label**
  of §3.1, not the bundle id, because Homebrew matches that string
  against `launchctl list` output and the bundle id never appears there
  (S1 g1) — and deliberately **not**
  `launchctl:`: that directive boots the label out of launchd while
  `SMAppService` and the background-task database still consider the
  login item enabled, so an app launch that registered "only if needed"
  would do nothing and the mach service would stay dead until the next
  login. A TERM leaves the launchd registration alone. The agent exits
  with status 0 on TERM and on `sshdrive agent stop`, and its plist sets
  `KeepAlive` to `SuccessfulExit` false rather than plain `true` (§3):
  with plain `true` launchd would relaunch the agent the instant it
  exited, from whatever bundle sat at the path at that moment, which
  mid-upgrade is the old one about to be deleted, and `agent stop` could
  not stop anything. With the conditional form a clean exit stays down
  until the next mach lookup, a crash is restarted at once, and the
  lookup that brings the agent back after an upgrade normally finds the
  new bundle in place. If a lookup lands during the swap and starts the
  old bundle, the agent's watch on its own executable (below) catches
  the replacement and it exits cleanly again, and the next lookup starts
  the new one. The app also calls `SMAppService.register()`
  unconditionally on every launch, since it is idempotent, rather than
  checking `status` first — but registering is **not** repairing, and an
  upgrade needs more than that. Homebrew deletes the app and installs the
  new one, and a login item whose bundle has been deleted and put back
  keeps its enabled status while launchd can no longer resolve the
  program: every spawn fails with `Could not find and/or execute program
  specified by service` and `copy_bundle_path(...) error 0x6f`, on a 10 s
  retry, for good. `register()` keeps returning success throughout,
  because as far as `SMAppService` is concerned the item is still
  enabled, so the unconditional register on launch does not clear it
  (S1 f2). Only `unregister()` does. So the upgrade path is
  **unregister, then register**: the cask's `postflight` runs the new
  bundle once with `SSHDRIVE_AGENT_ROLE=unregister`, which calls
  `SMAppService.unregister()` and exits, before the `open -g` that
  registers it again. The same two steps are what a developer replacing
  the bundle by hand has to run.
  Locations, domains, the local replica and pending uploads all survive
  an upgrade untouched, and S1 checks that the agent is reachable after
  a `brew reinstall` and that the `signal:` stanza finds the
  launchd-started agent at all, since Homebrew matches the launchd label
  against `launchctl list` output rather than asking LaunchServices.
  `zap` is where the rest of removal lives, with one limit: Homebrew runs
  the `uninstall` stanza, then deletes the app, then `zap`, so by the time
  `zap` runs there is no `sshdrive` and no provider left to call
  `NSFileProviderManager.remove(domain)`. Domain removal therefore cannot
  be automated from the cask. `zap` deletes the group container and the
  launch-agent registration
  (`launchctl:` is right here, since nothing is coming back). It cannot
  delete the keychain items: they live in the data-protection keychain,
  which no file removal reaches and no cask directive addresses, and by
  the time `zap` runs the only executable that could delete them is
  gone. `sshdrive remove --all` is what deletes them, and a `zap`
  without it leaves orphaned items that a later install's `add` simply
  overwrites. Nor does `zap` clear the entry under Login Items, which is
  the system's own record and goes away once the system finds the bundle
  missing, sometimes not before the next login. So the cask's `caveats`, the docs
  and `sshdrive doctor` all say the same thing: run `sshdrive remove
  --all` before `brew uninstall`. A user who skips it is left with sidebar
  entries for a provider that no longer exists, shown as unavailable,
  until a reinstall, when the app on its first launch removes every domain
  whose identifier is not in `config.json`, or every domain of ours when
  the container is gone too.

### 10.1 Repository and hosting

Everything lives on GitHub under `alecdwm/sshdrive`, with one small satellite
repo for Homebrew.

| What | Where | Notes |
|---|---|---|
| Source, this document, issues, CI | `github.com/alecdwm/sshdrive` | `DESIGN.md` at the root; user docs under `docs/`. |
| Release binaries | GitHub Releases on the same repo | CI attaches the notarized, stapled `SSH-Drive-<version>.dmg` plus a `.sha256`. Tags `v1.2.3`. |
| Website / user docs | GitHub Pages from `docs/` on `main` | Static site (a Markdown-driven generator such as MkDocs or plain Jekyll). Optional custom domain `sshdrive.shirls.org` via a `CNAME` file and a DNS CNAME to `alecdwm.github.io`. |
| Homebrew tap | `github.com/alecdwm/homebrew-tap` | Must be a separate repo: `brew tap alecdwm/tap` resolves to `alecdwm/homebrew-tap` by naming convention, so the cask cannot sit inside the main repo without users typing a full URL. Contains `Casks/ssh-drive.rb`. |
| Support links baked into the app | `sshdrive --help`, `sshdrive doctor` | Point at the Pages site and the issues tracker. |

Install path for users:

```
brew tap alecdwm/tap
brew install --cask ssh-drive
sshdrive add nas
```

Release flow (GitHub Actions, a Linux job feeding a macOS job, triggered
by a `v*` tag):

1. Build the helper. The Linux and FreeBSD targets are cross-compiled
   with `cross` (musl for Linux, its FreeBSD image for `freebsd/x86_64`)
   in a **Linux job**, since `cross` needs Docker and GitHub's macOS
   runners do not provide it; the macOS job builds `darwin/arm64`
   natively with `cargo`, ad-hoc signs it (`codesign`; arm64 macOS
   refuses to run unsigned code even over `ssh`), collects the Linux
   job's artifacts, and records every hash into the app's manifest.
2. `xcodebuild archive` → Developer ID sign (certificate and App Store Connect
   API key stored as repository secrets) → `notarytool submit --wait` → staple
   → DMG.
3. Upload DMG + sha256 to the GitHub Release.
4. Render `Casks/ssh-drive.rb` from a template with the new version, URL and
   sha256, and push it to `alecdwm/homebrew-tap` (a deploy key or fine-grained
   PAT for that one repo). `brew upgrade` then picks it up.
5. Publish the docs site (Pages deploys automatically from `main`).

The tap can be reused for any future casks or formulae of yours; that is why it
is named `homebrew-tap` rather than `homebrew-sshdrive`. If the project gains
enough users, the cask can later be submitted to the main `homebrew-cask`
repository, at which point `brew install --cask ssh-drive` works without the
tap.

Upgrades replace the bundle under a running agent and extension. The
extension is killed by the system and relaunched from the new bundle. The
agent watches its own executable with a vnode dispatch source; when it
is deleted or replaced, the agent waits until the bundle at its path is
readable, its `Info.plist` parses, and its main executable is a
different inode from the one the agent is running, so it never hands
over to a half-copied bundle and never waits forever on a
`brew reinstall` of the same version, and then exits cleanly, and the
next mach lookup starts the new build (the `KeepAlive` rule above). Pending uploads are
held by the system and survive.

---

## 11. Spikes (do these first; each is a day or less)

| # | Question | Why it matters |
|---|---|---|
| S1 | The process boundary, in this order: (a) a sandboxed File Provider appex connects to the app-group-prefixed mach service declared in the `SMAppService` agent's plist, and launchd starts the agent on that lookup; (b) the agent's listener validates the peer's audit token against our code requirement (§5.2); (c) a `FileHandle` opened by the extension crosses NSXPC and the agent can write through it; (d) the app bundle with an embedded Developer ID profile and `keychain-access-groups` on the agent passes notarization and reaches the data-protection keychain, while the bare CLI and askpass launch with no restricted entitlements (§3.1); (e) `NSFileProviderManager.add(domain)` from the launchd-started agent associates the domain with our extension, and `open -g` from a Homebrew `postflight` registers both the extension and the login item; (f) after `brew reinstall --cask` has sent the agent TERM and replaced the bundle, the mach service comes back on the next lookup without a logout (§10); and (g) Homebrew's `signal:` stanza actually finds the launchd-started agent by bundle id (§10). | Everything else in the design assumes (a) through (d). If any of them fails, the component split in §3 changes before a line of SFTP is written. (e) decides whether install needs any manual step. |
| S2 | `ssh` under our supervision, run from the launchd-started agent and not from a terminal: `none` auth against Tailscale SSH; an encrypted ed25519 key via askpass with `SSH_ASKPASS_REQUIRE=force` and the token protocol (§4.2); the two-step collect connection of §4.2, `IdentityAgent=none` first against a key that `ssh-agent` already holds, confirming the passphrase prompt is seen and stored, then the agent pass for an agent-only key; a key reachable only through an `SSH_AUTH_SOCK` exported in `.zshrc` and a `ProxyCommand` that calls a Homebrew tool, both of which only the login shell snapshot (§6.1) makes work; a two-hop `ProxyJump` chain built by the agent as its own `ProxyCommand` (§6.1), with a password on both hops and with `ControlMaster auto` set for the bastion in `~/.ssh/config`, confirming the hop uses neither the user's socket nor the key agent during the `IdentityAgent=none` pass; the `SSH_ASKPASS_PROMPT` values `ssh` sets for the host-key question and a FIDO user-presence notice; a `-N` master with SFTP and exec mux clients, and killing one client without disturbing the others; a mux client spawned after its socket was removed, confirming that with `-F /dev/null`, `BatchMode=yes` and `ProxyCommand=/usr/bin/false` it exits at once rather than connecting on its own, and that the agent classifies that exit as master lost (§6.1); that the master stays in the foreground as our child with `ControlPersist=no` and detaches with `ControlPersist=yes` (§6.1); the 60 s authentication deadline firing against an agent-held key that waits for a touch, and `agent refused operation` being retried rather than stopping (§4.2, §6.1); the screen-unlock and present-user request re-arm firing exactly once each after a deadline stop, with the domain still connected, and a request arriving with input idle over 30 s not firing it (§4.2, §5.6); a host block carrying `RemoteCommand`, `RequestTTY force` and `ForkAfterAuthentication yes`, confirming the session-shape overrides (§6.1) keep the master in the foreground and the mux clients working; an `agentDependent` location whose `identityagent` socket does not exist at spawn time, confirming the pre-spawn socket check classifies it transient where `ssh`'s own stderr at `LogLevel=ERROR` would not (§6.1); a first-pass location on a Mac whose config names 1Password through `IdentityAgent`, confirming the runtime `IdentityAgent=none` keeps 1Password silent across a reconnect (§6.1); a key whose passphrase lives in the login keychain through `UseKeychain`, confirming the launchd-started `ssh` reads it without a keychain dialog (§4.2); an identity list whose first encrypted key has no stored passphrase and is accepted by the server, confirming the empty answer skips it and the second key authenticates without the location stopping (§4.2); a hop whose bastion has `ControlPath` set in the config, confirming `ControlPath=none` keeps it off that socket (§6.1); an identity path with a space and a quote inside the agent-built `ProxyCommand` (§6.1); throughput of our SFTP client with pipelining against `sftp(1)` and `rsync` on a 1 GB file and on 10,000 small files. | Validates the transport decision and the auth goal in §1 before anything is built on it, including the claim that a location which passes `add` cannot fail from the agent. |
| S3 | Minimal replicated extension against the **fake backend** of milestone 1 (§12), so it runs before any transport exists: list, open, save, rename; observe the sidebar label and mount path with two domains and with `displayName` set to `nas` versus `SSH Drive - nas`; confirm the system requests `enumerateChanges` on a folder's enumerator when Finder shows it, and if not, whether it at least creates a container enumerator on a revisit, which decides which of §6.5's two fallbacks applies; what Finder does with `.filenameCollision`; whether `fileSystemFlags.userExecutable` on a served item makes the fetched file executable and a `chmod +x` inside the mount arrives as `.fileSystemFlags` in `changedFields` (§5.4); what the delete confirmation looks like without `allowsTrashing`; what the system does when `modifyItem` returns an item whose version differs from the upload, since the conflict path of §5.5 assumes it re-fetches and does not re-offer; and how an atomic save from TextEdit, Xcode and Word reaches the extension, one `modifyItem` on the original identifier or a `createItem` plus `deleteItem`, since without tombstones (§5.3) the latter loses a pin or tag placed on that one file. What `.syncAnchorExpired` from a working set whose `enumerateItems` returns nothing makes the system re-enumerate (§5.3), with the agent's catch-up sweep disabled for the test so the system's own behaviour is visible. Confirm the extension can open `index.sqlite` read-only in WAL mode from the group container inside the sandbox while the agent is writing to it (§5.2), that it sees `meta.reconciling` and `meta.generation` change promptly, that a restore through the backup API into the live file is visible to the open reader, what the system does when `item(for:)` itself throws `.serverUnreachable`, which the reconcile stall (§5.2) assumes is harmless, and measure `item(for:)` served that way against the XPC round trip it falls back to, under a 50,000-entry listing. **Deferred to milestone 3, against a real server:** the containment test, replacing an enumerated directory with a symlink to `/etc` on the server and confirming nothing inside it is listed, fetched or deleted. | Settles the naming scheme (§2, §4), the root-set design (§6.5), the trash decision (§5.4), and that the extension's direct index reads work from the sandbox; the deferred part settles the §9.1 guarantees from the first networked build. |
| S4 | Does `evictItem` work for files in our domain, does atime on materialized files advance on every read, only when older than the mtime, or never (§7), does the system refuse to evict an item with pending changes, do Finder tags and other xattrs served from our index survive eviction, which §5.4 assumes, and does a launchd agent's `stat` under `~/Library/CloudStorage` draw a TCC prompt on 14 or 15 (§7)? | Determines whether TTL eviction can use real last-access, whether it needs a pending-upload check of its own, and whether local xattrs need re-applying after an evict. |
| S5 | Behaviour when throwing `.serverUnreachable` for writes: how long the system retries, whether `signalErrorResolved(.serverUnreachable)` reliably wakes the flush, and whether `signalEnumerator` alone does (§5.6). Whether requests still reach the extension while the domain is connected but every call fails fast, which the deadline re-arm depends on (§4.2). How long the system waits after `.serverUnreachable` from `fetchContents` before calling again, since that, not our breaker, bounds the spinner Finder shows when a fetch arrives during a reconnect (§6.3). What the extension sees when the agent's mach service is unavailable (login item disabled), and whether `disconnect(reason:)` can be called from inside the extension at all; if not, the extension answers `.serverUnreachable` and the message lives only in `sshdrive doctor` (§5.2). Whether the system times out an `enumerateItems` that takes the full 60 s the breaker may hold a call during a reconnect (§6.3), and what it does to the extension if so. What the system does with a pending local edit when the extension reports that item, or its parent, deleted through the working set, and when the item comes back with a content version the system cannot match, which the reconcile walk produces for pending items (§5.3). What the system does with an item whose `fetchContents` fails with `.noSuchItem` versus `.cannotSynchronize`, since the mass-deletion guard (§6.4) needs the second to leave the item in place. Whether a `readdir` and `lstat` walk of the mount is served from the replica while every enumeration returns `.serverUnreachable`, which the reconcile stall (§5.3) depends on. | The "no fuss across network drops" requirement rests on this, and so does the agent-missing message (§5.2). The last question decides whether the mass-deletion guard (§6.4) must also hold deletions of pending items. |
| S6 | Flip a folder's `contentPolicy` to `.downloadEagerlyAndKeepDownloaded` at runtime: does the system download the whole subtree after a working-set signal, does it enumerate subfolders that have never been opened in Finder (the offline claim in §7.1 depends on it), does it accept a chain of never-enumerated ancestors reported through the working set, which `sshdrive pin` on an unseen path depends on (§7.1), do new files added remotely get fetched on the next poll, and does `evictItem` correctly refuse? Does an explicit `.downloadLazily` on a child override an eager ancestor (needed for exclusions, §7.1.1)? Record exactly which built-in menu items Finder shows for pinned vs unpinned items, that an item returned without `allowsEvicting` gets no "Remove Download" entry and that no other route evicts it (§7.2), and whether custom actions with `userInfo`-based activation rules appear at the top level of the context menu or in an app submenu. Also: does the eager policy on the item returned for `.rootContainer` download the whole location, and do custom actions appear when right-clicking the background of the location's top-level window or its sidebar entry, with the root as the selected item (§7.1.2)? How many `fetchContents` calls the system keeps open at once for an eager subtree, which bounds the transfer scheduler's backlog (§6.2). | Pinning (§7.1) depends on the policy being honoured dynamically; the Finder menu design (§7.2) depends on how the system entry behaves on pinned items. |
| S7 | Run tier 1 and the helper (§6.4) over `ControlMaster` exec channels alongside SFTP traffic: does a long-running helper stream coexist with two SFTP channels on one connection, and how long does the `find -cmin` sweep take on a 1M-file tree with 200 roots? Check `-cmin` and `-printf` across GNU, BSD and busybox `find`, including the busybox on a real Synology DSM box and the `-mmin` fallback (§6.4), the server-clock sweep window against a server whose clock is five minutes behind, and the `sh -s` stdin-script mechanism (§9.2) under bash, zsh, fish and csh login shells, each with an rc file that prints to stdout, confirming the sentinel discards it, plus the `env -0` shell snapshot (§6.1) under fish and the `-ic` form under tcsh, and an rc file that leaves a background child holding stdout, confirming the closing sentinel returns the snapshot before the timeout. Kill the client abruptly with `ClientAliveInterval` unset on the server and record whether a bare background process survives, and whether the heartbeat wrapper (§6.4) kills it within a minute under dash, busybox and bash. Run the probe against an account whose login shell prints on startup and whose sshd uses an external `sftp-server`, confirming the exec-channel `sftp-server` fallback (§9.2), and against a `ForceCommand internal-sftp` account, confirming it is reported as no shell rather than unusable output. On FreeBSD, measure the helper's kqueue directory watch plus 60 s sweep on a 100,000-file tree (§6.4 tier 2). Measure a tier 0 cycle with 5,000 `materialized`-only roots under the rotation (§6.5). | Decides whether tier 1 and the helper are practical on one connection, sets the default poll interval, proves the quoting design, and proves that nothing we start outlives the connection. |
| S8 | Return an item with `contentType = .symbolicLink` and `symlinkTargetPath`: does the system create a real symlink under CloudStorage, does Finder badge it, does a relative target resolve inside the mount, how does Finder present a dangling one, does `ln -s` inside the mount reach `createItem` with the target intact so escaping targets can be refused? | Confirms §5.7 end to end. |
| S9 | Does calling `NSFileProviderManager.add(domain)` with an existing identifier and a new `displayName` rename the domain in place, keeping cache and pending uploads? | If yes, `set nickname` stops re-creating the domain and the §13 data-loss caveat goes away. |
| S10 | Finder tags on an item whose extension returns `extendedAttributes` from local storage: does tagging round-trip, and does the xattr hash in the metadata version (§5.3) stop the system re-offering the `modifyItem`? Also check what happens if the version is deliberately left unchanged, to know what the hash is protecting against. | Confirms the local-xattr policy (§5.4) does not produce a retry loop. |

---

## 12. Milestones

1. **Skeleton** — app/agent, extension, CLI, askpass all sign and launch;
   XPC between the three; the extension's read-only index reader, kept
   or dropped on S3's measurement (§5.2);
   `sshdrive doctor` green; and a **fake backend**: an in-memory tree
   behind the agent's `SFTPTransport` protocol (§6.2) that lists,
   fetches, writes, renames and deletes, and can be mutated from a test
   hook to stand in for a remote change, so the File Provider half can
   be exercised before a byte of SSH exists. Spikes S1, S3 (its
   fake-backend part), S4 and S6 folded in: S3, S4 and S6 gate the
   naming scheme and two of the goals in §1 (TTL eviction and pinning)
   and need only the skeleton and the fake backend, so they run before
   any transport code exists. The fake backend stays as the test double
   for every later milestone.
2. **Transport** — `ssh` supervision with a `-N` master and mux clients,
   the agent-built `ProxyJump` chain, the login shell snapshot, the askpass token protocol with the keychain
   behind the agent, the SFTP client with pipelining, deadlines and
   extensions, the `RelativePath` chokepoint, `sh -s` remote scripts with
   the heartbeat wrapper. Spike S2.
3. **Read-only** — `add` through the agent with `ssh -G` display and
   relayed prompts, `list`, `show`, `remove`; browse and open files through
   the transfer scheduler (§6.2); capability
   probe and `status` (§8.1); permissions to capabilities; hidden-name
   handling. The deferred, real-server part of S3 (containment).
4. **Read-write** — create/modify/delete/rename/move; temp-file + rename
   uploads with mode restore; conflict copies; local xattrs; `.DS_Store`;
   symlink handling (§5.7). Spikes S8, S10.
5. **Offline hardening** — circuit breaker with bounded waiting, reconnect,
   queued-write flush on network-up via `signalErrorResolved`, sleep/wake
   testing, agent-missing behaviour, the deadline re-arm (§4.2). Spike S5.
6. **Change detection, tiers 0–1** — root set, anchors, poll cadence, remote
   sweep, fallback ladder, mass-deletion guard and `accept-deletions`.
   Spike S7.
7. **Eviction** — TTL agent loop, `sshdrive evict`, `set cache-ttl`. Built
   on S4's answers from milestone 1.
8. **Pinning** — `pin`/`unpin`/`pins`, content policy, kept-subtree watching,
   eviction exclusion, Finder "Keep Downloaded"/"Don't Keep Downloaded" actions
   and the pin badge. Built on S6's answers from milestone 1.
9. **Remote helper (tier 2)** — Rust helper binary, cross-compiled in CI,
   deploy/verify/upgrade over SFTP, NDJSON protocol, `helper on|off`. Until
   this ships, `auto` tops out at sweep.
10. **Ship** — notarized DMG, Homebrew cask with postflight and uninstall,
    `logs`, docs. Spike S9 applied to `set nickname` if it passed.

---

## 13. Decisions

Questions that were open during drafting and how they were settled. Each
entry is a pointer: the reasoning lives in the section named, and only
there, so that this list cannot drift from the body.

- **Transport** is the system `/usr/bin/ssh` by absolute path, owned by
  the agent, with our own SFTP wire-protocol client; not libssh2, not a
  session in the extension (§6.1, §6.2).
- **The CLI is a pure XPC client;** even `add` and `passwd` connect from
  the agent (§3, §4.2).
- **The extension reads the index directly** through a read-only WAL
  reader, kept only if S3's measurement earns it (§5.2).
- **Secrets** live in the keychain, read only by the agent, served to
  `ssh` through a token-authenticated askpass; keyed by the resolved
  `user@hostname:port`, never the alias, and shared across locations;
  the collect connection runs `IdentityAgent=none` first, then with the
  key agent (§4.2).
- **Prompts that need a human every time are refused at `add`;** a touch
  refusal names the key and the `--identity` that skips it, chosen over
  pinning the successful identity automatically (§4.2).
- **Authentication has a 60 s deadline from spawn,** watching for the
  control socket; an `agentDependent` timeout stops reconnection and is
  re-armed once on screen unlock or a request with the user present;
  refusals are never re-armed; a missing or refusing key-agent socket,
  checked at the `identityagent` `ssh -G` resolves, is transient (§4.2,
  §6.1).
- **Key agents are for `agentDependent` locations only;** every other
  location runs with `IdentityAgent=none` (§4.2, §6.1).
- **`ssh` runs with the login shell's `PATH` and `SSH_AUTH_SOCK`,**
  snapshotted through `env -0` between two sentinels; `add` verifies
  through the agent (§4.2, §6.1).
- **The master is `-N` with `ControlPersist=no`,** every channel a mux
  client, the socket named by location id (§6.1).
- **Connection sharing and session shape are never inherited:** a fixed
  override set on the master and every hop, `ProxyJump` chains built by
  the agent as `ProxyCommand` with `ControlPath=none` on hops, mux
  clients with `-F /dev/null`, `BatchMode=yes` and
  `ProxyCommand=/usr/bin/false`; a hand-written `ProxyCommand ssh …`
  escapes this and `add` says so (§6.1).
- **`MaxSessions` is probed;** 2 drops the bulk channel, 1 makes the
  location SFTP-only (§6.1).
- **Transfers interleave under a scheduler,** four at a time, foreground
  before background (§6.2).
- **Calls wait for an in-flight connection attempt,** bounded by its
  deadline; only an open breaker fails fast (§6.3).
- **Reconnection stops on auth and host-key failures;** host keys are the
  user's `known_hosts`, checked strictly, with no pinning of our own
  (§4.3, §6.1).
- **SFTP status codes are the error model;** nothing reads an errno off
  the wire (§6.2).
- **Content versions are size, second-mtime and generation at every
  tier;** ns-mtime and inode only feed change detection (§5.3).
- **The conflict check includes generation,** read from the row (§5.5).
- **Writes** go through temp + `posix-rename`, restore the mode, never
  write in place; owner, group and hard links are not preserved; every
  upload ends with an `lstat` that becomes the version and resets inode
  and ns-mtime; in-flight paths are invisible to change detection;
  conflict copies are named after this Mac; new files get the Mac file's
  mode (§5.5).
- **Temp files name their Mac;** our own stale ones go at once, other
  Macs' after 30 days (§5.5).
- **Case-only renames are detected with `realpath`** and redone through
  `posix-rename` (§5.5).
- **The overwrite-rename probe runs in the location root;** `create-check
  lstat` forces the preflight (§5.5).
- **No trash;** Finder deletes are immediate after its confirmation
  (§5.4).
- **Name collisions:** the visible name wins, then byte order; the rest
  are hidden and reported (§5.4).
- **Permissions map to capabilities and `fileSystemFlags`** per location
  (`mode` or `none`), using `id` from the probe; SFTP-only accounts see
  everything writable; the probe recommends `none` on ACL evidence and
  never switches alone (§5.4).
- **Extended attributes stay local; `.DS_Store` is swallowed** (§5.4).
- **Symlinks** are native, never followed, shown only when a lexical
  check keeps them inside the root under either of its two spellings
  (§5.7).
- **No tombstones;** a deleted row is deleted and a re-created path is a
  new item (§5.3).
- **A lost index is reconciled against the replica,** backup first, walk
  second, versions rebuilt from the replica's `lstat`, only unseen items
  minted fresh; the restore goes into the live database through the
  backup API; reconciliation stalls the agent and the extension's reads
  alike (§5.2, §5.3).
- **A fresh working-set anchor triggers a full sweep** (§5.3).
- **A row is a finished item:** derived fields are stored by the agent
  (§5.2).
- **A pin change rewrites every known descendant** and writes an anchor
  for each (§7.1).
- **Change detection has three tiers,** poll, sweep, helper;
  inotify/fswatch is deferred (§6.4, §14).
- **The helper is on by default and first in the ladder,** with a short
  ignore list that leaves `.git` watched, verified by hash or by size
  plus `--version` (§6.4).
- **Sweep windows use the server's clock** (§6.4).
- **Large listing-derived deletions are held and re-checked;** helper
  delete events apply at once; held fetches fail with
  `.cannotSynchronize` (§6.4).
- **The root set** is materialized + pinned + recently viewed; viewed is
  capped at 256, materialized is rotated at tier 0, both skip pin roots;
  the per-folder refresh has a decided fallback (§6.5).
- **Remote renames at polling tiers stay delete + create** (§6.5, §14).
- **TTL** measures time since last read where atime allows, otherwise
  since last fetch or save, with `last_fetch` as the floor; system
  readers count (§7).
- **No download budget in v1** (§7).
- **Pins** live in the index with a write-only recovery copy; one rule
  for nested states; invariant 2 applies from Finder silently; the root
  is pinnable (§7.1, §7.1.1, §7.1.2).
- **Kept items drop `allowsEvicting`;** an eviction that reaches one
  anyway is re-asserted, unless S6 finds a deliberate route, in which
  case it unpins (§7.2).
- **Every remote script starts with a sentinel;** the SFTP subsystem
  behind a chatty rc file is worked around through an exec channel, not
  refused (§9.2).
- **Logs are `.public`** for hostnames and paths (§9).
- **`KeepAlive` is `SuccessfulExit` false;** the cask's `uninstall` only
  sends TERM; `remove --all` precedes `brew uninstall`; domain removal
  cannot be automated from the cask (§3, §10).
- **The cask's `signal:` names the launchd label `org.shirls.sshdrive.agent`,
  not the bundle id,** because Homebrew matches it against `launchctl list`
  output, where only the label appears (2026-09-04, §10).
- **An upgrade unregisters the login item before registering it,** since
  `SMAppService.register()` reports success but does not repair a
  registration whose bundle was deleted and replaced (2026-09-04, §10).
- **The helper is built in a Linux job** and the darwin binary on the
  macOS job (§10.1).
- **Nickname and remote-path changes re-create the domain,** refused
  while uploads are pending; S9 may lift the nickname half (§8).
- **Remote path defaults to the account's home;** multiple locations on
  one host are allowed, each with its own connection (§4, §6.1).
- **Minimum macOS is 14** (§2).
- **Milestone 1 has a fake backend** that stays as the test double (§12).

---

## 14. Future work

Not planned for v1, recorded so the design leaves room for them:

- **Move detection at the polling tiers.** In one diff cycle, a vanished
  directory and a new one with the same child names, sizes and mtimes could
  be reported as a rename, keeping identifiers and cached content.
- **One-time-code logins.** Servers that require a fresh code on every
  connection could be supported by a `sshdrive unlock <name>` that answers
  the next prompt interactively.
- **Finder aliases as remote symlinks.** A `createItem` whose content type is
  an alias file could be resolved on the Mac side; if the bookmark points
  inside the same domain, create a remote symlink instead of uploading the
  alias file.
- **Selective offline profiles**, such as "keep everything opened in the
  last 7 days", built on the same pin markers.
- **Server-side trash**, if users ask for "Put Back".
- **inotify / fswatch as a change-detection tier** between sweep and the
  helper, for accounts with exec whose cache directory is `noexec` and
  whose OS/arch the helper does not cover. The design was worked out
  and is kept here so it need not be rediscovered: two `inotifywait -m
  -P -q --no-newline --format '%e%0%w%f%0'` processes per location under
  one wrapper (recursive for pin roots, flat for the working set), `-P`
  mandatory because `-r` otherwise follows symlinks out of the share,
  `modify` left out of the event list since `close_write` reports the
  finished write, `moved_from`/`moved_to` as delete + create because the
  rename cookie is not exposed, watch-limit and overflow errors dropping
  to sweep, watcher restarts debounced per root set, and `fswatch -r -0
  --event-flags` on macOS and BSD. It was cut from v1 because it was the
  most code for the narrowest audience, needs a tool installed on the
  server, and cannot report renames; adding a helper target for the
  platform in question is usually cheaper.
- **Submitting the cask to homebrew-cask** so the tap is unnecessary.
