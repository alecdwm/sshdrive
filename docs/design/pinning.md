# Pinning

A pin keeps a path and everything under it downloaded on the Mac and out of
the TTL's reach. Markers are stored in the index and enforced through the
File Provider content policy; the CLI and two Finder context-menu entries
are the ways in.

Two words are used strictly throughout these pages:

- **pinned** / **excluded** are *markers* the user places on a path with
  `sshdrive pin` / `sshdrive unpin` (or the Finder entries). They are what
  gets stored.
- **kept** is the *effect* on an item: whether the nearest marker at or above
  it is a pin. Kept is what the system, the eviction loop, the badge and the
  Finder menu act on. Every pinned item is kept; most kept items are not
  pinned, they inherit it.

## Keeping a folder fully offline

Markers live in the index (`pin_state`), and the index is the only
authority; `pins.json` beside it ([the index](item-index.md)) is a
write-only copy for recovery, never read while the index is healthy. The
index is the agent's, and every pin change, from the CLI or from Finder, is
one XPC call to the agent, so there is one writer and no second store to
keep in sync. `sshdrive pins --export` writes the marker list as JSON and
`--import` reads it back, for anyone who rebuilds an index or moves to a new
Mac.

What Finder provides on its own for a third-party domain is limited to
"Download Now" (materialize once) and "Remove Download" (evict once). There is
no built-in "always keep on this Mac" for third-party providers; OneDrive,
Google Drive and Nextcloud each implement their own. We do too, through the
framework's declarative `contentPolicy`:

1. **Store the pin.** `sshdrive pin <location> <remote-path>`, or the Finder
   "Keep Downloaded" entry, sets `pin_state = 1` on the matching row.
   From Finder the row always exists. From the CLI the path may never have
   been enumerated, and the system cannot apply a policy to an item whose
   ancestors it has never seen, so `pin` first `lstat`s the path over
   SFTP, refuses if it does not exist or is a symlink, then `readdir`s
   each missing ancestor into the index from the nearest known one and
   reports those rows through the working set, so that by the time the
   pinned row is signalled the system has a complete chain down to it.
   **That is necessary and not sufficient.** The system ingests none of it
   from the working set alone (macOS 26.4, 2026-09-04): ninety seconds after
   the rows and their anchors were reported nothing had been enumerated or
   downloaded, and `signalEnumerator(for:)` on each new ancestor's own
   container changed nothing either. What starts it is a **lookup of the
   path in the replica**, and the agent makes that itself as the last step
   of `pin`: `NSFileProviderManager.getUserVisibleURL` for the pinned
   identifier followed by one `lstat` of the returned path - well under a
   second, on a still-dataless item. The system then enumerates the chain
   and the eager download follows within about a minute. The agent is
   allowed to read its own domain's mount ([cache eviction](eviction.md));
   without this step `pin` on a path Finder has never shown would write the
   markers, report them, and silently download nothing.
   Pins are on paths, so a re-enumeration keeps them; deleting the path
   removes them ([the index](item-index.md)).
2. **Declare the policy.** Items are returned with
   `contentPolicy = .downloadEagerlyAndKeepDownloaded` when their effective
   state (see Nested items below) is kept, `.downloadLazily` when excluded,
   and `.inherited` otherwise. On any pin-state change the agent recomputes
   `kept` and `capabilities` on the affected row **and on every known
   descendant row**, in one transaction, which moves each row's metadata
   version since that is derived from those fields, writes an anchor for
   each, and signals the working-set enumerator so the system re-reads
   them and applies the new policy. The descendants are not optional:
   `contentPolicy` is inherited by the system, but `userInfo.kept`, the
   badge and `allowsEvicting` are per item and cached by the
   system until that item's own metadata version moves, so bumping the
   pinned folder alone would leave every file inside it offering "Keep
   Downloaded" and "Remove Download" as if nothing had happened.
   Descendants the index has never seen need nothing: their rows are
   created with the right state when they are first listed. The cost is
   O(subtree) rows and anchors per pin change, the same order as a
   directory rename. The system then downloads the subtree eagerly
   (through our normal `fetchContents`), shows it as downloaded in
   Finder, and refuses to evict it. Each half measured on macOS 26.4
   (2026-09-04): the whole subtree comes down after one working-set signal,
   including **folders nothing has ever listed**, which is what the offline
   claim below rests on; files that appear remotely under the pin later are
   fetched too; and the system holds **at most six `fetchContents` calls
   open at once** for an eager subtree, in strict batches, which is the
   bound the [SFTP](sftp.md) transfer scheduler sits under. The refusal to
   evict comes from the **inherited `contentPolicy`, not from
   `allowsEvicting`**: a file that still carried the capability refused
   eviction because its ancestor was eager.
