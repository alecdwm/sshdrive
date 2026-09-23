# The SFTP client

SSH Drive speaks SFTP v3 itself, in Swift, over the stdio of an `ssh` mux client
([ssh](ssh.md)). Requests are pipelined sixteen deep, transfers are scheduled at most four at once
per location, and the wire carries status classes, never an errno.

## Scope

- Length-prefixed packet framing and the twenty request types.
- Five OpenSSH extensions: `posix-rename@openssh.com`, `statvfs@openssh.com`,
  `fsync@openssh.com`, `limits@openssh.com`, `lsetstat@openssh.com`.
- A few thousand lines, no dependencies, tested against OpenSSH's `sftp-server` directly on stdio
  without any network.
- The client exposes a `protocol SFTPTransport` whose methods take `RelativePath` values only
  ([security](security.md)).

## Pipelining

Reads and writes keep **sixteen requests** in flight, each of the largest size the server will
take. That is what gives `sftp(1)`-class throughput (SQ-051).

`limits@openssh.com` sizes the request, not the window (SQ-027, gotcha 38). It advertises
`max-packet-length`, `max-read-length`, `max-write-length` and `max-open-handles`, and says nothing
about how many requests may be outstanding. The chunk size is the server's; the depth is ours.

| Server | Chunk | Window (x16) |
|---|---|---|
| OpenSSH 9.2 and 9.7 (`limits` answered) | 255 KiB inside a 256 KiB packet | about 4 MiB |
| no `limits@openssh.com` | 32 KB | 512 KiB |

## `readdir`

`readdir` uses the same window. A page carries about a hundred names, so a 10,000-entry directory
is a hundred pages, and the first Finder listing is bounded by round trips, not bytes (SQ-051).

The client fills a window of sixteen `SSH_FXP_READDIR`s on the one handle, drains it, and asks
again until the server answers EOF: seven round trips for that directory, and **one** for any
directory of sixteen pages or fewer.

- **Pages are reassembled in the order the questions went out**, not the order answers arrive. A
  concurrent window really does shuffle a listing if merged in completion order, and the
  [name rules](names-and-attributes.md) break a collision between two new names by listing order.
- **Request order is not the request id**, since an id is allocated before the outstanding-request
  gate. The order is recorded when the packet is appended to the outbox.
- **The window over-issues at the end**, because it is filled before EOF can come back: at most
  fifteen extra requests per listing, each answered with an EOF status and dropped.

A listing reads its links' targets through the window too: every symlink costs a `readlink`
([symlinks](symlinks.md#reading-targets)), those go out sixteen in flight, and a `readlink` that
fails costs only its own link.

!!! note "Unmeasured: pipelined `readdir` on Go `pkg/sftp`"
    OpenSSH's `sftp-server` reads requests one at a time, so sixteen outstanding `readdir`s on one
    handle are answered strictly in order. Go's `pkg/sftp` (Tailscale SSH's subsystem) dispatches
    requests to a pool of workers, and `os.File.Readdir` is not documented as safe to call from
    two of them at once. The symptom to look for is a large listing on a `pkg/sftp` server that
    returns a name twice or loses one. If it does, the depth becomes a server-fingerprint question
    (the capability report already tells `pkg/sftp` from `sftp-server` by its extension set,
    [cli](cli.md)) rather than one number.

## Transfer scheduling

Every transfer of a location runs on the bulk channel. SFTP requests are independent per handle,
so transfers interleave: the agent runs **at most four at once per location**, splits the
pipelined window between them, and holds the rest with their XPC calls open.

The four are chosen from two classes:

| Class | What is in it | When it runs |
|---|---|---|
| Foreground | a `fetchContents` whose `NSFileProviderRequest` is a file-viewer request or is not a system request (the extension passes the two flags with the call); every `createItem` and `modifyItem` upload; every `fetchPartialContents` | first |
| Background | eager downloads of a kept subtree ([pinning](pinning.md)); anything else the system issues on its own | only while no foreground transfer is waiting |

A running transfer is never pre-empted, so a double-click during a 50 GB pin waits for at most one
background transfer's share of the window, not for the pin.

At `MaxSessions` 2 ([ssh](ssh.md#channels-and-maxsessions)) there is no bulk channel: the same
scheduler runs on the metadata channel, metadata requests are served ahead of both classes, and
each transfer takes half the pipelined window so the channel keeps request slots free for them.

### The six-fetch ceiling

The system keeps at most six `fetchContents` calls open at once for an eager subtree (MQ-031).
That bounds the background class and nothing else: eight files opened at once from a shell arrive
as eight simultaneous foreground calls (MQ-032, gotcha 42).

So "four running plus at most two waiting" is what the agent holds for an eager subtree, not a
limit on what it may be asked for. The queue is sized to six but not capped: a seventh arrival is
admitted and counted, because refusing a `fetchContents` the system did make fails a user's open.
`sshdrive status` reports the count so the measurement can be revisited if it moves.

## Request deadlines

Every request carries a deadline:

- 20 s for metadata;
- for transfers, scaled by size and extended while bytes keep arriving.

A request that misses it fails as `.serverUnreachable` and reports its channel dead
([ssh](ssh.md#dead-connections)).

## Status codes carry no errno

OpenSSH's `errno_to_portable` folds errno into SFTP status classes (SQ-028, gotcha 24):

| errno | SFTP status |
|---|---|
| `ENOENT`, `ENOTDIR`, `ELOOP` | `NO_SUCH_FILE` |
| `EPERM`, `EACCES` | `PERMISSION_DENIED` |
| `EINVAL`, `ENAMETOOLONG` | `BAD_MESSAGE` |
| `ENOSYS` | `OP_UNSUPPORTED` |
| everything else, including `ENOSPC`, `EDQUOT`, `EEXIST`, `ENOTEMPTY`, `EXDEV` | `FAILURE`, message "Failure" |

The client exposes exactly those classes. Wherever the design needs to know more (a collision, a
full disk, a directory that is not empty) it asks a second question - an `lstat`, a `statvfs`, a
`readdir` - rather than reading an errno that is not there.

!!! warning "`SSH2_FXP_SYMLINK` argument order"
    OpenSSH takes the two paths in the opposite order from the draft that defines it: `targetpath`
    first, then `linkpath` (SQ-029). A client talking to `sftp-server` has to match OpenSSH, not
    the draft.

## Why not a library

- **OpenSSH does the auth.** It is the only implementation that supports every auth mechanism,
  `ProxyJump`, key agents, certificates and FIDO keys, and it is already on every Mac. Reusing it
  is what makes the auth goal a one-liner ([goals](goals.md)).
- **The libraries each fall short:**
    - `swift-nio-ssh` has no SFTP.
    - Citadel does not document encrypted OpenSSH keys and has RSA in a fork.
    - libssh2 chooses `posix-rename` whenever the server has it, which breaks the non-overwriting
      rename the upload protocol relies on ([writes](writes.md)); it has no `limits@openssh.com`,
      needs its own crypto backend built into an XCFramework for notarization, and its SFTP
      throughput is well below OpenSSH's.
- **The protocol is small.** The client is the easiest part of the project to test exhaustively.
