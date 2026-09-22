# Install and use

## Requirements

- macOS 14 or newer.
- A server you can reach with `sftp`: SSH Drive runs your own `/usr/bin/ssh`, so whatever
  `ssh` does for that server (your `~/.ssh/config`, `ProxyJump`, a key agent, a password)
  is what it does here.
- Authentication that can complete with nobody at the keyboard. A key that asks for a
  touch, a PIN, or a one-time code on every connection is refused at `add`. A key held by
  a key agent, a FIDO key made with `no-touch-required`, a passphrase or a password all
  work, the last two stored in your keychain.

## Installing

```sh
brew tap alecdwm/tap
brew install --cask sshdrive
```

The cask installs `SSH Drive.app` into `/Applications`, symlinks the `sshdrive` command
out of the bundle onto your `PATH`, checks the app's notarization with `spctl --assess`
and clears the quarantine attribute Homebrew leaves on it, and launches the app once so
it can register itself.

There is no separate download to run and nothing to open. The app is a background agent:
launching it registers the File Provider extension and a login item, and it exits. The
quarantine step is what lets that registration happen. macOS registers no extension
belonging to a bundle that is still marked as downloaded and has never been opened by a
person, and the cask has already done the verification that marking exists for.

### Without Homebrew

Each release on <https://github.com/alecdwm/sshdrive/releases> carries
`SSH-Drive-<version>.dmg`. Open it and drag `SSH Drive.app` to `/Applications`, then do
by hand what the cask does:

```sh
spctl --assess --type execute --verbose=4 "/Applications/SSH Drive.app"   # accepted, Notarized Developer ID
xattr -dr com.apple.quarantine "/Applications/SSH Drive.app"
open -g -a "SSH Drive"
sudo ln -sf "/Applications/SSH Drive.app/Contents/MacOS/sshdrive" /usr/local/bin/sshdrive
```

The symlink can go in any directory on your `PATH`. When you replace an installed copy
with a newer one, run this before the `open -g`, or the login item keeps pointing at the
bundle that was deleted:

```sh
SSHDRIVE_AGENT_ROLE=unregister "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"
```

### Version

`sshdrive --version` prints one number. The agent, the extension, the CLI and the remote
helper are built from the same version and always report the same string.

### The prompts you will see

Two, both of them from macOS, neither avoidable, and neither repeated.

1. **Background Items Added.** A notification telling you SSH Drive registered its login
   agent. The item is *already enabled*; this is a notification, not a request. If you
   ever want to turn the whole thing off: System Settings → General → Login Items &
   Extensions.

2. **Allow "SSH Drive" to find devices on local networks?** The first time it connects to
   a server on your own network, which is every NAS. Answer **Allow**. There is no
   entitlement that suppresses this one and no window it can be shown over, so it arrives
   in the app's name while `sshdrive add` is running.

   If you miss it or say no, the mount cannot reach a server on your LAN. The fix is
   System Settings → Privacy & Security → Local Network.

## Your first location

```sh
sshdrive add nas alec@nas.local
```

`nas` is the nickname, and it becomes the name in Finder's sidebar. The rest is anything
`ssh` understands: `alec@nas.local`, `nas.local:2222`, or the name of a `Host` block in
`~/.ssh/config`.

`add` connects once, in the agent's own environment, so that whatever `ssh` asks for is
asked **now**, at your terminal, rather than silently later:

- an unknown host key, the same question `ssh` asks, answered the same way
- a password, or a key passphrase, stored in your keychain and reused
- a warning if your terminal's `PATH` or `SSH_AUTH_SOCK` differs from the login shell's,
  since the agent uses the login shell's

If the connection works, the location is saved and its domain appears in Finder under
Locations. If it does not, nothing is saved.

The command is quiet: prompts, warnings, and on success the one line
`Added <name> (<user>@<host>:<port>) at <mount path>`, which is the exception to the rule
that a command that changes something prints nothing. Add `-v` after the subcommand,
`sshdrive add -v nas alec@nas.local`, to see what
`ssh -G` resolved the destination to, which of those values came from `~/.ssh/config`,
and the capability report for the server. `sshdrive status nas` prints that report at any
time.

Useful flags: `--remote-path /srv/media` to mount somewhere other than the account's
home, `--identity ~/.ssh/id_nas`, `--jump bastion`, `--cache-ttl 12h`, and `-o` for any
other ssh option.

## Everyday commands

```sh
sshdrive list                     every location, its state and its TTL
sshdrive status [nas]             state, last error, change detection, cache, what the server can do
sshdrive show nas                 the whole resolution: ssh options, chain, mount path
sshdrive pin nas /Projects        keep a folder offline-complete
sshdrive unpin nas /Projects/tmp  exclude a subfolder from a pin above it
sshdrive evict nas --all          drop the cache now
sshdrive set nas cache-ttl 12h    15m | 1h | 12h | 1d | 1w | 1mo | never
sshdrive set nas nickname media   rename the Finder entry in place, cache and uploads kept
sshdrive set nas helper off       on | off: the change-detection helper on the server
sshdrive logs -f nas              our log and the system's, live
sshdrive doctor                   check the install and say what to fix
```

`sshdrive --help` lists all of them. Everything takes a location by nickname, hostname, or
the start of its id. A command that changes something prints nothing on success beyond
prompts, warnings and errors (`add` also prints its one line); `-v`, typed after the
subcommand, restores the full report. The commands whose job is to
report, `list`, `show`, `status`, `pins`, `logs` and `doctor`, print either way.

## When something is wrong

`sshdrive doctor` first, then [troubleshooting](troubleshooting.md), then
`sshdrive logs`.

## Uninstalling

**Run this first**, while the app is still installed:

```sh
sshdrive remove --all
```

That removes every location's Finder entry, its index, its downloaded files and its
keychain items. Homebrew can remove neither the Finder entries nor the keychain items: by the time `brew zap`
runs, the app that could has already been deleted, and no cask directive reaches the
keychain at all.

It asks first unless you pass `-y`. It refuses while any location has uploads pending,
because removing the domain throws them away: wait for them, or pass `--force` to discard
them.

Then:

```sh
brew uninstall --cask sshdrive     # or: brew zap --cask sshdrive
```

`brew zap` additionally deletes the app group container, which holds the locations, the
indexes and the pins.

If you skip `sshdrive remove --all`, you are left with sidebar entries for a provider
that no longer exists, shown as unavailable until the next login, and orphaned keychain
items that a later install simply overwrites.
