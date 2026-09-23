# The root set and the maintenance timers

Every change-detection tier watches the same bounded set of directories, kept in the `roots`
table. Nothing outside it is polled, so tier 0's cost follows what the user is looking at or
holding, not everything they ever browsed.

## The three reasons

| Reason | Directories | Leaves when |
|---|---|---|
| `materialized` | every directory holding at least one materialized file, from `enumeratorForMaterializedItems()` refreshed on `materializedItemsDidChange` | the last materialized file in it is evicted |
| `pinned` | every pin root, watched recursively, excluded subtrees pruned | the pin is removed |
| `viewed` | every directory the extension has been asked to enumerate this session | the 256-entry cap evicts it, or the agent restarts |

A directory under a pin root is never added as `viewed` or `materialized`: the pin's recursive
watch already covers it.

## No per-folder refresh

The system enumerates a folder **once, ever** (`MQ-001`, gotcha 29). Revisiting it, reopening
the window, or a remote change landing while it is open produces no container-enumerator call at
all. Everything after the first listing reaches the window through the working set.

So `viewed` is armed from our own `enumerateItems`, which fires once per folder, and keeps its
directories for the session. It is cleared on agent restart because there is no second
enumeration to time from. A folder with nothing downloaded and nothing pinned is refreshed only by
the poll, and only while it is still in the viewed set.

## Bounding `viewed`: the 256 cap

"Finder has enumerated" is not "the user has looked". `ls -R`, a Spotlight pass, `grep -r`, or
the eager download of a freshly pinned subtree enumerates every directory it touches. Uncapped,
each would become a polled root for the session: one `readdir` per minute per directory at tier 0.

The viewed set holds at most **256** directories per location and evicts the least recently
enumerated.

## Rotating `materialized` at tier 0

`materialized` is not capped, since dropping a directory from it would leave cached files
unwatched. But a photo library browsed under a one-month TTL leaves thousands of directories
holding one downloaded file each, and a `readdir` of every one per cycle is not proportional to
anything the user is doing.

So each tier 0 cycle lists:

- every `viewed` and `pinned` root;
- at most **64** `materialized`-only roots, round-robin in order of least recent listing.

A directory holding only cached files is refreshed every `ceil(M / 64)` cycles, and the cost per
cycle is bounded whatever `M` is. `status` shows the rotation period when it exceeds one cycle.

The rotation is tier 0's alone. Tier 1 passes the whole set to `find`, whose cost is the
server's, and the helper watches all of it. A reconnect's full sweep suspends the rotation for one
cycle ([change detection](change-detection.md#reconnect)).

## Sharing the materialized set

Enumerating the system's materialized set is not free, so the last one read is published.
`sshdrive status` reuses whichever of the tier 0 cycle, the eviction pass
([eviction](eviction.md)) or `materializedItemsDidChange` published it last, rather than
enumerating again.

## Directory renames

A remote rename of a directory reaches tiers 0 and 1 as delete + create of the whole subtree:
cached content under it is discarded and, if kept, re-downloaded. The helper reports the rename
and keeps identifiers and content. Recognising moves at the polling tiers is
[future work](future-work.md).

## Eviction and pin maintenance

The eviction loop ([eviction](eviction.md)) and the kept-subtree walk ([pinning](pinning.md)) run
in the agent on timers. The agent is not sandboxed, so it `stat`s files under
`~/Library/CloudStorage/…` directly. The TTL takes the replica's mtime from that `stat`; atime is
read and logged beside the decision and decides nothing ([eviction](eviction.md)).
