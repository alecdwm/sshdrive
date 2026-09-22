# Writes, conflicts and atomicity

Every change the user makes in the mount reaches the agent as one of these,
and each of them lands on the server through a temp file and a rename.

- **New files:** upload to `<dir>/.sshdrive-upload-<mac8>-<uuid>` (below), opened with the
  Mac file's permission bits in the `open` attributes (`0644` for an
  ordinary file, `0755` when the local file is executable; the server's
  umask still applies), as `sftp put` does, then the plain,
  non-overwriting SFTP `rename` into place. OpenSSH's `process_rename`
  implements that as `link` + `unlink`, so it fails atomically if
  anything now holds the name (a hidden link, a collision, a file
  created meanwhile); on a filesystem without hard links it falls back
  to `stat` + `rename`, which still refuses an existing name, only with
  a race between the two calls. Either way the refusal arrives as a
  bare `FAILURE` status ([the SFTP client](sftp.md)), so the agent
  confirms it with an `lstat`
  of the destination before reporting `.filenameCollision`, and reports
  an ordinary sync error when nothing is there. `.filenameCollision` is
  **not** a way to refuse a create for good: the system draws no alert for
  it, puts nothing in the pending set, and retries the create with a
  doubling backoff for ever (2026-09-04). It may only be answered when
  the name is about to stop being taken - the conflict copy below, which
  moves our own file aside - and never as a standing refusal, or it is the
  `.Trash` loop of [names and attributes](names-and-attributes.md) again.
  Servers that are not
  OpenSSH may overwrite on a plain `rename`; the probe tests this once,
  in the location root, and where it overwrites every create and rename
  gets an `lstat` preflight instead, with `status` showing the cost
  ([the CLI](cli.md)). `sshdrive set <name> create-check lstat` forces the preflight
  on a server the user does not trust on this point.
- **Existing files:** upload to the temp name, `lstat` the target, then
  `posix-rename@openssh.com` over it so the replacement is atomic, then
  `setstat` the old mode back onto the new file. The `lstat` comes after
  the upload and immediately before the rename, so the conflict window
  (below) is one round trip rather than the length of the upload. Owner and group cannot be
  restored (that needs root) and hard links to the old inode are broken;
  both are documented. Servers without `posix-rename` do `remove` + `rename`,
  a non-atomic window that `status` reports as a degraded capability.
  Creating the temp file needs write permission on the directory, so a
  file the account can write inside a directory it cannot is **not
  saveable through SSH Drive**: the upload fails with `PERMISSION_DENIED`,
  which becomes a sync error, and where the identity is known the capability
  mapping ([names and attributes](names-and-attributes.md)) already shows
  such files locked. Writing in place was
  considered and rejected: it would preserve the inode, owner, ACLs and
  hard links, but leaves a truncated file if the connection drops
  mid-upload and a partial-file window on every save.
- **Case-only renames.** A Finder rename that changes only case
  (`Makefile` to `makefile`) is an ordinary non-overwriting `rename` on a
  case-sensitive server. On a case-insensitive one, a macOS server or a
  Samba-backed share, OpenSSH's `link` fails with `EEXIST`, the
  confirming `lstat` finds a file at the destination, and the rule above
  would report a collision for a legitimate rename. So when the `lstat`
  confirms a destination and the two names differ only by case or by
  Unicode normalisation (APFS is insensitive to both), the agent asks
  SFTP `realpath` for both; if they agree, the names are one
  file and the rename is redone with `posix-rename@openssh.com`, which
  is `rename(2)` and changes case in place. Where the server lacks
  `posix-rename` the rename goes through a temporary third name.
- **After every upload,** create or modify, the agent `setstat`s the mode
  back, sets the mtime to the `contentModificationDate` the system passed
  in, truncated to whole seconds since SFTP v3 carries no more, `lstat`s
  the result, records that size and mtime as the item's
  `content_version`, and resets the row's `inode` and `mtime_ns` to null
  ([the index](item-index.md)), because the rename gave the path a new
  inode that `lstat`
  cannot report. The item `createItem` / `modifyItem` return carries the
  date the `lstat` read back, which is the truncated date when the
  `setstat` was honoured and the server's own write time when an account
  is not allowed to set times, so the system's copy and the server's
  agree either way. The next
  poll, sweep or helper event for that path then finds a version the
  index already holds, records the fresh inode and ns-mtime, and reports
  nothing, so the agent's own writes never come back as remote changes or
  as conflicts against themselves. That holds only if the differ cannot
  look between the rename landing and that `lstat`: in that window a
  helper event or a concurrent poll sees the path with its new inode
  and a version the index does not hold yet, and would report the agent's
  own write as a remote change and make the system re-fetch the file it
  just wrote. So every path with an upload in flight sits in a
  per-location **in-flight set**: the differ skips dirty paths in it, the
  coalescer holds their events, and both are released after the
  post-upload row is written, at which point the held events find a
  version the index already holds and report nothing. The same set
  serialises two saves of one file in quick succession, so the second
  `modifyItem`'s conflict check runs against the first's result rather
  than racing it.
