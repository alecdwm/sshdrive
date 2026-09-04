# Spike results

One entry per sub-question, newest date first. Steps and expected answers are in
`milestone-1.md` (S1, S3, S4, S6) and `milestone-2.md` (S2); this file records only what
happened.

---

## 2026-09-04 (milestone 3, part 2) - the CLI: `add` with relayed prompts, `list`/`show`/`remove`/`set`, and the section 8.1 capability report

Section 8's user-facing half, section 4.2's collect connection driven from a terminal, and
section 8.1's report. Same headless VM (macOS 26.4.1 arm64, `OpenSSH_10.2p1`), the signed
Debug build from `scripts/mac-build.sh signed` installed over `/Applications/SSH Drive.app`
with `ditto`. Testbed up on the Mac; seven services were used (`deb` 2201, `deb-kbdint`
2204, `deb-maxsess` 2205, `alp` 2206, `bastion-a` 2210 and, behind it, `bastion-b` and
`inner`). Every `add` was driven over ssh with its answers on stdin, which is a pipe, so
the hidden-tty read falls back to a line read - that path is what a script and a CI run
take too.

**295 package tests, 0 failures** (was 246; 31 skipped without the testbed). The 49 new
ones are the destination and `set`-key parser (`ConfigTests`), the `ssh -G` attribution
diff and its display (`SSHProcessTests`), the add-flow state machine and the broker driven
through `AskpassHarness` (`AgentCoreTests`), and three for the nested-transaction fix
below (`IndexTests`).

### What `add` does, in order

The whole of section 8's paragraph, on one screen:

```
$ sshdrive add deb alec@192.168.64.1:2201 --identity ~/.ssh/sshdrive-spike
192.168.64.1 resolves to:
  user alec (from this location)
  hostname 192.168.64.1 (ssh default)
  port 2201 (from this location)
  identityfile /Users/alec/.ssh/sshdrive-spike (from this location)
  identitiesonly yes (from this location)
  …
Your terminal's PATH differs from the login shell snapshot SSH Drive will use.
  terminal:  /Applications/SSH Drive.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin
  SSH Drive: /opt/homebrew/opt/openjdk@17/bin:…:/Library/Apple/usr/bin
Your terminal's SSH_AUTH_SOCK differs from the one SSH Drive will use.
  terminal:  (unset)
  SSH Drive: /var/run/com.apple.launchd.be1Nf5Ktqm/Listeners
Connecting once to check, with the command SSH Drive will use later.
Connecting for real, from the stored answers.

Added deb (1EF434B3-164B-4F1B-B5B8-6C96451C9B5A)
  server     alec@192.168.64.1:2201
  root       /home/alec  (7 entries)
  mount      ~/Library/CloudStorage/SSHDrive-deb
  Capabilities  6/8 optimal   probed 0s ago
```

The attribution is the section 4.1 diff, and it earns its keep: every line above says
which of the three precedence levels it came from, and an `--identity` shows up as *from
this location* rather than being confused with a config file's `IdentityFile`. Against the
`spike-*` aliases the same display credits the config instead.

