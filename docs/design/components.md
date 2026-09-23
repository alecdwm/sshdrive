# Components and identifiers

SSH Drive is four executables in one app bundle plus a helper binary uploaded to servers. The
background agent owns everything of consequence; the extension, the CLI and askpass are thin XPC
clients of it.

Two words are used strictly on these pages. **The agent** is SSH Drive's own background process. A
**key agent** is `ssh-agent`, 1Password, Secretive, or anything else that answers on
`SSH_AUTH_SOCK`; the literal `ssh` message `agent refused operation` refers to one of those.

## Bundle layout

```
SSH Drive.app                          (LSUIElement agent app, Developer ID signed, notarized)
├── Contents/MacOS/SSH Drive           host process: the background agent (SSH, SFTP, index,
│                                      change detection, eviction, XPC server)
├── Contents/MacOS/sshdrive            the CLI (symlinked into PATH by the Homebrew cask)
├── Contents/MacOS/sshdrive-askpass    SSH_ASKPASS program: relays ssh's prompts to the agent
│                                      (secrets.md)
├── Contents/PlugIns/SSHDriveFileProvider.appex
│                                      File Provider extension: a thin XPC client of the agent
├── Contents/Resources/helper/sshdrive-helper-<ver>-<os>-<arch>
│                                      static remote helper binaries + sha256 manifest
│                                      (change-detection.md, tier 2)
└── Contents/Library/LaunchAgents/org.shirls.sshdrive.agent.plist
                                       registered via SMAppService.agent
```

## The shared package

```
Shared Swift package: SSHDriveCore
├── Config         location model, JSON store in the app-group container
├── Secrets        keychain wrapper (shared access group, data-protection keychain)
├── SFTP           SFTP v3 wire-protocol client over a byte stream, plus OpenSSH extensions
├── SSHProcess     spawns and supervises ssh, ControlMaster, exec channels
├── Index          SQLite path <-> item identifier index, per domain
├── XPCProtocols   the agent's interfaces for the extension and the CLI
├── XPCInterfaces  the @objc NSXPC half of those interfaces (macOS only)
├── AgentCore      the decision types the agent's parts share, all pure and clock-injected
├── ProviderCore   everything the extension decides, behind platform-free protocols
├── AgentRuntime   everything the agent decides, behind the protocols of one AgentEnvironment
└── Logging        os.Logger subsystems, shared by all processes
```

The four executables are adapters. They translate between Apple's types and the package and hold
no branch worth testing; a new rule belongs in `ProviderCore` or `AgentRuntime` with a scenario
([testing](testing.md)).

## What each process does

### Extension

Mandatory, sandboxed, ephemeral.

- Answers `item(for:)` and the working-set change stream from the domain's index, which it opens
  read-only ([the extension](extension.md)).
- Translates every other system call (list, fetch, create, modify, delete) into one XPC call to the
  agent and passes the reply back.
- Holds no state, opens no sockets, never writes the index.
- Its only other file I/O: the temp file the system gives it for fetched content, whose handle it
  passes to the agent to fill, and `domains/<id>/reader-state.json`, where it records the state of
  its index reader for `sshdrive doctor` ([the index](item-index.md)).
- Calls `disconnect(reason:)` and `reconnect()` on its own domain when the agent cannot be reached
  ([the extension](extension.md)). This is the one case where a process other than the agent
  changes domain state, because the agent is not there to do it. Its other uses of
  `NSFileProviderManager` (the temp directory, `signalEnumerator`) change nothing.

### Agent

An invisible `SMAppService` login agent.

- Its plist sets `RunAtLoad` and `KeepAlive` with `SuccessfulExit` false: it runs from login rather
  than from the first mach lookup, comes back after a crash, and stays down after a deliberate exit
  until the next lookup ([packaging and install](packaging.md)). Running from login matters because
  the poll schedule, the eviction loop, the kept-subtree refresh and the wake handler are its own
  timers and would otherwise not run until Finder touched a domain.
- Owns the `ssh` processes, the SFTP sessions, the per-domain index, the change detection streams,
  the eviction loop, and the domain lifecycle (`add`, `remove`, `signalEnumerator`, `evictItem`).
- Is the only writer of the index and, apart from the extension's `disconnect`/`reconnect` above,
  the only process that changes domain state through `NSFileProviderManager`.

### CLI

The only user interface, and a pure XPC client: every command is a request to the agent, so the CLI
never touches the network, the keychain or File Provider, and can be invoked through any path,
including the Homebrew symlink. Even `sshdrive add` does not run `ssh`: the agent makes the
verification connection in its own environment and the CLI only relays prompts to the terminal
([secrets](secrets.md)).

