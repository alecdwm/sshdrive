# SSH Drive — design document

SSH Drive mounts remote SFTP locations into Finder using Apple's File Provider
framework (the same mechanism iCloud Drive, Google Drive, OneDrive and Dropbox
use on modern macOS). It has no GUI; everything is driven by the `sshdrive` CLI.

This document is the plan: what we build, how the pieces fit, the decisions
already made, the questions still open, and the order of work.

---

## 1. Goals and non-goals

**Goals**

- SFTP-only remote locations, each shown as its own Finder sidebar entry named
  `SSH Drive - <nickname, else hostname>`.
- Zero GUI. Add / remove / configure / inspect via `sshdrive`.
- Files are placeholders ("dataless") until opened; opening downloads on demand.
- Locally cached content is evicted after a per-location TTL (15m … 1 month).
- Mounts survive reboots and network loss without user intervention. Offline,
  already-downloaded files stay readable and previously browsed folders stay
  listable. Writes queue and flush when the network returns.
- Auth: password, key (optionally passphrase-protected, passphrase in the
  system keychain), or no credential at all (Tailscale SSH and similar).
- Remote changes appear in Finder without the user doing anything. How fast
  depends on the server: near-instant where the SSH account has shell access
  and inotify (or our helper), polled otherwise. `sshdrive status` always
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

---

## 2. Platform facts the design depends on

The user-facing term "Filesync" corresponds to Apple's **File Provider**
framework. The relevant facts:

| Fact | Consequence for us |
|---|---|
| A File Provider extension must ship inside an `.app` bundle and is loaded by the system from `Contents/PlugIns/*.appex`. | We need an app bundle even with no windows. The app is an agent app (`LSUIElement = true`): no Dock icon, no menu bar, no windows. |
| The extension runs in its own sandboxed process, launched by the system on demand and killed when idle. | Nothing that must run continuously can live in the extension. Long-lived work (network monitor, eviction timer) lives in a background agent. |
| Each `NSFileProviderDomain` gets its own Finder sidebar entry (under "Locations") named by `displayName`, and is mounted at `~/Library/CloudStorage/<AppName>-<DisplayName>`. Domains persist across reboots. | One domain per location. Naming is exactly what the spec wants. "Permanent sidebar presence" is free. |
| `NSFileProviderReplicatedExtension` (macOS 11+) keeps a system-side copy of the tree, calls us to fetch content, and marks items dataless until fetched. | On-demand download and offline browsing of already-seen folders are provided by the system, not by us. |
| The system handles retry/backoff when we throw `NSFileProviderError.serverUnreachable`. Pending local changes are held by the system and re-offered later. | Offline writes "just queue" if we fail fast and correctly. |
| `NSFileProviderManager.evictItem(identifier:)` and `enumeratorForMaterializedItems()` exist for the containing app and the extension. Reports show eviction fails for folders and for some files (`.nonEvictable`). | Evict files only, tolerate per-item failures, retry next cycle. |
| Finder gives third-party domains "Download Now" and "Remove Download" for free. Those are one-off actions; the downloaded copy is still evictable. Permanent "keep offline" is not a Finder feature for third-party providers: the extension declares it per item through `contentPolicy` (`.downloadEagerlyAndKeepDownloaded`, macOS 13+), and Apple's guidance is to use the policy rather than `requestDownloadForItem`. | Pinning is ours to implement (§6.5): store pin markers, return the policy for kept items, keep kept subtrees polled, and skip kept items in TTL eviction. |
| An extension can add its own Finder context-menu entries (`NSExtensionFileProviderActions` in the appex Info.plist, handled by `NSFileProviderCustomAction.performAction`). Each entry has a label and an `NSPredicate` activation rule evaluated over the selected items, including their `userInfo`. Finder's own "Remove Download" cannot be intercepted. | Pin/unpin get their own menu entries, shown conditionally on pin state (§6.6). Our entries set keep policy ("Keep Downloaded" / "Don't Keep Downloaded"); Finder's own "Download Now" / "Remove Download" are left alone. |
| SFTP has no change notifications and no stable file IDs. The SSH connection that carries it can also run commands on the server when the account has shell access. | Change detection is tiered (§5.4): SFTP polling always works; an exec channel unlocks a remote `find` sweep, `inotifywait`, or our own helper. We keep our own path → identifier index (§5.3). |
| Servers differ in which SFTP extensions they offer (`posix-rename`, `fsync`, `statvfs`, `limits`, `copy-data`) and whether exec is allowed. | Every server-dependent feature has a fallback, and `sshdrive status` shows which tier each feature is running at and what would upgrade it (§7.1). |
| Sandboxed extensions cannot reach `~/.ssh`, `ssh-agent`'s socket, or user config files. | Keys are copied into our group container at `add` time; passphrases and passwords live in a shared keychain access group. |
| App groups, keychain sharing, and File Provider entitlements require a real Team ID; Developer ID + notarization for installs outside the App Store. | Team `RWGDZAYBM8` is already in place. All identifiers derive from it and `org.shirls` (§3.1). |

**Minimum macOS:** 13 Ventura. Reason: `SMAppService` for the background agent
and a stable replicated-extension implementation. Develop and test on 14/15.

---

## 3. Components

```
SSH Drive.app                          (LSUIElement agent app, Developer ID signed, notarized)
├── Contents/MacOS/SSH Drive           host process: background agent (network monitor, eviction, XPC)
├── Contents/MacOS/sshdrive            the CLI (symlinked into PATH by the installer / Homebrew cask)
├── Contents/PlugIns/SSHDriveFileProvider.appex
│                                      File Provider extension: the SFTP <-> Finder bridge
├── Contents/Resources/helper/sshdrive-helper-<ver>-<os>-<arch>
│                                      static remote helper binaries + sha256 manifest (§5.4 tier 3)
└── Contents/Library/LaunchAgents/org.shirls.sshdrive.agent.plist
                                       registered via SMAppService.agent

Shared Swift package: SSHDriveCore
├── Config        location model, JSON store in the app-group container
├── Secrets       keychain wrapper (shared access group, data-protection keychain)
├── SFTP          transport abstraction + libssh2 implementation
├── Index         SQLite path <-> item identifier index, per domain
└── Logging       os.Logger subsystems, shared by all three processes
```

Why three executables:

- **Extension** — mandatory, sandboxed, ephemeral. Does only what the system
  asks: enumerate, fetch, create, modify, delete.
- **Agent** — a `SMAppService` login agent. Runs always, invisible. Owns the
  eviction loop, the network-path monitor, and remote change polling nudges.
  Also the XPC endpoint the CLI talks to for status.
- **CLI** — the only user interface. Lives inside the bundle so `Bundle.main`
  resolves to the app and `NSFileProviderManager.add(domain)` associates the
  domain with our extension. (Spike S1 confirms this; fallback is to proxy
  domain add/remove through the agent over XPC.)

Shared state lives in the app-group container
`~/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive/`:

```
config.json                  locations (no secrets)
keys/<location-id>/id_key    private key copied at `add` time (0600)
domains/<location-id>/
    index.sqlite             path <-> identifier map, versions, last-fetch times, pins
    hostkey                  pinned host key (TOFU)
```

Secrets (passwords, key passphrases) go in the keychain under access group
`RWGDZAYBM8.org.shirls.sshdrive`, keyed by location id, never in `config.json`.

