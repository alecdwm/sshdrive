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
| Laptop wakes from sleep | Same path as network returns; the masters were already dropped at the will-sleep message ([ssh](ssh.md#dead-connections)). |
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
without being asked (rule 5), and a read that meets a silently dead connection is retried once
through the breaker (rule 4).

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

    - 2 s, doubling to 60 s;
    - 300 s while the failure is a key agent that is not ready ([ssh](ssh.md#key-agents));
    - a path change or wake from sleep resets it.

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
   per-request deadline ([sftp](sftp.md#request-deadlines)) and, after sleep, by dropping the
   master outright ([ssh](ssh.md#dead-connections)), so the breaker opens within seconds rather
   than after the keepalive window. The request that finds it is **retried once**, through the
   breaker, if it is a read or a metadata call: the retry either waits for the attempt under rule 2
   or fails fast because the breaker is open.

    Writes are not retried. An upload's source cannot be replayed and a `rename` that may already
    have landed must not be re-sent; a failed write is the one thing the system does re-offer.
    Without the read retry, the first double-click after a master died is spent discovering the
    death, and since the system never re-issues a failed `fetchContents` (MQ-036), that one call is
    the whole of the user's experience of it.

5. **The backoff is a reconnect schedule.** When it expires the agent attempts a connection whether
   or not anything has asked, and a connection that drops is attempted again at once. The reason
   is rule 4's: waiting to be asked would make "the server came back" mean "the user clicked
   twice". The attempt is what produces the `signalErrorResolved` that flushes the queue.

6. **Auth and host-key failures bypass the breaker.** They stop reconnection until the user acts
   ([ssh](ssh.md#exit-classification)):

    - any `sshdrive set` change to the location;
    - `sshdrive agent restart` (the breaker lives in the agent's memory);
    - `sshdrive debug breaker <name> --connect`, which clears the stop and attempts once.

    A deadline stop is also re-armed for one attempt by a screen unlock or a request arriving with
    the user present ([secrets](secrets.md)). A stopped location gets no reconnect schedule: under
    rule 5 a stale password would be retried every minute, which is a `fail2ban` ban within the
    hour.
