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
- Locally cached content is evicted after a per-location TTL (15m … 1 month)
  measured from the last time the file was read.
- Mounts survive reboots and network loss without user intervention. Offline,
  already-downloaded files stay readable and previously browsed folders stay
  listable. Writes queue and flush when the network returns.
- Auth is whatever the user's `ssh` already does: passwords, keys with or
  without passphrases, keys held by `ssh-agent`, 1Password or Secretive,
  FIDO keys, certificates, `ProxyJump`, or no credential at all (Tailscale
  SSH and similar). If `ssh nas` works in a terminal, `sshdrive add nas`
  works.
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
- A Trash. Deleting in Finder deletes on the server, after Finder's own
  "will be deleted immediately" confirmation (§5.4).
- Recognising renames made on the server as moves when only polling is
  available. They appear as delete + create (§6.4); push tiers report real
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
| Finder gives third-party domains "Download Now" and "Remove Download" for free. Those are one-off actions; the downloaded copy is still evictable. Permanent "keep offline" is not a Finder feature for third-party providers: the extension declares it per item through `contentPolicy` (`.downloadEagerlyAndKeepDownloaded`, macOS 13+). | Pinning is ours to implement (§7.1): store pin markers, return the policy for kept items, keep kept subtrees polled, and skip kept items in TTL eviction. |
| An extension can add its own Finder context-menu entries (`NSExtensionFileProviderActions` in the appex Info.plist, handled by `NSFileProviderCustomAction.performAction`). Each entry has a label and an `NSPredicate` activation rule evaluated over the selected items, including their `userInfo`. Finder's own "Remove Download" cannot be intercepted. | Pin/unpin get their own menu entries, shown conditionally on pin state (§7.2). |
| Items declare `capabilities` (`allowsWriting`, `allowsRenaming`, `allowsDeleting`, `allowsTrashing`, `allowsAddingSubItems`, …). Without `allowsTrashing`, Finder deletes immediately after a confirmation dialog. A Finder copy arrives as a plain `createItem` with content; there is no copy callback and no API for reporting remote free space. | No trash (§5.4). Permissions map to capabilities (§5.4). "Server-side copy" and "free space in Finder" are not features we can offer. |
| SFTP has no change notifications and no stable file IDs. The SSH connection that carries it can also run commands on the server when the account has shell access. | Change detection is tiered (§6.4): SFTP polling always works; an exec channel unlocks a remote `find` sweep, `inotifywait`, or our own helper. We keep our own path → identifier index (§5.3). |
| Servers differ in which SFTP extensions they offer (`posix-rename`, `fsync`, `statvfs`, `limits`) and whether exec is allowed. | Every server-dependent feature has a fallback, and `sshdrive status` shows which tier each feature is running at and what would upgrade it (§8.1). |
| macOS ships OpenSSH (9.x on macOS 13+). `ssh -s host sftp` opens the SFTP subsystem on stdio, `ControlMaster` multiplexes further channels over one connection, and `SSH_ASKPASS_REQUIRE=force` (OpenSSH ≥ 8.4) makes `ssh` fetch passwords and passphrases from a program of ours with no tty. | The transport is the system's `ssh` (§6.1). We implement the SFTP wire protocol ourselves (§6.2), which is small and gives us every extension and every request type. |
| App groups, keychain sharing, and File Provider entitlements require a real Team ID; Developer ID + notarization for installs outside the App Store. `SMAppService.agent` registers a login agent from the calling app's own bundle. | Team `RWGDZAYBM8` is already in place. All identifiers derive from it and `org.shirls` (§3.1). Registration is done by the app itself, launched once (§10). |

**Minimum macOS:** 13 Ventura. Reason: `SMAppService` for the background agent,
`contentPolicy` for pinning, and an OpenSSH new enough for
`SSH_ASKPASS_REQUIRE`. Develop and test on 14/15.

---

## 3. Components

```
SSH Drive.app                          (LSUIElement agent app, Developer ID signed, notarized)
├── Contents/MacOS/SSH Drive           host process: the background agent (SSH, SFTP, index,
│                                      change detection, eviction, XPC server)
├── Contents/MacOS/sshdrive            the CLI (symlinked into PATH by the Homebrew cask)
├── Contents/MacOS/sshdrive-askpass    SSH_ASKPASS program: answers ssh's prompts from the keychain
├── Contents/PlugIns/SSHDriveFileProvider.appex
│                                      File Provider extension: a thin XPC client of the agent
├── Contents/Resources/helper/sshdrive-helper-<ver>-<os>-<arch>
│                                      static remote helper binaries + sha256 manifest (§6.4 tier 3)
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

- **Extension** — mandatory, sandboxed, ephemeral. Translates each system
  call (enumerate, fetch, create, modify, delete) into one XPC call to the
  agent and translates the reply back. It holds no state, opens no sockets
  and no database. Its only file I/O is the temp file the system gives it
  for fetched content, whose path it hands to the agent to fill.
- **Agent** — a `SMAppService` login agent. Runs always, invisible. Owns the
  `ssh` processes, the SFTP sessions, the per-domain index, the change
  detection streams, the eviction loop, and the File Provider domain
  lifecycle (`add`, `remove`, `signalEnumerator`, `evictItem`). It is the
  only process that talks to `NSFileProviderManager` and the only writer of
  the index.
- **CLI** — the only user interface. A pure XPC client of the agent: every
  command is a request to the agent, so the CLI never touches the network,
  the keychain or File Provider. It can therefore be invoked through any
  path, including the Homebrew symlink. `sshdrive add` is the one command
  that runs `ssh` itself, interactively, to verify the location and collect
  secrets (§4.2).

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
config.json                  locations (no secrets)
domains/<location-id>/
    index.sqlite             path <-> identifier map, versions, last-fetch times, pins, xattrs
    capabilities.json        cached server probe (§8.1)
```

Secrets (passwords, key passphrases) go in the keychain under access group
`RWGDZAYBM8.org.shirls.sshdrive`, keyed by location id and prompt kind (§4.2),
never in `config.json`.

### 3.1 Identifiers

| Thing | Value |
|---|---|
| Apple Developer Team ID | `RWGDZAYBM8` |
| App bundle (`SSH Drive.app`) | `org.shirls.sshdrive` |
| File Provider extension (`.appex`) | `org.shirls.sshdrive.fileprovider` |
| Background agent launchd label | `org.shirls.sshdrive.agent` |
| CLI and askpass executables | `sshdrive`, `sshdrive-askpass` (no bundle ids of their own; signed as part of the app) |
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
- App/agent, CLI and askpass: hardened runtime,
  `com.apple.security.application-groups`, `keychain-access-groups`. Not
  sandboxed (§9).

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
  "sshOptions": ["ProxyJump=bastion"], // optional extra -o options, verbatim
  "remotePath": "/srv/media",        // optional; default is the SFTP realpath of "." (the user's home)
  "secrets": ["password"],           // which keychain items exist for this location: password, passphrase:<keypath>
  "cacheTTL": "1h",                  // 15m | 1h | 12h | 1d | 1w | 1mo | never
  "watchMode": "auto",               // auto | poll | sweep | inotify | helper (§6.4)
  "helper": true,                    // default on: deploy the remote helper where the server supports it (§6.4, tier 3)
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

