# Milestone 5 spike: S5, offline hardening

Runbook for the spike DESIGN.md section 12 folds into milestone 5. Section 11's S5 row has
the questions; this file has the steps, the answer the design expects, and a **Result**
line for what actually happened. The long-form entry is in `results.md` under
"2026-09-04 (milestone 5)".

Everything here runs on the headless Mac VM against the Docker testbed on the Mac that
hosts it, over ssh.

| Tag | Meaning |
|---|---|
| **VM** | the headless VM plus the testbed. Everything below is this unless marked otherwise. |
| **host** | needs a command run on the *Mac* that hosts the VM (`docker compose`), which this session could not do. |
| **screen** | needs `screencapture`; Screen Recording is already granted to `/usr/libexec/sshd-keygen-wrapper` on this VM (see `results.md`, "what Finder actually draws"). |

---

## 0. Setup

### 0.1 Build and install

From the Linux side:

```
scripts/mac-build.sh test       # 381 package tests
scripts/mac-build.sh signed
```

**`mac-build.sh` rsyncs with `--delete` and `build/` does not exist on the Linux side, so
every run deletes the Mac's build directory.** Run `signed` *last*: a `test` run after it
removes the app that was about to be installed, and `ditto` then fails with "Cannot get the
real path for source". That cost a cycle on 2026-09-04.

On the Mac:

```sh
ditto "$HOME/sshdrive/build/Build/Products/Debug/SSH Drive.app" "/Applications/SSH Drive.app"
sshdrive agent restart          # never `launchctl kill` + `open -g`; see milestone-4.md 0.1
```

### 0.2 macOS has no `timeout`

Never `ls` a mount, and never run an `ssh`, without a deadline. This runbook installs a
`~/bin/timeout` that is a six-line perl `fork`/`alarm`/`exec`, so every command below can be
written the ordinary way:

```sh
cat > ~/bin/timeout <<'EOF'
#!/usr/bin/perl
use strict; use warnings;
my $secs = shift or die "usage: timeout <seconds> command...\n";
my $pid = fork(); die "fork: $!" unless defined $pid;
if ($pid == 0) { exec @ARGV or die "exec: $!"; }
$SIG{ALRM} = sub { kill "TERM", $pid; sleep 1; kill "KILL", $pid; waitpid($pid, 0); exit 124; };
alarm $secs; waitpid($pid, 0); alarm 0; exit($? >> 8);
EOF
chmod +x ~/bin/timeout
```

### 0.3 The location

One location is enough for S5: every question is about the system's behaviour, not the
server's. `deb` (2201, Debian, OpenSSH `sftp-server`).

```sh
ssh -i ~/.ssh/sshdrive-spike -p 2201 alec@192.168.64.1 '
  rm -rf ~/m5 && mkdir -p ~/m5/sub
  echo original > ~/m5/edit.txt
  echo hello    > ~/m5/note.txt
  head -c 3000000 /dev/urandom > ~/m5/big.bin
  echo a > ~/m5/sub/a.txt'

sshdrive add --nickname m5 --identity ~/.ssh/sshdrive-spike \
  --remote-path /home/alec/m5 alec@192.168.64.1:2201
```

### 0.4 Simulating an outage from inside the VM

A VM guest cannot take its host's link down and cannot stop its host's containers, so
nothing below is a true link-down. Six substitutes, in order of how much of the stack they
exercise:

