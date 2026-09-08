# Server quirks

Measured behaviour of remote servers — sshd and Tailscale SSH, SFTP implementations, login
shells, `find` flavours and OpenSSH's own client — that SSH Drive depends on. Format and rules:
`README.md`. Source of truth: `docs/spikes/results.md`, with `testbed/README.md` for the service
each was measured against.

`ServerModel.ServerProfile` is built from these rows: a profile is a set of values for them, and
the testbed's twelve services are twelve profiles.

**Implemented on Linux, 2026-09-08** (`docs/testing-architecture.md` §8 steps 6 and 7).
`Sources/ServerModel` keys a rule on each of the ids below, and `Tests/ServerModelTests`
defends it with no Mac, no VM, no network and no testbed:
`ServerProfileScenarios` (the profile table, the three extension sets, the prompt strings,
and the assertion that every id the model keys on is a row of *this file*),
`SFTPWireScenarios` (**L1**, **M2**, **D7**, **J8**, **J11**, **K12**, **N2** and the
`SQ-027`/`SQ-028`/`SQ-029` wire rules, over a real SFTP v3 wire server),
`ShellScenarios` (**J4**, **J5**, **J6**, **J7**, **N4**, against real shells),
`HeartbeatScenarios` (**J1** - including the bite-proof that the pre-2026-09-08 wrapper
really does kill a sibling session - **J2**, **J3**),
`SweepScenarios` (**H1**, **H2**, **H3**, **H6**),
`TransportScenarios` (**K1**, **K2**, **K7**, **K9**, **K10**, **K11**, **K13**, **K14**,
**N3**, **J12**, against a stub `ssh` that `SSHMaster` spawns exactly as it spawns the real
one). A scenario needing a shell this box lacks - `busybox`, `fish`, `tcsh` - skips with a
named reason rather than pretending, and **J1's bite-proof skips on macOS**: the sessions
are put in one shared process group there too, but a `kill -TERM 0` reaches nothing but the
sender's own child, so the row says so instead of passing for the wrong reason. Linux is
the gate.

## `find` and the sweep

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-001 | **No busybox has `find -cmin`.** BusyBox 1.36.1 answers `find: unrecognized: -cmin`, rc 1; it has `-mmin` and `-newer FILE` only. This is the ordinary NAS path, not a legacy case. | `alp`, `alp-nocmin` (2026-09-04) | results 2026-09-04 (M6) s7-3; §6.4; §13 2026-09-04; gotcha 15 | H1, H2, H3 |
| SQ-002 | **busybox `find --version` prints an error and exits 0.** A flavour probe keyed on the exit status therefore calls every busybox server GNU and every sweep on it fails outright with nothing on stdout. The probe must read the `busybox` banner and the `-cmin` answer. | `alp` (2026-09-04) | results 2026-09-04 (M6) s7-3; §8.1, §6.4; §13 2026-09-04; gotcha 73 | H1 |
| SQ-003 | busybox `find` has no `-printf` either (`find: unrecognized: -printf`, rc 1). | `alp` (2026-09-04) | results 2026-09-04 (M6) s7-3 | H2 |
| SQ-004 | A busybox `-cmin` does not lose a field, it **fails the whole sweep**, so `SweepPlan` refuses `-cmin`/`-printf` on a busybox flavour a second time even when the probe claims them. | `alp` (2026-09-04) | results 2026-09-04 (M6) s7-3; gotcha 73 | H2 |
| SQ-005 | **`-mmin` misses a ctime-only change.** A `chmod` on a file whose mtime was set back to 2020: found by GNU `-cmin`, missed by `-mmin` (1 hit vs 0). The fallback loses ctime-only changes and nothing else. | `deb`, `alp` (2026-09-04) | results 2026-09-04 (M6) s7-3; §6.4; gotcha 15 | H3 |
| SQ-006 | **`-cmin` and `-printf` each cost a `stat` per entry, and that is what a sweep spends.** Over a million files, warm: 204 ms with `-print0` and no time test, 850-900 ms adding `-cmin`, 1.6-3.0 s adding `-printf`. An ordinary incremental sweep of that tree returning one record is **876 ms**. | `deb`, GNU findutils (2026-09-04) | results 2026-09-04 (M6) s7-2; §6.4; §13 2026-09-04; gotcha 70 | H8 (shape only; the milliseconds are VM-only) |
| SQ-007 | **`find` has no portable `--`,** so a top-level directory named `-name` would be read as an option and take the whole sweep with it. Every root is spelled `./name` and the prefix stripped before `RelativePath`. | (design + testbed `weird/`) | §6.4; §13 2026-09-04; gotcha 71 | H6 |
| SQ-054 | **A container cannot have its clock skewed:** Docker has no time namespace and every container shares the host's clock, so a server whose clock disagrees with ours has never been tested against a real skew. | testbed (2026-09-04) | results 2026-09-04 (M6) s7-4; `testbed/README.md` | H4 (the only coverage there will ever be) |

