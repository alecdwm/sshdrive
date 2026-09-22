# Troubleshooting

Start with `sshdrive doctor`. It prints one line per check with `ok`, `warn`, `fail` or
`note`, and a remedy under any line that is not `ok`. Everything below is organised by
what that line says, or by what you can see going wrong when `doctor` is green.

`sshdrive logs` is the other half: it reads our own log **and** the `fileproviderd` lines
about our domains, which is where the system records what it asked for and what it made of
the answer.

```sh
sshdrive doctor
sshdrive logs --last 30m          # everything, the last half hour
sshdrive logs -f nas              # one location, live
sshdrive status nas               # state, last error, held deletions, what the server can do
```

---

## What `doctor` checks, and what each failure means

The checks are listed in the order `doctor` prints them.

### `agent reachable` - fail

The CLI could not get an answer on the mach service.

- **"no answer on the mach service"**: the login item is not registered, or is switched
  off. Run `open -g -a "SSH Drive"` once. If that does not fix it, System Settings →
  General → Login Items & Extensions, and switch SSH Drive on.
- **"the agent answered the connection but not the command in time"**: the agent is alive
  and wedged, usually behind a File Provider call that has not returned. `sshdrive agent
  restart`. This is a different fault from being unreachable and gets a different line on
  purpose.

#### The agent will not start after an upgrade

The most common cause of a suddenly unreachable agent. Everything worked, the app was
replaced, and now nothing can reach the agent. The log shows launchd retrying every 10
seconds:

```
Could not find and/or execute program specified by service: 3: No such process
Service could not initialize: copy_bundle_path(...), error 0x6f
```

A login item whose bundle was deleted and put back keeps its enabled status while launchd
cannot resolve the program, and `SMAppService.register()` keeps returning success
because as far as it is concerned the item is still enabled. Only `unregister()` clears it.

The cask's `postflight` does this automatically. By hand:

```sh
SSHDRIVE_AGENT_ROLE=unregister "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"
open -g -a "/Applications/SSH Drive.app"
sshdrive doctor
```

No logout is needed. Locations, domains, the cache and pending uploads all survive.

### `CLI on PATH` - warn

`sshdrive` is not in any directory on your `PATH`. The cask symlinks it; a hand-installed
bundle does not. Either add the symlink yourself or call it by its full path:

```sh
"/Applications/SSH Drive.app/Contents/MacOS/sshdrive" doctor
```

### `app in /Applications` - fail

The bundle is somewhere else. The Homebrew cask puts it in `/Applications`; a copy run from
`~/Downloads` or a build directory will work for a while and then confuse LaunchServices
and the login item. Move it.

### `macOS version` - fail

Minimum is macOS 14. Nothing here is going to work on 13.

### `login item` - fail

`SMAppService` reports the login item as `requires approval`, `not registered` or
`not found`.

- **not registered / not found**: the app has never been launched from its own bundle.
  `open -g -a "SSH Drive"`.
- **requires approval**: switch SSH Drive on under System Settings → General → Login Items
  & Extensions. On a signed, notarized install this state should not occur: a fresh user
  gets the item already **enabled**, and the "Background Items Added" notification is
  telling, not asking.

### `app group container` - fail

Either the agent is unsigned or missing its `application-groups` entitlement, or the
container exists and is not writable. On a cask install neither happens. On a hand-built
copy, check the signature: `codesign -d --entitlements - --xml "/Applications/SSH Drive.app"`.

The container is
`~/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive/`, and it holds `config.json`,
`domains/<location-id>/index.sqlite`, `capabilities.json` and `pins.json`.

Note that the *directory* existing proves nothing: `containermanagerd` creates an empty
skeleton for every installed app's group at first login. `config.json` inside it is the
thing that means "this has run here".

### `quarantine` - fail

