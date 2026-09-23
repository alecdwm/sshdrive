# Writes, conflicts and atomicity

Every change the user makes in the mount reaches the agent as a `createItem`, `modifyItem` or
`deleteItem`. Content always lands on the server through a temp file and a rename, never written
in place, and every upload ends with an `lstat` whose result becomes the item's version.

## The upload protocol

The temp name is `<dir>/.sshdrive-upload-<mac8>-<uuid>`, in the destination's own directory
([stale temp files](#stale-temp-files)).

1. **Enter the in-flight set** for the path ([below](#the-in-flight-set)).
2. **Upload to the temp name,** opened with the Mac file's permission bits in the `open` attributes
   (`0644` for an ordinary file, `0755` when the local file is executable; the server's umask still
   applies), as `sftp put` does.
3. **Move it into place:**
    - *create:* the plain, non-overwriting SFTP `rename` ([creating](#creating));
    - *modify:* `lstat` the target for the [conflict check](#conflicts), then
      `posix-rename@openssh.com` over it ([replacing](#replacing)).
4. **`setstat` the mode back** (on a modify, the old file's mode) and set the mtime to the
   `contentModificationDate` the system passed in, truncated to whole seconds, since SFTP v3 carries
   no more.
5. **`lstat` the result** and write the row ([after the upload](#after-the-upload)).
6. **Leave the in-flight set.**

**Durability:** `fsync@openssh.com` after each upload, when the server offers it.

## Creating

The plain SFTP `rename` does not overwrite. OpenSSH's `process_rename` implements it as `link` +
`unlink`, so it fails atomically if anything now holds the name (a hidden link, a collision, a
file created meanwhile). On a filesystem without hard links it falls back to `stat` + `rename`,
which still refuses an existing name, with a race between the two calls.

Either way the refusal arrives as a bare `FAILURE` ([the SFTP client](sftp.md)). The agent
`lstat`s the destination to confirm it:

| `lstat` of the destination | Reported as |
|---|---|
| something is there | `.filenameCollision` |
| nothing is there | an ordinary sync error |

!!! warning "`.filenameCollision` is not a standing refusal"
    The system draws no alert for it, puts nothing in the pending set, and retries the create on a
    doubling backoff for ever (`MQ-014`). It may only be answered when the name is about to stop
    being taken - the [conflict copy](#conflicts), which moves our own file aside. Used as a
    permanent refusal it is the `.Trash` loop of
    [names and attributes](names-and-attributes.md#no-trash) again.

**Servers whose plain `rename` overwrites.** Servers that are not OpenSSH may overwrite. The probe
tests this once, in the location root (`SQ-034`); where it overwrites, every create and rename gets
an `lstat` preflight instead, and `status` shows the cost ([the CLI](cli.md)).
`sshdrive set <name> create-check lstat` forces the preflight on a server the user does not trust
on this point.

## Replacing

`posix-rename@openssh.com` over the target makes the replacement atomic. The `lstat` for the
conflict check comes after the upload and immediately before the rename, so the conflict window is
one round trip rather than the length of the upload.

- **Owner and group are not restored** (that needs root), and hard links to the old inode are
  broken. Both are documented.
- **Without `posix-rename`** the server gets `remove` + `rename`, a non-atomic window that `status`
  reports as a degraded capability.
- **The directory must be writable.** Creating the temp file needs write permission on the
  directory, so a file the account can write in a directory it cannot is **not saveable through
  SSH Drive**: the upload fails with `PERMISSION_DENIED`, which becomes a sync error. Where the
  identity is known, the capability mapping ([names and attributes](names-and-attributes.md))
  already shows such files locked.

Writing in place was rejected. It would keep the inode, owner, ACLs and hard links, but leaves a
truncated file if the connection drops mid-upload, and a partial-file window on every save.

## Case-only renames

A Finder rename that changes only case (`Makefile` to `makefile`) is an ordinary non-overwriting
`rename` on a case-sensitive server. On a case-insensitive one - a macOS server, a Samba-backed
share - OpenSSH's `link` fails with `EEXIST`, the confirming `lstat` finds a file, and the rule
above would report a collision for a legitimate rename.

So when the `lstat` confirms a destination and the two names differ only by case or by Unicode
normalisation (APFS is insensitive to both):

1. Ask SFTP `realpath` for both names.
2. If they agree, the names are one file: redo the rename with `posix-rename@openssh.com`, which is
   `rename(2)` and changes case in place.
3. Where the server lacks `posix-rename`, rename through a temporary third name.

## After the upload

The `lstat` in step 5 of [the protocol](#the-upload-protocol) is what keeps the agent's own writes
from coming back as remote changes. The agent:

- records that size and mtime as the item's `content_version` ([the index](item-index.md#versions));
- resets the row's `inode` and `mtime_ns` to null, because the rename gave the path a new inode
  that `lstat` cannot report;
- returns an item from `createItem` / `modifyItem` carrying the date the `lstat` read back. That is
  the truncated date when the `setstat` was honoured, and the server's own write time when the
  account may not set times, so the system's copy and the server's agree either way.

The next poll, sweep or helper event for the path then finds a version the index already holds,
records the fresh inode and ns-mtime, and reports nothing.

The `lstat` is not optional for a second reason: the system believes whatever version a
`modifyItem` reply carries (`MQ-013`). A version the agent invents is one the next sweep will not
recognise, and nothing will correct it.

### The in-flight set

Between the rename landing and that `lstat`, a helper event or a concurrent poll would see the path
with its new inode and a version the index does not hold yet, report the agent's own write as a
remote change, and make the system re-fetch the file it just wrote.

So every path with an upload in flight sits in a per-location **in-flight set**:

- the differ skips dirty paths in it;
- the coalescer holds their events;
- both are released after the post-upload row is written, when the held events find a version the
  index already holds and report nothing;
- it serialises two saves of one file in quick succession, so the second `modifyItem`'s conflict
  check runs against the first's result rather than racing it.

## Conflicts

A save conflicts when the `lstat`'s size or mtime, **or the row's `generation`**, differs from the
corresponding field of the `baseVersion` the system passed. The remote changed underneath the user.

The generation comes from the index, not the wire
([the index](item-index.md#what-the-conflict-check-compares)): a remote rewrite of equal size
within the same second is visible only through the inode or nanosecond evidence that bumped it,
and a check that read the `lstat` alone would overwrite it.

On a conflict the agent:

1. Renames the temp file, which already holds the local content, to
   `<name> (conflicted copy from <Mac name> <date>).<ext>` beside it. `<Mac name>` is this Mac's
   `LocalHostName`, since it is the Mac's content being set aside.
2. Returns the remote item as current.
3. Records a working-set anchor for the new sibling, and logs.
4. Calls `NSFileProviderManager.evictItem(identifier:)` on the item, so the next open downloads the
   remote content. The call is retried with a doubling backoff from 0.25 s and given up after seven
   attempts, logging either way.
5. Signals the working set.

This mirrors Dropbox and OneDrive and never loses data. The last two steps are what make it work:

- **Eviction:** the system takes a returned version at face value. It never re-fetches and never
  re-offers the edit (`MQ-013`), so returning the remote item alone leaves the replica holding the
  *local* bytes under the *remote* version for ever. An `evictItem` issued straight after the reply
  is refused `NSFileProviderErrorNonEvictable` (-2008) while the system finishes the modification,
  hence the retry; the first retry has always been enough (`MQ-017`).
- **Signal:** the copy is a new sibling in a folder the system has already listed, and a folder is
  enumerated once, ever ([the root set](root-set.md), `MQ-001`). Without the signal its anchor is
  a row nobody asks for and Finder does not show it.

The check-then-rename is not atomic. A remote write landing in that one round trip is lost, as it
would be between any two SFTP clients.

## Stale temp files

`<mac8>` in `.sshdrive-upload-<mac8>-<uuid>` is the first eight hex digits of an identifier minted
once per install and kept at the top level of `config.json`, so every temp file says which Mac made
it.

| Temp file | Removed |
|---|---|
| this Mac's `<mac8>`, not in the in-flight set | as soon as the agent lists its directory, however new it is: the upload it belonged to died with a connection or an agent |
| another Mac's `<mac8>` | once it is 30 days old. Another Mac's upload may legitimately take longer than a day over a slow link, and its own agent removes the file the moment it lists the directory again. |

The ignore patterns elsewhere ([names and attributes](names-and-attributes.md),
[change detection](change-detection.md)) match `.sshdrive-upload-*` and need no change.

## Deletes

| Situation | Behaviour |
|---|---|
| non-empty directory, no recursive option | refused with `.deletionRejected` |
| non-empty directory, recursive option set | walk the directory on the server with `readdir`, depth first, re-`lstat`ing each directory before descending ([security](security.md)), then `remove` / `rmdir` |
| target already gone (`ENOENT` from `remove` or `rmdir`) | success, and the row is removed |

- **The walk cannot come from the index:** folders Finder never opened have no rows, and an
  index-driven `rmdir` would fail with `ENOTEMPTY` on the first unexplored subfolder.
- **Deleting a ghost succeeds** so that a user deleting an item the mass-deletion guard
  ([change detection](change-detection.md)) is still showing gets what they asked for, not an
  error.
