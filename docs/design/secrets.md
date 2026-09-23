# Secrets and host keys

The agent runs `ssh` with no tty, so every prompt `ssh` raises goes to our askpass program, which
holds nothing and relays the prompt to the agent. The agent answers from the keychain, relays it to
the terminal during `add`, or refuses. Secrets are collected once, at `add`, by a connection the
agent itself makes; host keys stay entirely in the user's `known_hosts`.

## The askpass environment

Every `ssh` the agent spawns that may prompt carries:

```
SSH_ASKPASS=<bundle>/Contents/MacOS/sshdrive-askpass      (path taken from the running bundle)
SSH_ASKPASS_REQUIRE=force
SSHDRIVE_ASKPASS_TOKEN=<one-time token minted by the agent for this ssh process>
```

`ssh` invokes the program with the prompt text as its argument and reads the answer from its
stdout. It sets `SSH_ASKPASS_PROMPT` to `confirm` for yes/no questions and `none` for
notifications, and leaves it unset for secrets.

## The token protocol

1. The agent mints a token for every master it spawns and for every collect connection, and records
   which location and which purpose (runtime or *collect*) it belongs to. Mux clients run with
   `BatchMode=yes` and get none.
2. The token goes into that `ssh`'s environment. A `ProxyJump` hop is spawned by the master, through
   the `ProxyCommand` the agent built ([SSH process management](ssh.md)), and inherits the master's
   environment, token included. The agent never sees a hop start or exit.
3. When `ssh` prompts, askpass opens an XPC connection to the agent and sends:
    - the token,
    - the prompt text,
    - `SSH_ASKPASS_PROMPT`,
    - the argv of its parent `ssh` process, read with `sysctl KERN_PROCARGS2`.
4. The agent refuses to answer a request with no token, a retired token, or a caller that is not a
   descendant of the `ssh` the token was issued to.
5. The agent tells which host is asking by the parent argv, not the prompt text: a hop shares the
   master's token and is told apart from it only this way (SQ-063). It resolves that argv with
   `ssh -G`.
