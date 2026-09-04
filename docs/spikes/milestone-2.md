# Milestone 2 spike: S2, the transport

Runbook for the transport spike DESIGN.md section 12 folds into milestone 2. Section 11 has
the questions; this file has the steps, the answer the design expects, and what actually
happened. The long-form results live in `results.md`, newest first; the two entries this
runbook quotes are "2026-09-04 (assembled stack) - S2: the transport end to end" and
"2026-09-04 (night) - S2 askpass".

Every sub-question is tagged with what it needs:

| Tag | Meaning |
|---|---|
| **VM** | runs on the headless Mac VM against the Docker testbed on the Mac that hosts it, over ssh. No GUI, no hardware. |
| **real Mac** | needs a Mac somebody uses: a key agent app (1Password, Secretive), a security key in a USB port, a login keychain with `UseKeychain` items, a Tailscale tailnet, or a screen that locks and unlocks. Nothing here is reachable from the VM. |

Several of the **VM** items have a half the VM cannot reach — a live 1Password socket
behind an `IdentityAgent` question, a Homebrew `ProxyCommand` behind the login shell
snapshot. Where that happens the Result line says which half was measured and which was
not, rather than claiming the whole question.

---

## 0. Setup

### 0.1 Build and install

From the Linux side:

```
scripts/mac-build.sh signed   # sync, xcodegen, xcodebuild, then sign with the Apple
                              # Development identity and the profiles under ~/Developer
```

`signed` is not optional for S2. Everything below either reads the data-protection keychain
or is driven by a hook that does, and `keychain-access-groups` needs the embedded
provisioning profile (section 3.1); an ad-hoc build answers `errSecMissingEntitlement` to
every `debug secrets` call.

On the Mac:

```
ditto "$HOME/sshdrive/build/Build/Products/Debug/SSH Drive.app" "/Applications/SSH Drive.app"
SSHDRIVE_AGENT_ROLE=unregister "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"
open -g -a "/Applications/SSH Drive.app"
"/Applications/SSH Drive.app/Contents/MacOS/sshdrive" doctor
```

The registration is dropped and retaken because it is not self-repairing once the bundle
has been replaced (S1 f1). `ditto` over the installed bundle, never `rm -rf` followed by a
copy: a deleted bundle
leaves launchd unable to resolve the login item and `SMAppService.register()` keeps
answering success, which is the S1 f2 trap and costs an hour every time. `doctor` green is
the gate for everything below, and since 2026-09-04 it also prints the login shell snapshot
(section 6.1), which is what s2-18 reads.

### 0.2 The testbed

Bring it up on the Mac that hosts the VM, not on the VM:

```
cd testbed && docker compose up -d && docker compose ps      # wait for healthy
nc -G 3 -w 4 192.168.64.1 2201 </dev/null | head -1          # readiness is the banner
```

`testbed/README.md` has the accounts, the ports, the passwords and the `~/.ssh/config`
every `spike-*` alias below comes from; that config and a populated `known_hosts` are
already installed on the build VM. Four traps from that file are worth repeating here
because they bite in this spike specifically.

- **`bashbg` hangs anything that reads to EOF.** Its rc leaves `( sleep 300 & )` holding
  stdout, so only the closing sentinel ends the read.
- **macOS has no `timeout`.** `perl -e 'alarm(shift); exec @ARGV' 20 ssh …` is the
  substitute, and every command below that could block on a read carries it.
- **`-J` does not pass command-line `-o` flags to the hops**, so a first connection over
  the chain stops on `bastion-b`'s host key unless the hop has been reached as a
  destination once. This is exactly why the agent builds the chain itself (section 6.1).
- **Killing an `ssh` that used `-J` leaves its `-W` children behind.** `pkill -f 'ssh .*-W'`.

### 0.3 The package tests

Most of the module-level answers are `swift test`, not a session at a terminal. On the Mac:

```
cd ~/sshdrive/Packages/SSHDriveCore
swift test                          # 214 tests, 0 failures, 31 skipped without the testbed
SSHDRIVE_TESTBED=1 swift test       # 214 tests, 0 failures, 2 skipped
```

The 31 are the testbed-gated files; with `SSHDRIVE_TESTBED=1` set they run and the two that
remain are the ones nothing on this machine can satisfy. The files that carry the S2 work
are `Tests/SSHProcessTests/TestbedMasterTests.swift`,
`TestbedProxyChainTests.swift`, `TestbedShellTests.swift`, `TestbedHeartbeatTests.swift`
and `AskpassTokenTests.swift`, and `Tests/SFTPTests/SFTPIntegrationTests.swift` and
`TestbedChannelTransportTests.swift`. Individual tests are named in the Result lines below
and run with `swift test --filter <name>`.

### 0.4 The debug hooks

`docs/skeleton-notes.md` has the full syntax. The two that drive this spike:

```
sshdrive debug ssh add <name> <[user@]host[:port]> [--remote-path P]
                                                  [--identity FILE] [--jump CHAIN]
sshdrive debug ssh remove <name>

sshdrive debug secrets [store|lookup|delete|list|classify|connect]
        [--key ACCOUNT] [--destination user@host] [--port N] [--identity PATH]
        [--value V] [--prompt TEXT] [--kind confirm|none] [--command CMD]
        [--host-key-checking yes|ask|accept-new] [--jump CHAIN]
        [--purpose master|collect] [--with-key-agent]
```

