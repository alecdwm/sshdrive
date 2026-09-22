# Item identifiers and the index

SFTP gives us paths, not IDs. The File Provider system needs identifiers that
stay stable across renames. The agent keeps a per-domain SQLite index, the
only copy of everything we know about the remote tree:

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

The marker and effective-state columns are described in [pinning](pinning.md),
the derived bitmasks in [names and attributes](names-and-attributes.md),
`link_target` in [symlinks](symlinks.md), the root set in
[the root set](root-set.md), and `held` and the tiers that fill `mtime_ns`
and `inode` in [change detection](change-detection.md).

- Identifier = UUID minted the first time we see a path, from a
  generator seeded once per process rather than from the platform's
  per-call entropy: a first listing of a ten-thousand-entry directory
  mints ten thousand of them, and an item identifier is a local name for
  a row, never a secret and never a capability. The root is the
  one exception: it is a permanent row with the empty path and the
  identifier `NSFileProviderItemIdentifier.rootContainer`, created when the
  domain is, so it can carry a pin state and xattrs like any other item.
- Rename/move initiated by the user (via `modifyItem`) updates `path` and keeps
  the identifier. Moving a directory rewrites `path` on every descendant
  row, and on the matching rows of `roots` and `held` - `held.dir` as
  well as `held.path`, since the guard's 5- and 30-minute re-checks are
  driven by re-listing that directory ([change detection](change-detection.md))
  and a `dir` left at the old
  name would be re-listed for ever and never resolve - in one transaction;
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
  all the conflict check in [writes](writes.md) has in hand, and because a
  location can change tier mid-session: a version whose format depended on
  the tier would turn every tier change into a modification of every item and
  every save on a helper-tier location into a conflict. So the nanosecond
  mtime and inode that the helper or a GNU `find` sweep report are stored
  in their own columns and used only by change detection: when either
  differs from the stored value while size and second-mtime do not (two
  writes of equal size within one second, a `cp -p` that preserved mtime),
  the agent bumps the row's `generation`, which changes the version and
  makes the system re-fetch. Both columns are nullable, and null means
  "unknown: record whatever comes next without comparing". They are null
  on a fresh row and are **reset to null after every upload of the
  agent's own** ([writes](writes.md)): a temp-file-plus-rename upload gives
  the path a new inode and a new ns-mtime that SFTP `lstat` cannot read back,
  so the stored values are stale the moment the upload lands, and comparing
  against them would bump the generation on the next helper event or GNU
  sweep and make the system re-fetch the file it just wrote. The conflict
  check compares all three fields, but from two sources: size and
  mtime from the `lstat` it has just made, and generation from the row,
  since the wire cannot carry it. Comparing only the `lstat` fields would
  let a save land on top of exactly the same-size, same-second remote
  change that the generation exists to catch. Metadata version = content
  version plus mode, uid, gid, the derived `capabilities` and `fs_flags`
  (a change of the `permissions` setting or of the probed identity
  recomputes those without touching the mode, see
  [names and attributes](names-and-attributes.md), and the system
  re-reads an item only when its version moves), the effective `kept`
  state (not the
  marker: a child's kept state changes when an ancestor is pinned, and
  the system re-reads an item only when its own version moves, see
  [pinning](pinning.md)),
  and a hash of the stored `xattrs` blob, so that accepting a tag change
  always returns a new metadata version and the system never
  re-offers a change it already made.
- A rename reported by the helper (tier 2,
  [change detection](change-detection.md)) whose destination path
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
  helper, or the mass-deletion guard applying a held deletion
  ([change detection](change-detection.md)), its
  row is removed in the same transaction that writes the deletion anchor,
  and its `pin_state` and `xattrs` go with it. There are no tombstones: a
  path that is re-created later is a new item with a new identifier, and
  the system drops the old cache and Finder tags exactly as it does for
  any deleted item. That is the price of the simplest rule, and it is
  paid in two places: a remote rename-and-back at the polling tiers, and
  any Mac app whose atomic save reaches the extension as a `createItem`
  plus `deleteItem` rather than a content modification, which loses an
  explicit pin or tag placed on that one file. The ordinary atomic save
  is not one of them: TextEdit and a shell temp+rename both arrive as a
  single `modifyItem` on the original item, so the identifier survives
  and the rule costs nothing there (measured on macOS 26.4, 2026-09-04).
  A pin marker on a path that vanishes vanishes
  with it, so `sshdrive pins` never shows a dangling pin; the only pin
  that outlives its item is one on a directory whose deletion the guard
  is currently holding. A **local-only** row (`hidden = 3`, see
  [names and attributes](names-and-attributes.md)) is the
  one exception to the listing half of this rule: it has no remote content
  by definition, so a `readdir` that does not mention it is not evidence
  that it went, and the differ skips it. Only a `deleteItem` removes one.