## Process lifetime and remote command teardown

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-008 | **A bare background process started by a session survives an abrupt client kill.** A `sleep &` was still running three minutes after the client was `SIGKILL`ed. sshd reaping the session does not reach a child that has left the foreground job. | `deb-shells`, `deb`, `alp` (2026-09-04) | results 2026-09-04 (M6) s7-6; §6.4; §13 2026-09-04; gotcha 69 | J2 |
| SQ-009 | **`ClientAliveInterval` changes nothing about SQ-008.** Measured with it unset, at 15/3, and on busybox: identical outcome. The heartbeat wrapper is the only mechanism there is, not a workaround for a misconfiguration. | `deb` (15/3), `deb-shells` (unset), `alp` (unset) (2026-09-04) | results 2026-09-04 (M6) s7-6; §6.4; §13 2026-09-04; gotcha 69 | J3 |
| SQ-010 | **Tailscale SSH puts every session of every client in `tailscaled`'s process group.** A `kill -TERM 0` from one session therefore signals all of them: measured with three concurrent sessions, one `kill -TERM 0` killed the two bystanders **and the connections under them** (exit 255 after 3 s and 6 s). `tailscaled` itself is root and survives. | `ts-ssh` (2026-09-08) | results 2026-09-08; §6.4, §13 2026-09-08; gotcha 100 | **J1** |
| SQ-012 | OpenSSH's sshd gives each session a **session and process group of its own**, so `kill … 0` there has a blast radius of exactly that session — which is why the bug in SQ-010 was invisible for four milestones. | `deb` (2026-09-08) | results 2026-09-08 "The fix" | J1 |
| SQ-011 | A remote command **killed by a signal** makes `ssh` return **255 with nothing on stderr**, indistinguishable at the exit code from a mux-client error. | `ts-ssh` (2026-09-08) | results 2026-09-08 | J13 |
| SQ-077 | **The helper's stream does not survive its connection, and it is the connection that usually kills it.** A master `kill -9`ed, an agent restart, a wake, a network path change and a 90-second stall all end the exec channel; the helper on the server then exits on its own 60 s heartbeat timeout. Nothing about any of that is a statement about whether the server can run a helper. | `deb` (2026-09-08) | results 2026-09-08 (addendum, the helper stream); §6.4; §13 2026-09-08 | F7, F8, F9 |
| SQ-078 | **A stall of more than 60 s kills the helper even though nothing is broken.** With the master and its mux clients `SIGSTOP`ped for 90 s and then continued, the helper had already exited (missed pings) and the exec channel came back exit 255 — with the master still alive, so the agent saw a stream that died on a *live* connection. | `deb` (2026-09-08) | results 2026-09-08 (addendum, scenario c) | F8 |
| SQ-079 | **A channel open that fails because the master died is not distinguishable from a refused session by anything but the master.** `ssh` prints `mux_client_request_session: session request failed` only for a real refusal, but a dead master produces `Control socket connect: No such file or directory`, `mux_client_hello_exchange: … Broken pipe` or nothing at all — and every one of those was read as "the server allows one channel at a time". Whether the `-N` master is still running is the test. | `deb` (2026-09-08) | results 2026-09-08 (addendum, scenario d); §6.1; §13 2026-09-08 | K13, K14 |
| SQ-032 | Writing over a **running** executable fails `ETXTBSY` / `Text file busy`, which is why an upload must go to a temp name and rename. | `deb` (2026-09-05) | results 2026-09-05 (M9) "A corrupted binary"; §6.4; gotcha 89 | **J8**, J10 |
| SQ-033 | `mkdir`'s attributes go through the **server's umask**, so a mode of 0700 that was asked for can land as 0755; the mode must be asserted with a `setstat` afterwards. | `deb` (2026-09-05) | results 2026-09-05 (M10) addendum item 3; §6.4; §13 2026-09-05 | J8 |