| How | What it stands in for | Command |
|---|---|---|
| kill the master | the connection dying under us, silently | `kill -9 <pids from ps>` |
| `sshdrive debug breaker --drop` | the same, cleanly (`-O exit`) | `sshdrive debug breaker m5 --drop` |
| `kill -STOP` the master and its mux clients | a stalled network: the socket is up, nothing answers | `pkill -STOP -f sshdrive-<id8>` … `pkill -CONT -f …` |
| `debug fault --unreachable on` | a server that is down: every **connect attempt** fails, so the breaker opens on the ordinary path and every call after that fails fast | `sshdrive debug fault m5 --unreachable on` |
| `debug fault --connect-hang MS` | a server that accepts the TCP connection and then takes its time - section 6.3's bounded wait, on its own | `sshdrive debug fault m5 --connect-hang 20000` |
| `debug fault --transport-hang MS` | a network that has gone away without saying so: every **call** stalls, the connection is fine | `sshdrive debug fault m5 --transport-hang 60000` |
| `debug fault --connect-failure <c>` | which of section 6.1's classifications the attempt reports; `authenticationDeadline` is the only way to reach section 4.2's re-arm on a VM with no key agent, no FIDO key and no screen | `--unreachable on --connect-failure authenticationDeadline` |

**`--unreachable` fails the attempt, not the call, and the difference is the whole point.**
The first shape of this hook failed the transport call directly, which short-circuits the
breaker: `failFastCalls` stayed at zero, no attempt was ever made, and the fault was testing
itself. Fixed 2026-09-04; if a measurement here ever shows `attempts` not moving, that is
the bug to look for.

**`pgrep` counts zombies** and a restarted location can hold two masters (milestone 4), so
"did I kill the master?" is read from `ps -o pid,stat,command` and not from `pgrep` alone.
Orphans from earlier sessions (ppid 1, socket already unlinked) cannot be reached by
`-O exit` at all and have to be killed by hand.

**A stop is sticky.** After any step that ends in `stopped: …` - anything using
`--connect-failure authenticationDeadline` - every later call fails fast in milliseconds and
the next measurement silently reads nothing. `sshdrive debug breaker m5 --connect` is what
clears it, and it is worth running between steps.

**What a real link-down would still add**, for whoever has the host to hand:
`docker compose stop deb` in `testbed/` on the Mac gives a server that completes the TCP
handshake and then refuses, which is the only way to see the `ConnectTimeout=15` and
connection-refused branches of the exit classifier under the breaker rather than under a
synthetic failure; and taking the VM's interface down is the only way to see
`NWPathMonitor` report an unsatisfied path for real rather than through
`sshdrive debug power path-down`. Neither changes an answer below - the breaker sees the
same classification either way - but both would close the last gap between "the fault says
the attempt failed" and "the attempt failed".

### 0.5 The instruments

Three hooks carry every measurement in this runbook.

```sh
sshdrive debug calls m5 [--limit N] [--reset]   # every File Provider call, with the gap
                                                # since the previous call of the same kind
sshdrive debug breaker m5 [--drop] [--reset] [--connect] [--quiet-recovery on|off]
sshdrive debug power [will-sleep|did-wake|path-down|path-up]
sshdrive debug presence                         # section 4.2's presence test as the agent reads it
sshdrive debug rearm m5 [--request]             # section 4.2's two triggers, by hand
sshdrive debug row m5 <path> [--forget] [--content-version V]
```

`debug calls` is what answers every "how long does the system wait before calling again"
question: the agent records an `arrived` entry for each XPC method the moment it lands and a
second entry when it replies, and prints `sincePreviousSameCall` for each.

---

## 1. Writes after `.serverUnreachable` (S5, first question)

### s5-1. How long does the system retry a write after `.serverUnreachable`?

```sh
sshdrive debug calls m5 --reset
sshdrive debug fault m5 --unreachable on
echo edited-while-offline > ~/Library/CloudStorage/SSHDrive-m5/edit.txt
sshdrive debug materialized m5 --pending      # the item should be in the pending set
sleep 720
sshdrive debug calls m5 --limit 400
```

Expected (section 5.6): the system stores the file locally, marks it "waiting to upload"
and calls `modifyItem` again on retry, for ever - the agent fails fast until it can connect.

**Result: for ever, on a doubling backoff with no ceiling in sight.** The gaps between
`modifyItem` arrivals for the same item were 5.50, 10.56, 20.30, 43.03, 79.36, 153.23 and
331.30 seconds - five and a half minutes, ten minutes into the outage. **Each retry arrives
on a freshly launched extension instance**: an `indexReady` lands in the same millisecond
as every `modifyItem`. The item sat in the pending set throughout and the server was
untouched.