`debug ssh add` writes an ssh-backed location and adds its File Provider domain, so the
transport can be driven through `~/Library/CloudStorage/SSHDrive-<name>` before milestone 3
exists. It connects with whatever the keychain already holds, so put the secrets in place
with `debug secrets store` first, and it is all-or-nothing: a location that cannot connect
is removed again rather than left in `config.json`. `debug secrets connect` spawns one real
`/usr/bin/ssh` from the agent's own environment with `SSH_ASKPASS`,
`SSH_ASKPASS_REQUIRE=force` and a freshly minted `SSHDRIVE_ASKPASS_TOKEN`, and reports the
exit status, the prompts raised, the ones answered from the keychain, and every miss with
the key it would have used. That report is the measurement for most of section C.

### 0.5 What is left on the VM between sessions

The 2026-09-04 pass left five keychain items in place on purpose, so the next session does
not have to re-collect them: `password:pw@192.168.64.1:2201`,
`passphrase:/Users/alec/.ssh/sshdrive-spike-enc`, `password:hop@192.168.64.1:2210`,
`password:hop@bastion-b:22` and `password:alec@inner:22`. List them with
`sshdrive debug secrets list` and remove one with
`sshdrive debug secrets delete --key <account>`. No File Provider domains and no locations
were left behind.

### 0.6 What this runbook does not cover

Two things that look like S2 and are not.

- **`sshdrive add` is milestone 3.** The `ssh -G` display that tells the user what the
  config resolved to, the two-pass collect connection driven from a terminal, and the
  prompts relayed to that terminal are the three things the real command adds over
  `debug ssh add`. The agent-side halves of all three are measured here (s2-13, s2-9);
  the CLI half is not, and has unit coverage only.
- **The breaker and reconnection are milestone 5.** Jittered backoff, the raised cap for a
  key agent that is not ready, the reconnect after `-O exit` at will-sleep and what the
  File Provider sees while a location is down are section 6.3 and spike S5. This runbook
  stops at the classification of an exit; what the reconnect loop then does with it is
  measured there.

---

## A. The master and its mux clients

Section 6.1. All four run against `spike-deb` (`192.168.64.1:2201`) unless a question needs
another server.

- [ ] **s2-1. The master stays in the foreground as our child with `ControlPersist=no`, and detaches with `ControlPersist=yes`** &mdash; **VM**

  ```
  cd ~/sshdrive/Packages/SSHDriveCore
  SSHDRIVE_TESTBED=1 swift test --filter testMasterWithTwoMuxClientsAndKillingOne
  ```

  and by hand, for the control case the design's claim rests on:

  ```
  /usr/bin/ssh -N -o ControlMaster=yes -o ControlPath=$TMPDIR/cp-no  -o ControlPersist=no  spike-deb &
  ps -o pid=,ppid=,command= -p $!
  /usr/bin/ssh -N -o ControlMaster=yes -o ControlPath=$TMPDIR/cp-yes -o ControlPersist=yes spike-deb
  echo "rc=$?"; ls -l $TMPDIR/cp-yes         # socket present, our ssh already gone
  ```

  Expected (section 6.1): with `ControlPersist=no` the `-N` master is the agent's own child
  for the life of the connection, so its pid can be supervised, its stderr read and its exit
  used as the disconnect signal; with `ControlPersist=yes` `ssh` forks the master into the
  background after authentication and the process we spawned exits, even under `-N`, which
  would leave the agent with nothing to watch.

  Result: **PASS on the `ControlPersist=no` half**, 2026-09-04.
  `testMasterWithTwoMuxClientsAndKillingOne` asserts the spawned master is still running as
  our child after both mux clients have been used, and the three mounts of the assembled
  pass were all supervised that way. The `ControlPersist=yes` control case was not run;
  the design's claim about it is still from the documentation.

- [ ] **s2-2. A `-N` master with SFTP and exec mux clients, and killing one client without disturbing the others** &mdash; **VM**

  ```
  cd ~/sshdrive/Packages/SSHDriveCore
  SSHDRIVE_TESTBED=1 swift test --filter TestbedMasterTests
  ```

  Expected (section 6.1): every SFTP and exec channel is a mux client with its own process,
  so a wedged channel is killed and reopened on its own without touching the connection, and
  the master outlives any one of them.

  Result: **PASS**, 2026-09-04. `testMasterWithTwoMuxClientsAndKillingOne` kills one of two
  exec channels and the other keeps answering, after which a third opens on the same master;
  `testTwoSFTPChannelsAndAnExecChannelShareOneConnection` runs two SFTP channels beside an
  exec channel on one connection and kills the bulk one without the metadata channel or the
  master noticing. `testASecondChannelOpensOnTheSameMasterAfterTheFirstIsKilled` in
  `TestbedChannelTransportTests` proves the same thing through the production
  `SFTPTransport` surface.

- [ ] **s2-3. A mux client spawned after its socket was removed exits at once, and the agent classifies that exit as master lost** &mdash; **VM**

  ```
  cd ~/sshdrive/Packages/SSHDriveCore
  SSHDRIVE_TESTBED=1 swift test --filter testMuxClientWithoutASocketExitsAtOnceAndIsMasterLost
  swift test --filter testMuxClientWithoutAChannelIsAlwaysMasterLost
  ```

  Expected (section 6.1): with `-F /dev/null`, `BatchMode=yes` and
  `ProxyCommand=/usr/bin/false` the client cannot read a config, cannot prompt and cannot
  fall back to a connection of its own, so it exits before a byte is exchanged; and a mux
  client that exits before its channel opened is always classified as master lost, never as
  an authentication failure, because the latter would stop reconnection for the location.

  Result: **PASS**, 2026-09-04, on both halves.
  `testMuxClientWithoutASocketExitsAtOnceAndIsMasterLost` covers the real client against the
  testbed and `ExitClassificationTests.testMuxClientWithoutAChannelIsAlwaysMasterLost`,
  `testAMuxClientThatDidOpenItsChannelIsClassifiedNormally` and `testChannelLimitBeatsTheMuxRule`
  cover the classifier's three cases.