### 4.1 Reusing `~/.ssh/config`

Nothing to do: the agent runs the system `ssh`, which reads
`~/.ssh/config` on every connection, so `Include`, `Match`, wildcards,
`ProxyJump`, `ProxyCommand`, `IdentityAgent`, `CertificateFile` and
everything else behave exactly as they do for `ssh`. Edits to the config
take effect on the next reconnect, with no snapshot to keep honest.

The CLI still runs `ssh -G <host>` at `add` time and in `sshdrive show`, so
the user can see what the location resolves to ("user: alec, port: 2222,
identity: ~/.ssh/id_nas (from ~/.ssh/config)"). Explicit flags on `add`
become overrides stored in the location and passed as `-o` options, which
take precedence over the config file, as they do for `ssh`.

### 4.2 Secrets: how `ssh` gets passwords and passphrases

The agent runs `ssh` with no tty. Anything `ssh` would normally ask for on
the terminal is routed to our askpass program:

```
SSH_ASKPASS=/Applications/SSH Drive.app/Contents/MacOS/sshdrive-askpass
SSH_ASKPASS_REQUIRE=force
SSHDRIVE_LOCATION=<location id>
```

`ssh` invokes the program with the prompt text as its argument and reads the
answer from its stdout. The program classifies the prompt:

| Prompt from `ssh` | Keychain item | Answer |
|---|---|---|
| `Enter passphrase for key '<path>':` | `passphrase:<path>` for this location | the stored passphrase |
| `<user>@<host>'s password:` (or a `Password:` keyboard-interactive prompt) | `password` for this location | the stored password |
| anything else (a one-time code, an unexpected host-key question) | none | exits non-zero, `ssh` fails, the domain shows `.notAuthenticated` and `status` prints the prompt text so the user knows what the server wanted |

**Collecting secrets** happens once, in `sshdrive add` (and again in
`sshdrive passwd`). The CLI runs the same `ssh` command the agent will use,
against a tty, with the askpass program in *store* mode: each prompt is
shown to the user on the terminal, the answer is passed to `ssh` and kept in
memory. When the connection succeeds, every answer that was actually used is
written to the keychain; a wrong password is never stored. `list` and `show`
report which items exist ("password stored", "passphrase stored for
~/.ssh/id_nas"). Passphrases are always stored, even when `ssh-agent` also
holds the key, so the mount works at login before any agent has been
unlocked. An unencrypted key or a key in a hardware token needs nothing
stored.

Keyboard-interactive login is covered as far as the prompt is a password.
Servers that require a one-time code on every connection cannot be mounted
in v1; `add` says so when it sees such a prompt.

### 4.3 Host keys

`ssh` checks the server against `~/.ssh/known_hosts` as it always does.

- `sshdrive add` runs `ssh` on a tty with the default
  `StrictHostKeyChecking=ask`, so an unknown host gets `ssh`'s own
  fingerprint prompt and the answer lands in the user's `known_hosts`.
  `--trust-first` passes `StrictHostKeyChecking=accept-new` instead.
- The agent always runs with `StrictHostKeyChecking=yes`. A changed key
  makes `ssh` exit with its "REMOTE HOST IDENTIFICATION HAS CHANGED" banner;
  the agent recognises that on stderr, marks the domain `.notAuthenticated`,
  and `sshdrive status` shows the fingerprint `ssh` reported and the fix:
  `ssh-keygen -R <host>` followed by `sshdrive test <name>`.

We keep no host-key state of our own, so `ssh`, `sftp` and SSH Drive can
never disagree about a server.

---

## 5. The File Provider extension

### 5.1 Responsibilities

Implements `NSFileProviderReplicatedExtension`. One instance per domain; the
system may host several instances in one process, so nothing is global.
Every call is forwarded to the agent (§5.2), which does the work:

| System call | What the agent does |
|---|---|
| `enumerator(for: container)` → `enumerateItems` | `opendir/readdir` the mapped path over SFTP, reconcile with the index, return items. Records the folder as recently viewed (§6.5). |
| `enumerator(for: container)` → `enumerateChanges(from:)` | Same, diffed against the index; this is how a folder refreshes when Finder shows it (verify in S3). |
| `enumerator(for: .workingSet)` → `enumerateChanges(from:)` | Return the anchors recorded by change detection (§6.4). Never touches the network. |
| `item(for: identifier)` | Read the index row. Never touches the network. |
| `fetchContents(for:)` / `fetchPartialContents` | Download into the temp file the extension names, then the extension returns that URL. Partial fetches serve range requests for large media. |
| `createItem` | `mkdir`, `symlink` (§5.7), or upload-to-temp + non-overwriting `rename` into place (§5.5). |
| `modifyItem` | Depending on `changedFields`: rename/move (non-overwriting `rename`), content (upload + `posix-rename`), attributes (`setstat` mtime), extended attributes (stored locally, §5.4). |
| `deleteItem` | `rmdir` (recursive if requested) or `remove`. |
| `materializedItemsDidChange` | Forwarded so the agent can refresh its root set (§6.5) and the pin safety net (§7.2). |
| `performAction` | Pin / unpin (§7.2). |

Every item carries: `contentPolicy` (§7.1.1), `capabilities` (§5.4),
`userInfo.kept` (§7.2), `contentVersion` and `metadataVersion` (§5.3), and
`extendedAttributes` from the index.

Every SFTP failure classified as network-related (connect timeout, EOF,
`ENETUNREACH`, DNS, `ssh` exiting with a connection error) becomes
`NSFileProviderError(.serverUnreachable)` so the system queues and retries.
Auth and host-key failures become `.notAuthenticated`; the domain then shows
as needing attention and `sshdrive status` explains why. A name held by a
hidden symlink or by a collision (§5.4, §5.7) becomes `.filenameCollision`.
`ENOSPC`/`EDQUOT` on upload become `.insufficientQuota`.

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

Fetched content crosses the boundary without copying: the extension
creates the target file in its own temp directory
(`NSFileProviderManager.temporaryDirectoryURL()`) and sends the path; the
agent, which is not sandboxed, writes into it directly. Uploads go the
other way: the system gives the extension a URL for the new content and
the extension sends that path; the agent reads it. Directory listings and
item records are small and travel as XPC values.

The XPC interface is versioned. A mismatched agent and extension (mid
upgrade) is reported as `.serverUnreachable` until the agent restarts.

### 5.3 Item identifiers and the index

SFTP gives us paths, not IDs. The File Provider system needs identifiers that
stay stable across renames. The agent keeps a per-domain SQLite index, the
only copy of everything we know about the remote tree:

```
items(identifier TEXT PK, path TEXT UNIQUE, parent TEXT, type, size, mtime,
      mtime_ns INTEGER, inode INTEGER,  -- when a push tier or GNU sweep reports them (§6.4)
      uid INTEGER, gid INTEGER, mode INTEGER,
      content_version TEXT, last_fetch REAL, deleted_at REAL,
      pin_state INTEGER DEFAULT 0,   -- 0 inherit, 1 pinned, -1 excluded (§7.1.1)
      hidden INTEGER DEFAULT 0,      -- 1 symlink omitted (§5.7), 2 name collision (§5.4), 3 our temp file
      xattrs BLOB)                   -- Finder tags and other extended attributes, local only (§5.4)
anchors(seq INTEGER PK, changed_identifier TEXT, change_kind TEXT)
roots(path TEXT PK, reason TEXT, last_seen REAL)   -- change-detection root set (§6.5)
```

- Identifier = UUID minted the first time we see a path.
- Rename/move initiated by the user (via `modifyItem`) updates `path` and keeps
  the identifier.
- Renames done remotely (outside Finder) appear as delete + create at the
  polling tiers; tiers 2 and 3 report real renames and the identifier is
  kept.
- `content_version` = `"\(size)-\(mtime)"` at the polling tiers. SFTP v3
  reports mtime in whole seconds, so two writes of the same size within one
  second, or a `cp -p` that preserves mtime, are indistinguishable. Where
  the helper or a GNU `find` sweep runs, the version becomes
  `"\(size)-\(mtime_ns)-\(inode)"` and those cases are caught. Metadata
  version = content version plus mode, uid, gid and the pin state.
- If the system presents an anchor the index no longer knows (index
  rebuilt), the agent answers `.syncAnchorExpired` and the system
  re-enumerates.

### 5.4 Names, permissions, attributes

**Case and normalisation.** The server is byte-exact and usually
case-sensitive; the local replica is case-insensitive and
normalisation-insensitive. When two server names in one directory map to
the same local name (`Makefile` and `makefile`; NFC and NFD `é.txt`), the
first in `readdir` order is shown and the rest are recorded with
`hidden = 2`. Names that are not valid UTF-8 are hidden the same way. Hidden
names hold their slot: a create or rename to one of them fails with
`.filenameCollision`. `sshdrive status` lists hidden names under "not
shown" with the reason, so the user can rename them server-side. Names are
sent to the server exactly as the system provides them; we never
normalise.

**Permissions become capabilities.** The capability probe (§8.1) runs
`id -u -G` where exec is available, and every item's `capabilities` are
computed from its `mode`, `uid`, `gid` and that identity: a file the
account cannot write loses `allowsWriting`, a directory it cannot write
loses `allowsAddingSubItems`, `allowsRenaming` and `allowsDeleting` follow
the parent's write bit. Finder then shows a lock and refuses the edit up
front instead of failing the upload later. SFTP-only accounts, where the
identity is unknown, get full capabilities and learn about permission
errors from the sync error list. Owner and mode are shown in Finder's Get
Info as far as the system displays them.

**No trash.** `allowsTrashing` is never set. Finder asks "will be deleted
immediately, are you sure?" and then calls `deleteItem`, which removes the
item on the server. This is honest for a remote filesystem and avoids
inventing a server-side trash that other SFTP clients would not understand.

**Extended attributes stay local.** Finder tags, colours, `FinderInfo` and
any other xattr the system sends in `modifyItem` (`changedFields` contains
`.extendedAttributes`) are stored in the index row and returned on every
item, so tagging works, and nothing is ever sent to the server. They are
lost if the remote item is deleted or the index is rebuilt, which `sshdrive
status` does not need to mention.

**`.DS_Store` is swallowed.** A `createItem` or `modifyItem` for a
`.DS_Store` succeeds locally with an item the agent records but never
uploads; a `.DS_Store` on the server is never enumerated. Finder keeps
working, the server stays clean.

**Our own temp files** (`.sshdrive-upload-*`, §5.5) are never enumerated
and are ignored by every change-detection tier.

### 5.5 Writes, conflicts, atomicity

- **New files:** upload to `<dir>/.sshdrive-upload-<uuid>`, then the plain,
  non-overwriting SFTP `rename` into place. OpenSSH implements that as
  `link` + `unlink`, so it fails atomically if anything now holds the name
  (a hidden link, a collision, a file created meanwhile), which maps to
  `.filenameCollision`. Servers whose plain `rename` overwrites (the probe
  tests this once in a scratch directory) get an `lstat` preflight instead,
  and `status` shows the cost (§8.1).
- **Existing files:** `lstat` the target, upload to the temp name, then
  `posix-rename@openssh.com` over it so the replacement is atomic, then
  `setstat` the old mode back onto the new file. Owner and group cannot be
  restored (that needs root) and hard links to the old inode are broken;
  both are documented. Servers without `posix-rename` do `remove` + `rename`,
  a non-atomic window that `status` reports as a degraded capability.
- **Conflicts:** if the `lstat` shows a `content_version` different from the
  `baseVersion` the system passed us, the remote changed underneath the
  user. Policy: upload the local content as `<name> (conflicted copy from
  <hostname> <date>).<ext>` beside it, return the remote item as current,
  record a working-set anchor for the new sibling so Finder shows it at
  once, and log. This mirrors Dropbox/OneDrive behaviour and never loses
  data. The check-then-write is not atomic; a write landing in that window
  is lost the same way it would be with any two SFTP clients.
- **Durability:** `fsync@openssh.com` after each upload when the server
  offers it.
- **Stale temp files:** a `.sshdrive-upload-*` older than a day found in
  any directory the agent lists is removed; a dropped connection mid-upload
  therefore leaves nothing behind for long.
- **Deletes** of non-empty directories: refuse unless the system passed the
  recursive option; then depth-first remove, re-`lstat`ing each directory
  on the way down (§9.1).

### 5.6 Offline behaviour, end to end

| Situation | What happens |
|---|---|
| Open a file already downloaded, network down | Reads served by the system from local storage. We are not called. |
| Browse a folder listed before, network down | Served from the system's replica; the refresh request gets `.serverUnreachable` and Finder shows the cached listing. |
| Browse a never-listed folder, network down | `.serverUnreachable` at once; Finder shows the folder as unavailable. |
| Save a file, network down | System stores it locally, marks it "waiting to upload", calls `modifyItem` again on retry. The agent fails fast until it can connect, then the flush goes through. |
| Network returns | Agent's `NWPathMonitor` fires → connection attempt → on success `signalEnumerator` for every domain, and `reconnect()` if `disconnect(reason:)` had been used. |
| Laptop wakes from sleep | Same path as network returns. |
| Agent not running | Domain shows a disconnect message (§5.2); everything already cached keeps working. |

We deliberately do not use `disconnect(reason:)` for network outages;
throwing `.serverUnreachable` is enough and keeps the domain writable. The
agent calls `disconnect` with a human message only for auth, host-key and
agent-missing failures, where retrying is pointless until the user acts.

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

---

## 6. The background agent

### 6.1 SSH process management

Per mounted location the agent keeps one master connection and opens
channels on it as needed, all through the system `ssh`:

```
ssh -o ControlMaster=yes -o ControlPath=$TMPDIR/sshdrive-%C -o ControlPersist=no \
    -o StrictHostKeyChecking=yes -o ConnectTimeout=5 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
    -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR \
    <overrides as -o User= / Port= / IdentityFile=> <sshOptions…> \
    -s <host> sftp                      # the master: also the primary SFTP channel
ssh -S $TMPDIR/sshdrive-%C -s <host> sftp      # a second SFTP channel for bulk transfers
ssh -S $TMPDIR/sshdrive-%C <host> sh -s        # exec channels: probe, sweep, inotifywait, helper (§9.2)
```

- The master's stdio is the primary SFTP channel, used for metadata
  (`stat`, `readdir`, `rename`, small files). A second SFTP channel carries
  bulk downloads and uploads so a long transfer never blocks a listing.
  Exec channels are opened per command. All of them are channels on one TCP
  connection, so a server's `MaxSessions` (default 10) is comfortably
  enough; the agent never holds more than five open per location.
- `ControlPath` lives under `$TMPDIR` because Unix socket paths are limited
  to 104 bytes and the group container path is long.
- `ssh` exiting is the disconnect signal. The agent reconnects with jittered
  backoff and classifies the exit: connection errors are `.serverUnreachable`,
  auth and host-key banners are `.notAuthenticated` (§4.3), and stderr is
  kept for `sshdrive status`.
- Environment for every `ssh`: the askpass variables (§4.2), a clean `PATH`,
  and the user's `HOME` so `~/.ssh/config` is found. `ssh-agent` is reached
  through whatever `SSH_AUTH_SOCK` the login session provides; the agent
  re-reads it from launchd on every spawn so an agent started later is
  picked up.
- Every location has its own master; two locations on one host are two
  connections, which keeps their failures and reconnects independent.

### 6.2 SFTP client

We implement the SFTP v3 wire protocol in Swift over the `ssh` process's
stdio: a length-prefixed packet framing, the twenty request types, and the
OpenSSH extensions we use (`posix-rename@openssh.com`, `statvfs@openssh.com`,
`fsync@openssh.com`, `limits@openssh.com`, `lsetstat@openssh.com`,
`hardlink@openssh.com`). It is a few thousand lines, has no dependencies,
and is tested against OpenSSH's `sftp-server` directly on stdio without any
network.

Requests are pipelined: reads and writes keep up to the server-advertised
`limits@openssh.com` window in flight (or a conservative 32 KB × 16 without
it), which is what gives `sftp(1)`-class throughput. `readdir` pages are
requested back to back. The client exposes a `protocol SFTPTransport` whose
methods take `RelativePath` values only (§9.1).

Why this rather than a library:

- OpenSSH is the only implementation that supports every auth mechanism,
  `ProxyJump`, agents, certificates and FIDO keys, and it is already on every
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
   resets the breaker.
3. `ConnectTimeout=5` bounds the one attempt that does go out.

### 6.4 Remote change detection

SFTP cannot push changes, but the SSH connection can run commands on the
server when the account has shell (exec) access. Change detection therefore
has four tiers. All tiers produce the same thing: a set of "dirty" remote
paths that the agent re-`stat`s over SFTP, diffs against the index, and
turns into working-set anchors, followed by `signalEnumerator(for:
.workingSet)`. Nothing on the File Provider side knows which tier is active.

| Tier | Mode | Needs on the server | Latency | Cost per cycle |
|---|---|---|---|---|
| 0 | `poll` | SFTP only | poll interval | one `readdir` per root, over the network |
| 1 | `sweep` | exec + `find` (GNU, BSD or busybox) | poll interval | one command; server walks the tree locally |
| 2 | `inotify` | exec + `inotifywait` (Linux) or `fswatch` (macOS/BSD) | ~1 s | idle stream; nothing per cycle |
| 3 | `helper` | exec + a writable, executable directory + a supported OS/arch | ~1 s | idle stream; server-side batching and filtering |

**Scope** is the root set of §6.5. Tiers 2 and 3 are restarted, debounced by
a few seconds, when it changes.

**Selection.** `watchMode: auto` (the default) tries the tiers from the top:
helper first, then inotify, then sweep, then poll, settling on the first one
that starts successfully. The helper is enabled by default and is skipped only
when the server cannot run it (no exec, no writable directory, directory
mounted `noexec`, unsupported OS/arch, upload or hash check failed) or the
user has set `helper off` for the location. A tier that fails at runtime
(stream dies with a non-network error, `inotifywait` reports a watch-limit or
queue-overflow, `find` is missing) drops the location one tier down for the
rest of the session and records why, which `sshdrive status` shows. Setting
`watchMode` to a specific tier disables the fallback ladder except to `poll`,
which always works. On reconnect after any outage every tier first runs one
full sweep (tier 1, or tier 0 if exec is unavailable) so changes made while
disconnected are caught, then resumes streaming.

**Schedule for tiers 0 and 1.** Every 60 s while the user has touched the
domain in the last 10 minutes, every 10 min otherwise, and immediately on
network-up. Tiers 2 and 3 replace the schedule with events; a sweep still
runs every 30 min as insurance against missed events.

#### Tier 0: SFTP poll

`readdir` every root, compare name/size/mtime against the index. This is the
only tier available to SFTP-only accounts (chrooted `internal-sftp`), and the
final fallback for everyone else.

#### Tier 1: remote sweep

One `sh -s` exec channel per cycle, fed a script on stdin (§9.2) that runs:

```
find "$@" -maxdepth 1 \( -type d -o -type f \) -mmin -<N> -print0     # working-set roots
find "$@"             \( -type d -o -type f \) -mmin -<N> -print0     # pin roots, excluded subtrees pruned with -path … -prune
```

Two invocations because `-maxdepth` applies to every starting point of one
`find`. `-mmin` rather than `-newermt` because GNU, BSD and busybox all
accept it and only GNU takes an epoch timestamp; `N` is the minutes since the
previous sweep, rounded up, plus one minute of overlap. Duplicates are
harmless because the result is diffed anyway. Both files and directories are
matched: a directory's mtime changes on create, delete and rename inside it,
but an in-place edit changes only the file's own mtime, so the file test is
needed too. There is no `-xdev`: a NAS root routinely contains separate
mounts (ZFS datasets, bind mounts), and containment comes from not following
links (§9.1), not from staying on one filesystem. On GNU `find` the sweep
adds `-printf '%T@ %i\0'` so the index gets nanosecond mtime and inode
(§5.3); elsewhere the returned paths are `stat`ed over SFTP.

#### Tier 2: inotify / fswatch

```
inotifywait -m -r -q --format '%e%0%w%f%0' \
  -e create,delete,modify,close_write,moved_from,moved_to,attrib "$@"   # pin roots
inotifywait -m    -q --format '%e%0%w%f%0' -e … "$@"                     # working-set roots
```

Two long-running processes on one exec channel each (recursive for pin
roots, flat for the working set), started through the same stdin-script
mechanism as the sweep (§9.2), output NUL-delimited so filenames containing
newlines or `|` cannot break parsing, coalesced for 500 ms before the diff
runs. `inotifywait` does not expose the rename cookie in its output, so
`moved_from` / `moved_to` are treated as delete + create at this tier; only
the helper reports renames. Watch-limit errors (`max_user_watches`), queue
overflow, or the process exiting drop the tier to `sweep` with a status
note. Remote NFS/FUSE mounts produce no events; the 30-minute insurance
sweep and the reconnect sweep cover that.

On macOS/BSD hosts `fswatch -r -0 --event-flags` plays the same role with the
same parsing shape.

#### Tier 3: remote helper (default where supported)

A single static binary, `sshdrive-helper`, built from this repo in Rust for
`linux/x86_64`, `linux/aarch64`, `darwin/arm64` and `freebsd/x86_64`, embedded
in `SSH Drive.app`. Deployment happens over the existing connection:

1. Probe `uname -sm` and a writable, executable directory:
   `$XDG_CACHE_HOME/sshdrive`, else `~/.cache/sshdrive`, else
   `/tmp/sshdrive-<uid>`. "Executable" is tested by actually running the
   uploaded binary with `--version`, which catches `noexec` mounts.
2. Upload `sshdrive-helper-<version>-<os>-<arch>` over SFTP if
   `sha256sum`/`shasum` of the remote copy does not match the hash embedded in
   the app. The version is tied to the app release; upgrades happen the same
   way, and stale versions in the directory are removed.
3. Run `<path>/sshdrive-helper watch --json --root <root> --roots-from-stdin`
   on an exec channel, feed it the root set, and read NDJSON events:
   `{"op":"create|modify|delete|rename|overflow","path":…,"from":…,
   "size":…,"mtime_ns":…,"inode":…}` plus a heartbeat every 15 s.

What it adds over tier 2: inotify/FSEvents/kqueue used directly (no watch
tool to install), root-set changes applied live without a restart, real
rename events with identifiers preserved, nanosecond mtime and inode in every
event, server-side coalescing and ignore rules (`.git`, editor temp files, our
own `.sshdrive-upload-*`), an `overflow` event that makes the agent run a
sweep rather than silently missing changes, and a `sweep` subcommand that does
tier 1's job with size/mtime/inode included so no follow-up `stat`s are
needed. It never listens on a socket, never runs detached, and exits when its
stdin closes, so a dropped connection leaves nothing behind.

The helper is on by default and is the first thing `auto` tries, even where
`inotifywait` is installed, because it is the most reliable push mechanism,
the only one that reports renames, and needs nothing installed on the
server. Since it does place our code on the remote machine, `sshdrive add`
states this plainly in its output ("SSH Drive will upload a small helper
binary to ~/.cache/sshdrive on this server to watch for changes; disable
with `sshdrive set <name> helper off`"), and `sshdrive status` shows the
exact remote path and version in use. `helper off` stops it and removes the
binary on the next connection; `helper on` re-enables it. Deployment
failures are never fatal: the location silently continues at the next tier
and the status report says why the helper is not running.

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

A remote rename of a directory reaches tiers 0 and 1 as delete + create of
the whole subtree. Cached content under it is discarded and, if pinned,
re-downloaded. Tiers 2 and 3 report the rename and keep identifiers and
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
   to fail): last use = max(atime of the user-visible file, `last_fetch` from
   the index). atime is read with `AT_SYMLINK_NOFOLLOW` (§9.1). Spike S4
   verifies atime advances on read on the target macOS versions;
   `last_fetch` is the fallback and is always present. atime is not
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

Kept items (§7.1.1) are never evicted: the agent derives each item's
effective state from the `pin_state` markers on it and its ancestors before
evicting. A file the user fetched with Finder's built-in "Download Now" is
treated like any other cached file and falls under the TTL; use `sshdrive
pin` to keep it.

### 7.1 Pinning: keep a folder fully offline

Two words are used strictly throughout this document:

- **pinned** / **excluded** are *markers* the user places on a path with
  `sshdrive pin` / `sshdrive unpin` (or the Finder entries). They are what
  gets stored.
- **kept** is the *effect* on an item: whether the nearest marker at or above
  it is a pin. Kept is what the system, the eviction loop, the badge and the
  Finder menu act on. Every pinned item is kept; most kept items are not
  pinned, they inherit it.

Markers live in the index (`pin_state`) and nowhere else. The index is the
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
   "Keep Downloaded" entry (§7.2), sets `pin_state = 1` on the matching row
   (creating it if the path has not been enumerated yet). Pins are on paths,
   so a re-enumeration keeps them.
2. **Declare the policy.** Items are returned with
   `contentPolicy = .downloadEagerlyAndKeepDownloaded` when their effective
   state (§7.1.1) is kept, `.downloadLazily` when excluded, and `.inherited`
   otherwise. On any pin-state change the agent bumps the metadata version
   of the affected item and signals the working-set enumerator so the system
   re-reads the item and applies the new policy. The system then downloads
   the subtree eagerly (through our normal `fetchContents`), shows it as
   downloaded in Finder, and refuses to evict it.
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

### 7.2 Pinning from Finder's context menu

The CLI is the source of truth, but the natural place to pin a folder is the
folder itself. Two custom File Provider actions provide that, declared in the
extension's Info.plist and handled in the extension by
`performAction(identifier:onItemsWithIdentifiers:)`, which forwards to the
agent. No window, no UI extension: Finder renders the menu items and calls us.

Every item the extension returns carries `userInfo = ["kept": 0|1]`, its
kept state from §7.1.1 (1 when the nearest marker at or above it is a pin).
The activation rules read it:

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
  once; "Remove Download" evicts an unkept item immediately. On a kept item
  the eager policy makes Finder hide or fail its "Remove Download", so a user
  who wants space back chooses "Don't Keep Downloaded" first and then Finder's
  "Remove Download", or waits for the TTL.

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

## 8. The CLI: `sshdrive`

Built with `swift-argument-parser`. Every command is an XPC request to the
agent; if the agent is not running the CLI starts it (§10) and retries. All
prompts use a hidden tty read and can be avoided for scripting with flags or
stdin.

```
sshdrive add [user@]host-or-alias[:port] [--nickname NAME] [--remote-path PATH]
             [--user USER] [--port N] [--identity PATH] [-o SSHOPTION]…
             [--password | --password-stdin | --no-password]
             [--cache-ttl 1h] [--trust-first]
        Runs `ssh -G` to show what the host resolves to, then connects once
        on the terminal with the same command the agent will use (§4.2):
        ssh's own host-key prompt, then our askpass prompts for a password
        or passphrase, stored on success. Then asks the agent to record the
        location, probe the server (§8.1), and add the File Provider domain.
        Says so if the helper will be deployed (§6.4 tier 3).

sshdrive list                     table: name, host, secrets, mounted, TTL, state
sshdrive show <name>              full detail: `ssh -G` resolution, mount path, last error
sshdrive remove <name> [--keep-files]
                                  removes domain + config + keychain entries; refuses while
                                  uploads are pending unless --force; --keep-files uses the
                                  system's preserve-downloaded-data mode so cached files
                                  land in a folder on the Desktop
sshdrive remove --all             every location, for uninstall (§10)
sshdrive mount <name> / unmount <name>
                                  add/remove the File Provider domain without
                                  forgetting the location
sshdrive set <name> nickname|cache-ttl|remote-path|host|port|user|identity|watch-mode|helper <value>
                                  nickname and remote-path re-create the domain (the
                                  sidebar name is fixed at domain creation unless S9 says
                                  otherwise; a new root invalidates every path in the index),
                                  so they are refused while uploads are pending;
                                  watch-mode: auto|poll|sweep|inotify|helper (§6.4);
                                  helper on|off: allow the remote helper (default on)
sshdrive set <name> option add|remove <SSHOPTION>
                                  edit the extra -o list
sshdrive passwd <name>            re-run the interactive connection and replace stored secrets
sshdrive test <name>              connect + list root, print timing, run the
                                  capability probe and print the report (§8.1)
sshdrive status [<name>] [--json] [--probe]
                                  per-domain state, sync errors, hidden names, and the
                                  capability report (§8.1); --probe re-runs the server
                                  probe instead of using the cached result
sshdrive evict <name> [path] [--all] [--unpin-all]
sshdrive pin <name> <remote-path>
                                  keep a folder or file fully offline (§7.1); same
                                  effect as Finder's "Keep Downloaded" entry (§7.2)
sshdrive unpin <name> <remote-path>
                                  clears an explicit pin, or excludes the path if it
                                  inherits a pin from a folder above (§7.1.1)
sshdrive pins [<name>] [--export | --import FILE]
                                  tree of pins and exclusions with cached size and file counts
sshdrive logs [--follow]          streams os_log for our subsystem
sshdrive doctor                   checks: app in /Applications, extension registered
                                  (pluginkit), login item enabled and agent reachable,
                                  app group container writable, CLI on PATH, ssh version,
                                  macOS version
sshdrive agent start|stop|restart
```

`<name>` resolves nickname, then host, then id prefix.

A host-key change needs no command of ours: `status` prints the
`ssh-keygen -R` line to run (§4.3).

### 8.1 Capability report in `sshdrive status`

Several features run at different levels depending on what the remote server
offers. The probe runs on every connection and on `sshdrive test` and
`status --probe`; the result is cached in
`domains/<id>/capabilities.json` with a timestamp and the server banner. It
consists of the SFTP `extensions` list from the SFTP init reply, whether an
exec channel opens, and one shell script (§9.2) that reports
`uname -sm`, `id -u -G`, the `find` flavour, the presence of `inotifywait`,
`fswatch`, `sha256sum`/`shasum`, and a writable, executable cache directory.

The catalogue of server-dependent features:

| Feature | Levels (best first) | What unlocks the next level |
|---|---|---|
| Change detection | helper · inotify · sweep · poll | shell access plus a writable directory for the helper; otherwise `inotify-tools`/`fswatch` on the server |
| Rename detection | rename events (helper) · delete+create | the helper |
| Change versions | ns-mtime + inode (helper or GNU sweep) · size + mtime | shell access |
| Permissions | mapped to Finder capabilities (`id` available) · everything writable | shell access |
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
       capabilities poll-only (SFTP-only account), 6 upgradeable   probed 2h ago (cached)

$ sshdrive status nas
SSH Drive - nas
  Server    alec@nas.tail1234.ts.net:22   OpenSSH_9.6   Linux x86_64   shell access: yes
            ssh resolves nas via ~/.ssh/config (user, port, identityfile)
  State     mounted at ~/Library/CloudStorage/SSHDrive-nas   online   last change 12s ago
  Auth      passphrase stored for ~/.ssh/id_nas   host key in ~/.ssh/known_hosts
  Sync      2 pending uploads (14.1 MB)   0 conflicts   last error none
  Cache     1.2 GB materialized (312 files), 480 MB kept   TTL 1d   next eviction sweep in 3m
  Pins      Documents/thesis   Photos/2026
  Not shown 1 name (case collision: build/Makefile vs build/makefile)

  Capabilities  7/8 optimal   probed 3m ago
  ● change detection   helper 1.2.0 at ~/.cache/sshdrive (push, ~1s)   watch-mode auto
  ● rename detection   helper move events
  ● change versions    ns-mtime + inode
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
  Capabilities  2/8 optimal   probed 2h ago (cached; offline)
  ◐ change detection   poll (SFTP readdir every 60s while active)
        upgrade: shell access on the server enables the helper (push); without a writable directory, inotify-tools also enables push, and plain shell access enables remote sweep
  ◐ rename detection   delete + create (identifiers not preserved on remote renames)
        upgrade: the helper, which needs shell access
  ◐ change versions    size + mtime (same-second rewrites of equal size are missed)
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

- A runtime downgrade (for example inotify hit the watch limit and fell back
  to sweep) shows the level in use with `◐` and a `note:` line giving the
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
- `--json` emits the same data: an array of `{feature, level, best, glyph,
  upgrade, note}` objects plus the probe timestamp, for scripting.
- When offline, the cached probe is shown with "(cached; offline)" and no
  guesses are made about what changed.

---

## 9. Security

- Sandbox on the extension (required). It has no network entitlement and
  no keychain access; it can only talk to the agent. Agent, CLI and askpass
  not sandboxed (they need `~/.ssh`, `ssh-agent`, the keychain, and the
  CloudStorage paths for eviction).
- Hardened runtime on all executables; notarized.
- Private keys are never copied or read by us. `ssh` uses them where they
  are.
- Passwords and passphrases only in the keychain, `kSecAttrAccessible =
  afterFirstUnlock`, shared access group so agent, CLI and askpass read the
  same items. The askpass program answers only when invoked with the
  agent's or CLI's environment (`SSHDRIVE_LOCATION` naming a known
  location) and only for password and passphrase prompts; anything else
  gets a refusal, never a stored secret.
- Host keys are the user's `known_hosts`; the agent never accepts a new or
  changed key on its own (§4.3).
- Logs never contain file content or credentials; hostnames and paths
  are `privacy: .private` in `os.Logger`.
- Remote access never leaves the location root; see §9.1. Remote commands
  never interpolate filenames; see §9.2.
- The remote helper (§6.4 tier 3) is on by default; `sshdrive add` says so
  when a location is created and `helper off` disables it per location. It is
  verified by SHA-256 against a hash embedded in the app before every launch,
  runs as the SSH user with no elevated rights, opens no sockets, writes only
  to its own cache directory, and exits when the connection drops.

### 9.1 Path containment

Nothing the agent, helper or CLI does on the server may touch a path
outside the location's `remotePath`. Symlink policy (§5.7) is one piece of
that; the rest follows.

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
connection the agent calls `realpath` on it again and refuses to operate
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
`-L` (physical walk); `inotifywait -r` does not follow symlinks when
recursing; the helper takes `--root` and refuses any watch or sweep root
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
  `"$@"`. This is the same for the probe, the sweep, `inotifywait`, the
  helper deployment and every other remote command.
- **Output is NUL-delimited** wherever a filename can appear (`-print0`,
  `%0` in `inotifywait`'s format, NDJSON from the helper) and parsed as
  bytes, never split on newlines.
- **Every path coming back** is checked for the root prefix and built into a
  `RelativePath` (§9.1) before use.

---

## 10. Packaging and install

- Xcode project with four targets (app/agent, extension, CLI, askpass) plus
  the `SSHDriveCore` local package, and a Rust crate for the helper.
- CI: `xcodebuild archive`, Developer ID sign, `notarytool`, staple, DMG.
- Homebrew cask: installs `SSH Drive.app` and links `sshdrive` from inside the
  bundle via the cask `binary` stanza. The cask's `postflight`, and
  `sshdrive doctor`, run `open -g -a "SSH Drive"` once. Launching the app is
  what registers both the extension with PlugInKit and the login item
  through `SMAppService`, and both must be done from the app's own bundle,
  which a symlinked CLI cannot do. The app, on launch, registers its login
  item if needed, notices the launchd-managed instance already holds the
  mach service, and exits. macOS asks the user once to allow the login item;
  that system notification is the only "UI" the user ever sees.
- The cask's `uninstall` stanza runs `sshdrive remove --all --force` before
  deleting the app, so no ghost domains are left in the sidebar, and
  unregisters the login item. `zap` removes the group container and keychain
  items.

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

Release flow (GitHub Actions on a macOS runner, triggered by a `v*` tag):

1. Cross-compile the helper (`cross` with musl targets, plus darwin and
   freebsd), record its hashes into the app's manifest.
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
extension is killed by the system and relaunched from the new bundle; the
agent notices its own executable changed and restarts itself. Pending
uploads are held by the system and survive.

---

## 11. Spikes (do these first; each is a day or less)

| # | Question | Why it matters |
|---|---|---|
| S1 | The agent as the single File Provider client: does `NSFileProviderManager.add(domain)` from the launchd-started agent associate the domain with our extension, and does launching the app with `open -g` from a Homebrew `postflight` register both the extension and the login item? | Decides whether the CLI can stay a pure XPC client and whether install needs any manual step. |
| S2 | `ssh -s sftp` under our supervision: `none` auth against Tailscale SSH; an encrypted ed25519 key via askpass with `SSH_ASKPASS_REQUIRE=force`; a key held only in 1Password's agent; `ProxyJump`; a second SFTP channel and an exec channel over `ControlMaster`; throughput of our SFTP client with pipelining against `sftp(1)` and `rsync` on a 1 GB file and on 10,000 small files. | Validates the transport decision and the auth goal in §1 before anything is built on it. |
| S3 | Minimal replicated extension: list, open, save, rename against a real SFTP server through the agent; observe the sidebar label and mount path with two domains and with `displayName` set to `nas` versus `SSH Drive - nas`; confirm the system requests `enumerateChanges` on a folder's enumerator when Finder shows it; what Finder does with `.filenameCollision`; what the delete confirmation looks like without `allowsTrashing`. Include a containment test: replace an enumerated directory with a symlink to `/etc` on the server and confirm nothing inside it is listed, fetched or deleted. | Settles the naming scheme (§2, §4), the root-set design (§6.5), the trash decision (§5.4), and the §9.1 guarantees from the first build. |
| S4 | Does `evictItem` work for files in our domain, does atime on materialized files advance on read, and does the system refuse to evict an item with pending changes? | Determines whether TTL eviction can use real last-access and whether it needs a pending-upload check of its own. |
| S5 | Behaviour when throwing `.serverUnreachable` for writes: how long the system retries, and whether `NWPathMonitor` + `signalEnumerator` reliably wakes the flush. What the extension sees when the agent's mach service is unavailable (login item disabled). | The "no fuss across network drops" requirement rests on this, and so does the agent-missing message (§5.2). |
| S6 | Flip a folder's `contentPolicy` to `.downloadEagerlyAndKeepDownloaded` at runtime: does the system download the whole subtree after a working-set signal, do new files added remotely get fetched on the next poll, and does `evictItem` correctly refuse? Does an explicit `.downloadLazily` on a child override an eager ancestor (needed for exclusions, §7.1.1)? Record exactly which built-in menu items Finder shows for pinned vs unpinned items, whether the built-in "Remove Download" is hidden, fails, or succeeds on a pinned item, and whether custom actions with `userInfo`-based activation rules appear at the top level of the context menu or in an app submenu. | Pinning (§7.1) depends on the policy being honoured dynamically; the Finder menu design (§7.2) depends on how the system entry behaves on pinned items. |
| S7 | Run tier 1 and tier 2 (§6.4) over `ControlMaster` exec channels alongside SFTP traffic: does a long-running `inotifywait` stream coexist with two SFTP channels on one connection, and how long does the `find -mmin` sweep take on a 1M-file tree with 200 roots? Check `-mmin` and `-printf` across GNU, BSD and busybox `find`, and the `sh -s` stdin-script mechanism (§9.2) under bash, zsh, fish and csh login shells. | Decides whether tiers 1–2 are practical on one connection, sets the default poll interval, and proves the quoting design. |
| S8 | Return an item with `contentType = .symbolicLink` and `symlinkTargetPath`: does the system create a real symlink under CloudStorage, does Finder badge it, does a relative target resolve inside the mount, how does Finder present a dangling one, does `ln -s` inside the mount reach `createItem` with the target intact so escaping targets can be refused? | Confirms §5.7 end to end. |
| S9 | Does calling `NSFileProviderManager.add(domain)` with an existing identifier and a new `displayName` rename the domain in place, keeping cache and pending uploads? | If yes, `set nickname` stops re-creating the domain and the §13 data-loss caveat goes away. |
| S10 | Finder tags on an item whose extension returns `extendedAttributes` from local storage: does tagging round-trip, and does the system keep re-offering the `modifyItem` if we accept the change without a version bump? | Confirms the local-xattr policy (§5.4) does not produce a retry loop. |

---

## 12. Milestones

1. **Skeleton** — app/agent, extension, CLI, askpass all sign and launch;
   XPC between the three; `sshdrive doctor` green. Spikes S1, S3, S5 folded
   in.
2. **Transport** — `ssh` supervision with `ControlMaster`, askpass and
   keychain, the SFTP client with pipelining and extensions, the
   `RelativePath` chokepoint, `sh -s` remote scripts. Spike S2.
3. **Read-only** — `add` with `ssh -G` display and interactive secret
   collection, `list`, `show`, `remove`; browse and open files; capability
   probe and `status` (§8.1); permissions to capabilities; hidden-name
   handling.
4. **Read-write** — create/modify/delete/rename/move; temp-file + rename
   uploads with mode restore; conflict copies; local xattrs; `.DS_Store`;
   symlink handling (§5.7). Spikes S8, S10.
5. **Offline hardening** — circuit breaker, reconnect, queued-write flush on
   network-up, sleep/wake testing, agent-missing behaviour.
6. **Change detection, tiers 0–2** — root set, anchors, poll cadence, remote
   sweep, inotify/fswatch streams, fallback ladder. Spike S7.
7. **Eviction** — TTL agent loop, `sshdrive evict`, `set cache-ttl`. Spike S4.
8. **Pinning** — `pin`/`unpin`/`pins`, content policy, kept-subtree watching,
   eviction exclusion, Finder "Keep Downloaded"/"Don't Keep Downloaded" actions
   and the pin badge. Spike S6.
9. **Remote helper (tier 3)** — Rust helper binary, cross-compiled in CI,
   deploy/verify/upgrade over SFTP, NDJSON protocol, `helper on|off`. Until
   this ships, `auto` tops out at inotify.
10. **Ship** — notarized DMG, Homebrew cask with postflight and uninstall,
    `logs`, docs. Spike S9 applied to `set nickname` if it passed.

---

## 13. Decisions

Questions that were open during drafting and how they were settled:

- **Transport is the system OpenSSH, owned by the agent, with our own SFTP
  wire-protocol client.** Not libssh2, and not a session inside the
  extension. This is what makes every `ssh` auth method work unchanged, puts
  the long-running watch streams in a process allowed to run long, gives the
  index one writer, lets the extension drop its network entitlement, and
  gives us control of every SFTP request (non-overwriting `rename`,
  `limits`). The cost is a hard dependency on the login agent, which the
  design already had for eviction and polling, and a few thousand lines of
  protocol code.
- **The CLI is a pure XPC client.** It never calls File Provider or opens a
  connection itself, except the one interactive `ssh` in `add` and `passwd`.
  So it may be invoked through any symlink, and there is no CLI-in-bundle
  requirement to spike.
- **Secrets:** passphrases and passwords are always stored in the keychain
  and served to `ssh` by our askpass program, so mounts come up at login
  before any agent is unlocked. Keys themselves are never copied.
- **Host keys:** the user's `known_hosts`, checked strictly by the agent.
  No pinning of our own, no re-trust command; the fix for a changed key is
  the same `ssh-keygen -R` it would be for `ssh`.
- **No trash.** Finder deletes are immediate after Finder's confirmation.
- **Writes** replace files via temp + `posix-rename`, then restore the mode.
  Owner, group and hard links are not preserved; this is documented rather
  than worked around with in-place writes and their partial-file window.
- **TTL** measures time since the last read, using unfiltered atime with
  `last_fetch` as the floor. System readers (Spotlight, Quick Look) count as
  reads. Watching opens precisely would need Endpoint Security, which a
  login agent cannot have.
- **Root set** for change detection is materialized + pinned + recently
  viewed (§6.5), not everything ever enumerated.
- **Helper** stays on by default and first in the ladder.
- **Name collisions** (case, normalisation, invalid UTF-8): first wins, the
  rest are hidden and reported.
- **Extended attributes** stay local; `.DS_Store` is swallowed.
- **Remote renames at polling tiers** stay delete + create in v1.
- **Permissions** are mapped to Finder capabilities using `id` from the
  probe; SFTP-only accounts see everything as writable.
- **Pins** live only in the index, with export/import for portability.
- **Content versions** are size + mtime at the polling tiers and gain
  nanosecond mtime + inode wherever the helper or GNU `find` runs.
- **Nickname changes** re-create the domain, because the sidebar name is the
  domain's `displayName` and is fixed at creation. This drops the local cache
  and pending uploads, which is accepted; `set nickname` is refused while
  uploads are pending, and warns about the cache otherwise. S9 may remove
  this caveat.
- **Remote path** defaults to the user's home directory (the SFTP realpath of
  `.`), the same as `sftp`. `--remote-path` overrides it; changing it later
  re-creates the domain.
- **Multiple locations on the same host** are allowed. Each is its own
  domain with its own nickname, connection and cache, so two remote
  paths on one server are two sidebar entries.
- **Symlinks** are native symlinks, never followed, and shown only when
  their target stays inside the share by a lexical check; absolute or
  escaping links are ignored because a server path has no meaning inside the
  mount. A Mac-side item created under a hidden link's name fails with a
  clear error rather than replacing the link. Following links could turn one
  link into a download of the whole server. See §5.7.

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
- **Submitting the cask to homebrew-cask** so the tap is unnecessary.
