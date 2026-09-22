# The File Provider extension

The extension is the part of SSH Drive the system talks to. It answers what it
can from the index and hands everything else to the agent over XPC.

## Responsibilities

Implements `NSFileProviderReplicatedExtension`. One instance per domain; the
system may host several instances in one process, so nothing is global.
Every call that touches the network or changes anything is forwarded to
the agent (see Talking to the agent, below); `item(for:)` and the
working-set change stream are answered from the index by the extension
itself whenever its reader is usable, and by the agent when it is not:

| System call | What the agent does |
|---|---|
| `enumerator(for: container)` → `enumerateItems` | `opendir/readdir` the mapped path over SFTP, reconcile with the index, return items. Records the folder as recently viewed ([the root set](root-set.md)). |
| `enumerator(for: container)` → `enumerateChanges(from:)` | Same, diffed against the index. The system does not call it in practice: a folder is enumerated once, ever, and every later change reaches Finder through the working set ([the root set](root-set.md)). |
| `enumerator(for: .workingSet)` → `enumerateChanges(from:)` | Read the anchors recorded by [change detection](change-detection.md) from the index, in the extension. Never touches the network. When the reader is not usable - not yet declared ready, dropped after a SQLite error, a schema newer than this build, or `meta.reconciling` set - the call goes to the agent, which runs the same query on its own connection. The agent is also told when the extension has answered `.syncAnchorExpired` and handed out a fresh anchor ([the index](item-index.md)). |
| `item(for: identifier)` | Read the index row, in the extension. Never touches the network. When the reader is not usable, for the same reasons as the working set, the call goes to the agent, which answers from its own connection or, while reconciling, refuses with `.serverUnreachable`. |
| `fetchContents(for:)` / `fetchPartialContents` | Download through the file handle the extension opened on its temp file; the extension then returns that URL. Partial fetches serve range requests for large media. The `Progress` the extension returns is fed by byte counts from the agent, and cancelling it cancels the transfer. The agent `lstat`s before and after the download; if size or mtime moved in between, the file changed under the transfer and the download is made again, once, after which a still-moving file fails the fetch as `.serverUnreachable` so the system retries later rather than keeping a torn copy. The item returned carries the version the final `lstat` read. |
| `createItem` | `mkdir`, `symlink` ([symlinks](symlinks.md)), or upload-to-temp + non-overwriting `rename` into place ([writes](writes.md)). |
| `modifyItem` | Depending on `changedFields`: rename/move (non-overwriting `rename`, with every descendant's path rewritten in the index, see [the index](item-index.md)), content (upload + `posix-rename`, then a post-upload `lstat` that records the new version, see [writes](writes.md)), attributes (`setstat` mtime; execute bits from `fileSystemFlags`, see [names and attributes](names-and-attributes.md)), extended attributes (stored locally). |
| `deleteItem` | `remove`, or `rmdir` after a server-side depth-first walk when the recursive option is set ([writes](writes.md)). |
| `materializedItemsDidChange` | Forwarded so the agent can refresh its [root set](root-set.md) and the [pin safety net](pinning.md). |
| `performAction` | Pin / unpin ([pinning](pinning.md)). |

Every item carries: `contentPolicy` ([pinning](pinning.md)), `capabilities` and
`fileSystemFlags` ([names and attributes](names-and-attributes.md)),
`userInfo.kept`, `contentVersion` and `metadataVersion`
([the index](item-index.md)), and `extendedAttributes` from the index.

Every SFTP failure classified as network-related (connect timeout, EOF,
`ENETUNREACH`, DNS, `ssh` exiting with a connection error) becomes
`NSFileProviderError(.serverUnreachable)` so the system queues and retries.
Auth and host-key failures become `.notAuthenticated`; the domain then shows
as needing attention and `sshdrive status` explains why. A name held by a
hidden symlink or by a collision ([names and attributes](names-and-attributes.md),
[symlinks](symlinks.md)) becomes `.filenameCollision`.
A write that fails with a bare `FAILURE` is followed by
`statvfs@openssh.com` on its directory where the server offers it; a full
or over-quota filesystem then becomes `.insufficientQuota`, and otherwise
the failure is an ordinary sync error, since the wire carries no errno
([the SFTP client](sftp.md)).

## Talking to the agent

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
by the system and must be answered from local state
([platform facts](platform.md)); a round trip to
the agent for each one would put an XPC call on the hottest path in the
extension. So the extension opens `domains/<id>/index.sqlite` read-only,
in WAL mode, from the group container, and answers `item(for:)` and the
working-set change enumerator from it directly, with no agent involved,
which also means they keep working while the agent is restarting. When
the reader cannot answer, the call is handed to the agent rather than
failed (below and [the index](item-index.md)). The
agent remains the only writer, and that is what makes this safe: WAL
readers never block the writer and always see a consistent snapshot.
Both sides cache their compiled statements by SQL text: the index runs a
fixed and very small set of them, a listing is three statements once per
entry and an `item(for:)` is one, and compiling each afresh is most of
what either costs - without the cache a 2,000-entry listing compiles
8,006 statements and a single `item(for:)` five, against a fixed set of a
handful in all. A statement is taken out of the cache to be
handed out and put back, reset and cleared, when its caller is done, so a
second caller asking for the same SQL while the first is still stepping
compiles one of its own and nothing is ever rebound under a live reader.
Where a caller runs the same statement for every entry of a listing it
holds the one it was handed for the whole pass instead of going back to
the cache per row ([the index](item-index.md)).
`sqlite3_prepare_v2` re-prepares a kept statement after a schema change,
so neither the migration nor the restore needs to invalidate anything. A
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
mode, owner and the probe's identity
([names and attributes](names-and-attributes.md)), the effective `kept`
state from the markers at and above
the path ([pinning](pinning.md)), and the Mac-side `link_target` of a
symlink after the relative rewrite ([symlinks](symlinks.md)).
`item(for:)` in the extension is therefore a
row read and a field-by-field copy, with no ancestor walk, no access to
`capabilities.json` and no second copy of the rules in those pages.
The cost is that a change to an ancestor's marker rewrites every known
descendant row, which the pin path pays once per pin change; the
alternative, an extension that re-implements those rules against a moving
index, was judged worse.

The `meta` table carries three things the reader checks on every call:
the schema version, a `reconciling` flag, and a `generation` counter.
`item(for:)` arrives in bulk, so they are not read in a statement of
their own at all: they ride on the row's own query as three scalar
subqueries, and answering one `item(for:)` is one statement. A row that
is not there is the one exception - there is then no row to carry the
three values, so the check is asked in its own right before
`.noSuchItem` is answered, because a rebuild in progress must never look
like a deletion.
An extension that finds a schema version newer than it understands falls
back to asking the agent for items, which it can always do, so a
mid-upgrade mismatch degrades to the slow path rather than failing. The
same hand-off covers a reader the agent has not yet declared ready and a
reader dropped after any SQLite error. While `reconciling` is set
([the index](item-index.md)) the reader does not read rows that are still
being rebuilt: it hands the call to the agent, and the agent refuses
every File Provider call with `.serverUnreachable` until the walk
finishes, since a missing row answered with `.noSuchItem` would delete
the user's file. `generation` is bumped by
the agent whenever it has replaced the database's contents wholesale (a
restore, see [the index](item-index.md)), and the reader hands it to the
extension's state file from the same read. The database file itself is
never replaced under the reader, so the inode is stable and no re-`stat`
is needed.

