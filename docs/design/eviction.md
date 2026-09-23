# Cache eviction

Content downloaded to the Mac is dropped once the location's TTL has passed since it was last
fetched or saved. Kept items are never evicted, and the system refuses to evict anything with
unsynced local changes.

## The loop

1. **Every 5 minutes**, for each mounted domain with `cacheTTL != never`, enumerate
   `NSFileProviderManager(for: domain).enumeratorForMaterializedItems()`.

2. **For each materialized file**, skipping local-only items, which have nothing to fetch back
   ([names and attributes](names-and-attributes.md)):

    ```
    lastUse = max(mtime of the user-visible file, mtime of the row, last_fetch)
    ```

    mtime counts because a file the user saved but never re-read was used. Both the replica's and
    the row's are consulted, the later winning: a save in the mount moves the replica's before the
    upload finishes and the row's only after it.

    The loop goes file by file because a TTL is per file. A directory can be evicted: `evictItem`
    on one evicts its children recursively and then itself, and works on `.rootContainer`
    (`MQ-020`), which is what `evict --all` uses.

3. **If `now - lastUse > TTL`, call `evictItem`.** Ignore a refusal: log it and move on. The
   system refuses to evict an item with unsynced local changes, so pending uploads need no check
   of ours. The error code does not say why:

    | Refusal | Arrives as |
    |---|---|
    | item with pending edits | `NSFileProviderErrorNonEvictable` (-2008), never the documented `NSFileProviderErrorUnsyncedEdits` (-2007) (`MQ-018`) |
    | kept item | also -2008 (`MQ-018`) |
    | directory with a pending child | `NSCocoaErrorDomain` 4101, underlying `contentVersionMismatch`, not `NSFileProviderErrorNonEvictableChildren` (-2006) (`MQ-019`) |

    Nothing may be inferred from -2008 beyond "not now".

4. **`sshdrive evict <location> [path]`** runs the same routine on demand; see
   [`evict` on demand](#evict-on-demand).

## TTL values

`15m`, `1h`, `12h`, `1d`, `1w`, `1mo` (30 days), `never`. Default: `1h`.

## What the TTL measures

The TTL is time since the last fetch or save, not since the last read. `sshdrive show` and the
user docs say so.

- **Reads do not count.** atime follows the `relatime` rule on APFS (`MQ-023`): materializing a
  file sets it, and after that a read advances it only when it is older than mtime, so ten reads
  of a materialized file move nothing. Watching opens precisely would need Endpoint Security,
  which a login agent cannot hold.
- **atime is read, logged and decided on by nobody.** It is read with `AT_SYMLINK_NOFOLLOW`
  ([security](security.md)) before anything is evicted, since an eviction moves it (`MQ-021`),
  and logged beside the age the decision used. It is not in the `max`: something in the system
  advances a materialized file's atime minutes after the fetch, deferred, with no read of ours
  near it (`MQ-022`, gotcha 80). With atime in the rule the TTL becomes "time since whatever last
  touched the replica", which no user can observe or predict.
- Keeping atime out also makes Spotlight, Quick Look and Finder thumbnails irrelevant. They read
  every file in the mount and would otherwise hold the whole cache open indefinitely.

The agent's `stat`s under its own mount draw no TCC prompt and no `EPERM` (`MQ-060`), so
`sshdrive doctor` carries no line for it.

## Kept items

The agent reads each item's `kept` column ([item index](item-index.md)), which it maintains from
the markers on the item and its ancestors, and skips kept items. See [pinning](pinning.md) for what
kept means; the eager `contentPolicy` is what makes the system refuse the eviction as well
(`MQ-024`).

A file fetched with Finder's built-in "Download Now" is an ordinary cached file under the TTL.
`sshdrive pin` is how to keep it.

## `evict` on demand

A path names one item and evicts it whatever the TTL says:

- with the doubling backoff of [writes](writes.md), because a user who has just unpinned races the
  same still-finishing modification the conflict path races (`MQ-017`);
- a kept path is refused with a sentence naming `unpin`, rather than left to fail as -2008.

`--all` drops everything cached. It is one `evictItem` on the root container **only while nothing
is or has just been pinned** (gotcha 82):

| Situation | Root-container call | So `--all` |
|---|---|---|
| nothing pinned | evicts everything | done |
| a pin in place | meets a kept child and fails as a whole (`MQ-033`) | walks the materialized set |
| straight after `--unpin-all` | fails as `NSCocoaErrorDomain` "The file couldn't be opened": the system has not re-read the rows whose policy changed; a single file becomes evictable 5-10 s after an unpin and the container did not within a minute (`MQ-034`) | walks the materialized set |

The walk evicts the unkept files one by one, each with the write path's backoff, which is what
"`evict --all` skips kept items" means. The directory rows stay materialized, since the walk is
per file. A refused root container is reported and the walk runs anyway: the one call is an
optimisation, not the contract.

## Anything that opens files downloads them

A dataless file is materialized by whichever process opens it: `grep -r` in the mount, an
antivirus scanner, a backup tool other than Time Machine (which excludes
`~/Library/CloudStorage`), a build reading a whole tree. The TTL is the only thing that later frees
the space. This is true of every File Provider domain.

v1 adds no mechanism against it: no download budget, no size cap on unsolicited fetches. The user
docs say it plainly, and `sshdrive status` shows the materialized total so an unexpected download
is at least visible.