- [ ] **s2-4. A host block carrying `RemoteCommand`, `RequestTTY force` and `ForkAfterAuthentication yes`** &mdash; **VM**

  The testbed's `spike-deb-shapes` alias is that host block, pointing at the same server as
  `spike-deb`.

  ```
  ssh -G spike-deb-shapes | grep -E '^(remotecommand|requesttty|forkafterauthentication|controlmaster|controlpath)'
  cd ~/sshdrive/Packages/SSHDriveCore
  SSHDRIVE_TESTBED=1 swift test --filter testSessionShapeOverrides
  ```

  Expected (section 6.1): the fixed override set (`RemoteCommand=none`, `RequestTTY=no`,
  `StdinNull=no`, `ForkAfterAuthentication=no`, `BatchMode=no`, `UpdateHostKeys=no`,
  `PermitLocalCommand=no`, `ForwardAgent=no`, `ForwardX11=no`, `ClearAllForwardings=yes`)
  keeps the master in the foreground and the mux clients working, whatever the block says.

  Result: **PASS**, 2026-09-04. `testSessionShapeOverrides` first asserts the config really
  does carry the three shapes, so the test cannot pass vacuously, then brings a master up
  against that alias and runs a mux client over it. `OptionAssemblyTests.testMasterCarriesTheWholeFixedOverrideSet`
  and `testFixedOverridesComeBeforeTheUsersOwnOptions` pin the assembly.

---

## B. The ProxyJump chain

Section 6.1. The chain is `spike-inner`, whose config carries
`ProxyJump spike-bastion-a,spike-bastion-b`, with a **different** password on each hop
(`spike-password-a`, `spike-password-b`) and key auth at the destination.

- [ ] **s2-5. A two-hop chain built by the agent as its own `ProxyCommand`, password on both hops, `ControlMaster auto` set for the bastion** &mdash; **VM**

  ```
  sshdrive debug secrets store --destination hop@192.168.64.1 --port 2210 --value spike-password-a
  sshdrive debug secrets store --destination hop@bastion-b   --port 22   --value spike-password-b
  sshdrive debug secrets store --destination alec@inner      --port 22   --value spike-password
  sshdrive debug ssh add inner spike-inner
  ps -Ao command= | grep 'ssh -N' | grep -v grep          # read the whole chain off argv
  ls -R ~/Library/CloudStorage/SSHDrive-inner/data
  ```

  Expected (section 6.1): no `ProxyJump` is ever handed to `ssh`; the agent supplies its own
  `-o ProxyCommand=…` and cancels the resolved jump with `-o ProxyJump=none` **after** it,
  recursively; `%h:%p` is doubled once for every level a hop sits below the master; every
  hop carries `ControlMaster=no` **and** `ControlPath=none`; and each hop's password prompt
  is keyed by its own `<user>@<hostname>:<port>` (section 4.2), so the two hops get
  different items.

  Result: **PASS**, 2026-09-04. The `inner` mount was driven from
  `~/Library/CloudStorage/SSHDrive-inner`: `ls -R data`, write, `cat`, rename and delete,
  all confirmed on `inner` two hops away. Both hops answered from the keychain with
  different passwords and the destination authenticated by key. `ps` on the live master
  shows all three things section 6.1 insists on: `ProxyCommand` written before
  `ProxyJump=none` at both levels, `%h:%p` doubled to `%%h:%%p` for the hop one level down,
  and `ControlPath=none` on every hop. `TestbedProxyChainTests.testTwoHopChainConnectsAndCarriesAnExecChannel`,
  `testTheChainIsResolvedAndRebuiltNotForwarded` and `testChainGivenAsUserAtHostColonPort`
  cover the same ground from the package.

- [ ] **s2-6. A hop whose bastion has `ControlPath` set in the config stays off that socket** &mdash; **VM**

  The `spike-bastion-a` block sets `ControlMaster auto` and `ControlPath ~/.ssh/cm-%r@%h-%p`
  precisely so this can be falsified. Stand the user's own master up first, then connect.

  ```
  /usr/bin/ssh -N -M -o ControlPath=~/.ssh/cm-hop@192.168.64.1-2210 spike-bastion-a &
  ssh -G -o ControlMaster=no spike-bastion-a | grep -E '^controlpath'
  cd ~/sshdrive/Packages/SSHDriveCore
  SSHDRIVE_TESTBED=1 swift test --filter testHopDoesNotAttachToALiveBastionSocket
  SSHDRIVE_TESTBED=1 swift test --filter testControlMasterNoAloneLeavesTheConfigsControlPath
  ```

  Expected (section 6.1): `ControlMaster=no` alone does **not** detach a hop from the
  socket the config names for the bastion — `ssh -G` still prints the config's
  `controlpath` under it — so only `ControlPath=none` clears it. A hop that honoured the
  config would multiplex onto the user's live master and never be asked for hop 1's
  password.

  Result: **PASS**, 2026-09-04, on both halves.
  `testControlMasterNoAloneLeavesTheConfigsControlPath` is the `ssh -G` measurement that the
  rule rests on, and `testHopDoesNotAttachToALiveBastionSocket` shows our hop still being
  asked for the password with the user's master live. The assembled pass ran the user's own
  `ssh -N -M -o ControlPath=~/.ssh/cm-hop@192.168.64.1-2210` throughout the `inner` mount
  and our hop did not attach to it.