The app bundle still carries `com.apple.quarantine`, the attribute macOS puts on anything
unpacked from a download. The agent does not care (launchd starts it directly), but
**LaunchServices registers no plugin of a quarantined bundle that has never been assessed
through a launch a person saw**, and `open -g` is not such a launch. The File Provider
extension therefore does not exist as far as the system is concerned. The rest of the
picture is the `extension registered` failure below, `file provider domains` failing with
*The application cannot be used right now*, and `sshdrive logs` showing fileproviderd
saying

```
getDomainsForProviderIdentifier((null)) failed: FP -2001 Underlying FP -2014
```

(-2001 is "provider not found", -2014 "application extension not found"), while the agent
is running and reachable, the login item is enabled, and no mount ever appears in Finder.

```sh
xattr -dr com.apple.quarantine "/Applications/SSH Drive.app"
open -g -a "SSH Drive"
sshdrive doctor
```

That registers the extension durably. `pluginkit -a` on the appex appears to fix it, and
the next launch wipes the registration again.

Nothing is being bypassed by removing the attribute. The DMG was checked on the download
path and the notarization ticket is stapled to the app; `spctl --assess --type execute
"/Applications/SSH Drive.app"` says so, and the cask's `postflight` runs exactly that check
before it strips the attribute, so a `brew install --cask sshdrive` should not land here. A
copy you dragged out of the DMG by hand needs the two commands above.

#### Gatekeeper refuses to open the app

*"Apple could not verify "SSH Drive" is free of malware"* means the copy you have is not
notarized: a build from source, or a release that skipped the notarization step. A cask
install is notarized, assesses itself in the `postflight` and then clears the quarantine
attribute, so it shows no Gatekeeper dialog at all.

```sh
spctl --assess --type execute --verbose=4 "/Applications/SSH Drive.app"
```

`accepted / source=Notarized Developer ID` is what a shipped build says.

### `extension registered` - fail

PlugInKit does not know about `SSHDriveFileProvider.appex`. Launching the app from its own
bundle is what registers it, and a symlinked CLI cannot do it:

```sh
open -g -a "SSH Drive"
pluginkit -m -A -i org.shirls.sshdrive.fileprovider -vvv
```

**Check the `quarantine` line first: a quarantined bundle is the usual cause**, and
re-registering the appex by hand does not survive the next launch. Otherwise the bundle is
probably not where LaunchServices thinks it is.

### `index reader (<name>)` - warn

One line per mounted location: what the File Provider extension last reported about its
read-only view of that location's index. `ok` is `ready`. Anything else is a warning, not a
failure, because every read the extension cannot answer itself falls back to the agent, so
the location keeps working, only more slowly.

- **"the extension has never reported its reader"**: open the location in Finder once. If
  the line stays like this, the extension is not running; look at `extension registered`.
- **any other state**, with the time it was reported and its last error: a reader that
  stays unready is worth an issue, with `sshdrive logs` attached.

### `ssh` - fail

`/usr/bin/ssh` could not be run. SSH Drive uses the system `ssh` by absolute path and never
a `PATH` lookup, so a Homebrew OpenSSH does not affect this line.

### `~/.ssh/config parses` - fail

`ssh -G` failed against a name nothing can match, which means one of your `Host *` blocks
or `Include`d files uses a keyword Apple's build of OpenSSH does not know. A config written
for a newer Homebrew `ssh` does this. Guard the block with `Match exec` or remove the
keyword. The exact diagnostic is in the check's detail line.

### `control sockets` - fail

There are `sshdrive-*` sockets in `$TMPDIR` that no live location owns: an agent crashed
and left its `ssh -N` masters behind. `sshdrive agent restart` sweeps them: it sends each
socket `-O exit`, unlinks it, and kills the `ssh` that owned it if it is still there.

`doctor` reports them rather than sweeping them, because adopting or killing a master while
a location is mounted would be a repair nobody asked for.

### `keychain` - fail

