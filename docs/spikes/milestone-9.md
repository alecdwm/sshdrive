# Milestone 9 spike: tier 2, the remote helper

Runbook for DESIGN.md section 12 milestone 9 - the Rust helper binary, its cross
compilation, deploy/verify/upgrade over SFTP, the NDJSON protocol, `helper on|off` - and
for the helper half of spike **S7**, which milestone 6 left open because tier 2 did not
exist yet. Each section has the steps, what the design expects, and a **Result** line for
what actually happened. The long-form entry is in `results.md` under "2026-09-05
(milestone 9)".

| Tag | Meaning |
|---|---|
| **linux** | this development box: `cargo` and the cross targets. No Swift here. |
| **unit** | a package test (`swift test`) or a crate test (`cargo test`). |
| **mount** | needs the signed build installed on the VM and a real File Provider domain. |

---

## 0. Setup

### 0.1 Build the helper (linux)

```sh
rustup target add aarch64-unknown-linux-musl x86_64-unknown-linux-musl \
                  armv7-unknown-linux-musleabihf x86_64-unknown-freebsd
cd helper && cargo test          # 54 tests
scripts/build-helper.sh aarch64-unknown-linux-musl x86_64-unknown-linux-musl \
                        armv7-unknown-linux-musleabihf
```

`helper/.cargo/config.toml` links the musl targets with rustc's own `rust-lld` and
`-C link-self-contained=yes`, so **no cross C toolchain is needed**. The binaries and
`manifest.json` land in `Resources/helper/`, which is in `.gitignore`.

