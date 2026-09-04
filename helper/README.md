# `sshdrive-helper` — the remote helper (DESIGN.md section 6.4, tier 2)

One small static Rust binary that SSH Drive uploads to the server over the connection it
already has, runs on an exec channel under the heartbeat wrapper of section 9.2, and reads
NDJSON events back from. It is what makes a remote change arrive in about a second instead
of at the next 60-second poll, and it is the only tier that reports a **rename** as a
rename, so the item keeps its identifier, its pin, its tags and its cached bytes.

It never listens on a socket, never runs detached, writes only to its own directory, and
exits when its stdin closes or the agent's pings stop — with or without sshd's help
(section 9).

```
sshdrive-helper --version
sshdrive-helper watch --json --root <dir> [--roots-from-stdin]
                      [--shallow P]… [--recursive P]… [--exclude P]…
sshdrive-helper sweep --root <dir> [--since <epoch seconds>] [--shallow P]…
```

## What it does

| | |
|---|---|
| Linux | inotify, read directly — not `inotifywait` (section 14), which is not installed on a NAS and does not expose the rename cookie |
| FreeBSD, macOS | kqueue on **directories** plus its own `sweep` every 60 s. kqueue reports a content change only through a descriptor held open on each watched *file*, and a hundred thousand of those does not fit; `status` says `helper (kqueue + 60s sweep)` rather than claiming push latency |
| Scope | the root set of section 6.5, sent on stdin and applied live: `--shallow` roots are watched one level deep, `--recursive` roots all the way down, `--exclude` prunes a subtree |
| Ignored | `.sshdrive-upload-*`, `.*.swp`, `*~`, `.#*`, `4913`. **`.git` is deliberately not on the list**: a repository browsed through the mount must show a current `.git` |
| Containment | symlinks are never followed (`IN_DONT_FOLLOW`, `O_NOFOLLOW`), so a directory swapped for a link to `/etc` yields the link and nothing under it (section 9.1) |
| Coalescing | a burst on one path leaves the server as one line; a batch over 5,000 events becomes a single `overflow`, which the agent answers with a sweep |

## The protocol

NDJSON on stdout, one line per event, `\n`-framed, parsed as bytes:

```json
{"op":"ready","version":"0.1.0","os":"linux","arch":"aarch64","mechanism":"inotify","roots":3}
{"op":"create","path":"a/b.txt","type":"f","size":3,"mtime_ns":…,"inode":42,"mode":420,"uid":1000,"gid":1000}
{"op":"rename","from":"a/b.txt","path":"a/c.txt","type":"f",…}
{"op":"delete","path":"a/c.txt"}
{"op":"overflow","reason":"the kernel event queue overflowed"}
{"op":"heartbeat","t":1788538116}
```

Two lines section 6.4 does not name are here and are recorded in section 13 (2026-09-05):
**`ready`**, because the ladder settles on "the first tier that starts successfully" and the
agent needs one byte that says the binary is running rather than that `sh` printed
something; and **`error`**, so a helper that cannot establish a watch says why.

Paths are **relative to `--root`** and are in server bytes. A name that is valid UTF-8
travels as `"path"`; one that is not travels as `"path_b64"`, base64 of the raw bytes,
because a JSON string is UTF-8 by definition and a server filename need not be (section
5.4). That is the one thing tier 1 cannot do: `set --` is a String pipeline end to end
(section 9.2), so a non-UTF-8 root has to be dropped from a sweep.

On **stdin** the agent sends `.` as a ping every 15 s and, when the root set changes,

```json
{"op":"roots","shallow":["a","b/c"],"recursive":["pin"],"excluded":["pin/big"]}
```

Sixty seconds without a line, or EOF, and the helper exits. That is a second, independent
kill switch beside the wrapper of section 9.2.

**How stdin reaches it.** Section 9.2 says background children never share the script's
stdin — they are started `</dev/null` so they cannot swallow the heartbeat lines — and
section 6.4 says the helper is fed its root set and its pings on stdin. Both cannot be the
channel's stdin, and only one process may read a pipe. So the wrapper stays the only reader
and **relays** every line it reads into a FIFO in the helper's own directory, which the
helper is given as its stdin (`RemoteScript.stdinRelay`). A server where `mkfifo` fails runs
the helper `</dev/null` with its initial root set on its own argv; it then watches what it
was started with, and the wrapper is its only kill switch. Recorded in section 13
(2026-09-05).

## `--version`, and how the agent verifies the binary

```
sshdrive-helper 0.1.0 linux/aarch64 sha256=bb78…e962
```

The digest is of the **running executable**, computed at startup. Section 6.4 asks for
verification "by SHA-256 against a hash embedded in the app where the server has
`sha256sum` or `shasum`, and by size plus its own `--version` output otherwise"; a constant
compiled in could not be the hash of the file that contains it, so the fallback path is a
real check rather than a weaker one (section 13, 2026-09-05).

## Building

```sh
rustup target add aarch64-unknown-linux-musl        # once
scripts/build-helper.sh aarch64-unknown-linux-musl x86_64-unknown-linux-musl
```

`helper/.cargo/config.toml` links the musl targets with rustc's own `rust-lld` and its
bundled self-contained objects, so **no cross C toolchain is needed** — `rustup target add`
is the whole of the setup. The binaries and a `manifest.json` (version, sha256 and size per
target) land in `Resources/helper/`, which `scripts/mac-build.sh` copies into
`SSH Drive.app/Contents/Resources/helper/` after `xcodebuild` and before signing. Neither
directory is in git; an absent helper is not a build failure, and the agent then reports the
sweep tier with "this build ships no helper binaries" as the reason.

Release binaries come from `.github/workflows/helper.yml`: a Linux job for the three musl
targets (rust-lld) and `freebsd/x86_64` (`cross`, which needs Docker), feeding a macOS job
that builds `darwin/arm64` natively, ad-hoc signs it — arm64 macOS refuses to run unsigned
code even over ssh — and rewrites the manifest over all of them (section 10.1).

| Target | Built by | Verified |
|---|---|---|
| `x86_64-unknown-linux-musl` | rust-lld, self-contained | linked and run |
| `aarch64-unknown-linux-musl` | rust-lld, self-contained | linked and **run on the testbed** (glibc `deb` and musl `alp`) |
| `armv7-unknown-linux-musleabihf` | rust-lld, self-contained | linked only; no armv7 hardware here |
| `x86_64-unknown-freebsd` | `cross` in CI | `cargo check` only; the testbed has no BSD |
| `aarch64-apple-darwin` | native on the macOS runner | `cargo check` only from Linux |
| `aarch64-unknown-freebsd` | **not built** | tier 3 in Rust: no prebuilt `rust-std`, so it cannot be built or even checked without `-Z build-std` on nightly. Section 6.4's own list stops at `freebsd/x86_64` |

## Tests

`cargo test` in this directory. 54 tests, no network and no server: the protocol's framing
and escaping, the coalescer's merge table, the sweep against a real temporary tree
(depth, the ctime window, exclusions, the ignore list, a symlinked directory, a fifo), the
inotify watcher against a real temporary tree (create/modify/rename/delete, a `chmod`, a new
subdirectory under a recursive root, a burst coalescing to one line, a move out of the
watched set), the stdin control framing, and SHA-256 against the published vectors.

The kqueue build is compiled for FreeBSD and macOS but is **not** exercised anywhere: the
testbed is Linux containers and the build VM cannot host a BSD. Its tests are the Linux
ones by construction, which is not the same thing, and section 11's S7 FreeBSD row stays
open.
