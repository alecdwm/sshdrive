# Secrets and host keys

The agent runs `ssh` with no tty. Anything `ssh` would normally ask for on
the terminal is routed to our askpass program:

```
SSH_ASKPASS=<bundle>/Contents/MacOS/sshdrive-askpass      (path taken from the running bundle)
SSH_ASKPASS_REQUIRE=force
SSHDRIVE_ASKPASS_TOKEN=<one-time token minted by the agent for this ssh process>
```

`ssh` invokes the program with the prompt text as its argument, sets
`SSH_ASKPASS_PROMPT` to `confirm` for yes/no questions and `none` for
notifications (unset for secrets), and reads the answer from its stdout.
The program itself knows nothing: it opens an XPC connection to the agent
and sends the token, the prompt text, `SSH_ASKPASS_PROMPT`, and the argv of
its parent `ssh` process (read with `sysctl KERN_PROCARGS2`), then prints
the agent's reply. `ProxyJump` runs the jump hop as a child `ssh -W`
process with the same environment, so the parent argv is how the agent
tells which host is asking.

The token is what authorises the request. The agent mints one for every
master it spawns and for every collect connection; mux clients run with
`BatchMode=yes` and get none. A `ProxyJump` hop is not spawned by the
agent but by the master, through the `ProxyCommand` the agent built
([SSH process management](ssh.md)), and inherits the master's environment,
token included; the agent never sees a hop start or exit, so hops share the
master's token and are told apart from it by the parent argv the askpass
sends. The agent remembers which location and which purpose the token
belongs to, and retires it when the master exits, which ends every hop too,
since a hop's `-W` pipe closes with it. An askpass invocation with no
token, a retired one, or one whose caller is not a descendant of the `ssh`
it was issued to gets no answer. Environment variables are not a secret,
but a token that only ever exists in one short-lived process tree and is
useless once it exits is enough: another process on the Mac would have to
read our child's environment during the connection, which already requires
the user's privileges over our processes, and with those it could simply
run `ssh` with the user's keys. An askpass that read the keychain itself
and trusted a location id from its environment would be a password oracle
for any local process; this one holds nothing.

The agent classifies the prompt:

| Prompt from `ssh` | Keychain item | Answer |
|---|---|---|
| `Enter passphrase for key '<path>':` | `passphrase:<path>` | the stored passphrase |
| `<user>@<hostname>'s password:` | `password:<user>@<hostname>:<port>`, the port from the `ssh -G` resolution of the asking `ssh` (below) | the stored password |
| a keyboard-interactive password prompt, which `ssh` presents as `(<user>@<host>) Password:` with `<host>` replaced by `HostKeyAlias` when the config sets one | `password:<user>@<hostname>:<port>` for the destination of the asking `ssh`, identified by its argv and resolved with `ssh -G`; nothing is parsed out of the prompt text | the stored password |
| the host-key question (below), recognised **by its text**: it begins `The authenticity of host '<host>' can't be established` (or `Warning: the <type> host key for … differs from the key for the IP address …`) and ends `Are you sure you want to continue connecting (yes/no/[fingerprint])? ` | none | during `add`: relayed to the terminal; otherwise refused |
| `SSH_ASKPASS_PROMPT=confirm`, which `ssh` sets only for its own permission questions | none | during `add`: relayed to the terminal; otherwise refused |
| `SSH_ASKPASS_PROMPT=none` (`Confirm user presence for key …`) | none | acknowledged; during `add` this marks the key as touch-required (below) |
| `Enter PIN for … key`, a one-time code, anything else | none | refused |

**The host-key question carries no hint, so the text is what classifies it.**
`ssh` sets `SSH_ASKPASS_PROMPT` only where `read_passphrase` is called with
`RP_ASK_PERMISSION` (`confirm`) or from `notify_start` (`none`); the
host-key question goes through `read_passphrase(prompt, RP_ECHO)` and arrives
with the variable **unset**, indistinguishable by hint from a password prompt.
Measured on `OpenSSH_10.2p1` with an empty `known_hosts`, 2026-09-04. An agent
that trusted the hint would answer a stored password to "Are you sure you want
to continue connecting", so the classifier matches the question's own text
first and treats the hint as corroboration. `confirm` exists and is refused
outside `add`; nothing we have seen produces it.

The passphrase prompt names the key through `%.100s`, so a path longer than 100
bytes arrives truncated. The agent maps the prefix back onto the asking `ssh`'s
own `identityfile` list from the same `ssh -G` resolution, and keys on the full
path; with no unique match it takes the prompt at its word.

