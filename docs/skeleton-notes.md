# Milestone 1, "Skeleton": what is here

Scaffold for DESIGN.md section 12 milestone 1. Everything the design assigns to
milestones 2 to 10 is a stub with a TODO naming the milestone.

Built and tested on macOS 26.4.1 arm64, Xcode 26.4, Swift 6.3 (Swift 5 language mode),
xcodegen 2.46. `scripts/mac-build.sh` does the sync, generate, `swift test` and
`xcodebuild` loop; the Mac used for it has no signing identities, so it builds ad-hoc
signed. `project.yml` keeps the real Developer ID settings and the script overrides them
on the command line only.

## What compiled and ran

- `swift build` and `swift test` in `Packages/SSHDriveCore`: 24 tests, 0 failures
  (RelativePath validation, the fake transport's non-overwriting rename and its
  invisible-rewrite case, the config store, the index writer and the read-only reader,
  anchors, anchor expiry, subtree path rewriting, `VACUUM INTO` backup).
- `xcodebuild -scheme "SSH Drive"` in **both Debug and Release**: BUILD SUCCEEDED, no
  warnings from our own sources.
- The produced bundle is exactly the tree in section 3:
  `Contents/MacOS/{SSH Drive,sshdrive,sshdrive-askpass}`,
  `Contents/PlugIns/SSHDriveFileProvider.appex`,
  `Contents/Library/LaunchAgents/org.shirls.sshdrive.agent.plist`.
  (`ENABLE_DEBUG_DYLIB: NO` keeps Xcode's debug-dylib split out of `Contents/MacOS`.)
- `sshdrive --help` runs and lists `doctor`, `agent`, `debug`.
- The CLI carries an embedded `__TEXT,__info_plist` whose `CFBundleIdentifier` is
  `org.shirls.sshdrive.cli` (confirmed with `otool -s __TEXT __info_plist`), which is what
  the agent's peer requirement matches; a bare tool's default identifier would be its
  product name and would be refused (section 3.1).
- Both `NSExtensionFileProviderActions` activation rules parse as `NSPredicate`.
- The literal the index uses for the root row equals
  `NSFileProviderItemIdentifier.rootContainer.rawValue`
  (`"NSFileProviderRootContainerItemIdentifier"`), checked on the Mac.

Nothing was run as a login item or connected over XPC: that is spike S1, and it needs a
signed build.

## Real code

| Where | What |
|---|---|
| `Packages/.../XPCProtocols` | `SSHDriveAgentProtocol`, `SSHDriveExtensionProtocol`, the configured `NSXPCInterface`s with their class whitelists, `SSHDriveItemSnapshot`/`SSHDriveItemPage` (NSSecureCoding), `SSHDriveAgentError`, every identifier from section 3.1, and the peer code requirement. |
| `Packages/.../Config` | The section 4 location model, `config.json` in the app-group container, atomic writes, `<name>` resolution (nickname, host, id prefix). |
| `Packages/.../Index` | The full section 5.3 schema (`items`, `anchors`, `roots`, `held`, `meta`), a small SQLite wrapper, `IndexWriter` (agent, sole writer: upsert, delete with its deletion anchor, subtree path rewrite, anchor append/prune/expire, roots, `VACUUM INTO` backup, `reconciling` and `generation`), `IndexReader` (extension, read-only WAL, meta checks, `item`, `children`, change stream with `.syncAnchorExpired`), and the row-to-snapshot conversion both sides share. |
| `Packages/.../SFTP` | `RelativePath` (the section 9.1 chokepoint, byte components), `SFTPTransport`, the section 6.2 error classes, and `FakeTransport`: an in-memory tree with list, fetch, write, rename (non-overwriting), posix-rename, delete, symlink, statvfs, plus the mutation hook. |
| `Packages/.../Logging` | The section 3.1 subsystem and categories. |
| `Apps/Agent` | Two-role `main.swift` (launchd agent vs `open -g` registrar), `SMAppService` registration, the `NSXPCListener` on the group-prefixed mach service with `setCodeSigningRequirement`, `DomainManager` (`NSFileProviderManager.add`/`remove`/`signalEnumerator`), `LocationRuntime` (listing reconcile against the index, fetch through the peer's `FileHandle`, create/modify/delete, catch-up sweep, pin marker), `ItemDerivation` (section 5.4 capabilities and `fileSystemFlags`, stable metadata version), and `ControlCommands` (`doctor` plus the debug hooks). |
| `Apps/FileProvider` | `NSFileProviderReplicatedExtension` with `item(for:)` answered from the read-only index reader and an XPC fallback, container and working-set enumerators, `fetchContents` over a `FileHandle` with a cancellable `Progress`, `createItem`/`modifyItem`/`deleteItem`, `disconnect(reason:)`/`reconnect()` on an unreachable agent, and the agent-error to `NSFileProviderError` mapping. |
| `Apps/CLI` | `sshdrive` on ArgumentParser: `doctor` (fully implemented for the skeleton's checks), `agent start|stop|restart`, and the `debug` group. Pure XPC client, with the `open -g` relaunch of section 8. |
| `Apps/Askpass` | `sshdrive-askpass`: reads the token and `SSH_ASKPASS_PROMPT`, calls the agent, prints the answer. The agent side is the stub. |

## Stubbed, with the milestone named

- `Secrets` (`KeychainSecretsStore`): keys and shape only. Milestone 2.
- `SSHProcess`: `/usr/bin/ssh -V` for `doctor` is real; the master, mux clients,
  ProxyJump chain, login-shell snapshot and `ssh -G` are milestone 2.
- `LocationBackend.sftp` raises "milestone 2" from `DomainManager`; only `.fake` runs.
- `fetchPartialContents` (milestone 3), the temp-file plus rename upload, conflict copies,
  symlink containment, `.DS_Store` (milestone 4), reconcile walk and restore-into-live
  (milestone 5), root-set rotation and the mass-deletion guard (milestone 6), eviction
  (7), real pin/unpin and `performAction` (8), helper (9, placeholder `helper/README.md`).
- Directory paging, name-collision hiding and non-UTF-8 hiding: entries are skipped, not
  yet recorded with `hidden = 2`. Milestone 3.
- Every section 8 command other than `doctor`, `agent` and `debug`.

## `sshdrive debug` hooks, exact syntax

```
sshdrive debug fake add <name> [--files N]        # default 8
sshdrive debug fake remove <name>
sshdrive debug fake list
sshdrive debug tree <name>
sshdrive debug mutate <name> <op> <path> [--to PATH] [--contents TEXT] [--mode OCTAL]
                                               [--target PATH] [--recursive]
        op = create-file | create-dir | create-symlink | write | touch
           | rewrite-invisibly | chmod | rename | delete
sshdrive debug anchor expire <name>
sshdrive debug sweep <name> on|off
sshdrive debug policy <name> <path> eager-keep|lazy|inherit
sshdrive debug index dump <name> [--table items|anchors|roots] [--limit N]
sshdrive debug signal <name>
```

Notes for whoever writes the runbook:

- `fake add` creates the location, seeds the tree, enumerates the root once and adds the
  File Provider domain. `<name>` becomes the nickname and the domain's display name, so
  S3 can compare `nas` against `SSH Drive - nas` by creating two.
- Every `mutate` runs the catch-up sweep afterwards and signals the working set, so a
  mutation reaches Finder the way a remote change would. `rewrite-invisibly` keeps size
  and second-mtime and moves only ns-mtime and inode: that is the case the `generation`
  column exists for (section 5.3).
- For S3's anchor-expiry question, run `sweep <name> off` first, then
  `anchor expire <name>`, so the system's own re-enumeration is visible rather than ours.
- `policy <name> <path> eager-keep` sets the pin marker, serves
  `.downloadEagerlyAndKeepDownloaded` and drops `allowsEvicting`, which is what S6 needs.
- `index dump` prints identifiers, paths, both versions, the derived bitmasks and the
  pin/kept state.
- `Apps/FileProvider/IndexReaderStore.useReader` is the switch for S3's reader-vs-XPC
  measurement. It is a stored property with no CLI hook yet; add one, or flip it in the
  debugger, when running that measurement.

## Verify on Mac (what the compiler could not settle)

1. **The whole of S1.** Nothing here has been signed, registered or connected. In
   particular: that a sandboxed appex reaches the group-prefixed mach service, that
   launchd starts the agent on that lookup, that a `FileHandle` crosses NSXPC and the
   agent can write through it, and that `NSFileProviderManager.add(domain)` from the
   launchd-started agent associates the domain with our extension.
2. **The code requirement strings** in `CodeRequirement.swift`. The marker OIDs and the
   `certificate 1[...] exists` syntax were never evaluated. Check each build's own chain
   with `codesign -v -R="<string>"` against all four executables before trusting the
   listener. Derivation: release uses the Developer ID leaf and intermediate markers,
   debug the Apple Development leaf and the WWDR intermediate, chosen by `#if DEBUG`, so
   a release agent never admits a debug client.
3. **The launchd plist.** `SMAppService.agent(plistName:)` with `BundleProgram`,
   `MachServices`, `AssociatedBundleIdentifiers` and an `EnvironmentVariables` entry
   (`SSHDRIVE_AGENT_ROLE=launchd`, which is how the same binary tells its two roles
   apart) is written from the documentation, not from a working registration.
4. **Section 10 vs section 3.1: the cask `signal:` label.** Section 10 writes
   `signal: ["TERM", "org.shirls.sshdrive"]` while section 3.1 gives the launchd label as
   `org.shirls.sshdrive.agent`. Not resolved here, as instructed: this repo's plist uses
   `Label = org.shirls.sshdrive.agent`. Homebrew matches the bundle id against
   `launchctl list` output, so S1(g) is what decides which string the cask must carry.
5. **An `.app` whose main executable is not an `NSApplication`.** `open -g -a "SSH Drive"`
   is assumed to launch it, let it register and let it exit 0. If LaunchServices objects,
   the fix is `LSBackgroundOnly` or a minimal `NSApplication`.
6. **Restricted entitlements.** `keychain-access-groups` needs a Developer ID
   provisioning profile embedded in the bundle, and
   `com.apple.developer.fileprovider.testing-mode` needs to be accepted for debug builds.
   Neither is exercised by an ad-hoc build.
7. **The extension's read-only WAL reader from inside the sandbox** (S3), including that
   a read-only connection may open `-shm` for writing in the group container, and the
   reader-vs-XPC measurement that decides whether the reader survives at all.
8. **`NSFileProviderManager.disconnect(reason:options:)` called from inside the
   extension** (S5). If it is not allowed, the message lives only in `sshdrive doctor`.
9. **The NSXPC interface at runtime.** The class whitelists, the `Error?` reply
   parameters and the `FileHandle` arguments compile, but only a live connection proves
   the interface accepts them.
10. **`contentPolicy = .inherited` as the neutral value** for an unpinned item, and
    whether Finder's context menu shows our two actions at the top level (S6).