6. The agent classifies the prompt ([below](#prompt-classification)) and replies. askpass prints
   the reply and exits.
7. The agent retires the token when the master exits. That ends every hop too, since a hop's `-W`
   pipe closes with the master.

### Why this is safe

Environment variables are not secret, but a token that exists in one short-lived process tree and
is useless once it exits is enough. Reading it requires reading our child's environment during the
connection, which needs the user's privileges over our processes, and with those an attacker could
run `ssh` with the user's keys directly.

An askpass that read the keychain itself and trusted a location id from its environment would be a
password oracle for any local process. This one holds nothing.

## Prompt classification

| Prompt from `ssh` | Keychain item | Answer |
|---|---|---|
| `Enter passphrase for key '<path>':` | `passphrase:<path>` | the stored passphrase |
| `<user>@<hostname>'s password:` | `password:<user>@<hostname>:<port>`, the port from the `ssh -G` resolution of the asking `ssh` | the stored password |
| a keyboard-interactive password prompt, which `ssh` presents as `(<user>@<host>) Password:` with `<host>` replaced by `HostKeyAlias` when the config sets one | `password:<user>@<hostname>:<port>` for the destination of the asking `ssh`, identified by its argv and resolved with `ssh -G`; nothing is parsed out of the prompt text | the stored password |
| the host-key question, recognised **by its text**: it begins `The authenticity of host '<host>' can't be established` (or `Warning: the <type> host key for … differs from the key for the IP address …`) and ends `Are you sure you want to continue connecting (yes/no/[fingerprint])? ` | none | during `add`: relayed to the terminal; otherwise refused |
| `SSH_ASKPASS_PROMPT=confirm`, which `ssh` sets only for its own permission questions | none | during `add`: relayed to the terminal; otherwise refused |
| `SSH_ASKPASS_PROMPT=none` (`Confirm user presence for key …`) | none | acknowledged; during `add` this marks the key as touch-required ([below](#prompts-that-need-a-human-every-time)) |
| `Enter PIN for … key`, a one-time code, anything else | none | refused |

The exact prompt strings, trailing spaces included, are SQ-060.

!!! warning "The host-key question has no hint"
    It arrives with `SSH_ASKPASS_PROMPT` **unset**, indistinguishable by hint from a password
    prompt (SQ-047). A classifier that trusted the hint would answer a stored password to "Are you
    sure you want to continue connecting". So the question's own text is matched first and the
    hint is only corroboration. `confirm` exists and is refused outside `add`; nothing we have seen
    produces it.

The passphrase prompt names the key through `%.100s`, so a path over 100 bytes arrives truncated
(SQ-048). The agent maps the prefix back onto the asking `ssh`'s own `identityfile` list from the
same `ssh -G` resolution and keys on the full path. With no unique match it takes the prompt at its
word.

## Keychain keys

Items are keyed `password:<user>@<hostname>:<port>` and `passphrase:<keypath>`, never by location.

- `<hostname>` is the resolved `hostname` from `ssh -G`, lowercased as `ssh` prints it in the
  prompt. The alias never appears in a key, so `nas` and `nas.tail1234.ts.net` share one item.
- Keying by host rather than location is what makes `ProxyJump` work with password auth on both
  hops: each hop's prompt names its own host and gets its own item.
- The port is in the key because one hostname routinely fronts several machines on different ports
  (the usual NAT layout); `known_hosts` keys entries as `[host]:port` for the same reason. `ssh`
  puts no port in any prompt, so the agent adds it from the resolution of the asking `ssh`, found by
  its argv (a hop carries its `-p` there, [SSH process management](ssh.md)).
- An item is shared by every location that names it ([the location model](locations.md)).

## Prompts with no stored answer

A refused PIN, one-time code or `confirm` makes `ssh` fail. The domain shows `.notAuthenticated`,
reconnection stops ([SSH process management](ssh.md)), and `sshdrive status` prints the prompt text
so the user knows what the server wanted.

A passphrase prompt for a key with no stored item is answered with an empty passphrase, and nothing
is stopped:

- `ssh` offers every `identityfile` in order without decrypting any, because the OpenSSH key format
  keeps the public half in the clear (an encrypted key with no `.pub` beside it is still offered
  with no passphrase asked). It decrypts a key only once the server accepts it.
- So the prompt arises for an unstored key only when the server accepts it as well as the stored
  one (a personal and a work key on the same account can), or for a key in the old PEM format,
  which must be decrypted before it can be offered.
- `NumberOfPasswordPrompts=1` bounds passphrase attempts too, so `ssh` gives up on that key after
  one try and moves to the next. If no key works, the "Permission denied" that follows is
  classified on exit like any other.

A password prompt with no stored item is answered the same way. `ssh` gets one password attempt, so
the exit that follows stops reconnection with the prompt text in `status`: the right outcome for a
server that has started asking for a credential the location does not have.

## Collecting secrets at `add`

Collection happens in `sshdrive add`, and again when `sshdrive set` changes the host, user, port or
identity. The CLI does not run `ssh`.

1. The CLI asks the agent to make the verification connection (the **collect connection**).
2. The agent runs the exact command it will use later, in its own environment
   ([SSH process management](ssh.md)), with the token marked *collect*.
3. For every prompt with no stored answer, the agent calls back to the CLI over the same XPC
   connection. The CLI shows the prompt, reads the answer (hidden for secrets, visible for the
   host-key question) and returns it.
4. The agent hands the answer to `ssh` and keeps it in memory. The CLI never holds a secret beyond
   the prompt.
5. When the connection succeeds, every answer that was actually used is written to the keychain. A
   wrong password is never stored.

Because the test connection is the agent's, a location that passes `add` works from the agent:
there is no second environment for it to fail in. `list` and `show` report which items exist
("password stored for alec@nas", "passphrase stored for ~/.ssh/id_nas").

What gets stored:

- Passphrases always, even when `ssh-agent` also holds the key, so the mount works at login before
  any key agent is unlocked.
- Nothing for an unencrypted key or a key that lives only in a key agent.

### Two passes: key files first, then the key agent

A key agent that already holds the key would defeat collection: `ssh` signs through the agent,
never opens the key file, never asks for the passphrase, and `add` stores nothing. The first reboot
then finds an empty agent, falls back to the file, and fails on the refused prompt. So the collect
connection runs at most twice.

| Pass | Runs with | Can use |
|---|---|---|
| 1 | `-o IdentityAgent=none` | key files, passphrases Apple's `UseKeychain` finds in the login keychain, and passwords; every passphrase needed is seen and stored |
| 2, only if pass 1 fails to authenticate | the key-agent socket | agent-only keys too (1Password, Secretive, a FIDO key loaded into `ssh-agent`) |

- When pass 1 falls through to a password prompt, the CLI says so: "your key files did not
  authenticate and the server accepts passwords; press Enter to skip this and try your key agent
  instead". Without it, a user whose only key lives in 1Password and whose server also accepts
  passwords (SQ-064) would type a password and end up with a location that quietly authenticates by
  password.
- An empty answer refuses that prompt: nothing is stored and the pass fails over. The same
  Enter-to-skip works for a passphrase prompt for a key the user does not mean to use here; `ssh`
  moves to the next identity, exactly as at runtime ([above](#prompts-with-no-stored-answer)).
- Whichever pass succeeded is how the location connects from then on. A pass-1 location runs with
  `IdentityAgent=none` for good, so no key agent is ever consulted for it and none can prompt.
- A location that passes only pass 2 is recorded as `agentDependent`. `show` says "authenticates
  through the key agent only; the mount waits for it after login". While the key agent is
  unavailable its reconnects use the transient retry of [the SSH page](ssh.md): a key-agent socket
  that is missing or refuses, probed before the spawn at the path `ssh -G` resolves for
  `identityagent`, is a transient failure, not an authentication one.

The collect connection of `set host|user|port|identity` repeats the same two passes.

### A stale stored answer

A second location on a host whose password has since changed finds the shared
`password:<user>@<hostname>:<port>` item; `ssh` uses it for its single prompt
(`NumberOfPasswordPrompts=1`) and is refused. `add` then repeats the collect connection with the
stored items for that host masked, so every prompt reaches the terminal, and on success replaces
the item for every location that names it.

Replacing a stored secret on purpose is `sshdrive remove` then `sshdrive add`: `remove` deletes
each item no other location names, and the new `add` collects it again.

### The terminal's environment versus the agent's

A tmux session, a forwarded agent socket or a directory-scoped environment can give the terminal a
different `SSH_AUTH_SOCK` or `PATH` from the agent's login-shell snapshot, and a key reachable only
through those passes `ssh nas` there and fails from the agent. So `add` compares the CLI's two
values with the snapshot before connecting and, when they differ, prints both and says which the
agent will use. "Works in a terminal" means "works in a fresh login shell", and this is where the
user finds that out.

## Prompts that need a human every time

If the collect connection sees any of these, the location is not created:

- a user-presence notice (a FIDO key that requires a touch),
- a PIN prompt,
- a keyboard-interactive prompt that is not a password (a one-time code).

Such a location would mount once and then fail into `.notAuthenticated` on the first unattended
reconnect, with nobody there for the touch. `add` explains which prompt it saw and what works
unattended: a key held by a key agent (1Password, Secretive and `ssh-agent` show their own prompt
or none), a FIDO key generated with `no-touch-required`, or a password. `sshdrive unlock` for
one-time codes is [future work](future-work.md).

### Naming the touch key

`ssh` offers identities in the order `ssh -G` lists them, and the default list includes
`~/.ssh/id_ecdsa_sk` and `~/.ssh/id_ed25519_sk`. So a touch-required FIDO key that sits in `~/.ssh`
and that the server also accepts is used, and asks for its touch, before a passphrase key or
password that would have worked unattended gets its turn. (A key the server does not accept is
offered and passed over without a prompt.)

The user-presence notice carries the key type and fingerprint
(`Confirm user presence for key ED25519-SK SHA256:…`). The agent matches the fingerprint against
`ssh-keygen -lf` of every `identityfile` in the `ssh -G` output, and `add` names the file and the
way around it:

> `~/.ssh/id_ed25519_sk` needs a touch on every connection; run
> `sshdrive add --identity ~/.ssh/id_nas nas` to authenticate with a different key

`--identity` stores the override with `IdentitiesOnly=yes` ([the location model](locations.md)), so
the touch key is never offered again for that location. Nothing is stored unless the user asks: a
location added without `--identity` keeps following `~/.ssh/config`, and a key added to the config
later is picked up on the next connection.

## The authentication deadline

A key held by a key agent is signed by the agent, and any touch or biometric prompt comes from the
agent's own UI, never through askpass. Secretive keys that require Touch ID, 1Password's
per-session authorisation and a FIDO key loaded into `ssh-agent` all pass the collect connection
while the user is at the keyboard, then wait for a human on every unattended reconnect. `add` cannot
detect these, and `ConnectTimeout` does not cover authentication.

So every connection has a deadline of the agent's own:

- If the master's control socket has not appeared **60 s after `ssh` was spawned**, the agent kills
  it. `ssh` creates the socket only once authentication has succeeded
  ([SSH process management](ssh.md)).
- The 60 s run from the spawn and **contain** the 15 s `ConnectTimeout` of the TCP and banner phase
  ([offline behaviour](offline.md)), because the agent has no signal for when that phase ended. A
  `ProxyCommand` that takes ten seconds to hand over a connection leaves fifty for authentication.

!!! note "The collect connection runs to 300 s"
    Its prompts go to a terminal, and a user reading a fingerprint and typing a password for each
    hop of a chain routinely takes longer than 60 s. The 60 s exists because nothing may wait for a
    human on an unattended connection; somebody at the keyboard is the premise of this one. The
    master `add` brings up **afterwards** carries the ordinary 60 s: that is the connection that
    has to work unattended.

What a deadline expiry means depends on the location:

| Location | Treated as | Result |
|---|---|---|
| `agentDependent` | an authentication failure, for the reconnect loop | Reconnection stops. `status` says "authentication did not complete within 60 s; a key agent may be waiting for a touch or approval", with the fix: use a stored passphrase, a key-agent key that does not prompt, or a password, then `sshdrive debug breaker <name> --connect` |
| any other | a slow or wedged server: it runs with `IdentityAgent=none`, so nothing on the Mac can be waiting for a human | Retried with the network backoff like any other connection failure ([offline behaviour](offline.md)) |

### Re-arming after a deadline stop

The commonest cause of a deadline stop is a 1Password or Secretive agent that only gives approval
while somebody is at the keyboard. After every sleep the master is dropped
([SSH process management](ssh.md)), the reconnect blocks on a prompt nobody is there to answer, and
the deadline fires. Leaving that stopped until the user clears it by hand would make the mount die
every morning for exactly the key agents [goals and non-goals](goals.md) supports. So a
deadline-stopped location is **re-armed for one attempt** when a human is demonstrably present.

A File Provider request on its own is not evidence of that. Spotlight, Quick Look, Finder's
background refreshes and the working-set enumerator issue requests on an unattended Mac all day;
each would re-arm an attempt, block for 60 s, raise the key agent's prompt with nobody there, time
out and hand the trigger to the next request. Presence is measured directly:

| Test | Source | Passes when |
|---|---|---|
| input idle time | `CGEventSource.secondsSinceLastEventType` over the combined session state (keyboard, mouse, trackpad; needs no permission) | under 30 s |
| screen lock | `CGSSessionScreenIsLocked` in `CGSessionCopyCurrentDictionary()` | unlocked |

Two things re-arm the attempt:

- the `com.apple.screenIsUnlocked` distributed notification;
- a File Provider request for that domain arriving while the presence test passes. The test is
  evaluated at most once a minute, so it costs nothing.

The rules around it:

- The domain is not disconnected for a deadline stop ([offline behaviour](offline.md)), so requests
  keep arriving and failing fast (MQ-038), which is what the request trigger rides on.
- An `agentDependent` location makes no attempt at all while the screen is locked, wake included.
  Its first attempt after a sleep is the one the unlock re-arms, so it never spends 60 s prompting a
  key agent at a locked screen.
- The re-armed attempt has the same 60 s deadline. If it times out again the location is stopped
  until the next trigger, so an unattended Mac never retries and the prompt appears only when the
  user is there to see it.
- Refused prompts (a PIN, a one-time code, a `confirm` outside `add`) are never re-armed: they
  cannot succeed attended or unattended.

Measured against a forced deadline stop (2026-09-04): the unlock trigger re-arms exactly one
attempt, a request with input idle at 45 s re-arms nothing, a request with input idle at 2 s re-arms
one, and a burst of requests inside one minute costs a single presence reading.

`launchctl setenv` does not reach a launchd agent on macOS 26 (MQ-067), so anything that overrides
the presence reading for a test does it through a file in the group container, never the
environment.

## Host keys

`ssh` checks the server against `~/.ssh/known_hosts` as it always does. We keep no host-key state
of our own, so `ssh`, `sftp` and SSH Drive can never disagree about a server.

| Connection | Host-key options | An unknown or changed key |
|---|---|---|
| `add` (collect) | `ssh`'s default `StrictHostKeyChecking=ask`; `--trust-first` passes `accept-new` instead | Unknown: `ssh`'s fingerprint question arrives at askpass with `SSH_ASKPASS_PROMPT` unset, is recognised by its text, and is relayed to the terminal; `ssh` writes the answer to `known_hosts` as it would from a tty. Under `--trust-first` no question is asked |
| every other | `StrictHostKeyChecking=yes`, `UpdateHostKeys=no`; any `confirm` prompt is refused | Changed: `ssh` exits with its "REMOTE HOST IDENTIFICATION HAS CHANGED" banner, which the agent recognises on stderr. The domain goes `.notAuthenticated`, reconnection stops ([SSH process management](ssh.md)), and `status` shows the fingerprint `ssh` reported and the fix |

The fix for a changed key is `ssh-keygen -R <host>`, accepting the new key with `ssh` once, then
`sshdrive debug breaker <name> --connect`.

`UpdateHostKeys=no` matters because `UpdateHostKeys ask` in the user's config passes straight
through `ssh -G` and would raise a `confirm` on a healthy server, which the refusal rule would turn
into a stopped location.