3. **Keep it current.** Pin roots are always in the change-detection
   [root set](root-set.md), watched recursively. New or changed remote files
   show up in the working-set diff, the system sees the eager policy, and
   fetches them.
4. **Unpin.** `sshdrive unpin` on an explicitly pinned item clears it and
   every explicit state beneath it; on an item that merely inherits a pin it
   records an exclusion instead. Either way the content stays on disk
   and becomes subject to the location's TTL from that moment.
5. **Eviction skips kept items** and so does `sshdrive evict --all`, unless
   `--unpin-all` is passed, which removes every pin first.

## Nested items: one rule

A pin applies to a whole subtree, but users will still right-click a file
inside a kept folder, and "that file's 4 GB of raw video can stay on the
server" is a reasonable thing to want. Rather than ignoring children or
unpinning the whole folder from a child, each path can carry one of three
explicit states, and the **effective state of any item is the nearest explicit
state at or above it in the tree**:

| Explicit state | Meaning | `contentPolicy` returned |
|---|---|---|
| `pinned` | keep this subtree downloaded | `.downloadEagerlyAndKeepDownloaded` |
| `excluded` | inside a kept subtree, but leave this subtree lazy | `.downloadLazily` |
| (none) | inherit from the nearest ancestor | `.inherited` |

Three invariants govern every change:

1. `pin` and `unpin` act on exactly the path named, never on an ancestor.
2. **Any change to a path's explicit state, whether setting `pinned`, setting
   `excluded`, or removing either, first deletes every explicit state beneath
   that path.** A subtree's state is therefore always "whatever the changed
   ancestor says", as if nothing below it had ever been pinned or excluded.
   Toggling the top folder off and on is the way to reset a complicated
   pin/exclusion structure: two commands, or two Finder clicks, and the
   subtree is clean.
3. **Minimal markers.** A request is "make this kept" or "make this not
   kept", and the handler writes the smallest explicit state that produces
   that effective result: removing an exclusion rather than adding a pin
   inside an already-kept subtree, removing a pin rather than adding an
   exclusion when nothing above is kept. Invariant 2 makes this safe: a pin
   nested inside a kept subtree with no exclusion in between can
   never behave differently from inheriting, because any change to the
   ancestor wipes it. So such redundant markers are never created. One
   case needs spelling out: markers move with their paths (below), so an
   exclusion can end up with no pin above it. "Make this kept" on such an
   item removes the exclusion *and* writes `pinned`, since removing the
   exclusion alone would leave it inheriting nothing.

Because of invariant 3 there are only two user-facing operations, `pin`
("keep downloaded") and `unpin` ("don't keep downloaded"), and each item is
in exactly one of five situations:

| Situation | Nearest marker at or above | Kept? | `pin` / Keep Downloaded | `unpin` / Don't Keep Downloaded |
|---|---|---|---|---|
| A. plain | none | no | writes `pinned` here; subtree cleared | no-op (CLI says so; Finder hides the entry) |
| B. pin root | `pinned`, on this item | yes | CLI only: re-asserts the pin, clearing the subtree (the one-command reset). Finder hides the entry. | removes the pin; subtree cleared; content stays and goes under the TTL |
| C. inheriting a pin | `pinned`, on an ancestor | yes | no-op (CLI names the covering ancestor; Finder hides the entry) | writes `excluded` here; subtree cleared; ancestor and siblings untouched |
| D. exclusion | `excluded`, on this item | no | removes the exclusion, so the item is kept by the ancestor's pin again, or writes `pinned` in its place when no ancestor is pinned (an exclusion moved out of its kept tree); subtree cleared | no-op |
| E. inheriting an exclusion | `excluded`, on an ancestor | no | writes `pinned` here (re-include below the exclusion); subtree cleared | no-op |

Finder always shows exactly the one entry that changes the item's effective
state, so the user never has to know which of the five situations applies.

Consequences that follow from the one rule, listed so nobody has to derive
them:

- A new file appearing remotely inside a kept folder is downloaded; one
  appearing inside an excluded subfolder is not.
