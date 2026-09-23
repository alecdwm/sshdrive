# The File Provider extension

The extension is the process the system talks to. It answers `item(for:)` and the working-set
change stream itself, from a read-only view of the index, and forwards everything else to the
agent over XPC. It holds no state of its own.

It implements `NSFileProviderReplicatedExtension`, one instance per domain. The system may host
several instances in one process, so nothing in the extension is global.

## System calls

`item(for:)` and the working set are answered in the extension whenever its index reader is
usable, and by the agent when it is not ([the reader](#the-read-only-index-reader)). Every call
that touches the network or changes anything goes to the agent.

| System call | Who answers | What happens |
|---|---|---|
| `item(for: identifier)` | extension | Read the index row. Never touches the network. With the reader unusable the agent answers from its own connection or, while reconciling, refuses with `.serverUnreachable`. |
| `enumerator(for: .workingSet)` → `enumerateChanges(from:)` | extension | Read the anchors [change detection](change-detection.md) recorded. Never touches the network. With the reader unusable the agent runs the same query on its own connection. The agent is told whenever the extension answers `.syncAnchorExpired` and hands out a fresh anchor ([the index](item-index.md#anchors-and-the-working-set)). |
| `enumerator(for: container)` → `enumerateItems` | agent | `opendir`/`readdir` the mapped path over SFTP, reconcile with the index, return items. Records the folder as recently viewed ([the root set](root-set.md)). |
| `enumerator(for: container)` → `enumerateChanges(from:)` | agent | The same listing, diffed against the index. The system does not call it in practice: a folder is enumerated once, ever, and later changes arrive through the working set ([the root set](root-set.md)). |
| `fetchContents(for:)` / `fetchPartialContents` | agent | Download into the file handle the extension opened on its temp file ([file handles](#file-handles-not-paths)); the extension returns that URL. Partial fetches serve range requests for large media. See [fetch consistency](#fetch-consistency). |
| `createItem` | agent | `mkdir`, `symlink` ([symlinks](symlinks.md)), or upload to a temp name plus a non-overwriting `rename` ([writes](writes.md)). |
| `modifyItem` | agent | By `changedFields`: rename/move (non-overwriting `rename`, every descendant's path rewritten in [the index](item-index.md#renames)); content (upload + `posix-rename`, then a post-upload `lstat` that records the new version, [writes](writes.md)); attributes (`setstat` mtime; execute bits from `fileSystemFlags`, [names and attributes](names-and-attributes.md)); extended attributes (stored locally). |
| `deleteItem` | agent | `remove`, or `rmdir` after a server-side depth-first walk when the recursive option is set ([writes](writes.md#deletes)). |
| `materializedItemsDidChange` | agent | Forwarded so the agent can refresh its [root set](root-set.md) and the [pin safety net](pinning.md). |
| `performAction` | agent | Pin / unpin ([pinning](pinning.md)). |

### Fetch consistency

The agent `lstat`s before and after a download. If size or mtime moved in between, the file
changed under the transfer and the download is made again, once. A file still moving after that
fails the fetch as `.serverUnreachable`, so the system retries later rather than keeping a torn
copy. The returned item carries the version the final `lstat` read.

### What every item carries

- `contentPolicy` ([pinning](pinning.md))
- `capabilities` and `fileSystemFlags` ([names and attributes](names-and-attributes.md))
- `userInfo.kept`, `contentVersion` and `metadataVersion` ([the index](item-index.md#versions))
- `extendedAttributes` from the index

## Error mapping

| Situation | Answer to the system |
|---|---|
| SFTP failure classified as network-related: connect timeout, EOF, `ENETUNREACH`, DNS, `ssh` exiting with a connection error | `.serverUnreachable`, so the system queues and retries |
| Auth or host-key failure | `.notAuthenticated`; the domain shows as needing attention and `sshdrive status` explains why |
| Name held by a hidden symlink or a collision ([names and attributes](names-and-attributes.md), [symlinks](symlinks.md)) | `.filenameCollision` |
| Write fails with a bare `FAILURE`, then `statvfs@openssh.com` on its directory (where offered) shows a full or over-quota filesystem | `.insufficientQuota` |
| Write fails with a bare `FAILURE`, anything else | ordinary sync error: the wire carries no errno ([the SFTP client](sftp.md)) |
| Fetch whose file is still changing after one re-download | `.serverUnreachable` |
| Agent cannot be reached | `.serverUnreachable`, and the domain is disconnected ([connecting](#connecting)) |
| Agent and extension on different XPC interface versions (mid-upgrade) | `.serverUnreachable` until the agent restarts |
| Reader unusable while `meta.reconciling` is set | the agent refuses every File Provider call with `.serverUnreachable` until the walk finishes |

!!! warning "Never `.noSuchItem` for a row that may be rebuilding"
    `.noSuchItem` from `item(for:)` makes the system delete the user's file (`MQ-011`). A missing
    row is only answered `.noSuchItem` after the reader has checked that no rebuild is in progress
    ([the meta check](#the-meta-check)).

## Talking to the agent

### Connecting

The extension connects to the agent's mach service `RWGDZAYBM8.org.shirls.sshdrive.agent` on first
use. launchd starts a registered agent on demand, so the extension does not care whether it was
already running.

If the connection cannot be made - in practice, the user disabled the login item in System
Settings › General › Login Items - the extension calls
`NSFileProviderManager.disconnect(reason:)` on its domain with:

> SSH Drive's background agent is not running. Enable it in Login Items or run `sshdrive doctor`.

Every call then returns `.serverUnreachable`. The next successful XPC connection reconnects and
lifts the disconnect. `sshdrive doctor` checks the login item and prints the same instruction.

A connection that *invalidates* is not the same thing: the system kills idle extension instances
and the connection invalidates as part of that teardown, so disconnecting from the invalidation
handler leaves the domain disconnected for good (`MQ-073`).

### File handles, not paths

Content crosses the boundary as an open file descriptor, never a path. NSXPC carries descriptors
natively.

- **Fetch:** the extension creates the target in its own temp directory
  (`NSFileProviderManager.temporaryDirectoryURL()`), opens it for writing and sends the
  `FileHandle`. The agent writes through it.
- **Upload:** the system gives the extension a URL for the new content; the extension opens it for
  reading and sends the handle. The agent reads it.

The agent never resolves, or needs permission to reach, a path inside the extension's container,
and never opens a file the extension did not hand it. This keeps working if a future macOS
tightens what an unsandboxed process may touch under another process's container.

Directory listings travel as XPC values, paged for directories with tens of thousands of entries.

### Progress and cancellation

A fetch or upload is one long XPC call with a reply block. While it runs, the agent sends byte
counts through a callback on the extension's exported object, and the extension feeds them to the
`Progress` it returned to the system.

Cancelling that `Progress` sends a cancel for the transfer's id over the same connection. The
agent abandons the SFTP requests in flight and removes any temp file it had started on the server
([writes](writes.md)). A transfer whose extension process disappears mid-way, because the system
killed it as idle, is cancelled the same way when the XPC connection invalidates.

Finder offers no cancel control for a third-party download (`MQ-059`), so in practice a cancel
comes from the system abandoning a fetch; the cancellation path is exercised from code.

### Peer code requirement

The agent's listener accepts a connection only from a peer that satisfies a code requirement,
set with `setCodeSigningRequirement` before the connection is resumed:

- signed through Apple's Developer ID chain for team `RWGDZAYBM8`, and
- carrying one of the four identifiers in [components and identifiers](components.md), listed
  explicitly, because the requirement language matches identifiers exactly and has no prefix form.

Debug builds are signed with an Apple Development certificate, so the requirement is generated at
build time from the build's own signing chain: Developer ID in release, Apple Development for the
same team in debug. A release agent never admits a debug client.

Any process of the user can look the service up; only ours get past the delegate. The CLI and
askpass are signed with explicit identifiers from the list, since a bare tool's default identifier
is its product name and would be refused. The requirement matters because the interface can
remove locations and evict caches, and the askpass path ([secrets](secrets.md)) hands out
secrets.

### Interface version

The XPC interface is versioned. A mismatched agent and extension, as happens mid-upgrade, is
reported as `.serverUnreachable` until the agent restarts.

## The read-only index reader

`item(for:)` arrives in bulk and must be answered from local state ([platform facts](platform.md));
an XPC round trip per call would sit on the extension's hottest path. So the extension opens
`domains/<id>/index.sqlite` from the group container, read-only and in WAL mode, and answers
`item(for:)` and the working-set change enumerator from it with no agent involved. Both keep
working while the agent restarts.

This is safe because the agent is the only writer: WAL readers never block the writer and always
see a consistent snapshot. The extension never opens the database for writing, never touches
`capabilities.json` or `config.json`, and sends every mutation and every network operation
through the agent.

A read-only WAL connection still opens the `-shm` file for writing, because readers publish their
read marks through it. The group container is writable by the sandboxed extension, which is what
makes a read-only reader there possible.

### When the reader hands a call to the agent

A call the reader cannot answer goes to the agent; it is never failed. The reader is unusable
when:

- the agent has not yet declared it ready (`indexReady`),
- it was dropped after any SQLite error,
- the schema version is newer than this build understands, or
- `meta.reconciling` is set.

A newer schema degrades a mid-upgrade mismatch to the slow path instead of failing it. While
`reconciling` is set the reader does not read rows that are still being rebuilt; the agent then
refuses with `.serverUnreachable` ([error mapping](#error-mapping)). Readiness, the restore window
and the reconcile are in [the index](item-index.md#reader-readiness).

### The meta check

The `meta` table carries three values the reader checks on every call: the schema version, the
`reconciling` flag and a `generation` counter.

- **One statement per `item(for:)`.** The three values are not read in a statement of their own:
  they ride on the row's query as three scalar subqueries.
- **A missing row is the exception.** There is then no row to carry them, so the check runs on its
  own before `.noSuchItem` is answered. A rebuild in progress must never look like a deletion.
- **`generation`** is bumped by the agent whenever it replaces the database's contents wholesale
  (a restore, see [the index](item-index.md#restore)). The reader hands it to the extension's state
  file from the same read.
- **The inode is stable.** The database file is never replaced under the reader, so no re-`stat`
  is needed.

### A row is a finished item

Everything an item carries that is derived rather than observed is computed by the agent when it
writes the row, and stored on it:

| Derived field | From | Rules |
|---|---|---|
| `capabilities`, `fileSystemFlags` | mode, owner, the probe's identity | [names and attributes](names-and-attributes.md) |
| `kept` | the markers at and above the path | [pinning](pinning.md) |
| `link_target` | the symlink target after the relative rewrite | [symlinks](symlinks.md) |

`item(for:)` is therefore a row read and a field-by-field copy: no ancestor walk, no access to
`capabilities.json`, no second copy of those rules. The cost is that a change to an ancestor's
marker rewrites every known descendant row, paid once per pin change. An extension re-implementing
the rules against a moving index was judged worse.

### Statement cache

Both sides cache compiled statements by SQL text. The index runs a small fixed set of them: a
listing is three statements per entry, an `item(for:)` is one. Compiling afresh is most of what
either costs - without the cache a 2,000-entry listing compiles 8,006 statements and a single
`item(for:)` five.

- A statement is taken out of the cache when handed out and put back, reset and cleared, when its
  caller is done. A second caller asking for the same SQL meanwhile compiles its own, so nothing is
  ever rebound under a live reader.
- A caller that runs one statement for every entry of a listing holds it for the whole pass rather
  than returning to the cache per row ([the index](item-index.md#a-listing-is-one-transaction)).
- `sqlite3_prepare_v2` re-prepares a kept statement after a schema change, so neither the migration
  nor the restore invalidates the cache.