- [ ] **s2-7. An identity path with a space and a quote inside the agent-built `ProxyCommand`** &mdash; **VM**

  The testbed's key file is `~/.ssh/spike key's copy` and the `spike-deb-spacekey` alias
  names it.

  ```
  cd ~/sshdrive/Packages/SSHDriveCore
  swift test --filter ProxyCommandQuotingTests
  # end to end, not yet run:
  sshdrive debug ssh add space spike-deb-spacekey --jump hop@192.168.64.1:2210
  ls ~/Library/CloudStorage/SSHDrive-space/
  ```

  Expected (section 6.1): the `ProxyCommand` the agent builds is run by `ssh` through
  `/bin/sh -c`, so every value in it — identity paths, verbatim `sshOptions`, the jump host
  — is single-quoted by the rule section 9.2 applies to remote scripts, and survives one
  round of quoting per level of nesting.

  Result: **answered at the module level, not end to end.**
  `ProxyCommandQuotingTests.testIdentityPathWithASpaceAndAQuoteSurvivesTwoLevels` builds the
  two-level case and `testRealShAgreesWithOurQuoting` / `testRealShAgreesAfterTwoRoundsOfQuoting`
  check the result against a real `/bin/sh` rather than against our own reading of the rule,
  and `testThreeHopChainDoublesPercentsPerLevel` covers the percent doubling that travels
  with it. A connection through `spike-deb-spacekey` with a hop under it was **not run**;
  nothing has yet put that path through a live `ProxyCommand`.

---

## C. Askpass, the token protocol and the keychain

Section 4.2. Every `debug secrets connect` below runs from the launchd-started agent with no
tty anywhere.

- [ ] **s2-8. An encrypted ed25519 key via askpass with `SSH_ASKPASS_REQUIRE=force` and the token protocol** &mdash; **VM**

  ```
  sshdrive debug secrets store --identity ~/.ssh/sshdrive-spike-enc --value spike-passphrase
  sshdrive debug secrets connect --destination alec@192.168.64.1 --port 2201 \
      --identity ~/.ssh/sshdrive-spike-enc --command 'echo AUTH-OK-PASSPHRASE'
  # the token is what authorises; both of these must fail
  SSHDRIVE_ASKPASS_TOKEN= "/Applications/SSH Drive.app/Contents/MacOS/sshdrive-askpass" "x's password: "; echo "rc=$?"
  SSHDRIVE_ASKPASS_TOKEN=made-up "/Applications/SSH Drive.app/Contents/MacOS/sshdrive-askpass" "x's password: "; echo "rc=$?"
  ```

  Expected (section 4.2): `ssh` invokes the program with the prompt text as its argument and
  reads the answer from its stdout; the program itself knows nothing and holds nothing, and
  an invocation with no token, a retired one, or one whose caller is not a descendant of the
  `ssh` it was issued to gets no answer.

  Result: **PASS**, 2026-09-04. `exitStatus 0`, `stdout "AUTH-OK-PASSPHRASE"`, `prompts 1`,
  `misses []`, the passphrase from `passphrase:/Users/alec/.ssh/sshdrive-spike-enc`. The
  same key drove the `enc` mount end to end in the assembled pass — passphrase from the
  keychain, no tty anywhere, then write, `cat`, rename and delete through Finder's own mount
  path. `sshdrive-askpass` with no token exits 1 without contacting the agent; with a made-up
  token it reaches the agent and gets
  `Error Domain=org.shirls.sshdrive.AgentError Code=2 "unknown token"` and exits 1, which
  also proves the listener hands an askpass peer the one-method askpass interface and
  nothing else. `AskpassTokenTests` covers the environment side: a fresh token per master,
  the same token inherited by every hop, none on a mux client, and the token retired at
  shutdown.

- [ ] **s2-9. What `SSH_ASKPASS_PROMPT` `ssh` sets for the host-key question** &mdash; **VM**

  ```
  printf '#!/bin/sh\nprintf "argv1=[%%s]\\nhint=[%%s]\\n" "$1" "${SSH_ASKPASS_PROMPT-UNSET}" >>/tmp/askpass.log\nexit 1\n' \
    > /tmp/logging-askpass.sh
  chmod +x /tmp/logging-askpass.sh
  : > /tmp/empty_known_hosts
  SSH_ASKPASS=/tmp/logging-askpass.sh SSH_ASKPASS_REQUIRE=force \
    perl -e 'alarm(shift); exec @ARGV' 20 \
    /usr/bin/ssh -o StrictHostKeyChecking=ask -o UserKnownHostsFile=/tmp/empty_known_hosts \
                 -o BatchMode=no spike-deb true
  cat /tmp/askpass.log

  # and what the agent makes of it, without connecting to anything:
  sshdrive debug secrets classify --prompt "The authenticity of host '[192.168.64.1]:2201 ([192.168.64.1]:2201)' can't be established."
  sshdrive debug secrets connect --destination alec@192.168.64.1 --port 2201 --host-key-checking ask
  ```

  Expected, as section 4.2 and section 4.3 were written: the question arrives with
  `SSH_ASKPASS_PROMPT=confirm`, and is relayed to the terminal during `add` and refused
  otherwise.

  Result: **answered, and the design was wrong.** 2026-09-04: the host-key question arrives
  with `SSH_ASKPASS_PROMPT` **unset**, indistinguishable by hint from a password prompt,
  because `ssh` sets the hint only for `RP_ASK_PERMISSION` (`confirm`) and `notify_start`
  (`none`) while the host-key question goes through `read_passphrase(prompt, RP_ECHO)`. An
  agent that trusted the hint would have answered a stored password to "Are you sure you
  want to continue connecting". The classifier now matches the question's own text first and
  treats the hint as corroboration; sections 4.2, 4.3 and 13 were corrected. Nothing raised
  on this VM produced `confirm` at all. The refusal path was measured too: with an empty
  `known_hosts` and `--host-key-checking ask` the agent recorded the miss, replied a
  refusal, `ssh` exited 255 with `Host key verification failed.`, the empty `known_hosts`
  stayed 0 bytes and nothing was written to the user's real one. A *changed* host key raises
  no prompt at all — `ssh` prints the banner and exits, which is the stderr path section 4.3
  already describes. Two smaller findings the same night: the passphrase prompt's `%.100s`
  truncates a long path, so the prompt text alone cannot be the keychain key and the broker
  maps the prefix back onto the asking `ssh`'s own `identityfile` list from `ssh -G`; and the
  verbatim prompt strings for password, passphrase and keyboard-interactive were captured
  with their trailing spaces and are recorded in `results.md`.

- [ ] **s2-10. What `SSH_ASKPASS_PROMPT` `ssh` sets for a FIDO user-presence notice** &mdash; **real Mac**

  With a security key plugged in and an `id_ed25519_sk` the server accepts:

  ```
  ssh-keygen -t ed25519-sk -f ~/.ssh/id_ed25519_sk
  SSH_ASKPASS=/tmp/logging-askpass.sh SSH_ASKPASS_REQUIRE=force \
    /usr/bin/ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_sk <host> true
  cat /tmp/askpass.log
  ```

  Expected (section 4.2): the notice arrives as `SSH_ASKPASS_PROMPT=none` with the text
  `Confirm user presence for key ED25519-SK SHA256:…`, is acknowledged rather than answered,
  and during `add` marks the key as touch-required so the location is refused with a message
  naming the key file and how to skip it.

  Result: **needs a real Mac** — no security key can be attached to the headless VM, so the
  user-presence and PIN rows of section 4.2's classification table are still the format
  strings pulled out of `strings /usr/bin/ssh` (`Confirm user presence for key %s %s`,
  `Enter PIN for %s key %s: `, `Enter PIN for '%s': `) plus unit tests over the classifier.

- [ ] **s2-11. An identity list whose first encrypted key has no stored passphrase and is accepted by the server** &mdash; **VM**

  ```
  # no item for the first key, and both keys offered: the enc one first (spike-* appends
  # sshdrive-spike as a second identity), so the empty answer is what moves ssh along
  sshdrive debug secrets delete --identity ~/.ssh/sshdrive-spike-enc
  sshdrive debug secrets connect --destination alec@192.168.64.1 --port 2201 \
      --command 'echo AUTH-OK'
  # the same on the wire: an askpass that answers empty (exit 0, nothing on stdout, which
  # is not the refusal of s2-9's exit 1), with -v to see what ssh decides
  printf '#!/bin/sh\nprintf "%%s\\n" "$1" >>/tmp/askpass.log\nexit 0\n' > /tmp/empty-askpass.sh
  chmod +x /tmp/empty-askpass.sh
  SSH_ASKPASS=/tmp/empty-askpass.sh SSH_ASKPASS_REQUIRE=force \
    perl -e 'alarm(shift); exec @ARGV' 20 \
    /usr/bin/ssh -v -i ~/.ssh/sshdrive-spike-enc -i ~/.ssh/sshdrive-spike \
                 -o IdentitiesOnly=yes spike-deb true 2>&1 | grep -i 'no passphrase given'
  ```

  Expected (section 4.2): the agent answers with an empty passphrase, `ssh` gives up on that
  key after its single attempt (`NumberOfPasswordPrompts=1` bounds passphrase attempts too),
  moves on to the next identity, and nothing is stopped.

  Result: **PASS**, 2026-09-04, measured with the logging askpass rather than the agent.
  `ssh` offered the encrypted key first, got an empty passphrase, logged
  `no passphrase given, try next key`, moved to `~/.ssh/sshdrive-spike` and authenticated.
  That is section 4.2's "the agent answers with an empty passphrase … and nothing is
  stopped", on the wire.

- [ ] **s2-12. A key whose passphrase lives in the login keychain through `UseKeychain`** &mdash; **real Mac**

  ```
  ssh-add --apple-use-keychain ~/.ssh/id_nas          # once, at the keyboard
  printf 'Host nas\n  UseKeychain yes\n  IdentityFile ~/.ssh/id_nas\n' >> ~/.ssh/config
  sshdrive debug secrets connect --destination alec@nas --port 22 --identity ~/.ssh/id_nas
  ```

  Expected (section 4.2): the launchd-started `ssh` reads the passphrase out of the login
  keychain without a keychain dialog, so the first pass of the collect connection can
  authenticate with `IdentityAgent=none` and still not prompt.

  Result: **needs a real Mac** — `UseKeychain` is Apple's patch to their own `ssh` reading
  the *login* keychain, and the VM's login keychain has an empty password and no such item;
  a dialog raised against a screen nobody is at is exactly what cannot be observed here.

---

## D. The collect connection and key agents

Sections 4.2 and 6.1.

- [ ] **s2-13. The two-step collect connection: `IdentityAgent=none` first against a key `ssh-agent` already holds, then the agent pass for an agent-only key** &mdash; **VM**

  First pass, against a key the agent holds:

  ```
  eval "$(ssh-agent -a /tmp/sshdrive-s2-agent)"
  ssh-add ~/.ssh/sshdrive-spike-enc                    # passphrase spike-passphrase
  sshdrive debug secrets connect --purpose collect --identity ~/.ssh/sshdrive-spike-enc \
      --destination alec@192.168.64.1 --port 2201
  sshdrive debug secrets delete --identity ~/.ssh/sshdrive-spike-enc
  sshdrive debug secrets connect --purpose collect --identity ~/.ssh/sshdrive-spike-enc \
      --destination alec@192.168.64.1 --port 2201      # now the miss, and the fall-through
  ```

  Second pass, for a key that exists only in the agent:

  ```
  ssh-keygen -t ed25519 -N '' -f /tmp/agent-only
  ssh-add /tmp/agent-only
  ssh-copy-id -i /tmp/agent-only.pub -p 2201 alec@192.168.64.1
  rm -f /tmp/agent-only                                # the private file is gone
  sshdrive debug secrets connect --purpose collect --destination alec@192.168.64.1 --port 2201
  sshdrive debug secrets connect --purpose collect --destination alec@192.168.64.1 --port 2201 --with-key-agent
  ```

  Expected (section 4.2): the first attempt runs with `-o IdentityAgent=none` so `ssh` can
  use only key files, `UseKeychain` passphrases and passwords, and every passphrase it needs
  is seen and stored; a fall-through to a password prompt is the "your key files did not
  authenticate and the server accepts passwords" branch; and only if that attempt fails does
  the second run with the agent socket, recording the location `agentDependent`.

  Result: **PASS on both passes**, 2026-09-04. First pass with the key loaded into
  `ssh-agent`: `IdentityAgent=none` raised the **passphrase** prompt rather than signing
  through the agent — `prompts 1`, `answeredFromKeychain 1`, `exitStatus 0` — and with the
  keychain item deleted the same prompt is recorded as a miss keyed
  `passphrase:/Users/alec/.ssh/sshdrive-spike-enc`, which is exactly what `add` relays to
  the terminal and then stores, after which `ssh` falls through to
  `alec@192.168.64.1's password: ` recorded as a second miss keyed by the destination: the
  section 4.2 branch, visible in the data. Second pass with a fresh ed25519 key added to the
  agent, its public half in `deb`'s `authorized_keys` and the private file deleted: first
  pass `exitStatus 255` with one password prompt and
  `Permission denied (publickey,password)`, second pass with `--with-key-agent`
  `exitStatus 0` and **zero prompts**. That is the `agentDependent` recording, end to end.
  The key and the `authorized_keys` line were removed afterwards.

