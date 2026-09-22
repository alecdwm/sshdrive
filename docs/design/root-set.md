# The root set and the maintenance timers

Every tier watches the same bounded set of directories, kept in the
`roots` table:

| Reason | Directories | Leaves when |
|---|---|---|
| `materialized` | every directory that contains at least one materialized file, from `enumeratorForMaterializedItems()` refreshed on `materializedItemsDidChange` | the last materialized file in it is evicted |
| `pinned` | every pin root, watched recursively, excluded subtrees pruned | the pin is removed |
| `viewed` | every directory the extension has been asked to enumerate this session | the 256-entry cap evicts it, or the agent restarts (there is no second enumeration to time from) |

Directories never listed, or listed long ago and holding nothing
downloaded, are not polled by anyone. That keeps tier 0's cost
proportional to what the user is actually looking at or holding, not to
everything they ever browsed.

**The system gives no per-folder refresh at all** (measured on macOS 26.4,
2026-09-04). A folder is enumerated exactly once, the first time it is
shown: opening it, navigating away and back, closing and reopening the
window, and a remote change landing while it is open all produce no further
container-enumerator call - not `enumerateChanges`, not a second
`enumerateItems`, not even a new enumerator. Everything after that first
listing reaches the window through the working set. So the `viewed` reason
is armed from our own `enumerateItems`, which fires once per folder, and it
keeps its directories for the rest of the session, capped at 256. A folder
with nothing downloaded and nothing pinned gets no refresh other than a
poll, and that is only true while it is still in the viewed set.

The `viewed` reason is bounded, because "Finder has enumerated" is not
the same as "the user has looked at": `ls -R`, a Spotlight pass,
`grep -r`, or the eager download of a freshly pinned subtree enumerates
every directory it touches, and each would otherwise become a polled root
for the rest of the session, one `readdir` per minute per directory at tier
0. So the viewed set holds at most 256 directories per location, evicting
the least recently enumerated, and a directory under a recursive pin root
is never added to it, since the pin's recursive watch already covers it.
The `materialized` reason is not capped, since dropping a directory from
it would leave cached files in it unwatched, but it is **rotated** at
tier 0: a photo library browsed under a one-month TTL leaves thousands
of directories holding one downloaded file each, and a `readdir` of
every one per cycle is not proportional to anything the user is looking
at. So each tier 0 cycle lists every `viewed` and `pinned` root and at
most 64 `materialized`-only roots, taken round-robin in order of least
recent listing, so a directory holding only cached files is refreshed
every `ceil(M / 64)` cycles rather than every cycle, and the cost per
cycle is bounded whatever `M` is. Tier 1 passes the whole set to one
`find`, whose cost is the server's, and the helper watches it all, so
the rotation applies to tier 0 only; `status` shows the rotation period
when it exceeds one cycle. The `materialized` reason too skips
directories under a pin root.

Enumerating the system's materialized set is not free, so the last one read
is published for anything else that wants it: `sshdrive status` reuses
whichever of the tier 0 cycle, the eviction pass (`docs/design/eviction.md`)
or `materializedItemsDidChange` published it last rather than enumerating
again.

A remote rename of a directory reaches tiers 0 and 1 as delete + create of
the whole subtree. Cached content under it is discarded and, if pinned,
re-downloaded. The helper reports the rename and keeps identifiers and
content. Recognising moves heuristically at the polling tiers is future
work (`docs/design/future-work.md`).

## Eviction and pin maintenance

The eviction loop (`docs/design/eviction.md`) and the kept-subtree walk
(`docs/design/pinning.md`) run here on timers. The agent is not sandboxed,
so it can `stat` files under `~/Library/CloudStorage/…` directly for their
access time.
