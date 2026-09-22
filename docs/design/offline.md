# Offline behaviour

A mount whose server is unreachable has to stay usable for everything already
on the Mac, fail everything else in under a second, and come back without the
user doing anything. The table is what the user sees; the gating rules below
are what the agent does to produce it.

## End to end

| Situation | What happens |
|---|---|
| Open a file already downloaded, network down | Reads served by the system from local storage. We are not called. |
| Browse a folder listed before, network down | Served from the system's replica; the refresh request gets `.serverUnreachable` and Finder shows the cached listing. |
| Browse a never-listed folder, network down | `.serverUnreachable` at once; Finder shows the folder as unavailable. |
| Save a file, network down | System stores it locally, marks it "waiting to upload", calls `modifyItem` again on retry. The agent fails fast until it can connect, then the flush goes through. |
| Network returns | Agent's `NWPathMonitor` fires → connection attempt → on success `signalErrorResolved(.serverUnreachable)` on every domain, which is the system's cue to retry pending uploads and fetches, then `signalEnumerator` for the working set, and `reconnect()` if `disconnect(reason:)` had been used. **`signalErrorResolved` is the one that does it, and it is not optional:** measured on macOS 26.4, 2026-09-04, the queued `modifyItem` arrived 20 ms after the signal, and neither reconnecting on its own nor `signalEnumerator` for the working set wakes the flush at all. The working-set signal is still sent, for the working set. |
| Laptop wakes from sleep | Same path as network returns; the masters were already dropped at the will-sleep message (`docs/design/ssh.md`). |
| Agent not running | Domain shows a disconnect message (`docs/design/extension.md`); everything already cached keeps working. |

**What the system does while we are down decides how hard the agent has to
try.** Both halves were measured on macOS 26.4, 2026-09-04. A queued
`modifyItem` is re-offered with a doubling backoff - 5.5 s, 10.6 s, 20.3 s,
43 s, 79 s, 153 s, 331 s - which is past five minutes after ten minutes
offline and still growing, and each retry arrives on a freshly launched
extension instance. A `fetchContents` that failed is **never** re-issued: the
read that provoked it gets `ETIMEDOUT` and nothing comes back until something
opens the file again. So an agent that only reconnected when it was asked
would leave a mount dead until the user clicked it, and a save waiting on an
interval that only grows. Two things follow, and both are rules below: the
agent reconnects on the breaker's backoff **without being asked**, and a read
that meets a connection which died silently is retried once through the
breaker rather than surfaced.

Repeated failure has a second cost, on the working set rather than on one
call. fileproviderd throttles a working-set change enumeration that keeps
failing, and the throttle has no ceiling: 27 consecutive `.serverUnreachable`
answers on a real domain produced a 47-minute retry interval, and a mount that
took no server-side change at all while every other path worked (measured
2026-09-08). Only `signalErrorResolved` clears it, so the working set has an
XPC fallback and both the extension and the agent clear the backoff
explicitly.

We deliberately do not use `disconnect(reason:)` for network outages;
throwing `.serverUnreachable` is enough and keeps the domain writable. The
agent calls `disconnect` with a human message only for refused prompts,
host-key changes, a root that no longer canonicalises to what `add`
recorded (`docs/design/security.md`) and the agent-missing case, where
retrying is pointless until the user acts. A stop caused by the
authentication deadline (`docs/design/secrets.md`) does not disconnect the
domain: requests keep arriving, fail fast with `.serverUnreachable` while
the location is stopped, and the first one that arrives while the user is
present is what re-arms the attempt, so the domain has to stay connected for
that trigger to exist. `sshdrive status` carries the explanation in that
case.

## Failing fast when offline

Waiting for a TCP timeout freezes Finder, so every remote call is gated:

1. `NWPathMonitor` says no path at all → `.serverUnreachable` immediately.
   This covers Wi-Fi off, but not a powered-down NAS or a tailnet that is
   down while the Mac is online.
2. A per-location **circuit breaker** covers the rest: after a failed
   connection attempt the location is marked down for a backoff interval
   (2 s, doubling to 60 s), during which every call fails fast without
   touching the network. A path change, wake from sleep, or `sshdrive test`
   resets the breaker. **While an attempt is in progress, calls wait for
   it**, bounded by the attempt's own remaining deadline: at most the 60 s
   authentication deadline (`docs/design/secrets.md`), measured from the
   spawn of `ssh`, which already contains the 15 s `ConnectTimeout` of the
   TCP and banner phase (never the two added together). When the attempt
   succeeds the waiting calls run; when it fails they all get
   `.serverUnreachable` at once and the breaker opens. Failing them fast
   instead was considered and rejected: the first enumeration after login
   or wake would arrive during the connect, fail immediately, and Finder
   would show the folder as unavailable until the user clicked again,
   since the system does not retry an enumeration on its own. A spinner
   for the length of one connect is the better of the two.
3. `ConnectTimeout=15` bounds the TCP and banner phase of the one attempt
   that does go out. 15 rather than 5 because `ProxyCommand` tunnels such
   as `cloudflared access ssh` routinely take longer than 5 s to hand over
   a connection. The 60 s authentication deadline
   (`docs/design/secrets.md`) runs from the same spawn and bounds the whole
   attempt.
4. A connection that died silently is found by the per-request deadline
   (`docs/design/sftp.md`) and, after sleep, by dropping the master
   outright (`docs/design/ssh.md`), so the breaker opens within seconds
   rather than after the keepalive window. The request that finds it is
   **retried once**, through the breaker, if it is a read or a metadata
   call: by then the breaker is either connecting, in which case the retry
   waits for the attempt under rule 2, or open, in which case it fails fast
   as it should. Writes are not retried - an upload's source cannot be
   replayed and a `rename` that may already have landed must not be
   re-sent - and they need no help, because a failed write is the one thing
   the system does re-offer on its own. Without the read retry the first
   double-click after a master died is spent discovering the death: the
   system never re-issues a `fetchContents` that failed (measured on macOS
   26.4, 2026-09-04), so that one call is the whole of the user's
   experience of it.
5. **The breaker's backoff is a reconnect schedule, not only a refusal
   window.** When it expires the agent attempts a connection whether or
   not anything has asked, and a connection that drops is attempted again
   at once. Same reason as rule 4: the system re-offers a queued write on
   an interval that has passed five minutes by the time the mount has been
   down ten, and re-offers a failed read never, so waiting to be asked
   would make "the server came back" mean "the user clicked twice". The
   attempt is what produces the `signalErrorResolved` in the table above,
   which is what flushes the queue.
6. Auth and host-key failures do not go through the breaker at all: they
   stop reconnection until the user acts (`docs/design/ssh.md`), or, for a
   deadline stop, until screen unlock, or a request arriving with the user
   present, re-arms one attempt (`docs/design/secrets.md`). A stopped
   location gets no reconnect schedule: rule 5 would be a stale password
   retried every minute, which is a `fail2ban` ban within the hour.

Two measurements on macOS 26.4, 2026-09-04, are what the bounded wait of
rule 2 rests on: the system does **not** time out an `enumerateItems` held
for the full 60 s - it waited 60.19 s, took the answer and left the
extension running - and requests keep arriving at the extension while the
domain is connected and every call fails fast, which is what the
present-user re-arm rides on (`docs/design/secrets.md`). What Finder draws
during the wait is a circular progress indicator in place of the item's
dataless badge, for the length of the connect, with no alert.
