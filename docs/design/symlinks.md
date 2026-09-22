# Symlinks

File Provider can represent symbolic links directly: an item whose
`contentType` is `.symbolicLink` and whose `symlinkTargetPath` is set becomes
a real symlink in the mounted folder, and Finder draws it with the same arrow
badge it uses for aliases. That is the only representation used. Remote
symlinks are never followed: presenting a link as a copy of whatever it points
at would silently turn `~/all -> /` into a download of the entire server, and
would make edits, pins and change detection act on paths the user never saw.
Finder alias files are not used either: they are ordinary files containing
bookmark data that references a local volume, meaningless on the server.

A remote symlink is shown only if it **stays inside the share**. The check
is lexical, done once per link at enumeration time, and never touches the
server: resolve the target string against the link's own directory
(relative targets) or take it as is (absolute targets), collapse `.` and
`..`, and require the result to remain at or below the location's root.
"The root" here has two spellings, and the check accepts either: the
canonical path `realpath` returned at `add` ([security](security.md)), and
the path as the
user typed it, or, for the default root, the `$HOME` the probe
([the CLI](cli.md))
reads where exec is available, which is the spelling links under a home
directory usually carry; the agent stores that beside the canonical one. On a host where `/home` is itself a
symlink (Fedora Silverblue's `/home -> /var/home`, or a NAS that keeps
homes on a linked volume) the canonical root is `/var/home/alec` while
every absolute link the user ever made says `/home/alec/…`; checked
against the canonical spelling alone, all of them would be hidden. Both
spellings are prefix-matched lexically, and the rewrite to a relative
target (below) uses whichever matched. Links that pass are native
symlinks on the Mac, and the rewritten target is stored on the row
(`link_target`, see [the index](item-index.md)) so the extension serves it
without repeating the
check. "Once per link at enumeration time" costs a round trip of its own:
SFTP v3's `readdir` carries attributes but no target, so every link a
listing reports needs a `readlink` before its row can be built. That is
the price of the check, it is paid once per link rather than once per
look, and a directory of ordinary files pays nothing. A directory of
links pays it **through the SFTP client's window
([the SFTP client](sftp.md)) rather than one link at a time**:
the requests are independent, they go out sixteen at a time on the one
channel with one more issued for each answer that lands, and the listing
costs a round trip per sixteen links rather than one per link. Order is
not part of the answer - each target is filed under its own path - and a
`readlink` that fails leaves its link with no target, which is the empty
target the check below hides. One refusal never fails the listing it was
found in.

What the Mac makes of the links it is given was measured on macOS 26.4
(2026-09-04). The system creates a **real symlink** under
`~/Library/CloudStorage/`: `ls -la` shows `lrwx------`, `readlink` returns
the string the row carries, a relative target resolves inside the mount
and `cat link` reads the file it points at. Finder lists every one of them
with **Kind "Alias"** and the arrow-badged icon, and a link to a directory
gets a badged *folder* icon. A **dangling** link is drawn exactly like a
working one - same badge, same Kind, its size the length of the target
string - with no broken-link marker of any sort, which is the honest
presentation and the reason a link whose target may appear later is worth
showing.
Links that fail are **omitted from enumeration entirely**, logged at debug
level, and otherwise ignored. A link that leaves the share has no meaning
inside a File Provider mount, and a broken link in Finder would only
invite questions.

An absolute target that lands inside the root is as safe as a relative one
and is common on NAS home directories (`media -> /volume1/media` under a
root of `/volume1`), so it is shown, with the target **rewritten as the
relative path** from the link's directory to the resolved location. The
server keeps the absolute string; only the Mac-side symlink carries the
rewritten one. If such a link is later moved from the Mac, the agent
recomputes the relative form for its new directory and bumps its metadata
version, since the same absolute target now needs a different relative
spelling.

