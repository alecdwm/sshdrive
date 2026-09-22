<img src="docs/assets/icon-256.png" alt="SSH Drive" width="128">

# SSH Drive

Your SFTP servers show up in Finder, in the sidebar, next to iCloud Drive. Folders list
without downloading anything. A file downloads when you open it, and the cache clears
itself again later. It connects with your own `/usr/bin/ssh`, so if `ssh nas` works in a
terminal then so does this: `~/.ssh/config` aliases, `ProxyJump` chains, `ssh-agent`,
1Password, Secretive, FIDO keys. There is no window: you set it up with `sshdrive` in a
terminal, then use Finder.

## Install

```sh
brew tap alecdwm/tap
brew install --cask sshdrive
sshdrive add nas alec@nas.local
```

`nas` is the nickname, and it becomes the name in Finder's sidebar. The rest is anything
`ssh` understands, including the name of a `Host` block in `~/.ssh/config`. `add` connects
once while you are watching, so whatever `ssh` wants to ask is asked at your terminal
rather than silently later. An unknown host key is the same question `ssh` asks. A
password or a key passphrase goes into your keychain and gets reused. If the connection
works, the location is saved and appears in Finder under Locations. If it does not,
nothing is saved. Commands that change something are quiet; put `-v` after the subcommand
for the full report.

## The first time

macOS shows you two things, once each. **Background Items Added** is a notification, not a
question: SSH Drive registered a login agent and it is already on. To turn it off, System
Settings, General, Login Items & Extensions.

**Allow "SSH Drive" to find devices on local networks?** turns up during your first
`sshdrive add` against a server on your own network, which is every NAS. Answer Allow. If
you say no, the mount cannot reach the server, and the fix is System Settings, Privacy &
Security, Local Network.

## Everyday commands

```sh
sshdrive list                     # every location, its state and its TTL
sshdrive status nas               # sync errors, hidden names, what the server can do
sshdrive show nas                 # ssh options, jump chain, mount path
sshdrive pin nas /Projects        # keep a folder downloaded
sshdrive unpin nas /Projects/tmp  # leave a subfolder out of a pin above it
sshdrive evict nas --all          # drop the cache now
sshdrive set nas cache-ttl 12h    # 15m | 1h | 12h | 1d | 1w | 1mo | never
sshdrive logs -f nas              # our log and the system's, live
sshdrive doctor                   # check the install and say what to fix
```

`sshdrive --help` lists the rest. Every command takes a location by nickname, by hostname,
or by the start of its id.

## How it behaves

A file is a placeholder until something opens it, and then it is fetched. Nothing comes
down in bulk. Cached content is dropped again after the TTL you set for that location,
which is anything from 15 minutes to a month, or never. A pinned folder is different:
`sshdrive pin nas /Projects` downloads the whole subtree and keeps it, including files
that appear on the server afterwards. It is the same thing as Finder's "Keep Downloaded".

Changes made on the server show up on their own. How fast depends on what the server can
run, and `sshdrive status` says which of the three methods it settled on; the quickest is
a small helper binary it uploads, which pushes changes in about a second. Sleep, wake and
a dropped network are handled, and edits you make while the server is unreachable are
queued and go up when it comes back.

No trash: deleting a file in the mount deletes it on the server, and Finder says so.

## Requirements

macOS 14 or newer. SFTP only, so it is not `sshfs` and not a general SSH client.

## When something is wrong

`sshdrive doctor` first: it checks the install and names what to fix. Then
[troubleshooting](https://alecdwm.github.io/sshdrive/troubleshooting/), which is organised
by what `doctor` says. Then `sshdrive logs`.

## Uninstalling

Run this first, while the app is still there:

```sh
sshdrive remove --all
```

That takes every location out of Finder and removes its keychain items. Homebrew can do
neither: by then the app that could has already been deleted, and no cask directive
reaches the keychain at all. Then this, where `zap` in place of `uninstall` also deletes
the locations, the indexes and the pins:

```sh
brew uninstall --cask sshdrive     # or: brew zap --cask sshdrive
```

## Building it

`scripts/mac-build.sh` builds and tests on a Mac over ssh, and `docs/release.md` is the
release procedure. The [design](https://alecdwm.github.io/sshdrive/design/goals/) pages
are how it works; [testing](https://alecdwm.github.io/sshdrive/design/testing/) is how it
is checked.

## Links

- Docs: <https://alecdwm.github.io/sshdrive/>
- Source and issues: <https://github.com/alecdwm/sshdrive>