### s5-2. Does `signalErrorResolved(.serverUnreachable)` wake the flush? Does `signalEnumerator` alone?

The recovery normally sends both. `--quiet-recovery on` makes a reconnect send neither, so
each can be sent by hand and timed separately.

```sh
sshdrive debug breaker m5 --quiet-recovery on
sshdrive debug fault m5 --unreachable off      # connects; sends nothing
sleep 30 ; sshdrive debug calls m5             # did anything arrive on its own?
sshdrive debug signal m5                       # signalEnumerator(workingSet) alone
sleep 30 ; sshdrive debug calls m5
sshdrive debug signal m5 --error-resolved      # signalErrorResolved(.serverUnreachable) alone
sleep 30 ; sshdrive debug calls m5
```

**Result: `signalErrorResolved` does it in 20 ms; nothing else does it at all.**
Reconnecting with no signal: 75 s, nothing. `signalEnumerator(.workingSet)` alone: 60 s,
nothing. `signalErrorResolved(.serverUnreachable)`: `modifyItem` arrived 20 ms later, the
upload went through and the pending set emptied. Section 5.6's "`signalEnumerator` alone is
the fallback" is **wrong** and has been corrected; there is no fallback.

---

## 2. Requests while every call fails fast (S5, second question)

### s5-3. Do requests still reach the extension while the domain is connected but every call fails fast?

This is what section 4.2's request re-arm depends on: the domain is **not** disconnected
for a deadline stop, so the requests that carry the trigger have to keep arriving.

```sh
sshdrive debug fault m5 --unreachable on
sshdrive debug calls m5 --reset
timeout 60 ls -R ~/Library/CloudStorage/SSHDrive-m5 ; timeout 30 cat …/note.txt
sleep 60
sshdrive debug calls m5 --limit 200
```

**Result: yes for the work that needs the server, and the domain stays connected.** During
one deadline stop the journal recorded 6 `fetchContents` and 4 `createItem` arrivals with
`failFastCalls: 7`, while `fileproviderctl dump` showed **no** `permanently disconnected`
marker on the domain - unlike the agent-missing case of s5-5. What does **not** reach the
extension is the walk itself: see s5-9.

---

## 3. The fetch retry interval (S5, third question)

### s5-4. How long does the system wait after `.serverUnreachable` from `fetchContents` before calling again?

This, and not our breaker, is what bounds the spinner Finder shows when a fetch arrives
during a reconnect (section 6.3).

```sh
sshdrive debug evict m5 big.bin                 # so a read has to fetch
sshdrive debug fault m5 --unreachable on
sshdrive debug calls m5 --reset
timeout 20 cat ~/Library/CloudStorage/SSHDrive-m5/big.bin > /dev/null   # fails
sleep 300
sshdrive debug calls m5 --limit 200             # gaps between fetchContents arrivals
```

**Result: it never calls again.** One `fetchContents`, one `.serverUnreachable`, and
`cat: …: Operation timed out` immediately - no spinner, because there is no wait. Seven
minutes of watching produced no second call. A second `cat` does produce a second call, so
the item is not poisoned; the system simply has no retry of its own for a fetch. The
question's premise ("that, not our breaker, bounds the spinner") is therefore false: **our
breaker is the only thing that bounds anything here**, and the spinner exists only while a
call waits for a connect attempt (s5-13).

---

## 4. The agent's mach service (S5, fourth question)

### s5-5. What does the extension see when the mach service is unavailable, and does `disconnect(reason:)` work from inside the extension?

The login item is what launchd starts the agent from, and `SSHDRIVE_AGENT_ROLE=unregister`
is the only thing that clears its record (S1(f)).