Keying passwords by `<user>@<hostname>:<port>` rather than by location is
what makes `ProxyJump` work with password auth on both hops: each hop's
prompt names its own host and gets its own item. `<hostname>` is the
resolved `hostname` from `ssh -G`, lowercased as `ssh` itself prints it
in the prompt; the alias the user typed never appears in a key, so `nas`
and `nas.tail1234.ts.net` share one item. The port is in the key because
one hostname routinely fronts several machines on different ports, the
usual NAT layout, and `known_hosts` keys its entries as `[host]:port`
for the same reason; `ssh` puts no port in any prompt, so the agent adds
it from the resolution of the `ssh` that is asking, which the askpass
identifies by that process's argv (a hop carries its `-p` there,
[SSH process management](ssh.md)).
A refused PIN, one-time code or
`confirm` makes `ssh` fail; the domain shows `.notAuthenticated`,
reconnection stops ([SSH process management](ssh.md)), and
`sshdrive status` prints the prompt text
so the user knows what the server wanted. A passphrase prompt for a key
file that has no stored item is different. `ssh` offers every
`identityfile` in order without decrypting any of them, since the
OpenSSH key format keeps the public half in the clear (an encrypted key
with no `.pub` beside it is still offered with no passphrase asked), and
decrypts a key only once the server has accepted it. So the prompt arises
for a key the location never stored only when the server accepts that key
as well as the one that was stored, which a personal and a work key on the
same account can produce, or for a key in the old PEM format, which has to
be decrypted before it can be offered at all. Either way the agent answers
with an empty passphrase; `ssh` gives up on that key after its single
attempt (`NumberOfPasswordPrompts=1` bounds passphrase attempts as well)
and moves on to the next, and nothing is stopped. If no key works, the
"Permission denied" that follows is classified on exit like any other. A
password prompt with no stored item is answered the same way, and since
`ssh` gets one password attempt the exit that follows stops reconnection
with the prompt text in `status`, which is the right outcome for a server
that has started asking for a credential the location does not have.

**Collecting secrets** happens once, in `sshdrive add` (and again when
`sshdrive set` changes the host, user, port or identity). The CLI does not run `ssh`. It asks the agent to make
the verification connection, and the agent runs the exact command it will
use later, in its own environment ([SSH process management](ssh.md)), with
the token marked *collect*. For every prompt the agent has no stored answer
for, it calls back to the CLI over the same XPC connection; the CLI shows
the prompt on the terminal, reads the answer (hidden for secrets, visible
for the host-key question), and returns it. The agent hands it to `ssh` and
keeps it in memory. When the connection succeeds, every answer that was
actually used is written to the keychain; a wrong password is never stored,
and the CLI never holds a secret beyond the prompt. Because the test
connection is the agent's, not the terminal's, a location that passes `add`
works from the agent: there is no second environment for it to fail in.
`list` and `show` report which items exist ("password stored for alec@nas",
"passphrase stored for ~/.ssh/id_nas"). Passphrases are always stored, even
when `ssh-agent` also holds the key, so the mount works at login before any
key agent has been unlocked. An unencrypted key or a key that lives only in
a key agent needs nothing stored. A stored answer can also be stale: a
second location on a host whose password has since changed finds the shared
`password:<user>@<hostname>:<port>` item ([the location model](locations.md)),
`ssh` uses it for its single prompt (`NumberOfPasswordPrompts=1`) and is
refused. `add` then repeats the collect connection with the stored items for
that host masked, so every prompt reaches the terminal, and on success
replaces the item for every location that names it. Replacing a stored secret on purpose is
`sshdrive remove` followed by `sshdrive add`: `remove` deletes each item no
other location names, and the new `add` collects it again.

The terminal the user is typing in can still differ from the snapshot: a
tmux session, a forwarded agent socket or a directory-scoped environment
gives it a different `SSH_AUTH_SOCK` or `PATH`, and a key reachable only
through those passes `ssh nas` there and fails from the agent. So `add`
compares the CLI's own two values with the snapshot before connecting
and, when they differ, prints both and says which the agent will use.
"Works in a terminal" means "works in a fresh login shell", and this is
where the user finds that out.

