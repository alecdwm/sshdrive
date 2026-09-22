# Server quirks

Measured behaviour of remote servers - sshd and Tailscale SSH, SFTP implementations, login
shells, `find` flavours and OpenSSH's own client - that SSH Drive depends on. Format and rules:
`README.md`. Each row is the record of its own measurement; `testbed/README.md` describes the
service a row names in its **measured on** cell. Design pages named in the **source** column
live under `docs/design/`.

`ServerModel.ServerProfile` is built from these rows: a profile is a set of values for them, and
the testbed's twelve services are twelve profiles.

`Sources/ServerModel` keys a rule on each of the ids below, and `Tests/ServerModelTests`
defends it with no Mac, no VM, no network and no testbed:
`ServerProfileScenarios` (the profile table, the three extension sets, the prompt strings,
and the assertion that every id the model keys on is a row of *this file*),
`SFTPWireScenarios` (**L1**, **M2**, **D7**, **J8**, **J11**, **K12**, **N2** and the
`SQ-027`/`SQ-028`/`SQ-029` wire rules, over a real SFTP v3 wire server),
`ShellScenarios` (**J4**, **J5**, **J6**, **J7**, **J14**, **N4**, against real shells -
J14 is the login-shell snapshot per shell shape, with the bite-proof that a reader
waiting for EOF is still waiting when its deadline fires),
`HelperShellScenarios` (**J9**, **J10**, **J13**: the real Rust helper's self-digest
against a same-size corruption, `ETXTBSY` over a running executable and the
temp-name-and-rename that gets past it, and an exec channel that dies 255 with
nothing on stderr, reported to the log with its status and its stderr),
`HeartbeatScenarios` (**J1** - including the bite-proof that a wrapper naming the ambient
process group kills a sibling session - **J2**, **J3**),
`SweepScenarios` (**H1**, **H2**, **H3**, **H4**, **H5**, **H6**, **H7**),
`NamesAndAttributesScenarios` (**L7**, **L8**: the case collision the wire really
carries, and the two bitmasks derived from a mode the server really reports),
`TransportScenarios` (**K1**, **K2**, **K7**, **K9**, **K10**, **K11**, **K13**, **K14**,
**N3**, **J12**, against a stub `ssh` that `SSHMaster` spawns exactly as it spawns the real
one),
`MasterScenarios` (**K3**, **K4**, **K5**, **K6** - the mux client's three options, the
`-N` master's shape, the orphan sweep and the three routes `agent stop` needs to take
every master - against real processes with real `AF_UNIX` sockets, each with the
bite-proof that shows what the rule prevents: a mux client that opens a second
unsupervised connection, a `ControlPersist` master that forks away from its own pid, and
a name-only sweep that deletes the package's test databases).

**The same suite runs on the Mac, and the box is a seam there too.** Nothing is branched out
with a `#if`: `ServerModel.HostTools` measures what the machine running the suite can actually
do - the flavour of its own `find` by what it *accepts* (`SQ-081`), whether its filesystem will
hold a name that is not valid UTF-8 (`SQ-080`), and its `PATH_MAX` and `sun_path` budgets
(`SQ-085`) - and a row that meets one of those bounds skips with an `XCTSkip` naming the fact,
the same rule as `ScriptShell.skipReason`. Exactly one row loses coverage on a Mac: `H7`'s
real-`find` half, because APFS cannot hold the name (`SQ-080`); its `partitionRoots` and
SFTP-wire halves still run there. `J14`'s zsh row is skipped by the same rule (`SQ-083`) with
bash and dash still running on both. `SQ-082` and `SQ-084` are what let `K4`, `K6` and `J13`
run on Darwin at all.

Nine of these rows are also defended from the **agent's** side, in
`Tests/AgentRuntimeTests/AddFlowScenarios.swift`: suite **Q** drives the shipping
`sshdrive add` end to end against `FakeSSH` and `FakeSFTPServer`, with a real
`sshdrive-askpass`-shaped program answering from the real `AskpassBroker`, so the prompt
strings (`SQ-060`), the missing hint on the host-key question (`SQ-047`), the truncating
passphrase prompt (`SQ-048`), keyboard-interactive's shape (`SQ-062`), the per-hop argv rule
(`SQ-063`) and the key-and-password server (`SQ-064`) are exercised by the code that makes
the decision rather than by an assertion about a string.

A scenario needing a shell this box lacks - `busybox`, `fish`, `tcsh` - skips with a
named reason rather than pretending, and **J1's bite-proof skips on macOS**: the sessions
are put in one shared process group there too, but a `kill -TERM 0` reaches nothing but the
sender's own child, so the row says so instead of passing for the wrong reason. Linux is
the gate.

## `find` and the sweep

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-001 | **No busybox has `find -cmin`.** BusyBox 1.36.1 answers `find: unrecognized: -cmin`, rc 1; it has `-mmin` and `-newer FILE` only. This is the ordinary NAS path, not a legacy case. | `alp`, `alp-nocmin` (2026-09-04) | change-detection.md; gotcha 15 | H1, H2, H3, H4, H5 |
| SQ-002 | **busybox `find --version` prints an error and exits 0.** A flavour probe keyed on the exit status therefore calls every busybox server GNU and every sweep on it fails outright with nothing on stdout. The probe must read the `busybox` banner and the `-cmin` answer. | `alp` (2026-09-04) | change-detection.md, cli.md; gotcha 73 | H1 |
| SQ-003 | busybox `find` has no `-printf` either (`find: unrecognized: -printf`, rc 1). | `alp` (2026-09-04) | change-detection.md | H2, H4 |
| SQ-004 | A busybox `-cmin` does not lose a field, it **fails the whole sweep**, so `SweepPlan` refuses `-cmin`/`-printf` on a busybox flavour a second time even when the probe claims them. | `alp` (2026-09-04) | change-detection.md; gotcha 73 | H2 |
| SQ-005 | **`-mmin` misses a ctime-only change.** A `chmod` on a file whose mtime was set back to 2020: found by GNU `-cmin`, missed by `-mmin` (1 hit vs 0). The fallback loses ctime-only changes and nothing else. | `deb`, `alp` (2026-09-04) | change-detection.md; gotcha 15 | H3, H4, H5 |
| SQ-006 | **`-cmin` and `-printf` each cost a `stat` per entry, and that is what a sweep spends.** Over a million files (2,000 directories x 500 empty files), warm: 204-228 ms with `-print0` and no time test, 858-886 ms adding `-cmin`, 1.6-3.0 s adding `-printf`. An ordinary incremental sweep of that tree returning one record is **876 ms**. A container on the same Mac is a floor, not a NAS: the page cache cannot be dropped. | `deb`, GNU findutils, Debian 12 (2026-09-04) | change-detection.md; gotcha 70 | H8, H10 (shape only; the milliseconds are VM-only) |
| SQ-007 | **`find` has no portable `--`,** so a top-level directory named `-name` would be read as an option and take the whole sweep with it. Every root is spelled `./name` and the prefix stripped before `RelativePath`. | (design + testbed `weird/`) | change-detection.md; gotcha 71 | H6, H7 |
| SQ-054 | **A container cannot have its clock skewed:** Docker has no time namespace and every container shares the host's clock, so a server whose clock disagrees with ours has never been tested against a real skew. What stands in for it is `sshdrive debug watch --clock-skew N`, which shifts the stored server timestamp the next window is computed from; `status` prints a `note:` while it is set. | testbed (2026-09-04) | change-detection.md; `testbed/README.md` | H4 (the only coverage there will ever be) |
| SQ-055 | **A root whose bytes are not valid UTF-8 cannot travel to `find` at all.** `set --` is a String pipeline end to end, so such a root has no spelling that survives the trip; it is left out of the `find` argv and listed at tier 0 in the same cycle instead, which watches it at the same cadence and loses only the server-side walk. A lossy conversion is worse than none: `String(decoding:as:)` succeeds by substituting U+FFFD, and `find` then answers `No such file or directory` for a name no server has while the real directory goes unwatched. | (design + testbed `weird/`; a server name need not be valid UTF-8, see `names-and-attributes.md`) | change-detection.md, names-and-attributes.md, security.md | H7 |

## Process lifetime and remote command teardown

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-008 | **A bare background process started by a session survives an abrupt client kill.** A `sleep &` started by the session that was then `SIGKILL`ed was still running three minutes later. sshd reaping the session does not reach a child that has left the foreground job. | `deb-shells`, `deb`, `alp` (2026-09-04) | change-detection.md; gotcha 69 | J2 |
| SQ-009 | **`ClientAliveInterval` changes nothing about SQ-008.** Measured with it unset, at 15/3, and on busybox: identical outcome. The heartbeat wrapper is the only mechanism there is, not a workaround for a misconfiguration. | `deb` (15/3), `deb-shells` (unset), `alp` (unset) (2026-09-04) | change-detection.md; gotcha 69 | J3 |
| SQ-010 | **Tailscale SSH puts every session of every client in `tailscaled`'s process group.** A `kill -TERM 0` from one session therefore signals all of them: measured with three concurrent sessions, one `kill -TERM 0` killed the two bystanders **and the connections under them** (exit 255 after 3 s and 6 s). `tailscaled` itself is root and survives. `ssh <host> 'ps -o pid,ppid,pgid,sid,comm; cat /proc/self/stat'` shows it: the per-session child, the shell under it and the command under that all carry `tailscaled`'s pid as their pgid, in session 1. | `ts-ssh` (2026-09-08) | change-detection.md; gotcha 100 | **J1** |
| SQ-012 | OpenSSH's sshd gives each session a **session and process group of its own**, so `kill … 0` there has a blast radius of exactly that session. A wrapper that names the ambient group is therefore correct on OpenSSH and destructive on the servers of SQ-010, and only the second kind shows it. | `deb` (2026-09-08) | change-detection.md | J1 |
| SQ-011 | A remote command **killed by a signal** makes `ssh` return **255 with nothing on stderr**, indistinguishable at the exit code from a mux-client error. | `ts-ssh` (2026-09-08) | ssh.md | J13 |
| SQ-077 | **The helper's stream does not survive its connection, and it is the connection that usually kills it.** A master `kill -9`ed, an agent restart, a wake, a network path change and a 90-second stall all end the exec channel; the helper on the server then exits on its own 60 s heartbeat timeout. Nothing about any of that is a statement about whether the server can run a helper. | `deb` (2026-09-08) | change-detection.md | F7, F8, F9, N1, P9 |
| SQ-078 | **A stall of more than 60 s kills the helper even though nothing is broken.** With the master and its mux clients `SIGSTOP`ped for 90 s and then continued, the helper had already exited (missed pings) and the exec channel came back exit 255 - with the master still alive, so the agent saw a stream that died on a *live* connection. | `deb` (2026-09-08) | change-detection.md | F8 |
| SQ-079 | **A channel open that fails because the master died is not distinguishable from a refused session by anything but the master.** `ssh` prints `mux_client_request_session: session request failed` only for a real refusal, but a dead master produces `Control socket connect: No such file or directory`, `mux_client_hello_exchange: … Broken pipe` or nothing at all - and every one of those reads as "the server allows one channel at a time". Whether the `-N` master is still running is the test. | `deb` (2026-09-08) | ssh.md | K13, K14, K3, N1 |
| SQ-032 | Writing over a **running** executable fails `ETXTBSY` / `Text file busy`, which is why an upload must go to a temp name and rename. Seven bytes overwritten in place, leaving the size unchanged, is a corruption only a hash can see, and it is the case the temp-and-rename path has to survive. | `deb` (2026-09-05) | change-detection.md; gotcha 89 | **J8**, J10 |
| SQ-033 | `mkdir`'s attributes go through the **server's umask**, so a mode of 0700 that was asked for can land as 0755; the mode must be asserted with a `setstat` afterwards. Checked by `chmod 0755 ~/.cache/sshdrive` and a redeploy, after which the directory reads `drwx------` again. | `deb` (2026-09-05) | change-detection.md | J8, D10 |

## Shells and remote scripts

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-015 | **rc files print on non-interactive startup**, in every shell shape: `.bashrc` for bash, `.zshenv` for zsh (read for every invocation), `config.fish` for `fish -c`, `.cshrc` for tcsh. Everything before the sentinel must be discarded. | `deb-shells` (2026-09-04) | security.md; gotcha 13 | J5, J14 |
| SQ-016 | An rc file can leave a **background child holding stdout**, so EOF never arrives on the channel and only the closing sentinel ends the read. Any reader that waits for EOF hangs. | `deb-shells` `bashbg` (2026-09-04) | security.md; `testbed/README.md` | J5, H5, J14 |
| SQ-017 | **Debian's `/bin/sh` is dash**, which an exec channel runs, so the heartbeat wrapper's `sleep`-and-mtime watchdog branch is the *ordinary* Linux path rather than a fallback; busybox ash takes the `read -t` branch. | `deb`, `alp` (2026-09-04) | change-detection.md; gotcha 36 | J6, J14 |
| SQ-018 | **dash answers `;;` with `Syntax error: ";;" unexpected`** and the channel dies on the spot. A relay fragment that already ends in `;` written as `… \|\| break; <relay>; done` produces exactly that. The ladder then reads the dead channel as "the helper would not start". | `deb` dash, `alp` busybox ash (2026-09-05) | change-detection.md; gotcha 84 | J7 |
| SQ-019 | `.` with no argument is a POSIX **special builtin** whose failure ends a non-interactive shell outright, which is why the wrapper's stamp file is `touch`ed and never `:`-redirected. | (POSIX + 2026-09-04) | change-detection.md; gotcha 36 | J6 |
| SQ-020 | **`printf "\0<sentinel>"` reads `\0` and the octal digits after it as one character,** so a sentinel beginning with a digit silently loses its first bytes and the marker is never found. Every sentinel's NUL must be its own `printf`. | (2026-09-04) | ssh.md, security.md; gotcha 34 | J4 |
| SQ-013 | A **`ForceCommand internal-sftp` account may answer an exec channel with a plain sentence** - `This service allows sftp connections only.` - rather than SFTP framing. Both shapes mean "no shell access (ForceCommand)", never "shell output unusable". | `deb-shells` `forcesftp` (2026-09-04) | security.md; gotcha 37 | N4, J12 |
| SQ-014 | An **external `sftp-server` behind a noisy rc file** puts the rc output in front of the SFTP `VERSION` reply; `sftp(1)` fails with "Received message too long". The client must fall back to running `sftp-server` on an exec channel. | `deb-extsftp` `extnoisy` (2026-09-04) | security.md; `testbed/README.md` | N4 |
| SQ-050 | Six directory names of the shape `$(echo pwned)`, `quote'name`, `space in name`, `*star*`, `[bracket]`, `back\slash` work as sweep roots, each returning its own file and creating no `pwned` file - the `set --` single-quoting rule holding under real shells. | `deb` `weird/` (2026-09-04) | security.md | H6, L7 |

## SFTP: implementations, extensions and the wire

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-024 | **Go `pkg/sftp` advertises exactly `hardlink@openssh.com`, `posix-rename@openssh.com` and `statvfs@openssh.com`** and nothing else; that fingerprint identifies it. No version advertises `fsync@openssh.com` or `limits@openssh.com`, so an `upgrade:` line naming either asks the user to replace their SSH server for nothing. | `ts-ssh` (2026-09-08) | cli.md; gotcha 101 | K12, N2, N5 |
| SQ-025 | OpenSSH's own `sftp-server` advertises, in this order, `posix-rename`, `statvfs`, `fstatvfs`, `hardlink`, `fsync`, `lsetstat`, `limits`, `expand-path`, `copy-data`, `home-directory`, `users-groups-by-id` - anything carrying `fsync`/`lsetstat`/`limits`/`expand-path` is OpenSSH. | `deb`, OpenSSH_9.2p1 Debian-2+deb12u10 (2026-09-05) | cli.md | K12, N2, N5 |
| SQ-026 | Alpine's `internal-sftp` offers the **same** OpenSSH extensions as the external `sftp-server` (`posix-rename`, `fsync`, `lsetstat`, `limits`), so nothing in the write protocol degrades there; the capability report reads 5/8 optimal, the two `◐` being busybox `find`. | `alp` (2026-09-04) | sftp.md, writes.md | N2, N5 |
| SQ-027 | **`limits@openssh.com` sizes the request, not the window.** It says nothing about how many requests may be outstanding; the pipeline depth of sixteen is the client's own. Measured: `maxPacketLength 262144`, `maxReadLength/maxWriteLength 261120`, `maxOpenHandles 20475` - 255 KiB inside a 256 KiB packet. | `deb` (2026-09-04) | sftp.md; gotcha 38 | N2 |
| SQ-028 | **SFTP v3 carries nine status codes and no errno**: `ENOSPC`, `EEXIST`, `ENOTEMPTY` and `EXDEV` all arrive as a bare `FAILURE`, so a second question (`lstat`, `statvfs`, `readdir`) is the only way to tell them apart. | (protocol + measurement) | sftp.md; gotcha 24 | D3, D10, L7, J10 |
| SQ-029 | OpenSSH's `SSH2_FXP_SYMLINK` takes its two paths in the **opposite order from the draft**. | (protocol) | sftp.md; gotcha 24 | M1, **L1** |
| SQ-030 | **SFTP `opendir` follows a symlink.** With `mv data/swap data/swap.real && ln -s /etc data/swap` done on the server, listing `data/swap` returned `/etc`: `passwd`, `shadow`, `skel`, `ld.so.cache` and eighty other names landed in the index as rows under the mount root, out of an `/etc` of 82 entries. Every listing must re-`lstat` its own directory before `readdir` and refuse to descend when the answer is no longer `directory`. | `deb` (2026-09-04) | security.md; gotcha 41 | **L1** |
| SQ-031 | **SFTP v3's `readdir` carries attributes but no link target,** so every symlink a listing reports costs a `readlink` before its row can be built. They go out through the SFTP client's request window rather than one at a time, so a directory of links costs a round trip per sixteen of them, and a `readlink` that fails costs only its own link. | `deb` (2026-09-04) | symlinks.md, sftp.md; gotcha 54 | M2 |
| SQ-034 | A server's plain `rename` may refuse an existing name or may overwrite it; busybox + `internal-sftp` reports `renameRefusesAnExistingName: true` and needs no preflight, and the probe is what decides. | `alp` (2026-09-04) | writes.md | D7, D10 |
| SQ-051 | A directory of 10,000 entries `readdir`s in 0.10 s on the wire; sixteen requests in flight at the server's own 255 KiB read size gave 252 MiB/s reading and 129 MiB/s writing against `sftp(1)`'s 94 MiB/s. **A `readdir` page carries about a hundred names**, so that directory is a hundred pages and its listing costs one round trip per *window* of pages: 51 at a pipeline depth of two, 7 at sixteen, and 1 for any directory of sixteen pages or fewer. The window over-issues past EOF by at most one window's worth of requests, each answered with an EOF status. | `deb`, OpenSSH 9.2 (2026-09-04); the window measured on the wire against `FakeSFTPServer` (2026-09-09) | sftp.md | N2 |

## OpenSSH client behaviour

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-035 | **`ssh` ends every stderr log line with CRLF, and in Swift `"\r\n"` is one `Character`,** so `split(separator: "\n")` finds no separator in `ssh -v` output at all: the whole transcript is one "line". Line endings must be normalised on **unicode scalars** before splitting. | `ts-ssh` via OpenSSH 10.2p1 (2026-09-08) | cli.md; gotcha 102 | K11, K3 |
| SQ-036 | `remote software version <x>` is printed only at **`DEBUG1` and above**. Masters run at `LogLevel=ERROR` and a mux client speaks to the master's socket, so the collect connection - a real, fresh `ssh` the agent makes once per `add` - is the only `ssh` that can read the server's identification string. Its `debug1:` lines are stripped again before the exit classifier or `add`'s own message sees them. | (2026-09-08) | cli.md, ssh.md; gotcha 101 | K12, K4, N5, Q9 |
| SQ-037 | A **mux client never speaks to the server**: it speaks to the master's control socket, so it sees no banner and no version. | (2026-09-04) | ssh.md | K3, K12 |
| SQ-038 | **`-o ProxyJump=none` written before `-o ProxyCommand=…` silently discards the ProxyCommand.** readconf takes the first setting of each keyword and `ProxyJump none` marks the jump host as set; the master then resolves the inner hostname itself and dies `Could not resolve hostname inner`. With `ProxyCommand` first and `ProxyJump=none` after, `ssh -G` shows the proxycommand, the chain works, and a `ProxyJump` in the user's own config is still cancelled. | OpenSSH 10.2p1 (2026-09-04) | ssh.md; gotcha 33 | **K1** |
| SQ-039 | `ssh` **percent-expands a `ProxyCommand` before `/bin/sh -c` sees it**, so a nested hop's `%h`/`%p` must be doubled once per level it sits below the master (`%%h:%%p` at hop *n-1*); without that, hop 1 dials the destination. | (2026-09-04) | ssh.md; gotcha 33 | K2 |
| SQ-040 | `ControlMaster=no` alone still attaches to the config's socket; a hop needs **`ControlPath=none`** as well. | (2026-09-04) | ssh.md; gotcha 4 | K2 |
| SQ-041 | With `ControlPersist` set, `ssh` **forks away** and the agent loses the pid, the stderr and the exit signal; the master must run `-N` with `ControlPersist=no`. | (design + measurement) | ssh.md; gotcha 2 | K4 |
| SQ-042 | Without `-F /dev/null -o BatchMode=yes -o ProxyCommand=/usr/bin/false`, a mux client whose socket is missing opens a **second, unsupervised connection** instead of failing. A mux client that exits before its channel opened is always "master lost", never an auth failure. | (2026-09-04) | ssh.md; gotcha 3 | K3 |
| SQ-043 | A **restarted location can hold two masters**: the second finds the first's socket in place, prints `ControlSocket already exists, disabling multiplexing` and runs **without a socket at all**, so a socket-based sweep cannot see it. The command line is the only way to find it: a process named `ssh`, owned by this uid, whose argv contains `ControlPath=$TMPDIR/sshdrive-`. | (2026-09-05) | ssh.md | K6, P4 |
| SQ-044 | An orphan master whose socket has **already been unlinked** cannot be reached by `ssh -O exit` at all; only its pid can, and `ssh -O check` on a socket that is still there is where that pid comes from (`Master running (pid=NNNN)`). A pid read from a socket left over from an earlier boot can have been reused, so it is checked to still be a process named `ssh` before it is signalled. | (2026-09-04, 2026-09-05) | ssh.md | K6, P4 |
| SQ-045 | A `-J` chain needs the **jump host's** key in `known_hosts` already: `-o StrictHostKeyChecking` on the command line does not reach the `-W` children, only a `~/.ssh/config` alias does. | testbed (2026-09-04) | `testbed/README.md` | — (testbed only) |
| SQ-046 | Killing an `ssh`/`sftp` that used `-J` **leaves its `-W` children alive**, holding the pipe open - the same orphan problem as our own masters. | testbed (2026-09-04) | `testbed/README.md` | K6 |
| SQ-047 | **The host-key question reaches askpass with `SSH_ASKPASS_PROMPT` unset,** exactly like a password prompt: `ssh` sets the hint only for `RP_ASK_PERMISSION` and `notify_start`, and the host-key question goes through `read_passphrase(prompt, RP_ECHO)`. Classifying on the hint would answer a stored password to "Are you sure you want to continue connecting". Nothing raised against the testbed set the hint at all, so `confirm` is a branch with no observed producer. | OpenSSH 10.2p1 (2026-09-04) | secrets.md; gotcha 6 | **K7**, Q5, Q8 |
| SQ-048 | `Enter passphrase for key '%.100s': ` **truncates**, so a path over 100 bytes reaches askpass cut short and the prompt text alone can never be the keychain key; the prefix must be mapped onto the asking `ssh`'s own `identityfile` list from the same `ssh -G` resolution and keyed on the full path. | OpenSSH 10.2p1 (2026-09-04) | secrets.md; gotcha 6 | K8, Q8 |
| SQ-049 | A **changed** host key raises no prompt at all under `StrictHostKeyChecking=ask`: `ssh` prints the REMOTE HOST IDENTIFICATION HAS CHANGED banner and exits. Only an *unknown* host asks. | OpenSSH 10.2p1 (2026-09-04) | secrets.md | K7, Q5 |
| SQ-052 | **stderr distinguishes no key-agent state.** A missing socket, a dead socket and a *locked* agent all exit with the same bare `Permission denied (publickey,password)` at `LogLevel=ERROR`; OpenSSH's own agent locked with `ssh-add -x` reports *no identities* rather than refusing. The pre-spawn socket probe is the only signal. `agent refused operation` stays in the classifier because 1Password and Secretive are documented to produce it, and neither is installable on the VM. | OpenSSH 10.2p1 (2026-09-04) | ssh.md; gotcha 40 | K9, K3, Q6 |
| SQ-053 | An **empty answer skips an identity**: `ssh` logs `no passphrase given, try next key` and moves on to the next `identityfile`, which is what makes a refusal safe. | OpenSSH 10.2p1 (2026-09-04) | secrets.md | K9, Q8 |
| SQ-021 | **`MaxSessions 2` leaves exactly one spare channel** beside the metadata SFTP channel: the `-N` master carries no session of its own, so master + metadata + bulk is already at the limit. The bulk channel is dropped, transfers share the metadata channel with the scheduler's window share halved to 8, and the spare is kept for exec (sweep, probe, helper), which cannot share. The probe records `"concurrentChannels": 2, "bulkChannel": false, "execChannel": true`. | `deb-maxsess` (2026-09-04) | ssh.md; gotcha 44 | N3, J12, P9 |
| SQ-022 | **A channel is proved open only by completing the SFTP handshake on it.** `ssh` spawns successfully whether or not the session was granted; only the refusal on stderr, or a handshake that never lands, tells the two apart. So the probe asks "may I hold three at once" with two opens: the second *is* the bulk channel and the third stands in for the exec channel and is closed again. | `deb-maxsess` (2026-09-04) | ssh.md; gotcha 44 | N3 |
| SQ-023 | The agent **never sees a server banner** on the connections it makes, so a capability cache cannot be keyed on one; it is keyed per location in `domains/<id>/capabilities.json` and invalidated by an explicit re-probe. A cached budget that has stopped holding is noticed anyway, because opening the bulk channel is what the cached answer is used for. | (2026-09-04) | ssh.md | N2 |

## Auth shapes

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-060 | The prompt strings are exact, **trailing spaces included**: `<user>@<host>'s password: `, `Enter passphrase for key '<path>': `, `(<user>@<host>) Password: ` for keyboard-interactive, and the multi-line host-key question ending `Are you sure you want to continue connecting (yes/no/[fingerprint])? `. | OpenSSH 10.2p1 (2026-09-04) | secrets.md | K7, K8, Q2, Q8 |
| SQ-061 | Tailscale SSH authenticates with the **`none`** userauth method - the tailnet ACL is the auth - and serves a Go `pkg/sftp` subsystem. sshd's own `none` method (an empty password with `PermitEmptyPasswords`) is the closest OpenSSH-side control case. | `ts-ssh`, `deb` `nopw` (2026-09-07/08) | secrets.md; `testbed/README.md` | K12, Q1 |
| SQ-062 | A **keyboard-interactive** password reaches askpass as `(<user>@<host>) Password: ` and is stored under the same `password:<user>@<hostname>:<port>` key as a plain password. | `deb-kbdint` (2026-09-04) | secrets.md | K7, Q4 |
| SQ-063 | Two hops of a chain are told apart by the **argv of the asking `ssh`**, never by the prompt text: two bastions with deliberately different passwords each got their own keychain item and their own prompt naming their own host. The argv is read with `sysctl KERN_PROCARGS2` and resolved with `ssh -G`; the hop inherits the master's askpass token. | `bastion-a`/`bastion-b`/`inner` (2026-09-04) | secrets.md | K2, Q3 |
| SQ-064 | A server can accept **both** a key and a password for the same account, which is what makes the two-pass collect connection's "your key files did not authenticate and the server accepts passwords" branch reachable. | `deb` `keypass` (2026-09-04) | secrets.md; `testbed/README.md` | K10, Q9 |

**Measurement:** the prompts were captured with an `SSH_ASKPASS` script that logged `argv[1]`
and `SSH_ASKPASS_PROMPT` and answered nothing, run against the testbed from the VM
(macOS 26.4.1 arm64, `OpenSSH_10.2p1, LibreSSL 3.3.6`, 2026-09-04). `strings /usr/bin/ssh`
gives the format strings behind them: `%s@%s's password: `,
`Enter passphrase for key '%.100s': `, `The authenticity of host '%.200s (%s)' can't be
established`, `Are you sure you want to continue connecting (yes/no/[fingerprint])? `,
`Are you sure you want to continue connecting (yes/no)? `, `Warning: the %s host key for
'%.200s' differs from the key for the IP address '%.128s'`, `Confirm user presence for key
%s %s`, `Enter PIN for %s key %s: `, `Enter PIN for '%s': `. The last three have never been
raised here: no security key was attached, so those rows of the classification table are the
format strings plus unit tests.

## Helper targets and build

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-065 | **`aarch64-unknown-freebsd` has no prebuilt `rust-std`** - `rustup target add` refuses it - so it cannot be built or even `cargo check`ed, and the helper's FreeBSD target is x86_64 only. The four musl targets need no `cross` and no C toolchain: `rust-lld` with `-C link-self-contained=yes`. | (2026-09-05) | packaging.md; gotcha 90 | — (build-time; CI) |
| SQ-066 | **One static aarch64 binary runs on both glibc and musl** and reports the same self-computed digest on each: `sshdrive-helper 0.1.0 linux/aarch64 sha256=bb786789…dbe962`, matching the manifest on both servers. | `deb` (Debian 12), `alp` (Alpine) (2026-09-05) | change-detection.md | J9 |
| SQ-067 | A server may have neither `sha256sum` nor `shasum`, which is why the deployment's fallback is the remote file's size plus running the binary with `--version` - and why **a hash the build embeds in a binary cannot be the hash of that binary**: `--version` computes the digest of its own executable at startup. That is what catches a same-size corruption on a server where `sha256sum` is available too. | (2026-09-05) | change-detection.md, security.md; gotcha 85 | J9 |
| SQ-068 | A server may have no working `mkfifo`, in which case the helper runs `</dev/null` with its roots on its argv and the wrapper is then its only kill switch. | (2026-09-05) | change-detection.md; gotcha 84 | J8 |
| SQ-069 | The **wrapper's `EXIT` trap does not run when the wrapper is `SIGKILL`ed**, which is every abrupt client kill - the case the wrapper exists for - so its relay FIFO is left behind and must be swept by the next deployment, with no age rule. A FIFO with no writer is inert. | (2026-09-05) | change-detection.md; gotcha 89 | J11 |
| SQ-070 | A `kill -9` of the client leaves **no helper on the server within 10 s**, by the helper's own 60 s stdin deadline rather than the wrapper's kill, because its stdin is the relay FIFO whose only writer was the wrapper. | `deb` (2026-09-05, 2026-09-08) | change-detection.md | J1, J11 |

## Testbed and environment traps

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-071 | **An open port is not a running server.** Docker's proxy completes the TCP handshake before sshd is listening, so readiness is the banner, not the connect. And a published port can be dead while the container is healthy. | testbed (2026-09-04) | `testbed/README.md` | — (harness) |
| SQ-072 | Containers see connections coming from the docker bridge gateway, never from the VM, so sshd logs and `Match Address` cannot tell clients apart. | testbed (2026-09-04) | `testbed/README.md` | — (harness) |
| SQ-073 | **zsh does not word-split an unquoted parameter,** so `ssh $K …` with `K="-o BatchMode=yes -i key"` passes it as one argument and every remote command fails; a zsh harness must spell `${=K}`. A latency run then "passes" the steps that check for absence. | (2026-09-05) | gotcha 98 | — (harness) |
| SQ-074 | `$TMPDIR` is shared and `sshdrive-*` there is **not** necessarily ours: the package's own test databases are `sshdrive-nested-<uuid>.sqlite` with `-wal`/`-shm` sidecars, and a name-only orphan sweep on a clean VM reported `[ fail ] control sockets  6 socket(s), 6 with no location` and would have deleted all six. Each candidate must be `lstat`ed for `S_IFSOCK`, following no links. | (2026-09-04) | ssh.md; gotcha 79 | K5, D11, P4 |
| SQ-075 | `pgrep` counts **zombies**: an `ssh` mux client killed with `-9` stays in `pgrep -f` output as `Z` until the agent reaps it, so "did I kill the master?" is unanswerable from `pgrep` alone; `ps -o stat` is the one to read. | (2026-09-04) | gotcha 56 | K6, P4, **N3** (the session budget counts by state, not by pid) |
| SQ-076 | macOS has neither `timeout` nor `gtimeout`, and **zsh has a `log` builtin** that shadows `/usr/bin/log`, so every command that touches the mount wants a wrapper and `log` must be spelled absolutely. | (2026-09-04) | cli.md; gotcha 96 | — (harness) |
| SQ-080 | **APFS refuses a filename whose bytes are not valid UTF-8**: `mkdir("latin1-caf\xff")` answers **`EILSEQ`** (errno 92). The non-UTF-8 sweep root is a real shape on a Linux or NAS server and cannot be made to exist on a Mac at all. | macOS 26.4 / APFS (2026-09-08); Linux/ext4 takes it (2026-09-08) | change-detection.md, names-and-attributes.md | **H7** (the real-filesystem half runs on Linux only; the `partitionRoots` and SFTP-wire halves run everywhere) |
| SQ-081 | **macOS's `/usr/bin/find` is BSD, not GNU findutils**: it takes `-cmin` and `-mmin`, has **no `-printf`**, and answers `--version` with `find: illegal option -- -`. A sweep row calibrated to `-printf` therefore has no `find` to run against on a Mac, and the flavour a box really has must be probed by what it *accepts*, exactly as `SQ-002` says a server's must be. | macOS 26.4 (2026-09-08); Debian findutils 4.9.0 (2026-09-08) | change-detection.md | **H4**, **H7** (both run against the flavour the host box really has) |
| SQ-082 | **XNU takes a process's short name (`p_comm`) from the interpreter binary, never from the script**, where Linux takes it from the script's own name - so a shell-script stub named `ssh` is called `dash` or `bash` on a Mac. And there is no way round it: **macOS launch constraints `SIGKILL` a copy of any system shell**, ad-hoc re-signed or not (`/bin/dash` copied and `codesign -s -`ed dies 137), so no binary named `ssh` can be produced to point a shebang at. And the name is only settled once the **script** is running: macOS's `/bin/sh` is a small launcher that re-execs `bash`, so `p_comm` reads `sh` for the first hundred-odd milliseconds (longer on a cold start) and `bash` from then on. A timer-based probe reads whichever it catches; a byte printed by the script cannot race, because `p_comm` only changes at `exec`. | macOS 26.4 (2026-09-08); Linux 6.1 (2026-09-08) | ssh.md | **K4**, **K6** (via `ControlSocket.masterProcessName`, which `FakeSSH.install()` sets to the measured name) |
| SQ-083 | **macOS's `/etc/zprofile` runs `/usr/libexec/path_helper`, which rewrites `PATH` from `/etc/paths` and `/etc/paths.d`, and zsh reads `$ZDOTDIR/.zshenv` *before* the system's `/etc/zprofile`** - so a login zsh's `PATH` is the system's list with the account's appended, and no `ZDOTDIR` can prevent it. bash is unaffected: `/etc/profile` runs `path_helper` *before* `.bash_profile`, so there the account still wins. (`-f`/`NO_RCS` would suppress the account's own file along with the system's.) | macOS 26.4 (2026-09-08); Debian zsh reads no such file (2026-09-08) | ssh.md (the login-shell snapshot) | **J14** (the zsh row runs on Linux only; bash and dash run on both) |
| SQ-084 | **A POSIX shell prints a job-status report on stderr when a foreground child dies by a signal** - `Killed`, `Terminated`, `User defined signal 1` - and only `SIGINT` and `SIGPIPE` are silent. **dash writes that report to the *command's* redirected stderr rather than to its own**, so `cmd 2>&3` sends the report to fd 3 and only `exec 2>/dev/null` around the whole session suppresses it. It is an artifact of a shell-based harness: no sshd sends it, and `SQ-011` is the claim that a signal-killed remote command says nothing at all. | dash 0.5.12, bash 5.2 (Linux), `/bin/sh` and `/bin/dash` on macOS 26.4 (2026-09-08) | security.md | **J13** (`FakeSSH.run_session` hands the session its real stderr on fd 4 and points its own at `/dev/null`) |
| SQ-085 | **`PATH_MAX` is 1024 on macOS against 4096 on Linux, and `sockaddr_un.sun_path` holds 104 bytes of which macOS's per-user `$TMPDIR` is about fifty.** A harness tree deep enough to outrun a channel's 4 MB buffer, and any control socket a scenario binds, must be sized from the box: over the first limit every `open` fails `ENAMETOOLONG` and the tree is silently empty; over the second the `bind` fails and what is left at the path is a plain file, not a socket. | macOS 26.4 (2026-09-08); Linux 6.1 (2026-09-08) | ssh.md (why `ControlPath` is never `%C`) | **H5**, **K4**, **K5** |
| SQ-086 | **A test child inherits an ignored `SIGINT` on Darwin** - SwiftPM leaves `SIGINT` ignored while a test child runs - **and an ignored `SIGPIPE` everywhere** (Foundation ignores it), and an ignored disposition survives `exec`. So neither of the two signals a shell reports silently (`SQ-084`) can be used to kill one from inside a scenario; `SIGKILL`, which can be neither caught, blocked nor ignored, is the one that behaves identically on every box. | macOS 26.4 under `swift test` (2026-09-08) | security.md | **J13** |