```sh
sshdrive agent stop
SSHDRIVE_AGENT_ROLE=unregister "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"
launchctl print gui/$(id -u)/org.shirls.sshdrive.agent    # should be gone
log stream --predicate 'subsystem == "org.shirls.sshdrive"' --style compact &
timeout 30 ls ~/Library/CloudStorage/SSHDrive-m5
timeout 30 cat ~/Library/CloudStorage/SSHDrive-m5/note.txt
fileproviderctl dump | grep -A3 -i disconnect
# and back:
open -g -a "SSH Drive"
```

Expected (section 5.2): the extension calls `NSFileProviderManager.disconnect(reason:)` on
its own domain with the agent-missing message and answers `.serverUnreachable`; anything
already cached keeps working; the disconnect is lifted on the next successful connection.
If `disconnect(reason:)` cannot be called from inside the extension, the message lives only
in `sshdrive doctor`.

**Result: it can be called, and it works.** `launchctl print` says
`Could not find service "org.shirls.sshdrive.agent"`, and `fileproviderctl dump` shows the
domain as `+ (⏹  permanently disconnected)` with
`NSFileProviderErrorDomainDisconnectionStateKey=4` and the item-level error
`FP -1004 … domain:serverUnreachable`. The directory listing still works (replica) and a
**write** still succeeds and queues; a fetch is `ETIMEDOUT`. `open -g -a "SSH Drive"`
brought the agent back, the disconnect was lifted, and the queued create was on the server
with its contents. Section 5.2's message can therefore be shown by the extension and does
not have to live only in `doctor`.

---

## 5. A held `enumerateItems` (S5, fifth question)

### s5-6. Does the system time out an `enumerateItems` that takes the full 60 s the breaker may hold a call for, and what does it do to the extension?

```sh
sshdrive debug fault m5 --transport-hang 60000
sshdrive debug calls m5 --reset
timeout 120 ls ~/Library/CloudStorage/SSHDrive-m5/sub     # a folder listed before
sshdrive debug calls m5 --limit 50                        # how long did the call live?
log show --last 5m --predicate 'subsystem == "org.shirls.sshdrive"' --style compact | tail -40
sshdrive debug fault m5 --transport-hang 0
```

**Result: no timeout at all.** Against a second location added and never listed:

```
12:01:43.053  enumerateItems  arrived
12:02:43.240  enumerateItems  60186.8 ms   2 item(s)
ls exit=0 after 61s
```

The system waited the whole 60.19 s, took the answer, and the extension process was still
alive afterwards. Section 6.3's bounded wait may use the full authentication deadline.

---

## 6. A pending edit and the working set (S5, sixth question)

### s5-7a. What does the system do with a pending local edit when the item, or its parent, is reported deleted through the working set?

`debug row --forget` deletes the row and its subtree with a deletion anchor, which is
exactly what the extension reports when a listing says the item has gone (section 5.3, no
tombstones). Nothing is touched on the server.

```sh
sshdrive debug fault m5 --unreachable on
echo pending-edit > ~/Library/CloudStorage/SSHDrive-m5/edit.txt
sshdrive debug materialized m5 --pending          # confirm it is pending
sshdrive debug row m5 edit.txt --forget           # "the server says it is gone"
sleep 30
sshdrive debug materialized m5 --pending
timeout 20 ls -la ~/Library/CloudStorage/SSHDrive-m5
```

Then the parent form, with `sub/a.txt` pending and `sub` forgotten.

**Result: the edit is re-offered as a `createItem`, which then collides for ever.** The
file stays in the mount with the **local** content and stays in the pending set; the
pending `modifyItem` becomes a `createItem` for the same bytes; and because the path is
still there on the server - the deletion was wrong, which is the case the guard exists for
- that create is answered `.filenameCollision`, which the system retries for ever with no
alert (section 5.5, S3). Observed at 11:51:54 and again at 11:57:21, still going. No bytes
are lost and nothing is ever resolved: the mount shows the new content, the server keeps the
old, the user is told nothing, and the item has a new identifier so any pin or tag on it is
gone. **The mass-deletion guard must hold deletions of pending items**; section 6.4 says so
now.