A key agent that already holds the key would defeat that: `ssh` signs through
the agent, never opens the key file, never asks for the passphrase, and
`add` would store nothing, only for the first reboot to find an empty
agent, fall back to the file, and fail on the refused prompt. So the
collect connection is made twice at most. The first attempt runs with
`-o IdentityAgent=none`, so `ssh` can use only key files, passphrases
Apple's `UseKeychain` finds in the login keychain, and passwords, and every
passphrase it needs is seen and stored. When that attempt falls through
to a password prompt, the CLI says so ("your key files did not
authenticate and the server accepts passwords; press Enter to skip this
and try your key agent instead"), because a user whose only key lives in
1Password and whose server also accepts passwords would otherwise type a
password and end up with a location that quietly authenticates by
password. An empty answer is a refusal of that prompt: nothing is stored,
and the attempt fails over. The same Enter-to-skip applies to a
passphrase prompt for a key the user does not mean to use for this
location: `ssh` moves to the next identity, exactly as it will at
runtime (above). If that attempt fails to
authenticate, the second runs with the agent socket, so agent-only keys
(1Password, Secretive, a FIDO key loaded into `ssh-agent`) still work. A
location that passes only the second attempt is recorded as
`agentDependent`; `show` says "authenticates through the key agent only;
the mount waits for it after login", and its reconnects use the transient
retry of [the SSH page](ssh.md) while the agent is unavailable: a key-agent
socket that is missing or refuses, probed before the spawn at the path
`ssh -G` resolves for `identityagent`, is a transient failure and not an
authentication one. The collect connection of `set host|user|port|identity`
repeats the same two steps. Whichever pass
succeeded is how the location connects from then on: a first-pass location
runs with `IdentityAgent=none` for good, so no key agent is ever consulted
for it and none can prompt.

**Prompts that need a human every time are refused at `add`.** If the
collect connection sees a user-presence notice (a FIDO key that requires a
touch), a PIN prompt, or a keyboard-interactive prompt that is not a
password (a one-time code), the location is not created. `add` explains
which prompt it saw and what works unattended: a key held by a key agent
(1Password, Secretive and `ssh-agent` show their own prompt or none), a
FIDO key generated with `no-touch-required`, or a password. Mounting such a
location would succeed once and then fail into `.notAuthenticated` on the
first unattended reconnect, with nobody watching for the touch; refusing up
front is kinder. `sshdrive unlock` for one-time codes is
[future work](future-work.md).

The refusal names the key. `ssh` offers identities in the order `ssh -G`
lists them, and the default list includes `~/.ssh/id_ecdsa_sk` and
`~/.ssh/id_ed25519_sk`, so a touch-required FIDO key that happens to sit
in `~/.ssh` and that the server also accepts is used, and asks for its
touch, before the passphrase key or password that would have worked
unattended ever gets its turn (a key the server does not accept is
offered and passed over without a prompt, as above). The user-presence
notice carries the key type and
fingerprint (`Confirm user presence for key ED25519-SK SHA256:…`); the
agent matches that fingerprint against `ssh-keygen -lf` of every
`identityfile` in the `ssh -G` output and `add` says which file it was
and how to skip it: "`~/.ssh/id_ed25519_sk` needs a touch on every
connection; run `sshdrive add --identity ~/.ssh/id_nas nas` to
authenticate with a different key". `--identity` stores the override with
`IdentitiesOnly=yes` ([the location model](locations.md)), so the touch key
is never offered again for that location. Nothing is stored unless the user
asks for it: a location added without `--identity` keeps following
`~/.ssh/config`, and a key added to the config later is picked up on the
next connection.

**What `add` cannot see, and the authentication deadline.** A key held by
an agent is signed by the agent, and any prompt for a touch or a
biometric comes from the agent's own UI, never through `ssh`'s askpass:
Secretive keys configured to require Touch ID, 1Password's per-session
authorisation, and a FIDO key loaded into `ssh-agent` all pass the collect
connection while the user is at the keyboard and then wait for a human on
every unattended reconnect. `add` cannot detect these, and `ConnectTimeout`
does not cover the authentication phase. So every connection carries an
**authentication deadline** of the agent's own: if the master's control
socket has not appeared 60 s after `ssh` was started, which `ssh` does
only once authentication has succeeded ([SSH process management](ssh.md)),
the agent kills it. The
60 s run from the spawn and contain the 15 s `ConnectTimeout` of the TCP
and banner phase ([offline behaviour](offline.md)), because the agent has
no signal for when that phase ended; a `ProxyCommand` that takes ten
seconds to hand over a connection leaves fifty for authentication.
**The collect connection is the one exception**,
and it has to be: its prompts go to a terminal, so a user reading a
fingerprint off the screen and typing a password for each hop of a chain
routinely spends longer than that, and a 60 s kill lands in the middle of
their typing. Somebody being at the keyboard is the whole premise of that
connection, and the whole reason the 60 s exists is that nothing may wait
for a human on an unattended one; so the collect connection runs to 300 s
and the master `add` brings up **afterwards** carries the ordinary 60 s,
which is the connection that has to work unattended and the one worth
measuring. For
an `agentDependent` location that is treated as an authentication
failure for the purpose of the reconnect loop; for any other location
nothing on the Mac can be waiting for a human, since it runs with
`IdentityAgent=none`, so the same timeout is a slow or wedged
server and is retried with the network backoff
([offline behaviour](offline.md)) like any other
connection failure. For the agent-dependent case reconnection stops
and `sshdrive status` says
"authentication did not complete within 60 s; a key agent may be waiting
for a touch or approval", with the fix: use a stored passphrase, a
key-agent key that does not prompt, or a password, then
`sshdrive debug breaker <name> --connect`.

A deadline stop is not final, though, because its commonest cause is a
1Password or Secretive key agent that only wants its approval given while
somebody is at the keyboard: after every sleep the master is dropped
([SSH process management](ssh.md)), the reconnect blocks on a prompt nobody
is there to answer, and the deadline fires. Leaving it stopped until the
user clears the stop by hand would make the mount die every morning for exactly the key
agents [goals and non-goals](goals.md) names as supported.
So a location stopped by the deadline is **re-armed for one attempt**
when a human is demonstrably present. A File Provider request on its own
is not that evidence: Spotlight, Quick Look, Finder's background
refreshes and the working-set enumerator issue requests on an unattended
Mac all day, and each would re-arm an attempt, block for 60 s, raise the
key agent's prompt with nobody there, time out, and hand the trigger to
the next request, which is exactly the loop this rule exists to prevent.
Presence is therefore measured directly: the time since the last
keyboard, mouse or trackpad event, from
`CGEventSource.secondsSinceLastEventType` over the combined session
state, which needs no permission, must be under 30 s, and the screen must
be unlocked, read from `CGSSessionScreenIsLocked` in
`CGSessionCopyCurrentDictionary()`. Two things re-arm the attempt: the
`com.apple.screenIsUnlocked` distributed notification, and a File
Provider request for that domain that arrives while the presence test
passes, evaluated at most once a minute so the test itself costs nothing.
The domain is not disconnected for a deadline stop
([offline behaviour](offline.md)), so those requests keep arriving:
`fetchContents` and `createItem` still reach the extension while every call
fails fast, which is what gives the request trigger anything to ride on.
An `agentDependent` location also makes no
attempt at all while the screen is locked, on wake included: its first
attempt after a sleep is the one the unlock re-arms, so it never spends
60 s prompting a key agent at a locked screen only to stop. The attempt
runs with the same 60 s deadline; if
it times out again the location is stopped again until the next trigger,
so an unattended Mac never retries and the prompt appears only when the
user is there to see it. Measured against a forced deadline stop
(2026-09-04): the unlock trigger re-arms exactly one attempt, a request
with input idle at 45 s re-arms nothing, a request with input idle at 2 s
re-arms one, and a burst of requests inside one minute costs a single
presence reading. Refused prompts (a PIN, a one-time code, a
`confirm` outside `add`) are never re-armed: they cannot succeed attended
or unattended. The first unattended reconnect is therefore what tells the
user, once, and the next time they touch the mount it tries again.
`launchctl setenv` does not reach a launchd agent on macOS 26 (measured
2026-09-04), so anything that overrides the presence reading for a test
does it through a file in the group container, never the environment.

## Host keys

`ssh` checks the server against `~/.ssh/known_hosts` as it always does.

- The `add` connection runs with `ssh`'s default
  `StrictHostKeyChecking=ask`. An unknown host produces `ssh`'s own
  fingerprint question, which arrives at askpass with
  `SSH_ASKPASS_PROMPT` **unset** and is recognised by its text (above); the
  agent relays it to the CLI, the user
  answers on the terminal, and `ssh` writes the answer to the user's
  `known_hosts` exactly as it would have from a tty. `--trust-first`
  passes `StrictHostKeyChecking=accept-new` instead and no question is
  asked.
- Every other connection runs with `StrictHostKeyChecking=yes` and
  `UpdateHostKeys=no`, and the agent refuses any `confirm` prompt that
  reaches it. The second override matters because `UpdateHostKeys ask` in
  the user's config passes straight through `ssh -G` and would raise a
  `confirm` on a perfectly healthy server, which the refusal rule would
  then turn into a stopped location. A changed key makes
  `ssh` exit with its "REMOTE HOST IDENTIFICATION HAS CHANGED" banner; the
  agent recognises that on stderr, marks the domain `.notAuthenticated`,
  stops reconnecting ([SSH process management](ssh.md)), and
  `sshdrive status` shows the fingerprint
  `ssh` reported and the fix: `ssh-keygen -R <host>`, accepting the new
  key with `ssh` once, and `sshdrive debug breaker <name> --connect`.

We keep no host-key state of our own, so `ssh`, `sftp` and SSH Drive can
never disagree about a server.
