# Pinning

A pin keeps a path and everything under it downloaded on the Mac and out of the TTL's reach.
Markers are stored in the index and enforced through the File Provider `contentPolicy`; the CLI and
two Finder context-menu entries are the ways in. Everything acts on **kept**, the effect, never on
the marker itself.

## Markers and kept

- **pinned** / **excluded** are *markers* the user places on a path with `sshdrive pin` /
  `sshdrive unpin` or the Finder entries. They are what is stored.
- **kept** is the *effect* at an item: the nearest marker at or above it is a pin. The system, the
  eviction loop, the badge and the Finder menu all act on kept. Every pinned item is kept; most
  kept items are not pinned, they inherit it.

Each path carries one of three explicit states, and an item's effective state is the **nearest
explicit state at or above it**:

| Explicit state | Meaning | `contentPolicy` returned |
|---|---|---|
| `pinned` | keep this subtree downloaded | `.downloadEagerlyAndKeepDownloaded` |
| `excluded` | inside a kept subtree, leave this subtree lazy | `.downloadLazily` |
| (none) | inherit from the nearest ancestor | `.inherited` |

An explicit `.downloadLazily` overrides an eager ancestor (`MQ-027`), and `.inherited` forces
nothing on its own (`MQ-026`). Exclusions exist because "that file's 4 GB of raw video can stay on
the server" is a reasonable thing to want inside a kept folder.

## The three invariants

!!! warning "Every pin change obeys these"

    1. **`pin` and `unpin` act on exactly the path named**, never on an ancestor.
    2. **Any change to a path's explicit state first deletes every explicit state beneath it** -
       setting `pinned`, setting `excluded`, or removing either. A subtree's state is always
       "whatever the changed ancestor says", as if nothing below had ever been pinned or excluded.
    3. **Minimal markers.** A request is "make this kept" or "make this not kept", and the handler
       writes the smallest explicit state that produces it: removing an exclusion rather than
       adding a pin inside a kept subtree, removing a pin rather than adding an exclusion when
       nothing above is kept.

Invariant 2 makes invariant 3 safe. A pin nested in a kept subtree with no exclusion between can
never behave differently from inheriting, because any change to the ancestor wipes it, so such
redundant markers are never created. It also makes toggling the top folder off and on the way to
reset a complicated structure: two commands or two Finder clicks, and the subtree is clean.

One case needs spelling out. Markers move with their paths, so an exclusion can end up with no pin
above it. "Make this kept" on such an item removes the exclusion *and* writes `pinned`, since
removing the exclusion alone would leave it inheriting nothing.

## The five situations

Because of invariant 3 there are two user-facing operations, `pin` ("Keep Downloaded") and `unpin`
("Don't Keep Downloaded"), and every item is in exactly one of five situations:

| Situation | Nearest marker at or above | Kept? | `pin` / Keep Downloaded | `unpin` / Don't Keep Downloaded |
|---|---|---|---|---|
| A. plain | none | no | writes `pinned` here; subtree cleared | no-op (CLI says so; Finder hides the entry) |
| B. pin root | `pinned`, on this item | yes | CLI only: re-asserts the pin, clearing the subtree (the one-command reset). Finder hides the entry. | removes the pin; subtree cleared; content stays and goes under the TTL |
| C. inheriting a pin | `pinned`, on an ancestor | yes | no-op (CLI names the covering ancestor; Finder hides the entry) | writes `excluded` here; subtree cleared; ancestor and siblings untouched |
| D. exclusion | `excluded`, on this item | no | removes the exclusion, so the item is kept by the ancestor's pin again, or writes `pinned` in its place when no ancestor is pinned (an exclusion moved out of its kept tree); subtree cleared | no-op |
| E. inheriting an exclusion | `excluded`, on an ancestor | no | writes `pinned` here (re-include below the exclusion); subtree cleared | no-op |

Finder always shows exactly the one entry that changes the item's effective state, so the user
never needs to know which situation applies.

### Consequences of the rule

- A new remote file inside a kept folder is downloaded; one inside an excluded subfolder is not.
- Exclusions nest: pin `Projects`, exclude `Projects/archive`, re-pin `Projects/archive/2026`.
  Each level wins over the one above.
- Unpinning the top folder forgets its exclusions too, so a re-pin starts clean. `pin` and `unpin`
  print what they cleared: "Pinned Projects (cleared 3 nested exclusions and 1 nested pin)".