- **A listing is one transaction.** Every row and every anchor a
  `readdir` produces is written inside a single `BEGIN IMMEDIATE`, not
  row by row. A directory with 10,000 entries is 10,000 autocommits
  otherwise, each its own WAL frame, and that - not the wire, which
  reads the same directory in a tenth of a second - is what a large
  enumeration spends its time on: `ls` of a 10,000-entry directory
  through the mount timed out (`fts_read: Operation timed
  out`) row by row and completed in one transaction (2026-09-04).
  That listing's own body calls two things that are each a transaction in
  their own right - the deletion above, which writes the row and its
  anchor together, and the anchor appended for every changed row - and
  SQLite has no nested `BEGIN`, so a second one fails with `cannot start
  a transaction within a transaction` and takes the listing with it.
  So the index's transaction helper **nests**, with `SAVEPOINT` for every
  level below the outermost, which is what lets a rule about the whole
  listing and a rule about one row's atomicity both hold.
  The anchor is the one thing that takes no level of its own: an `INSERT`
  is atomic by itself, nothing inside the batch catches an error, and a
  throw rolls the whole listing back either way, so a `SAVEPOINT` and a
  `RELEASE` per anchor - four thousand `sqlite3_exec` calls in a
  two-thousand-entry listing - would buy nothing. Its sequence number
  comes from `sqlite3_last_insert_rowid` rather than from a `SELECT` of
  its own. The deletion, which writes a row and its anchor together,
  takes one level.
  **The transaction holds the writes and nothing else.** The rule is that
  a listing lands atomically, not that everything a listing does happens
  under the write lock: the path construction, the read of the incumbent
  row and the `RowBuilder` call that turns the two into a finished row
  are done for every entry *before* the `BEGIN IMMEDIATE`, and what the
  transaction then contains is the upserts, the anchors and the deletion
  pass. This matters because the location is an actor and the batch is
  synchronous SQLite, so for as long as the transaction is open every
  other call on that location - a fetch, a write, `sshdrive status` -
  is waiting behind it; reading the incumbents outside it is safe for the
  same reason the listing is one transaction at all, that the agent is
  the index's only writer and there is no suspension point between the
  reads and the batch. And a row that is byte for byte the one already
  stored is not written at all: `IndexItem` is the whole of what an
  upsert binds, so an equal row is a no-op statement, and an equal row
  carries the same metadata version and the same `hidden`, which are what
  decide the anchor - skipping the write cannot change which anchors a
  listing appends.
  **Nothing a listing does is once per entry that could be once per
  listing.** The incumbent rows are read on one compiled statement bound
  once per path and answered in the order asked, and the write pass holds
  the row statement and the anchor statement open for its whole length,
  so ten thousand entries cost three statement *executions* each and a
  handful of compilations in all - not a trip to the cache, a wrapper and
  two resets per row. The rows and their anchors land interleaved, in
  listing order, and the deletion pass runs after all of them.