### 3.1 Identifiers

| Thing | Value |
|---|---|
| Apple Developer Team ID | `RWGDZAYBM8` |
| App bundle (`SSH Drive.app`) | `org.shirls.sshdrive` |
| File Provider extension (`.appex`) | `org.shirls.sshdrive.fileprovider` |
| Background agent launchd label | `org.shirls.sshdrive.agent` |
| CLI executable | `sshdrive` (no bundle id of its own; signed as part of the app) |
| App group | `RWGDZAYBM8.org.shirls.sshdrive` (macOS app groups are Team-ID prefixed) |
| Keychain access group | `RWGDZAYBM8.org.shirls.sshdrive` (same string, listed under `keychain-access-groups`) |
| XPC mach service (agent ↔ CLI) | `RWGDZAYBM8.org.shirls.sshdrive.agent` (app-group prefixed so the sandboxed extension may also connect) |
| `os.Logger` subsystem | `org.shirls.sshdrive`, categories `extension`, `agent`, `cli`, `sftp` |
| Finder mount root | `~/Library/CloudStorage/SSHDrive-<DisplayName>` (derived by the system from the app name) |
| Homebrew cask | `ssh-drive`, in the tap `alecdwm/tap` (repo `alecdwm/homebrew-tap`, see §10.1) |
| Source repository | `https://github.com/alecdwm/sshdrive` |
| Domain identifier | the location's UUID (§4) |

Entitlements per target:

- Extension: `com.apple.security.app-sandbox`, `com.apple.security.network.client`,
  `com.apple.security.application-groups`, `keychain-access-groups`,
  `com.apple.developer.fileprovider.testing-mode` (debug builds only).
- App/agent and CLI: hardened runtime, `com.apple.security.application-groups`,
  `keychain-access-groups`. Not sandboxed (§9).

---

## 4. Location model

```jsonc
{
  "id": "6f1c…",                     // UUID, doubles as the File Provider domain identifier
  "nickname": "homelab",             // optional
  "host": "nas.tail1234.ts.net",
  "port": 22,
  "user": "alec",                    // defaults to the local username, like ssh(1)
  "remotePath": "/srv/media",        // optional; default is the SFTP realpath of "." (the user's home)
  "auth": {
    "method": "none" | "password" | "key",
    "keyPath": "keys/6f1c…/id_key", // present for "key"; relative to the group container
    "keyHasPassphrase": true         // passphrase itself is in the keychain
  },
  "hostKey": { "type": "ssh-ed25519", "fingerprint": "SHA256:…" },
  "sshConfig": {                     // §4.1: what was taken from ~/.ssh/config, if anything
    "alias": "nas",                  // the Host alias the user typed, if it resolved via ssh_config
    "fields": ["hostname", "user", "port", "identityfile"],
    "resolvedAt": "2026-09-02T14:02:11Z"
  },
  "cacheTTL": "1h",                  // 15m | 1h | 12h | 1d | 1w | 1mo | never
  "watchMode": "auto",               // auto | poll | sweep | inotify | helper (§5.4)
  "helper": true,                    // default on: deploy the remote helper where the server supports it (§5.4, tier 3)
  "pins": [                          // explicit pin states; nearest ancestor wins (§6.5.1)
    { "path": "Documents/thesis", "state": "pinned" },
    { "path": "Documents/thesis/raw-video", "state": "excluded" },
    { "path": "Photos/2026", "state": "pinned" }
  ],
  "mounted": true                    // whether a File Provider domain currently exists for it
}
```

Display name = `"SSH Drive - " + (nickname ?? host)`.

Notes on the spec:

- The spec lists hostname/IP + port but SSH also needs a username. We default
  to whatever `~/.ssh/config` says for the host (§4.1), then the local user,
  and accept `user@host:port` syntax.
- `remotePath` is an addition: without it every mount is the user's home
  directory, which is rarely what people want for a NAS.
- "No password" and "no key" together means auth method `none`. libssh2 sends
  the `none` request first anyway; if the server accepts (Tailscale SSH does),
  we're in without further prompting.

---

### 4.1 Reusing `~/.ssh/config`

Users who already have `Host nas` with `User`, `Port`, `HostName` and
`IdentityFile` in `~/.ssh/config` should not have to repeat any of it. The
extension cannot read that file (sandbox), and libssh2 does not parse it, so
the CLI resolves it once at `add` time and snapshots the result:

1. `sshdrive add nas` runs `ssh -G nas` (OpenSSH's own resolver, so `Include`,
   `Match`, wildcards and `~` expansion all behave exactly as they do for
   `ssh`). From its output it takes `hostname`, `port`, `user`,
   `identityfile` (in order), and notes `proxyjump`/`proxycommand`,
   `identityagent` and `certificatefile` if set.
2. Precedence is explicit flag > `ssh_config` > default. Anything taken from
   the config is recorded in `sshConfig.fields` so `sshdrive show` can say
   "user: alec (from ~/.ssh/config)".
3. If the user typed a config alias rather than a real hostname, the alias
   becomes the default nickname and is stored, so the location can be
   re-resolved later.
4. Identity files are tried in the order `ssh -G` lists them, skipping ones
   that do not exist (the defaults `~/.ssh/id_ed25519`, `id_ecdsa`, `id_rsa`
   are in that list even without an `IdentityFile` line). The first key the
   server accepts is copied into the group container. An encrypted key still
   needs its passphrase once: the extension has to hold the key itself, and
   `ssh-agent` cannot be reached from the sandbox, so the passphrase goes into
   the keychain as for any other key.
5. `~/.ssh/known_hosts` is consulted for the host key; a matching entry is
   pinned without prompting, otherwise the fingerprint is shown for approval.

Keeping the snapshot honest: the agent watches `~/.ssh/config` (and files it
`Include`s) with a dispatch source. When it changes, each location that has an
`sshConfig.alias` is re-resolved with `ssh -G`; if hostname, port, user or the
chosen identity file changed, `config.json` is updated and the domain's
connection is cycled. Values the user overrode with explicit flags are left
alone. `sshdrive show` reports the last resolve time, and `sshdrive set <name>
resync` forces one.

Not supported from `ssh_config` in v1, reported clearly by `add` rather than
silently ignored: `ProxyCommand` (needs to spawn a process from the sandbox),
`IdentityAgent`/agent forwarding, `CertificateFile` (libssh2 supports OpenSSH
certificates only with a workaround, revisit), and `ProxyJump`. `ProxyJump`
is the one worth adding later: libssh2 can open a `direct-tcpip` channel
through the jump host and run the second session over it, which covers the
common bastion setup without any process spawning.

## 5. The File Provider extension

### 5.1 Responsibilities

Implements `NSFileProviderReplicatedExtension` for one domain per process
instance. The system asks us for:

| System call | What we do over SFTP |
|---|---|
| `enumerator(for: container)` | `opendir/readdir` the mapped path, return items with attributes. |
| `enumerator(for: .workingSet)` | Return items changed since the anchor, from the polling diff (§5.4). |
| `item(for: identifier)` | `stat` the mapped path. Every item we return carries `contentPolicy`: `.downloadEagerlyAndKeepDownloaded` if the item is kept, `.downloadLazily` if it carries an exclusion, else `.inherited` (§6.5.1; domain default is lazy). |
| `fetchContents(for:)` | Download to the system-provided temp URL, then hand it back. Use partial-content fetching for range requests when the system asks (large media files). |
| `createItem` | `mkdir` or upload-to-temp + `rename` into place. |
| `modifyItem` | Depending on `changedFields`: rename/move (`rename`), content (upload + `rename`), attributes (`setstat` mtime). |
| `deleteItem` | `rmdir` (recursive if requested) or `remove`. |
| `materializedItemsDidChange` | Record timestamps used by eviction. |