## Shells and remote scripts

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-015 | **rc files print on non-interactive startup**, in every shell shape: `.bashrc` for bash, `.zshenv` for zsh (read for every invocation), `config.fish` for `fish -c`, `.cshrc` for tcsh. Everything before the sentinel must be discarded. | `deb-shells` (2026-09-04) | results 2026-09-04 (M6) s7-5; §9.2; gotcha 13 | J5 |
| SQ-016 | An rc file can leave a **background child holding stdout**, so EOF never arrives on the channel and only the closing sentinel ends the read. Any reader that waits for EOF hangs. | `deb-shells` `bashbg` (2026-09-04) | results 2026-09-04 (M6) s7-5; `testbed/README.md`; §9.2 | J5 |
| SQ-017 | **Debian's `/bin/sh` is dash**, which an exec channel runs, so the heartbeat wrapper's `sleep`-and-mtime watchdog branch is the *ordinary* Linux path rather than a fallback; busybox ash takes the `read -t` branch. | `deb`, `alp` (2026-09-04) | §6.4; §13 2026-09-04; gotcha 36 | J6 |
| SQ-018 | **dash answers `;;` with `Syntax error: ";;" unexpected`** and the channel dies on the spot. A relay fragment that already ends in `;` written as `… \|\| break; <relay>; done` produces exactly that. | `deb` dash, `alp` busybox ash (2026-09-05) | results 2026-09-05 (M9) "Three smaller things"; §6.4; §13 2026-09-05; gotcha 84 | J7 |
| SQ-019 | `.` with no argument is a POSIX **special builtin** whose failure ends a non-interactive shell outright, which is why the wrapper's stamp file is `touch`ed and never `:`-redirected. | (POSIX + 2026-09-04) | §6.4; §13 2026-09-04; gotcha 36 | J6 |
| SQ-020 | **`printf "\0<sentinel>"` reads `\0` and the octal digits after it as one character,** so a sentinel beginning with a digit silently loses its first bytes and the marker is never found. Every sentinel's NUL must be its own `printf`. | (2026-09-04) | §6.1, §9.2; §13 2026-09-04; gotcha 34 | J4 |
| SQ-013 | A **`ForceCommand internal-sftp` account may answer an exec channel with a plain sentence** — `This service allows sftp connections only.` — rather than SFTP framing. Both shapes mean "no shell access (ForceCommand)", never "shell output unusable". | `deb-shells` `forcesftp` (2026-09-04) | results 2026-09-04 (M6) s7-7; §9.2; §13 2026-09-04; gotcha 37 | N4, J12 |
| SQ-014 | An **external `sftp-server` behind a noisy rc file** puts the rc output in front of the SFTP `VERSION` reply; `sftp(1)` fails with "Received message too long". The client must fall back to running `sftp-server` on an exec channel. | `deb-extsftp` `extnoisy` (2026-09-04) | results 2026-09-04 (M6) s7-5, s7-7; §9.2; `testbed/README.md` | N4 |
| SQ-050 | Six directory names of the shape `$(echo pwned)`, `quote'name`, `space in name`, `*star*`, `[bracket]`, `back\slash` work as sweep roots, each returning its own file and creating no `pwned` file — the `set --` single-quoting rule holding under real shells. | `deb` `weird/` (2026-09-04) | results 2026-09-04 (M6) s7-5; §9.2 | H6, L7 |