- Unpinning the top folder forgets its exclusions too, so a later re-pin
  starts clean. Both `pin` and `unpin` print how many nested states they
  cleared, so a reset is visible: "Pinned Projects (cleared 3 nested
  exclusions and 1 nested pin)". Finder has no output channel, so the
  same clearing is silent there: "Don't Keep Downloaded" followed by
  "Keep Downloaded" on a pin root discards every exclusion under it and
  starts downloading whatever they held. This is accepted. A Finder path
  that cleared nothing would make the same two clicks mean different
  things in Finder and in the CLI, which is worse than the occasional
  surprise; `sshdrive pins` shows what is left, and the badge on a
  previously excluded folder reappears, which is the only feedback Finder
  gives.
- Exclusions can nest: pin `Projects`, exclude `Projects/archive`, re-pin
  `Projects/archive/2026`. Each level wins over the one above it.
- The recursive watch of kept subtrees ([root set](root-set.md)) skips
  excluded subtrees.
- The [eviction loop](eviction.md) uses the kept state, so an excluded file
  inside a kept folder is evicted like any other cached file.
- `userInfo.kept` (used by the Finder menu predicates) and the badge
  reflect the kept state. An excluded folder inside a kept one shows no
  badge; its kept parent still does.
- Moving an item in Finder keeps whatever explicit state its path carried and
  re-evaluates the effective state at the new location, since states are keyed
  by path and `modifyItem` updates the path. Moving a file out of a kept
  folder therefore stops it being kept, and moving one in makes it kept,
  which is what the folder's badge already suggests.
- Unreadable subtrees inside a pin are skipped and reported by
  `sshdrive pins`, not treated as errors. Symlinks follow
  [the symlink policy](symlinks.md).

`sshdrive pins` renders the states as a tree so the layering is visible:

```
$ sshdrive pins nas
Documents/thesis                 pinned    2.1 GB, 412 files downloaded
  raw-video                      excluded  (14.8 GB on server, not downloaded)
Photos/2026                      pinned    480 MB, 1,203 files downloaded
```

Behaviour offline: a kept folder is fully readable and listable with no
network, including subfolders never opened, because the eager download already
materialized them. Edits inside it queue exactly like any other offline write.

Costs to be aware of: a kept folder is downloaded in full, and at tier 0 each
poll cycle `readdir`s every directory in it over SFTP. Deeply nested pins on
slow links without shell access are the main performance risk; `sshdrive
pins` reports subtree size and file count so the user can see what they've
signed up for.

## Pinning the root

"Keep this whole location offline" is a legitimate request and must not be
a special case that falls through somewhere. The root is an item like any
other in every mechanism above, and the places where it could have been
different are pinned down here:

- **It has a row.** The index holds a permanent root row whose
  `pin_state` works exactly like a folder's. Pinning the root is situation
  A with no ancestor; every other item becomes situation C and can
  be excluded individually; unpinning the root is situation B and, by
  invariant 2, clears every marker in the location.
- **It has a path.** `RelativePath` allows zero components
  ([path containment](security.md)); that value is the root and is what the
  transport joins to `remotePath` unchanged. `sshdrive pin <name> /` and
  `sshdrive pin <name> .` both name it, `sshdrive pins` renders it as `/`,
  and `pin` prints the location's total size and file count from the last
  probe before starting, since "keep everything" on a home directory or a
  media share is a large decision.
- **It gets the policy.** `item(for: .rootContainer)` returns the root row
  with `contentPolicy = .downloadEagerlyAndKeepDownloaded` when pinned, and
  **the system honours it exactly as it does on a folder**: pinning the root
  of a location downloads every directory and file in it (macOS 26.4,
  2026-09-04).
- **It is a watch root.** A pinned root puts the whole location into the
  recursive part of the [root set](root-set.md): `find` from the root, the
  helper watching its own `--root`. At tier 0 that is a
  `readdir` of every directory in the location per cycle, which `pin`
  warns about along with the size.
- **It is reachable from Finder,** but only through the window background.
  The root has no parent to right-click in Finder's list; our entries are
  offered on a right-click of the background of the location's top-level
  window, where the item they act on is the folder being shown, and not on
  the sidebar row (below), so a whole location is pinned from the CLI.
- **Excluding under a pinned root** is how a user keeps "everything except
  `Videos`", and moving items around inside the location never changes
  their kept state, since every path in it inherits from the root.

## Pinning from Finder's context menu

The CLI is the source of truth, but the natural place to pin a folder is the
folder itself. Two custom File Provider actions provide that, declared in the
extension's Info.plist and handled in the extension by
`performAction(identifier:onItemsWithIdentifiers:)`, which forwards to the
agent. No window, no UI extension: Finder renders the menu items and calls us.