**Result: all three link and run; 443,216 / 495,816 / 413,992 bytes,
`opt-level="z"`, `lto`, `panic=abort`, stripped.** `cargo check` passes for
`x86_64-unknown-freebsd` and `aarch64-apple-darwin`.
**`aarch64-unknown-freebsd` cannot be checked at all**: it is a tier 3 Rust target with no
prebuilt `rust-std`, and `rustup target add` refuses it ("no prebuilt artifacts
available"). Section 6.4's own target list stops at `freebsd/x86_64`, so nothing is owed;
section 13 records it and `.github/workflows/helper.yml` says where it would have to
change.

### 0.2 Build and install the app (VM)

```sh
scripts/mac-build.sh test        # 592 package tests
scripts/mac-build.sh signed      # run this LAST: it rsyncs with --delete
```

`mac-build.sh` now `ditto`s `Resources/helper/` into
`SSH Drive.app/Contents/Resources/helper/` **after `xcodebuild` and before `codesign`**,
because signing the app seals what is inside it. An absent `Resources/helper` is not an
error; the app then ships no helper and every location says so.

On the Mac VM:

```sh
"/Applications/SSH Drive.app/Contents/MacOS/sshdrive" agent stop
ditto "$HOME/sshdrive/build/Build/Products/Debug/SSH Drive.app" "/Applications/SSH Drive.app"
"/Applications/SSH Drive.app/Contents/MacOS/sshdrive" agent start
```

### 0.3 The servers this spike needs

| Server | Port | Why |
|---|---|---|
| `deb` | 2201 | Debian 12, glibc, GNU `find`, `MaxSessions` default: the ordinary tier 2 case |
| `alp` | 2206 | Alpine, **musl**, busybox: the same static aarch64 binary has to run here too |
| `deb-maxsess` | 2205 | `MaxSessions 2`: the helper must be refused a channel |
| `deb-shells` | 2202 | the `forcesftp` account: `ForceCommand internal-sftp`, no shell at all |

Every change to a served tree below is made by a **separate** `ssh`, never by the agent.
`~/bin/timeout` (the perl `alarm`/`exec` from `milestone-5.md` 0.2) wraps every `ssh` and
every touch of a mount; macOS has no `timeout`.

**A harness written in zsh must spell `${=K}`, not `$K`.** zsh does not word-split an
unquoted parameter, so `K="-o BatchMode=yes -i ~/.ssh/…"; ssh $K …` passes the whole thing
as one argument and every remote command silently fails with
`keyword batchmode extra arguments at end of line`. The first latency run "passed" three
steps that way, because a file that was never created is also never seen.

---

## 1. The crate (unit, linux)

`cargo test` in `helper/`. **Result: 54 tests, 0 failures.**

| Group | What it pins |
|---|---|
| `json` | the NDJSON escaping, `\u00XX` for control characters, base64 both ways, the control-line parser, and that a truncated line is refused rather than guessed |
| `proto` | every op section 6.4 names is one line; a delete carries no metadata; the coalescer's merge table (create+modify→create, anything+delete→delete, delete+create→modify, a rename clearing both endpoints, 100 writes→1 line, overflow first and once) |
| `paths` | the ignore list is exactly section 6.4's, `.git` is **not** on it, containment is a whole-component byte comparison, a non-UTF-8 name round-trips, `..` never passes |
| `walk` | the sweep against a real tree: shallow vs recursive depth, every hit complete (size+mtime+inode+mode), the **ctime** window, exclusions, the ignore list, a symlinked directory as a leaf, a fifo skipped, the entry limit becoming an overflow |
| `watch_inotify` | against a real tree: create/modify/rename/delete, a **`chmod`** (`IN_ATTRIB`), a new directory under a recursive root watched and its contents reported, a shallow root not descending, exclusions, a burst of 50 writes coalescing to one line, a move out of the watched set as a delete |
| `control` | `.` is a ping; a `roots` line replaces the set; a garbled line is a complaint and still a ping; silence expires; **EOF expires at once**; lines are framed on newlines, not on reads |
| `sha256` | the published vectors, chunked input, a real file |

`cargo clippy --all-targets -- -D warnings` is clean and is a CI gate.

**The kqueue build is compiled and not exercised.** `cargo check
--target x86_64-unknown-freebsd` and `--target aarch64-apple-darwin` pass; there is no BSD
to run it on here and the build VM cannot host one. **S7's FreeBSD row stays open.**

---

## 2. The Swift side (unit, VM)

`swift test`. **Result: 592 tests, 0 failures** (was 548; 40 skipped without
`SSHDRIVE_TESTBED=1`). With `SSHDRIVE_TESTBED=1` on the VM, `TestbedHeartbeatTests` -
including the new relay test against Debian dash and Alpine busybox ash - is 5 of 5.

New: `HelperDeploymentTests` (the `uname -sm` table, the upload verdict from every
evidence shape, the seven-day rule, the relay-FIFO sweep, the `--version` line),
`HelperEventTests` (the decoder's framing, `path_b64`, the flood becoming one `overflow`,
the roots control line), the tier 2 half of `ChangeDetectionLadderTests`, and the relay
half of `RemoteScriptTests` and `TestbedHeartbeatTests`.

---

## 3. Deploy, verify and the mount at tier 2 (mount, `deb`)

```sh
sshdrive add m9 alec@192.168.64.1:2201 --identity ~/.ssh/sshdrive-spike --path /home/alec/m9
```

**Result: `add` says so before anything is uploaded**, with the directory the probe chose,
which is section 6.4's requirement:

```
SSH Drive will upload a small helper binary to /home/alec/.cache/sshdrive on this server
to watch for changes; disable with `sshdrive set m9 helper off`
```

and 20 s later:

```
watch helper   every 60s (active)   1 cycle(s)   1 root(s)
Capabilities  8/8 optimal   probed 29s ago
● change detection     helper 0.1.0 at /home/alec/.cache/sshdrive (push, ~1s)
      note: ignores: .sshdrive-upload-*  .*.swp  *~  .#*  4913
● rename detection     helper move events
● change evidence      ns-mtime + inode
```

On the server: `-rwx------ 1 alec alec 443216 … sshdrive-helper-0.1.0-linux-aarch64`, mode
700 in a 700 directory, and one process

```
/home/alec/.cache/sshdrive/sshdrive-helper-0.1.0-linux-aarch64 watch --json \
    --root /home/alec/m9 --roots-from-stdin --shallow …
```

**This is the first `8/8 optimal` any milestone has produced.**

---

## 4. Latency: create, modify, rename, delete, chmod (mount)

A separate `ssh` makes each change; the mount is polled every 100 ms with a 30 s ceiling.
Section 6.4 promises "about a second"; milestone 6 measured the same steps at the poll
interval.

**Result:**

| Step | `m9` (`deb`, glibc) | `m9a` (`alp`, musl + busybox) | milestone 6, tier 1 |
|---|---|---|---|
| create -> visible | **260 ms** | **129 ms** | 59,743 ms |
| modify -> new content | **903 ms** | **308 ms** | 104 ms* |
| rename -> new name visible | **82 ms** | **106 ms** | 59,923 ms |
| rename -> old name gone | **85 ms** | **79 ms** | 7 ms* |
| delete -> gone | **78 ms** | **82 ms** | 59,647 ms |
| chmod -> mode changes in the mount | **76 ms** | **78 ms** | not seen at all on busybox |

\* milestone 6's millisecond rows are an artefact of the cadence: everything one 60-second
cycle finds arrives together. At tier 2 every row is independent, and **every one is under
a second**.

The last row is the case S7 measured tier 1 losing: a `chmod` on a file with an old mtime
moves ctime and not mtime, so a busybox `-mmin` sweep provably misses it. The helper
watches `IN_ATTRIB` and reports it on both servers in under 80 ms.

---

## 5. The helper stream beside two SFTP channels (mount, S7 s7-1's helper half)

48 MiB file on the server, two concurrent `cat`s of it through the mount, and a file
created on the server in the middle of them.

**Result: all three channels lived.**

```
channels 3 at a time, bulk channel, shell
watch helper   every 60s (active)   5 cycle(s)
a file created during two concurrent fetches appeared after 1215 ms
transfers 0 running, 0 waiting, 2 admitted
```

The Mac's side of the connection during the test is exactly the budget of section 6.1: one
`-N` master, two `ssh … -s sftp` mux clients, and one `ssh … sh -s` carrying the helper.

---

## 6. Killing the client kills the helper (mount, S7 s7-6's helper half)

`kill -9` on the master and all three mux clients at once - no `-O exit`, no close, exactly
what a crashed agent leaves behind - then a **separate** ssh watches the server.

**Result:**

```
t+0s   helper processes on the server: 1
t+10s  helper processes on the server: 0
```

Gone in under 10 s, well inside the 60 s heartbeat window, and by the helper's *own* rule
rather than the wrapper's: its stdin is the relay FIFO, whose only writer was the wrapper,
so the write end closed and the helper saw EOF. The wrapper's 60 s timeout is the second
line of defence section 6.4 says it is.

The agent then reconnected on the breaker's schedule and the next cycle started a new
stream: **killed 02:37:55, streaming again 02:39:30**, with a full sweep in between to
catch what happened while it was away.

---

## 7. A corrupted deployed binary (mount)

Seven bytes overwritten in place, **same size**, so only a hash can see it.

**Result:**

```
sha256 before:               bb786789…dbe962
sha256 after corruption:     d22a836d…3b16ef   (443216 bytes, unchanged)
sshdrive agent restart
sha256 after the agent came back: bb786789…dbe962
REDEPLOYED: the bytes match the build again
```

**Writing over the running helper failed first, with `Text file busy`** - `ETXTBSY`, which
is precisely why section 6.4 uploads to a temp name and renames rather than writing over
the existing file. The corruption had to kill the running helper first.

---

## 8. `helper off` and `helper on` (mount)

**Result:**

```
$ sshdrive set m9 helper off
m9: helper is now off
  removed 1 helper file(s) from the server.

watch sweep   every 60s (active)
  note: the helper is off for this location
◐ change detection     sweep (find -cmin over the root set)
      note: the helper is off for this location

$ sshdrive set m9 helper on
m9: helper is now on

watch helper   every 60s (active)
● change detection     helper 0.1.0 at /home/alec/.cache/sshdrive (push, ~1s)
```

The binary is removed on the spot, not "on the next connection": the connection is up when
the setting changes, so there is no reason to wait.

**`helper off` left two relay FIFOs behind** (`.sshdrive-helper-in-<n>`), so the directory
could not be removed either. The wrapper's `EXIT` trap removes its own FIFO, but the trap
does not run when the wrapper is SIGKILLed - which is every abrupt client kill, the case
the wrapper exists for. Fixed: the deployment sweeps them with no age rule (a FIFO with no
writer is inert) and `helper off` removes them too, with a test.

---

## 9. `deb-maxsess` (2205), `MaxSessions 2`

**Result: the helper is refused a channel, and the note says exactly that.**

```
◐ change detection     sweep (find -cmin over the root set)
      note: the server will not give the helper a channel of its own (MaxSessions 2)
      upgrade: the remote helper (push events, real renames)
```

Nothing was uploaded. This is a rule tier 1 did not need: a sweep opens a channel, spends
half a second on it and gives it back, while the helper's stream holds one for the life of
the connection. At `MaxSessions 2` the single spare channel is shared by the probe, the
`sshdrive test` command and section 6.4's own 30-minute insurance sweep, and a helper that
never gave it back would cost the location all three. `ChannelBudget` grew
`allowsPersistentExecChannel` for it (section 13, 2026-09-05).

---

## 10. `forcesftp` on `deb-shells` (2202), `ForceCommand internal-sftp`

**Result: reported as no shell, and the helper's note says so** - not "shell output
unusable", which is the distinction section 9.2 spends a paragraph on.

---

## 11. S7's helper questions, answered

| # | Question | Answer |
|---|---|---|
| s7-1 (helper half) | Does a long-running helper stream coexist with two SFTP channels on one connection? | **Yes.** Section 5: two concurrent 48 MiB fetches on the bulk channel, the helper streaming on the exec channel, and an event delivered in 1,215 ms while both ran |
| s7-6 (helper half) | Does the helper die when the client is killed abruptly? | **Yes, within 10 s**, by its own stdin-EOF rule; the wrapper's 60 s is the backstop |
| **FreeBSD kqueue on a 100,000-file tree** | | **Not testable here.** The testbed is Linux containers and the build VM cannot host a BSD. The kqueue build compiles for `freebsd/x86_64` and `darwin/arm64` and is exercised by nothing. **Open.** |
| armv7 | Does the Synology/QNAP target work? | **Links only.** No armv7 hardware here. **Open.** |

---

## 12. Teardown

```sh
for n in m9 m9a m9x m9f; do yes | sshdrive remove "$n" --force; done
```

**`--force` is not `--yes`.** It waives the pending-upload refusal; the
"Remove "m9"? The local cache and the keychain items only it names go too. [y/N]" prompt
is still there, and a teardown script that does not answer it hangs on the first location
with nothing on stdout to say why.

`remove` takes the helper off the server on its last connection - "when no other location
of this Mac on the same `user@hostname:port` uses them" (section 8), which for
`remove --all` has to count the locations being removed in the same breath as already
gone - so nothing has to be cleaned up by hand.

**Result, afterwards:**

```
port 2201: ls: cannot access '/home/alec/.cache/sshdrive': No such file or directory   0
port 2205: ls: cannot access '/home/alec/.cache/sshdrive': No such file or directory   0
port 2206: ls: /home/alec/.cache/sshdrive: No such file or directory                   0
domains: No locations.        ~/Library/CloudStorage: empty
ssh processes: none           control sockets: none
```

(the trailing `0` is `ps | grep -c sshdrive-helper` on each server)