Every SFTP failure classified as network-related (connect timeout, EOF,
`ENETUNREACH`, DNS) becomes `NSFileProviderError(.serverUnreachable)` so the
system queues and retries. Auth failures become `.notAuthenticated`; the domain
then shows as needing attention and `sshdrive status` explains why.

### 5.2 Connection handling

- One `SFTPSession` actor per domain process, lazily connected, with a small
  pool (2–4 channels) so a long download doesn't block directory listings.
- Keepalive every 30 s; reconnect with jittered backoff on drop.
- **Fail fast when offline.** Before any remote call, consult the agent's
  current network reachability (shared via a tiny file/mach notification) or
  our own `NWPathMonitor`. If unreachable, throw `.serverUnreachable`
  immediately. Waiting for a TCP timeout freezes Finder.
- Host key: compare against the pinned fingerprint; mismatch is a hard error
  surfaced as `.notAuthenticated` plus a clear message in `sshdrive status`.

### 5.3 Item identifiers

SFTP gives us paths, not IDs. The File Provider system needs identifiers that
stay stable across renames. We keep a per-domain SQLite index:

```
items(identifier TEXT PK, path TEXT UNIQUE, parent TEXT, type, size, mtime,
      content_version TEXT, last_fetch REAL, deleted_at REAL,
      pin_state INTEGER DEFAULT 0,   -- 0 inherit, 1 pinned, -1 excluded (§6.5.1)
      hidden INTEGER DEFAULT 0,      -- 1 for symlinks omitted from enumeration (§5.7)
      dirty INTEGER DEFAULT 0)
anchors(seq INTEGER PK, changed_identifier TEXT, change_kind TEXT)
```

- Identifier = UUID minted the first time we see a path.
- Rename/move initiated by the user (via `modifyItem`) updates `path` and keeps
  the identifier.
- Renames done remotely (outside Finder) appear as delete + create; without
  inodes from SFTP v3 that's the best we can do, and Finder copes.
- `content_version` = `"\(size)-\(mtime)"`, exposed as
  `NSFileProviderItemVersion.contentVersion`. Metadata version = same plus
  permissions.

### 5.4 Remote change detection

SFTP cannot push changes, but the SSH connection can run commands on the
server when the account has shell (exec) access. Change detection therefore
has four tiers. All tiers produce the same thing: a set of "dirty" remote
paths that the extension re-`stat`s over SFTP, diffs against the index, and
turns into working-set anchors for the system. Nothing on the File Provider
side knows which tier is active.

| Tier | Mode | Needs on the server | Latency | Cost per cycle |
|---|---|---|---|---|
| 0 | `poll` | SFTP only | poll interval | one `readdir` per known directory, over the network |
| 1 | `sweep` | exec + `find` (GNU, BSD or busybox) | poll interval | one command; server walks the tree locally |
| 2 | `inotify` | exec + `inotifywait` (Linux) or `fswatch` (macOS/BSD) | ~1 s | idle stream; nothing per cycle |
| 3 | `helper` | exec + a writable directory + a supported OS/arch | ~1 s | idle stream; server-side batching and filtering |

**Scope.** Every tier tracks the same set of roots: directories the user has
enumerated (the working set, non-recursive) and pin roots (recursive,
skipping excluded subtrees). Directories never listed and not kept are
ignored by every tier. Roots
change as the user browses; tiers 2 and 3 are restarted, debounced by a few
seconds, when the root set changes.

**Selection.** `watchMode: auto` (the default) tries the tiers from the top:
helper first, then inotify, then sweep, then poll, settling on the first one
that starts successfully. The helper is enabled by default and is skipped only
when the server cannot run it (no exec, no writable directory, unsupported
OS/arch, upload or hash check failed) or the user has set `helper off` for the
location. A tier that fails at runtime (stream dies with a non-network
error, `inotifywait` reports a watch-limit or queue-overflow, `find` is
missing) drops the location one tier down for the rest of the session and
records why, which `sshdrive status` shows. Setting `watchMode` to a specific
tier disables the fallback ladder except to `poll`, which always works. On
reconnect after any outage every tier first runs one full sweep (tier 1, or
tier 0 if exec is unavailable) so changes made while disconnected are caught,
then resumes streaming.

**Schedule for tiers 0 and 1.** The agent nudges the extension over XPC every
60 s while the user has recently touched the domain, every 10 min otherwise,
and immediately on network-up. Tiers 2 and 3 replace the schedule with
events; the agent still triggers a sweep every 30 min as insurance against
missed events.

#### Tier 0: SFTP poll

`readdir` every root, compare name/size/mtime against the index. This is the
only tier available to SFTP-only accounts (chrooted `internal-sftp`), and the
final fallback for everyone else.

#### Tier 1: remote sweep

One exec-channel command per cycle, on the same SSH connection:

```
find <roots…> -xdev \( -type d -o -type f \) -newermt @<ts> -print0
```

Working-set roots are passed with `-maxdepth 1`, pin roots without (excluded
subtrees are pruned with `-path … -prune`). Both
files and directories are matched: a directory's mtime changes on create,
delete and rename inside it, but an in-place edit changes only the file's own
mtime, so the file test is needed too. `<ts>` is taken from the server's own
clock (`date +%s` in the same command) at the previous sweep, minus a 2-second
overlap; duplicates are harmless because the result is diffed anyway. Busybox
`find` lacks `-newermt`; the probe detects this and switches to `-mmin -N`
with the same overlap. The returned paths (usually a handful) are `stat`ed
over SFTP and diffed.

#### Tier 2: inotify / fswatch

```
inotifywait -m -r -q --format '%e|%w|%f' \
  -e create,delete,modify,close_write,moved_from,moved_to,attrib <pin roots…>
inotifywait -m    -q --format '%e|%w|%f' -e … <working-set roots…>
```

Two long-running processes on one exec channel each (recursive for pin
roots, flat for the working set), stdout parsed line by line into dirty paths
and coalesced for 500 ms before the extension is signalled. `moved_from` /
`moved_to` pairs with the same cookie are treated as a rename, which lets us
keep the item identifier instead of delete+create. Watch-limit errors
(`max_user_watches`), queue overflow, or the process exiting drop the tier to
`sweep` with a status note. Remote NFS/FUSE mounts produce no events; the
30-minute insurance sweep and the reconnect sweep cover that.

On macOS/BSD hosts `fswatch -r -0 --event-flags` plays the same role with the
same parsing shape.

#### Tier 3: remote helper (default where supported)

A single static binary, `sshdrive-helper`, built from this repo in Rust for
`linux/x86_64`, `linux/aarch64`, `darwin/arm64` and `freebsd/x86_64`, embedded
in `SSH Drive.app`. Deployment happens over the existing connection:

1. Probe `uname -sm` and a writable directory: `$XDG_CACHE_HOME/sshdrive`,
   else `~/.cache/sshdrive`, else `/tmp/sshdrive-<uid>`.