- [ ] **s2-14. `none` auth against Tailscale SSH** &mdash; **real Mac**

  ```
  tailscale up --ssh                                   # on both ends
  sshdrive debug ssh add ts <user>@<host>.tail1234.ts.net
  ls ~/Library/CloudStorage/SSHDrive-ts/
  ```

  Expected (section 4.2, section 1): the `none` userauth method succeeds outright, no prompt
  of any kind reaches askpass, and nothing is stored in the keychain for the location.

  Result: **needs a real Mac** — there is no Tailscale in the compose network and none on
  the VM. The testbed's `nopw` account (empty password, `PermitEmptyPasswords`) makes sshd's
  `none` method succeed and was verified answering that way from the VM on 2026-09-04, but
  that is the same wire outcome, not the same implementation, and it was not driven through
  the agent.

- [ ] **s2-15. An `agentDependent` location whose `identityagent` socket does not exist at spawn time** &mdash; **VM**

  ```
  cd ~/sshdrive/Packages/SSHDriveCore
  swift test --filter LoginShellSnapshotTests
  # by hand, against a socket that is not there:
  printf 'Host gone\n  HostName 192.168.64.1\n  Port 2201\n  IdentityAgent /tmp/not-a-socket\n' >> ~/.ssh/config
  ssh -G gone | grep '^identityagent'
  ```

  Expected (section 6.1): before every spawn for an `agentDependent` location the agent
  connects to the key agent's socket itself, and a missing or refusing socket is a
  **transient** failure without `ssh` being run at all — because `ssh` logs a missing socket
  only at debug level, so at `LogLevel=ERROR` the failure would read as a plain
  "Permission denied (publickey)" and stop reconnection on exactly the morning this
  exception exists for. Which socket is the one `ssh -G` resolves as `identityagent`, with
  `~` already expanded, and only when that is unset or reads `SSH_AUTH_SOCK` does the
  snapshot's variable apply.

  Result: **PASS at the module level**, 2026-09-04.
  `LoginShellSnapshotTests.testIdentityAgentSocketSelection` covers the `ssh -G` versus
  `SSH_AUTH_SOCK` precedence, `testMissingSocketIsATransientFailureWithSshNeverRun` proves
  no `ssh` is spawned at all, and `testAPathThatIsNotASocketRefuses` covers the path that
  exists but is not a socket; `ExitClassificationTests.testKeyAgentNotReadyIsRetriedWithARaisedCap`
  is the classification that follows. The reason the pre-spawn probe carries the whole load
  got **stronger** on 2026-09-04, see s2-16. A live 1Password or Secretive socket is s2-17
  and needs a real Mac.