### askpass

The program `ssh` calls for every prompt. A pure XPC client that reads nothing itself: it forwards
the prompt to the agent with a one-time token and prints the agent's answer
([secrets](secrets.md)).

### Why the agent owns everything

- The agent is not sandboxed, so `ssh` reads `~/.ssh/config`, talks to `ssh-agent`, runs
  `ProxyCommand` and uses FIDO keys exactly as in a terminal. That is what makes the auth promise
  of [goals and non-goals](goals.md) true.
- The long-running watch streams ([change detection](change-detection.md)) live in the one process
  allowed to be long-running.
- The index has a single writer.

The cost is that the mount depends on the login agent being enabled ([the extension](extension.md)).

## Shared state

The app-group container is `~/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive/`:

```
config.json                  schema version, the install's macId (writes.md), locations (no secrets)
domains/<location-id>/
    index.sqlite             path <-> identifier map, versions, last-fetch times, pins, xattrs
                             (written only by the agent; read by the agent and the extension,
                             extension.md)
    index.sqlite.bak         the agent's periodic backup of the index, restored into the live
                             database when the index is corrupt (item-index.md)
    pins.json                write-only copy of the pin markers, read only to restore them
                             after a rebuild (pinning.md, item-index.md)
    reader-state.json        the extension's last word on its read-only reader; the one file
                             the extension writes here (extension.md)
    capabilities.json        cached server probe (cli.md)
```

Secrets (passwords, key passphrases) are never in `config.json`. They go in the keychain under
access group `RWGDZAYBM8.org.shirls.sshdrive`, keyed `password:<user>@<hostname>:<port>` or
`passphrase:<keypath>`, shared by every location that names the same item, and read and written
only by the agent ([secrets](secrets.md)).

## Identifiers

| Thing | Value |
|---|---|
| Apple Developer Team ID | `RWGDZAYBM8` |
| App bundle (`SSH Drive.app`) | `org.shirls.sshdrive` |
| File Provider extension (`.appex`) | `org.shirls.sshdrive.fileprovider` |
| Background agent launchd label | `org.shirls.sshdrive.agent` |
| CLI and askpass executables | `sshdrive`, `sshdrive-askpass`, signed as part of the app with the explicit signing identifiers `org.shirls.sshdrive.cli` and `org.shirls.sshdrive.askpass`; a bare tool's default identifier is its product name, which would fail the agent's code requirement ([the extension](extension.md)) |
| App group | `RWGDZAYBM8.org.shirls.sshdrive` (macOS app groups are Team-ID prefixed) |
| Keychain access group | `RWGDZAYBM8.org.shirls.sshdrive` (same string, listed under `keychain-access-groups`) |
| XPC mach service (agent ↔ extension, agent ↔ CLI) | `RWGDZAYBM8.org.shirls.sshdrive.agent` (app-group prefixed so the sandboxed extension may connect) |
| `os.Logger` subsystem | `org.shirls.sshdrive`, categories `extension`, `agent`, `cli`, `sftp`, `ssh` |
| Finder mount root | `~/Library/CloudStorage/`, the directory name derived by the system ([platform facts](platform.md)) |
| Homebrew cask | `sshdrive`, in the tap `alecdwm/tap` (repo `alecdwm/homebrew-tap`, see [packaging and install](packaging.md)) |
| Source repository | `https://github.com/alecdwm/sshdrive` |
| Domain identifier | the location's UUID ([the location model](locations.md)) |

## Entitlements

| Target | Entitlements | Notes |
|---|---|---|
| Extension | `com.apple.security.app-sandbox`, `com.apple.security.application-groups`, `com.apple.developer.fileprovider.testing-mode` (debug builds only) | The app group is required to connect to the group-prefixed mach service. No network entitlement: the extension never opens a socket. |
| App / agent | hardened runtime, `com.apple.security.application-groups`, `keychain-access-groups` | Not sandboxed ([security](security.md)). `keychain-access-groups` is restricted and needs a Developer ID provisioning profile, which only a bundle can embed; the bundle carries one, so the agent, as its main executable, is the only process with keychain access. |
| CLI and askpass | hardened runtime only | Bare executables in `Contents/MacOS` cannot embed a profile, and need no entitlement: both are pure XPC clients of the agent ([secrets](secrets.md)). |

!!! warning "A profile only authorises its own certificate"
    Signed with a different Developer ID Application certificate than the profile names, every
    restricted entitlement is unsatisfied: `amfid` answers `-413 "No matching profile found"` and
    the agent is SIGKILLed at exec, after notarizing and stapling perfectly
    ([packaging and install](packaging.md); gotcha 91).
