# Troubleshooting

Start with `sshdrive doctor`. It prints one line per check with `ok`, `warn` or `fail`, and
a remedy under any line that is not `ok`. Everything below is organised by what that line
says, or by what you can see going wrong when `doctor` is green.

`sshdrive logs` is the other half: it reads our own log **and** the `fileproviderd` lines
about our domains, which is where the system records what it asked for and what it made of
the answer.

```sh
sshdrive doctor
sshdrive logs --last 30m          # everything, the last half hour
sshdrive logs -f nas              # one location, live
sshdrive status nas               # sync errors, held deletions, what the server can do
```

---

## What `doctor` checks, and what each failure means

### `agent reachable` — fail

The CLI could not get an answer on the mach service.

- **"no answer on the mach service"**: the login item is not registered, or is switched
  off. Run `open -g -a "SSH Drive"` once. If that does not fix it, System Settings →
  General → Login Items & Extensions, and switch SSH Drive on.
- **"the agent answered the connection but not the command in time"**: the agent is alive
  and wedged, usually behind a File Provider call that has not returned. `sshdrive agent
  restart`. This is a different fault from being unreachable and gets a different line on
  purpose.

The most common cause of a suddenly unreachable agent is an upgrade that replaced the
bundle without the unregister step — see **"the agent will not start after an upgrade"**
below.

### `app in /Applications` — fail

The bundle is somewhere else. The Homebrew cask puts it in `/Applications`; a copy run from
`~/Downloads` or a build directory will work for a while and then confuse LaunchServices
and the login item. Move it.

### `macOS version` — fail

Minimum is macOS 14. Nothing here is going to work on 13.

### `login item` — fail

`SMAppService` reports the login item as `requires approval`, `not registered` or
`not found`.

- **not registered / not found**: the app has never been launched from its own bundle.
  `open -g -a "SSH Drive"`.
- **requires approval**: switch SSH Drive on under System Settings → General → Login Items
  & Extensions. On a signed, notarized install this state should not occur — a fresh user
  gets the item already **enabled**, and the "Background Items Added" notification is
  telling, not asking (measured on a clean account, 2026-09-04).

### `app group container` — fail

Either the agent is unsigned or missing its `application-groups` entitlement, or the
container exists and is not writable. On a cask install neither happens. On a hand-built
copy, check the signature: `codesign -d --entitlements - --xml "/Applications/SSH Drive.app"`.

The container is
`~/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive/`, and it holds `config.json`,
`domains/<location-id>/index.sqlite`, `capabilities.json` and `pins.json`.

Note that the *directory* existing proves nothing: `containermanagerd` creates an empty
skeleton for every installed app's group at first login. `config.json` inside it is the
thing that means "this has run here".

### `extension registered` — fail

PlugInKit does not know about `SSHDriveFileProvider.appex`. Launching the app from its own
bundle is what registers it, and a symlinked CLI cannot do it:

```sh
open -g -a "SSH Drive"
pluginkit -m -A -i org.shirls.sshdrive.fileprovider -vvv
```

If it stays unregistered, the bundle is probably not where LaunchServices thinks it is.

### `ssh` — fail

`/usr/bin/ssh` could not be run. SSH Drive uses the system `ssh` by absolute path and never
a `PATH` lookup, so a Homebrew OpenSSH does not affect this line.

### `~/.ssh/config parses` — fail

`ssh -G` failed against a name nothing can match, which means one of your `Host *` blocks
or `Include`d files uses a keyword Apple's build of OpenSSH does not know. A config written
for a newer Homebrew `ssh` does this. Guard the block with `Match exec` or remove the
keyword. The exact diagnostic is in the check's detail line.

### `control sockets` — fail

There are `sshdrive-*` sockets in `$TMPDIR` that no live location owns: an agent crashed
and left its `ssh -N` masters behind. `sshdrive agent restart` sweeps them — it sends each
socket `-O exit`, unlinks it, and kills the `ssh` that owned it if it is still there.

`doctor` reports them rather than sweeping them, because adopting or killing a master while
a location is mounted would be a repair nobody asked for.

### `keychain` — fail

The agent could not reach the data-protection keychain. This is almost always a signing
problem, not a keychain problem: `keychain-access-groups` is a restricted entitlement, and
it only works when the bundle embeds a provisioning profile that authorises **the exact
certificate the bundle was signed with**.

A build signed with a Developer ID certificate the embedded profile was not issued for
loses the entitlement silently — or, if the entitlement is left in, is killed at exec.
`docs/release.md` has the check to run. A cask install is never in this state.

Passwords and key passphrases are the only thing that stops working; browsing, fetching and
writing do not use the keychain.

### `login shell snapshot` — warn

The agent takes `PATH` and `SSH_AUTH_SOCK` from a fresh login shell, which is what makes a
key agent socket exported from `.zshrc`, and a `ProxyCommand` in `/opt/homebrew/bin`, work
from a launchd job. If the snapshot failed, the agent falls back to launchd's environment
and those two things will not be found.

`csh` and `tcsh` are read with `-ic` rather than `-l`, so a `PATH` set only in `.login` is
missed; the check says so when that applies.

### `file provider domains`

Informational: the domains the system currently holds for us. If a location is `mounted` in
`sshdrive list` but missing here, `sshdrive mount <name>` re-adds it.

---

## Things that go wrong with `doctor` green

### The Finder sidebar entry is there but nothing lists

Check `sshdrive status <name>` first. It prints the location's state, its last error, the
sync errors the system is holding, and the capability report.

- **`serverUnreachable`**: the agent cannot connect. `sshdrive show <name>` prints the
  resolved `ssh` command and the last error. A location that has just started asking for a
  password it used to have stored is a keychain problem (above).
