# Symlinks

A remote symlink is shown as a native symlink on the Mac, and only if its target lexically stays
inside the location's root. Links are never followed.

## Representation

An item whose `contentType` is `.symbolicLink` and whose `symlinkTargetPath` is set becomes a real
symlink in the mount. That is the only representation used.

- **Never followed.** Presenting a link as a copy of its target would turn `~/all -> /` into a
  download of the entire server, and would make edits, pins and change detection act on paths the
  user never saw.
- **No Finder alias files.** An alias is an ordinary file holding bookmark data that references a
  local volume, meaningless on the server.

On the Mac the system creates a real symlink under `~/Library/CloudStorage/` whose `readlink` is
the row's target. Finder lists every link with Kind "Alias" and the arrow badge (a badged folder
icon for a link to a directory), and draws a dangling link exactly like a working one, with no
broken-link marker (MQ-076, MQ-077, gotcha 54). That is why a link whose target may appear later
is worth showing.

## The inside-the-root check

The check is lexical, done once per link at enumeration time, and never touches the server:

1. Resolve the target string against the link's own directory (relative target), or take it as is
   (absolute target).
2. Collapse `.` and `..`.
3. Require the result to be at or below the location's root.

### Two spellings of the root

The check accepts either spelling, prefix-matched lexically, and the relative rewrite uses
whichever matched:

- the canonical path `realpath` returned at `add` ([security](security.md));
- the path as the user typed it, or for the default root the `$HOME` the probe
  ([cli](cli.md)) reads where exec is available. The agent stores it beside the canonical one.

Both are needed because on a host where `/home` is itself a symlink (Fedora Silverblue's
`/home -> /var/home`, or a NAS that keeps homes on a linked volume) the canonical root is
`/var/home/alec` while every absolute link the user made says `/home/alec/…`. Checked against the
canonical spelling alone, all of them would be hidden.

### What each case becomes

| Remote link | On the Mac |
|---|---|
| relative, target resolves lexically inside the root | native symlink, same target string. Resolves inside the mount; dangling if the target does not exist yet, which is fine, it may appear later |
| absolute, target lexically inside the root | native symlink, target rewritten relative to the link's directory |
| relative, target climbs above the root | not listed |
| absolute, target outside the root | not listed |

An absolute in-root target is as safe as a relative one and is common on NAS home directories
(`media -> /volume1/media` under a root of `/volume1`). The server keeps the absolute string; only
the Mac-side symlink carries the relative form. If the link is later moved from the Mac, the agent
recomputes the relative form for its new directory and bumps its metadata version.

Links that fail are **omitted from enumeration entirely** and logged at debug level. A link that
leaves the share has no meaning inside a File Provider mount, and a broken link in Finder would
only invite questions.

The rewritten target is stored on the row (`link_target`, [index](item-index.md)), so the
extension serves it without repeating the check.

### Per link, not per chain

`a -> b` is judged on where `b` is, not on where `b` points. If `b` is hidden because it escapes,
`a` shows up on the Mac as a dangling link. Resolving chains would require following links, which
[security](security.md) forbids.

## Reading targets

SFTP v3's `readdir` carries attributes but no target, so every link a listing reports costs a
`readlink` before its row can be built (SQ-031). A directory of ordinary files pays nothing.

The `readlink`s go through the SFTP client's window ([sftp](sftp.md#readdir)): independent
requests, sixteen in flight on the one channel, one more issued for each answer that lands. A
directory of links costs a round trip per sixteen links.

- Order does not matter: each target is filed under its own path.
- A `readlink` that fails leaves its link with no target, which the check hides.
- One refusal never fails the listing it was found in.

## Name collisions with hidden links

A hidden link still occupies its name on the server, so a Mac-side create or rename to that name
must not silently replace it.

- **Known hidden links.** They are recorded in the index when their directory is enumerated
  (`hidden = 1`), and the parent of any new item has necessarily been enumerated. A `createItem` or
  a rename/move consults the index first, and a name held by a hidden link fails at once with
  `.filenameCollision`. The system keeps the item local with an error badge and Finder's "name
  already in use" message; `sshdrive status` lists it under sync errors as "name taken by a hidden
  symlink on the server".
- **Links that appeared after the last enumeration** are caught by the server, through the
  non-overwriting `rename` every create and move ends with ([writes](writes.md)). The `modifyItem`
  content path `lstat`s before uploading, so a known file that has since become a link is noticed
  by the same call.
- **The reverse needs nothing special.** The visible set is "items that are not hidden": a hidden
  link replaced by a real file or directory appears as a new item on the next poll, a real item
  replaced by a hidden link appears as a deletion, and a link whose target crosses the boundary
  appears as a deletion or creation.

## Rules

- A symlink is a single small item. Kept state, eviction, polling and the index all stop at it;
  `sshdrive pins` counts links but never descends.
- Enumeration uses `lstat` semantics (SFTP `readdir` reports the link itself), so a link to a
  directory is listed as a link, not a folder.

### Creating a link from the Mac

`ln -s` inside the mount arrives as a `createItem` with `.symbolicLink` and the target intact
(MQ-076).

- A **relative target inside the share** is accepted, and the agent issues an SFTP `symlink` with
  the string unchanged.
- Anything else is refused with `EINVAL` and a message saying the target must be a relative path
  inside the share, since the link would be hidden the moment it was created. An absolute target
  from the Mac is a Mac path (`/Users/…/CloudStorage/…`), meaningless on the server, and is refused
  even when it points inside the mount.

!!! note "The refusal is a sync error, not a message"
    `ln -s` itself succeeds: the system takes the item locally first, and the refusal comes back as
    the item's `uploadingError`, an `NSFileProviderErrorCannotSynchronize` with the system's own
    wording. The link sits in the replica with an error badge and the system keeps retrying it. Our
    sentence reaches the user only through `sshdrive status`'s sync-error list (MQ-078, gotcha 55).

Finder cannot create symlinks; it creates alias files, which upload as regular files. Converting
those into remote symlinks is [future work](future-work.md).

### Renaming, moving and copying a link

- A rename or move moves the link only. The server's target string is not rewritten, matching `mv`
  on the server; the Mac-side spelling of an absolute in-root target is recomputed.
- Before the move, a relative target is re-checked from the *destination* directory. An absolute
  in-root target stays inside wherever the link lives.
- If the target would escape the root there, the `modifyItem` is refused with `EINVAL` and the
  same message as for creation, and the system puts the link back. Allowing the move and hiding the
  result would be a way to plant an escaping link on the server through the mount.
- The same check applies to copies, since Finder copies a link by creating a new one.