## SFTP: implementations, extensions and the wire

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-024 | **Go `pkg/sftp` advertises exactly `hardlink@openssh.com`, `posix-rename@openssh.com` and `statvfs@openssh.com`** and nothing else; that fingerprint identifies it. No version advertises `fsync@openssh.com` or `limits@openssh.com`, so an `upgrade:` line naming either asks the user to replace their SSH server for nothing. | `ts-ssh` (2026-09-08) | results 2026-09-08 "The capability report now names the server"; §8.1; §13 2026-09-08; gotcha 101 | K12, N2 |
| SQ-025 | OpenSSH's own `sftp-server` advertises `posix-rename`, `statvfs`, `fstatvfs`, `hardlink`, `fsync`, `lsetstat`, `limits`, `expand-path`, `copy-data`, `home-directory`, `users-groups-by-id` — anything carrying `fsync`/`lsetstat`/`limits`/`expand-path` is OpenSSH. | `deb` OpenSSH 9.2p1 (2026-09-05) | results 2026-09-05 (M10) addendum; §8.1 | K12, N2 |
| SQ-026 | Alpine's `internal-sftp` offers the **same** OpenSSH extensions as the external `sftp-server` (`posix-rename`, `fsync`, `lsetstat`, `limits`), so nothing in the write protocol degrades there. | `alp` (2026-09-04) | results 2026-09-04 (M4) "busybox and internal-sftp" | N2 |
| SQ-027 | **`limits@openssh.com` sizes the request, not the window.** It says nothing about how many requests may be outstanding; the pipeline depth of sixteen is the client's own. Measured: `maxPacketLength 262144`, `maxReadLength/maxWriteLength 261120`, `maxOpenHandles 20475`. | `deb` (2026-09-04) | results 2026-09-04 (S2) throughput; §6.2; §13 2026-09-04; gotcha 38 | N2 |
| SQ-028 | **SFTP v3 carries nine status codes and no errno**: `ENOSPC`, `EEXIST`, `ENOTEMPTY` and `EXDEV` all arrive as a bare `FAILURE`, so a second question (`lstat`, `statvfs`, `readdir`) is the only way to tell them apart. | (protocol + measurement) | §6.2; §13; gotcha 24 | D3, L7 |
| SQ-029 | OpenSSH's `SSH2_FXP_SYMLINK` takes its two paths in the **opposite order from the draft**. | (protocol) | §6.2; gotcha 24 | M1, **L1** |
| SQ-030 | **SFTP `opendir` follows a symlink.** A directory swapped on the server for a link to `/etc` is read straight through, and eighty names outside the account's tree land in the index. Every listing must re-`lstat` its own directory before `readdir`. | `deb` (2026-09-04, S3 deferred containment) | results 2026-09-04 (M3 part 1) "S3's deferred containment test"; §9.1; §13 2026-09-04; gotcha 41 | **L1** |
| SQ-031 | **SFTP v3's `readdir` carries attributes but no link target,** so every symlink a listing reports costs a `readlink` before its row can be built. | `deb` (2026-09-04) | results 2026-09-04 (M4) S8; §5.7, §6.2; §13 2026-09-04; gotcha 54 | M2 |
| SQ-034 | A server's plain `rename` may refuse an existing name or may overwrite it; busybox + `internal-sftp` reports `renameRefusesAnExistingName: true` and needs no preflight, and the probe is what decides. | `alp` (2026-09-04) | results 2026-09-04 (M4) "busybox and internal-sftp"; §5.5 | D7 |
| SQ-051 | A directory of 10,000 entries `readdir`s in 0.10 s on the wire; sixteen requests in flight at the server's own 255 KiB read size gave 252 MiB/s reading and 129 MiB/s writing against `sftp(1)`'s 94 MiB/s. | `deb` (2026-09-04) | results 2026-09-04 (S2) throughput | — (VM/testbed only) |