- Finder has no output channel, so the same clearing is silent there: "Don't Keep Downloaded" then
  "Keep Downloaded" on a pin root discards every exclusion under it and downloads what they held.
  This is accepted. A Finder path that cleared nothing would make the same two clicks mean
  different things in Finder and the CLI. `sshdrive pins` shows what is left, and the badge
  reappearing on a formerly excluded folder is Finder's only feedback.
- Moving an item keeps whatever explicit state its path carried and re-evaluates the effective
  state at the new location: states are keyed by path and `modifyItem` updates the path. A file
  moved out of a kept folder stops being kept; one moved in becomes kept.
- The recursive watch of kept subtrees ([root set](root-set.md)) skips excluded subtrees.
- The [eviction loop](eviction.md) uses kept, so an excluded file inside a kept folder is evicted
  like any other cached file.
- `userInfo.kept` and the badge reflect kept. An excluded folder inside a kept one shows no badge;
  its kept parent still does.
- Unreadable subtrees inside a pin are skipped and reported by `sshdrive pins`, not treated as
  errors. Symlinks follow [the symlink policy](symlinks.md).

## Where markers live

Markers live in the index (`pin_state`), which is the only authority. `pins.json` beside it
([item index](item-index.md)) is a write-only copy for recovery, never read while the index is
healthy. Every pin change, from the CLI or from Finder, is one XPC call to the agent, so there is
one writer and no second store to keep in sync.

`sshdrive pins --export` writes the marker list as JSON and `--import` reads it back, for a
rebuilt index or a new Mac.

Pins are on paths, so a re-enumeration keeps them; deleting the path removes them
([item index](item-index.md)).

## How a pin takes effect

Finder offers only "Download Now" and "Remove Download" for a third-party domain, with no built-in
"always keep on this Mac" (`MQ-053`). We build one on the declarative `contentPolicy`:

1. **Store the pin.** `sshdrive pin <location> <remote-path>`, or Finder's "Keep Downloaded", sets
   `pin_state = 1` on the row.
    - From Finder the row always exists.
    - From the CLI the path may never have been enumerated, and the system cannot apply a policy to
      an item whose ancestors it has never seen. So `pin` `lstat`s the path over SFTP, refuses if
      it does not exist or is a symlink, `readdir`s each missing ancestor into the index from the
      nearest known one, and reports those rows through the working set.
    - **That is necessary and not sufficient**: the system ingests none of it from the working set
      alone (`MQ-029`, gotcha 25). So the last step of `pin` is a lookup of the path in the replica:
      `NSFileProviderManager.getUserVisibleURL` for the pinned identifier, then one `lstat` of the
      returned path. The system then enumerates the chain and the eager download follows. Without
      it, `pin` on a path Finder has never shown writes and reports the markers and downloads
      nothing. The agent may read its own mount ([eviction](eviction.md)).

2. **Declare the policy.** Items are returned with the `contentPolicy` of their effective state
   (table above). On any pin-state change the agent, in one transaction:
    - recomputes `kept` and `capabilities` on the changed row **and on every known descendant
      row**, which moves each row's metadata version;
    - writes an anchor for each;
    - signals the working set, so the system re-reads them and applies the new policy.

    The descendants are required (gotcha 83). `contentPolicy` is inherited by the system, but
    `userInfo.kept`, the badge and the capabilities are per item and cached until that item's own
    metadata version moves; bumping the pinned folder alone would leave every file inside it
    offering the wrong menu entries. Descendants the index has never seen need nothing: their rows
    are created with the right state when first listed. The cost is O(subtree) rows and anchors per
    pin change, the same order as a directory rename.

    The system then downloads the subtree eagerly through our `fetchContents`, including folders
    nothing has ever listed (`MQ-028`), fetches files that appear under the pin later, and holds at
    most six `fetchContents` open at once (`MQ-031`) - the bound the [SFTP](sftp.md) transfer
    scheduler sits under. It refuses to evict the subtree because of the inherited `contentPolicy`,
    not `allowsEvicting` (`MQ-024`, gotcha 23).

3. **Keep it current.** Pin roots are always in the [root set](root-set.md), watched recursively.
   New or changed remote files show up in the working-set diff and the system fetches them under
   the eager policy.

4. **Unpin.** On an explicitly pinned item, `unpin` clears it and every explicit state beneath it;
   on an item that inherits a pin it records an exclusion. Either way the content stays on disk
   and falls under the location's TTL from that moment.

5. **Eviction skips kept items**, and so does `sshdrive evict --all` unless `--unpin-all` is
   passed, which removes every pin first.

### Offline and cost

A kept folder is fully readable and listable offline, including subfolders never opened, because
the eager download already materialized them. Edits inside it queue like any other offline write.