**Transfers report progress and can be cancelled.** A fetch or upload is
one long XPC call with a reply block. While it runs, the agent sends byte
counts through a callback on the extension's exported object, and the
extension forwards them to the `Progress` it returned to the system.
Cancelling that `Progress` sends a cancel for that transfer's id over the
same connection; the agent abandons the SFTP requests in flight and
removes any temp file it had started on the server ([writes](writes.md)).
Finder itself offers no cancel control for a third-party download - its
list-row progress ring is not clickable (measured on macOS 26.4,
2026-09-04) - so in practice the cancel comes from the system abandoning
a fetch, and the extension's own cancellation path is exercised from
code. A transfer whose extension process disappears mid-way, because the
system killed it as idle, is cancelled the same way when the XPC
connection invalidates.

The agent's listener accepts a connection only from a peer that
satisfies a code requirement, set with `setCodeSigningRequirement` on
the connection before it is resumed: signed through Apple's Developer
ID chain for team `RWGDZAYBM8` and carrying one of the four identifiers
in [components and identifiers](components.md), listed explicitly, since
the requirement language matches
identifiers exactly and has no prefix form. Debug builds are signed with an Apple Development
certificate, so the requirement is generated at build time from the
build's own signing chain, Developer ID in release and Apple Development
for the same team in debug, and a release agent never admits a debug
client. Every process of the user can look the service up;
only ours get past the delegate. The CLI and askpass are signed with
explicit identifiers from that list, since a bare tool's
default identifier is its product name and would be refused. This matters because the interface can
remove locations and evict caches, and because the askpass path
([secrets](secrets.md)) hands out secrets.

The XPC interface is versioned. A mismatched agent and extension (mid
upgrade) is reported as `.serverUnreachable` until the agent restarts.
