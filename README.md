# SSH Drive

Mount SFTP servers in Finder, on macOS, the way iCloud Drive is mounted: a real entry in
the sidebar, files that are placeholders until you open them, and a cache that clears
itself.

There is no window. Everything is `sshdrive`, a command-line tool, and Finder.

```
brew tap alecdwm/tap
brew install --cask ssh-drive
sshdrive add nas alec@nas.local
```

## What it is

A [File Provider](https://developer.apple.com/documentation/fileprovider) extension and a
background agent. The agent runs your own `/usr/bin/ssh`, so a server you can already
`ssh` into is a server SSH Drive can mount: `~/.ssh/config` aliases, `ProxyJump` chains,
`ssh-agent`, 1Password and Secretive, FIDO keys, `Match exec` blocks — all of it, because
none of it is reimplemented.

- **Files are dataless placeholders** until something opens them, and are downloaded on
  demand. Nothing is copied down in bulk unless you ask.
- **Cached content is evicted on a TTL** you set per location — 15 minutes to a month, or
  never.
- **Pinned folders stay offline-complete.** `sshdrive pin nas /Projects` downloads the
  whole subtree and keeps it, including files that appear on the server later. It is the
  same thing as "Keep Downloaded" in Finder's context menu.
- **Changes on the server show up.** Three tiers, chosen per server: an SFTP poll, a
  `find` sweep over an ssh exec channel, or a small static helper binary that pushes
  changes in about a second. It picks the best one the server can do and says which in
  `sshdrive status`.
- **Sleep, wake and network loss are handled.** Writes made offline are queued by the
  system and flushed when the server comes back; a lost connection is retried on a
  backoff.
- **No trash, no multi-user, no GUI.** Deleting inside the mount deletes on the server,
  and Finder says so.

Requires **macOS 14 or newer**. SFTP only — this is not `sshfs`, and not a general SSH
client.

## Installing

```sh
brew tap alecdwm/tap
brew install --cask ssh-drive
```

The cask installs `SSH Drive.app` into `/Applications`, symlinks the `sshdrive` command
out of the bundle onto your `PATH`, and launches the app once so it can register itself.

There is no separate download to run and nothing to open. The app is a background agent:
launching it registers the File Provider extension and a login item, and it exits.

### The prompts you will see

Three, all of them from macOS, none of them avoidable, and none of them repeated.

1. **"SSH Drive" was downloaded from the Internet. Are you sure you want to open it?**
   Gatekeeper, the first time the freshly downloaded bundle is opened. Click Open. It does
   not come back.

2. **Background Items Added.** A notification telling you SSH Drive registered its login
   agent. The item is *already enabled* — this is a notification, not a request. If you
   ever want to turn the whole thing off: System Settings → General → Login Items &
   Extensions.

3. **Allow "SSH Drive" to find devices on local networks?** The first time it connects to
   a server on your own network — which is every NAS. Answer **Allow**. There is no
   entitlement that suppresses this one and no window it can be shown over, so it arrives
   in the app's name while `sshdrive add` is running.

   If you miss it or say no, the mount cannot reach a server on your LAN. The fix is
   System Settings → Privacy & Security → Local Network.

## Your first location

```sh
sshdrive add nas alec@nas.local
```

`nas` is the nickname — it becomes the name in Finder's sidebar. The rest is anything
`ssh` understands: `alec@nas.local`, `nas.local:2222`, or the name of a `Host` block in
`~/.ssh/config`.

`add` shows you what `ssh -G` resolved the destination to, then connects once, in the
agent's own environment, so that whatever `ssh` asks for is asked **now**, at your
terminal, rather than silently later:

- an unknown host key — the same question `ssh` asks, answered the same way
- a password, or a key passphrase — stored in your keychain and reused
- a warning if your terminal's `PATH` or `SSH_AUTH_SOCK` differs from the login shell's,
  since the agent uses the login shell's

If the connection works, the location is saved and its domain appears in Finder under
Locations. If it does not, nothing is saved.

Useful flags: `--remote-path /srv/media` to mount somewhere other than the account's home,
`--identity ~/.ssh/id_nas`, `--jump bastion`, `--cache-ttl 12h`, `-o` for any other ssh
option.

## Everyday commands

```sh
sshdrive list                     every location, its state and its TTL
sshdrive status [nas]             sync errors, hidden names, what the server can do
sshdrive show nas                 the whole resolution: ssh options, chain, mount path
sshdrive pin nas /Projects        keep a folder offline-complete
sshdrive unpin nas /Projects/tmp  exclude a subfolder from a pin above it
sshdrive evict nas --all          drop the cache now
sshdrive set nas cache-ttl 12h    15m | 1h | 12h | 1d | 1w | 1mo | never
sshdrive logs -f nas              our log and the system's, live
sshdrive doctor                   check the install and say what to fix
```

`sshdrive --help` lists all of them. Everything takes a location by nickname, hostname, or
the start of its id.

## When something is wrong

`sshdrive doctor` first, then `docs/troubleshooting.md`, then `sshdrive logs`.

## Uninstalling

**Run this first**, while the app is still installed:

```sh
sshdrive remove --all
```

That removes every location's Finder entry and its keychain items. Homebrew cannot do
either: by the time `brew zap` runs, the app that could has already been deleted, and no
cask directive reaches the keychain at all.

Then:

```sh
brew uninstall --cask ssh-drive     # or: brew zap --cask ssh-drive
```

`brew zap` additionally deletes the app group container — locations, indexes and pins.

If you skip `sshdrive remove --all`, you are left with sidebar entries for a provider that
no longer exists, shown as unavailable until the next login, and orphaned keychain items
that a later install simply overwrites.

## Building it yourself

`DESIGN.md` is the whole design, and `CLAUDE.md` is the map to it. `scripts/mac-build.sh`
builds and tests on a Mac over ssh; `docs/release.md` is the release procedure;
`docs/spikes/` is what was measured, and on what.

## Links

- Source and issues: <https://github.com/alecdwm/sshdrive>
- Design: [`DESIGN.md`](DESIGN.md)
- Troubleshooting: [`docs/troubleshooting.md`](docs/troubleshooting.md)