The agent could not reach the data-protection keychain. This is almost always a signing
problem, not a keychain problem: `keychain-access-groups` is a restricted entitlement, and
it only works when the bundle embeds a provisioning profile that authorises **the exact
certificate the bundle was signed with**.

Passwords and key passphrases are the only thing that stops working; browsing, fetching and
writing do not use the keychain. A build from source, or one signed with a Developer ID
certificate the embedded profile was not issued for, is in this state. A cask install is
never in it; `brew reinstall --cask sshdrive` replaces a copy that is.

### `login shell snapshot` - warn

The agent takes `PATH` and `SSH_AUTH_SOCK` from a fresh login shell, which is what makes a
key agent socket exported from `.zshrc`, and a `ProxyCommand` in `/opt/homebrew/bin`, work
from a launchd job. If the snapshot failed, the agent falls back to launchd's environment
and those two things will not be found.

`csh` and `tcsh` are read with `-ic` rather than `-l`, so a `PATH` set only in `.login` is
missed; the check says so when that applies.

### `file provider domains`

Informational: the domains the system currently holds for us. If a location is `mounted` in
`sshdrive list` but missing here, `sshdrive mount <name>` re-adds it.

*The application cannot be used right now* on this line is not about a location at all: the
system cannot find our extension, and the `quarantine` and `extension registered` lines
above say why.

### `uninstall reminder` - note