2. Upload `sshdrive-helper-<version>-<os>-<arch>` over SFTP if
   `sha256sum`/`shasum` of the remote copy does not match the hash embedded in
   the app. The version is tied to the app release; upgrades happen the same
   way, and stale versions in the directory are removed.
3. Run `<path>/sshdrive-helper watch --json --roots-from-stdin` on an exec
   channel, feed it the root set, and read NDJSON events:
   `{"op":"create|modify|delete|rename|overflow","path":…,"from":…}` plus a
   heartbeat every 15 s.

What it adds over tier 2: inotify/kqueue used directly (no watch tool to
install), root-set changes applied live without a restart, server-side
coalescing and ignore rules (`.git`, editor temp files), an `overflow` event
that makes the extension run a sweep rather than silently missing changes, and
a `sweep` subcommand that does tier 1's job with size/mtime included so no
follow-up `stat`s are needed. It never listens on a socket, never runs
detached, and exits when its stdin closes, so a dropped connection leaves
nothing behind.

The helper is on by default and is the first thing `auto` tries, because it
is the most reliable push mechanism and needs nothing installed on the server.
Since it does place our code on the remote machine, `sshdrive add` states
this plainly in its output ("SSH Drive will upload a small helper binary to
~/.cache/sshdrive on this server to watch for changes; disable with
`sshdrive set <name> helper off`"), and `sshdrive status` shows the exact
remote path and version in use. `helper off` stops it and removes the binary
on the next connection; `helper on` re-enables it. Deployment failures are
never fatal: the location silently continues at the next tier and the status
report says why the helper is not running.

### 5.5 Writes, conflicts, atomicity

- Uploads go to `<dir>/.sshdrive-upload-<uuid>` then `rename` over the target
  (using the `posix-rename@openssh.com` extension when the server offers it so
  overwrite is atomic; otherwise `remove` then `rename`, a non-atomic window
  that `sshdrive status` reports as a degraded capability, §7.1).
- Before uploading in `modifyItem`, `lstat` the target. If the remote
  `content_version` differs from the `baseVersion` the system passed us, the
  remote changed underneath the user. Policy: upload the local content as
  `<name> (conflicted copy from <hostname> <date>).<ext>` beside it, report the
  remote item as current, and log. This mirrors Dropbox/OneDrive behaviour and
  never loses data.
- Deletes of non-empty directories: refuse unless the system passed the
  recursive option; then depth-first remove.

### 5.6 Offline behaviour, end to end

| Situation | What happens |
|---|---|
| Open a file already downloaded, network down | Reads served by the system from local storage. We are not called. |
| Browse a folder listed before, network down | Served from the system's replica. We are not called. |
| Browse a never-listed folder, network down | We throw `.serverUnreachable` instantly; Finder shows the folder as unavailable. |
| Save a file, network down | System stores it locally, marks it "waiting to upload", calls `modifyItem` again on retry. We fail fast until the agent reports network-up, then it flushes. |
| Network returns | Agent's `NWPathMonitor` fires → nudges the extension → `signalEnumerator`, and calls `NSFileProviderManager.reconnect()` if we had used `disconnect(reason:)` to show a status line. |
| Laptop wakes from sleep | Same path as network returns. |

We deliberately do not use `disconnect(reason:)` as the primary mechanism;
throwing `.serverUnreachable` is enough and keeps the domain writable. The
agent may call `disconnect` with a human message only for auth/host-key
failures, where retrying is pointless until the user runs `sshdrive`.

---

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
server: join the link's own directory with its target string, collapse `.`
and `..`, and require the result to remain at or below the location root.
Absolute targets fail that test by definition. Links that pass are native
symlinks on the Mac carrying the target string verbatim; links that fail are
**omitted from enumeration entirely**, logged at debug level, and otherwise
ignored. An absolute or escaping server path has no meaning inside a File
Provider mount, and a broken link in Finder would only invite questions.

| Remote link | On the Mac |
|---|---|
| relative, target resolves lexically inside the root | native symlink, same target string. Resolves inside the mount; dangling if the target does not exist yet, which is fine, it may appear later |
| relative, target climbs above the root | not listed |
| absolute | not listed |

The check is per link, not per chain: `a -> b` is judged on `b`'s location,
not on where `b` itself points. If `b` is then hidden because it escapes,
`a` shows up on the Mac as a dangling link. Resolving chains would require
following links, which §9.1 forbids; the dangling `a` is the honest result.

**Name collisions with hidden links.** A hidden link still occupies its name
on the server, so a Mac-side create or rename to that name has to be handled
rather than silently replacing the link:

- The check costs no extra round trips. Hidden links are recorded in the
  index when their directory is enumerated (a row with `hidden = 1`), and the
  parent of any new item has necessarily been enumerated, so a `createItem`
  or a rename/move first consults the index locally. If the name is held by a
  hidden link, the operation fails immediately with `EEXIST`. The system
  keeps the new item local with an error badge and Finder's usual "name
  already in use" message; `sshdrive status` lists it under sync errors as
  "name taken by a hidden symlink on the server", and the user renames it or
  fixes the link server-side.
- A hidden link that appeared *after* the last enumeration is caught by the
  server instead: the final step of a create, and every rename/move, uses the
  **non-overwriting** SFTP `rename`, which fails atomically if anything
  exists at the destination (OpenSSH implements it as `link` + `unlink`).
  The failure maps to the same `EEXIST` path. `posix-rename@openssh.com`,
  which overwrites, is used only when overwriting is the intent: replacing
  the contents of a file we already know (§5.5). That `modifyItem` path
  already `stat`s the target for the conflict check; it is an `lstat`, so a
  known file that has since turned into a link is noticed by the same call.
  On servers whose plain `rename` overwrites (the probe tests this once in a
  scratch directory), the extension falls back to an `lstat` preflight and
  `sshdrive status` shows the cost (§7.1).
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
  extension issues an SFTP `symlink` with the string unchanged. Otherwise it
  is refused with `EINVAL` and a message saying the target must be a relative
  path inside the share, since the resulting link would be hidden the moment
  it was created. Finder itself cannot create symlinks; it creates alias
  files, which upload as regular files. Converting those into remote
  symlinks is listed in §14.
- Renaming or moving a link moves the link only; the target string is not
  rewritten, matching `mv` on the server. Before the move, the target is
  re-checked from the *destination* directory. If it would escape the root
  there, the `modifyItem` is refused with `EINVAL` and the same message as
  for creation, and the system puts the link back where it was. Allowing the
  move and then hiding the result would be a way to plant an escaping link
  on the server through the mount, which creation already forbids. The same
  check applies to copies, since Finder copies a link by creating a new one.

## 6. Cache eviction (TTL)

Requirement: content downloaded to the Mac is dropped after the location's
TTL unless it has been used again.

Design (runs in the **agent**, not the extension, because it needs to be on a
timer and the extension is short-lived):

1. Every 5 minutes, for each mounted domain with `cacheTTL != never`:
   `NSFileProviderManager(for: domain).enumeratorForMaterializedItems()`.
2. For each materialized **file** (skip directories; folder eviction is known
   to fail): determine last use = max(atime of the user-visible file,
   `last_fetch` from the index). The agent is not sandboxed, so it can `stat`
   `~/Library/CloudStorage/SSHDrive-…/path` directly. atime is a best-effort
   signal (verify it advances on read on the target macOS versions — spike S4);
   `last_fetch` is the fallback and is always present.
3. If `now - lastUse > TTL` and the item is not pending upload (check via the
   index's dirty flag maintained by the extension), call `evictItem`. Ignore
   `.nonEvictable`; log and move on.
4. `sshdrive evict <location> [path]` triggers the same routine on demand,
   with `--all` to drop everything cached.

TTL values map to seconds: `15m`, `1h`, `12h`, `1d`, `1w`, `1mo` (30 days),
`never`. Default: `1d`.

Kept items (§6.5.1) are never evicted: the agent derives each item's
effective state from the `pin_state` markers on it and its ancestors before
evicting. A file the user fetched
with Finder's built-in "Download Now" is treated like any other cached file
and falls under the TTL; use `sshdrive pin` to keep it.

### 6.5 Pinning: keep a folder fully offline

Two words are used strictly throughout this document:

- **pinned** / **excluded** are *markers* the user places on a path with
  `sshdrive pin` / `sshdrive unpin` (or the Finder entries). They are what
  gets stored.
- **kept** is the *effect* on an item: whether the nearest marker at or above
  it is a pin. Kept is what the system, the eviction loop, the badge and the
  Finder menu act on. Every pinned item is kept; most kept items are not
  pinned, they inherit it.

What Finder provides on its own for a third-party domain is limited to
"Download Now" (materialize once) and "Remove Download" (evict once). There is
no built-in "always keep on this Mac" for third-party providers; OneDrive,
Google Drive and Nextcloud each implement their own. We do too, through the
framework's declarative `contentPolicy`:

1. **Store the pin.** `sshdrive pin <location> <remote-path>`, or the Finder
   "Keep Downloaded" entry (§6.6), writes the path into `config.json` and sets
   `pin_state = 1` on the matching row (creating it if the path has not been
   enumerated yet). Pins are on paths, so they survive the index being rebuilt.
2. **Declare the policy.** The extension returns
   `contentPolicy = .downloadEagerlyAndKeepDownloaded` for items whose
   effective state (§6.5.1) is kept, `.downloadLazily` for excluded ones,
   and `.inherited` for everything else. On any pin-state change the extension
   bumps the metadata version of the affected item and signals the working-set
   enumerator so the system re-reads the item and applies the new policy. The
   system then downloads the subtree eagerly (through our normal
   `fetchContents`), shows it as downloaded in Finder, and refuses to evict it.
3. **Keep it current.** The change-polling cycle (§5.4) walks kept subtrees
   every time, not only when the user has been browsing. New or changed remote
   files show up in the working-set diff, the system sees the eager policy,
   and fetches them.
4. **Unpin.** `sshdrive unpin` on an explicitly pinned item clears it and
   every explicit state beneath it; on an item that merely inherits a pin it
   records an exclusion instead (§6.5.1). Either way the content stays on disk
   and becomes subject to the location's TTL from that moment.
5. **Eviction skips kept items** (§6 step 3) and so does `sshdrive evict
   --all`, unless `--unpin-all` is passed, which removes every pin first.

#### 6.5.1 Nested items: one rule

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
   ancestor wipes it. So such redundant markers are never created.

Because of invariant 3 there are only two user-facing operations, `pin`
("keep downloaded") and `unpin` ("don't keep downloaded"), and each item is
in exactly one of five situations:

| Situation | Nearest marker at or above | Kept? | `pin` / Keep Downloaded | `unpin` / Don't Keep Downloaded |
|---|---|---|---|---|
| A. plain | none | no | writes `pinned` here; subtree cleared | no-op (CLI says so; Finder hides the entry) |
| B. pin root | `pinned`, on this item | yes | CLI only: re-asserts the pin, clearing the subtree (the one-command reset). Finder hides the entry. | removes the pin; subtree cleared; content stays and goes under the TTL |
| C. inheriting a pin | `pinned`, on an ancestor | yes | no-op (CLI names the covering ancestor; Finder hides the entry) | writes `excluded` here; subtree cleared; ancestor and siblings untouched |
| D. exclusion | `excluded`, on this item | no | removes the exclusion, so the item is kept by the ancestor's pin again; subtree cleared | no-op |
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
  exclusions and 1 nested pin)".
- Exclusions can nest: pin `Projects`, exclude `Projects/archive`, re-pin
  `Projects/archive/2026`. Each level wins over the one above it.
- The change-polling walk of kept subtrees (§5.4) skips excluded subtrees.
- The eviction loop (§6) uses the kept state, so an excluded file inside a
  kept folder is evicted like any other cached file.
- `userInfo.kept` (used by the Finder menu predicates, §6.6) and the badge
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

Costs to be aware of: a kept folder is downloaded in full, and each poll
cycle `stat`s every directory in it over SFTP. Deeply nested pins on slow links
are the main performance risk; `sshdrive pins` reports subtree size and file
count so the user can see what they've signed up for.

### 6.6 Pinning from Finder's context menu

The CLI is the source of truth, but the natural place to pin a folder is the
folder itself. Two custom File Provider actions provide that, declared in the
extension's Info.plist and handled in the extension by
`performAction(identifier:onItemsWithIdentifiers:)`. No window, no UI
extension: Finder renders the menu items and calls us.

Every item the extension returns carries `userInfo = ["kept": 0|1]`, its
kept state from §6.5.1 (1 when the nearest marker at or above it is a pin).
The activation rules read it:

| Menu label | Shown when | Handler |
|---|---|---|
| **Keep Downloaded** | at least one selected item is not kept: `SUBQUERY(FILEPROVIDER_ITEMS, $item, $item.userInfo.kept == 0).@count > 0` | `sshdrive pin` semantics (§6.5.1, situations A, D, E) for each selected item that is not kept; kept items in the selection are skipped. Bump metadata versions, signal the working set; the system then eagerly downloads. |
| **Don't Keep Downloaded** | at least one selected item is kept: `SUBQUERY(FILEPROVIDER_ITEMS, $item, $item.userInfo.kept == 1).@count > 0` | `sshdrive unpin` semantics (situations B, C) for each selected kept item: remove the pin if it is the pin root, otherwise record an exclusion. Not-kept items are skipped. No eviction. |

Two labels, one concept. The entries are worded as a policy ("keep" / "don't
keep") rather than an action on the current download, so they read as a pair
and never collide with Finder's built-in "Download Now" / "Remove Download",
which we leave entirely to Finder. The division of labour is:

- **Our entries set policy.** "Keep Downloaded" makes the item and its
  subtree eager and non-evictable. "Don't Keep Downloaded" returns it to
  lazy; the content stays on disk and falls under the location's TTL.
- **Finder's entries act now.** "Download Now" materializes an unkept item
  once; "Remove Download" evicts an unkept item immediately. On a kept item
  the eager policy makes Finder hide or fail its "Remove Download", so a user
  who wants space back chooses "Don't Keep Downloaded" first and then Finder's
  "Remove Download", or waits for the TTL.

Mixed selections show both entries, and each acts only on the items it
applies to, so selecting a kept folder together with a plain file and
choosing "Keep Downloaded" pins the file and leaves the folder alone. An item
inside a kept folder shows only "Don't Keep Downloaded", which excludes just
that item (§6.5.1 situation C); the folder keeps its badge, the excluded item
loses it, and "Keep Downloaded" on it later removes the exclusion (situation
D). Whether an item's kept state is its own pin or inherited is deliberately
not visible in Finder, since by invariant 3 the two never behave differently;
`sshdrive pins` shows the markers for anyone who wants them.

Spike S6 records what Finder actually shows for kept and unkept items, in
particular whether the built-in "Remove Download" is hidden or merely fails
on a kept item. If it can still succeed, `materializedItemsDidChange` is the
safety net: a kept file turning dataless without our handler having run is
treated as "Don't Keep Downloaded", debounced per pin root so a folder
eviction arriving one child at a time results in a single change. Otherwise
that code path stays dormant.

Kept items also get a **decoration**: a small pin badge declared under
`NSExtensionFileProviderDecorations` in the Info.plist and attached via
`decorations` on the item, so kept folders are visibly different in Finder.

---

## 7. The CLI: `sshdrive`

Built with `swift-argument-parser`. All prompts use a hidden tty read and can
be avoided for scripting with flags or stdin.

```
sshdrive add [user@]host-or-alias[:port] [--nickname NAME] [--remote-path PATH]
             [--password | --password-stdin | --no-password]
             [--key PATH] [--cache-ttl 1h] [--accept-hostkey FINGERPRINT|--trust-first]
             [--no-ssh-config]
        Resolves the host through ~/.ssh/config first (§4.1), so
        `sshdrive add nas` is enough when User/Port/IdentityFile are already
        configured there; flags override, --no-ssh-config skips it. Connects
        once to verify, shows the host key fingerprint and asks to trust it
        (auto-trusts if known_hosts already has it, or with --trust-first),
        stores credentials, copies the chosen key into the group container,
        then adds the File Provider domain. If the key is encrypted, prompts
        for its passphrase and stores it in the keychain.

sshdrive list                     table: name, host, auth, mounted, TTL, state
sshdrive show <name>              full detail incl. mount path and last error
sshdrive remove <name>            removes domain + config + key + keychain entries
sshdrive mount <name> / unmount <name>
                                  add/remove the File Provider domain without
                                  forgetting the location
sshdrive set <name> nickname|cache-ttl|remote-path|port|user|watch-mode|helper <value>
                                  nickname changes re-create the domain (the
                                  sidebar name is fixed at domain creation), so
                                  they are refused while uploads are pending;
                                  watch-mode: auto|poll|sweep|inotify|helper (§5.4);
                                  helper on|off: allow the remote helper (default on, §5.4 tier 3)
sshdrive passwd <name>            re-prompt and replace stored password / passphrase
sshdrive set <name> resync        re-read ~/.ssh/config for this location now (§4.1)
sshdrive test <name>              connect + list root, print timing, run the
                                  capability probe and print the report (§7.1)
sshdrive status [<name>] [--json] [--probe]
                                  per-domain state and the capability report (§7.1);
                                  --probe re-runs the server probe instead of
                                  using the cached result
sshdrive evict <name> [path] [--all] [--unpin-all]
sshdrive pin <name> <remote-path>
                                  keep a folder or file fully offline (§6.5); same
                                  effect as Finder's "Keep Downloaded" entry (§6.6)
sshdrive unpin <name> <remote-path>
                                  clears an explicit pin, or excludes the path if it
                                  inherits a pin from a folder above (§6.5.1)
sshdrive pins [<name>]            tree of pins and exclusions with cached size and file counts
sshdrive logs [--follow]          streams os_log for our subsystem
sshdrive doctor                   checks: extension registered (pluginkit), agent
                                  running, app group container writable, CLI on
                                  PATH, macOS version
sshdrive agent start|stop|restart
```

`<name>` resolves nickname, then host, then id prefix.

---

### 7.1 Capability report in `sshdrive status`

Several features run at different levels depending on what the remote server
offers. The probe runs on every extension connection and on `sshdrive test`
and `status --probe`; the result is cached in
`domains/<id>/capabilities.json` with a timestamp and the server banner. It
consists of the SFTP `extensions` list from the SFTP init reply, whether an
exec channel opens, and one shell command that reports
`uname -sm`, the `find` flavour, and the presence of `inotifywait`, `fswatch`,
`sha256sum`/`shasum` and a writable cache directory.

The catalogue of server-dependent features:

| Feature | Levels (best first) | What unlocks the next level |
|---|---|---|
| Change detection | helper · inotify · sweep · poll | shell access plus a writable directory for the helper; otherwise `inotify-tools`/`fswatch` on the server |
| Atomic overwrite | `posix-rename@openssh.com` · remove+rename | OpenSSH ≥ 4.9 or a server that offers the extension |
| Durable writes | `fsync@openssh.com` · none | OpenSSH ≥ 6.3 |
| Free-space in Finder | `statvfs@openssh.com` · unknown (Finder shows no capacity) | OpenSSH ≥ 5.1 |
| Server-side copy | `copy-data` · download+upload through this Mac | OpenSSH ≥ 9.0 |
| Transfer sizing | `limits@openssh.com` · conservative 32 KB requests | OpenSSH ≥ 8.5 |
| Rename detection | rename events (tiers 2–3) · delete+create | any push tier |
| Collision-safe create | server-enforced (non-overwriting `rename` fails on an existing name) · `lstat` preflight, one extra round trip per create/rename | a server whose plain `rename` refuses to overwrite, as OpenSSH does |

Every line in the report follows one shape so all permutations read the same
way: a level glyph, the feature name, the level in use, and, whenever the
level is not the best one, an indented `upgrade:` line naming the concrete
requirement. Glyphs: `●` best available level, `◐` a fallback is in use, `○`
the feature is off entirely. A summary counts how many features are at `●`.

```
$ sshdrive status
nas    alec@nas.tail1234.ts.net:22   mounted  online   2 pending uploads   cache 1.2 GB / TTL 1d
       capabilities 5/7 optimal, 2 upgradeable          probed 3m ago
work   alec@build.example.org:22     mounted  offline since 14:02   0 pending   cache 210 MB / TTL 1h
       capabilities poll-only (SFTP-only account), 6 upgradeable   probed 2h ago (cached)

$ sshdrive status nas
SSH Drive - nas
  Server    alec@nas.tail1234.ts.net:22   OpenSSH_9.6   Linux x86_64   shell access: yes
  State     mounted at ~/Library/CloudStorage/SSHDrive-nas   online   last change 12s ago
  Auth      key ed25519 (passphrase in keychain)   host key SHA256:Kx3…9Qw pinned 2026-09-02
  Sync      2 pending uploads (14.1 MB)   0 conflicts   last error none
  Cache     1.2 GB materialized (312 files), 480 MB kept   TTL 1d   next eviction sweep in 3m
  Pins      Documents/thesis   Photos/2026

  Capabilities  5/7 optimal   probed 3m ago
  ● change detection   helper 1.2.0 at ~/.cache/sshdrive (push, ~1s)   watch-mode auto
  ● atomic overwrite   posix-rename@openssh.com
  ● durable writes     fsync@openssh.com
  ● free-space         statvfs@openssh.com
  ◐ server-side copy   copying through this Mac
        upgrade: copy-data extension (OpenSSH ≥ 9.0); server is OpenSSH_9.6 with copy-data disabled
  ◐ transfer sizing    conservative 32 KB requests
        upgrade: limits@openssh.com (OpenSSH ≥ 8.5) — server does not advertise it
  ● rename detection   inotify move events

$ sshdrive status work
SSH Drive - work
  Server    alec@build.example.org:22   OpenSSH_8.2   unknown OS   shell access: no (SFTP-only account)
  …
  Capabilities  1/7 optimal   probed 2h ago (cached; offline)
  ◐ change detection   poll (SFTP readdir every 60s while active)
        upgrade: shell access on the server enables the helper (push); without a writable directory, inotify-tools also enables push, and plain shell access enables remote sweep
  ◐ atomic overwrite   remove + rename (brief window where the file is absent)
        upgrade: posix-rename@openssh.com (OpenSSH ≥ 4.9) — server did not advertise it
  ◐ durable writes     none; uploads are complete when the server acknowledges the write
        upgrade: fsync@openssh.com (OpenSSH ≥ 6.3)
  ● free-space         statvfs@openssh.com
  ◐ server-side copy   copying through this Mac
        upgrade: copy-data extension (OpenSSH ≥ 9.0)
  ◐ transfer sizing    conservative 32 KB requests
        upgrade: limits@openssh.com (OpenSSH ≥ 8.5)
  ◐ rename detection   delete + create (identifiers not preserved on remote renames)
        upgrade: any push tier for change detection
```

Rules that keep the format stable across permutations:

- A runtime downgrade (for example inotify hit the watch limit and fell back
  to sweep) shows the level in use with `◐` and a `note:` line giving the
  reason and time, in addition to the `upgrade:` line.
- A user-forced `watch-mode` below the best available shows `◐` with
  `note: forced by watch-mode <x>` and no `upgrade:` line, since the user
  chose it.
- When the helper is not the active tier on a server with shell access, the
  change-detection line carries a `note:` saying why: `helper off (user
  setting)`, `helper unsupported: <os>/<arch>`, `no writable directory for
  helper`, or `helper upload failed: <reason>`. The `upgrade:` line then
  names the fix, so a user who turned it off sees `sshdrive set nas helper on`
  and a user on an unsupported platform sees the request to file an issue
  with the `uname -sm` output.
- `--json` emits the same data: an array of `{feature, level, best, glyph,
  upgrade, note}` objects plus the probe timestamp, for scripting.
- When offline, the cached probe is shown with "(cached; offline)" and no
  guesses are made about what changed.

## 8. SSH / SFTP transport

**Decision: libssh2**, statically linked with an mbedTLS backend, built into an
XCFramework by a script in the repo and consumed through a SwiftPM binary
target. A thin Swift wrapper (`SFTPSession` actor) hides the C API.

Why not the pure-Swift options:

- `swift-nio-ssh` does include the `none` auth offer, but has no SFTP layer.
- Citadel adds SFTP on top of it, but its README states RSA authentication is
  "implemented & supported, but in a fork of NIOSSH", and it does not document
  encrypted OpenSSH private keys. RSA keys and passphrase-protected keys are
  both in our requirements.
- libssh2 has been the SFTP client under many products for 15+ years, handles
  `none`/password/publickey, OpenSSH-format and encrypted keys (with the
  OpenSSL or mbedTLS backend), ed25519/ECDSA/RSA, and SFTP extensions we want
  (`posix-rename`, `statvfs`, `fsync`, `limits`, `copy-data`), and exec
  channels on the same session for the change-detection tiers (§5.4).

The transport sits behind a `protocol SFTPTransport` so a Swift-native
implementation can replace it later without touching the extension.

Bundling note: the Homebrew `libssh2` dylib is not redistributable inside a
notarized app; the repo builds its own.

---

## 9. Security

- Sandbox on the extension (required). Agent and CLI not sandboxed (they need
  `~/.ssh` at `add` time and CloudStorage paths for eviction).
- Hardened runtime on all executables; notarized.
- Keys copied into the group container with mode 0600; original left untouched.
  Only the key actually used is copied, never every identity `ssh -G` lists.
- Passwords/passphrases only in the keychain, `kSecAttrAccessible =
  afterFirstUnlock`, shared access group so extension, agent and CLI all read
  the same items.
- Host keys pinned on first use; `sshdrive add` prints the fingerprint and can
  import a matching line from `~/.ssh/known_hosts` if one exists.
- Logs never contain paths' file content or credentials; hostnames and paths
  are `privacy: .private` in `os.Logger`.
- Remote access never leaves the location root; see §9.1.
- The remote helper (§5.4 tier 3) is on by default; `sshdrive add` says so
  when a location is created and `helper off` disables it per location. It is
  verified by SHA-256 against a hash embedded in the app before every launch,
  runs as the SSH user with no elevated rights, opens no sockets, writes only
  to its own cache directory, and exits when the connection drops.

---

### 9.1 Path containment

Nothing the extension, agent, helper or CLI does on the server may touch a
path outside the location's `remotePath`. Symlink policy (§5.7) is one piece
of that; the rest follows.

**One chokepoint for every remote path.** The SFTP layer has no API that
takes a string path. Every operation takes a `RelativePath`, a value type
that can only be constructed from validated components, and the transport
joins it to the canonical root itself. A component is rejected if it is
empty, `.`, `..`, or contains `/` or NUL. Filenames arriving from the system
(`createItem`, `modifyItem` renames) and paths arriving from the CLI, the
sweep output, `inotifywait` and the helper all pass through that constructor
before anything else sees them, so an escape would have to be a bug in one
function rather than in any of the dozens of call sites.

**The root is canonical and verified.** At `add` time the root is resolved
with SFTP `realpath` and the canonical absolute path is stored. On every
connection the extension calls `realpath` on it again and refuses to operate
if the result differs (root deleted, or replaced by a symlink pointing
elsewhere); the domain goes into an error state that `sshdrive status`
explains rather than quietly serving whatever now sits at that path.

**Never descend through a link.** Enumeration uses `lstat` semantics, links
are leaf items, and the index never contains a path with a link as an
intermediate component. Recursive operations do their own walk from the
index and re-`lstat` each directory as they go, so a directory replaced by a
symlink after it was enumerated is noticed before anything is done inside
it. That check is mandatory for recursive delete, the one operation where
following a link would be destructive, and is one extra round trip per
directory, which is acceptable for a delete.

**Server-side tools are told the same root.** The sweep runs `find` without
`-L` (physical walk) and with `-xdev`; `inotifywait -r` does not follow
symlinks when recursing; the helper takes `--root` and refuses any watch or
sweep root that does not canonicalise to a path under it. Paths reported
back by any of them are validated for the root prefix and passed through the
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

## 10. Packaging and install

- Xcode project with three targets plus the `SSHDriveCore` local package.
- CI: `xcodebuild archive`, Developer ID sign, `notarytool`, staple, DMG.
- Homebrew cask: installs `SSH Drive.app` and links `sshdrive` from inside the
  bundle via the cask `binary` stanza. First `sshdrive` run registers the
  agent with `SMAppService` (macOS asks the user once to allow the login item;
  that system prompt is the only "UI" the user ever sees).

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
sshdrive add alec@nas.example.org --nickname nas
```

Release flow (GitHub Actions on a macOS runner, triggered by a `v*` tag):

1. `xcodebuild archive` → Developer ID sign (certificate and App Store Connect
   API key stored as repository secrets) → `notarytool submit --wait` → staple
   → DMG.
2. Upload DMG + sha256 to the GitHub Release.
3. Render `Casks/ssh-drive.rb` from a template with the new version, URL and
   sha256, and push it to `alecdwm/homebrew-tap` (a deploy key or fine-grained
   PAT for that one repo). `brew upgrade` then picks it up.
4. Publish the docs site (Pages deploys automatically from `main`).

The tap can be reused for any future casks or formulae of yours; that is why it
is named `homebrew-tap` rather than `homebrew-sshdrive`. If the project gains
enough users, the cask can later be submitted to the main `homebrew-cask`
repository, at which point `brew install --cask ssh-drive` works without the
tap.
- `pluginkit -a` registration happens automatically when the app bundle lands
  in `/Applications`; `sshdrive doctor` verifies it.

---

## 11. Spikes (do these first; each is a day or less)

| # | Question | Why it matters |
|---|---|---|
| S1 | Does `NSFileProviderManager.add(domain)` work when called from `Contents/MacOS/sshdrive` rather than the app's main executable? | Decides whether the CLI talks to File Provider directly or proxies via the agent over XPC. |
| S2 | libssh2 (mbedTLS backend) static XCFramework: builds, notarizes, authenticates with `none` against Tailscale SSH and with an encrypted ed25519 key against OpenSSH. | Validates the transport decision before anything is built on it. |
| S3 | Minimal replicated extension: list, open, save, rename against a real SFTP server; observe sidebar naming and mount path with two domains. Include a containment test: replace an enumerated directory with a symlink to `/etc` on the server and confirm nothing inside it is listed, fetched or deleted. | Confirms the naming scheme and multi-domain sidebar behaviour on macOS 14/15, and the §9.1 guarantees from the first build. |
| S4 | Does `evictItem` work for files in our domain, and does atime on materialized files advance on read? | Determines whether TTL eviction can use real last-access or only last-fetch. |
| S5 | Behaviour when throwing `.serverUnreachable` for writes: how long the system retries, and whether `NWPathMonitor` + `signalEnumerator` reliably wakes the flush. | The "no fuss across network drops" requirement rests on this. |
| S6 | Flip a folder's `contentPolicy` to `.downloadEagerlyAndKeepDownloaded` at runtime: does the system download the whole subtree after a working-set signal, do new files added remotely get fetched on the next poll, and does `evictItem` correctly refuse? Does an explicit `.downloadLazily` on a child override an eager ancestor (needed for exclusions, §6.5.1)? Record exactly which built-in menu items Finder shows for pinned vs unpinned items, whether the built-in "Remove Download" is hidden, fails, or succeeds on a pinned item, and whether custom actions with `userInfo`-based activation rules appear at the top level of the context menu or in an app submenu. | Pinning (§6.5) depends on the policy being honoured dynamically; the Finder menu design (§6.6) depends on how the system entry behaves on pinned items. |
| S7 | Run tier 1 and tier 2 (§5.4) over a libssh2 exec channel on a live session alongside SFTP traffic: does a long-running `inotifywait` stream coexist with SFTP channels on one connection, and how long does the `find` sweep take on a 1M-file tree with 200 roots? Check `-newermt` vs `-mmin` across GNU, BSD and busybox `find`. | Decides whether tiers 1–2 are practical on one connection or need a second SSH session, and sets the default poll interval. |
| S8 | Return an item with `contentType = .symbolicLink` and `symlinkTargetPath`: does the system create a real symlink under CloudStorage, does Finder badge it, does a relative target resolve inside the mount, how does Finder present a dangling one, does `ln -s` inside the mount reach `createItem` with the target intact so escaping targets can be refused, and what does the system do with a `createItem` that fails with `EEXIST` (error badge and local retention, or something else)? | Confirms §5.7 end to end, including the hidden-link name collision. |

---

## 12. Milestones

1. **Skeleton** — app bundle, extension, CLI, agent all sign and launch;
   `sshdrive doctor` green. Spikes S1–S3 folded in.
2. **Read-only** — `add` with `~/.ssh/config` resolution (§4.1), `list`,
   `remove`; browse and open files; host-key pinning; keychain-backed auth for
   all three methods.
3. **Read-write** — create/modify/delete/rename/move; temp-file + rename
   uploads; conflict copies; symlink handling (§5.7). Spike S8.
4. **Offline hardening** — fail-fast reachability, reconnect, queued-write
   flush on network-up, sleep/wake testing. Spike S5 findings applied.
5. **Change detection, tiers 0–2** — working-set enumeration, anchors,
   poll cadence, remote sweep, inotify/fswatch streams, fallback ladder,
   capability probe and the `status` report (§7.1). Spike S7.
6. **Eviction** — TTL agent loop, `sshdrive evict`, `set cache-ttl`. Spike S4.
7. **Pinning** — `pin`/`unpin`/`pins`, content policy, kept-subtree polling,
   eviction exclusion, Finder "Keep Downloaded"/"Don't Keep Downloaded" actions and
   the pin badge. Spike S6.
8. **Remote helper (tier 3)** — Rust helper binary, cross-compiled in CI,
   deploy/verify/upgrade over SFTP, NDJSON protocol, `helper on|off`. Until
   this ships, `auto` tops out at inotify.
9. **Ship** — notarized DMG, Homebrew cask, `logs`, docs.

---

## 13. Decisions

Questions that were open during drafting and how they were settled:

- **Nickname changes** re-create the domain, because the sidebar name is the
  domain's `displayName` and is fixed at creation. This drops the local cache
  and pending uploads, which is accepted; `set nickname` is refused while
  uploads are pending, and warns about the cache otherwise.
- **Remote path** defaults to the user's home directory (the SFTP realpath of
  `.`), the same as `sftp`. `--remote-path` overrides it.
- **Multiple locations on the same host** are allowed. Each is its own
  domain with its own nickname, credentials snapshot and cache, so two remote
  paths on one server are two sidebar entries.
- **ProxyJump** is out of v1 and recorded in §14. `sshdrive add` reports when
  an `ssh_config` entry relies on it.
- **Symlinks** are native symlinks, never followed, and shown only when
  their target stays inside the share by a lexical check; absolute or
  escaping links are ignored because a server path has no meaning inside the
  mount. A Mac-side item created under a hidden link's name fails with a
  clear error rather than replacing the link. Following links could turn one
  link into a download of the whole server. See §5.7.

---

## 14. Future work

Not planned for v1, recorded so the design leaves room for them:

- **ProxyJump.** libssh2 can open a `direct-tcpip` channel through a jump
  host and run the second session over it, with no process spawning, which
  covers the common bastion setup. Needs credentials for both hops in the
  keychain and the capability probe run against the final host.
- **Finder aliases as remote symlinks.** A `createItem` whose content type is
  an alias file could be resolved on the Mac side; if the bookmark points
  inside the same domain, create a remote symlink instead of uploading the
  alias file.
- **OpenSSH certificates** (`CertificateFile`) once the transport supports
  them cleanly.
- **Selective offline profiles**, such as "keep everything opened in the
  last 7 days", built on the same pin markers.
- **Server-side copy for Finder duplicates** is already in the capability
  catalogue (§7.1); using it for cross-location copies between two domains on
  the same server would be a further step.
- **Submitting the cask to homebrew-cask** so the tap is unnecessary.