A kept folder is downloaded in full, and at tier 0 every poll cycle `readdir`s every directory in
it over SFTP. Deeply nested pins on slow links without shell access are the main performance risk.
`sshdrive pins` shows subtree size and file count:

```
$ sshdrive pins nas
Documents/thesis                 pinned    2.1 GB, 412 files downloaded
  raw-video                      excluded  (14.8 GB on server, not downloaded)
Photos/2026                      pinned    480 MB, 1,203 files downloaded
```

## Pinning the root

"Keep this whole location offline" is a legitimate request, and the root is an item like any
other in every mechanism above:

- **It has a row.** The index holds a permanent root row whose `pin_state` works like a folder's.
  Pinning the root is situation A with no ancestor; every other item then becomes situation C and
  can be excluded; unpinning it is situation B and, by invariant 2, clears every marker in the
  location.
- **It has a path.** `RelativePath` allows zero components ([security](security.md)); that value is
  the root and is joined to `remotePath` unchanged. `sshdrive pin <name> /` and
  `sshdrive pin <name> .` both name it and `sshdrive pins` renders it as `/`. `pin` prints the
  location's total size and file count from the last probe first, since "keep everything" on a
  home directory or a media share is a large decision.
- **It gets the policy.** `item(for: .rootContainer)` returns the root row with
  `.downloadEagerlyAndKeepDownloaded` when pinned, and the system honours it as on a folder,
  downloading the whole location (`MQ-030`).
- **It is a watch root.** A pinned root puts the whole location in the recursive part of the
  [root set](root-set.md): `find` from the root, the helper watching its own `--root`. At tier 0
  that is a `readdir` of every directory in the location per cycle, which `pin` warns about with
  the size.