## OpenSSH client behaviour

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-035 | **`ssh` ends every stderr log line with CRLF, and in Swift `"\r\n"` is one `Character`,** so `split(separator: "\n")` finds no separator in `ssh -v` output at all: the whole transcript is one "line". Line endings must be normalised on **unicode scalars** before splitting. | `ts-ssh` via OpenSSH 10.2p1 (2026-09-08) | results 2026-09-08 "One assumption that failed"; §8.1; §13 2026-09-08; gotcha 102 | K11 |
| SQ-036 | `remote software version <x>` is printed only at **`DEBUG1` and above**. Masters run at `LogLevel=ERROR` and a mux client speaks to the master's socket, so the collect connection is the only `ssh` that can read the server's identification string. | (2026-09-08) | results 2026-09-08; §8.1, §6.1; §13 2026-09-08; gotcha 101 | K12 |
| SQ-037 | A **mux client never speaks to the server**: it speaks to the master's control socket, so it sees no banner and no version. | (2026-09-04) | results 2026-09-04 (M3 part 1) "MaxSessions"; §6.1; §13 2026-09-04 | K3, K12 |
| SQ-038 | **`-o ProxyJump=none` written before `-o ProxyCommand=…` silently discards the ProxyCommand.** readconf takes the first setting of each keyword and `ProxyJump none` marks the jump host as set; the master then resolves the inner hostname itself and dies `Could not resolve hostname`. | OpenSSH 10.2p1 (2026-09-04) | results 2026-09-04 night "An OpenSSH ordering trap"; §6.1; §13 2026-09-04; gotcha 33 | **K1** |
| SQ-039 | `ssh` **percent-expands a `ProxyCommand` before `/bin/sh -c` sees it**, so a nested hop's `%h`/`%p` must be doubled once per level it sits below the master (`%%h:%%p` at hop *n-1*); without that, hop 1 dials the destination. | (2026-09-04) | results 2026-09-04 (S2) "The two-hop chain"; §6.1; §13 2026-09-04; gotcha 33 | K2 |
| SQ-040 | `ControlMaster=no` alone still attaches to the config's socket; a hop needs **`ControlPath=none`** as well. | (2026-09-04) | §6.1; gotcha 4 | K2 |
| SQ-041 | With `ControlPersist` set, `ssh` **forks away** and the agent loses the pid, the stderr and the exit signal; the master must run `-N` with `ControlPersist=no`. | (design + measurement) | §6.1; gotcha 2 | K4 |
| SQ-042 | Without `-F /dev/null -o BatchMode=yes -o ProxyCommand=/usr/bin/false`, a mux client whose socket is missing opens a **second, unsupervised connection** instead of failing. A mux client that exits before its channel opened is always "master lost", never an auth failure. | (2026-09-04) | §6.1; gotcha 3 | K3 |
| SQ-043 | A **restarted location can hold two masters**: the second finds the first's socket in place, prints `ControlSocket already exists, disabling multiplexing` and runs **without a socket at all**, so a socket-based sweep cannot see it. The command line (`ControlPath=$TMPDIR/sshdrive-`) is the only way to find it. | (2026-09-05) | results 2026-09-05 (M10) "agent stop, SIGTERM and the orphan sweep"; §6.1; §13 2026-09-05 | K6 |
| SQ-044 | An orphan master whose socket has **already been unlinked** cannot be reached by `ssh -O exit` at all; only its pid can. | (2026-09-04, 2026-09-05) | results 2026-09-04 (S2) "One trap this pass found"; §6.1; §13 2026-09-05 | K6 |
| SQ-045 | A `-J` chain needs the **jump host's** key in `known_hosts` already: `-o StrictHostKeyChecking` on the command line does not reach the `-W` children, only a `~/.ssh/config` alias does. | testbed (2026-09-04) | `testbed/README.md`; CLAUDE.md testbed traps | — (testbed only) |
| SQ-046 | Killing an `ssh`/`sftp` that used `-J` **leaves its `-W` children alive**, holding the pipe open — the same orphan problem as our own masters. | testbed (2026-09-04) | `testbed/README.md` | K6 |
| SQ-047 | **The host-key question reaches askpass with `SSH_ASKPASS_PROMPT` unset,** exactly like a password prompt: `ssh` sets the hint only for `RP_ASK_PERMISSION` and `notify_start`, and the host-key question goes through `read_passphrase(prompt, RP_ECHO)`. Classifying on the hint would answer a stored password to "Are you sure you want to continue connecting". | OpenSSH 10.2p1 (2026-09-04) | results 2026-09-04 night; §4.2, §4.3; §13 2026-09-04; gotcha 6 | **K7** |
| SQ-048 | `Enter passphrase for key '%.100s': ` **truncates**, so a path over 100 bytes reaches askpass cut short and the prompt text alone can never be the keychain key; the prefix must be mapped onto the asking `ssh`'s own `identityfile` list. | OpenSSH 10.2p1 (2026-09-04) | results 2026-09-04 night; §4.2; §13 2026-09-04; gotcha 6 | K8 |
| SQ-049 | A **changed** host key raises no prompt at all under `StrictHostKeyChecking=ask`: `ssh` prints the REMOTE HOST IDENTIFICATION HAS CHANGED banner and exits. Only an *unknown* host asks. | OpenSSH 10.2p1 (2026-09-04) | results 2026-09-04 night; §4.3 | K7 |
| SQ-052 | **stderr distinguishes no key-agent state.** A missing socket, a dead socket and a *locked* agent all exit with the same bare `Permission denied (publickey,password)` at `LogLevel=ERROR`; OpenSSH's own agent locked with `ssh-add -x` reports *no identities* rather than refusing. The pre-spawn socket probe is the only signal. | OpenSSH 10.2p1 (2026-09-04) | results 2026-09-04 (S2) "agent refused operation"; §6.1; §13 2026-09-04; gotcha 40 | K9 |
| SQ-053 | An **empty answer skips an identity**: `ssh` logs `no passphrase given, try next key` and moves on, which is what makes a refusal safe. | OpenSSH 10.2p1 (2026-09-04) | results 2026-09-04 night | K9 |
| SQ-021 | **`MaxSessions 2` leaves exactly one spare channel** beside the metadata SFTP channel: master + metadata + bulk is already at the limit, so the bulk channel is dropped and the spare is kept for exec (sweep, probe, helper), which cannot share. | `deb-maxsess` (2026-09-04) | results 2026-09-04 (M3 part 1) "MaxSessions"; §6.1; §13 2026-09-04; gotcha 44 | N3, J12 |
| SQ-022 | **A channel is proved open only by completing the SFTP handshake on it.** `ssh` spawns successfully whether or not the session was granted; only the refusal on stderr, or a handshake that never lands, tells the two apart. | `deb-maxsess` (2026-09-04) | results 2026-09-04 (M3 part 1); §6.1; gotcha 44 | N3 |
| SQ-023 | The agent **never sees a server banner** on the connections it makes, so a capability cache cannot be keyed on one; it is keyed per location and invalidated by an explicit re-probe. | (2026-09-04) | results 2026-09-04 (M3 part 1); §6.1; §13 2026-09-04 | N2 |

