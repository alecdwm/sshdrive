# Install and use

Install with Homebrew, run `sshdrive add` once per server, and use Finder from then on. macOS asks
two questions the first time; answer **Allow** to the Local Network one.

## Requirements

- macOS 14 or newer.
- A server you can reach with `sftp`. SSH Drive runs your own `/usr/bin/ssh`, so your
  `~/.ssh/config`, `ProxyJump`, key agent or password work here as they do in a terminal.
- Authentication that completes with nobody at the keyboard. The mount reconnects on its own, so
  `add` refuses a key that asks for a touch, a PIN or a one-time code on every connection.

What works unattended:

| Method | Notes |
|---|---|
| A key held by a key agent | `ssh-agent`, 1Password, Secretive |
| A FIDO key made with `no-touch-required` | |
| A key passphrase | stored in your keychain |
| A password | stored in your keychain |

## Installing

```sh
brew tap alecdwm/tap
brew install --cask sshdrive
```

The cask:

- installs `SSH Drive.app` into `/Applications`
- symlinks the `sshdrive` command onto your `PATH`
- checks the app's notarization with `spctl --assess`, then clears the quarantine attribute
  Homebrew leaves on it
- launches the app once so it can register itself

There is nothing to open afterwards. The app is a background agent: launching it registers the
File Provider extension and a login item, then it exits. Clearing the quarantine attribute is what
lets that registration happen, because macOS registers no extension from a bundle that is still
marked as downloaded and has never been opened by a person.

### Without Homebrew

Each release on <https://github.com/alecdwm/sshdrive/releases> carries
`SSH-Drive-<version>.dmg`. Drag `SSH Drive.app` to `/Applications`, then do by hand what the cask
does:

```sh
spctl --assess --type execute --verbose=4 "/Applications/SSH Drive.app"   # accepted, Notarized Developer ID
xattr -dr com.apple.quarantine "/Applications/SSH Drive.app"
open -g -a "SSH Drive"
sudo ln -sf "/Applications/SSH Drive.app/Contents/MacOS/sshdrive" /usr/local/bin/sshdrive
```

The symlink can go in any directory on your `PATH`.

!!! warning "Replacing an installed copy"
    Run this before the `open -g`, or the login item keeps pointing at the deleted bundle:

        SSHDRIVE_AGENT_ROLE=unregister "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"

### Version

`sshdrive --version` prints one number. The agent, the extension, the CLI and the remote helper
are built from the same version and report the same string.

## The two macOS prompts

Both come from macOS, neither can be avoided, and neither repeats.

**Background Items Added** is a notification, not a question. SSH Drive registered its login agent
and it is already on. To turn it off: System Settings → General → Login Items & Extensions.

**Allow "SSH Drive" to find devices on local networks?** appears the first time it connects to a
server on your own network, which is every NAS. It arrives during `sshdrive add`, in the app's
name. Answer **Allow**.

!!! note "If you missed it or said no"
    The mount cannot reach servers on your LAN. Turn it back on in System Settings → Privacy &
    Security → Local Network.

## Your first location

```sh
sshdrive add nas alec@nas.local
```

`nas` is the nickname and becomes the name in Finder's sidebar. The rest is anything `ssh`
understands: `alec@nas.local`, `nas.local:2222`, or the name of a `Host` block in
`~/.ssh/config`.

`add` connects once, in the agent's own environment, so whatever `ssh` would ask later is asked
now, at your terminal:

- an unknown host key: the same question `ssh` asks, answered the same way
- a password or key passphrase: stored in your keychain and reused
- a warning if your terminal's `PATH` or `SSH_AUTH_SOCK` differs from your login shell's, since the
  agent uses the login shell's

If the connection works, the location is saved and appears in Finder under Locations. If it does
not, nothing is saved.

On success `add` prints one line, `Added <name> (<user>@<host>:<port>) at <mount path>`. With `-v`
after the subcommand (`sshdrive add -v nas alec@nas.local`) it also shows what `ssh -G` resolved
the destination to, which values came from `~/.ssh/config`, and the server's capability report.
`sshdrive status nas` shows that report at any time.

Useful flags:

| Flag | Effect |
|---|---|
| `--remote-path /srv/media` | mount somewhere other than the account's home |
| `--identity ~/.ssh/id_nas` | the key to offer |
| `--jump bastion` | reach the server through a jump host |
| `--cache-ttl 12h` | how long downloaded files are kept |
| `-o OPTION` | any other ssh option |

## How the mount behaves

- **Files are placeholders** until something opens them, then they are fetched. Nothing comes down
  in bulk.
- **Downloaded files are dropped after the location's TTL**: 15 minutes to a month, or never.
- **A pinned folder stays downloaded.** `sshdrive pin nas /Projects` fetches the whole subtree and
  keeps it, including files that appear on the server later. It is the same as Finder's "Keep
  Downloaded".
- **Server-side changes show up on their own.** There are three ways of noticing them, depending
  on what the server can run, and `sshdrive status` says which one a location uses. The fastest is
  a small helper binary uploaded to the server, which reports changes in about a second.
- **Sleep, wake and a dropped network are handled.** Edits made while the server is unreachable are
  queued and uploaded when it comes back.
- **There is no trash.** Deleting a file in the mount deletes it on the server, and Finder says so.

## Everyday commands

```sh
sshdrive list                     # every location, its state and its TTL
sshdrive status [nas]             # state, last error, change detection, cache, what the server can do
sshdrive show nas                 # the whole resolution: ssh options, chain, mount path
sshdrive pin nas /Projects        # keep a folder downloaded
sshdrive unpin nas /Projects/tmp  # leave a subfolder out of a pin above it
sshdrive pins nas                 # the tree of pins and exclusions
sshdrive evict nas --all          # drop the cache now
sshdrive set nas cache-ttl 12h    # 15m | 1h | 12h | 1d | 1w | 1mo | never
sshdrive set nas nickname media   # rename the Finder entry in place, cache and uploads kept
sshdrive set nas helper off       # on | off: the change-detection helper on the server
sshdrive logs -f nas              # our log and the system's, live
sshdrive doctor                   # check the install and say what to fix
```

Any command takes a location by nickname, hostname or the start of its id. `sshdrive --help`
lists the rest.

A command that changes something prints nothing on success, apart from prompts, warnings and
errors (`add` also prints its one line). Put `-v` after the subcommand for the full report. The
reporting commands, `list`, `show`, `status`, `pins`, `logs` and `doctor`, print either way.

## When something is wrong

1. `sshdrive doctor` checks the install and names what to fix.
2. [Troubleshooting](troubleshooting.md) is organised by what `doctor` says.
3. `sshdrive logs` shows what happened.

## Uninstalling

Run this first, while the app is still installed:

```sh
sshdrive remove --all
```

It removes every location's Finder entry, its index, its downloaded files and its keychain items.
Homebrew can remove neither the Finder entries nor the keychain items: by the time `brew zap` runs,
the app that could has been deleted, and no cask directive reaches the keychain.

- It asks first unless you pass `-y`.
- It refuses while a location has uploads pending, because removing the location discards them.
  Wait for them, or pass `--force` to discard them.

Then:

```sh
brew uninstall --cask sshdrive     # or: brew zap --cask sshdrive
```

`brew zap` also deletes the app group container, which holds the locations, the indexes and the
pins.

If you skip `sshdrive remove --all`, the sidebar keeps entries for a provider that no longer
exists, shown as unavailable until the next login, and the keychain keeps orphaned items that a
later install overwrites.