- `anchors` is pruned to the newest 30 days and to the newest 1,000,000
  rows, both limits applying. The row cap is deliberately generous: a pin change writes
  an anchor per known descendant ([pinning](pinning.md)), so a cap in the tens of
  thousands would let one pin of a large tree push the anchor the
  system last saw out of the table and force the expiry path below on a
  system that was merely a few seconds behind. Anchor rows are a few
  dozen bytes, so a million of them cost less than the index they
  describe. If the system presents an anchor the index no longer knows
  (older than the oldest kept row, or the index was rebuilt), the reader
  answers `.syncAnchorExpired`; pruning and rebuilds are the only two
  sources of that error. That reader is the extension
  ([the File Provider extension](extension.md)), which
  sees nothing of the agent's schedule, so when it then hands out a
  fresh anchor it tells the agent so over XPC, one call per expiry, and
  the sweep below is the agent's response. `enumerateItems` on the working set returns no
  items and the current sequence number as the anchor: the working set
  is only ever a change stream, never a listing. When the reader is not
  usable - the `indexReady` call has not come back, the agent answered
  no, the schema is newer than the extension understands, or the file
  could not be opened - the working-set `enumerateChanges` **asks the
  agent for the same change stream over XPC**
  (`enumerateWorkingSetChanges`), which the agent answers from the
  writer's connection with the same query the reader runs
  (`IndexChangeStream`), so the two cannot drift. What it must never
  answer is an empty change set at the anchor the system already holds:
  the system launches a fresh extension instance for every working-set
  signal, so the first `enumerateChanges` on a signalled instance
  races the readiness call, and "no changes" tells the system it is up
  to date. The change is then dropped until something else signals,
  which for a deletion leaves a file that is gone from both the server
  and the index sitting in Finder indefinitely - measured on a real
  mount, 2026-09-04. **`.serverUnreachable` is reserved for an agent
  that genuinely cannot be reached**, which is the one case where there
  is nothing to say, because fileproviderd throttles a change
  enumeration that keeps failing, on a doubling schedule with no
  ceiling: a real domain reached 27 consecutive failures and a
  47-minute retry interval, after which nothing the agent found on the
  server reached Finder at all while listings, `item(for:)` and uploads
  all kept working (2026-09-08). For the same reason the extension calls
  `signalErrorResolved(.serverUnreachable)` on its own domain the first
  time a change enumeration succeeds after one has failed: a signalled
  enumerator is re-scheduled, not un-throttled, and only that call
  clears the backoff. The agent makes the same call once per mounted
  location at start, which is the only way to clear a backoff left
  behind by an earlier run. A container enumerator
  hands out the same sequence number and its `enumerateChanges` never
  expires it: a folder refresh is a fresh listing diffed against the
  index ([the File Provider extension](extension.md)), whatever anchor
  the system holds. That makes expiry
  lossy on its own: whatever changed between the pruned anchor and the
  fresh one is in no listing the system will ask for, unless it re-walks
  every container, which the design does not rely on. So
  the agent treats handing out a fresh working-set anchor exactly as it
  treats a reconnect ([change detection](change-detection.md)): it runs
  one full sweep of the root set at
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
  transfer progress, to close its reader and answer
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
  ready, and an agent mid-restore answers no, so the instance opens
  nothing and every read goes to the agent instead until the answer
  changes. **"Not ready" is a window, not a verdict.** The agent
  answers no for any location whose runtime is not up yet - a domain
  restart, an upgrade handover - which is a few seconds; an instance
  that took the answer once and held it for its whole life could never
  read the index again (2026-09-08). So every read that meets a
  non-ready answer asks again, no more often than a couple of seconds,
  and the rule is a value with tests of its own
  (`IndexReaderReadiness`). The
  one permanent answer is a schema newer than the extension
  understands, because waiting does not make an unknown schema
  readable; a reader shut for a truncate is lifted by the reopen
  callback and by nothing else. An agent that cannot be reached at all
  leaves the instance free to open the reader, since a missing agent is
  the case the direct reader exists for. The reader's side of this is
  one rule: any SQLite error, a corrupt page, a not-a-database header
  during the truncate window, a missing table, drops the reader and
  sends that call to the agent, and is never answered `.noSuchItem`, so
  a rebuild in progress can never look like a deletion. The extension
  writes what it last knew about its own reader - state, the
  `meta.generation` it last saw, the last error, and when - into
  `domains/<id>/reader-state.json`, which is the one file it writes in
  the container besides the `-shm` its read-only connection needs, and
  which `sshdrive doctor` reports: the extension is sandboxed, short
  lived and usually not running when the question is asked, so the last
  thing it said is the only evidence there is. Replacing the file at the
  path is wrong twice
  over: the `-wal` and `-shm` sidecars belong to the old inode and a
  stale WAL would be replayed into the new file on first open, and the
  extension's reader, which holds the database open across calls,
  would keep reading the unlinked file. Then, and also when there is no
  backup at all, the index is **reconciled against the replica** before
  anything is re-enumerated, with `meta.reconciling` set for the whole
  walk so the extension's own reads stall too: the agent walks the mount
  under
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
  through its own `modifyItem`, whose post-upload `lstat` sets it.
  A path whose backup row carries a different
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
  same way by the extension, which sees `meta.reconciling`; the
  system serves the walk from the replica, and
  normal service resumes when the flag is cleared, followed by
  `signalEnumerator` for the working set so the system re-asks for what
  it was refused. The flag is what
  makes the stall complete: the agent-side stall alone would leave the
  extension answering `item(for:)` from a half-built index, and a row
  that is not there yet reads as `.noSuchItem`, which deletes the file.
  The flag also outlives a crash: an agent that starts and finds
  `reconciling` set redoes the walk before serving anything, since the
  extension is stalled on that flag and nothing else will clear it. Two
  consequences follow. The health check and the
  restore run at location start, but **the walk runs after
  `NSFileProviderManager.add(domain)`**, because it reads the system's
  replica and `getUserVisibleURL` has nothing to answer with until the
  domain exists; the restore therefore leaves the flag set and the walk
  is what clears it. And the walk is bounded - a deadline and an item
  cap - because a replica of a million materialized files must not stall
  a domain indefinitely; a walk that hits either limit **still clears
  the flag**, since the alternative is a domain stalled for ever with
  nothing that would ever clear it, and the cost is that the paths it
  never reached get fresh identifiers on their next enumeration, which
  is the delete-plus-create the walk exists to avoid for the paths it
  did reach.