### s5-7b. And when the item comes back with a content version the system cannot match?

This is what the reconcile walk produces for a pending item (section 5.3).

```sh
sshdrive debug row m5 edit.txt --content-version 999-999-99
sleep 30
sshdrive debug materialized m5 --pending
timeout 20 cat ~/Library/CloudStorage/SSHDrive-m5/edit.txt
```

**Result: not measured; left for the next pass.** Running s5-7a first forgets the row, and
`--content-version` needs one, so the two halves have to be run against separate files or in
the other order. What it would add is bounded: the identifier does not change in this case,
so the create-versus-modify finding above does not apply to it.

---

## 7. `.noSuchItem` versus `.cannotSynchronize` (S5, seventh question)

### s5-8. What does the system do with an item whose `fetchContents` fails each way?

The mass-deletion guard (section 6.4) needs `.cannotSynchronize` to leave the item in
place, where `.noSuchItem` would delete the user's file.

```sh
sshdrive debug evict m5 note.txt
sshdrive debug fault m5 --fetch-error cannotSynchronize
timeout 20 cat ~/Library/CloudStorage/SSHDrive-m5/note.txt ; echo "exit=$?"
timeout 20 ls -la ~/Library/CloudStorage/SSHDrive-m5      # is note.txt still there?

sshdrive debug fault m5 --fetch-error noSuchItem
timeout 20 cat ~/Library/CloudStorage/SSHDrive-m5/note.txt ; echo "exit=$?"
timeout 20 ls -la ~/Library/CloudStorage/SSHDrive-m5      # and now?
sshdrive debug fault m5 --fetch-error none
```

**Result: `ESTALE` versus `ETIMEDOUT`, and neither removes the item.**

| Fault | What the reader gets | The item |
|---|---|---|
| `.cannotSynchronize` | `Operation timed out` (`ETIMEDOUT`) | still listed |
| `.noSuchItem` | `Stale NFS file handle` (`ESTALE`) | still listed, after 60 s **and** after a working-set signal |

The rule that `.noSuchItem` deletes the user's file is about `item(for:)` (section 5.2), not
about `fetchContents`. The guard's preference for `.cannotSynchronize` therefore rests on
the message the user sees. Both were reversible: clearing the fault and re-reading returned
the content.

---

## 8. The replica while every enumeration fails (S5, eighth question)

### s5-9. Is a `readdir` and `lstat` walk of the mount served from the replica while every enumeration returns `.serverUnreachable`?

The reconcile stall of section 5.3 depends on it: the reconcile walks the mount and calls
`getIdentifierForUserVisibleFile(at:)` while the extension answers `.serverUnreachable` to
everything else.

```sh
timeout 60 ls -R ~/Library/CloudStorage/SSHDrive-m5      # warm the replica first
sshdrive debug fault m5 --unreachable on
timeout 60 find ~/Library/CloudStorage/SSHDrive-m5 -type f -exec ls -l {} \; ; echo "exit=$?"
sshdrive debug calls m5 --limit 100
```

**Result: yes, and it reaches the extension not at all.** `ls -R` returned the whole tree
with exit 0 and `stat` of a dataless file answered, with **zero** `enumerateItems` arrivals
in the journal - a folder is enumerated once, ever (section 6.5), so the walk is the
system's replica answering. That is exactly what the reconcile stall of section 5.3 needs.

---

## 9. Sleep and wake (section 6.1)

### s5-10. Does the VM honour `pmset sleepnow`, and are the masters dropped at will-sleep?

```sh
ps -o pid,stat,command -ax | grep 'sshdrive-' | grep -v grep
pmset sleepnow ; echo "exit=$?"
sleep 20
sshdrive debug power                 # willSleep / didWake counters
sshdrive debug breaker m5
```

If the VM does not sleep, the same two handlers are driven by hand and the runbook says so:

