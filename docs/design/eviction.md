# Cache eviction

Content downloaded to the Mac is dropped after the location's TTL unless it
has been used again.

1. Every 5 minutes, for each mounted domain with `cacheTTL != never`:
   `NSFileProviderManager(for: domain).enumeratorForMaterializedItems()`.
2. For each materialized **file** (skip local-only items, which have nothing
   to fetch back; see [names, permissions and
   attributes](names-and-attributes.md)):
   last use = max(mtime of the user-visible file, `last_fetch` from the
   index). mtime counts because a file the user saved but never re-read
   was used, and the replica's mtime and the row's are both consulted,
   the later winning: a save in the mount moves the replica's before the
   upload finishes and the row's only afterwards.

   The loop works file by file because a TTL is per file, not because a
   directory cannot be evicted: `evictItem` on a directory evicts its
   children recursively and then the directory itself, and it works on
   `.rootContainer` too, which is what `evict --all` uses (macOS 26.4,
   2026-09-04).

   **The TTL is time since the last fetch or save**, not time since the last
   read. atime follows the `relatime` rule (macOS 26.4, 2026-09-04):
   materializing a file sets it, and after that a read advances it only when
   it is older than the mtime, so ten reads of a materialized file move
   nothing. That is the APFS rule rather than anything File Provider does -
   a file on `/tmp` behaves identically. `last_fetch` and mtime carry the
   meaning between them, and the docs and `sshdrive show` state it. Watching
   opens precisely would need Endpoint Security, which a login agent cannot
   hold, so there is no third option.

   **atime is read and logged and decided on by nobody.** It is read with
   `AT_SYMLINK_NOFOLLOW` ([path containment](security.md)) **before**
   anything is evicted, since an eviction moves it, and it goes in the log
   line beside the age the decision used - but it is not in the `max` above.
   Something in the system advances a materialized file's atime minutes
   after the fetch, with no read of ours anywhere near it, and the write is
   *deferred*, so the `stat` immediately after a materialization still shows
   the old value (2026-09-05). With atime in the `max` the TTL silently
   becomes "time since whatever last touched the replica" - a file fetched
   280 s earlier survived a 60 s TTL because its atime was 23 s old - which
   is neither the meaning above nor anything a user can observe or predict.
   Keeping it out is also what makes Spotlight indexing, Quick Look and
   Finder thumbnails irrelevant to the TTL: those readers touch every file
   in the mount and would otherwise hold the whole cache open indefinitely.

   These `stat`s draw **no TCC prompt and no `EPERM`** from the
   launchd-started agent (macOS 26.4, 2026-09-04): `tccd` denies the agent
   `kTCCServiceSystemPolicyAllFiles`, which it does not need, and then
   allows the access as `kTCCServiceFileProviderDomain` with our own domain
   as the indirect object, silently. A provider reaching its own mount is
   not gated, so `sshdrive doctor` carries no line for it.
3. If `now - lastUse > TTL`, call `evictItem`. The system refuses to evict
   an item with unsynced local changes, so pending uploads need no check of
   ours. Ignore the refusal; log and move on. **The error code does not say
   why**: an item with pending edits and a kept item both come back as
   `NSFileProviderErrorNonEvictable` (-2008), never the documented
   `NSFileProviderErrorUnsyncedEdits` (-2007), so nothing may be inferred
   from -2008 beyond "not now". A directory eviction that meets a pending
   child fails as `NSCocoaErrorDomain` 4101 with a `contentVersionMismatch`
   underneath rather than `NSFileProviderErrorNonEvictableChildren` (-2006);
   that too is logged and passed over.
4. `sshdrive evict <location> [path]` triggers the same routine on demand,
   with `--all` to drop everything cached, which is one `evictItem` on the
   root container rather than a walk - **while nothing is or has just been
   pinned**. With a pin in place that one call meets a kept child and fails
   as a whole, and straight after `--unpin-all` it fails too, as
   `NSCocoaErrorDomain` "The file couldn't be opened", which names no
   reason: the system has not yet re-read the rows whose policy just
   changed. A single file becomes evictable 5-10 s after an unpin and the
   container did not within a minute (2026-09-05). So in both cases `--all`
   walks the materialized set and evicts the unkept files one by one, each
   with the backoff of [writes, conflicts and atomicity](writes.md) - which
   is also what "`evict --all` skips kept items" has to mean. The cost of
   the walk is that the directory rows stay materialized, since a directory
   holds no content and the loop is per file. A refused root container is
   reported and the walk runs anyway: the one call is an optimisation, not
   the contract. A path names one item and is evicted whatever the TTL says,
   with the same doubling backoff, since a user who has just unpinned races
   the same still-finishing modification the conflict path races; a kept
   path is refused with a sentence naming `unpin` rather than left to fail
   as -2008.

TTL values map to seconds: `15m`, `1h`, `12h`, `1d`, `1w`, `1mo` (30 days),
`never`. Default: `1d`.

Kept items are never evicted: the agent reads each item's `kept` column
([the index](item-index.md)), which it maintains from the markers on the
item and its ancestors, before evicting. See [pinning](pinning.md) for what
kept means. A file the user fetched with Finder's built-in "Download Now" is
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