## Auth shapes

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-060 | The prompt strings are exact, **trailing spaces included**: `<user>@<host>'s password: `, `Enter passphrase for key '<path>': `, `(<user>@<host>) Password: ` for keyboard-interactive, and the multi-line host-key question ending `Are you sure you want to continue connecting (yes/no/[fingerprint])? `. | OpenSSH 10.2p1 (2026-09-04) | results 2026-09-04 night "The prompt strings" | K7, K8 |
| SQ-061 | Tailscale SSH authenticates with the **`none`** userauth method — the tailnet ACL is the auth — and serves a Go `pkg/sftp` subsystem. sshd's own `none` method (an empty password with `PermitEmptyPasswords`) is the closest OpenSSH-side control case. | `ts-ssh`, `deb` `nopw` (2026-09-07/08) | results 2026-09-08; `testbed/README.md` | K12 |
| SQ-062 | A **keyboard-interactive** password reaches askpass as `(<user>@<host>) Password: ` and is stored under the same `password:<user>@<hostname>:<port>` key as a plain password. | `deb-kbdint` (2026-09-04) | results 2026-09-04 (M3 part 2) "The seven scenarios" | K7 |
| SQ-063 | Two hops of a chain are told apart by the **argv of the asking `ssh`**, never by the prompt text: two bastions with deliberately different passwords each got their own keychain item and their own prompt naming their own host. | `bastion-a`/`bastion-b`/`inner` (2026-09-04) | results 2026-09-04 night; results 2026-09-04 (M3 part 2); §4.2 | K2 |
| SQ-064 | A server can accept **both** a key and a password for the same account, which is what makes the two-pass collect connection's "your key files did not authenticate and the server accepts passwords" branch reachable. | `deb` `keypass` (2026-09-04) | results 2026-09-04 (S2); `testbed/README.md` | K10 |