**"Connecting once to check" and "Connecting for real" are two different connections and
that is the point.** The collect connection is an `SSHMaster` on a scratch control path -
the same `ssh` command line the location's own master runs, differing only in
`StrictHostKeyChecking` (`ask` rather than `yes`, so section 4.3's question can be raised)
and in the socket it binds. It needs no remote command, because the control socket
appearing *is* authentication having succeeded, which is also why it would work against a
`ForceCommand internal-sftp` account. It is then shut down and the location connects
again, unattended, from the stored answers. Section 4.2's "a location that passes `add`
works from the agent" is therefore demonstrated on every `add` rather than asserted.

### The seven scenarios

| Scenario | Server | Result |
|---|---|---|
| key auth, no prompts | `alec@192.168.64.1:2201` | added; 7 entries; `6/8 optimal` |
| password relayed and stored | `pw@192.168.64.1:2201` | one prompt, answered on the terminal, `password:pw@192.168.64.1:2201` written **after** the connection authenticated |
| second location, same host | `pw@192.168.64.1:2201 --path /home/pw/.cache` | **no prompt at all**; the shared item answered it |
| one-hop chain | `alec@inner --jump hop@192.168.64.1:2210` | two prompts, keyed `password:hop@192.168.64.1:2210` and `password:alec@inner:22` |
| two-hop chain | `alec@inner --jump hop@192.168.64.1:2210,hop@bastion-b` | three prompts, three items, **a different password on each hop** |
| keyboard-interactive | `kbd@192.168.64.1:2204` | one prompt, stored as `password:kbd@192.168.64.1:2204` |
| fresh `known_hosts`, answered **no** | `alec@192.168.64.1:2206` | exit 1, "The server's host key was not accepted, so nothing was added", `known_hosts` untouched, no location |
| the same question, answered **yes** | `alec@192.168.64.1:2206` | added; `known_hosts` gained one entry; `5/8 optimal` (busybox) |
| wrong password | `keypass@192.168.64.1:2201` | exit 1, `ssh said: Permission denied (publickey,password)`, **nothing stored and no location** |
| a remote path that does not exist | `pw@…:2201 --path /home/pw/nope` | exit 1, "The server has no /home/pw/nope …", no location left behind |

The two-hop transcript, trimmed, is the one worth keeping:

```
  jump chain hop@192.168.64.1:2210 -> hop@bastion-b (rebuilt as SSH Drive's own
      ProxyCommand; never handed to ssh)
It will be stored in your keychain as password stored for hop@192.168.64.1.
hop@192.168.64.1's password:
It will be stored in your keychain as password stored for hop@bastion-b.
hop@bastion-b's password:
It will be stored in your keychain as password stored for alec@inner.
alec@inner's password:
Connecting for real, from the stored answers.
Added inner …
  jump       192.168.64.1 -> bastion-b
  auth       password stored for alec@inner
  auth       password stored for hop@192.168.64.1
  auth       password stored for hop@bastion-b
```

Section 4.2's reason for keying on `user@hostname:port` rather than on the location is
visible in three lines: the two bastions have deliberately different passwords and each
hop's prompt named its own host. The hops are told apart from the master by the argv the
askpass sends, exactly as milestone 2 established; nothing here parses the prompt text.

**Rollback is real.** Every failure above left `config.json`, the domain list and the
keychain as they were. Three of them fail before anything is written at all (the location
is created only after the collect connection succeeds), and the fourth - a bad
`--remote-path`, which is only discovered by the *second* connection - removes the domain,
the runtime, the config entry and the domain directory before it reports.

### `list`, `show`, `status`, `set`, `remove`

- **`list`** is the section 8 table: name, destination, mounted, state, TTL, and the
  secrets by kind. It connects nothing: state comes from runtimes that are already up, so
  a `list` on a laptop with no network is instant. `status --probe` is the way to ask for
  a connection on purpose.
- **`show`** prints the `ssh` binary and version, the whole `ssh -G` resolution with its
  attribution, the keywords section 6.1 overrode, the environment snapshot, whether the
  location runs `IdentityAgent=none` or through the key agent, the rebuilt `ProxyCommand`,
  the mount path, the last error, the stored secrets **by kind and never their values**,
  and the capability report.
- **`status`** carries section 8.1's report with the glyphs and the `upgrade:`/`note:`
  lines. Against `deb-maxsess` it also carries the part-1 channel budget:

```
maxsess   alec@192.168.64.1:2205   mounted   online   TTL 1h
       channels 2 at a time, no bulk channel, shell
         note: the server allows two channels at a time (MaxSessions 2): the bulk transfer
         channel is dropped and transfers share the metadata channel, …
       server sees us as uid=2401(alec) gid=2401 groups=2401
```

  and against `alp` the busybox `find` shows up twice, which is the report doing real work
  rather than printing a constant:

```
alp   5/8 optimal
  ◐ change detection  sweep (find -mmin over the root set; a rename or chmod moves ctime,
                      not mtime, so those are missed until the next full sweep)
  ◐ change evidence   size + mtime (same-second rewrites of equal size are missed)
        upgrade: a `find` that takes -printf (GNU findutils), or the helper
```

  `--json` emits the same objects (`{feature, level, best, glyph, upgrade, note}`), so the
  text and the machine-readable form cannot disagree - the agent computes both and the CLI
  only lays out.
- **`set`** applied `nickname` (domain re-created, `SSHDrive-alp` became
  `SSHDrive-alpine`, with the warning section 8 asks for - S9 is still unanswered, so the
  documented behaviour is what runs), `cache-ttl 1d`, and `option add|remove`. A bad value
  is refused and changes nothing (`"2h" is not a valid cache-ttl; expected
  15m|1h|12h|1d|1w|1mo|never`). `host|user|port|identity` re-run the collect connection
  before saving, as section 8 requires.
- **`remove`** asks section 8's confirmation (`n` leaves everything and exits 1), takes the
  domain, the index directory and the location, and applies the shared-item rule exactly:
  removing `debpw` while `debpw2` still named `password:pw@192.168.64.1:2201` left the item
  alone, and removing `debpw2` deleted it. `remove --all` cleared four locations and the two
  chain passwords in one go.
- **`doctor`** grew the four transport checks: `ssh -V`, `~/.ssh/config` parse warnings from
  a `ssh -G` of a name nothing can match, orphan control sockets (reported, never swept -
  `doctor` is a diagnosis), and keychain reachability under the access group. The
  login-shell snapshot summary was already there.

### Two assumptions that failed

**Section 5.3's "a listing is one transaction" could not be applied as written.** The first
real `add` died with `SQLite error 1: cannot start a transaction within a transaction`. The
listing's own body calls two things that are each a transaction in their own right -
`appendAnchor` for every changed row, and `delete`, which section 5.3 requires to write the
row and its deletion anchor together - and SQLite has no nested `BEGIN`. Both rules are
right; the helper was wrong. `SQLiteConnection.transaction` now nests, with `SAVEPOINT` for
every level below the outermost, so an inner failure its caller catches undoes only its own
writes and one that propagates still rolls the whole listing back. Three tests cover it.
Section 5.3 and section 13 say so now. (Part 1 measured the one-transaction listing before
the anchor calls moved inside it, which is why this was not seen then.)

**Section 4.2's 60 s authentication deadline cannot cover the collect connection.** It is
written as "every connection", and it exists because nothing may sit waiting for a human on
an unattended reconnect. But the collect connection is the one where somebody *is* at the
keyboard: reading a fingerprint off the screen and typing a password for each of three hops
took well over a minute in the two-hop run, and a 60 s kill lands in the middle of it. The
collect connection now runs to 300 s (the broker's token expiry moves with it), and the
master `add` brings up immediately afterwards carries the ordinary 60 s - which is the
connection that has to work unattended and therefore the one worth bounding. Section 4.2
and section 13 corrected.

### Three smaller things worth writing down

- **The CLI has to export an XPC object.** Section 4.2 has the agent "call back to the CLI
  over the same XPC connection", which the listener did not allow for: it set the
  extension's interface as `remoteObjectInterface` for every non-askpass peer. It now picks
  by executable, the same rule that gives `sshdrive-askpass` its one-method interface, so a
  `sshdrive` peer gets `SSHDriveCLIProtocol` (one prompt method, one note method) and
  everyone else the extension's.
- **The CLI's stdout must be unbuffered.** stdout is *fully* buffered when it is a pipe -
  which every transcript, `script -q` run and CI invocation is. The agent writes a relayed
  prompt through the file descriptor so it reaches the terminal before the read blocks on
  it; a buffered `print` from the CLI's own report then lands behind it, and the transcript
  stops matching what happened. `setvbuf(stdout, nil, _IONBF, 0)` once, in the client.
  Related: on a pipe nothing supplies the newline the user's Return would, so the CLI writes
  one itself after a piped read.
- **Reinstalling the app with `rm -rf` first loses the domains.** `NSFileProviderManager.domains()`
  then answers "The application cannot be used right now" until the extension is
  re-registered and the app relaunched. `ditto` **over** the existing bundle keeps
  everything, and `open -g "/Applications/SSH Drive.app"` by path rather than
  `open -g -a "SSH Drive"` by name is what stops LaunchServices registering the copy in
  the build directory instead - `sshdrive doctor`'s "app in /Applications" line is what
  catches that, and it caught it here. Worth knowing before blaming the code; nothing in
  the design depends on either.

### State the VM was left in

No locations, no File Provider domains, no `~/Library/CloudStorage` entries, no
`sshdrive-*` control sockets, and **an empty keychain** - the five items milestone 2 left
were deleted at the start of this pass so the prompt relay was genuinely exercised, and
everything this pass stored was removed with its location. `known_hosts` differs from the
backup by exactly the `[192.168.64.1]:2206` entry the host-key test removed and re-added.
Three `ssh -N -M … cm-hop@192.168.64.1-2210` and one `cm-hb4` process from the milestone-2
pass (15:17-15:41) are still running; they use the testbed config's own `ControlPath`, not
ours, which is itself the evidence for section 6.1's claim that our rebuilt hop touches
neither.

---

## 2026-09-04 (milestone 3, part 1) - the transfer scheduler, permissions to capabilities, and S3's deferred containment test

The §6.2 transfer scheduler on a second bulk channel, §5.4's permissions and hidden names,
and the containment half of S3 that milestone 1 deferred to a real server. Same headless VM
(macOS 26.4.1 arm64, `OpenSSH_10.2p1`), the signed Debug build from
`scripts/mac-build.sh signed` (`MAC_DIR=~/sshdrive`) installed over `/Applications/SSH Drive.app`
with `ditto` and restarted with `open -g`. Testbed up on the Mac; `deb` (2201) and
`deb-maxsess` (2205) were the two servers used.

**246 package tests, 0 failures** (was 214; 31 skipped without the testbed). The 32 new ones
are a new `AgentCore` module - `ItemDerivation`, `NameVisibility` and `TransferScheduler`
moved out of `Apps/Agent` so they can be unit-tested without an app bundle.

### The scheduler, on a real mount

Two SFTP mux clients on one master, visible in `ps`:

```
/usr/bin/ssh -N -o ControlMaster=yes -o ControlPath=$TMPDIR/sshdrive-159bb6b1 … 192.168.64.1
/usr/bin/ssh -F /dev/null -S $TMPDIR/sshdrive-159bb6b1 … -s 192.168.64.1 sftp   <- metadata
/usr/bin/ssh -F /dev/null -S $TMPDIR/sshdrive-159bb6b1 … -s 192.168.64.1 sftp   <- bulk
```

Eight 32 MiB files opened at once from a shell loop through
`~/Library/CloudStorage/SSHDrive-deb`, and the agent's own log:

```
159BB6B1…: transfer queued (4 running, 1 waiting)
159BB6B1…: transfer queued (4 running, 2 waiting)
159BB6B1…: 6 transfers held, above the six-fetch ceiling
159BB6B1…: transfer queued (4 running, 3 waiting)
159BB6B1…: 7 transfers held, above the six-fetch ceiling
159BB6B1…: transfer queued (4 running, 4 waiting)
```

`peakRunning 4`, `peakHeld 8`, every one of the eight delivering its full 33,554,432 bytes,
and the window share visibly splitting (16, 8, 5, 4 as the four filled up).

- **A 64 MiB upload** through the same scheduler and the same temp-file-plus-rename path:
  0.73 s, 87 MiB/s, on the bulk channel, streamed a megabyte at a time so it never sits in
  the agent's memory.
- **A cancel mid-fetch**: a 512 MiB file cancelled 300 ms in stopped at 52,485,120 bytes and
  answered "The transfer was cancelled."; cancelled 30 ms in, at 45,173,760. Uncancelled the
  same file takes 2.9 s. A queued transfer that is cancelled never starts.
- **A partial fetch**, 1 MiB at offset 16 MiB, returned exactly 1,048,576 bytes.

### The §6.2 assumption that failed

**The six-fetch ceiling bounds an eager subtree and nothing else.** S6 measured 38 transfers
running in strict batches of six and §6.2 concluded "the four running plus at most two
waiting is everything the agent ever holds". Eight `cat`s from a shell reached the extension
as **eight simultaneous foreground `fetchContents` calls**, so the agent held eight. The
scheduler now treats six as a size, not a cap: a seventh arrival is admitted and counted
(`overCeilingAdmissions`, which `status` shows) rather than refused, because refusing a
`fetchContents` the system did make fails a user's open for the sake of a measurement.
§6.2 and §13 corrected.

### `MaxSessions`: what the design wants at 2, and how the probe asks

`deb-maxsess` has `MaxSessions 2`. The `-N` master carries no session of its own, so two is
two *channels*, and master + metadata + bulk is exactly at the limit - with nothing left for
an exec channel. §6.1 already decides it: at 2 the bulk channel is dropped, transfers share
the metadata channel under the scheduler, and the second channel is kept for the shell,
because tier 1's sweep, the capability probe and the `id` identity all need exec and nothing
can share an exec channel, while transfers can share an SFTP one. So the probe's real
question is **"may I hold three at once"**, and two opens answer it: the second *is* the bulk
channel, and the third stands in for the exec channel and is closed again. Against 2205:

```
"channels": { "concurrentChannels": 2, "bulkChannel": false, "execChannel": true,
  "note": "the server allows two channels at a time (MaxSessions 2): the bulk transfer
   channel is dropped and transfers share the metadata channel, so a large download slows
   listings; the second channel is kept for shell access (sweep, probe, helper)" }
```

One `sftp` mux client in `ps`, the `id` probe still answering (`uid=2401(alec)`), the
scheduler's window share halved to 8 so the shared channel keeps request slots free for the
metadata calls served ahead of transfers, and uploads and fetches both working on it.

Two things worth writing down. **A channel is proved open by completing the SFTP handshake on
it**: `ssh` spawns successfully whether or not the session was granted, and only the refusal
on stderr, or a handshake that never lands, tells the two apart. And **the agent never sees a
server banner**, so §6.1's "cached once per server banner, re-probed when the banner changes"
cannot be implemented as written: its `ssh` runs at `LogLevel=ERROR`, which prints no remote
version, and a mux client speaks to the master's socket rather than to the server. The cache
in `domains/<id>/capabilities.json` is keyed by the location and invalidated only by an
explicit re-probe; a cached budget that has stopped holding is noticed anyway, because
opening the bulk channel is what the cached answer is used for. §6.1 and §13 say so now.

### Permissions to capabilities (§5.4), against a real `id`

The identity comes from one `id -u; id -g; id -G; id -un` exec channel through `RemoteScript`
at connect: `uid=2001(alec) gid=2001 groups=2001` on `deb`, `uid=2401(alec)` on
`deb-maxsess`. Where there is no shell - a `ForceCommand` account, or a `MaxSessions 1`
server with no channel to spare - the identity stays unknown and §5.4's SFTP-only rule
applies. The derived rows, read back out of the index:

| Path | mode | `capabilities` | `fs_flags` |
|---|---|---|---|
| `data/perm` (dir) | 0755 | 111 | 7 (exec, read, write) |
| `data/perm/script.sh` | 0755 | 111 | 7 |
| `data/perm/plain.txt` | 0644 | 111 | 6 (read, write; **no** exec) |
| `data/perm/rootowned.txt` | 0444 | 109 (no writing) | 2 (read only) |
| `data/perm/ro` (dir) | 0555 | 109 (no adding sub-items) | 3 (search, read) |
| `data/perm/ro/locked.txt` | **0666** | **65** (reading + evicting only) | 2 |

The last row is the paragraph §5.4 spends the most words on: a writable file in a read-only
directory is shown **locked**, because replacing content goes through a temp file in that
directory, and renaming and deleting follow the parent's write bit. It is derived, not
guessed - and it is the row, not the extension, that says so.

### Hidden names (§5.4)

`data/weird` seeded with `Makefile`/`makefile`, an NFC and an NFD `é.txt`, and a `.DS_Store`,
on top of the testbed's own ten weird names. Through the mount, ten entries; and:

```
"notShown": [
  { "path": "data/weird/latin1-caf\xff", "reason": "the name is not valid UTF-8, which macOS cannot represent" },
  { "path": "data/weird/makefile",  "reason": "the local filesystem cannot tell it from \"Makefile\"; rename one on the server" },
  { "path": "data/weird/é.txt",     "reason": "the local filesystem cannot tell it from \"é.txt\"; rename one on the server" }
]
```

`Makefile` wins on the byte-wise rule (`M` is 0x4D, `m` is 0x6D) and an incumbent keeps its
slot regardless of `readdir` order. The server-side `.DS_Store` is not listed at all and is
not in "not shown" either: §5.4 says it is never enumerated, so it gets no row, which is what
tells it apart from a hidden name. Sockets and FIFOs, `.`/`..`, and our own
`.sshdrive-upload-*` temp files are dropped the same way. A create or rename onto a hidden
name fails `.filenameCollision`.

### S3's deferred containment test, on a real server

Everything below was done over ssh as `alec@deb`, inside that account's own home.
`data/swap/` was created with an `inside.txt`, listed and read through the mount, then
replaced: `mv data/swap data/swap.real && ln -s /etc data/swap`.

**The §9.1 assumption that failed.** §9.1's "never descend through a link" was written as a
rule for recursive delete. It has to hold for enumeration too, because **SFTP `opendir`
follows a symlink**: with the swap in place, forcing the agent to list `data/swap` returned
`/etc` and put `passwd`, `shadow`, `skel`, `ld.so.cache` and eighty other names into the
index as rows under the mount root. Nothing outside the account's own tree was ever written
or deleted, and Finder never showed them - the replica had already cached the pre-swap
listing, and §6.5's "a folder is enumerated once, ever" meant nothing re-asked - but the
index is exactly where they must not be, and a pin or a sweep would have acted on them.

Fixed: every listing re-`lstat`s its own directory before `readdir` and refuses to descend
when the answer is no longer `directory`; the row is rewritten from that `lstat`, every row
beneath it is deleted, and the container answers `.noSuchItem`. §9.1 and §13 corrected.
With the check in place, and the swap still in place on the server:

| Question | Answer |
|---|---|
| Rows anywhere under `data/swap` | **0** |
| `ls -la <mount>/data` | `swap` appears as `lrwx------ … swap -> ` (a link, empty target: §5.7's target rewrite is milestone 4) |
| `ls <mount>/data/swap` | the link itself, no contents |
| `cat <mount>/data/swap/passwd` | `No such file or directory` |
| `rm <mount>/data/swap/hostname` | nothing to remove; `/etc/hostname` untouched |
| `/etc` on the server afterwards | intact, 82 entries |

Restored afterwards: `rm data/swap && mv data/swap.real data/swap`, and `inside.txt` reads
back.

**`RelativePath` escape attempts**, handed straight to `createItem` with no shell and no
string path in between (`sshdrive debug transport escape`):

| `createItem` filename | Result |
|---|---|
| `..` | refused: `A path component may not be ".."` |
| `../escaped.txt` | refused: `A path component may not contain "/"` |
| `/etc/escaped.txt` | refused: `A path component may not contain "/"` |
| `.` | refused: `A path component may not be "."` |
| upload to `../escaped.bin` | refused: `A path component may not be ".."` |

**An absolute symlink target in `createItem`** is the one case that is not refused yet:
`createItem(filename: "escape-link", symlinkTarget: "/etc")` creates the link on the server,
at a path the chokepoint validated. That is §5.7's lexical inside-the-root check, which is
milestone 4 and is still a `TODO` in `LocationRuntime.createItem`. §9.1 holds regardless: the
target string is never joined to a remote path, and through the mount `ls escape-link` and
`cat escape-link-passwd` both answer `No such file or directory`, with zero index rows under
either. Both links were removed afterwards.

### Two more things a large directory taught us

- **A directory listing must be one transaction.** `ls` of the testbed's 10,000-entry
  `data/many` through the mount answered `ls: fts_read: Operation timed out` - with paging on
  *and* with paging off, so it was never the paging. Row by row, the listing is 10,000
  autocommits, each its own WAL frame; wrapped in one `BEGIN IMMEDIATE` the same `ls` returns
  all 10,000 names in 70 s cold and instantly warm. §5.3 and §13 say so now.
- **Paging works and the system follows it.** 2,000 items a page; the extension logs
  `enumerateItems container=41AC454A… page=E113FC6D…` for the continuations and the agent
  logs `paging 10000 entries of data/many in 2000s`. A page token is an offset into a listing
  the agent already holds, so a second page never re-lists the directory.

### State the VM was left in

The signed build is installed at `/Applications/SSH Drive.app` and the agent is running, for
whoever picks milestone 3 up. **No File Provider domains and no locations in `config.json`**;
`sshdrive doctor` reports "file provider domains: none" and no `sshdrive-*` control sockets
are left. The testbed trees are back to what `testbed/README.md` documents: `data/{many,tree,weird}`
on `deb` with the original ten weird names, nothing extra in `~alec`, and `deb-maxsess`
clean. The keychain items the milestone 2 pass left in place are still there.

---

## 2026-09-04 (assembled stack) - S2: the transport end to end, three real mounts, and what is left for a real Mac

The three milestone 2 modules (`SFTP`, `SSHProcess`, `Secrets`) merged into one stack, wired
behind the agent's `SFTPTransport`, and driven from Finder's own mount path. Same headless VM
(macOS 26.4.1 arm64, `OpenSSH_10.2p1, LibreSSL 3.3.6`), the signed Debug build from
`scripts/mac-build.sh signed` (`MAC_DIR=~/sshdrive`), installed over `/Applications/SSH Drive.app`
with `ditto` and restarted with `open -g`. Testbed up on the Mac. The three per-agent build
directories on the VM (`~/sshdrive-sftp`, `~/sshdrive-ssh`, `~/sshdrive-secrets`) are gone.

**214 package tests, 0 failures**, both without the testbed (31 skipped) and with
`SSHDRIVE_TESTBED=1` (2 skipped; the two that need a real Mac).

### What the seams became

- **One `ByteStream`.** `SFTP` now depends on `SSHProcess` and uses its `ByteStream`;
  `SFTPByteStream`/`SFTPPipeByteStream` are gone. `PipeByteStream` kept its deadline-carrying
  `read(upTo:deadline:)` (the `bashbg` rule) and gained the bounded buffer the SFTP one had, so a
  1 GB transfer cannot outrun the parser into memory; the deadline-free spelling the wire client
  wants is a protocol extension, because deadlines there are per *request* (§6.2).
- **`SFTPClient` runs on a mux client in production.** `SSHMaster.openSFTPChannel()` ->
  `SFTPChannel.stream` -> `RealSFTPTransport.connect(stream:root:)`. `SFTPSubprocess` stays as the
  test path `SFTPIntegrationTests` uses. New `TestbedChannelTransportTests` covers the production
  route: list, write, read back, `lstat`, rename, delete over the master's socket, and a second
  channel opening on the same master after the first was killed.
- **One askpass environment,** in `XPCProtocols` (`AskpassEnvironment`), used by `Secrets`,
  `SSHProcess`, the agent and `sshdrive-askpass`. `SSHProcess` and `Secrets` meet on
  `AskpassTokenProviding`: `SSHMaster` mints a token per spawn, puts it in that child's
  environment, attaches its pid and retires it when the master goes. Mux clients get
  `removingAskpass(from:)`.
- **`askpassAnswer` is off `SSHDriveAgentProtocol`.** The askpass path is
  `SSHDriveAskpassProtocol` and nothing else.
- **`ProxyCommand` before `ProxyJump=none`, everywhere.** `debug secrets connect` no longer
  hand-rolls a hop: it calls `ProxyChainBuilder`, so it takes a whole comma-separated chain. And a
  `ProxyJump` written into a location's own `sshOptions` now reaches `ssh -G` (where the chain
  builder wants it) and is stripped from the master's command line, so "`ProxyJump` is never handed
  to `ssh`" is literally true.

### The debug hook the mounts were driven with

`sshdrive debug ssh add <name> <[user@]host[:port]> [--remote-path P] [--identity F] [--jump CHAIN]`
and `sshdrive debug ssh remove <name>`. Not `sshdrive add`: no `ssh -G` display, no two-pass
collect connection, no relayed prompts - those are milestone 3. It writes the location, connects
with whatever the keychain already holds, and is all-or-nothing (a location that cannot connect is
not left in `config.json`). `--identity` stores `IdentitiesOnly=yes` with it, as §4 says.

### Three mounts, each exercised through `~/Library/CloudStorage/SSHDrive-<name>`

| Mount | How | Result |
|---|---|---|
| `deb` | `debug ssh add deb alec@192.168.64.1:2201 --identity ~/.ssh/sshdrive-spike` | root canonicalised to `/home/alec`; `ls -la`, `ls -R data/weird`, `cat`, create, `mkdir`, `mv` into the new directory, `rm -r`. Every one reached the server. |
| `inner` | `debug ssh add inner spike-inner` (the alias's `ProxyJump spike-bastion-a,spike-bastion-b`), passwords put in place with `debug secrets store` | both hops answered from the keychain with **different** passwords, destination by key; `ls -R data`, write, `cat`, rename, delete, all confirmed on `inner` two hops away. |
| `enc` | `debug ssh add enc alec@192.168.64.1:2201 --identity ~/.ssh/sshdrive-spike-enc` | passphrase from `passphrase:/Users/alec/.ssh/sshdrive-spike-enc`, no tty anywhere; write, `cat`, rename, delete. |

All three came back after `sshdrive agent restart` without being re-added: `config.json` says
`mounted`, and `DomainManager.start()` spawns a master per location.

Two things worth knowing before repeating this:

- **A name the server no longer has stays in the mount.** Change detection is milestone 6, so a
  directory removed on the server by hand keeps its index row and keeps showing up. Nothing is
  wrong; there is simply nothing yet that notices.
- **`weird/` is served as it is.** `$(echo pwned)`, `quote'name`, `back\slash`, `*star*`,
  `[bracket]`, `space in name`, a name containing a newline and `utf8-café` all list and open
  through `ls -R` in the mount. The non-UTF-8 name is skipped, which is milestone 3's `hidden = 2`
  row rather than a real answer.

### The two-hop chain, as the master actually ran it

`ps` while `inner` was mounted, elided:

```
/usr/bin/ssh -N -o ControlMaster=yes -o ControlPath=$TMPDIR/sshdrive-90ea6950 -o ControlPersist=no
  … -o IdentityAgent=none
  -o ProxyCommand='/usr/bin/ssh' '-W' '%h:%p' '-o' 'ControlMaster=no' '-o' 'ControlPath=none' …
     '-o' 'ProxyCommand='\''/usr/bin/ssh'\'' '\''-W'\'' '\''%%h:%%p'\'' … '\''spike-bastion-a'\'''
     '-o' 'ProxyJump=none' 'spike-bastion-b'
  -o ProxyJump=none spike-inner
```

The three things §6.1 insists on are all visible: `ProxyCommand` written **before**
`ProxyJump=none` at both levels, `%h:%p` doubled to `%%h:%%p` for the hop one level down, and
`ControlPath=none` on every hop. A user's own multiplexing master for the same bastion
(`ssh -N -M -o ControlPath=~/.ssh/cm-hop@192.168.64.1-2210`, which the testbed's `~/.ssh/config`
sets up precisely so this can be falsified) was running throughout, and our hop did not attach to
it.

### S2 items this pass answered

- **The login shell snapshot, from the launchd-started agent: PASS.** `sshdrive doctor` now prints
  it. It reports `/bin/zsh` and the Homebrew `PATH` (`/opt/homebrew/bin` and the rest), which
  launchd's own `/usr/bin:/bin:/usr/sbin:/sbin` does not have - that is the `ProxyCommand` that
  calls a Homebrew tool, working.
- **A key reachable only through an `SSH_AUTH_SOCK` exported in `.zshrc`: PASS.** With
  `export SSH_AUTH_SOCK=/tmp/sshdrive-s2-agent` appended to a throwaway `~/.zshrc` and the agent
  restarted, `doctor` reported that socket in place of launchd's Apple `ssh-agent` listener
  (`/var/run/com.apple.launchd.*/Listeners`), and the agent pass below authenticated through it.
  `.zshrc` was restored afterwards.
- **The two-step collect connection, first pass, against a key `ssh-agent` already holds: PASS.**
  `~/.ssh/sshdrive-spike-enc` loaded into the agent; `debug secrets connect --purpose collect
  --identity ~/.ssh/sshdrive-spike-enc` (which runs `IdentityAgent=none`) raised the **passphrase**
  prompt rather than signing through the agent: `prompts 1`, `answeredFromKeychain 1`,
  `exitStatus 0`. Delete the keychain item and the same prompt is recorded as a miss keyed
  `passphrase:/Users/alec/.ssh/sshdrive-spike-enc` - which is exactly what `add` relays to the
  terminal and then stores - after which `ssh` falls through to `alec@192.168.64.1's password: `,
  recorded as a second miss keyed by the destination. That second miss is §4.2's "your key files
  did not authenticate and the server accepts passwords" branch, visible in the data.
- **The second pass, for an agent-only key: PASS.** A fresh ed25519 key added to `ssh-agent`, its
  public half appended to `deb`'s `authorized_keys`, and the **private file deleted**. First pass
  (`IdentityAgent=none`): `exitStatus 255`, one password prompt,
  `Permission denied (publickey,password)`. Second pass (`--with-key-agent`): `exitStatus 0` with
  **zero prompts**. That is the `agentDependent` recording, end to end.
- **`agent refused operation` could not be provoked here, and the reason matters.** OpenSSH's own
  `ssh-agent` locked with `ssh-add -x` does not refuse a signature: it reports *no identities*, and
  `ssh` exits with a plain `Permission denied (publickey,password)`. A socket whose agent has been
  killed, and a socket path that no longer exists, both produce the same line at `LogLevel=ERROR`.
  So §6.1's conclusion is stronger than it was written: stderr distinguishes **none** of the three
  key-agent states, not only the missing-socket one, and the pre-spawn `IdentityAgentCheck` probe
  is the only signal for a locked agent as well as an absent one. The `agent refused operation`
  string stays in the classifier because 1Password and Secretive are documented to produce it;
  neither is installable on this VM. §6.1 and §13 say so now.

### Throughput, as far as a container on the same Mac can say

The integration tests print rather than assert, and a `SSHDRIVE_TESTBED=1` run against
`spike-deb` (OpenSSH 9.2) says:

```
[spike-deb] limits: maxPacketLength 262144, maxReadLength 261120,
                    maxWriteLength 261120, maxOpenHandles 20475
[deb] pipelined write 64 MiB in 0.49 s = 129.6 MiB/s
[deb] pipelined read  64 MiB in 0.25 s = 252.1 MiB/s
[S2]  64 MiB: sshdrive 0.25 s (252.1 MiB/s); sftp(1) 0.68 s (94.6 MiB/s)
[deb] readdir data/many: 10000 entries in 0.10 s
```

Sixteen requests in flight at the server's own 255 KiB read size beats `sftp(1)` by about
2.7x here, which is what §6.2 meant by "`sftp(1)`-class throughput", and the 255 KiB inside
a 256 KiB packet that §6.2 quotes is confirmed on the wire. The 1 GB file
(`BIG_FILE: "1"` on the `deb` service) and the `rsync` comparison are still not run, and
none of this is a NAS over a network: a container on the same Mac is a floor.

### Still needs a real Mac

Unchanged from the S2 row of §11, and none of it is reachable from a headless VM: Tailscale SSH's
`none` auth (the testbed's `nopw` account is the same wire outcome, not the same implementation),
1Password or Secretive behind `IdentityAgent`, Apple's `UseKeychain`, a FIDO key's user-presence
notice and the 60 s authentication deadline firing against a touch, and the screen-unlock and
present-user re-arm after a deadline stop (§4.2, §5.6). The FIDO and PIN rows of §4.2's
classification table remain format strings plus unit tests.

### One trap this pass found

`ssh -O exit` over the control socket is how the agent sweeps orphans at start, and it works
(`Exit request sent.`, the master dies). But an orphan whose socket has **already** been unlinked
cannot be reached at all, and that is what a test leaves behind when it shuts its master down in a
detached `Task` inside a `defer`: the task can outlive the test process. Both testbed test files now
shut the master down in `tearDown`.

### State the VM was left in

No File Provider domains, no locations in `config.json`, `~/.zshrc` restored, the throwaway
`ssh-agent` and its key gone from the VM and from `deb`'s `authorized_keys`. Keychain items left in
place on purpose, for whoever picks this up: `password:pw@192.168.64.1:2201`,
`passphrase:/Users/alec/.ssh/sshdrive-spike-enc`, `password:hop@192.168.64.1:2210`,
`password:hop@bastion-b:22`, `password:alec@inner:22`. Delete them with
`sshdrive debug secrets delete --key <account>`.

---

## 2026-09-04 (night) - S2 askpass: the token protocol, the keychain, and the prompts `ssh` really sends

Same headless VM (macOS 26.4.1 arm64, `OpenSSH_10.2p1, LibreSSL 3.3.6`), the signed Debug
build from `MAC_DIR=~/sshdrive-secrets scripts/mac-build.sh signed`, installed over
`/Applications/SSH Drive.app` with `ditto` (never `rm -rf` plus a copy - that is the S1 f2
trap) and restarted with `open -g`. Testbed up on the Mac. Milestone 2 code: the real
`Secrets` keychain store, the askpass broker, `sshdrive-askpass`, and the agent's
askpass-only XPC interface.

### The prompt strings, captured rather than assumed

An `SSH_ASKPASS` script that logged `argv[1]` and `SSH_ASKPASS_PROMPT` and answered
nothing, run against the testbed from the VM. Verbatim, **trailing spaces included**:

| What | `argv[1]` | `SSH_ASKPASS_PROMPT` |
|---|---|---|
| password (`pw@…:2201`) | `pw@192.168.64.1's password: ` | **unset** |
| passphrase (`-i ~/.ssh/sshdrive-spike-enc`) | `Enter passphrase for key '/Users/alec/.ssh/sshdrive-spike-enc': ` | **unset** |
| keyboard-interactive (`kbd@…:2204`) | `(kbd@192.168.64.1) Password: ` | **unset** |
| host key, empty `known_hosts`, `StrictHostKeyChecking=ask` | `The authenticity of host '[192.168.64.1]:2201 ([192.168.64.1]:2201)' can't be established.\nED25519 key fingerprint is: SHA256:sZBoBnxDlU39oYKVYqzjq1RLWQPpnryr1+EXhXWDt3w\nThis key is not known by any other names.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ` | **unset** |

`strings /usr/bin/ssh` gives the format strings behind them, and the two we cannot raise
on this VM: `%s@%s's password: `, `Enter passphrase for key '%.100s': `,
`The authenticity of host '%.200s (%s)' can't be established`,
`Are you sure you want to continue connecting (yes/no/[fingerprint])? `,
`Are you sure you want to continue connecting (yes/no)? `,
`Warning: the %s host key for '%.200s' differs from the key for the IP address '%.128s'`,
`Confirm user presence for key %s %s`, `Enter PIN for %s key %s: `, `Enter PIN for '%s': `.

### The §4.2 assumption that failed

**The host-key question does not set `SSH_ASKPASS_PROMPT=confirm`.** §4.2's table and §4.3
both say it does. It arrives with the variable unset, exactly like a password prompt:
`ssh` sets the hint only for `RP_ASK_PERMISSION` ("confirm") and `notify_start` ("none"),
and the host-key question goes through `read_passphrase(prompt, RP_ECHO)`. Classifying on
the hint would have made the agent answer a **stored password** to "Are you sure you want
to continue connecting". The classifier now matches the question's own text first and
treats the hint as corroboration. §4.2, §4.3 and §13 corrected (2026-09-04). Nothing we
raised on this VM produced `confirm` at all; the branch is kept and still refused outside
`add`.

Two smaller ones:

- **`Enter passphrase for key '%.100s'` truncates.** A path over 100 bytes reaches askpass
  cut short, so the prompt text alone cannot be the keychain key. The broker maps the
  prefix onto the asking `ssh`'s own `identityfile` list from the same `ssh -G` resolution
  and keys on the full path (§4.2, §13).
- **A changed host key raises no prompt at all** under `StrictHostKeyChecking=ask`: `ssh`
  prints the REMOTE HOST IDENTIFICATION HAS CHANGED banner and exits, which is the stderr
  path §4.3 already describes. Only an *unknown* host asks.

### An OpenSSH ordering trap, for §6.1

**`-o ProxyJump=none` before `-o ProxyCommand=…` silently discards the ProxyCommand.**
readconf takes the first setting of each keyword and `ProxyJump none` marks the jump host
as set, after which `ProxyCommand` is skipped: the master then tries to resolve the inner
hostname itself and dies with `Could not resolve hostname inner`. With `ProxyCommand`
given **first** and `ProxyJump=none` after, `ssh -G` shows the proxycommand and the chain
works, and a `ProxyJump` in the user's config is still cancelled. §6.1 says to do both but
not in which order; the order is load-bearing.

### What was proved end to end, from the launchd-started agent

Hooks used: `sshdrive debug secrets store|lookup|delete|list|classify|connect`
(documented in `docs/skeleton-notes.md`). Every `connect` spawns a real `/usr/bin/ssh`
from the agent's own environment with `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE=force` and
`SSHDRIVE_ASKPASS_TOKEN` set, and no tty anywhere.

- **The real keychain from the agent: PASS.** `store` / `lookup` / `delete` / `list`
  against the data-protection keychain, `kSecAttrAccessGroup =
  RWGDZAYBM8.org.shirls.sshdrive`, `kSecUseDataProtectionKeychain = true`,
  `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock`. `list` reports
  `password stored for pw@192.168.64.1` / `passphrase stored for ~/.ssh/sshdrive-spike-enc`,
  which is §4.2's `list`/`show` wording.
- **Password auth through askpass: PASS.**
  `debug secrets connect --destination pw@192.168.64.1 --port 2201` -> `exitStatus 0`,
  `stdout "AUTH-OK-PASSWORD"`, `prompts 1`, `misses []`. The password came from
  `password:pw@192.168.64.1:2201`.
- **Encrypted key through askpass: PASS.** Same hook with
  `--identity ~/.ssh/sshdrive-spike-enc` against `alec@192.168.64.1:2201` ->
  `exitStatus 0`, `stdout "AUTH-OK-PASSPHRASE"`, `prompts 1`, `misses []`, passphrase from
  `passphrase:/Users/alec/.ssh/sshdrive-spike-enc`.
- **A `ProxyJump` hop is keyed by its own host: PASS.** Master to `alec@inner` through the
  agent-built `ProxyCommand` to `hop@192.168.64.1:2210`. Two prompts, **both** answered
  from the keychain with *different* passwords (`password:hop@192.168.64.1:2210` =
  `spike-password-a`, `password:alec@inner:22` = `spike-password`), `exitStatus 0`,
  `stdout "AUTH-OK-CHAIN"`. This is the whole §4.2 hop story working: the hop inherited
  the master's token, and the agent told it apart by the argv the askpass read with
  `sysctl KERN_PROCARGS2` and resolved with `ssh -G`.
- **The host-key question is refused outside `add`: PASS.** A temporary `~/.ssh/config`
  stanza pointing `UserKnownHostsFile` at an empty file (removed again in the same run)
  plus `--host-key-checking ask`: the agent recorded the miss, replied a refusal,
  `ssh` exited 255 with `Host key verification failed.`, and the empty `known_hosts`
  stayed empty (0 bytes). Nothing was written to the user's real `known_hosts`.
- **The token is what authorises: PASS.** `sshdrive-askpass` run by hand with no
  `SSHDRIVE_ASKPASS_TOKEN` exits 1 without contacting the agent; run with a made-up token
  it reaches the agent and gets
  `Error Domain=org.shirls.sshdrive.AgentError Code=2 "unknown token"` and exits 1. The
  second case also proves the listener hands an askpass peer the one-method askpass
  interface (`AskpassService.register`, matched on the peer's `proc_pidpath`).
- **An empty answer skips an identity: PASS** (measured with the logging askpass, not the
  agent). `ssh` offered the encrypted key first, got an empty passphrase, logged
  `no passphrase given, try next key`, moved to `~/.ssh/sshdrive-spike` and authenticated.
  That is §4.2's "the agent answers with an empty passphrase ... and nothing is stopped".

Not covered on this VM: the FIDO user-presence notice and the PIN prompt (no security key
attached), so those two rows of the table are the format strings plus unit tests. The
collect flow's relay to the terminal has unit coverage and no CLI yet - `sshdrive add`
arrives in milestone 3.

Left behind on the VM on purpose, for whoever picks S2 up: keychain items
`password:pw@192.168.64.1:2201`, `passphrase:/Users/alec/.ssh/sshdrive-spike-enc`,
`password:hop@192.168.64.1:2210` and `password:alec@inner:22`. Delete them with
`sshdrive debug secrets delete --key <account>`.

---

## 2026-09-04 (late) - what Finder actually draws: s6-7, s6-8, s6-10, and S1 c2

The owner granted **Screen Recording** and then **Accessibility** to
`/usr/libexec/sshd-keygen-wrapper`, which turns the three drawing questions into ordinary
work: `screencapture -x` produces a 2646x1558 PNG (a 2x Retina capture of a 1323x779-point
display) and `System Events` UI scripting reads and drives Finder's windows. Same VM, same
signed Debug build, two domains `nas` and `nas2`.

### How the captures were taken, for the next person

Two things that do **not** work and cost time:

- `perform action "AXShowMenu"` on a Finder list row: the row exposes only
  `AXShowDefaultUI` / `AXShowAlternateUI`, so this silently does nothing.
- `tell application "System Events" to key down control` + `click at {x, y}`: the synthetic
  click does not carry the modifier and Finder opens nothing.

What works is a real right-click posted with CoreGraphics. A six-line Swift program
(`CGEvent(mouseEventSource:mouseType:.rightMouseDown/.rightMouseUp …).post(tap:
.cghidEventTap)`) at the row's AX `position`, with `Accessibility` granted, opens the
contextual menu; `screencapture -x` then captures it and `key code 53` dismisses it. The
row is located by asking Finder to `select` the file and then taking `first row … whose
selected is true`; matching rows by name does not work, because a Finder list row's static
texts read `missing value`. AX coordinates are points and `CGEvent` takes points, so no
scaling is needed, but the resulting PNG is 2x.

The contextual menu itself is **not readable through AX** (`menu 1 of window 1` of the
Finder process does not exist while it is open), so the entries below are read off the
screenshots.

### s6-7. The built-in entries, pinned versus unpinned - **and "Remove Download" is shown on a kept item**

Three captures in one folder of the mount, all in list view.

**Unpinned, downloaded** (`report-001.txt`):

```
Open
Open With                    >
Remove Download
------
Move to Bin
------
Get Info / Rename / Compress "report-001.txt" / Duplicate / Make Alias / Quick Look
------
Copy / Share...
------
(tag colours) / Tags...
------
Quick Actions                >
[ ] Keep Downloaded
```

**Pinned, downloaded** (`report-000.txt`, `debug policy … eager-keep`): byte-for-byte the
same list, with two differences - the last entry reads `[ ] Don't Keep Downloaded`, and
**`Remove Download` is still there.**

**Unpinned, dataless** (`report-003.txt` after `debug evict`): `Download Now` replaces
`Remove Download`, the row carries the system's cloud-with-arrow badge, and the last entry
is `[ ] Keep Downloaded` again.

So the built-in File Provider entries on 26.4 are exactly two, both in the third slot of
the menu: **`Download Now`** when the item is dataless and **`Remove Download`** when it is
materialized. Which one appears follows `isDownloaded` and nothing else. This is the
picture that goes with the capability measurement earlier today: an item served without
`allowsEvicting` still gets `Remove Download`. §2 and §7.2 are corrected accordingly, and
the `NSExtensionFileProviderAllowsUserControlledEviction` question is now a real decision
for milestone 8 rather than a maybe.

Two incidentals:

- **`Move to Bin` is offered even though `allowsTrashing` is never set.** The contextual
  menu has no `Delete Immediately…`; that entry is in the **File** menu, which for a file in
  the mount reads `… Move to Bin / Delete Immediately… / Eject`. So the deletion path a user
  takes from the contextual menu is `Move to Bin`, and §5.4's alert is what turns it into an
  immediate delete.
- **No decoration.** The kept file's row carries no badge of ours, because we declare no
  `NSFileProviderDecorations`; §7.2's pin badge is still unwritten. The only badge in the
  mount is the system's own dataless cloud.

### s6-8. Top level or submenu? - **top level, last, and only one of the pair**

Our custom actions are drawn **at the very bottom of the contextual menu, below `Quick
Actions`, at the top level** - not inside `Quick Actions`, not inside a submenu named after
the app. Each is drawn with a leading empty checkbox-style glyph, which is how Finder
renders `NSExtensionFileProviderActions` entries. Exactly one of the pair appears, which is
the activation rules working: `Keep Downloaded` on an unkept item, `Don't Keep Downloaded`
on a kept one.

That also settles the worry from this morning's entry. Finder 26.4 does carry strings for a
built-in `Keep Downloaded` (N153.7/N153.8) and a `Kept Downloaded` badge, but it does not
draw them for us: an unpinned item shows exactly **one** `Keep Downloaded`, and the pinned
one shows `Don't Keep Downloaded`, a label that exists only in our Info.plist. So there is
no duplicate-label problem and §7.2 keeps its wording.

### s6-10. Window background and sidebar - **background yes, sidebar no**

**Right-click on the empty area of the window** (no selection):

```
New Folder
------
Get Info
------
View                         >
Use Groups
Sort By                      >
Show View Options
------
[ ] Keep Downloaded
```

So the action is offered on the background too, at the top level, and the item it is
evaluated against is the **folder being shown** - here `Documents/Reports`, unpinned, hence
the pin entry. Nothing about the root container is special; the same is true with the mount
itself open.

**Right-click on the sidebar row** (`SSH Drive - nas`):

```
Open in New Tab
Show "SSH Drive"
Download Now
------
Remove from Sidebar
Get Info
Add to Dock
```

**Our entries are absent from the sidebar menu.** The built-in `Download Now` is there
(the domain root is not materialized), and `Show "SSH Drive"` names the *provider*, not the
domain. So `sshdrive pin <name>` on a whole location has no Finder route; the CLI is it.
§7.2 says so now.

### s3-2 confirmed visually

The sidebar with both domains present reads, under **Locations**:

```
iCloud Drive
SSH Drive - nas2
SSH Drive - nas
chosen-newt
Macintosh HD
AirDrop
Bin
```

which is exactly the `<app display name> - <displayName>` composition measured this
morning, with `displayName` the bare nickname.

### S1 c2. Cancelling a download from Finder's progress UI - **there is no cancel control**

With `debug fault nas --fetch-delay 40000` holding one `fetchContents` open, a `cat` of a
dataless file makes Finder draw a **pie-style progress ring** in the list row (AX: the row
gains a `progress indicator` next to its `image` and `text field`). Hovering the pointer
over it for 1.5 s does not turn it into a stop button, and a left click on its centre does
nothing: `debug transfers` still reports `inFlight 1`, the file stays dataless until the
fault's 40 s elapse, and the agent logs no cancellation. The contextual menu on a
downloading item offers no `Stop`/`Cancel` either.

So on 26.4 there is **no per-item cancel affordance in Finder's list view** for a
third-party provider, and c2's real question - does our `Progress` cancel cleanly - cannot
be asked from there. It stays open, and the honest place to test it is
`NSProgress.cancel()` from a unit or integration test in milestone 3, not Finder.

### State the VM was left in

Fault flags all off, `nas2` removed, `nas` re-created with its 8 files, no pin markers, no
Finder windows open, the helper binaries under `/tmp` deleted. `sshtest` untouched.

---

## 2026-09-04 (evening) - the Finder questions of S3 and S6, from a console session

Same VM (macOS **26.4.1** arm64, 25E253, Xcode 26.4), the signed Debug build from
`scripts/mac-build.sh signed` at `/Applications/SSH Drive.app`, fake-backed domains added
with `sshdrive debug fake add`. This pass differs from the earlier ones in that `alec` is
logged in at the console (`CGSessionCopyCurrentDictionary` reports
`kCGSSessionOnConsoleKey = 1`, no `ScreenIsLocked`), so **Apple Events reach Finder,
TextEdit and Xcode from the ssh session** and the runbook's GUI questions can be driven by
`osascript`.

### What the three routes could and could not do

| Route | Verdict |
|---|---|
| `fileproviderctl evaluate <item>` | **Works, and is the best tool here.** It prints the system's own copy of the item, the evaluated activation rules, the decorations, the capability letters and the content policy. `evaluate <action> <item> <target>` evaluates `NSFileProviderUserInteractions` only, of which we declare none, so it prints an empty interaction set; its error message is a useful catalogue of the valid actions: `Create, Move, MoveOut, MoveIn, Copy, CopyIn, CopyOut, Trash, Delete, Rename, ExcludeFromSync`. |
| `osascript` driving Finder / TextEdit | **Works, no TCC dialog needed.** `kTCCServiceAppleEvents` is already allowed for `/usr/libexec/sshd-keygen-wrapper` in the user TCC database, so Finder and TextEdit scripting ran without prompting anybody. |
| `screencapture -x` | **Blocked, and cannot be unblocked from a terminal.** Every attempt returns `could not create image from display`, and `tccd` logs `Service kTCCServiceScreenCapture does not allow prompting; returning denied` with `responsible=/usr/libexec/sshd-keygen-wrapper`. Routing it through Finder (`tell application "Finder" to do shell script "screencapture …"`) does not change the attribution. Screen Recording is a system-database service, so the owner has to add it by hand in System Settings > Privacy & Security > Screen Recording; it will never prompt. |

Accessibility is denied the same way (`tell application "System Events" to return UI
elements enabled` is `false`), so **no context menu could be opened or read**. Everything
below that talks about a menu is either the system's own evaluation of what applies or
Finder's own localized strings, never a picture of a menu.

### New `sshdrive debug` hooks and one Info.plist fix this pass added

- `debug fault <name> --version-mismatch on|off` - `modifyItem` replies with content and
  metadata versions that are not the ones just written (s3-7). The index keeps the true
  versions; only the reply lies.
- `debug fault <name> --collisions on|off` - every `createItem` fails
  `.filenameCollision`, which is the error §5.5's `lstat`-after-`FAILURE` check will raise
  for real in milestone 4 (s3-4).
- The container enumerator now logs `enumerateItems` and `enumerateChanges` with the
  container identifier, which is the only way to answer s3-3.
- `Apps/FileProvider/Info.plist`: **both action activation rules were dead.** See s6-8.

`swift test` is 33/33.

---

### s3-2. Sidebar label and mount path, `nas` versus `SSH Drive - nas` - **never prefix; the system adds the app name itself**

Three domains at once, `displayName` exactly as given:

```
displayName "nas"                -> ~/Library/CloudStorage/SSHDrive-nas
displayName "nas2"               -> ~/Library/CloudStorage/SSHDrive-nas2
displayName "SSH Drive - nas2"   -> ~/Library/CloudStorage/SSHDrive-SSHDrive-nas2
```

and what Finder itself shows for each (`tell application "Finder" to get displayed name
of …`, which is the sidebar and window-title string):

```
SSHDrive-nas             -> "SSH Drive - nas"
SSHDrive-nas2            -> "SSH Drive - nas2"
SSHDrive-SSHDrive-nas2   -> "SSH Drive - SSH Drive - nas2"
```

So the directory name is `<app name with spaces removed>-<displayName with spaces
removed>` and the label Finder draws is `<app display name> - <displayName>`. The app name
is contributed by the system in both, and a `displayName` of `SSH Drive - nas2` gives
exactly the stutter §2 was worried about. **`displayName` is the bare nickname**, which
settles §2 and §4. (`mdls` disagrees with Finder and reports the raw directory name;
Finder's `displayed name` is the one users see.)

### s3-3. Does the system call `enumerateChanges` on a folder's enumerator when Finder shows it? - **No; it does not even make a container enumerator again**

With the enumerators logging, a Finder window opened on `Documents/Reports` produced
exactly two calls, both `enumerateItems`, one per folder on the way down:

```
enumerateItems container=ECC9E10F-…   (Documents)
enumerateItems container=DF39F98B-…   (Documents/Reports)
```

Navigating away and back, closing the window and reopening it on the same folder, and
creating a file in that folder on the server while the window was open produced **no
further container-enumerator calls at all** - not `enumerateChanges`, not a second
`enumerateItems`. The new file still appeared in the open window within ~20 s, through the
working set. So a folder is listed once, ever, and after that Finder is fed from the
replica.

This settles §6.5: neither of the two fallbacks it hoped for exists. The system gives us
no "this folder is being looked at" signal, so the `viewed` reason can only be armed from
our own `enumerateItems` - which fires once, on first show - and everything after that has
to come from the working set.

### s3-4. What Finder does with `.filenameCollision` - **it never asks the user; the system retries the create for ever**

Two different things happen and they should not be confused.

**A real collision inside Finder never reaches us.** `duplicate` of `run.sh` creates
`run copy.sh`; Finder resolves the name itself before calling the provider.

**A case collision arriving from the server is resolved by the system, silently, on the
replica only.** With `README-renamed.txt` already there, `debug mutate nas create-file
README-RENAMED.TXT` gave:

```
server + index:  README-RENAMED.TXT   README-renamed.txt
the mount:       README-RENAMED.TXT   README-renamed 2.txt
```

The system renamed the *older* item to `README-renamed 2.txt` in its replica and did
**not** report that rename back to us - no `modifyItem`, and the server name is untouched.
So on 26.4 a case collision does not break anything, but the user sees a name the server
does not have, which is the argument for §5.4's `hidden = 2` rather than against it.

**Returning `.filenameCollision` from `createItem` is a retry loop, not a dialog.** With
`debug fault nas --collisions on`, a `printf > collide.txt` from the shell, a Finder "new
folder" and a Finder `duplicate` all reported success to their caller, left the item in
the mount, and made fileproviderd retry the create with a doubling backoff (0 s, 0.04 s,
5 s, 15 s, …) for as long as the fault was set:

```
fileproviderd: ‼️ done executing <J1 ‼️ create-item(… n:"c{5}e.txt" …)
               error:<NSError: FP -1001 "The file already exists in this location.">
```

No alert, no badge, and `enumeratorForPendingItems` stayed **empty** (unlike the
`.serverUnreachable` fault of s4-3, which does populate it). Turning the fault off made
all three creates land on the next retry. So `.filenameCollision` must only ever be
answered when the name will *stop* being taken - §5.5's conflict-copy path, which renames
our own file out of the way - and never as a standing refusal, or it is the `.Trash` loop
again.

### s3-5. `chmod +x` inside the mount - **arrives as `.fileSystemFlags`, and we currently drop it**

```
chmod +x <mount>/Documents/Reports/report-001.txt      # a 644 file
-> modifyItem Documents/Reports/report-001.txt changedFields=0x100   (1 << 8 = .fileSystemFlags)
```

Exactly what §5.4 expects. Two notes:

- `chmod +x` on a file that is **already** mode 755 produces no `modifyItem` at all: the
  only bit the replica carries is the owner-execute one, and it was already set. The
  group and other bits changed locally and went nowhere.
- The skeleton's `modifyItem` ignores `.fileSystemFlags`, so the mode did not reach the
  fake server and the system put the local mode straight back (`ls -l` reads `-rw-------`
  again seconds later). That is milestone 4's work; the spike only had to prove the field
  arrives, and it does.

### s3-6. The delete confirmation without `allowsTrashing` - **Finder deletes, and its wording is fixed**

AppleScript `delete` of an item in the mount schedules an `FPDeleteOperation`, not a trash
operation, completes in milliseconds and removes the file from the replica *and* the fake
server:

```
Finder: Scheduling FPOperation: <FPDeleteOperation: …>
Finder: FPOperation completed:  <FPDeleteOperation: …>
```

No dialog is drawn on the AppleScript path. The dialog a person gets is Finder's own, and
its exact wording is in `Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings`:

```
MT16_V1  Are you sure you want to delete “^1”?
MT16_V2  Are you sure you want to delete the ^0 selected items?
MT18_V1  This item will be deleted immediately. You can’t undo this action.
MT18_V2  ^0 items will be deleted immediately. You can’t undo this action.
AL7      Delete
```

So §5.4's "will be deleted immediately, are you sure?" is right in substance and can now
be quoted exactly. `NSFileProviderItem.h` also documents a switch we did not know about:
`NSExtensionFileProviderAllowsSystemDeleteAlerts = 0` in the appex Info.plist suppresses
the system's own delete warnings for a provider that wants to draw its own. We want the
system's, so we leave it alone.

### s3-7. `modifyItem` returning a version that differs from the upload - **the system believes us; it neither re-fetches nor re-offers**

With `debug fault nas --version-mismatch on`, one append to a materialized file gave
exactly one `modifyItem` (`changedFields=0x81`, contents + contentModificationDate), the
agent replied with `127-1788457968-0-fault` instead of `127-1788457968-0`, and then:

```
debug stat        blocks 8   dataless false   size 127
evaluate          isDownloaded 1   isMostRecentVersionDownloaded 1   hasUnresolvedConflicts 0
                  versionIdentifier = "127-1788457968-0-fault"
debug transfers   total 0        # no fetchContents, then or later
```

No second `modifyItem`, no re-fetch when the file was read again, no conflict flag. The
system simply records whatever version the reply carries.

**This contradicts §5.5.** Its conflict policy rests on "the system re-fetches that content
and does not re-offer the local edit"; only the second half is true. Returning the remote
item from a conflicting `modifyItem` leaves the replica holding the *local* bytes under
the *remote* version, and nothing will ever correct it. The fix is small and is now in
§5.5: after returning the remote item, the agent calls
`NSFileProviderManager.evictItem` on that identifier, which s4-1 proved works, so the next
open downloads the remote content. The same finding makes the post-upload `lstat` of §5.5
load-bearing for a second reason: a version we invent is a version the next sweep will not
recognise.

### s3-8. Atomic saves - **TextEdit and a shell temp+rename are both one `modifyItem` on the original identifier**

TextEdit, driven by AppleScript (`open`, `set text of document 1`, `save`, `close`):

```
modifyItem Documents/Reports/report-003.txt changedFields=0x8     (lastUsedDate, on open)
modifyItem Documents/Reports                changedFields=0x80    (the parent's mtime)
modifyItem Documents/Reports/report-003.txt changedFields=0x289   xattrKeys=com.apple.TextEncoding
```

`0x289` = contents | lastUsedDate | contentModificationDate | extendedAttributes. The item
identifier before and after is the same `7768EB02-…`. **No `createItem`, no `deleteItem`.**

The classic shell form of the same dance - write a temp file beside the target and `mv`
over it - behaves identically:

```
printf … > Documents/Reports/.tmp-005 ; mv .tmp-005 report-005.txt
-> modifyItem Documents/Reports            changedFields=0x80
   modifyItem …/report-005.txt             changedFields=0xc1
   identifier 5284601D-… unchanged, content is the new content
```

So the no-tombstones risk of §5.3 does not bite for these two. **Xcode: not exercised.**
Xcode 26.4 is installed and scriptable enough to open the file and set its text, but its
`source document` does not implement `save` (`-1708`), and there is no way to send it a
Cmd-S without Accessibility. **Pages, Numbers, Keynote and Microsoft Office are not
installed on this VM**, so their saves remain untested.

### s6-7. Which built-in menu entries Finder shows, and whether dropping `allowsEvicting` removes "Remove Download" - **partly answered, and the answer is that dropping it does nothing**

What can be measured without a screen is what the system thinks the item's capabilities
are, which is what Finder draws from. `fileproviderctl evaluate` prints them twice, as a
number and as a letter string whose sixth slot is `allowsEvicting`:

| item | row served by us | system's capabilities | letters |
|---|---|---|---|
| unpinned file, dataless | 111 (`e` set) | 0x2000002F | `rwdpf-t-----` |
| unpinned file, downloaded | 111 (`e` set) | 0x2000006F | `rwdpfet-----` |
| **pinned file, downloaded** | **47 (`e` cleared)** | **0x2000006F** | **`rwdpfet-----`** |
| pinned folder, downloaded | 47 (`e` cleared) | 0x2400006F | `rwdpfet-----` |
| root container, pinned | 47 (`e` cleared) | 0x2400006F | `rwdpfet-----` |

The pinned rows were read back four times over forty seconds and never changed, and the
same snapshot's `userInfo.kept` was `1`, so the system had certainly re-read the item.
**The system puts `allowsEvicting` back.** What it does track is `isDownloaded`: a dataless
item loses the bit, a materialized one has it, whatever we serve.

So §2's "an item whose `capabilities` omit `allowsEvicting` is not offered Remove Download
at all" and §7.2's second belt are both wrong on 26.4. The header agrees that the
capability is the wrong lever - it is `API_DEPRECATED("use NSFileProviderContentPolicy
instead", macos(11.0, 13.0))` - and names the one that works, per provider rather than per
item: `NSExtensionFileProviderAllowsUserControlledEviction = false` in the appex's
`NSExtension` dictionary, which "suppress[es] the user's ability to evict the item in the
UI but retain[s] the ability of the OS or the provider's program to evict items". The
neighbouring key `NSExtensionFileProviderAllowsContextualMenuDownloadEntry = 0` removes
Finder's "Download Now" the same way. Neither is set today.

The guarantee itself is unaffected: s6-5 already showed the eager `contentPolicy` is what
refuses an eviction, and it still does.

**Still needs a screen:** the actual list of entries Finder draws. Two things found in
`LocalizableMerged.strings` make that worth doing rather than assuming, because Finder
26.4 has a *built-in* keep-downloaded feature we did not know about:

```
N153.3    Download Now
N153.4_V1 Remove Download        N153.4_V2 Remove Downloads
N153.7_V1 Keep Downloaded        N153.8_V1 Keep Downloaded
NE88.2.1  Downloaded   NE88.3.1 Not Downloaded   NE88.3.2 Kept Downloaded
AXBADGE12 Kept downloaded
```

Our own action is also called "Keep Downloaded" (§7.2), so if Finder draws its own for a
third-party provider the menu has two entries with one label. Note that our items report
`isKeepDownloaded = 0` even when their effective content policy is
`downloadEagerlyAndKeepDownloaded` (3), so that flag is the system's own and is not driven
by our policy - which is a hint, not a proof, that the built-in entry is not offered to us.

### s6-8. Do our custom actions appear at the top level or in a submenu? - **not answerable without a screen, but both rules were dead and are now fixed**

The precondition turned out to be broken. `fileproviderctl evaluate` on any item printed:

```
org.shirls.sshdrive.action.pin: SUBQUERY(fileProviderItems, $item, $item.userInfo.kept == 0).@count
  == $fileProviderItems.@count - Can't get value for 'fileProviderItems' in bindings {}.
```

Two mistakes in one string:

1. **The bound key is `fileproviderItems`, lower-case p.** The object `fileproviderctl`
   evaluates against is a dictionary whose only key is spelled that way, and
   `fileProviderItems` with a capital P **does not occur anywhere in the dyld shared
   cache** - `strings` over `dyld_shared_cache_arm64e.*` finds exactly one standalone
   occurrence of the key and it is the lower-case one. Apple's own documentation uses the
   capital spelling.
2. **It is a key path, not a substitution variable.** `$fileProviderItems` raises
   `NSInvalidArgumentException` out of `-[NSVariableExpression expressionValueWithObject:]`
   because the bindings dictionary is empty, and the whole rule is dropped.

Either mistake alone silently removes the entry, with nothing in any log. Rewritten to
§7.2's "at least one" form with the right key, they evaluate:

```
unpinned item     pin YES   unpin NO
pinned item       pin NO    unpin YES
```

Recorded while we were there, because it decides between §7.2's form and the "all selected
items" one: `SUBQUERY(k, …).@count == k.@count` is `0 == nil-count`, i.e. **true**, when the
key is absent or the selection is empty, so the "all" form would light up both entries on
an empty selection. §7.2's `.@count > 0` form is false there, which is another reason to
keep it.

Where Finder puts the two entries once they are live still needs a screen.

### s6-10. Do the actions appear on the window background and the sidebar entry? - **the root container matches the rule; where Finder draws it still needs a screen**

`fileproviderctl evaluate <mount directory>` is exactly the "root as the selected item"
case, and it behaves like any other item:

```
root unpinned:  kept = 0   pin YES   unpin NO
root pinned:    kept = 1   pin NO    unpin YES   Content Policy 3
```

So nothing about the root container excludes it from the activation rules, and §7.1.2's
"the root is not a special case" holds here too. Whether Finder offers a provider's custom
actions on a window background with no selection, or on the sidebar row, is a drawing
question no terminal can answer. One thing the evaluator does say about the empty case:
with §7.2's `> 0` rules, an empty `fileproviderItems` matches neither entry.

### Also recorded

- **Decorations are empty** for every item, as expected: we declare no
  `NSFileProviderDecorations`. §7.2's pin badge is still unwritten.
- **A Finder rename** is one `modifyItem` with `changedFields=0x2` (`.filename`), which
  finishes s3-1's rename half.
- `fileproviderctl evaluate <action>` evaluates `NSFileProviderUserInteractions`, a
  different Info.plist key from `NSExtensionFileProviderActions`, and one worth knowing
  about: it is how a provider puts its own confirmation alert (title, subtitle, buttons,
  help URL, suppression) in front of a Move, Trash, Delete, Rename or Create. Nothing in
  milestone 1 needs it; §5.5's conflict copy and §5.4's delete might in milestone 4.
- **S1 c2 (cancelling a large download from Finder's progress UI)** was not attempted: it
  needs a pointer on the progress popover, so it stays a screen question.

### State the VM was left in

The signed Debug build at `/Applications/SSH Drive.app` (rebuilt and reinstalled twice
during this pass), agent running from launchd, `sshdrive doctor` green apart from the two
expected warnings, **one** fake location `nas` mounted at `~/Library/CloudStorage/SSHDrive-nas`,
no pin markers, all four faults off (`debug fault nas` reports `writesFail false`,
`createsCollide false`, `versionMismatch false`, `fetchDelayMilliseconds 0`). The `nas2`
and `SSH Drive - nas2` domains from s3-2 were removed. No Finder windows left open.
`sshtest`'s state was not touched.

### What to do next on the VM

1. The three drawing questions, in front of a screen: s6-7's actual entry list, s6-8's
   top-level-versus-submenu, s6-10's window background and sidebar, and S1 c2. All four
   need either Screen Recording added for `/usr/libexec/sshd-keygen-wrapper` in System
   Settings (it will never prompt) or somebody looking at the screen.
2. Decide, before milestone 8, whether to set
   `NSExtensionFileProviderAllowsUserControlledEviction = false`; s6-7 says the capability
   alone does nothing.
3. Still open from the entries below: re-run s4-2 and s4-5 on macOS 14 or 15, the
   `useReader` hook for s3-14, and a Developer ID plus `notarytool` pass for S1(d4).

---

## 2026-09-04 - S4 and S6 on the headless Mac VM (eviction, atime, pinning)

Every headless-feasible sub-question of S4 and S6, in runbook order. Same VM (macOS
**26.4.1** arm64, 25E253, Xcode 26.4, no GUI), the signed Debug build from
`scripts/mac-build.sh signed` installed at `/Applications/SSH Drive.app`, the appex
carrying `com.apple.developer.fileprovider.testing-mode`, one fake-backed domain `nas`.
Note the OS: the design asks about 14 and 15 in two places and this is 26.4, so every
answer below is "on 26.4" until someone runs it on 14.

The three Finder-menu questions - **s6-7, s6-8, s6-10** - are **needs-Finder** and were
not attempted: they are about what Finder draws, and no terminal can see that.

### New `sshdrive debug` hooks this pass added

`evict`, `materialized [--pending]`, `stat [--read]`, `xattr`, `fault [--writes]
[--fetch-delay]`, `transfers [--reset]`, `stabilize`, `testing`, `signal --container`,
and `fake add --testing-modes`. `debug policy` now creates the missing ancestor rows
first. All of them are documented in `docs/skeleton-notes.md`; `swift test` is 33/33.

Two behaviours of the harness worth knowing before the next pass:

- **`scripts/mac-build.sh` syncs with `rsync -a --delete`,** so any mode wipes `build/`
  on the Mac. Running `test` after `signed` deletes the app you were about to install.
  Build with `signed` last.
- **`waitForStabilization` is not a barrier for downloads.** It returns in well under a
  second and only says the two sides have exchanged what they know. The
  `com.apple.fileproviderd.background-download` scheduler is separate and, on an idle
  headless Mac, takes anything from 8 s to 90 s to start an eager fetch. Every timing
  below is "after stabilization plus that wait".

---

### s4-1. Does `evictItem` work for files in our domain? - **Yes, and for directories and the root too**

```
$ sshdrive debug evict nas README.txt
{ "evicted" : true, "allowsEvictingServed" : true, "kept" : false, ... }
$ sshdrive debug stat nas README.txt
  "blocks" : 0,   "dataless" : true,   "size" : 37
```

The file went dataless and kept its size, its xattrs and its atime.

**The design's folder rule is wrong on this OS.** `evictItem` on
`Documents/Reports` returned `evicted: true` and left every file under it dataless, and
`evictItem` on `.rootContainer` emptied the whole location: the materialized set went
from 11 items to **0**, directories included. `NSFileProviderManager.h` documents exactly
that ("When called on a directory, first each of the directory's children will be
evicted ... Then the directory itself will be made dataless"), with
`NSFileProviderErrorNonEvictableChildren` reserved for the case where a child refuses.
So §7 step 2's "skip directories; folder eviction is known to fail" and CLAUDE.md's
"Folder eviction fails; evict files only" are both out of date, and `sshdrive evict
--all` is one call on the root rather than a walk.

One incidental: **an eviction moves atime**, so the loop must read atime before it
evicts, not after. It already does.

### s4-2. Does atime advance on every read, only when older than mtime, or never? - **Only when older than mtime**

The relatime rule, and it is the whole macOS/APFS rule rather than anything File
Provider does. On a materialized file whose atime is already newer than its mtime, ten
`cat`s over forty seconds moved nothing:

```
materialized:      atime=1788454141 mtime=1788453962  wall=1788454140
idle 20s:          atime=1788454141 mtime=1788453962  wall=1788454160
after 5 reads:     atime=1788454141 mtime=1788453962  wall=1788454160
after 5 more:      atime=1788454141 mtime=1788453962  wall=1788454180
```

Force atime below mtime and the very next read advances it to now:

```
atime just before mtime:  atime=1788453961 mtime=1788453962
read;  wall=1788454123     atime=1788454123 mtime=1788453962
atime just after mtime:   atime=1788453963 mtime=1788453962
read;  wall=1788454123     atime=1788453963 mtime=1788453962   # unmoved
```

A plain file on `/tmp` on the same Mac behaves identically (atime 1788454300 > mtime
1788453000, two reads, unmoved), so this is not the replica being special.

Two things do move atime: **materializing** the file (the fetch sets it to now), and
**evicting** it. And the domain's own Spotlight indexer reads files, which is one of the
"we accept it as used" cases §7 already lists - it produced one unexplained advance
during this pass.

So the second of §7's two meanings is the one in force: **the TTL is time since the last
fetch or save**, `last_fetch` and mtime carry it, and atime adds nothing a materialized
file does not already have. §7 anticipated this; `sshdrive show` and the docs must state
it.

### s4-3. Does the system refuse to evict an item with pending changes? - **Yes**

With `sshdrive debug fault nas --writes on` every upload fails `.serverUnreachable`, so
an `echo >>` in the mount leaves the item in the system's pending set:

```
$ sshdrive debug materialized nas --pending
  "count" : 1,  "path" : "Documents/Reports/report-004.txt"
$ sshdrive debug evict nas Documents/Reports/report-004.txt
  "errorDomain" : "NSFileProviderErrorDomain",
  "errorCode" : -2008,
  "errorDescription" : "The file 'report-004.txt' cannot be evicted."
```

So §7 step 3 holds: the eviction loop needs no pending-upload check of its own.

**But the code is not the documented one.** -2008 is
`NSFileProviderErrorNonEvictable`, the "provider marked it non-purgeable" code;
`NSFileProviderErrorUnsyncedEdits` is -2007 and never appeared. A kept item refuses with
the same -2008 (s6-5), so **the loop cannot tell a pin from a pending upload by error
code** and must not read -2008 as either. Evicting the *parent directory* of the pending
item fails differently again, and opaquely:

```
  "errorDomain" : "NSCocoaErrorDomain",  "errorCode" : 4101,
  "errorDescription" : "Couldn't communicate with a helper application.",
  "underlyingErrors" : [ { "errorDomain" : "libfssync.VFSFileTree.ItemNotFoundReason",
      "errorCode" : 5,
      "errorDescription" : "contentVersionMismatch(55207874@3:sz:151, expected: ...@2:sz:140)" } ]
```

not the `NSFileProviderErrorNonEvictableChildren` (-2006) the header promises. A
directory evict is therefore worth doing for `evict --all`, but its failure must be
logged and moved past, never interpreted.

### s4-4. Do Finder tags and other xattrs survive eviction? - **Other xattrs yes; tags never arrive as xattrs at all**

Eviction is safe. All three xattrs written through the mount were still on the file
after `evictItem` made it dataless, which is what `NSFileProviderItem.extendedAttributes`
promises in as many words: "The system will set extended attributes on dataless files,
and will preserve them when a file is rendered dataless. I.e extended attributes are
considered metadata, not content."

```
$ xattr -l .../report-005.txt          # after evictItem, blocks=0, dataless=true
com.apple.metadata:_kMDItemUserTags: bplistfake-Red
org.sshdrive.spike: s4-4
org.sshdrive.spike2#S: syncable-value
```

Two findings §5.4 does not have, both from watching what `modifyItem` actually received:

- **The system decides which xattrs the extension ever sees.** Of the three above, only
  `org.sshdrive.spike2#S` - the name carrying `XATTR_FLAG_SYNCABLE` - arrived in
  `changedFields.extendedAttributes` and reached the index. `org.sshdrive.spike`, an
  ordinary name, never did: it lives in the replica and the extension is never told. The
  header names `NSExtensionFileProviderAdditionalSyncableExtendedAttributes` in the
  appex's Info.plist as the way to widen that set.
- **Finder tags do not come through `extendedAttributes` at all.**
  `com.apple.metadata:_kMDItemUserTags` and `com.apple.FinderInfo` are excluded
  deliberately, "because that would be redundant": tags reach a provider as the item's
  own `tagData` property. And they are **not preserved across a re-download** - after
  re-materializing the file the two `org.sshdrive.*` xattrs were still there and the tags
  xattr was gone, because our item carries no `tagData` for the system to restore it
  from.

So §5.4's "Finder tags, colours, `FinderInfo` ... are stored in the index row and
returned on every item" is right in intent and wrong in mechanism, and as written it
loses the user's tags on the first remote change. Corrected there; the round-trip half is
S10's to prove.

### s4-5. Does a launchd agent's `stat` under `~/Library/CloudStorage` draw a TCC prompt? - **No prompt, no `EPERM`**

Dozens of `lstat`s and `open`s of the replica from the launchd-started agent over this
pass, every one successful; no `statErrno`, no `openErrno`. `tccd` does evaluate them,
and the interesting part is which service it uses:

```
AUTHREQ_CTX: msgID=158.287, service=kTCCServiceSystemPolicyAllFiles, preflight=yes
AUTHREQ_ATTRIBUTION: accessing={identifier=org.shirls.sshdrive, pid=86265, auid=501,
    binary_path=/Applications/SSH Drive.app/Contents/MacOS/SSH Drive},
  requesting={identifier=com.apple.sandboxd}
AUTHREQ_RESULT: msgID=158.287, authValue=0, authReason=5      # denied: no Full Disk Access
... TCCCreateDesignatedRequirementIdentityFromAuditTokenForService service=kTCCServiceFileProviderDomain
... TCCCreateIndirectObjectIdentityForFileProviderDomainFromPath
    kTCCCodeIdentityIdentifier = "org.shirls.sshdrive";
    kTCCIndirectObjectFileProviderDomainID = "org.shirls.sshdrive..."
... TCCAccessRequestIndirect service=kTCCServiceFileProviderDomain -> REPLY (501)
```

The agent is denied `kTCCServiceSystemPolicyAllFiles`, which it does not need, and the
access is then evaluated as `kTCCServiceFileProviderDomain` with **our own domain as the
indirect object** and allowed with no prompt and no `Prompting` line anywhere in the log.
A provider reaching its own domain's mount is not gated. So §7's "a prompt a launchd
agent cannot answer would come back as a silent EPERM" is a contingency that does not
arise here, and `sshdrive doctor` needs no line for it - on 26.4. It is still worth a
re-run on 14 before the claim is made unconditional.

---

### s6-12. Is `contentPolicy = .inherited` the neutral value? - **Yes**

Taken first, because it is the baseline every other S6 answer is measured against. Every
unpinned item is served `.inherited` (the extension maps our "unset" to it). On a freshly
added domain with the root enumerated once, the materialized set holds one item - the
root - and `debug transfers` shows **0 fetches**, indefinitely. `.inherited` forces
nothing.

### s6-1. Does an eager policy download the whole subtree after a working-set signal? - **Yes**

`sshdrive debug policy nas Documents eager-keep`, one working-set signal, then ~10 s:

```
$ sshdrive debug materialized nas
  "count" : 11        # /, Documents, Documents/Reports, report-000..007
$ sshdrive debug transfers nas
  "peakConcurrent" : 5,   "total" : 8
```

Eight files down through our own `fetchContents`, exactly as §7.1 step 2 expects.

### s6-2. Does it enumerate subfolders never opened in Finder? - **Yes**

`Documents/Reports` had **no row in the index and had never been listed by anyone** when
the pin was set - `fake add` enumerates only the root. The system asked for it,
our container enumerator listed it, and its eight files came down in the same pass. The
offline claim in §7.1 stands.

### s6-3. Does it accept a chain of never-enumerated ancestors reported through the working set? - **Not on its own; the chain has to be looked up**

This is the one answer that changes a design step, and it was reproduced three times.

Building `Deep/a/b/{one,two}.txt` on the fake server without letting anything list it,
then `debug policy nas Deep/a/b eager-keep` (which readdirs `Deep` and `Deep/a` into the
index, writes an anchor for each and signals the working set, i.e. exactly §7.1 step 1):

```
--- working-set signal only ---
t=+30s  "total" : 0,  "count" : 2
t=+60s  "total" : 0,  "count" : 2
t=+90s  "total" : 0,  "count" : 2
--- then signalEnumerator on each new ancestor's own container ---
t=+30s  "total" : 0,  "count" : 2
t=+60s  "total" : 0,  "count" : 2
t=+90s  "total" : 0,  "count" : 2
--- then one `ls` of the pinned folder in the mount ---
t=+30s  "total" : 0,  "count" : 5
t=+60s  "total" : 2,  "count" : 7      # one.txt and two.txt downloaded
```

Reporting the ancestors through the working set is not enough, and neither is
`signalEnumerator(for:)` on each of them. What starts it is a **lookup of the path in the
replica**. The good news is that the agent can make that lookup itself, without a user,
a Finder or a shell: on a second chain, `getUserVisibleURL` for the pinned row followed
by one `lstat` - `sshdrive debug stat nas Deep2/x/y`, 0.46 s, the file still dataless -
was enough, and `Deep2/x/y/f1.txt` came down within 90 s. s4-5 is what makes that legal:
the agent may read its own domain's mount with no TCC prompt.

§7.1 step 1 is corrected to say so. Without it `sshdrive pin` on a path Finder has never
shown would write the markers, report them, and quietly download nothing.

### s6-4. Do new remote files under a pin get fetched on the next poll? - **Yes**

```
$ sshdrive debug mutate nas create-file Documents/Reports/new.txt --contents hello-from-the-server
$ sshdrive debug stabilize nas       # 0.84 s
   ... 8 s later
$ sshdrive debug materialized nas | grep new.txt
      "path" : "Documents/Reports/new.txt"
$ cat ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/new.txt
hello-from-the-server
```

The eager policy applies to children that appear after it was set, which is §7.1 step 3.

### s6-5. Does `evictItem` refuse a kept item? - **Yes, and the policy is what refuses, not the capability**

```
$ sshdrive debug evict nas Documents                        # the pin root
  "kept" : true, "allowsEvictingServed" : false, "errorCode" : -2008,
  "errorDescription" : "The folder 'Documents' cannot be evicted."
$ sshdrive debug evict nas Documents/Reports/report-000.txt  # merely inherits the pin
  "kept" : false, "allowsEvictingServed" : true,  "errorCode" : -2008,
  "errorDescription" : "The file 'report-000.txt' cannot be evicted."
$ sshdrive debug evict nas README.txt                        # unpinned control
  "evicted" : true
```

The middle case is the finding. That file's row still carried `allowsEvicting` and
`kept = false` - milestone 1's `debug policy` writes the marker on one row only - and the
system refused it anyway, because its **effective `contentPolicy`, inherited from the
eager ancestor, is what makes an item non-evictable.** `allowsEvicting` is also
`API_DEPRECATED("use NSFileProviderContentPolicy instead", macos(11.0, 13.0))`, and the
header adds a third lever we did not know about:
`NSExtensionFileProviderAllowsUserControlledEviction = false` in the appex's Info.plist,
which "suppress[es] the user's ability to evict the item in the UI but retain[s] the
ability of the OS or the provider's program to evict items". §7.2 is corrected: the eager
policy carries the guarantee, dropping `allowsEvicting` is belt-and-braces on a
deprecated key, and whether the Finder entry actually disappears is still s6-7's to
record.

### s6-6. Does an explicit `.downloadLazily` on a child override an eager ancestor? - **Yes**

`Documents/Reports` marked `excluded` (`pin_state = -1`, served as `.downloadLazily`),
then `Documents` marked `pinned`. After stabilization and a signal:

```
  "count" : 4,   "path" : "",  "Documents",  "Documents/Reports",  "Documents/top.txt"
  "peakConcurrent" : 1,   "total" : 1
```

One fetch: the sibling `Documents/top.txt` directly under the eager folder. All nine
files inside the excluded `Documents/Reports` stayed dataless. Exclusions work, so
§7.1.1's five-situation table has the mechanism it assumes.

(This needed the snapshot to serve a real `.downloadLazily` for `pin_state = -1`; it used
to serve "no opinion", under which the eager ancestor would simply have won. Fixed in
`IndexItemSnapshot.swift`, with a test.)

### s6-7, s6-8, s6-10 - **needs-Finder**

Which built-in menu entries Finder shows for kept and unkept items, whether dropping
`allowsEvicting` removes "Remove Download", whether our two custom actions land at the
top level or in a submenu, and what a right-click on the window background or the sidebar
entry offers. Not attempted. `fileproviderctl evaluate <item>` exists and is worth
recording next to what Finder draws, but it answers a different question.

### s6-9. Does an eager policy on `.rootContainer` download the whole location? - **Yes**

```
$ sshdrive debug policy nas / eager-keep
  "identifier" : "NSFileProviderRootContainerItemIdentifier", "kept" : true
   ... two minutes later
$ sshdrive debug materialized nas
  "count" : 20      # every directory, all 8 reports, README.txt and run.sh
```

The root is not a special case, which is what §7.1.2 assumed and no longer has to hedge.

### s6-11. How many `fetchContents` calls does the system keep open at once? - **Six**

Measured with `sshdrive debug fault nas --fetch-delay 5000`, which holds each fetch open
for 5 s so the overlap is real rather than inferred, over a 30-file eager subtree:

```
peak 6   total 38
start times, rounded to 0.5 s:
  0.0 x6   5.5 x6   10.5 x6   16.0 x6   21.0 x6   60.0 x6   65.0 x2
max overlap recomputed from the timeline: 6
```

Strict batches of six, never seven, for 38 transfers. The undelayed runs peaked at 5.
So the bound §6.2 wanted is **6 concurrent `fetchContents` per domain**, and the
scheduler's own limit of four sits comfortably under it: at most six XPC calls are ever
held.

---

### The testing-mode entitlement, in practice

`NSFileProviderManager.listAvailableTestingOperations` / `run(_:)` are reachable (the
profile's `com.apple.developer.fileprovider.testing-mode` is live) but only on a domain
added with `NSFileProviderDomainTestingModeInteractive`, which `debug fake add
--testing-modes interactive` now sets. **None of the answers above needed it**, and it
was left off: interactive mode "disable[s] the automatic scheduling from the system",
which is precisely the behaviour S6 is measuring, and the header warns the mode cannot be
removed from a domain once given. What did the work instead was `waitForStabilization`
plus `waitForChanges(below:)` (`debug stabilize`) for the metadata side, and patience for
the download scheduler. `fileproviderctl` on 26.4 has no scheduling verbs at all - only
`dump`, `diagnose`, `evaluate`, `check`/`repair` and `obfuscate`.

### State the VM was left in

The signed Debug build at `/Applications/SSH Drive.app`, agent running from launchd,
`sshdrive doctor` green apart from the two expected warnings, one fake location `nas`
(`5DFFD268-...`) mounted with 41 items materialized, no faults set (`--writes off`,
`--fetch-delay 0`), no pin markers left. `sshtest`'s state is untouched.

### What to do next on the VM

1. s6-7, s6-8, s6-10 in front of a screen, together with S3's Finder questions.
2. Re-run s4-2 and s4-5 on macOS 14 or 15 before either answer is written down
   unconditionally.
3. Still open from the entries below: the `useReader` hook for s3-14, and a Developer ID
   plus `notarytool` pass for S1(d4).

---

## 2026-09-04 - S1(e) on a fresh user install (sshtest)

The question section 0.5 left open: does a clean user, who has never opened System
Settings, have to flip **Login Items & Extensions > File Providers > SSH Drive** before a
freshly added domain works, or is `open -g` from the cask's `postflight` (section 10)
enough on its own?

**Answer: `open -g` alone is enough. No switch. The domain comes up enabled, the appex is
launched, and the mount lists.**

Machine: the same Mac, second local account `sshtest` (uid 502, admin, no sudo), created
for this and logged in at the console by fast user switching so `gui/502` exists. Nothing
in `alec`'s session, domains or login items was touched. The bundle under test is the one
already at `/Applications/SSH Drive.app` - the post-cask state, Debug, signed
`Apple Development: ... (73XULXLK48)`, Team `RWGDZAYBM8`, hardened runtime, with the
embedded profiles; it was not rebuilt or reinstalled for this pass. macOS 26.4.1
(25E253).

### Baseline, before anything ran

```
$ ls -la ~/Library/CloudStorage
ls: /Users/sshtest/Library/CloudStorage: No such file or directory
$ launchctl print gui/502/org.shirls.sshdrive.agent
Could not find service "org.shirls.sshdrive.agent" in domain for user gui: 502
$ pluginkit -m -A -i org.shirls.sshdrive.fileprovider -vvv
  (no matches)
$ pluginkit -m -v -p com.apple.fileprovider-nonui       # 3 plug-ins, all Apple's
$ fileproviderctl dump | grep -E 'domain:|user-disabled'
domain: (default)
domain: (default) (hidden)
$ ps -o pid,uid,user,args -p 84172
84172 501 alec Contents/MacOS/SSH Drive                 # alec's agent, left alone
```

Two baseline notes:

- **The group container already existed**, empty:
  `~/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive/` with only
  `Library/{Application Support,Preferences,Caches,Application Scripts}` and
  `.com.apple.containermanagerd.metadata.plist`, all stamped 02:20, the same minute as
  the sixty-odd Apple group containers. `containermanagerd` creates the skeleton for
  every installed app's group at first login, before our code has ever run. So "no group
  container" is *not* a usable check for "the app has never run here"; `config.json`
  inside it is.
- **`sfltool dumpbtm` needs admin rights and is unusable over ssh**:
  `Error obtaining right system.privilege.admin: ... errAuthorizationInteractionNotAllowed`.
  The background-task database could not be read directly at any point in this pass;
  everything below is inferred from `launchctl`, `pluginkit`, `fileproviderctl` and
  fileproviderd's log, which agree.

### The section 10 postflight, run exactly as written

The bundle carries **no `com.apple.quarantine` xattr** (`xattr -l` prints nothing) because
it was installed by `rsync`, not by a cask download - so this pass says nothing about
Gatekeeper's one-time dialog.

```
$ open -g "/Applications/SSH Drive.app"
open rc=0
```

`open` returns 0 on an `.app` whose main executable is not an `NSApplication`
(skeleton-notes item 5), as S1(e1) expected. Ten seconds later:

```
$ launchctl print gui/502/org.shirls.sshdrive.agent
gui/502/org.shirls.sshdrive.agent = {
	active count = 2
	path = (submitted by smd.91)
	type = Submitted
	managed_by = com.apple.xpc.ServiceManagement
	state = running
	program identifier = Contents/MacOS/SSH Drive (mode: 2)
	parent bundle identifier = org.shirls.sshdrive
	parent bundle version = 1
	BTM uuid = F6AAF5E2-FD05-4FD2-981D-A0698D45DB38
	environment = { OSLogRateLimit => 64
	                SSHDRIVE_AGENT_ROLE => launchd
	                XPC_SERVICE_NAME => org.shirls.sshdrive.agent }
	domain = gui/502 [100279]
	runs = 1
	pid = 84448
	...
	semaphores = { successful exit => 0 }
	endpoints = { "RWGDZAYBM8.org.shirls.sshdrive.agent" = { active = 1 ... } }
	properties = partial import | runatload | resolve program | has LWCR
}
$ ps -o pid,uid,user,args -p 84448
84448 502 sshtest Contents/MacOS/SSH Drive
```

`runatload`, `SuccessfulExit = 0`, the group-prefixed mach endpoint, and the agent running
as 502 in its own GUI domain - the whole of e1, from one `open -g`, on a user who has
opened nothing.

```
$ pluginkit -m -A -i org.shirls.sshdrive.fileprovider -vvv
     org.shirls.sshdrive.fileprovider(0.1.0)
	            Path = /Applications/SSH Drive.app/Contents/PlugIns/SSHDriveFileProvider.appex
	            UUID = 55C4395C-E92A-4ECC-9A14-624CC2746CBD
	       Timestamp = 2026-09-03 16:28:26 +0000       # = 02:28 local, our open -g
	             SDK = com.apple.fileprovider-nonui
	   Parent Bundle = /Applications/SSH Drive.app
 (1 plug-in)
```

One registration, under `/Applications`, timestamped by this `open -g`. That is e2.

```
$ "/Applications/SSH Drive.app/Contents/MacOS/sshdrive" doctor
[  ok  ] agent reachable            the background agent answered
[ warn ] CLI on PATH                sshdrive is not on PATH; the Homebrew cask symlinks it for you
[  ok  ] app in /Applications       /Applications/SSH Drive.app
[  ok  ] macOS version              26.4.1
[  ok  ] login item                 enabled
[  ok  ] app group container        /Users/sshtest/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive
[  ok  ] extension registered       org.shirls.sshdrive.fileprovider(0.1.0)
[  ok  ] ssh                        OpenSSH_10.2p1, LibreSSL 3.3.6
[ warn ] login shell snapshot       not taken: the snapshot arrives in milestone 2 with the transport
[  ok  ] file provider domains      none
```

Green apart from the two expected warnings, and `SMAppService` reports the login item
**enabled**, not `requiresApproval`. So on a fresh user the "background item added"
notification of section 10 arrives with the item already on, exactly as section 10 claims.

### Adding a domain: enabled, not user-disabled

```
$ sshdrive debug fake add nas --files 8
{ "files": 8, "id": "1B5C5E86-FCA9-4663-9E74-4148BF86FA41", "name": "nas", ... }
$ ls -la@ ~/Library/CloudStorage/
drwxr-xr-x+  3 sshtest  staff    96 Sep  4 02:28 .
	com.apple.FinderInfo	  32
drwx------@  7 sshtest  staff   224 Sep  4 02:28 SSHDrive-nas
	com.apple.file-provider-domain-id	  69
```

`fileproviderctl dump` over the whole output contains **no `user-disabled` and no `⏹`**,
anywhere, for any domain. Our domain's header is bare and its indexer is live:

```
domain: 1{34}1 (n{1}s)
  + features: repl,
  + root: <FPFS>/S{10}s
  + persona: FEEDEEEE-DDDD-CCCC-BBBB-0000000001F6
  + indexer:
      spDomainID:     75957DB8-BDDF-4145-88E7-F25317948B3F
      enabled:        yes
      needs-auth:     no
      errors:         0
      batch-indexed (since last startup): 10
      total-indexable-count: 6

== Domains cache: <GroupContainers>/group.com.apple.FileProvider.DomainCaching/....plist ==
  + com.apple.CloudDocs.iCloudDriveFileProvider
  + org.shirls.sshdrive.fileprovider/1B5C5E86-FCA9-4663-9E74-4148BF86FA41
```

fileproviderd launched the appex without being asked twice:

```
$ ps -o pid,uid,args -U 502
84448  502  Contents/MacOS/SSH Drive
84477  502  /Applications/SSH Drive.app/Contents/PlugIns/SSHDriveFileProvider.appex/Contents/MacOS/SSHDriveFileProvider -LaunchArguments ...
```

and the mount lists and reads:

```
$ ls -la ~/Library/CloudStorage/SSHDrive-nas        # rc=0, immediate
total 8
drwx------@     7 sshtest  staff      224 Sep  4 02:28 .
drwxr-xr-x+     3 sshtest  staff       96 Sep  4 02:28 ..
drwx------@ 65535 sshtest  staff  2097120 Sep  4 02:28 .Trash
drwx------      3 sshtest  staff       96 Sep  4 02:28 Documents
drwx------      2 sshtest  staff       64 Sep  4 02:28 Media
-rw-------      1 sshtest  staff       37 Sep  4 02:28 README.txt
-rwx------      1 sshtest  staff       21 Sep  4 02:28 run.sh
$ ls -R ~/Library/CloudStorage/SSHDrive-nas         # whole tree, incl. Documents/Reports/report-00{0..7}.txt
$ cat ~/Library/CloudStorage/SSHDrive-nas/README.txt
SSH Drive fake backend, milestone 1.
$ sshdrive doctor | tail -2
[  ok  ] file provider domains      nas (1B5C5E86-FCA9-4663-9E74-4148BF86FA41)
```

No approval is pending. `log show --last 8m --predicate 'process == "fileproviderd" OR
subsystem == "com.apple.TCC"'` (2104 fileproviderd lines) has **no** `FP -2011`, no "Sync
is not enabled", no `user-disabled` and no TCC decision naming us; the only `com.apple.TCC`
lines are `Platform binary prompting is 'Deny' because: is Platform Binary` from unrelated
Apple processes. fileproviderd adopted persona `...01F6` for uid 502 and got on with it.

### What this means for section 10

Section 10 is right as written and needs no new user-facing step. The cask's `postflight`
running `open -g -a "SSH Drive"` once registers the login item **and** the extension, and
a domain added afterwards is enabled without any visit to System Settings. The notification
that a background item was added (already enabled) and Gatekeeper's one-time
downloaded-from-the-internet dialog remain the only UI, so `caveats` and `sshdrive doctor`
do **not** have to tell the user to go and flip a switch.

What made it work, as far as this pass can tell: a real signing identity plus the embedded
profiles. The `user-disabled` state that section 0.5 of the runbook records, and that cost
the earlier pass a trip to the GUI, came from the ad-hoc-signed build. It is not what a
cask user gets. Two things this pass does **not** prove, and that stay for S1(f3) on a
notarized artefact: that a *quarantined* bundle opened by `postflight` behaves the same
once Gatekeeper's dialog is answered, and that a Developer ID + notarized signature
behaves as this Apple Development + profile one did.

`sshtest`'s state was deliberately left in place - agent running, extension registered,
domain `nas` present and enabled, mount populated - so the owner can look at
System Settings > Login Items & Extensions > File Providers on the console and see what a
never-touched machine actually shows.

### Two incidental notes

- **`.Trash` is still in `ls -la` on this domain**, minutes after `fake add`, unlike the
  entry below where it vanished after two refusals. It is harmless here: `ls -la` returns
  in well under a second with rc=0, and the fileproviderd log for this domain has **no**
  `fetch-children-metadata(.trash)` at all - no `itemNotFound`, no `materializationFailed`,
  no loop. The system created its trash node (`create-item(propagated:<trash ...>)`,
  then one `update-item ... diffs:nchildren`, both `✅`) and never asked the extension
  about it, so nothing ever refused it and nothing ever removed it. So the fix's guarantee
  is "no hang", not "no `.Trash` entry"; whether the node is swept away afterwards is the
  system's business and varies. Worth re-checking in Finder rather than `ls`.
- macOS has no `timeout`, and **zsh has a `log` builtin** that shadows `/usr/bin/log`
  (`zsh:log:1: too many arguments`). Use the absolute path. A two-line perl
  `alarm`+`exec` wrapper was left at `~sshtest/rt` for the same reason `~alec/rt` exists.

---

## 2026-09-04 - the `.Trash` hang on a mount: diagnosed and fixed

Follow-up to the signed pass below, which found that `ls -la` on
`~/Library/CloudStorage/SSHDrive-nas` never returned. Same VM, same signed Debug build
plus the fix; `scripts/mac-build.sh signed`, installed at `/Applications/SSH Drive.app`,
agent restarted, `nas` re-created with `debug fake remove` / `debug fake add`.

### What the system was actually asking for

From `log stream --predicate 'subsystem BEGINSWITH "org.shirls.sshdrive" OR process ==
"fileproviderd"'`, on a freshly added domain, before the fix:

```
✍️  FS snapshot mutation: insert<s:trash p:trash n:".{4}h/" dir dls child:0 ...> why:item changed
✅  done executing <J2 create-item(propagated:<trash ...>) why:itemChangedRemotely|diskImport>
      → <actual:<s:.trash p:.trash n:".{4}h/" dir child:65533 m:rwxhe ... nsattr:<cap:rw------- cp:system nsp:system>>
‼️  done executing <FP1 fetch-children-metadata(.trash) why:materialization|itemChangedRemotely
      error:<... "itemNotFound(.trash, ...  Domain=NSFileProviderErrorDomain Code=-1005 "The file doesn’t exist.")">
‼️  done executing <FS5 materialize(trash) why:materialization|userRequest
      error:<NSError: libfssync.MaterializationError 3 "materializationFailed">>
```

and then that last pair again at 02:17:25.19, 02:17:26.35, 02:17:27.41 … about once a
second, for ever.

So it is **not** a lookup of a `.Trash` name under the root and **not** `item(for:)`. The
system creates the trash container itself, as a system-owned item
(`cp:system nsp:system`), at `add(domain)` time, and then asks the extension for
`enumerator(for: .trashContainer)` — the call fileproviderd logs as
`fetch-children-metadata(.trash)`. That happens because
**`NSFileProviderDomain.supportsSyncingTrash` defaults to YES** and nothing was setting
it; the header says so in as many words ("This property defaults to YES"). Not setting
`allowsTrashing` (section 5.4) governs only whether an *item* may be trashed; it does not
stop the system from giving the domain a trash.

### What the extension answered, and why that is the loop

`enumerator(for:)` threw `NSFileProviderError(.noSuchItem)` (FP -1005) — written as "No
trash (section 5.4)", which reads right and is exactly wrong. From
`NSFileProviderReplicatedExtension.h`:

> If containerItemIdentifier is NSFileProviderTrashContainerItemIdentifier and the
> extension does not support trashing items, then it should fail the call with the
> NSFeatureUnsupportedError error code from the NSCocoaErrorDomain domain.
>
> If the item requested containerItemIdentifier does not exist in the provider, the
> extension should fail with NSFileProviderErrorNoSuchItem. In that case, the system will
> consider the item has been deleted and attempt to delete the item from disk.

That is the whole bug: we told the system its own trash had been deleted, the system tried
to delete it from disk, the deletion failed because the trash is the system's, it
re-materialized it, and asked again. `ls -la` sat in the `stat` of `.Trash` throughout.
Plain `ls` and `ls -R` never touch it, which is why they were fine.

### The fix

1. `Apps/Agent/DomainManager.swift` - `addDomain` sets `domain.supportsSyncingTrash =
   false` before `NSFileProviderManager.add(domain)`. This is the API's own way of saying
   "no trash" and is what section 5.4 implies; the trashing operation is then the system's
   to decide, which the header says is not guaranteed by contract.
2. `Apps/FileProvider/FileProviderExtension.swift` - `enumerator(for: .trashContainer)`
   now throws `SSHDriveTrash.unsupportedError` (`NSCocoaErrorDomain` /
   `NSFeatureUnsupportedError`, 3328) instead of `.noSuchItem`.
3. Same file, `item(for:)` - the trash container is refused with `.noSuchItem` from
   nothing at all, before the index reader and before any XPC round trip, so a domain
   added by an older build (which still has a trash) cannot make a `stat` of `.Trash` wait
   on the agent.
4. Same file, `createItem` - a create of the name `.Trash` directly under the root is
   refused with the same feature-unsupported error, so that a system which "decides how to
   handle the trashing operation" can never decide to put a `.Trash` directory on
   someone's server.
5. `Packages/SSHDriveCore/Sources/XPCProtocols/Trash.swift` (new) - the identifier, the
   name, the two predicates and that error in one place, with the reasoning. Four tests in
   `Tests/XPCProtocolsTests/TrashTests.swift`, including one asserting the written-out
   identifier still equals `NSFileProviderItemIdentifier.trashContainer.rawValue` and one
   asserting the refusal is *not* `noSuchItem`. `swift test` is **32/32**.

`allowsTrashing` was already never set (`ItemDerivation.capabilities`), on the root row and
on every other row; that half of section 5.4 was correct all along and needed no change.

### Which half of the fix did the work

The domain flag alone would not have been enough. With `supportsSyncingTrash = false` the
system *still* created the trash node and *still* called `fetch-children-metadata(.trash)`
— twice, per `fileproviderctl dump`:

```
i:.trash fetch-children-metadata: 🛑 last:'1788452622 (-4s5ms)' next:'1788452627 (931ms62µs)' count:2
    error:'NSError: Cocoa 3328 "The requested operation couldn’t be completed because the feature is not supported."'
```

What retires it is the answer: on `NSFeatureUnsupportedError` the system throttles, gives
up after those two attempts, and then removes `.Trash` from the mount altogether. The flag
is kept because it is the documented contract and because it decides where a trashing
operation goes; the error code is what stops the loop.

### Verification on the VM

```
$ ls -la ~/Library/CloudStorage/SSHDrive-nas          # 0.02s total, rc=0
total 8
drwx------@ 6 alec  staff  192 Sep  4 02:23 .
drwxr-xr-x+ 4 alec  staff  128 Sep  4 01:00 ..
drwx------  3 alec  staff   96 Sep  4 02:23 Documents
drwx------  2 alec  staff   64 Sep  4 02:23 Media
-rw-------  1 alec  staff   37 Sep  4 02:23 README.txt
-rwx------  1 alec  staff   21 Sep  4 02:23 run.sh
$ ls -la ~/Library/CloudStorage/SSHDrive-nas/.Trash
ls: .../.Trash: No such file or directory
$ ls -R ~/Library/CloudStorage/SSHDrive-nas           # whole tree, rc=0
$ cat ~/Library/CloudStorage/SSHDrive-nas/README.txt
SSH Drive fake backend, milestone 1.
$ cat ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/report-003.txt   # rc=0
```

`ls -la` immediately after `debug fake add` still shows a `.Trash` for a few seconds,
while the system is creating it and getting refused; it is gone by the time the second
attempt has been answered and it never comes back. Fifty seconds of `log stream` with the
mount idle and two `ls -la` runs in it produced **zero** lines matching `trash` — before
the fix the same window held one `fetch-children-metadata` / `materialize` pair per second.
`sshdrive doctor` is green apart from the two expected warnings.

`~/rt` on the VM is a two-line perl `alarm`+`exec` wrapper written during this session:
macOS has neither `timeout` nor `gtimeout`, and every command that touches the mount wants
one.

### Not done here

Section 5.4's "No trash" paragraph still says only that `allowsTrashing` is never set,
which is the half that was already true and is not the half that mattered. It should gain
a sentence about `supportsSyncingTrash` and the `NSFeatureUnsupportedError` contract.

---

## 2026-09-04 - S1 signed pass, on the headless Mac VM

Same VM (macOS 26.4.1 arm64, 25E253, Xcode 26.4, no GUI), but now with an **Apple
Development** identity (`73XULXLK48`) and a **Developer ID Application** identity in the
login keychain, a development profile for `org.shirls.sshdrive` at
`~/Developer/SSH_Drive.provisionprofile` (`keychain-access-groups = RWGDZAYBM8.*`, this VM
in `ProvisionedDevices`) and one for `org.shirls.sshdrive.fileprovider` at
`~/Developer/SSH_Drive_FileProvider_Testing.provisionprofile` (adds
`com.apple.developer.fileprovider.testing-mode`). Build: `scripts/mac-build.sh signed`,
Debug, installed at `/Applications/SSH Drive.app`. The owner enabled SSH Drive under
System Settings > Login Items & Extensions > File Providers before this pass.
`~/.sshdrive-spike-peer-requirement` was **deleted**: everything below ran against the
build's own code requirement.

### Setup findings, before any sub-question

- **`codesign` over ssh needs the login keychain unlocked.** It fails with
  `errSecInternalComponent` and cannot put a password dialog on a screen nobody is at.
  `launchctl asuser` does not help (it needs root). This VM's login keychain has an empty
  password, so `security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db`
  clears it; `scripts/mac-build.sh signed` does that itself (`UNLOCK_KEYCHAIN=1`,
  `KEYCHAIN_PASSWORD`).

- **Do not put `com.apple.application-identifier` in the app's signed entitlements.**
  This is the one that cost the most time. Xcode writes that key for a profile-signed app
  and it is what the profile's own `Entitlements` matches, so it looks obviously right.
  With it, AMFI refuses to let **launchd** start the agent:
  `AMFI: Launch Constraint Violation (enforcing), error info: c[5]p[1]m[1]e[0]` and
  `xpcproxy exited due to OS_REASON_CODESIGNING | Launch Constraint Violation ... launch
  type 0`, after which launchd removes the service "since it exited with consistent
  failure". Direct exec of the same binary works, and `codesign --verify --deep --strict`
  is happy, so nothing but the launchd path shows it. The agent is the app bundle's own
  **main executable** (section 3), and an executable carrying an application identifier
  may only be launched as an app. Removing the key — leaving exactly
  `Apps/Agent/SSHDrive.entitlements`, i.e. the app group and `keychain-access-groups`, with
  the profile still embedded — makes launchd start it immediately, and the restricted
  entitlement still validates. The extension keeps the key, since it is launched by
  fileproviderd rather than launchd, and needs it for the testing-mode profile to match.

- **`xcodebuild` still cannot sign this project.** Unchanged from the ad-hoc pass: it
  demands a profile it can manage. `signed` mode builds with `CODE_SIGNING_ALLOWED=NO` and
  signs the tree afterwards, inside out, with `--options runtime --timestamp=none`.

### S1(b) - the peer code requirement, evaluated against a real chain

- **b1, both requirement strings parse: PASS** (re-confirmed signed). `csreq` round-trips
  both forms including `certificate 1[field.1.2.840.113635.100.6.2.1] exists`.

- **b2, a peer that fails the requirement is refused: PASS.** See b4.

- **b3, each real build satisfies its own requirement, both directions: PASS.**
  `codesign -v -R <Apple Development form>` returns 0 for all four —
  `SSH Drive.app`, `Contents/MacOS/sshdrive`, `Contents/MacOS/sshdrive-askpass`,
  `Contents/PlugIns/SSHDriveFileProvider.appex` — and the **Developer ID form returns 3**
  (`code failed to satisfy specified code requirement(s)`) for the same files. So the
  marker OIDs, the `certificate leaf[subject.OU] = "RWGDZAYBM8"` clause and the explicit
  identifier list are all right, and a release agent would not admit a debug client.
  With the override file deleted, `sshdrive doctor` is green, which is the same thing
  proved end to end: the agent's listener admits its own CLI.

- **b4, a stranger is refused: PASS.** A copy of `sshdrive` re-signed with the same Apple
  Development identity but `--identifier org.example.notus` fails
  `codesign -v -R` (rc 3) and, run against the live agent, gets
  "Cannot reach SSH Drive's background agent" — the listener drops it. The identifier
  clause, not just the chain, is doing work.

### S1(d) - restricted entitlements

- **d2, the agent reaches the data-protection keychain: PASS.** New hook
  `sshdrive debug keychain [--key K] [--value V]` does one `SecItemAdd` /
  `SecItemCopyMatching` / `SecItemDelete` round trip with
  `kSecUseDataProtectionKeychain = true` and
  `kSecAttrAccessGroup = RWGDZAYBM8.org.shirls.sshdrive`, from the launchd-started agent.
  Result: `addStatus 0`, `readStatus 0`, `matched true`, value read back unchanged. So the
  embedded profile plus `keychain-access-groups` works, and section 3.1's claim that the
  agent is the process with keychain access is confirmed. (The `KeychainSecretsStore`
  itself is still the milestone 2 stub; this hook talks to `SecItem` directly.)

- **d3/d4 (the entitlements half), CLI and askpass carry nothing: PASS.**
  `codesign -d --entitlements -` returns no entitlements blob for either, their
  identifiers are `org.shirls.sshdrive.cli` and `org.shirls.sshdrive.askpass`, both launch
  normally, and both are hardened-runtime signed. **Notarization itself is still not
  done** (that is a Developer ID + `notarytool` exercise for milestone 10), so the
  original d4 stays open.

### S1(a), (e), (f) re-confirmed signed

- **a1, a mach lookup starts the agent: PASS.** `sshdrive agent stop` leaves it down
  (`LastExitStatus 0`, `OnDemand true`); `sshdrive agent start` returns the version JSON
  and `launchctl print` shows `RWGDZAYBM8.org.shirls.sshdrive.agent` with `active = 1`.

- **a2, the sandboxed appex connects: PASS**, and this is the first time it has run.
  `secinitd` logs the container for `<<RWGDZAYBM8/org.shirls.sshdrive.fileprovider;
  signer:development>>`, `SSHDriveFileProvider` appears in `ps`, and listing the mount is
  served through the agent. No sandbox denial on the group-prefixed mach service.

- **b1/b2, e1, e2, f1: PASS**, unchanged. `open -g` returns 0 and registers both halves;
  `pluginkit -m -v -p com.apple.fileprovider-nonui` lists the appex under
  `/Applications/SSH Drive.app`; TERM exits the agent 0 and the next lookup starts it.

- **e3, `add(domain)`: PASS.** The call now returns in ~50 ms rather than blocking (see
  the fixes below). Mount directory: `~/Library/CloudStorage/SSHDrive-nas` for
  `displayName = "nas"`, carrying `com.apple.file-provider-domain-id`.

- **e4, the domain is usable: PASS.** With the extension enabled in System Settings, a
  freshly added domain comes up **without** `user-disabled`, fileproviderd launches the
  appex, and the mount serves. What is still unknown is whether the System Settings switch
  was needed *because* the earlier build was ad-hoc, or whether every fresh install needs
  it: this pass started from an already-enabled provider. Section 10's "the notification
  and the Gatekeeper dialog are the only UI" is therefore still unproven, and a fresh-user
  install is the test.

### S1(c) - a `FileHandle` across NSXPC

- **c1, `fetchContents` writes into the extension's handle: PASS.**
  `cat ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/report-000.txt` and
  `cat .../README.txt` both return the fake backend's bytes. No `NSXPCConnection` error
  about an unexpected class, so the interface's `Error?` reply parameters, the class
  whitelists and the `FileHandle` argument are all right at runtime (skeleton-notes item
  9). After the fetch the file is no longer dataless. **The runbook's filename is wrong**:
  the seeded files are `report-000.txt` … `report-007.txt`, not `report-1.txt`.

- **c2, a cancelled transfer: still GUI.**

### The headless-VM-feasible parts of S3

- **s3-1 (partial), list / open / remote change: PASS.** `ls -R` returns the whole seeded
  tree (`Documents/Reports/report-00*.txt`, `Media`, `README.txt`, `run.sh`), `cat`
  materializes, and `sshdrive debug mutate nas write Documents/Reports/report-000.txt
  --contents second-version` reaches the replica: the file reads `second-version`
  afterwards. **It is not quick.** Nothing had changed 6 s or 40 s after the mutation; it
  had landed by ~45 s after a second `debug signal`. On an idle headless machine
  fileproviderd throttles the working-set fetch (its schedulers show as ⏳), so any timing
  claim about change latency has to be made on a Mac someone is using. `create-file`
  followed by `delete` within that window never showed up at all, which is consistent with
  the same throttling rather than with a lost anchor: the index and the `anchors` table
  recorded every mutation (`changesSeenBySweep: 1` each time).

- **s3-2 (the mount-path half), naming: recorded.** `displayName = "nas"` gives
  `~/Library/CloudStorage/SSHDrive-nas`. What the Finder sidebar reads is still GUI.

- **s3-5 (first half), mode to `fileSystemFlags`: PASS.** A seeded file with mode 755
  shows as `-rwx------` in the mount and a 644 one as `-rw-------`, so `userExecutable`
  survives to the replica. (The group and other bits are the system's, not ours.)

- **s3-10, the read-only WAL reader inside the sandbox: PASS, as far as a terminal can
  see.** No sandbox denial, no `index reader failed` log line, and the current domain's
  `index.sqlite-shm` picks up an extended attribute the older domains' do not, i.e. the
  sandboxed reader opened it. The measurement in s3-14 still needs the `useReader` CLI
  hook, which does not exist (it is a property of the extension process, so the hook has
  to go through XPC).

- **`.Trash` is a trap, and it is new.** `ls -la` (or anything that stats `.Trash`) on the
  mount **never returns**: fileproviderd loops on
  `fetch-children-metadata(.trash) ... itemNotFound(.trash)` → `materialize(trash)` →
  `materializationFailed`, about twice a second, for good. We set no `allowsTrashing` and
  have no trash (section 5.4), and the system nonetheless keeps trying to materialize one.
  Plain `ls` and `ls -R` are fine. Worth a decision before milestone 4: either serve a
  `.Trash` item or find the flag that stops the system asking. (Both, as it turned out:
  `supportsSyncingTrash` is the flag, `NSFeatureUnsupportedError` is the answer. See the
  entry at the top of this file.)

### Two bugs found while running this pass

- **The extension disconnected its own domain on the way out, permanently.**
  `AgentConnection` called `NSFileProviderManager.disconnect(reason:)` from the
  NSXPCConnection **invalidation** handler. The system kills an idle extension instance,
  the connection invalidates as part of that teardown, and the domain was left
  disconnected; `liftDisconnect()` was guarded on *this instance* having set the flag, so
  the next instance — which starts with the flag clear — never called `reconnect()`. The
  visible symptom was that the root listing worked once and then every request failed with
  `FP -1004 ... NSFileProviderErrorDomainDisconnectionStateKey=4`, i.e. the system, not
  us, refusing. Fixed: invalidation only drops the connection, and the reply to
  `indexReady` calls `reconnect()` unconditionally on every instance launch.

- **A fake-backed location does not survive an agent restart.** `FakeTransport` is an
  in-memory tree, so after the agent exits the location's backend comes back empty while
  the index and the system's replica still hold the old rows; the mount then answers
  `Stale NFS file handle` for everything below the root. Not a product bug — the fake
  backend is a test double — but the runbook needs it: **after any agent restart, run
  `sshdrive debug fake remove <name>` then `debug fake add <name>` before continuing.**

### Fixes made on the Linux side during this session

1. `Apps/Agent/ConfigAccess.swift` (new) - `config.json`'s blocking file I/O now runs on a
   serial queue of its own instead of on the `DomainManager` actor's executor. That is the
   62 s wedge from the ad-hoc pass: `Data.write(to:options:.atomic)` in the group container
   blocked, and because it blocked *inside* the actor every other call queued behind it.
2. `Apps/Agent/Deadline.swift` (new) plus `nonisolated` on `addDomain`, `removeDomain`,
   `signalWorkingSet` and `existingDomainDescriptions` - no File Provider call runs on the
   actor any more, and each is bounded at 20 s, under the CLI's 30 s, so a stalled call
   returns a sentence naming the operation rather than a timeout.
3. `Apps/CLI/AgentClient.swift` - "cannot reach the agent" and "the agent did not answer in
   time" are now different errors. Only a failure to reach the mach service is
   `AgentUnavailable` (and only that triggers the `open -g` relaunch); a reply that never
   arrives is `CommandTimedOut`, and `sshdrive doctor` says which one it was.
4. `Packages/SSHDriveCore/Sources/XPCProtocols/XPCError.swift` (new) - every error the
   agent hands back is flattened first, with the `LocalizedError` description written into
   `userInfo`. NSXPC rebuilds an `NSError` from domain, code and `userInfo` only, so a
   Swift error's description did not survive the trip and the CLI printed
   `Config.ConfigStoreError error 1` instead of `No location matches "nas".` Four tests
   cover it; `swift test` is 28/28.
5. `Apps/FileProvider/AgentConnection.swift` - the sticky-disconnect fix above.
6. `Apps/Agent/ControlCommands.swift`, `Apps/CLI/DebugCommands.swift` - new
   `sshdrive debug keychain` hook for S1(d2).
7. `scripts/mac-build.sh` - new `signed` mode (`app` still means ad-hoc). It embeds
   `~/Developer/SSH_Drive.provisionprofile` at `Contents/embedded.provisionprofile`, keeps
   `keychain-access-groups` on the agent, signs the appex with the sandbox and app-group
   entitlements plus testing-mode and its own embedded profile when
   `~/Developer/SSH_Drive_FileProvider*.provisionprofile` exists (and silently without them
   when it does not), signs the CLI and askpass with their explicit identifiers and no
   entitlements, works inside out with `--options runtime --timestamp=none`, unlocks the
   login keychain first, and finishes with `codesign --verify --deep --strict` and
   `codesign -d --entitlements -` on all five.

### Where index.sqlite and config.json live: not moved, deliberately

The ad-hoc pass suggested moving them out of the extension's
`NSExtensionFileProviderDocumentGroup` path. **There is nowhere to move them to.** The
document group *is* the app group identifier, so its path is the group container itself,
and fileproviderd's own replica lives in a subdirectory of it — `fileproviderctl dump`
reports the extension storage URL as
`<GroupContainers>/RWGDZAYBM8.org.shirls.sshdrive/File Provider Storage`. Everything we
write is already a sibling of that directory, and any other subdirectory would still sit
inside the same coordinated container. Sections 3 and 5.2 also name these exact paths, and
5.2's argument for the read-only WAL reader depends on the index being in the group
container, which the sandboxed extension may write `-shm` into. So the paths stay, the
stall is fixed where it belongs (items 1 and 2 above), and the reasoning is recorded in
`GroupContainer.swift`.

### State the VM was left in

`/Applications/SSH Drive.app` is the **signed** Debug build (Apple Development,
hardened runtime, both profiles embedded), the login item is registered and enabled, the
agent runs from launchd, `sshdrive doctor` is green apart from the two expected warnings
(`CLI on PATH`, `login shell snapshot`), and one working fake location `nas` is mounted at
`~/Library/CloudStorage/SSHDrive-nas` with its tree readable. There is no peer-requirement
override file. The login keychain is unlocked. Three stale `domains/<uuid>/` directories
from earlier runs are left in the group container; they hold nothing and no domain refers
to them.

### What to do next on the VM, in order

1. ~~Decide what to do about `.Trash` before milestone 4~~ - done the same day; see the
   entry at the top of this file.
2. Time the change-detection path on a Mac someone is using; the headless throttling makes
   any latency number from this VM meaningless.
3. Add the CLI hook for `Apps/FileProvider/IndexReaderStore.useReader` (it has to go over
   XPC to the extension) so S3's s3-14 measurement can run.
4. A Developer ID + `notarytool` pass for the real d4, and a fresh-user install to settle
   whether the File Providers switch is needed on a clean machine (e4's remaining half).

---

## 2026-09-04 - S1 on the headless Mac VM (ad-hoc pass)

macOS 26.4.1 arm64 (25E253), Xcode 26.4, no signing identities, no GUI session anyone can
see (there *is* an Aqua session: the console user is auto-logged in, so `open -g`,
`SMAppService` and `launchctl print gui/501` all work over ssh; only clicking does not).
Build: `scripts/mac-build.sh app`, Debug, **ad-hoc signed**, installed at
`/Applications/SSH Drive.app`. The peer code requirement was relaxed for the session with
`~/.sshdrive-spike-peer-requirement` (see the fixes at the bottom).

### Setup findings, before any sub-question

- **`xcodebuild` cannot sign this project at all without a provisioning profile.**
  `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` fails with
  `error: "SSHDriveFileProvider" requires a provisioning profile` and the same for
  `"SSH Drive"`, because the app group and `keychain-access-groups` are restricted
  entitlements. The previous `CODE_SIGNING_ALLOWED=NO` build was worse than it looked: it
  produced only a *linker-signed* signature with `Identifier=SSH Drive`,
  `Info.plist=not bound`, `Sealed Resources=none` and **no entitlements at all**, which
  cannot host a File Provider extension. Fixed by ad-hoc signing after the build; see the
  fixes below.

- **Only one copy of the bundle may be registered with LaunchServices.** With
  `~/sshdrive/build/Build/Products/{Debug,Release}/SSH Drive.app` also registered, launchd
  resolved the login item to the wrong bundle and every spawn failed
  (`copy_bundle_path(<uuid>, 501, 0), error 0x6f - Invalid or missing
  Program/ProgramArguments`). `lsregister -u` on both build-directory copies fixed it
  immediately. Worth a line in the developer docs: the debug loop breaks the login item.

### S1(a) - the appex reaches the mach service, launchd starts the agent on the lookup

- **a1, launchd starts the agent on a mach lookup: PASS** (VM).
  `sshdrive agent stop` → no `Contents/MacOS/SSH Drive` process. `sshdrive agent start`,
  which is only a lookup, returned `{"agentVersion":"0.1.0-milestone1","interfaceVersion":1}`
  and the log shows a new pid: `agent starting from launchd` /
  `listening on RWGDZAYBM8.org.shirls.sshdrive.agent`.
  `launchctl print gui/501/org.shirls.sshdrive.agent` shows
  `endpoints = { "RWGDZAYBM8.org.shirls.sshdrive.agent" = { active = 1, managed = 1 } }`,
  `program identifier = Contents/MacOS/SSH Drive (mode: 2)`,
  `parent bundle identifier = org.shirls.sshdrive`, `properties = ... runatload ... has LWCR`.

- **a2, the sandboxed appex connects: BLOCKED (GUI).** The extension process never runs;
  see S1(e4).

### S1(b) - the peer code requirement

- **b1, both requirement strings parse: PASS** (VM). `csreq -r <file> -b <bin>` then
  `csreq -r <bin> -t` round-trips both the Apple Development and the Developer ID form,
  including the `certificate 1[field.1.2.840.113635.100.6.2.1] exists` marker syntax that
  had never been evaluated (skeleton-notes item 2). Syntax only: no certificate chain on
  this Mac evaluates them.

- **b2, a peer that fails the requirement is refused: PASS** (VM).
  `codesign -v -R <appleDevelopment form> "/Applications/SSH Drive.app"` → rc 3,
  `code failed to satisfy specified code requirement(s)`. With no override file the agent
  accepted the connection and then dropped it, and the CLI got
  `NSCocoaErrorDomain Code=4097 "connection to service named
  RWGDZAYBM8.org.shirls.sshdrive.agent"`. That is the correct behaviour for an ad-hoc
  build, and it is why the spike override exists.

- **b3/b4, each real build satisfies its own requirement and a stranger does not: BLOCKED
  (SIGN).** Needs an Apple Development or Developer ID certificate.

### S1(c) - a `FileHandle` across NSXPC

- **c1/c2: BLOCKED (GUI).** No `fetchContents` can be driven while the extension cannot
  start; see S1(e4).

### S1(d) - restricted entitlements

- **d1, what ad-hoc signing costs: PASS, and it is a hard stop.** An ad-hoc signature
  carrying `keychain-access-groups` is killed at exec:
  `open -g` returns `RBSRequestErrorDomain Code=5 "Launch failed" ... NSPOSIXErrorDomain
  Code=163 "Launchd job spawn failed"`, direct exec is `Killed: 9`, and amfid logs
  `Error Domain=AppleMobileFileIntegrityError Code=-424 "The file is adhoc signed but
  contains restricted entitlements"` with
  `Code=-427 "Unable to retrieve certificate chain"`. Removing that one key makes the same
  binary launch. `com.apple.security.application-groups` is **not** rejected ad-hoc: the
  agent runs with it and reaches the container (see below).
  `scripts/mac-build.sh` now strips `keychain-access-groups` when it ad-hoc signs.

- **App group container under an ad-hoc signature: PASS.** `sshdrive doctor` reports
  `[ ok ] app group container /Users/alec/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive`,
  and the agent creates `config.json` and `domains/<id>/index.sqlite{,-wal,-shm}` there. No
  dialog, no denial. So the group container needs no team identity, only the entitlement.

- **d2, the data-protection keychain from a profile-carrying bundle: BLOCKED (SIGN).**
  Unblocking it needs, on the VM: an **Apple Development** certificate and private key in
  the login keychain, and a development provisioning profile for `org.shirls.sshdrive`
  that carries `keychain-access-groups` = `RWGDZAYBM8.org.shirls.sshdrive` and
  `com.apple.security.application-groups`, embedded at
  `SSH Drive.app/Contents/embedded.provisionprofile`. That one addition also unblocks b3,
  b4, and very likely a2, c1 and e4.

- **d3, the CLI and askpass carry no restricted entitlements: PASS** (VM).
  `codesign -dvv` gives `Identifier=org.shirls.sshdrive.cli` and
  `Identifier=org.shirls.sshdrive.askpass` (from the embedded `__TEXT,__info_plist`, not
  the product name), and `codesign -d --entitlements -` returns no entitlements blob for
  either. Both launch normally.

- **d4, notarization: BLOCKED (SIGN).**

### S1(e) - `add(domain)` and `open -g`

- **e1, `open -g` registers the login item: PASS** (VM). `open -g -a "/Applications/SSH
  Drive.app"` returns 0 even though the main executable is not an `NSApplication`
  (`LSUIElement`, no `NSApplication`): LaunchServices does not object, so neither
  `LSBackgroundOnly` nor a minimal `NSApplication` is needed (skeleton-notes item 5). The
  app logs `login item registered (status 1)` = `.enabled`, i.e. **no user approval step
  for the login item**, and launchd immediately runs the agent from `RunAtLoad`.
  One cosmetic log line from launchd on every registration:
  `[org.shirls.sshdrive.agent:] Unknown key for plist importer (key: SHA256 type: data)` -
  emitted by `SMAppService`, not by our plist; harmless.

- **e2, `open -g` registers the extension with PlugInKit: PASS** (VM).
  `pluginkit -m -v -p com.apple.fileprovider-nonui` lists
  `org.shirls.sshdrive.fileprovider(0.1.0) ... /Applications/SSH Drive.app/Contents/PlugIns/SSHDriveFileProvider.appex`.
  (An earlier registration of the *unsigned* build-directory copy was rejected by pkd with
  `Ignoring mis-configured plugin ...: plug-ins must be sandboxed`, which is the
  linker-signed-no-entitlements build, not a design problem.)

- **e3, `NSFileProviderManager.add(domain)` from the launchd-started agent: PASS** (VM).
  `sshdrive debug fake add nas` produced
  `added domain 8DA72311-E240-4E3C-8D5D-58800A0B6985 as nas` and
  `~/Library/CloudStorage/SSHDrive-nas` appeared, carrying a
  `com.apple.file-provider-domain-id` xattr (69 bytes) with `com.apple.FinderInfo` on the
  `CloudStorage` directory itself. `fileproviderctl dump` lists the domain under
  `org.shirls.sshdrive.fileprovider`, `containing bundle identifier: org.shirls.sshdrive`,
  `document group name: RWGDZAYBM8.org.shirls.sshdrive`.
  **Early S3 naming data point:** `displayName = "nas"` gives the mount directory
  `SSHDrive-nas`, i.e. the system prefixes the provider's own name with no separator
  spaces. So `SSH Drive - nas` as a display name would give `SSHDrive-SSH Drive - nas`.
  S3 still has to record what the sidebar reads.

- **e4, the domain is usable: FAIL on this VM, BLOCKED (GUI).** The domain comes up
  **user-disabled**. `fileproviderctl dump <domain-id>` prints
  `no process observed; grace period timer not running` and `+ (⏹ user-disabled)`, and
  every scheduled job is throttled with
  `error:'NSError: FP -2011 "Sync is not enabled for “(null)”." ' domain:domainDisabled`.
  The appex is never launched (`extension request grace timer ran out`), and
  `ls ~/Library/CloudStorage/SSHDrive-nas/` ends in `fts_read: Operation timed out`.
  Not fixable from a terminal: `pluginkit -e use -i org.shirls.sshdrive.fileprovider` sets
  PlugInKit's own flag to `+` and does not clear `user-disabled`, `killall fileproviderd`
  changes nothing, and `fileproviderctl` has no enable command. The switch lives in the
  background-task database and is System Settings → General → Login Items & Extensions →
  File Providers → SSH Drive.
  **Open question for the owner:** whether a Developer ID, notarized build comes up
  enabled. If it does not, section 10's claim that the "background item added"
  notification and the Gatekeeper dialog are the only UI a user ever sees is wrong, and
  the cask's `caveats`, the docs and `sshdrive doctor` need a "switch SSH Drive on under
  Login Items & Extensions" step.

### S1(f) - the agent after the bundle is replaced

- **f1, TERM then a lookup: PASS** (VM). `sshdrive agent stop` exits the agent with status
  0, launchd leaves it down (`KeepAlive` `SuccessfulExit=false`, `launchctl list` shows
  `"LastExitStatus" = 0`, `"OnDemand" = true`), and the next lookup starts it again.

- **f2, the bundle deleted and put back: FAIL, and it needs a design answer.** After
  `rm -rf "/Applications/SSH Drive.app"` plus a fresh copy, launchd could no longer resolve
  the login item's bundle: every spawn attempt logged
  `Could not find and/or execute program specified by service: 3: No such process:
  Contents/MacOS/SSH Drive` and
  `Service could not initialize: copy_bundle_path(<uuid>, 501, 0), error 0x6f`, retrying
  on a 10 s throttle forever. The app's unconditional `SMAppService.register()` on every
  launch does **not** repair this: it keeps returning success and logging
  `login item registered (status 1)` while the job stays dead. Only `unregister()` followed
  by a launch clears it. That is exactly the `brew upgrade` / `brew reinstall` shape
  (Homebrew deletes the app, then installs the new one), so section 10's "the app calls
  `register()` unconditionally on every launch, since it is idempotent" is not sufficient
  on its own. Two candidate fixes for the owner to choose between: the app checks whether
  the job can actually run and does `unregister()` + `register()` when it cannot, or the
  cask's `postflight` always unregisters first.
  A `SSHDRIVE_AGENT_ROLE=unregister` role was added to the agent so this is testable and
  scriptable at all; see the fixes below.

- **f3, real `brew reinstall --cask`: BLOCKED (SIGN).**

### S1(g) - Homebrew's `signal:` stanza

- **g1: PASS, and it settles section 10 against section 3.1.**
  `launchctl list | grep -i sshdrive` prints exactly one line:
  `75700	0	org.shirls.sshdrive.agent`. The bundle identifier `org.shirls.sshdrive` does
  **not** appear anywhere in `launchctl list`. Homebrew matches the string in `signal:`
  against that output, so section 10's `signal: ["TERM", "org.shirls.sshdrive"]` would
  find nothing and the cask must carry `signal: ["TERM", "org.shirls.sshdrive.agent"]`.
  This resolves skeleton-notes item 4; section 10 needs the edit and section 13 a dated
  pointer.

### Two things worth recording that no sub-question asked for

- **A stalled `NSFileProviderManager` call wedges the whole agent, and the CLI blames the
  wrong thing.** With the disabled domain present, `Data.write(to:options:.atomic)` on
  `config.json` inside the group container blocked for about three minutes; `sample`
  caught it at
  `DomainManager.start() → ConfigStore.load() → ConfigStore.save() → Data.write(to:options:)
  → createProtectedTemporaryFile → open`, while fileproviderd logged a continuous stream of
  `NSFileCoordinator requested ... to provide item` for `org.shirls.sshdrive.fileprovider`.
  Because those writes happen inside the `DomainManager` actor, every other actor call
  queued behind them, so `debug fake list`, `debug fake add` and `debug fake remove` each
  returned after exactly 62 s (two 30 s `AgentClient` timeouts) with
  *"Cannot reach SSH Drive's background agent"* while the agent was in fact alive and
  answering `ping` and `doctor`. Both halves are worth fixing before milestone 3: the
  index and `config.json` live in the same app-group container that is the extension's
  `NSExtensionFileProviderDocumentGroup` (fileproviderd's dump shows
  `extension storage URLs: <GroupContainers>/RWGDZAYBM8.org.shirls.sshdrive/File Provider Storage`),
  and the CLI should distinguish "no answer on the mach service" from "the agent took too
  long". Whether the stall survives a *working* extension is unknown and should be
  re-checked as soon as e4 unblocks.

- **`NSFileProviderManager.remove(domain)` on a disabled domain does not return** within
  three minutes either, so the leftover domain could not be cleaned up. See the VM state
  note at the end.

### Fixes made on the Linux side during this session

1. `scripts/mac-build.sh` - new ad-hoc signing step after `xcodebuild` (and a `sign`
   mode). It signs innermost-first with the four real identifiers and the real entitlement
   files, and strips `keychain-access-groups`, which AMFI refuses on an ad-hoc signature.
   Without this the "built and signed" bundle had no entitlements and the wrong signing
   identifier.
2. `Packages/SSHDriveCore/Sources/XPCProtocols/CodeRequirement.swift` - debug-only spike
   override, from `SSHDRIVE_PEER_REQUIREMENT` or `~/.sshdrive-spike-peer-requirement`. The
   file, not just the environment, because launchd hands an `SMAppService` job a scrubbed
   environment: `launchctl setenv` is visible to `launchctl getenv` and never reaches the
   job (`inherited environment` carries only `SSH_AUTH_SOCK`). Release builds ignore both.
3. `Apps/Agent/ListenerDelegate.swift` - logs at error level whenever the override is in
   force.
4. `Apps/Agent/main.swift` - `SSHDRIVE_AGENT_ROLE=unregister` calls
   `SMAppService.unregister()` and exits, which is the only way found to clear a login-item
   registration whose bundle was replaced (S1(f2)).

### State the VM was left in

`/Applications/SSH Drive.app` is the ad-hoc Debug build, the login item is registered and
enabled, the agent runs, and `sshdrive doctor` is green apart from the two expected
warnings (`CLI on PATH`, `login shell snapshot`). One leftover **disabled** domain remains,
`nas` = `8DA72311-E240-4E3C-8D5D-58800A0B6985`, with
`~/Library/CloudStorage/SSHDrive-nas` that times out on access; it cannot be removed until
the extension is enabled. `~/.sshdrive-spike-peer-requirement` is in place; delete it to
put the build's own requirement back.

### What to do next on the VM, in order

1. Enable **SSH Drive** under System Settings → General → Login Items & Extensions → File
   Providers (someone at the machine, or Screen Sharing). Then
   `sshdrive debug fake remove nas` to clear the leftover, and re-run S1(a2), S1(c1) and
   S1(e4).
2. Install an Apple Development certificate and a matching development provisioning
   profile for `org.shirls.sshdrive` (app group + `keychain-access-groups`), so
   `xcodebuild` can sign normally. That unblocks S1(b3), S1(b4) and S1(d2), removes the
   need for the spike requirement override, and is the first thing to try if the extension
   still will not start once the switch is on.
3. With the extension running, S3, S4 and S6 become mostly a GUI exercise; only S3's
   reader-versus-XPC measurement (s3-14) needs a code change first, a CLI hook for
   `Apps/FileProvider/IndexReaderStore.useReader`.
