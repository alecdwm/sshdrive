# The SFTP client

We implement the SFTP v3 wire protocol in Swift over the `ssh` process's
stdio: a length-prefixed packet framing, the twenty request types, and the
OpenSSH extensions we use (`posix-rename@openssh.com`, `statvfs@openssh.com`,
`fsync@openssh.com`, `limits@openssh.com`, `lsetstat@openssh.com`). It
is a few thousand lines, has no dependencies,
and is tested against OpenSSH's `sftp-server` directly on stdio without any
network.

Requests are pipelined: reads and writes keep sixteen requests in flight, each
of the largest size the server will take, which is what gives `sftp(1)`-class
throughput. `limits@openssh.com` sizes the request, not the window: it
advertises `max-packet-length`, `max-read-length`, `max-write-length` and
`max-open-handles`, and says nothing at all about how many requests may be
outstanding, so the chunk size is the server's and the depth is ours. OpenSSH
9.2 and 9.7 both answer 255 KiB reads and writes inside a 256 KiB packet
(measured against the testbed, 2026-09-04), which makes the window about 4 MiB;
without the extension the chunk falls back to a conservative 32 KB, and sixteen
of those is a 512 KiB window.

`readdir` uses the same window. A page carries about a hundred names on every
server we have measured, so a directory of ten thousand entries is a hundred
pages, and what bounds the first Finder listing of it is not the bytes but how
many of those questions are in the air at once: at a depth of two it is fifty
serial round trips, three quarters of a second on a 15 ms link for a directory
that transfers in a tenth of one. The client fills a window of sixteen
`SSH_FXP_READDIR`s on the one handle, drains it, and asks again until the server
answers EOF - seven round trips for that directory, and **one** for any
directory of sixteen pages or fewer, which is nearly every directory anyone
opens. Three things follow. The pages are reassembled in the order the
*questions* went out, not the order the answers arrive: a directory's pages are
cut server-side and handed out in arrival order, the window is filled by
concurrent requests, and merging in completion order really does shuffle a
listing - which the name rules must not have
([docs/design/names-and-attributes.md](names-and-attributes.md)), because they break a collision between
two new names by the order the listing reported them. The order a request went
out in is not its request id either, since an id is allocated before the
outstanding-request gate; it is recorded when the packet is appended to the
outbox. And the window over-issues at the end, because it is filled before EOF
can come back: at most fifteen extra requests per listing, each answered with an
EOF status and dropped, which is the price of never paying a round trip per
page.

A listing reads its links' targets through that window too. SFTP v3's `readdir`
carries attributes but no target, so every symlink a listing reports costs a
`readlink` ([docs/design/symlinks.md](symlinks.md)); those go out sixteen in flight rather
than one at a time, and a `readlink` that fails costs only its own link, not the
listing.

One property of the window is not measured. OpenSSH's `sftp-server` reads its
requests one at a time, so sixteen outstanding `readdir`s on one handle are
answered strictly in order, but Go's `pkg/sftp` - Tailscale SSH's SFTP
subsystem - dispatches requests to a pool of workers, and `os.File.Readdir` is
not documented as safe to call from two of them at once. What to look for is a
listing of a large directory on a `pkg/sftp` server that returns a name twice or
loses one; if it does, the depth becomes a server-fingerprint question (the
capability report already tells `pkg/sftp` from `sftp-server` by its extension
set, [docs/design/cli.md](cli.md)) rather than one number.
The client exposes a `protocol SFTPTransport` whose methods take
`RelativePath` values only ([docs/design/security.md](security.md)).

**Transfers are scheduled, not queued.** Every transfer of a location
runs on the bulk channel, and SFTP requests are independent per handle,
so transfers interleave: the agent runs at most four at once per
location, splits the pipelined window between them, and holds the rest
with their XPC calls open. The four are chosen from two classes.
Foreground transfers come first: a `fetchContents` whose
`NSFileProviderRequest` is a file-viewer request or is not a system
request (an app or the user opening the file; the extension passes the
two flags with the call), every `createItem` and
`modifyItem` upload, and every `fetchPartialContents`. Background
transfers, the eager downloads of a kept subtree ([docs/design/pinning.md](pinning.md))
and anything else the system issues on its own, start only while no
foreground transfer is waiting, and a running one is never pre-empted, so a
double-click during a 50 GB pin waits for at most one background
transfer's share of the window rather than for the pin. At a
`MaxSessions` of 2 ([docs/design/ssh.md](ssh.md)) the same scheduler runs on the
metadata channel and metadata requests are served ahead of both classes,
and each transfer takes half the pipelined window so the channel keeps
request slots free for them.

The system keeps at most **six** `fetchContents` calls open at once for an
eager subtree (measured on macOS 26.4, 2026-09-04: 38 transfers ran in
strict batches of six). That bounds the *background* class and nothing else:
eight files opened at once from a shell loop reached the extension as
eight simultaneous foreground `fetchContents` calls (measured on macOS
26.4, 2026-09-04), so "four running plus at most two waiting" is what the
agent holds for an eager subtree, not a limit on what it may be asked
for. The queue is therefore sized to six but not capped there: a seventh
arrival is admitted and counted rather than refused, because refusing a
`fetchContents` the system did make fails a user's open for the sake of a
measurement, and `sshdrive status` reports the count so the measurement
can be revisited if it moves.

Three details worth writing down before the first bug report. OpenSSH's
`SSH2_FXP_SYMLINK` takes its two path arguments in the opposite order from
the draft that defines it (`targetpath` first, then `linkpath`), and a
client that talks to `sftp-server` has to match OpenSSH, not the draft.
And every request carries a deadline (20 s for metadata, scaled by size
for transfers and extended while bytes keep arriving); a request that
misses it fails as `.serverUnreachable` and reports its channel dead
([docs/design/ssh.md](ssh.md)). And the status reply carries no errno. OpenSSH's
`errno_to_portable` folds `ENOENT`, `ENOTDIR` and `ELOOP` into
`NO_SUCH_FILE`, `EPERM` and `EACCES` into `PERMISSION_DENIED`, `EINVAL`
and `ENAMETOOLONG` into `BAD_MESSAGE`, `ENOSYS` into `OP_UNSUPPORTED`,
and everything else, `ENOSPC`, `EDQUOT`, `EEXIST`, `ENOTEMPTY` and
`EXDEV` included, into `FAILURE` with the literal message "Failure". The
client exposes exactly those classes and nothing finer, and every place
this design wants to know more (a collision, a full disk, a directory
that is not empty) asks a second question, an `lstat`, a `statvfs`, a
`readdir`, rather than reading an errno that is not there.

Why this rather than a library:

- OpenSSH is the only implementation that supports every auth mechanism,
  `ProxyJump`, key agents, certificates and FIDO keys, and it is already on every
  Mac. Reusing it is what makes the auth goal a one-liner
  ([docs/design/goals.md](goals.md)).
- The libraries on offer each fall short somewhere: `swift-nio-ssh` has no
  SFTP; Citadel does not document encrypted OpenSSH keys and has RSA in a
  fork; libssh2 chooses `posix-rename` for you whenever the server has it,
  which breaks the non-overwriting rename the upload protocol relies on
  ([docs/design/writes.md](writes.md)), has no `limits@openssh.com`, needs its own
  crypto backend built into an XCFramework for notarization, and its SFTP
  throughput is well below OpenSSH's.
- The protocol itself is small. The client is the easiest part of this
  project to test exhaustively.
