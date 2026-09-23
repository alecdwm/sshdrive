# Names, permissions and attributes

What a server name, a mode bit and an extended attribute become on the Mac, and what the system
does with each. Names are sent to the server exactly as the system provides them; SSH Drive never
normalises. Mode bits become capabilities and flags the agent stores on each row; xattrs and
Finder tags never leave the Mac.

## Hidden names

Some server names are recorded in the index but not shown. Their `hidden` value says why:

| `hidden` | Meaning |
|---|---|
| `0` | shown |
| `1` | symlink omitted ([symlinks](symlinks.md)) |
| `2` | name collision (below) |
| `3` | local-only item, such as `.DS_Store` ([below](#ds-store)) |

- **Hidden names hold their slot.** A create or rename to one fails with `.filenameCollision`.
- **`sshdrive status` lists them** under "not shown" with the reason, so the user can rename them
  server-side.

### Case and normalisation

The server is byte-exact and usually case-sensitive; the local replica is case-insensitive and
normalisation-insensitive. When two server names in one directory map to the same local name
(`Makefile` and `makefile`; NFC and NFD `é.txt`):

1. the name already visible in the index keeps its slot;
2. among newcomers, the byte-wise lowest name is shown;
3. the rest get `hidden = 2`.

`readdir` order is not stable across polls on hash-ordered directories, so it cannot be the
tie-breaker: the visible name must not flip from one cycle to the next. Rows are still written, and
a listing's XPC pages ([the File Provider extension](extension.md)) cut, in the order the server
reported them, so two listings of an untouched directory agree.

Left to itself the system copes: it renames the older item in its replica to `<name> 2.<ext>`
and reports nothing back (`MQ-016`). The server is untouched, but the user sees a name the server
does not have, which is why SSH Drive hides one instead.

### Names that are not UTF-8

Hidden the same way as a collision. This is why the index stores names as bytes
([the index](item-index.md)).

## Permissions become capabilities

The capability probe ([the CLI](cli.md)) runs `id -u` and `id -G` where exec is available. The
agent computes every item's `capabilities` from its `mode`, `uid`, `gid` and that identity and
stores them on the row ([the index](item-index.md)), so the extension never needs the identity. A
change to the `permissions` setting or to the probed identity recomputes every row.

| Capability | Removed when |
|---|---|
| `allowsWriting` (file) | the account cannot write the file **or cannot write its directory** |
| `allowsAddingSubItems` (directory) | the account cannot write the directory |
| `allowsRenaming`, `allowsDeleting` | the parent is not writable; or the parent has the sticky bit (a `1777` drop directory) and neither the item nor the parent is owned by the account, which is what the kernel requires |
| `allowsTrashing` | always: it is never set ([no trash](#no-trash)) |

A file needs its directory writable because replacing content goes through a temp file in that
directory ([writes](writes.md)). A writable file in a read-only directory is therefore shown
locked: Finder refuses the edit up front instead of the upload failing at save time.

**Unknown identity** (SFTP-only accounts): full capabilities, and permission errors arrive
through the sync error list.

Owner and mode appear in Finder's Get Info as far as the system displays them.

### Execute bits become `fileSystemFlags`

The system takes the local file's permission bits from the item's `fileSystemFlags`, stored on the
row like `capabilities`.

| Flag | Set when |
|---|---|
| `.userExecutable` | the mode has an execute bit the account can exercise: the owner's bit if the file is the account's, else the group's if the account is in the group, else the world bit. Any execute bit at all where the identity is unknown. Always on a directory, where it is the search bit. |
| `.userReadable` | always |
| `.userWritable` | `allowsWriting` is set |

Without `.userExecutable`, a script or binary fetched from the server arrives non-executable, and
the upload side ([writes](writes.md)) would faithfully send it back as `0644`.

In the other direction, a `modifyItem` whose `changedFields` contains `.fileSystemFlags` (a
`chmod +x` inside the mount, `MQ-047`) sets or clears the execute bits with `setstat` and
re-records the mode. Read and write bits are never changed that way; `allowsWriting` already
expresses them.

### ACLs and the `permissions` setting

Mode bits are not the whole truth on NAS boxes. Synology, TrueNAS and Samba-backed shares commonly
carry NFSv4 or POSIX ACLs that grant write access to files whose mode reads `0644 root`; mapping
by mode would lock those files with nothing the user can do about it.

So `permissions` is a per-location setting:

| Value | Behaviour |
|---|---|
| `mode` (default) | the mapping above |
| `none` | everything writable; errors arrive after upload, as for SFTP-only accounts |

The probe looks for ACL evidence: a `+` in `ls -ld` of the root, `getfacl` or `nfs4_getfacl`
present, or a Synology, TrueNAS or QNAP release string in `uname -a`. When it finds any,
`sshdrive status` recommends `sshdrive set <name> permissions none` on the permissions line
([the CLI](cli.md)). It does not switch by itself: a plain Linux box with `acl` installed is still
mode-governed.

## No trash

A delete in the mount deletes on the server. This is honest for a remote filesystem and avoids
inventing a server-side trash other SFTP clients would not understand.

- **`allowsTrashing` is never set.** Finder still labels the contextual-menu route **"Move to
  Bin"**; the File menu carries both "Move to Bin" and "Delete Immediately…" (`MQ-058`).
- **Finder's own alert is what makes it honest.** It asks *"Are you sure you want to delete
  “<name>”?"* over *"This item will be deleted immediately. You can't undo this action."* with a
  **Delete** button, then calls `deleteItem`. The strings are Finder's own MT16/MT18/AL7.
  `NSExtensionFileProviderAllowsSystemDeleteAlerts = 0` would suppress that alert for a provider
  drawing its own; we want Finder's, so it stays unset.
- **The domain is added with `supportsSyncingTrash = false`.** `allowsTrashing` only governs whether
  an *item* may be trashed, and the domain property defaults to YES (`MQ-008`).
- **`enumerator(for: .trashContainer)` answers `NSFeatureUnsupportedError` from
  `NSCocoaErrorDomain`,** as the header prescribes for a provider without a trash; the system then
  gives up after two attempts (`MQ-010`). Answering `.noSuchItem` instead tells the system its own
  trash container was deleted: it re-materializes and re-asks about once a second for ever,
  hanging anything that `stat`s `.Trash` in the mount (`MQ-009`).

## Extended attributes stay local

Any xattr the system sends in `modifyItem` (`changedFields` contains `.extendedAttributes`) is
stored in the index row and returned on every item. Nothing is sent to the server.

- They survive an eviction: the framework treats xattrs as metadata, not content, and keeps them
  on a dataless file (`MQ-045`).
- They are lost if the remote item is deleted or the index is rebuilt, which `sshdrive status` does
  not need to mention.
- **The system chooses what we see.** It decides which xattrs are syncable, largely by name: one
  written with `XATTR_FLAG_SYNCABLE` arrives; an ordinary name does not, and stays in the replica
  without the extension being told (`MQ-044`). An extension widens the set with
  `NSExtensionFileProviderAdditionalSyncableExtendedAttributes` in its Info.plist. Whatever we do
  not ask for still works for the user; it is local to this Mac and outside our index.

### Finder tags

Tags do not arrive as an xattr. `com.apple.metadata:_kMDItemUserTags` and `com.apple.FinderInfo`
are deliberately excluded from `extendedAttributes`: tags reach a provider as the item's
**`tagData`**, and the syncable Finder-info bits as the other `NSFileProviderItem` properties.

- **A tag change** is one `modifyItem` with `changedFields = 0x10` (`NSFileProviderItemTagData`), an
  empty `extendedAttributes`, and a `tagData` that is an `NSKeyedArchiver` archive, not the property
  list the xattr holds (`MQ-042`). It is stored and served opaquely and never parsed.
- **Tags are stored like xattrs,** in the row and hashed into the metadata version, but served
  through `tagData`.
- **An item must return its `tagData`.** The system rebuilds the tags xattr from it on every update,
  so an item that returns none loses the user's tags on the next re-download (`MQ-043`).
- **The system asks once,** even when the reply carries the metadata version the item already had,
  so there is no retry loop to prevent (`MQ-079`). The xattr hash exists for the other direction:
  it is the only thing that moves an item's version when the *agent* changes the stored blob, as a
  restore from the index backup does ([the index](item-index.md#restore)). Without it the system
  would never re-read the item and would keep serving tags that are no longer there.

!!! warning "The xattr blob is JSON with sorted keys"
    `JSONEncoder` promises no key order without `.sortedKeys`, so the same attributes encode to two
    different byte strings within one process, the hash moves on its own, and the system re-reads
    every item the agent holds for nothing (gotcha 67).

## `.DS_Store` is swallowed {#ds-store}

A `.DS_Store` written into the mount never reaches the extension: the system keeps it in the
replica and never asks anyone to upload it (`MQ-046`). The server stays clean for free.

SSH Drive still has a path for it, because the exclusion is the system's choice rather than a
contract, and any other writer of a `.DS_Store` would take that path:

- A `createItem` or `modifyItem` for a `.DS_Store` succeeds locally with a row recorded as
  local-only (`hidden = 3`), never uploaded.
- Its bytes (a few KB) are kept in the row's `local_content`, so a `fetchContents` after Finder's
  "Remove Download" or a system eviction returns what Finder wrote, not an empty file that would
  reset the folder's view settings.
- The eviction loop ([cache eviction](eviction.md)) skips local-only items, and a listing that does
  not mention one does not delete it ([the index](item-index.md#deleted-rows-are-deleted)).
- Local-only rows are lost on an index rebuild, which costs little: Finder recreates them.

A `.DS_Store` on the server is never enumerated.

## Never enumerated

- **Our own temp files** (`.sshdrive-upload-*`, see [writes](writes.md)) are never enumerated and
  are ignored by every change-detection tier.
- **Sockets, FIFOs and device nodes** that a `readdir` reports never get a row: File Provider has
  no item type for them. Tier 1's `find` already drops them with its type test. Only files,
  directories and symlinks exist.
