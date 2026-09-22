# Names, permissions and attributes

What a server name, a mode bit and an extended attribute become on the Mac,
and what the system does with each of them.

**Case and normalisation.** The server is byte-exact and usually
case-sensitive; the local replica is case-insensitive and
normalisation-insensitive. When two server names in one directory map to
the same local name (`Makefile` and `makefile`; NFC and NFD `é.txt`), the
one already visible in the index keeps its slot, and among newcomers the
byte-wise lowest name is shown; the rest are recorded with `hidden = 2`.
`readdir` order is not stable across polls on hash-ordered directories, so
it cannot be the tie-breaker: the visible name must not flip from one cycle
to the next. The *rows* are written, and the XPC pages of a listing
([the File Provider extension](extension.md)) cut, in the
order the server reported the entries in, which at least makes two
listings of a directory nothing has touched agree with each other. Left to
itself the system copes rather than failing - it renames the item
already in its replica to `<name> 2.<ext>` and does not report that
rename back, so the server name is untouched (2026-09-04) - but the user
is then looking at a name the server does not have, which is why we hide one
instead. Names that are not valid UTF-8 are hidden the same way, which is why
the index stores names as bytes ([the index](item-index.md)). Hidden
names hold their slot: a create or rename to one of them fails with
`.filenameCollision`. `sshdrive status` lists hidden names under "not
shown" with the reason, so the user can rename them server-side. Names are
sent to the server exactly as the system provides them; we never
normalise.

**Permissions become capabilities.** The capability probe
([the CLI](cli.md)) runs
`id -u` and `id -G` where exec is available, and every item's `capabilities` are
computed by the agent from its `mode`, `uid`, `gid` and that identity,
and stored on the row ([the index](item-index.md)) so the extension never
needs the identity
itself; a change to the `permissions` setting or to the probed identity
recomputes every row. A file loses
`allowsWriting` when the account cannot write it **or cannot write its
directory**, because replacing content goes through a temp file in that
directory ([writes](writes.md)), so a writable file in a read-only
directory is shown
locked rather than failing at save time; a directory the account cannot
write loses `allowsAddingSubItems`; `allowsRenaming` and `allowsDeleting`
follow the parent's write bit, and when the parent carries the sticky
bit (a `1777` drop directory) they additionally require the item or the
parent to be owned by the account, which is what the kernel requires.
Finder then shows a lock and refuses the
edit up front instead of failing the upload later. SFTP-only accounts, where the
identity is unknown, get full capabilities and learn about permission
errors from the sync error list. Owner and mode are shown in Finder's Get
Info as far as the system displays them.

**Execute bits become `fileSystemFlags`.** The mode also decides the
local file's own permission bits, which the system takes from the
item's `fileSystemFlags`: `.userExecutable` is set when the mode has
an execute bit the account can exercise (the owner's bit when the file
is the account's, the group's when the account is in the group,
otherwise the world bit, and any execute bit at all where the identity
is unknown; a directory always carries it, since there it is the search
bit), `.userReadable` is always set, and `.userWritable` follows
`allowsWriting`. Without the first, a script or binary fetched from the
server arrives non-executable, which the upload side ([writes](writes.md))
would then
faithfully send back as `0644`. The flags are stored on the row like
`capabilities` ([the index](item-index.md)). In the other direction, a
`modifyItem` whose
`changedFields` contains `.fileSystemFlags` (a `chmod +x` inside the
mount) sets or clears the execute bits with `setstat` and re-records
the mode; the read and write bits are never changed that way, since
`allowsWriting` already expresses them.

Mode bits are not the whole truth on NAS boxes. Synology, TrueNAS and
Samba-backed shares commonly carry NFSv4 or POSIX ACLs that grant the
account write access to files whose mode reads `0644 root`; mapping by mode
would lock those files in Finder with nothing the user can do about it. So
the mapping is a per-location setting, `permissions`: `mode` (the default,
as above) or `none` (everything writable, errors after upload, as for
SFTP-only accounts). The probe looks for ACL evidence, a `+` in `ls -ld` of
the root, `getfacl` or `nfs4_getfacl` present, or a Synology, TrueNAS or
QNAP release string in `uname -a`, and when it finds any, `sshdrive status`
recommends `sshdrive set <name> permissions none` on the permissions line
([the CLI](cli.md)). It does not switch by itself, since a plain Linux box
with `acl` installed is still mode-governed.

**No trash.** `allowsTrashing` is never set, but Finder still labels the
route **"Move to Bin"** in the contextual menu (the File menu carries both
"Move to Bin" and "Delete Immediately…"); what makes it honest is the
alert. Finder asks *"Are you sure you want to delete “<name>”?"* over
*"This item will be deleted immediately. You can't undo this action."*,
with a **Delete** button, and then calls `deleteItem`, which removes the
item on the server (2026-09-04; the strings are Finder's own
MT16/MT18/AL7). `NSExtensionFileProviderAllowsSystemDeleteAlerts = 0`
would suppress that alert for a provider drawing its own; we want Finder's, so
it stays unset. This is honest for a remote filesystem and avoids
inventing a server-side trash that other SFTP clients would not understand.
`allowsTrashing` alone is not enough, because it governs only whether an
*item* may be trashed: the domain is also added with
`supportsSyncingTrash = false` (it defaults to YES), and the extension's
`enumerator(for: .trashContainer)` answers `NSFeatureUnsupportedError` from
`NSCocoaErrorDomain`, which is what the header prescribes for a provider
without a trash - answering `.noSuchItem` instead tells the system its own
trash container was deleted, and it then re-materializes and re-asks about
once a second for ever, hanging anything that `stat`s `.Trash` in the mount.