- [ ] **s2-16. `agent refused operation` retried rather than stopping** &mdash; **VM**

  Three states of a key agent, and what `ssh` says about each at `LogLevel=ERROR`:

  ```
  eval "$(ssh-agent -a /tmp/s2-agent)"; ssh-add ~/.ssh/sshdrive-spike
  ssh-add -x                                            # locked
  SSH_AUTH_SOCK=/tmp/s2-agent /usr/bin/ssh -o LogLevel=ERROR -o IdentitiesOnly=yes \
      -o PubkeyAuthentication=yes -o IdentityAgent=/tmp/s2-agent spike-deb true; echo "rc=$?"
  ssh-agent -k                                          # killed, socket left behind
  SSH_AUTH_SOCK=/tmp/s2-agent /usr/bin/ssh -o LogLevel=ERROR -o IdentityAgent=/tmp/s2-agent spike-deb true
  rm -f /tmp/s2-agent                                   # socket gone
  SSH_AUTH_SOCK=/tmp/s2-agent /usr/bin/ssh -o LogLevel=ERROR -o IdentityAgent=/tmp/s2-agent spike-deb true
  cd ~/sshdrive/Packages/SSHDriveCore && swift test --filter testKeyAgentNotReadyIsRetriedWithARaisedCap
  ```

  Expected (section 6.1): `agent refused operation` on stderr is what 1Password and
  Secretive produce between login and their first unlock, and it is retried with the network
  backoff, its cap raised from 60 s to 5 minutes, rather than stopping reconnection.

  Result: **answered, and section 6.1's conclusion is stronger than it was written.**
  2026-09-04: `agent refused operation` **could not be provoked on this VM at all**.
  OpenSSH's own `ssh-agent` locked with `ssh-add -x` does not refuse a signature — it
  reports *no identities*, and `ssh` exits with a plain
  `Permission denied (publickey,password)` — and a socket whose agent has been killed and a
  socket path that no longer exists both produce that same line at `LogLevel=ERROR`. So
  stderr distinguishes **none** of the three key-agent states, not only the missing-socket
  one, and the pre-spawn `IdentityAgentCheck` probe of s2-15 is the only signal for a locked
  agent as well as an absent one. The `agent refused operation` string stays in the
  classifier because 1Password and Secretive are documented to produce it, and neither is
  installable on this VM; sections 6.1 and 13 say so now. That the string is classified
  transient with the raised cap rather than as an authentication failure is
  `testKeyAgentNotReadyIsRetriedWithARaisedCap`.