- A listing that hangs and then fails is usually the 60 s authentication deadline. Nothing
  may wait for a human unattended, so a connection that needs a touch, a one-time code or
  an unstored passphrase is stopped rather than left hanging. `sshdrive passwd <name>` (or
  `add` again) is how a secret gets stored.

### It asks for Local Network permission, or cannot see a server on the LAN

macOS asks *"Allow "SSH Drive" to find devices on local networks?"* the first time the
agent connects to a server on your own network. There is no entitlement that suppresses it
and a launchd agent has no window to put it over, so it arrives in the app's name, once.

If it was refused, a server on the LAN is unreachable and one reached over the internet or
a VPN is not. Fix it in System Settings → Privacy & Security → Local Network.

### Files do not update when they change on the server

`sshdrive status <name>` names the tier in use and why:

- **tier 0, poll** — an SFTP `readdir` of the watched directories. Minutes.
- **tier 1, sweep** — one `find` over an ssh exec channel. Up to a minute.
- **tier 2, helper** — a small static binary on the server pushing changes. About a second.

A location drops down the ladder when the server cannot support the tier above, and says
which reason applies: no shell access (`ForceCommand internal-sftp`), no spare channel
(`MaxSessions 2`), an unknown architecture, or `helper off`.

Only the **root set** is watched: directories with materialized files, pinned subtrees, and
folders you have looked at in the last 30 minutes, capped at 256. Nothing else is polled,
by design. `sshdrive debug roots <name>` shows the set.

Two other things worth knowing:

- **A folder is enumerated once, ever.** Re-opening it in Finder produces no request at
  all; everything after the first listing arrives through the change stream.
- **A busybox server has no `find -cmin`**, so its sweep falls back to `-mmin` and will not
  notice a `chmod` on a file whose contents did not change. `status` says so.

### A lot of files vanished from the server and Finder still shows them

That is the mass-deletion guard. A listing that removes at least half a directory and at
least 20 items — or empties a non-empty root — is **held** rather than applied, and
re-checked at 5 and 30 minutes. Deletions of items with a pending local edit are always
held.

```sh
sshdrive status nas               # says how many, and why
sshdrive accept-deletions nas     # apply them
```

A fetch of a held item fails with "cannot synchronize" and leaves the file in place, which
is the honest state.

### A file will not evict, or the cache is not shrinking

- Pinned items are never evicted. That is the whole point of a pin. `sshdrive pins` shows
  the tree.
- An item with an upload still pending is refused, and the refusal says nothing about why:
  a pending upload and a kept item both come back as the same error.
- `evict --all` is one call on the root container, and it fails as a whole if it meets a
  kept child — and for 5-10 seconds after an unpin, before the system has re-read the
  changed rows. It then falls back to walking the materialized set file by file, which
  leaves the directory rows materialized. That is expected.
- The TTL is time since the **last fetch or save**, not since the last read. Reading a file
  that is already downloaded does not keep it alive.

### An edit made offline has not been uploaded

The system holds the write and re-offers it on its own backoff; the agent flushes it when
the connection returns. If the location is online and a write is still pending,
`sshdrive status <name>` lists it. `sshdrive debug materialized <name> --pending` shows the
system's own pending set.

### A symlink shows as an alias, or a `ln -s` was refused

Symlinks are shown as native items and never followed. A link whose target lands outside
the location's root is not shown at all, and creating one inside the mount is refused. The
refusal arrives as the item's own sync error rather than as an alert, so
`sshdrive status <name>` is where the sentence is.

Finder draws every symlink as Kind "Alias" with the arrow badge, dangling or not.

### The host key changed

No command of ours. `sshdrive status` prints the `ssh-keygen -R` line to run, and then the
location reconnects.

---

## The agent will not start after an upgrade

Symptom: everything worked, the app was replaced, and now nothing can reach the agent. The
log shows launchd retrying every 10 seconds:

```
Could not find and/or execute program specified by service: 3: No such process
Service could not initialize: copy_bundle_path(...), error 0x6f
```

A login item whose bundle was deleted and put back keeps its enabled status while launchd
can no longer resolve the program, and `SMAppService.register()` keeps returning success
because as far as it is concerned the item is still enabled. Only `unregister()` clears it.

The cask's `postflight` does this automatically. By hand:

```sh
SSHDRIVE_AGENT_ROLE=unregister "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"
open -g -a "/Applications/SSH Drive.app"
sshdrive doctor
```

No logout is needed. Locations, domains, the cache and pending uploads all survive.

## Gatekeeper refuses to open the app

*"Apple could not verify "SSH Drive" is free of malware"* means the copy you have is not
notarized — a build from source, or a release that skipped the notarization step. A cask
install is notarized and shows only the one-time *"downloaded from the Internet"* dialog.

```sh
spctl --assess --type execute --verbose=4 "/Applications/SSH Drive.app"
```

`accepted / source=Notarized Developer ID` is what a shipped build says.

## `sshdrive` is not on PATH

`doctor` warns about this. The cask symlinks it; a hand-installed bundle does not. Either
add the symlink yourself or call it by its full path:

```sh
"/Applications/SSH Drive.app/Contents/MacOS/sshdrive" doctor
```

## Nothing above helped

```sh
sshdrive logs --last 1h > /tmp/sshdrive.log
sshdrive status --json >> /tmp/sshdrive.log
sshdrive doctor --json >> /tmp/sshdrive.log
```

and open an issue at <https://github.com/alecdwm/sshdrive/issues>. Hostnames and paths are
logged deliberately so that log is readable; secrets are never interpolated into a log line
at all, but read it before posting it.
