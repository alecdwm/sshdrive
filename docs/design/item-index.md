# Item identifiers and the index

SFTP gives paths; File Provider needs identifiers that survive renames. The agent keeps one SQLite
index per domain, `domains/<id>/index.sqlite`, the only copy of everything SSH Drive knows about
the remote tree. The agent is its sole writer; the extension reads it read-only
([the File Provider extension](extension.md#the-read-only-index-reader)).

## Schema

```
items(identifier TEXT PK, path BLOB UNIQUE, parent TEXT,
      -- path is BLOB: server names are bytes and need not be UTF-8
      type TEXT,                     -- file | directory | symlink
      size INTEGER, mtime INTEGER,   -- whole-second mtime
      mtime_ns INTEGER, inode INTEGER,  -- when the helper or a GNU sweep reports them
      uid INTEGER, gid INTEGER, mode INTEGER,
      generation INTEGER DEFAULT 0,  -- bumped when ns-mtime or inode evidence shows a
                                     -- change SFTP cannot (below)
      content_version TEXT, metadata_version TEXT,  -- the two versions the system holds
      last_fetch REAL,
      pin_state INTEGER DEFAULT 0,   -- 0 inherit, 1 pinned, -1 excluded: the marker
      kept INTEGER DEFAULT 0,        -- effective state, derived by the agent from the
                                     -- markers at and above
      capabilities INTEGER,          -- NSFileProviderItemCapabilities bitmask, derived
      fs_flags INTEGER,              -- NSFileProviderFileSystemFlags bitmask, derived
      link_target BLOB,              -- Mac-side symlink target after the relative
                                     -- rewrite; null for non-links
      hidden INTEGER DEFAULT 0,      -- 1 symlink omitted, 2 name collision, 3 local-only
      xattrs BLOB,                   -- Finder tags and other extended attributes, local
      local_content BLOB)            -- bytes of a local-only item such as .DS_Store
anchors(seq INTEGER PK AUTOINCREMENT, changed_identifier TEXT,
        change_kind TEXT,            -- modified | deleted
        at REAL)                     -- when the change was recorded
roots(path BLOB, reason TEXT,        -- materialized | pinned | viewed
      last_seen REAL,                -- when the reason was last refreshed; the viewed LRU key
      last_listed REAL DEFAULT 0,    -- when tier 0 last listed it; the rotation key
      PRIMARY KEY (path, reason))    -- the change-detection root set; one directory may
                                     -- carry several reasons, and leaves the set only
                                     -- when the last one goes
held(path BLOB PK, dir BLOB, first_missing REAL, recheck_at REAL,
     checks INTEGER DEFAULT 0,       -- re-checks made, at 5 and 30 minutes
     reason TEXT)                    -- why the deletion is held, for status
                                     -- (the mass-deletion guard)
meta(key TEXT PK, value TEXT)        -- schema_version (3), reconciling, generation,
                                     -- remote_root, sweep_server_time, last_full_sweep,
                                     -- watch_tier
```

| Columns | Explained in |
|---|---|
| `pin_state`, `kept` | [pinning](pinning.md) |
| `capabilities`, `fs_flags`, `hidden`, `xattrs`, `local_content` | [names and attributes](names-and-attributes.md) |
| `link_target` | [symlinks](symlinks.md) |
| `roots` | [the root set](root-set.md) |
| `held`, and the tiers that fill `mtime_ns` and `inode` | [change detection](change-detection.md) |

## Identifiers

- **An identifier is a UUID minted the first time a path is seen,** from a generator seeded once
  per process rather than from the platform's per-call entropy. A first listing of a
  10,000-entry directory mints 10,000 of them, and an identifier is a local name for a row, never
  a secret or a capability.
- **The root is a permanent row** with the empty path and the identifier
  `NSFileProviderItemIdentifier.rootContainer`, created with the domain, so it can carry a pin
  state and xattrs like any other item.

## Renames

- **A user rename or move** (`modifyItem`) updates `path` and keeps the identifier.
- **Moving a directory** rewrites, in one transaction, `path` on every descendant row and on the
  matching rows of `roots` and `held`. In `held` that means `held.dir` as well as `held.path`: the
  guard's 5- and 30-minute re-checks re-list that directory, and a `dir` left at the old name would
  be re-listed for ever and never resolve. Pin markers need nothing extra, since `pin_state` lives
  on the same rows.
- The rewrite is O(subtree) per directory rename, the price of path-keyed tables. `parent` is kept
  beside `path` so it can walk by identifier rather than by string prefix.
- **A rename the helper reports** (tier 2, [change detection](change-detection.md)) is applied the
  same way, identifier kept.
- **A helper rename onto a path that already has a row** is applied as a *modify* of the
  destination's identifier, and the source row is deleted. Editors save by writing a temp file and
  renaming it over the original; applied literally, that would give the original's path the temp
  file's identifier and lose its Finder tags and cached content. The helper's ignore rules
  suppress events *about* temp names but still report a rename *out of* one, so a save through
  `.file.swp` or `file~` reaches the index as one content change to `file`.
- **Remote renames at the polling tiers** (tiers 0 and 1) appear as delete + create.

## Versions

### Content version

```swift
content_version = "\(size)-\(mtime)-\(generation)"   // mtime in whole seconds
```

The format is the same at every tier. Size and mtime must be reproducible from a plain SFTP v3
`lstat`, because:

- that is all the conflict check in [writes](writes.md#conflicts) has in hand, and
- a location can change tier mid-session. A tier-dependent format would turn every tier change
  into a modification of every item, and every save on a helper-tier location into a conflict.

**`mtime_ns` and `inode`** come from the helper or a GNU `find` sweep and are used only by change
detection. When either differs from the stored value while size and second-mtime do not (two
writes of equal size within one second, a `cp -p` that preserved mtime), the agent bumps the row's
`generation`. That changes the version and makes the system re-fetch.

Both columns are nullable; null means "unknown: record whatever comes next without comparing".
They are null on a fresh row and **reset to null after every upload of the agent's own**
([writes](writes.md#after-the-upload)). A temp-file-plus-rename upload gives the path a new inode
and ns-mtime that SFTP `lstat` cannot read back, so the stored values are stale the moment it
lands; comparing against them would bump the generation on the next helper event or GNU sweep and
make the system re-fetch the file it just wrote.

### What the conflict check compares

All three fields of the content version, from two sources:

| Field | Source |
|---|---|
| size, mtime | the `lstat` the check has just made |
| generation | the row (the wire cannot carry it) |

Comparing only the `lstat` fields would let a save land on exactly the same-size, same-second
remote change the generation exists to catch.

### Metadata version

The system re-reads an item only when its own version moves. The metadata version is:

| Component | Why it is there |
|---|---|
| the content version | |
| `mode`, `uid`, `gid` | |
| derived `capabilities` and `fs_flags` | a change of the `permissions` setting or of the probed identity recomputes them without touching the mode ([names and attributes](names-and-attributes.md)) |
| effective `kept` (not the marker) | a child's kept state changes when an ancestor is pinned ([pinning](pinning.md)) |
| a hash of the stored `xattrs` blob | moves the version when the *agent* changes the blob, e.g. a restore from backup (`MQ-079`, [names and attributes](names-and-attributes.md#finder-tags)) |

## Deleted rows are deleted

When an item is reported deleted - by a Finder `deleteItem`, a listing diff, a helper delete
event, or the mass-deletion guard applying a held deletion ([change detection](change-detection.md))
- its row is removed in the same transaction that writes the deletion anchor, and its `pin_state`
and `xattrs` go with it.

- **No tombstones.** A path re-created later is a new item with a new identifier; the system drops
  the old cache and Finder tags as it does for any deleted item.
- **What that costs:** a remote rename-and-back at the polling tiers, and any Mac app whose atomic
  save reaches the extension as `createItem` + `deleteItem`, which loses an explicit pin or tag on
  that file. The ordinary atomic save is not one of them: TextEdit and a shell temp+rename both
  arrive as one `modifyItem` on the original item (`MQ-049`).
- **No dangling pins.** A pin marker vanishes with its path, so `sshdrive pins` never shows one.
  The only pin that outlives its item is on a directory whose deletion the guard is holding.
- **Local-only rows are the exception** (`hidden = 3`,
  [names and attributes](names-and-attributes.md#ds-store)). They have no remote content, so a
  `readdir` that does not mention one is no evidence it went, and the differ skips it. Only a
  `deleteItem` removes one.

## A listing is one transaction

Every row and every anchor a `readdir` produces is written inside a single `BEGIN IMMEDIATE`.
Row by row, a 10,000-entry directory is 10,000 autocommits, each its own WAL frame, and that - not
the wire, which reads it in a tenth of a second (`SQ-051`) - is what the enumeration spends its
time on: `ls` of such a directory through the mount failed with `fts_read: Operation timed out`
row by row and completed in one transaction (measured 2026-09-04).

### Nesting

The listing's body calls things that are each a transaction of their own (the deletion, which
writes a row and its anchor together). SQLite has no nested `BEGIN`; a second one fails with
`cannot start a transaction within a transaction` and takes the listing with it. So the index's
transaction helper **nests**, using a `SAVEPOINT` for every level below the outermost.

- **A deletion** takes one level.
- **An anchor takes none.** An `INSERT` is atomic on its own, nothing inside the batch catches an
  error, and a throw rolls the whole listing back either way. A `SAVEPOINT` and `RELEASE` per
  anchor would be four thousand `sqlite3_exec` calls in a two-thousand-entry listing for nothing.
  Its sequence number comes from `sqlite3_last_insert_rowid`, not a `SELECT`.

### The transaction holds the writes and nothing else

The location is an actor and the batch is synchronous SQLite, so while the transaction is open
every other call on that location - a fetch, a write, `sshdrive status` - waits behind it.

- **Before `BEGIN IMMEDIATE`,** for every entry: the path construction, the read of the incumbent
  row, and the `RowBuilder` call that turns the two into a finished row. Reading incumbents
  outside the transaction is safe because the agent is the only writer and there is no suspension
  point between the reads and the batch.
- **Inside:** the upserts, the anchors, then the deletion pass. Rows and anchors land interleaved,
  in listing order; the deletion pass runs after all of them.
- **An unchanged row is not written.** `IndexItem` is the whole of what an upsert binds, so an equal
  row is a no-op; it also carries the same metadata version and `hidden`, which decide the anchor,
  so skipping it cannot change which anchors the listing appends.

### Once per listing, not once per entry

The incumbent rows are read on one compiled statement, bound once per path and answered in the
order asked. The write pass holds the row statement and the anchor statement open for its whole
length. Ten thousand entries cost three statement executions each and a handful of compilations in
all, not a cache trip, a wrapper and two resets per row
([statement cache](extension.md#statement-cache)).

## Anchors and the working set

The working set is only ever a change stream. `enumerateItems` on it returns no items and the
current sequence number as the anchor (`MQ-002`).

### Pruning and expiry

- `anchors` is pruned to the newest **30 days** and the newest **1,000,000 rows**, both limits
  applying. The row cap is generous on purpose: a pin change writes an anchor per known descendant
  ([pinning](pinning.md)), and a cap in the tens of thousands would let one pin of a large tree
  push out the anchor the system last saw. Anchor rows are a few dozen bytes each.
- An anchor the index no longer knows (older than the oldest kept row, or the index was rebuilt)
  is answered `.syncAnchorExpired`. Pruning and rebuilds are its only two sources; the system
  re-asks from a fresh anchor (`MQ-006`).
- **Expiry triggers a full sweep.** The reader that answers expiry is the extension, which sees
  nothing of the agent's schedule, so when it hands out a fresh anchor it tells the agent over XPC,
  one call per expiry. Expiry alone is lossy: what changed between the pruned anchor and the fresh
  one is in no listing the system will ask for. The agent treats it like a reconnect
  ([change detection](change-detection.md)): one full sweep of the root set at once, every
  difference from the index becoming an anchor after the fresh one.
- **A container enumerator** hands out the same sequence number and its `enumerateChanges` never
  expires it: a folder refresh is a fresh listing diffed against the index, whatever anchor the
  system holds.
- **An anchor whose identifier has no row** is reported as a deletion. Only a deletion removes a
  row, so the deletion anchor that removed it is further along the same stream.

### When the reader is not usable

The reader is unusable when the `indexReady` call has not come back, the agent answered no, the
schema is newer than the extension understands, or the file could not be opened. The working-set
`enumerateChanges` then **asks the agent for the same change stream** over XPC
(`enumerateWorkingSetChanges`). The agent answers from the writer's connection with the same query
the reader runs (`IndexChangeStream`), so the two cannot drift.

!!! warning "Never an empty change set, and `.serverUnreachable` only for an unreachable agent"
    - **No empty answer.** The system launches a fresh extension instance for every working-set
      signal (`MQ-003`), so the first `enumerateChanges` races the readiness call. "No changes" at
      the anchor the system holds tells it that it is up to date, and the change is dropped until
      something else signals (`MQ-004`) - a deleted file then sits in Finder indefinitely.
    - **`.serverUnreachable` is reserved for an agent that cannot be reached,** the one case with
      nothing to say. fileproviderd throttles a change enumeration that keeps failing, on a
      doubling schedule, and a throttled domain stops receiving server-side changes at all while
      listings, `item(for:)` and uploads keep working (`MQ-005`).

Clearing the throttle:

- The extension calls `signalErrorResolved(.serverUnreachable)` on its own domain the first time a
  change enumeration succeeds after one has failed. A signalled enumerator is re-scheduled, not
  un-throttled; only that call clears the backoff.
- The agent makes the same call once per mounted location at start, the only way to clear a
  backoff left by an earlier run.

## Backup

The index is the only copy of the identifiers SSH Drive holds, but not the only copy that exists:
the system's replica holds every identifier it was given, keyed by the file it shows the user.
The index runs in WAL mode, and the agent takes `VACUUM INTO domains/<id>/index.sqlite.bak`:

- once a day,
- after a reconcile,
- after pin changes, debounced to at most one per minute, so a Finder multi-select that pins
  hundreds of items produces one backup.

`pins.json` beside the index is a second, human-readable copy of the pin markers, written on every
change.

## Restore

The health check and the restore run at location start. A corrupt index is restored from the
backup, with the anchors since then expired, and always **into the live database, never over
it**.

1. **If SQLite cannot open the file at all:**
    1. Ask the extension, through the callback interface it already uses for transfer progress, to
       close its reader and answer `.serverUnreachable` until told to reopen. This comes first
       because the reader has the `-shm` mapped, and truncating a mapped file under a live
       process faults it on its next access.
    2. Truncate the database and its `-wal` and `-shm` sidecars to zero length, under their own
       inodes. The sidecars go because a zero-length database with a surviving WAL would have that
       WAL replayed into it.
2. **Copy the backup in** with the online backup API (`sqlite3_backup_init`, the live connection
   as destination) in one write transaction, and bump `meta.generation`.
3. **Set `meta.reconciling`** and leave it set; the [reconcile walk](#reconcile-against-the-replica)
   clears it.
4. If the extension was closed in step 1, ask it to reopen.

Replacing the file at the path is wrong twice over: the `-wal` and `-shm` sidecars belong to the old
inode, so a stale WAL would be replayed into the new file on first open; and the extension's
reader, which holds the database open across calls, would keep reading the unlinked file.

### Reader readiness

An extension instance the system launches between the close and the truncate is covered by one
rule at reader open: before an instance opens the index for the first time it asks the agent
whether the index is ready. An agent mid-restore answers no, so the instance opens nothing and
sends every read to the agent until the answer changes.

- **"Not ready" is a window, not a verdict.** The agent answers no for any location whose runtime
  is not up yet - a domain restart, an upgrade handover - which lasts a few seconds. An instance
  that held the answer for its whole life could never read the index again. So every read that
  meets a non-ready answer asks again, no more often than every couple of seconds. The rule is a
  value with tests of its own, `IndexReaderReadiness`.
- **A schema newer than the extension understands is the one permanent answer:** waiting does not
  make it readable.
- **A reader shut for a truncate** (`closed`) is lifted by the reopen callback and by nothing else.
- **An instance the system tears down** closes its reader and reports `exited`, a state of its
  own and not the restore's `closed`. It is final for that instance: no later answer, failure or
  reopen lifts it. A schema too new is kept instead, because it describes the index. The next
  instance starts over.
- **An agent that cannot be reached at all** leaves the instance free to open the reader; a missing
  agent is the case the direct reader exists for.
- **Any SQLite error** - a corrupt page, a not-a-database header during the truncate window, a
  missing table - drops the reader and sends that call to the agent. It is never answered
  `.noSuchItem`, so a rebuild in progress cannot look like a deletion.

The extension writes what it last knew about its reader - state, the `meta.generation` it last
saw, the last error, and when - to `domains/<id>/reader-state.json`, which `sshdrive doctor`
reports: `ready` and `exited` pass, every other state warns ([the CLI](cli.md#doctor)). The
states are `unknown`, `ready`, `not-ready`, `schema-too-new`, `closed`, `failed` and `exited`. It is the one file the extension writes in the container besides the `-shm`. The
extension is sandboxed, short-lived and usually not running when the question is asked, so the
last thing it said is the only evidence there is.

## Reconcile against the replica

After a restore, and also when there is no backup at all, the index is reconciled against the
replica before anything is re-enumerated. For each entry of the mount under
`~/Library/CloudStorage`:

1. Walk with `readdir` and `lstat` only. Never open a file: that would materialize it.
2. Call `NSFileProviderManager.getIdentifierForUserVisibleFile(at:)`.
3. For a path without a row, create one with the identifier the system already knows, the name,
   the type, and a content version rebuilt from the same `lstat`: `"\(size)-\(mtime)-0"`.

The replica file's size and mtime are the values the system was given for the item, dataless or
not. So an item whose generation was never bumped comes back with exactly the version the system
holds and is not re-fetched; only an item whose generation had moved, which the walk cannot know,
is fetched again. Leaving versions null instead would move every materialized item's version on
the next listing, re-download the whole cache, and turn every pending edit into a conflict.

| Case | Outcome |
|---|---|
| Item listed in `enumeratorForPendingItems()` | Version left null: the replica file holds the pending edit, so its size and mtime are the edit's. It comes back through its own `modifyItem`, whose post-upload `lstat` sets it. |
| Backup row's identifier differs from the replica's (deleted and re-created after the backup) | The replica's identifier wins, since the user's file is keyed by it. The old row's pin marker and xattrs go with the old identifier, as for any deletion. |
| Item created since the backup | Keeps its identifier and its cache instead of coming back as delete + create. |
| Item the replica has never seen | Minted fresh on its next enumeration. |
| Every row | The metadata version moves (mode, owner and the xattr hash are not in the replica): a metadata re-read, not a transfer. |

The walk cannot recover what only the index held: pin markers come back from `pins.json`, local
xattrs only from the backup.

### Service stalls during the walk

While `meta.reconciling` is set, every enumeration and fetch for the domain is answered
`.serverUnreachable` by the agent, and `item(for:)` and the working set the same way by the
extension. The system serves the walk from the replica.

- **Why the agent stalls:** reading a directory the system considers stale triggers
  `enumerateItems`, and an agent with an empty index would mint fresh identifiers for everything in
  it before the walk got there.
- **Why the flag is needed as well:** the agent-side stall alone would leave the extension answering
  `item(for:)` from a half-built index, and a row not written yet reads as `.noSuchItem`, which
  deletes the file.
- **It outlives a crash:** an agent that starts and finds `reconciling` set redoes the walk before
  serving anything, since nothing else will clear it.
- **Resuming:** when the flag is cleared, the agent calls `signalEnumerator` for the working set so
  the system re-asks for what it was refused.

### Ordering and bounds

- **The walk runs after `NSFileProviderManager.add(domain)`,** never inside location start: it reads
  the system's replica, and `getUserVisibleURL` has nothing to answer until the domain exists.
  The restore therefore leaves the flag set and the walk clears it (gotcha 76).
- **The walk has a deadline and an item cap,** because a replica of a million materialized files
  must not stall a domain indefinitely. A walk that hits either limit **still clears the flag**:
  the alternative is a domain stalled for ever. The paths it never reached get fresh identifiers
  on their next enumeration - the delete-plus-create the walk exists to avoid for the paths it did
  reach.