- [ ] **s2-17. A first-pass location on a Mac whose config names 1Password through `IdentityAgent`** &mdash; **real Mac**

  ```
  grep -n IdentityAgent ~/.ssh/config
  ssh -G <host> | grep '^identityagent'
  sshdrive add <host>            # milestone 3; until then: debug ssh add + debug secrets
  sshdrive show <host> | grep -i 'agent'
  sshdrive agent restart         # then watch 1Password for an approval prompt
  ```

  Expected (section 6.1): a location that passed the collect connection's first pass carries
  `IdentityAgent=none` on every runtime spawn, master and hops alike, so 1Password is never
  consulted, raises no approval prompt on an unattended reconnect, and the passphrase stored
  precisely so the mount could come up before any agent is unlocked is what gets used.

  Result: **needs a real Mac** — 1Password and Secretive cannot be installed on the headless
  VM, and the whole question is whether a GUI app stays silent. The option assembly half is
  covered (`OptionAssemblyTests.testAgentDependentLocationKeepsTheConfigsIdentityAgent` and
  `ProxyCommandQuotingTests.testAgentDependentHopKeepsTheConfigsIdentityAgent` show the
  override going on for a first-pass location and coming off for an `agentDependent` one);
  what is unmeasured is the app's behaviour.

---

## E. The login shell snapshot

Section 6.1.

- [ ] **s2-18. A key reachable only through an `SSH_AUTH_SOCK` exported in `.zshrc`, and a `ProxyCommand` that calls a Homebrew tool** &mdash; **VM**

  ```
  sshdrive doctor | grep -A4 -i snapshot        # what the agent will hand ssh
  launchctl print gui/$(id -u)/org.shirls.sshdrive.agent | grep -i path

  cp ~/.zshrc ~/.zshrc.s2-backup 2>/dev/null || true
  eval "$(ssh-agent -a /tmp/sshdrive-s2-agent)"
  echo 'export SSH_AUTH_SOCK=/tmp/sshdrive-s2-agent' >> ~/.zshrc
  sshdrive agent restart
  sshdrive doctor | grep -i auth_sock           # ours, not launchd's Apple listener
  # restore afterwards:
  mv ~/.zshrc.s2-backup ~/.zshrc

  cd ~/sshdrive/Packages/SSHDriveCore
  swift test --filter LoginShellSnapshotTests
  SSHDRIVE_TESTBED=1 swift test --filter testLoginShellSnapshotCommandUnderEveryShell
  ```

  Expected (section 6.1): a launchd agent's `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin` and
  its `SSH_AUTH_SOCK` is the system `ssh-agent`'s, so the agent replaces both from a login
  shell snapshot taken with `<shell> -ilc` around a sentinel-delimited `env -0`, at agent
  start and again on every `add`, `test` and `passwd`. Only those two variables are taken.

  Result: **PASS**, 2026-09-04. `sshdrive doctor` prints the snapshot and reports `/bin/zsh`
  and the Homebrew `PATH` (`/opt/homebrew/bin` and the rest), which launchd's own
  `/usr/bin:/bin:/usr/sbin:/sbin` does not have. With
  `export SSH_AUTH_SOCK=/tmp/sshdrive-s2-agent` appended to a throwaway `~/.zshrc` and the
  agent restarted, `doctor` reported that socket in place of launchd's Apple `ssh-agent`
  listener (`/var/run/com.apple.launchd.*/Listeners`), and the s2-13 agent pass then
  authenticated through it; `.zshrc` was restored afterwards. The **`ProxyCommand` that
  calls a Homebrew tool was not itself run** — what was measured is the `PATH` that makes it
  work, not a `cloudflared` or `tailscale` hop. `TestbedShellTests.testLoginShellSnapshotCommandUnderEveryShell`
  runs the snapshot command line under zsh, fish, tcsh, dash and bash on `deb-shells`, and
  `LoginShellSnapshotTests.testABackgroundChildHoldingStdoutDoesNotCostTheSnapshot` covers
  the closing sentinel against the `bashbg` shape.

---

## F. The SFTP client

Section 6.2. The client's correctness against `sftp-server` is not an S2 row question and is
covered by `SFTPIntegrationTests` on both Debian and Alpine; what the row asks for is the
number.