Always printed, and never a fault: run `sshdrive remove --all` before
`brew uninstall --cask sshdrive`, because Homebrew cannot remove File Provider domains or
keychain items ([uninstalling](install.md#uninstalling)).

---

## Things that go wrong with `doctor` green

### The Finder sidebar entry is there but nothing lists

Check `sshdrive status <name>` first. Its first line gives the location's state, and a
`last error` line follows whenever there is one. The state is one of:

- **`not mounted`**: the location is saved but has no domain. `sshdrive mount <name>`.
- **`idle (not connected)`**: mounted, and nothing has asked for it since the agent
  started. Opening it in Finder connects it.
- **`online`**: connected.
- **`offline (<reason>)`**: not connected, with the reason: no network connection, the
  last attempt failed and the next is due in so many seconds, or reconnection has stopped
  (an authentication failure, a host key that did not match, or the 60 s authentication
  deadline).

`sshdrive show <name>` prints the resolved `ssh` command and the last error too. A location
that suddenly asks for a password it had stored is a keychain problem (above).

A listing that hangs and then fails is usually the 60 s authentication deadline
([secrets and host keys](design/secrets.md)). Nothing may wait for a human unattended, so
a connection that needs a touch, a one-time code or an unstored passphrase is stopped
rather than left hanging. To replace a stored password or passphrase, remove the location
and add it again; `add` asks for the secret and stores it:

```sh
sshdrive remove nas
sshdrive add nas alec@nas.local
```

`remove` asks first unless you pass `-y`, and refuses while the location has uploads
pending unless you pass `--force`, which discards them. Its downloaded files go with it.

After fixing an authentication failure in place (a key added to the agent, a password
changed back on the server), `sshdrive debug breaker <name> --connect` clears the stop and
tries once. `sshdrive agent restart` also clears it, for every location.

### It asks for Local Network permission, or cannot see a server on the LAN

macOS asks *"Allow "SSH Drive" to find devices on local networks?"* the first time the
agent connects to a server on your own network. There is no entitlement that suppresses it
and a launchd agent has no window to put it over, so it arrives in the app's name, once.

If it was refused, a server on the LAN is unreachable and one reached over the internet or
a VPN is not. Fix it in System Settings → Privacy & Security → Local Network.

### Files do not update when they change on the server

`sshdrive status <name>` names the tier in use and why
([remote change detection](design/change-detection.md)):

- **tier 0, poll**: an SFTP `readdir` of the watched directories. Minutes.
- **tier 1, sweep**: one `find` over an ssh exec channel. Up to a minute.
- **tier 2, helper**: a small static binary on the server pushing changes. About a second.

A location drops down the ladder when the server cannot support the tier above, and says
which reason applies: no shell access (`ForceCommand internal-sftp`), no spare channel
(`MaxSessions 2`), an unknown architecture, or `helper off`.

Only the **root set** is watched ([the root set](design/root-set.md)): directories with
materialized files, pinned subtrees, and folders you have looked at in the last 30
minutes, capped at 256. Nothing else is polled, by design. `sshdrive debug roots <name>` shows the set.

Two other things worth knowing:

- **A folder is enumerated once, ever.** Re-opening it in Finder produces no request at
  all; everything after the first listing arrives through the change stream.
- **A busybox server has no `find -cmin`**, so its sweep falls back to `-mmin` and will not
  notice a `chmod` on a file whose contents did not change. `status` says so.

### A lot of files vanished from the server and Finder still shows them

That is the mass-deletion guard ([remote change detection](design/change-detection.md)).
A listing that removes at least half a directory and at least 20 items, or empties a
non-empty root, is **held** rather than applied, and re-checked at 5 and 30 minutes. Deletions of items with a pending local edit are always
held.

```sh
sshdrive status nas               # says how many, and why
sshdrive accept-deletions nas     # apply them
```

A fetch of a held item fails with "cannot synchronize" and leaves the file in place, which
is the honest state.

### A file will not evict, or the cache is not shrinking

- Pinned items are never evicted. That is the whole point of a pin ([pinning](design/pinning.md)).
  `sshdrive pins <name>` shows the tree.
- An item with an upload still pending is refused, and the refusal says nothing about why:
  a pending upload and a kept item both come back as the same error.
- `evict --all` is one call on the root container. It fails as a whole if it meets a kept
  child, and after `--unpin-all` (which removes every pin first) it fails for at least a
  minute, because the system has not re-read the rows whose policy just changed; a single
  file becomes evictable 5-10 seconds after an unpin. In both cases the command falls back to walking
  the materialized set file by file, which leaves the directory rows materialized. That is
  expected ([cache eviction](design/eviction.md)).
- The TTL is time since the **last fetch or save**, not since the last read
  ([cache eviction](design/eviction.md)). Reading a file that is already downloaded does
  not keep it alive.

### An edit made offline has not been uploaded

The system holds the write and re-offers it on its own backoff; the agent flushes it when
the connection returns. `sshdrive debug materialized <name> --pending` lists the system's
own pending set, which is where a write that has not gone out yet is.

### A symlink shows as an alias, or a `ln -s` was refused

Symlinks are shown as native items and never followed ([symlinks](design/symlinks.md)).
A link whose target lands outside the location's root is not shown at all, and creating one
inside the mount is refused. The refusal arrives as the item's own sync error rather than
as an alert: Finder marks the item, and `sshdrive logs` has the reason.

Finder draws every symlink as Kind "Alias" with the arrow badge, dangling or not.

### The host key changed

Every connection after `add` runs with `StrictHostKeyChecking=yes`, so a changed key stops
the location, and `sshdrive status <name>` prints the `ssh-keygen -R` line to run. The
agent never accepts a key on its own, so after removing the old one, connect once with your
own `ssh` to the same destination and answer its fingerprint question, which writes the new
key to `~/.ssh/known_hosts`. Then clear the stop:

```sh
ssh-keygen -R nas.local
ssh alec@nas.local                  # check the fingerprint, answer yes, log out
sshdrive debug breaker nas --connect
```

`sshdrive agent restart` clears the stop as well.

## Nothing above helped

```sh
sshdrive logs --last 1h > /tmp/sshdrive.log
sshdrive status --json >> /tmp/sshdrive.log
sshdrive doctor --json >> /tmp/sshdrive.log
```

and open an issue at <https://github.com/alecdwm/sshdrive/issues>. Hostnames and paths are
logged deliberately so that log is readable; secrets are never interpolated into a log line
at all, but read it before posting it.