| Remote link | On the Mac |
|---|---|
| relative, target resolves lexically inside the root | native symlink, same target string. Resolves inside the mount; dangling if the target does not exist yet, which is fine, it may appear later |
| absolute, target lexically inside the root | native symlink, target rewritten relative to the link's directory |
| relative, target climbs above the root | not listed |
| absolute, target outside the root | not listed |

The check is per link, not per chain: `a -> b` is judged on `b`'s location,
not on where `b` itself points. If `b` is then hidden because it escapes,
`a` shows up on the Mac as a dangling link. Resolving chains would require
following links, which [security](security.md) forbids; the dangling `a` is
the honest result.

**Name collisions with hidden links.** A hidden link still occupies its name
on the server, so a Mac-side create or rename to that name has to be handled
rather than silently replacing the link:

- Hidden links are recorded in the index when their directory is enumerated
  (`hidden = 1`), and the parent of any new item has necessarily been
  enumerated, so a `createItem` or a rename/move first consults the index.
  If the name is held by a hidden link, the operation fails immediately with
  `.filenameCollision`. The system keeps the new item local with an error
  badge and Finder's usual "name already in use" message; `sshdrive status`
  lists it under sync errors as "name taken by a hidden symlink on the
  server", and the user renames it or fixes the link server-side.
- A hidden link that appeared *after* the last enumeration is caught by the
  server instead, through the non-overwriting `rename` that every create and
  move ends with ([writes](writes.md)). The `modifyItem` content path uses an `lstat`
  before uploading, so a known file that has since turned into a link is
  noticed by the same call.
- The reverse direction needs nothing special. The visible set is "items
  that are not hidden", so a hidden link replaced on the server by a real
  file or directory simply appears as a new item on the next poll, a real
  item replaced by a hidden link appears as a deletion, and a link whose
  target changes across the boundary appears as a deletion or creation.

Rules:

- A symlink is a single small item. Kept state, eviction, polling and the
  index all stop at it; `sshdrive pins` counts links but never descends.
- Enumeration uses `lstat` semantics (SFTP `readdir` reports the link
  itself), so a link to a directory is listed as a link, not a folder.
- **Creating symlinks from the Mac.** `ln -s` inside the mount arrives as a
  `createItem` with `.symbolicLink` and a target. It is accepted only if the
  target passes the same lexical inside-the-share check, in which case the
  agent issues an SFTP `symlink` with the string unchanged. Otherwise it is
  refused with `EINVAL` and a message saying the target must be a relative
  path inside the share, since the resulting link would be hidden the moment
  it was created. An absolute target from the Mac is a Mac path
  (`/Users/…/CloudStorage/…`), meaningless on the server, and is refused
  with the same message even when it points inside the mount. Finder itself cannot create symlinks; it creates alias
  files, which upload as regular files. Converting those into remote
  symlinks is listed in [future work](future-work.md).
  `ln -s` does reach `createItem` with the target intact
  (2026-09-04): a relative target inside the share is written to the server
  unchanged, and an absolute or escaping one never leaves the Mac. What
  the user sees of the refusal is less than this paragraph implies.
  `ln -s` itself succeeds - the system takes the item locally first - and
  the refusal comes back as the item's `uploadingError`, an
  `NSFileProviderErrorCannotSynchronize` carrying the system's own wording
  and not ours; the link sits in the replica with an error badge and the
  system keeps retrying it. Our sentence therefore has to reach the user
  through `sshdrive status`'s sync-error list and nowhere else.
- Renaming or moving a link moves the link only; the server's target
  string is not rewritten, matching `mv` on the server (the Mac-side
  spelling of an absolute-inside-root target is recomputed as above).
  Before the move, a relative target is re-checked from the *destination*
  directory; an absolute target inside the root stays inside wherever the
  link lives. If it would escape the root
  there, the `modifyItem` is refused with `EINVAL` and the same message as
  for creation, and the system puts the link back where it was. Allowing the
  move and then hiding the result would be a way to plant an escaping link
  on the server through the mount, which creation already forbids. The same
  check applies to copies, since Finder copies a link by creating a new one.