- **It is reachable from Finder only through the window background** of the location's top-level
  window, where the entry acts on the folder being shown. It is not offered on the sidebar row
  ([below](#where-the-entries-land)), so a whole location is pinned from the CLI.
- **Excluding under a pinned root** is how a user keeps "everything except `Videos`". Moving items
  within the location never changes their kept state, since every path inherits from the root.

## Finder's context menu

Two custom File Provider actions, declared in the extension's Info.plist and handled by
`performAction(identifier:onItemsWithIdentifiers:)`, which forwards to the agent. No window and no
UI extension: Finder renders the entries and calls us.

Every item the extension returns carries `userInfo = ["kept": 0|1]`, copied from the row's `kept`
column ([item index](item-index.md)), never derived in the extension. The activation rules read it:

| Menu label | Shown when | Handler |
|---|---|---|
| **Keep Downloaded** | at least one selected item is not kept: `SUBQUERY(fileproviderItems, $item, $item.userInfo.kept == 0).@count > 0` | `pin` semantics (situations A, D, E) for each selected item that is not kept; kept items are skipped. Bump metadata versions, signal the working set; the system then downloads eagerly. |
| **Don't Keep Downloaded** | at least one selected item is kept: `SUBQUERY(fileproviderItems, $item, $item.userInfo.kept == 1).@count > 0` | `unpin` semantics (situations B, C) for each selected kept item: remove the pin on a pin root, otherwise record an exclusion. Not-kept items are skipped. No eviction. |

!!! warning "Activation rule traps"

    - The bound key is **`fileproviderItems`, lower-case p**, used as a **key path**, not a `$`
      substitution variable. Either mistake drops the entry silently (`MQ-055`, gotcha 31).
    - The `.@count > 0` form is what makes an empty selection match neither entry. The "all
      selected items" form, `SUBQUERY(k, …).@count == k.@count`, is `0 == nil-count`, true with
      no selection, and would show both.
    - `fileproviderctl evaluate <path>` prints each rule and its verdict, which is how to check a
      change without a screen.

Mixed selections show both entries, and each acts only on the items it applies to: selecting a kept
folder and a plain file and choosing "Keep Downloaded" pins the file and leaves the folder alone.
An item inside a kept folder shows only "Don't Keep Downloaded", which excludes just that item
(situation C); "Keep Downloaded" on it later removes the exclusion (situation D). Whether kept is
the item's own pin or inherited is not visible in Finder, since by invariant 3 the two never
behave differently; `sshdrive pins` shows the markers.

### Our entries set policy; Finder's act now

The entries are worded as a policy ("keep" / "don't keep") so they read as a pair and never
collide with Finder's "Download Now" / "Remove Download", which we leave to Finder.

- **"Keep Downloaded"** makes the item and its subtree eager and non-evictable.
- **"Don't Keep Downloaded"** returns it to lazy; the content stays and falls under the TTL.
- **"Download Now"** materializes an unkept item once; **"Remove Download"** evicts an unkept item
  immediately. To free space on a kept item, choose "Don't Keep Downloaded" first, then "Remove
  Download", or wait for the TTL.

The eager `contentPolicy` is what refuses an eviction of a kept item (`MQ-024`). `allowsEvicting`
is `API_DEPRECATED("use NSFileProviderContentPolicy instead", macos(11.0, 13.0))`, and dropping it
does nothing: the system reports the bit from `isDownloaded` whatever we serve (`MQ-025`). So
"Remove Download" is offered on a kept, downloaded item and fails there. The per-item menu entry is
not ours to remove.

The lever that exists is per provider:

| Key in the appex's `NSExtension` dictionary | Effect | Setting |
|---|---|---|
| `NSExtensionFileProviderAllowsUserControlledEviction = false` | hides "Remove Download" on every item, leaving OS and provider eviction working | **unset**: it would take the entry from unkept items too, a worse menu for the common case |
| `NSExtensionFileProviderAllowsContextualMenuDownloadEntry = 0` | removes "Download Now" the same way | **unset** |

Finder 26.4 carries strings for a built-in "Keep Downloaded" entry and a "Kept Downloaded" badge,
and our items report `isKeepDownloaded = 0` even under an eager policy, so that flag is the
system's and is not driven by `contentPolicy`. Finder draws neither for us: the one "Keep
Downloaded" on an unkept item in the mount is ours (`MQ-053`).

### Where the entries land

- Finder's own entries are exactly two, in the third slot after "Open" and "Open With":
  **"Download Now"** when dataless, **"Remove Download"** when materialized, chosen by
  `isDownloaded` alone (`MQ-053`).
- Ours are drawn **at the very bottom, below "Quick Actions", at the top level**, each with a
  leading empty checkbox glyph, one of the pair at a time (`MQ-054`).
- They are also offered on a right-click of the **window background**, acting on the folder shown.
- They are **not** offered on the domain's **sidebar row**, whose menu is "Open in New Tab /
  Show “SSH Drive” / Download Now / Remove from Sidebar / Get Info / Add to Dock" (`MQ-054`,
  gotcha 32).

### Kept files evicted anyway are re-asserted

`materializedItemsDidChange` is the safety net. A kept file **turning** dataless without our
handler having run is re-asserted, not read as intent:

- the agent bumps the item's metadata version and signals the working set, so the system
  re-applies the eager policy and fetches it again;
- it logs the event;
- `sshdrive status` carries a note: "3 kept files were evicted outside SSH Drive and re-downloaded".

An eviction the user did not ask for, from a system that misbehaved or was short of disk, must not
rewrite a pin. If it recurs the status note tells the user, and `unpin` is one command away.
Finder's "Remove Download" on a kept item fails under the eager policy, so the ordinary route gives
the net nothing to do.

"Turning" is load-bearing. A freshly pinned tree is full of kept files that are dataless because
their eager download has not reached them. Only a file the agent saw as materialized in an earlier
`enumeratorForMaterializedItems` pass ([eviction](eviction.md)) counts, and the agent keeps that
set per domain for the purpose.

## The pin badge

Kept items carry a **decoration**: a pin badge declared under `NSFileProviderDecorations` in the
extension's `NSExtension` dictionary and attached through `decorations` on the item
(`NSFileProviderItemDecorating`). It follows kept, not the marker, so an excluded folder inside a
kept one shows nothing and its kept parent still does.

!!! warning "Declaration traps, all silent (`MQ-056`, gotcha 81)"

    - **The four keys are `Identifier`, `BadgeImageType`, `Label` and `Category`**, the bare words
      from `NSFileProviderItemDecoration.h`: not `NSFileProviderDecoration`-prefixed, and not the
      `NSExtensionFileProviderAction*` shape the actions use. A wrong key leaves a decoration that
      is declared, returned by the item and drawn nowhere.
    - **`BadgeImageType` is a UTI conforming to `com.apple.icon-decoration.badge`**, not an asset
      name. Ours is the system's `com.apple.icon-decoration.badge.pinned` (from `CoreTypes.bundle`),
      so the appex needs no icon asset and no exported type.
    - **`Category` is `Badge`**, which draws for files and folders alike. `FolderBadge` embosses and
      is valid only for folders; `Sharing` draws the `Label` as text.

Finder 26.4 draws the `Badge` in list view as an orange disc with a white push-pin at the
**trailing edge of the Name column**, not on the icon, on every kept row including the ones that
inherit the pin (`MQ-057`).