```sh
sshdrive debug power will-sleep
sshdrive debug power did-wake
```

**Result: the VM does not honour it.** `pmset sleepnow` answers
`Unable to sleep system: error 0xe00002e2`, exit 71, on a `VirtualMac2,1`; `pmset -g` shows
`sleep 1 (sleep prevented by powerd)` with powerd's own "Prevent sleep while display is on"
assertion held. `IORegisterForSystemPower` itself succeeds on this VM (`debug power` reports
`registered: true`), so what is unproven is that macOS delivers the messages, not what the
agent does with them. Driven by hand:

| Step | Result |
|---|---|
| `will-sleep` | both masters gone (`-O exit`), both locations `offline (idle)`, **no** reconnect scheduled |
| `did-wake` | new masters within 8 s, `connected`, `reconnects` incremented |
| `path-down` | `hasNetworkPath false`, state `no network path`, a read fails fast with no socket opened |
| `path-up` | reconnected, `reconnects` incremented |

The counters `debug power` prints stay at zero when the hook is used, because the hook calls
what the IOKit callback calls rather than the callback itself.

---

## 10. The deadline re-arm (section 4.2)

### s5-11. Do the screen-unlock and present-user triggers fire exactly once each after a deadline stop, and does a request with input idle over 30 s not fire it?

A headless VM has no screen to lock, and its console session reports an input-idle time
that only grows, so `SSHDRIVE_PRESENCE_OVERRIDE=idle=<s>,locked=<0|1>` in the agent's
environment is what stands in for a hand on the keyboard. The re-arm state machine itself is
covered by `DeadlineRearmTests` with an injected clock; what this step proves is that the
agent's own wiring - the distributed notification, the presence read, and the one attempt
that follows - is connected.

```sh
launchctl setenv SSHDRIVE_PRESENCE_OVERRIDE "idle=45,locked=0" ; sshdrive agent restart
sshdrive debug presence                     # userIsPresent should be false
# force a deadline stop: an agentDependent location whose key agent never answers
sshdrive debug rearm m5                     # the unlock trigger
sshdrive debug rearm m5 --request           # the present-user trigger, with idle 45
launchctl setenv SSHDRIVE_PRESENCE_OVERRIDE "idle=2,locked=0" ; sshdrive agent restart
sshdrive debug rearm m5 --request           # and now with idle 2
launchctl unsetenv SSHDRIVE_PRESENCE_OVERRIDE
```

**`launchctl setenv` does not work.** It sets the value in the user's session but the agent
started from the bundle's `LaunchAgents` plist does not inherit it, even across
`sshdrive agent restart`: `debug presence` keeps reporting `overridden: false` and the
machine's real idle time. Write the file instead - it needs no restart:

```sh
echo "idle=45,locked=0" > ~/Library/Group\ Containers/RWGDZAYBM8.org.shirls.sshdrive/presence-override
```

and force the stop with the fault that produces the right classification:

```sh
sshdrive debug fault m5 --unreachable on --connect-failure authenticationDeadline
```

**Result: every rule of section 4.2 held.**

| Step | Result |
|---|---|
| the attempt fails `authenticationDeadline` | `stopped: authenticationDeadline`, `rearmArmed: true`; `sshdrive show` says "offline (stopped: authenticationDeadline)" |
| a request with input idle **45 s** | no attempt; `presenceEvaluations` +1, `rearmRequestUsed` false |
| a request 5 s later, idle now 2 s | no attempt and **no presence read at all** - the once-a-minute rule |
| a request 65 s later, idle 2 s | one attempt; `presenceEvaluations` +1 |
| the screen-unlock notification | one attempt, `state: connecting`, without reading presence at all |
| `locked=1` | `userIsPresent false` |
| the domain, throughout | **not** disconnected; `fetchContents` and `createItem` kept arriving |

Each new deadline stop re-arms both triggers again, which is section 4.2 as written, so
"exactly once" is per stop and not per lifetime.