Every item the extension returns carries `userInfo = ["kept": 0|1]`, its
kept state (1 when the nearest marker at or above it is a pin), copied from
the row's `kept` column ([the index](item-index.md)) rather than derived in
the extension. The activation rules read it:

| Menu label | Shown when | Handler |
|---|---|---|
| **Keep Downloaded** | at least one selected item is not kept: `SUBQUERY(fileproviderItems, $item, $item.userInfo.kept == 0).@count > 0` | `sshdrive pin` semantics (situations A, D, E) for each selected item that is not kept; kept items in the selection are skipped. Bump metadata versions, signal the working set; the system then eagerly downloads. |
| **Don't Keep Downloaded** | at least one selected item is kept: `SUBQUERY(fileproviderItems, $item, $item.userInfo.kept == 1).@count > 0` | `sshdrive unpin` semantics (situations B, C) for each selected kept item: remove the pin if it is the pin root, otherwise record an exclusion. Not-kept items are skipped. No eviction. |

The bound key is **`fileproviderItems`, lower-case p**, and it is a key
path on the evaluated object, not a `$` substitution variable. Both
mistakes are silent: `$fileProviderItems` raises out of
`NSVariableExpression` against an empty bindings dictionary, the rule is
dropped, and the entry never appears, with nothing in any log. The
capital-P spelling Apple's documentation uses does not occur anywhere in
the dyld shared cache (macOS 26.4, 2026-09-04). The `.@count > 0` form above
is also what makes an empty selection match neither entry: the "all selected
items" form, `SUBQUERY(k, …).@count == k.@count`, is `0 == nil-count`,
i.e. true, when there is no selection, and would show both at once.
`fileproviderctl evaluate <path>` prints each rule and its verdict, which
is how to check a change to them without a screen.

