# Troubleshooting

Start with `sshdrive doctor`. It prints one line per check, marked `ok`, `warn`, `fail` or
`note`, with a remedy under every line that is not `ok`. Find the check by name below; if
`doctor` is all green, skip to [Problems with `doctor` green](#problems-with-doctor-green).

```sh
sshdrive doctor
sshdrive status nas               # state, last error, held deletions, what the server can do
sshdrive logs --last 30m          # the last half hour
sshdrive logs -f nas              # one location, live
```

`sshdrive logs` shows SSH Drive's own log and the system's `fileproviderd` lines about your
locations. The second half is where macOS records what it asked for and what it made of the
answer.

## `doctor` checks

In the order `doctor` prints them.

### `agent reachable` (fail)

The CLI got no answer from the background agent. The detail line says which of two faults it
is:

| Detail | Meaning | Fix |
|---|---|---|
| no answer on the mach service | The login item is not registered, or is switched off | `open -g -a "SSH Drive"`. If that does not help, switch SSH Drive on in System Settings → General → Login Items & Extensions |
| the agent answered the connection but not the command in time | The agent is running but stuck, usually behind a File Provider call that has not returned | `sshdrive agent restart` |

#### The agent will not start after an upgrade

This is the usual cause of an agent that worked until the app was replaced. The log shows
launchd retrying every 10 seconds:

```
Could not find and/or execute program specified by service: 3: No such process
Service could not initialize: copy_bundle_path(...), error 0x6f
```

The login item still looks enabled, but launchd cannot find the program, and registering it
again does nothing until it has been unregistered. The cask's `postflight` does this for you.
By hand:

```sh
SSHDRIVE_AGENT_ROLE=unregister "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"
open -g -a "/Applications/SSH Drive.app"
sshdrive doctor
```

No logout is needed. Locations, mounts, cached files and pending uploads all survive.

### `CLI on PATH` (warn)

`sshdrive` is not in any directory on your `PATH`. The cask symlinks it; a bundle you
installed by hand does not. Add the symlink yourself, or use the full path:

```sh
"/Applications/SSH Drive.app/Contents/MacOS/sshdrive" doctor
```

### `app in /Applications` (fail)

The app is somewhere else. A copy run from `~/Downloads` or a build directory works for a
while and then confuses LaunchServices and the login item. Move it to `/Applications`, or
install with the Homebrew cask.

### `macOS version` (fail)

SSH Drive needs macOS 14 or newer.

### `login item` (fail)

The login item is not enabled. The detail line gives its state:

- **not registered** or **not found**: the app has never been launched from its own bundle.
  Run `open -g -a "SSH Drive"`.
- **requires approval**: switch SSH Drive on in System Settings → General → Login Items &
  Extensions. A signed, notarized install should not get here: a new user gets the item
  already enabled, and the "Background Items Added" notification is telling you, not asking.

### `app group container` (fail)

Either the agent is unsigned or missing its `application-groups` entitlement, or the container
exists and is not writable. A cask install has neither problem. On a copy you built yourself,
check the signature:

```sh
codesign -d --entitlements - --xml "/Applications/SSH Drive.app"
```

The container is `~/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive/` and holds
`config.json`, `domains/<location-id>/index.sqlite`, `capabilities.json` and `pins.json`.
The directory existing proves nothing: macOS creates an empty one for every installed app's
group at first login. `config.json` inside it is what shows SSH Drive has run.

### `quarantine` (fail)

The app still carries `com.apple.quarantine`, the attribute macOS puts on anything from a
download. The agent runs anyway, but macOS will not register the Finder extension of a
quarantined app that has never been opened in a way a person saw, and `open -g` does not
count. So no mount ever appears in Finder, while the agent is reachable and the login item is
enabled.

The other signs: `extension registered` fails, `file provider domains` fails with *The
application cannot be used right now*, and `sshdrive logs` shows

```
getDomainsForProviderIdentifier((null)) failed: FP -2001 Underlying FP -2014
```

Fix:

```sh
xattr -dr com.apple.quarantine "/Applications/SSH Drive.app"
open -g -a "SSH Drive"
sshdrive doctor
```

This registers the extension for good. `pluginkit -a` on the extension looks like a fix, but
the next launch undoes it.

Removing the attribute bypasses nothing. The app is notarized with the ticket stapled to it,
and `spctl --assess --type execute "/Applications/SSH Drive.app"` confirms that. The cask's
`postflight` runs that exact check before stripping the attribute, so `brew install --cask
sshdrive` should not land here. A copy dragged out of the DMG by hand needs the commands
above.

#### Gatekeeper refuses to open the app

*"Apple could not verify "SSH Drive" is free of malware"* means your copy is not notarized: a
build from source, or a release that skipped notarization. A cask install is notarized,
checks itself in the `postflight` and clears the quarantine attribute, so it shows no
Gatekeeper dialog at all. To check a copy:

```sh
spctl --assess --type execute -v "/Applications/SSH Drive.app"
```

A shipped build says `accepted / source=Notarized Developer ID`.

### `launch services records` (fail)

`doctor` reads the LaunchServices records only when `extension registered` would fail: a stale
record matters only while it keeps the extension unregistered, and reading them takes seconds.
With the extension registered this line says `not checked: the extension is registered`.

LaunchServices holds a record for another copy of `SSH Drive.app`, and the check names its
path. That usually means the app was opened once from the mounted DMG: the record for
`/Volumes/SSH Drive/SSH Drive.app` outlives the volume.

LaunchServices keys records on the bundle identifier, so the other copy's record answers every
registration of the installed one. `lsd` logs `skipping registration of an incomplete bundle`
and `Registration succeeded, but did not actually register anything new; returning existing
bundle`, and the extension is never registered. Drop the record the check names, then launch:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "/Volumes/SSH Drive/SSH Drive.app"
open -g -a "SSH Drive"
sshdrive doctor
```

The app does this itself when it finds the extension unregistered, and so does the agent on
every start, so opening the app once or `sshdrive agent restart` is usually enough.

### `extension registered` (fail)

macOS does not know about the Finder extension (`SSHDriveFileProvider.appex`). **Check
`launch services records` and `quarantine` first**: a record for another copy of the app is
the usual cause, a quarantined app is the other, and registering the extension by hand does
not survive the next launch.

If `brew install` or `brew upgrade` printed `internal error in Code Signing subsystem`,
`failed to scan /Applications/SSH Drive.app: -10822 from spotlight`, `Trace/BPT trap: 5` or
`-10810 kLSUnknownErr`, the cask's postflight could not reach LaunchServices and registered
nothing. Opening the app does the same work:

```sh
open -a "SSH Drive"
sshdrive doctor
```

To do the same by hand, rebuild the bundle's own record and launch:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R -trusted "/Applications/SSH Drive.app"
open -g -a "SSH Drive"
pluginkit -m -A -i org.shirls.sshdrive.fileprovider -vvv
```

If the extension is still missing, the app is probably not where LaunchServices thinks it is.

### `index reader (<name>)` (warn)

One line per mounted location, reporting how the Finder extension's direct read of that
location's data last went. `ok` means `ready`, or **"last extension instance exited N s ago"**:
macOS stops the extension whenever it is idle, and that is the line a quiet mount ordinarily
shows. Anything else is a warning rather than a failure: the location keeps working, only more
slowly.

- **"the extension has never reported its reader"**: open the location in Finder once. If
  the line stays like this, the extension is not running; see `extension registered`.
- **`closed`**: the agent shut the reader while it restored a damaged index, and the extension
  never heard that the restore had finished. Opening the location in Finder starts a fresh
  instance, which reads again.
- **any other state**, shown with when it was reported and its last error: if it stays
  unready, open an issue with `sshdrive logs` attached.

### `ssh` (fail)

`/usr/bin/ssh` could not be run. SSH Drive always uses the system `ssh` by that path, so a
Homebrew OpenSSH makes no difference to this line.

### `~/.ssh/config parses` (fail)

`ssh -G` failed on your config, which means a `Host *` block or an `Include`d file uses a
keyword Apple's OpenSSH does not know. A config written for a newer Homebrew `ssh` does this.
Guard the block with `Match exec` or remove the keyword. The detail line has the exact error.

### `control sockets` (fail)

There are `sshdrive-*` sockets in `$TMPDIR` that no location owns: an agent crashed and left
its `ssh` connections behind. `doctor` only reports them. To clean up:

```sh
sshdrive agent restart
```

The restart closes each leftover connection, removes its socket and kills the `ssh` process
if it is still running.

### `keychain` (fail)

The agent cannot reach the keychain. This is a signing problem, not a keychain problem: the
app needs an embedded provisioning profile issued for the exact certificate it was signed
with. A build from source, or one signed with a different Developer ID certificate, is in
this state. A cask install never is.

Only stored passwords and key passphrases stop working; browsing, opening and saving files
do not use the keychain. To replace a broken copy:

```sh
brew reinstall --cask sshdrive
```

Or use a key that needs no stored secret.

### `login shell snapshot` (warn)

The agent reads `PATH` and `SSH_AUTH_SOCK` from a fresh login shell. That is what lets a key
agent socket exported from `.zshrc`, or a `ProxyCommand` in `/opt/homebrew/bin`, work. When
the snapshot fails, the agent uses launchd's environment instead and will not find either.

`csh` and `tcsh` are read with `-ic` rather than `-l`, so a `PATH` set only in `.login` is
missed. The detail line says so when that applies.

### `file provider domains`

Informational: the locations macOS currently holds for SSH Drive. If `sshdrive list` shows a
location as mounted but it is missing here, re-add it:

```sh
sshdrive mount <name>
```

If this line fails with *The application cannot be used right now*, no location is at
fault: macOS cannot find the extension. See `quarantine` and `extension registered`.

### `uninstall reminder` (note)

Always printed, never a fault. Run `sshdrive remove --all` before `brew uninstall --cask
sshdrive`, because Homebrew cannot remove File Provider domains or keychain items
([uninstalling](install.md#uninstalling)).

## Problems with `doctor` green

### The sidebar entry is there but nothing lists

Run `sshdrive status <name>`. The first line is the location's state, and a `last error`
line follows when there is one.

| State | Meaning | What to do |
|---|---|---|
| `not mounted` | Saved, but not in Finder | `sshdrive mount <name>` |
| `idle (not connected)` | Mounted, and nothing has asked for it since the agent started | Open it in Finder; that connects it |
| `online` | Connected | - |
| `offline (<reason>)` | Not connected. The reason is no network, a failed attempt with the next one due in so many seconds, or reconnection stopped | For a stop, see below |

`sshdrive show <name>` prints the resolved `ssh` command and the last error too. A location
that suddenly asks for a password it had stored has a keychain problem; see
[`keychain`](#keychain-fail).

Reconnection stops after an authentication failure, a host key that did not match, or the
60 s authentication deadline. The deadline is the usual cause of a listing that hangs and
then fails: SSH Drive never waits for a person unattended, so a connection that needs a
touch, a one-time code or a passphrase it has not stored is stopped
([secrets and host keys](design/secrets.md)).

Once you have fixed the cause (added a key to the agent, changed a password back on the
server), clear the stop and try once:

```sh
sshdrive debug breaker <name> --connect
```

`sshdrive agent restart` also clears it, for every location.

To replace a stored password or passphrase, remove the location and add it again; `add` asks
for the secret and stores it:

```sh
sshdrive remove nas
sshdrive add nas alec@nas.local
```

`remove` asks first unless you pass `-y`. It refuses while uploads are pending unless you pass
`--force`, which discards them. The location's downloaded files go with it.

### The host key changed

A changed host key stops the location, and `sshdrive status <name>` prints the `ssh-keygen
-R` line to run. SSH Drive never accepts a new key on its own, so connect once with your own
`ssh` to write it to `~/.ssh/known_hosts`, then clear the stop:

```sh
ssh-keygen -R nas.local
ssh alec@nas.local                  # check the fingerprint, answer yes, log out
sshdrive debug breaker nas --connect
```

`sshdrive agent restart` clears the stop as well.

### Local Network permission, or a server on the LAN is unreachable

The first time the agent connects to a server on your own network, macOS asks *"Allow "SSH
Drive" to find devices on local networks?"*. It asks once, in the app's name, and nothing can
suppress it.

If you refused, servers on your LAN are unreachable while ones over the internet or a VPN
still work. Turn it back on in System Settings → Privacy & Security → Local Network.

### Files do not update when they change on the server

`sshdrive status <name>` names the method in use and why
([remote change detection](design/change-detection.md)):

| Tier | How | Delay |
|---|---|---|
| tier 0, poll | an SFTP directory listing of the watched folders | minutes |
| tier 1, sweep | one `find` run over ssh | up to a minute |
| tier 2, helper | a small program on the server pushing changes | about a second |

A location drops to a lower tier when the server cannot support a higher one, and `status`
says which reason applies: no shell access (`ForceCommand internal-sftp`), no spare channel
(`MaxSessions 2`), an unknown architecture, or `helper off`.

Only some folders are watched ([the root set](design/root-set.md)): those holding downloaded
files, pinned folders, and folders opened since the agent started, up to 256. Nothing else is
checked, by design. To see the list:

```sh
sshdrive debug roots <name>
```

Also:

- **Finder lists a folder once.** Opening it again sends no request; later changes arrive
  only through change detection.
- **busybox servers have no `find -cmin`**, so the sweep uses `-mmin` and misses a `chmod` on
  a file whose contents did not change. `status` says so.

### Many files vanished on the server but Finder still shows them

That is the mass-deletion guard ([remote change detection](design/change-detection.md)). A
change that removes at least half a directory and at least 20 items, or empties a non-empty
root, is held rather than applied, and checked again at 5 and 30 minutes. Deletions of files
with an unsaved local edit are always held.

```sh
sshdrive status nas               # how many are held, and why
sshdrive accept-deletions nas     # apply them
```

Opening a held file fails with "cannot synchronize" and leaves it in place.

### A file will not evict, or the cache is not shrinking

- **Pinned items are never evicted** ([pinning](design/pinning.md)). `sshdrive pins <name>`
  shows what is pinned.
- **An item with an upload pending is refused**, with the same error as a pinned item, so the
  error does not tell you which.
- **`evict --all` falls back to file by file** when it meets a pinned item, and for at least a
  minute after `--unpin-all` (a single file becomes evictable 5-10 seconds after an unpin).
  The fallback leaves the folders themselves downloaded. That is expected
  ([cache eviction](design/eviction.md)).
- **The TTL counts from the last download or save**, not the last read. Reading a file that
  is already downloaded does not keep it.

### An edit made offline has not been uploaded

macOS holds the write and offers it again on its own schedule, and SSH Drive sends it once
the connection is back. To see what macOS still has waiting:

```sh
sshdrive debug materialized <name> --pending
```

### A symlink shows as an alias, or `ln -s` was refused

Symlinks show as native items and are never followed ([symlinks](design/symlinks.md)).

- Finder draws every symlink as Kind "Alias" with the arrow badge, whether or not its target
  exists.
- A link whose target is outside the location's root is not shown at all.
- Creating such a link inside the mount is refused. There is no alert: Finder marks the item
  with a sync error, and `sshdrive logs` has the reason.

## Nothing above helped

Collect the logs and open an issue at <https://github.com/alecdwm/sshdrive/issues>:

```sh
sshdrive logs --last 1h > /tmp/sshdrive.log
sshdrive status --json >> /tmp/sshdrive.log
sshdrive doctor --json >> /tmp/sshdrive.log
```

Hostnames and paths are in the log on purpose. Secrets never are, but read it before posting.