---

## 11. The two proofs on a real mount

### s5-12. An edit made while the master is dead is flushed after reconnect

```sh
ps -o pid,stat,command -ax | grep "sshdrive-" | grep -v grep     # find the master(s)
kill -9 <every master pid>
echo flushed-after-reconnect > ~/Library/CloudStorage/SSHDrive-m5/edit.txt
sshdrive list                       # offline
sshdrive debug materialized m5 --pending
sshdrive debug breaker m5 --reset   # the wake path: reset and connect
sleep 20
ssh -i ~/.ssh/sshdrive-spike -p 2201 alec@192.168.64.1 'cat ~/m5/edit.txt'
```

### s5-13. A fetch arriving during a reconnect resolves within the section 6.3 bound

The bound is the attempt's own remaining authentication deadline, at most 60 s - not the
system's own retry interval, which s5-4 measures.

```sh
sshdrive debug evict m5 big.bin
kill -9 <master pids>                       # nothing connected, no backoff owed
( timeout 90 cat ~/Library/CloudStorage/SSHDrive-m5/big.bin > /dev/null ; echo "read exit=$?" ) &
sshdrive debug breaker m5                   # should say "connecting", waitedCalls > 0
wait
```

### s5-14. **screen** The Finder-visible spinner

```sh
sshdrive debug breaker m5 --connect            # a stop left over from s5-11 fails everything fast
sshdrive debug evict m5 big.bin
open ~/Library/CloudStorage/SSHDrive-m5 ; osascript -e 'tell application "Finder" to activate'
screencapture -x ~/m5-shots/20-idle.png
sshdrive debug fault m5 --connect-hang 25000
kill -9 <master pids>
( timeout 90 cat ~/Library/CloudStorage/SSHDrive-m5/big.bin > /dev/null ) &
sleep 5 ; screencapture -x ~/m5-shots/21-t5.png
sleep 8 ; screencapture -x ~/m5-shots/22-t13.png
sleep 8 ; screencapture -x ~/m5-shots/23-t21.png
wait ; screencapture -x ~/m5-shots/24-done.png
```

**Result (s5-12): flushed 20 ms after the signal.**

```
11:37:44  write exit=0, pending count 1, server still says "before-the-outage"
          sshdrive list: mounted  offline (backing off for 4 s after 3 failure(s))
11:38:24  46 s later: pending count still 1, server unchanged
11:38:30  the server comes back
11:38:30.911  modifyItem -> modified
11:38:42  server: written-while-the-master-was-dead
```

**Result (s5-13): both reads waited for the one attempt and both succeeded.**

```
waitedCalls 3, failFastCalls 0
read B  exit=0 after 21s      fetchContents 17520.7 ms   6 bytes
read A  exit=0 after 21s      fetchContents 20555.4 ms   3000000 bytes
```

Bounded by the attempt's own remaining 60 s, not by any retry of the system's - which per
s5-4 does not exist. Separately, the first read after a **silent** master death now succeeds
in 1 s rather than failing, because a read that meets a dead connection is retried once
through the breaker (section 6.3 rule 4).

**Result (s5-14): a static circular progress ring, for the length of the connect.** While
the fetch waits, the item's status column shows a circular progress indicator where the
other, dataless items show the cloud-with-a-down-arrow; the row stays selected, no alert
appears, and after the fetch the badge is gone entirely. The frames at t+5 s, t+13 s and
t+21 s are byte-identical, so it is a progress ring rather than an animation, and it is the
whole of what the user sees for a 21-second reconnect. Shots in `~/m5-shots/`.

**Two traps.** A stop left over from an earlier step (`stopped: authenticationDeadline`)
makes every read fail fast in a second and the whole recipe measures nothing - clear it with
`debug breaker --connect` first. And `--transport-hang` stalls the **call**, which is not
what this step wants: `--connect-hang` stalls only the attempt, which is section 6.3's rule
3 on its own.