- [ ] **s2-19. Throughput of our SFTP client with pipelining against `sftp(1)` and `rsync`, on a 1 GB file and on 10,000 small files** &mdash; **VM**

  The 1 GB file is opt-in. On the compose host:

  ```
  # in testbed/compose.yaml, set BIG_FILE: "1" on the deb service, then
  docker compose up -d --force-recreate deb
  ```

  On the VM:

  ```
  cd ~/sshdrive/Packages/SSHDriveCore
  SSHDRIVE_TESTBED=1 swift test --filter testThroughputAgainstSftpOneGigabyteFile
  SSHDRIVE_TESTBED=1 swift test --filter testLargeSequentialRead

  # the two comparisons the harness does not make:
  perl -e 'alarm(shift); exec @ARGV' 600 rsync -e 'ssh -F ~/.ssh/config' \
      spike-deb:data/big/1g.bin /dev/null
  perl -e 'alarm(shift); exec @ARGV' 900 rsync -a spike-deb:data/many/ /tmp/many/
  ```

  Expected (section 6.2): sixteen requests in flight at the largest size the server will
  take is what gives `sftp(1)`-class throughput. OpenSSH 9.2 and 9.7 both answer 255 KiB
  reads and writes inside a 256 KiB packet, so the window is about 4 MiB; without
  `limits@openssh.com` the chunk falls back to 32 KB and sixteen of those is 512 KiB.

  Result: **partly answered, 2026-09-04; the 1 GB file and `rsync` are not run.** A
  `SSHDRIVE_TESTBED=1` run against `spike-deb` prints, from the integration tests:

  ```
  [spike-deb] limits: maxPacketLength 262144, maxReadLength 261120,
                      maxWriteLength 261120, maxOpenHandles 20475
  [deb] pipelined write 64 MiB in 0.49 s = 129.6 MiB/s
  [deb] pipelined read  64 MiB in 0.25 s = 252.1 MiB/s
  [S2]  64 MiB: sshdrive 0.25 s (252.1 MiB/s); sftp(1) 0.68 s (94.6 MiB/s)
  [deb] readdir data/many: 10000 entries in 0.10 s
  ```

  So the client is **faster than `sftp(1)`** on this link, which is what "`sftp(1)`-class
  throughput" was asking for, and the 255 KiB / 256 KiB numbers section 6.2 quotes are
  confirmed against OpenSSH 9.2 on the wire. What is still missing is the 1 GB file
  (`data/big/1g.bin` is not seeded, so `testThroughputAgainstSftpOneGigabyteFile` skips —
  it is one of the two skips a `SSHDRIVE_TESTBED=1` run reports), the `rsync` comparison,
  and a 10,000-small-file *transfer* run as opposed to the `readdir` of that directory.
  Note before believing any of these: a container on the same Mac is a floor, not a
  measurement of a NAS over a network.

---

## G. The deadline and the re-arm

Sections 4.2 and 5.6. Both of these are about a human being present, which is why neither is
reachable from the VM.

- [ ] **s2-20. The 60 s authentication deadline firing against an agent-held key that waits for a touch** &mdash; **real Mac**

  With a Secretive or 1Password key that requires an approval, or a FIDO key loaded into
  `ssh-agent`:

  ```
  sshdrive agent restart          # then do not touch the key
  log stream --predicate 'subsystem BEGINSWITH "org.shirls.sshdrive"' --style compact \
    | grep -i deadline
  sshdrive status <name>
  ```

  Expected (section 4.2): if the master's control socket has not appeared 60 s after `ssh`
  was started — and `ssh` creates it only once authentication has succeeded (section 6.1) —
  the agent kills it. For an `agentDependent` location that is treated as an authentication
  failure and reconnection stops, with `sshdrive status` saying "authentication did not
  complete within 60 s; a key agent may be waiting for a touch or approval"; for any other
  location, which runs with `IdentityAgent=none` and so can have nothing waiting for a
  human, the same timeout is a slow server retried with the network backoff.

  Result: **needs a real Mac** — provoking it needs a key agent that actually waits for a
  human, which is a touch on a security key or an approval in a GUI app, and neither exists
  on the VM. The deadline itself is implemented (`SSHMaster.Configuration.authenticationDeadline`,
  60 s, waiting on the control socket's appearance) and the classification either side of it
  is `ExitClassificationTests.testDeadlineDependsOnWhetherAKeyAgentCouldBeHoldingItUp`; what
  is unmeasured is the deadline firing against a real touch.

- [ ] **s2-21. The screen-unlock and present-user re-arm firing exactly once each after a deadline stop, and a request with input idle over 30 s not firing it** &mdash; **real Mac**

  After a location has been stopped by s2-20's deadline:

  ```
  sshdrive status <name>                       # stopped, domain still connected
  ls ~/Library/CloudStorage/SSHDrive-<name>/    # a request while you are at the keyboard
  # lock the screen (ctrl-cmd-q), wait, unlock; then leave the Mac alone for a minute and
  # touch the mount from a remote shell, which is the "idle over 30 s" case:
  ssh <this mac> 'ls ~/Library/CloudStorage/SSHDrive-<name>/'
  ```

  Expected (section 4.2, section 5.6): the domain is **not** disconnected for a deadline
  stop, so File Provider requests keep arriving; two things re-arm exactly one attempt — the
  `com.apple.screenIsUnlocked` distributed notification, and a request for that domain
  arriving while `CGEventSource.secondsSinceLastEventType` is under 30 s and
  `CGSSessionScreenIsLocked` says the screen is unlocked, evaluated at most once a minute.
  An `agentDependent` location makes no attempt at all while the screen is locked, wake
  included. A refused prompt is never re-armed.

  Result: **needs a real Mac, and the code is not written yet** — the re-arm belongs to
  milestone 5 (section 12, "the deadline re-arm"), so there is nothing here to measure even
  on a Mac with a screen: milestone 2 stops at the deadline itself firing and being
  classified. When it is written, this needs a screen that locks, a keyboard somebody is
  touching, and the s2-20 deadline stop to have happened first. Nothing about presence can
  be observed on a headless VM: `secondsSinceLastEventType` over an ssh session measures
  nothing.