**Extended attributes stay local.** Any xattr the system sends in
`modifyItem` (`changedFields` contains `.extendedAttributes`) is stored in
the index row and returned on every item, and nothing is ever sent to the
server. They survive an eviction untouched - the framework calls extended
attributes metadata, not content, and preserves them on a dataless file
(2026-09-04) - and are lost if the remote item is deleted or the index
is rebuilt, which `sshdrive status` does not need to mention.

Two things about that set are not obvious:

- **The system chooses what we see.** It decides which xattrs are syncable,
  largely from the name: one written with `XATTR_FLAG_SYNCABLE` arrives,
  an ordinary name does not and stays in the replica where the extension
  is never told about it. An extension widens the set with
  `NSExtensionFileProviderAdditionalSyncableExtendedAttributes` in its
  Info.plist. Whatever we do not ask for still works for the user; it is
  simply local to this Mac and outside our index.
- **Finder tags do not arrive as an xattr at all.**
  `com.apple.metadata:_kMDItemUserTags` and `com.apple.FinderInfo` are
  excluded from `extendedAttributes` deliberately, as redundant: tags reach
  a provider as the item's own **`tagData`** property, and the syncable
  Finder-info bits as the other `NSFileProviderItem` properties. And the
  system rebuilds the tags xattr from `tagData` on every update, so an item
  that returns no `tagData` **loses the user's tags on the next
  re-download**, which was watched happening (2026-09-04). Tags are
  therefore stored and
  served the same way as xattrs, in the row and hashed into the metadata
  version, but through `tagData` and `NSFileProviderItemTagData` in
  `changedFields` (bit 4, `0x10`), not through the xattr dictionary.
  The round trip was measured on macOS 26.4 (2026-09-04). Tagging a
  file in the mount arrives as exactly one `modifyItem` with
  `changedFields = 0x10`, an empty `extendedAttributes` dictionary, and a
  `tagData` that is an `NSKeyedArchiver` archive - not the
  `com.apple.metadata:_kMDItemUserTags` property list the xattr holds -
  which is why it is stored and served opaquely and never parsed. Nothing
  reaches the server, the item survives an eviction and a re-download with
  its tags intact, and the system does **not** re-offer the change. It
  does not re-offer it either when the reply deliberately carries the
  metadata version the item already had: with the version frozen, the same
  single `modifyItem` arrived and no more. So the xattr hash is not what
  stops a retry loop - there is no retry loop on macOS 26.4, for the same
  reason a `modifyItem` reply is believed at all ([writes](writes.md)).
  What the hash is for is the
  other direction: it is the only thing that moves an item's version when
  the *agent* changes the stored blob, which a restore from the index
  backup does ([the index](item-index.md)), and without it the system
  would never re-read the
  item and would keep serving tags that are no longer there.
  The blob is JSON with **sorted keys**, which is not a tidiness
  preference: `JSONEncoder` promises no key order without them, so the same
  attributes encode to two different byte strings inside one process, the
  hash moves on its own, and the system re-reads every item the agent holds
  for nothing (2026-09-04).

**`.DS_Store` is swallowed** - and mostly by the system
rather than by us. A `createItem` or `modifyItem` for a
`.DS_Store` succeeds locally with an item the agent records as local-only
(`hidden = 3`) but never uploads; a `.DS_Store` on the server is never
enumerated. Measured on macOS 26.4 (2026-09-04): **a `.DS_Store` written
into the mount never reaches the extension at all.** No `createItem`, no
`modifyItem`; the system keeps the file in the replica, reports it through
`fileproviderctl evaluate` as an ordinary item with `isUploaded = 0` and
`isUploading = 0`, and never asks anyone to upload it. So the server stays
clean for free, and the local-only path is not exercised by the case it
was written for. It is kept anyway: it is one branch, the exclusion is the
system's choice rather than a contract, and it is the path any other
writer of a `.DS_Store` would take. Local-only items have no remote content, so the
eviction loop ([cache eviction](eviction.md)) skips them, and their bytes
(a few KB for a
`.DS_Store`) are kept in the row's `local_content` column so that a
`fetchContents` for one, after Finder's "Remove Download" or a
system-side eviction, returns what Finder wrote rather than an empty
file that would reset the folder's view settings. They are lost on an
index rebuild, which costs little: Finder recreates them.

**Our own temp files** (`.sshdrive-upload-*`, see [writes](writes.md)) are
never enumerated and are ignored by every change-detection tier.

**Only files, directories and symlinks exist.** Sockets, FIFOs and device
nodes that a `readdir` reports are never enumerated and never get a row,
since File Provider has no item type for them; tier 1's `find` already
drops them with its type test.