Two labels, one concept. The entries are worded as a policy ("keep" / "don't
keep") rather than an action on the current download, so they read as a pair
and never collide with Finder's built-in "Download Now" / "Remove Download",
which we leave entirely to Finder. The division of labour is:

- **Our entries set policy.** "Keep Downloaded" makes the item and its
  subtree eager and non-evictable. "Don't Keep Downloaded" returns it to
  lazy; the content stays on disk and falls under the location's TTL.
- **Finder's entries act now.** "Download Now" materializes an unkept item
  once; "Remove Download" evicts an unkept item immediately. A user who
  wants space back on a kept item chooses "Don't Keep Downloaded" first,
  and then Finder's "Remove Download", or waits for the TTL.

  **What enforces this is the `contentPolicy`, not the capability** (macOS
  26.4, 2026-09-04). `evictItem` refused a file whose row still carried
  `allowsEvicting`, purely because the folder above it was eager; and
  `allowsEvicting` is `API_DEPRECATED("use NSFileProviderContentPolicy
  instead", macos(11.0, 13.0))`. So the guarantee "a kept item is not
  evicted" rests on the eager policy.

  **Dropping `allowsEvicting` is not a second belt: it does nothing.**
  `fileproviderctl evaluate` on a pinned, downloaded file whose row served
  capabilities `47` reported `0x2000006F` back - the bit put in again -
  unchanged over forty seconds, with `userInfo.kept = 1` in the same
  snapshot, so the item had certainly been re-read. What the system does
  track is `isDownloaded`: a dataless item loses the bit whatever we
  serve, a materialized one has it. The item is still kept, because the
  policy refuses the eviction; the *menu entry* is simply not ours to
  remove per item. The header names the lever that is:
  `NSExtensionFileProviderAllowsUserControlledEviction = false` in the
  appex's `NSExtension` dictionary, which "suppress[es] the user's ability
  to evict the item in the UI but retain[s] the ability of the OS or the
  provider's program to evict items" - i.e. it hides Finder's entry on
  every item while leaving the TTL loop working. It is a per-provider
  switch: setting it takes "Remove Download" away from unkept items too,
  which is a worse menu for the common case, so **it stays unset** and a
  "Remove Download" on a kept item is left to fail, caught by the
  re-assert net below. The neighbouring key
  `NSExtensionFileProviderAllowsContextualMenuDownloadEntry = 0` removes
  "Download Now" the same way, and is likewise unset.

  Finder 26.4 also carries strings for a **built-in "Keep Downloaded"**
  entry and a "Kept Downloaded" badge of its own, and our items report
  `isKeepDownloaded = 0` even under an eager policy, so that flag is the
  system's and is not driven by our `contentPolicy`. It draws neither for
  us: an unkept item in the mount shows exactly one "Keep Downloaded" and
  it is ours (2026-09-04). No label clash, and no built-in entry to
  compete with.

Mixed selections show both entries, and each acts only on the items it
applies to, so selecting a kept folder together with a plain file and
choosing "Keep Downloaded" pins the file and leaves the folder alone. An item
inside a kept folder shows only "Don't Keep Downloaded", which excludes just
that item (situation C); the folder keeps its badge, the excluded item
loses it, and "Keep Downloaded" on it later removes the exclusion (situation
D). Whether an item's kept state is its own pin or inherited is deliberately
not visible in Finder, since by invariant 3 the two never behave differently;
`sshdrive pins` shows the markers for anyone who wants them.

**Where the entries land** (Finder 26.4, 2026-09-04, captured on screen).
Finder's own File Provider entries are exactly two, both in the third slot of
the contextual menu, right after "Open" and "Open With": **"Download Now"**
when the item is dataless, **"Remove Download"** when it is materialized.
Which one appears follows `isDownloaded` and nothing else - a kept,
downloaded file is offered "Remove Download" like any other. Our two
entries are drawn **at the very bottom of the menu, below "Quick Actions",
at the top level**, each with a leading empty checkbox glyph, and exactly
one of the pair ever appears. The same entry is offered on a **right-click
of the window background**, where the item it acts on is the folder being
shown; it is **not** offered on the **sidebar row** for the domain, whose
menu is "Open in New Tab / Show “SSH Drive” / Download Now / Remove from
Sidebar / Get Info / Add to Dock". So a whole location can be pinned only
from the CLI, which is where Pinning the root puts it anyway.

`materializedItemsDidChange` is the safety net for the "Remove Download"
route as much as for any other: a kept file turning dataless without our
handler having run is **re-asserted**, not read as intent. The agent bumps
the item's metadata version and signals the working set so the system
re-applies the eager policy and fetches it again, logs the event, and
`sshdrive status` carries a note ("3 kept files were evicted outside SSH
Drive and re-downloaded"). An eviction the user did not ask for, from a
system that misbehaved or was short of disk, must not silently rewrite a
pin; if it recurs, the status note is what tells the user, and `unpin` is
one command away. Finder's "Remove Download" is offered on a kept item (the
capability cannot be withheld, above) and the eager policy makes it fail, so
the ordinary Finder route produces no eviction for the net to answer.
"Turning" is the operative word for the ones that do arrive: a freshly
pinned tree is full of kept files that are dataless because their eager
download has not reached them yet, so only a file the agent had seen as
materialized in an earlier `enumeratorForMaterializedItems` pass
([cache eviction](eviction.md)) counts, and the agent keeps that set per
domain for the purpose. Otherwise that code path stays dormant.

Kept items also get a **decoration**: a small pin badge declared under
`NSFileProviderDecorations` in the extension's `NSExtension` dictionary
and attached via `decorations` on the item (`NSFileProviderItemDecorating`),
so kept folders are visibly different in Finder. It follows the *kept*
state and not the marker, so an excluded folder inside a kept one shows
nothing and its kept parent still does.

The declaration has three traps, all silent:

- **Its four keys are `Identifier`, `BadgeImageType`, `Label` and
  `Category`** - the bare words from `NSFileProviderItemDecoration.h`, not
  `NSFileProviderDecoration`-prefixed spellings of them, and not the
  `NSExtensionFileProviderAction*` shape the actions above use. The same
  class of mistake as `fileproviderItems`: a wrong key leaves a decoration
  that is declared, returned by the item and drawn nowhere.
- **`BadgeImageType` is a UTI that must conform to
  `com.apple.icon-decoration.badge`,** not an asset name. The system ships
  a `.badge.pinned` (also `.checkmark`, `.locked`, `.syncing`, `.warning`
  and a dozen more, all in `CoreTypes.bundle`), so ours is
  `com.apple.icon-decoration.badge.pinned` and the appex needs no icon
  asset and no exported type of its own.
- **`Category` is `Badge`**, which draws for a file and a folder alike.
  `FolderBadge` embosses and is valid only for folders; `Sharing` draws the
  `Label` as text instead.

What Finder 26.4 draws for `Badge` in list view is an orange disc
with a white push-pin at the **trailing edge of the Name column**, not on
the item's icon (captured 2026-09-05). Every kept row in a listing carries
it, including the ones that merely inherit the pin, which is the point:
`kept` is what the badge reflects.