- **Conflicts:** if the `lstat`'s size or mtime, or the row's
  `generation`, differs from the corresponding field of the `baseVersion`
  the system passed us, the remote changed underneath the user. The
  generation comes from the index rather than the wire
  ([the index](item-index.md)): a remote
  rewrite of equal size within the same second is visible only through
  the inode or nanosecond evidence that bumped it, and a check that read
  the `lstat` alone would let this save overwrite that change. Policy:
  rename the temp file, which already holds the local
  content, to `<name> (conflicted copy from <Mac name> <date>).<ext>`
  beside it, `<Mac name>` being this Mac's
  `LocalHostName` since it is the Mac's content that is being set aside,
  return the remote item as current, record a working-set anchor for the
  new sibling so Finder shows it at once, and log. This mirrors
  Dropbox/OneDrive behaviour and never loses data. It rests on the system
  treating a `modifyItem` that returns an item with a different version
  as "the server won": re-fetching that content and not re-offering the
  local edit. **Only the second half is true** (2026-09-04). The
  system takes the returned version at face value - it records it, marks
  the item most-recent-version-downloaded, sets no conflict flag, never
  re-offers the edit, and never re-fetches, then or on the next open. So
  returning the remote item on its own would leave the replica holding the
  *local* bytes under the *remote* version, for ever. The agent therefore
  calls `NSFileProviderManager.evictItem(identifier:)` on that item
  straight after returning it - eviction works on files, directories and
  the root (2026-09-04) - which makes the next open download the
  remote content. **One call is not enough.** An `evictItem` issued
  immediately after the reply is refused with
  `NSFileProviderErrorNonEvictable` (-2008): the system is still finishing
  the modification it has just been told about. So the eviction is retried
  with a doubling backoff from 0.25 s and given up after seven attempts,
  logging either way (2026-09-04; the first retry was enough every time it
  was measured, and with no retry at all the replica keeps the *local*
  bytes under the *remote* version for ever, which is exactly what the
  eviction exists to prevent). The conflict copy is a new sibling in a
  folder the system has already listed, so its anchor is a row nobody will
  ask for: the agent signals the working set after the reply as well, and
  only then does Finder show the copy at once as this paragraph promises
  (a folder is enumerated once, ever - see [the root set](root-set.md)).
  This is also a second reason the post-upload
  `lstat` above is not optional: a version we invent is a version the next
  sweep will not recognise, and nothing will correct it. The check-then-rename is not atomic; a write landing in that
  one round trip is lost the same way it would be with any two SFTP
  clients.
- **Durability:** `fsync@openssh.com` after each upload when the server
  offers it.
- **Stale temp files:** the temp name is
  `.sshdrive-upload-<mac8>-<uuid>`, `<mac8>` being the first eight hex
  digits of an identifier minted once per install and kept at the top
  level of `config.json`, so every temp file says which Mac made it. A
  temp file carrying this Mac's `<mac8>` that is not in the in-flight set
  is stale by definition (the upload it belonged to died with a
  connection or an agent) and is removed as soon as the agent lists its
  directory, however new it is. A temp file from another Mac is left
  alone until it is 30 days old: another Mac's upload may legitimately
  take longer than a day over a slow link, and its own agent removes it
  the moment it lists the directory again. The ignore patterns everywhere
  else ([names and attributes](names-and-attributes.md),
  [change detection](change-detection.md)) match `.sshdrive-upload-*` and
  need no change.
- **Deletes** of non-empty directories: refuse with `.deletionRejected`
  unless the system passed the recursive option; then walk the directory
  on the server with `readdir`,
  depth first, re-`lstat`ing each directory before descending
  ([security](security.md)). The
  walk cannot come from the index: folders Finder never opened have no
  rows, and an index-driven `rmdir` would fail with `ENOTEMPTY` on the
  first unexplored subfolder.
- **Deleting something already gone** succeeds: `ENOENT` from `remove` or
  `rmdir` is reported as success and the row is removed, so a user who
  deletes a ghost the mass-deletion guard
  ([change detection](change-detection.md)) is still showing gets
  what they asked for rather than an error.
