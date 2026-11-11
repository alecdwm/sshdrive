# Offline behaviour

A mount whose server is unreachable stays usable for everything already on the Mac, fails
everything else in under a second, and comes back without the user doing anything. The one thing
to know: the agent reconnects on its own schedule, because the system barely retries anything.

## What the user sees

| Situation | What happens |
|---|---|
| Open a file already downloaded, network down | The system serves reads from local storage. We are not called. |
| Browse a folder listed before, network down | Served from the system's replica; the refresh request gets `.serverUnreachable` and Finder shows the cached listing. |
| Browse a never-listed folder, network down | `.serverUnreachable` at once; Finder shows the folder as unavailable. |
| Save a file, network down | The system stores it locally, marks it "waiting to upload" and calls `modifyItem` again on retry. The agent fails fast until it can connect, then the flush goes through. |
| Network returns | The agent's `NWPathMonitor` fires, a connection attempt runs, and on success the agent calls `signalErrorResolved(.serverUnreachable)` on every domain, then `signalEnumerator` for the working set, then `reconnect()` if `disconnect(reason:)` had been used. |
| Laptop wakes from sleep | Same path as network returns; the masters were already dropped at the will-sleep message ([ssh](ssh.md#dead-connections)). A connection still held on wake - the Mac slept without the message - is checked with one round trip and replaced if it does not answer within 10 s. |
| Agent not running | The domain shows a disconnect message ([extension](extension.md)); everything already cached keeps working. |

!!! warning "`signalErrorResolved` is what flushes the queue"
    It is the only call that makes the system retry pending uploads and fetches (MQ-037,
    gotcha 58). Neither reconnecting on its own nor `signalEnumerator` for the working set wakes the
    flush. The working-set signal is still sent, for the working set.

## What the system does while we are down

- A queued `modifyItem` is re-offered on a doubling backoff with no ceiling in sight, past five
  minutes after ten minutes offline, each retry on a freshly launched extension instance (MQ-035).
- A `fetchContents` that failed is **never** re-issued: the read that provoked it gets `ETIMEDOUT`
  and nothing comes back until something opens the file again (MQ-036).
- A working-set change enumeration that keeps failing is throttled with no useful ceiling: 27
  consecutive `.serverUnreachable` answers took one domain to a 47-minute retry, and the mount took
  no server-side change while every other path worked (MQ-005).

An agent that reconnected only when asked would leave a mount dead until the user clicked it, and
a save waiting on an interval that only grows. So the agent reconnects on the breaker's backoff
without being asked (rule 5), notices a master that exited while nothing was asking (rule 4), and
a read that meets a silently dead connection is retried once through the breaker (rule 4).

Only `signalErrorResolved` clears the working-set throttle, so the working set has an XPC fallback
and both the extension and the agent clear the backoff explicitly.

## When `disconnect(reason:)` is used

Network outages do not disconnect the domain: throwing `.serverUnreachable` is enough and keeps it
writable. The agent calls `disconnect` with a human message only where retrying is pointless until
the user acts:

- a refused prompt;
- a changed host key;
- a root that no longer canonicalises to what `add` recorded ([security](security.md));
- the agent missing.

A stop caused by the authentication deadline ([secrets](secrets.md)) does **not** disconnect the
domain. Requests keep arriving and fail fast with `.serverUnreachable` while the location is
stopped (MQ-038), and the first one that arrives while the user is present re-arms the attempt, so
the domain has to stay connected for that trigger to exist. `sshdrive status` carries the
explanation in that case.

## Failing fast: the gating rules

Waiting for a TCP timeout freezes Finder, so every remote call is gated. Tests cite these rules by
number.

1. **No path.** `NWPathMonitor` says there is no path at all: `.serverUnreachable` immediately.
   This covers Wi-Fi off, but not a powered-down NAS or a tailnet that is down while the Mac is
   online.

2. **Circuit breaker.** A per-location breaker covers the rest. After a failed connection attempt
   the location is marked down for a backoff interval, during which every call fails fast without
   touching the network:

    - 2 s, doubling to 60 s, jittered by +/-20 % so locations on one dead server do not retry
      in step;
    - 300 s while the failure is a key agent that is not ready ([ssh](ssh.md#key-agents));
    - a wake from sleep resets it, and so does the network path coming back. The agent passes on
      only a change of `NWPathMonitor`'s status, so a path that comes back is one that was
      reported unsatisfied first; a Wi-Fi hop straight from one network to another, which never
      goes unsatisfied, does not reset the breaker, and the wake that usually comes with it does.

    **While an attempt is in progress, calls wait for it**, bounded by the attempt's own remaining
    deadline: at most the 60 s authentication deadline ([secrets](secrets.md)), measured from the
    spawn of `ssh`, which already contains the 15 s `ConnectTimeout` (never the two added). On
    success the waiting calls run; on failure they all get `.serverUnreachable` at once and the
    breaker opens.

    Failing waiting calls fast instead was rejected: the first enumeration after login or wake
    would arrive during the connect, fail, and Finder would show the folder as unavailable until
    the user clicked again, since the system does not retry an enumeration on its own. The system
    does not time out an `enumerateItems` held the full 60 s (MQ-007, gotcha 60), and Finder draws
    a static circular progress indicator in place of the item's dataless badge for the length of
    the wait, with no alert (measured on macOS 26.4, 2026-09-04).

3. **`ConnectTimeout=15`** bounds the TCP and banner phase of the one attempt that does go out. 15
   rather than 5 because `ProxyCommand` tunnels such as `cloudflared access ssh` routinely take
   longer than 5 s to hand over a connection. The 60 s authentication deadline runs from the same
   spawn and bounds the whole attempt.

4. **Silent death, and the read retry.** A connection that died silently is found by the
   per-request deadline ([sftp](sftp.md#request-deadlines)), by the master watch, and around sleep
   by dropping the master outright or checking it on wake ([ssh](ssh.md#dead-connections)), so
   the breaker opens within seconds rather than after the keepalive window. The master watch polls
   the master process every 15 s while a connection is up, with nothing on the wire: an idle
   location whose master was killed, or gave up under `ServerAliveInterval`, is dropped and
   reconnected without waiting for a request. The request that finds a dead connection is
   **retried once**, through the breaker, if it is a read or a metadata call: the retry either
   waits for the attempt under rule 2 or fails fast because the breaker is open.

    Writes are not retried. An upload's source cannot be replayed and a `rename` that may already
    have landed must not be re-sent; a failed write is the one thing the system does re-offer.
    Without the read retry, the first double-click after a master died is spent discovering the
    death, and since the system never re-issues a failed `fetchContents` (MQ-036), that one call is
    the whole of the user's experience of it.

5. **The backoff is a reconnect schedule.** When it expires the agent attempts a connection whether
   or not anything has asked, and a connection that drops is attempted again at once. The reason
   is rule 4's: waiting to be asked would make "the server came back" mean "the user clicked
   twice". The attempt is what produces the `signalErrorResolved` that flushes the queue.

    While the breaker owes an attempt at a known time - backing off, or stopped with a slow retry
    due (rule 6) - exactly one retry is scheduled for that time. A drop that finds no connection
    up (a second call failing on the stale connection after a failed reconnect, the will-sleep
    drop of a location that is backing off) leaves the breaker and its retry as they were. With no
    network path the retry does nothing, and the path's return is the attempt.

    A call's failure counts against the connection it ran on. A call that started on a connection
    since dropped and replaced, and fails late, neither drops the new connection nor counts as one
    of its missed deadlines.

    A drop the gate made on purpose - the will-sleep message, a lost path - is not undone by the
    change detector: the helper's stream ending with it is not a reason to call the transport, so
    nothing reconnects between the will-sleep message and the wake.

6. **Auth and host-key failures stop the backoff.** A refused credential or a host key that does
   not match `known_hosts` ([ssh](ssh.md#exit-classification)) is not retried every minute. What
   replaces the backoff depends on what was refused.

    **A refused password stops reconnection outright.** The attempt sent a password or a
    keyboard-interactive answer when the askpass broker served its `ssh` such a prompt. That is the
    signal; the method list on stderr is what the server allows, not what was tried. Every retry
    would send the same stale password again, and `pam_faillock` (`deny=3` is common) or
    `fail2ban` counts each one towards locking the account or banning the Mac. A password that
    becomes right on its own is rare; a lockout is severe. So nothing retries it: not a timer, and
    not wake, a path change or an unlock. It waits for `sshdrive debug breaker <name> --connect`,
    any `sshdrive set` change to the location, or `sshdrive agent restart`, and `status` says so.
    An empty answer counts: with no stored password the broker answers empty, and `ssh` still
    sends it. Locations that share a host and user share the `password:` keychain item, and each
    of them spends its one attempt before it stops, so N such locations cost the server N failed
    logins at the first reconnect after the password changed, and none after.

    **A refused key or host key is retried slowly**, because the cause is often temporary - a home
    directory that is not mounted yet refuses every key in it, and a server reached on another
    network presents another key:

    - 5 minutes after the failure, doubling to a 30-minute cap, each interval jittered by
      +/-20 % like the backoff;
    - at most one early attempt per interval, on wake, the network path coming back or a screen
      unlock, which does not move the interval. An event within 60 s of the last attempt is merged
      into it and makes no attempt of its own, so a lid opening - a wake, a path and an unlock
      seconds apart - is one attempt, not three;
    - the worst case is two attempts per interval: four in any ten minutes, ten in the first hour
      and six an hour after that. A refused key is not counted by `pam_faillock`, and four in ten
      minutes stays under `fail2ban`'s default of five;
    - at once, and with the interval cleared, on any `sshdrive set` change to the location,
      `sshdrive agent restart` (the breaker lives in the agent's memory), or
      `sshdrive debug breaker <name> --connect`.

    Every retry is a fresh `ssh` that checks `known_hosts` as it always does, so a changed host
    key is never accepted, only asked about again. `status` says the location is stopped, why,
    and when the next attempt is.

    A stop caused by the authentication deadline ([secrets](secrets.md)) gets none of this. An
    unattended attempt there can make a security key blink or a phone prompt fire with nobody to
    answer it, so it waits for the re-arm: a screen unlock or a request arriving with the user
    present, one attempt each.

## After a connection comes up

Each connection the gate brings up runs the reconnect sequence ([change
detection](change-detection.md)) on a task of its own, and every connection has a generation.
Sequences run one at a time per location, and each step runs only while its connection is still
the gate's: a sequence for a connection that dropped part-way leaves the rest to the next one, so
the probe and budget in force are always the live connection's. The first connection is made
from inside the location's start, before its runtime is registered; its sequence waits for the
start to finish rather than skipping steps. An attempt that completes after its gate was shut down
or released - the runtime dropped by `set` or `remove`, the agent stopping - runs `-O exit` on the
master it brought up, which would otherwise belong to nobody.

`applyConnection` records the connection's channel budget and server probe before anything that
can fail - a root that is missing for the moment, a missed deadline - so the ladder decides on
what this connection found even when the rest of the step fails.

Two answers a connection can come up without are asked again on that connection, 30 s after it
came up, doubling to 10 minutes, until they are answered or the connection goes:

- **A server probe that went unanswered** - the script stalled past its deadline, its channel was
  refused or met a dying master, its output stopped short. That is not "no shell access", which
  only the server's own answer says ([security](security.md)). The last probe the server did
  answer stays in force, in the runtime and in `capabilities.json`, until the re-check answers;
  the ladder is then re-applied. A probe refused a session (`MaxSessions`) also says the channel
  budget on record may be wrong: it is marked suspect, so the next connect measures it, and the
  budget is asked again on this connection as below. A connection whose master died during the probe is never handed
  out at all: the attempt fails and the breaker tries again.
- **A channel budget that was inconclusive** ([ssh](ssh.md#the-probe)). The connection runs on
  the channels it got. A clear answer with room for more than it holds drops the connection and
  reconnects, since a channel cannot be added to a connection that is up; this is the one case
  where a working connection is replaced on purpose. It waits while a download or an upload is
  running on the location - a dropped `fetchContents` is never re-issued (MQ-036) - and is asked
  again at the next re-check, or taken up by the next reconnect that happens anyway, since the
  answer is on record by then. Three inconclusive re-checks in a row with the master still running
  is wording nobody has seen, and that connection stops asking; the next connect probes again.

Answers that did come back but keep the location below the tier its `watchMode` asks for - no
shell, a `noexec` cache directory, a budget with no channel for the helper - are asked again on
the same connection every 30 minutes, the budget only while it is below unrestricted, and the
ladder is re-applied ([change detection](change-detection.md)).