## Helper targets and build

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-065 | **`aarch64-unknown-freebsd` has no prebuilt `rust-std`** — `rustup target add` refuses it — so it cannot be built or even `cargo check`ed, and the helper's FreeBSD target is x86_64 only. The four musl targets need no `cross` and no C toolchain: `rust-lld` with `-C link-self-contained=yes`. | (2026-09-05) | results 2026-09-05 (M9) "Four assumptions that failed"; §10.1; §13 2026-09-05; gotcha 90 | — (build-time; CI) |
| SQ-066 | **One static aarch64 binary runs on both glibc and musl** and reports the same self-computed digest on each. | `deb` (Debian 12), `alp` (Alpine) (2026-09-05) | results 2026-09-05 (M9) "The mount proofs" | J9 |
| SQ-067 | A server may have neither `sha256sum` nor `shasum`, which is why the deployment's fallback is the remote file's size plus running the binary with `--version` — and why **a hash the build embeds in a binary cannot be the hash of that binary**: `--version` computes the digest of its own executable at startup. | (2026-09-05) | results 2026-09-05 (M9); §6.4, §9; §13 2026-09-05; gotcha 85 | J9 |
| SQ-068 | A server may have no working `mkfifo`, in which case the helper runs `</dev/null` with its roots on its argv and the wrapper is then its only kill switch. | (2026-09-05) | results 2026-09-05 (M9); §6.4; §13 2026-09-05; gotcha 84 | J8 |
| SQ-069 | The **wrapper's `EXIT` trap does not run when the wrapper is `SIGKILL`ed**, which is every abrupt client kill — the case the wrapper exists for — so its relay FIFO is left behind and must be swept by the next deployment. A FIFO with no writer is inert. | (2026-09-05) | results 2026-09-05 (M9) "Three smaller things"; §6.4; §13 2026-09-05; gotcha 89 | J11 |
| SQ-070 | A `kill -9` of the client leaves **no helper on the server within 10 s**, by the helper's own 60 s stdin deadline rather than the wrapper's kill, because its stdin is the relay FIFO whose only writer was the wrapper. | `deb` (2026-09-05, 2026-09-08) | results 2026-09-05 (M9) "An abrupt client kill"; results 2026-09-08 | J1, J11 |

## Testbed and environment traps

| id | statement | measured on | source | scenarios |
|---|---|---|---|---|
| SQ-071 | **An open port is not a running server.** Docker's proxy completes the TCP handshake before sshd is listening, so readiness is the banner, not the connect. And a published port can be dead while the container is healthy. | testbed (2026-09-04) | `testbed/README.md`; CLAUDE.md testbed traps | — (harness) |
| SQ-072 | Containers see connections coming from the docker bridge gateway, never from the VM, so sshd logs and `Match Address` cannot tell clients apart. | testbed (2026-09-04) | `testbed/README.md` | — (harness) |
| SQ-073 | **zsh does not word-split an unquoted parameter,** so `ssh $K …` with `K="-o BatchMode=yes -i key"` passes it as one argument and every remote command fails; a zsh harness must spell `${=K}`. A latency run then "passes" the steps that check for absence. | (2026-09-05) | results/CLAUDE.md gotcha 98 | — (harness) |
| SQ-074 | `$TMPDIR` is shared and `sshdrive-*` there is **not** necessarily ours: the package's own test databases are `sshdrive-nested-<uuid>.sqlite` with `-wal`/`-shm` sidecars, and a name-only orphan sweep reported six "orphaned sockets" on a clean install and would have deleted them. Each candidate must be `lstat`ed for `S_IFSOCK`. | (2026-09-04) | results 2026-09-04 (M6) "Three smaller things"; §6.1; §13 2026-09-04; gotcha 79 | K5 |
| SQ-075 | `pgrep` counts **zombies**: an `ssh` mux client killed with `-9` stays in `pgrep -f` output as `Z` until the agent reaps it, so "did I kill the master?" is unanswerable from `pgrep` alone; `ps -o stat` is the one to read. | (2026-09-04) | results 2026-09-04 (M4) "Three smaller things"; gotcha 56 | K6, **N3** (the session budget counts by state, not by pid) |
| SQ-076 | macOS has neither `timeout` nor `gtimeout`, and **zsh has a `log` builtin** that shadows `/usr/bin/log`, so every command that touches the mount wants a wrapper and `log` must be spelled absolutely. | (2026-09-04) | results 2026-09-04 S1(e); §8; gotcha 96 | — (harness) |
