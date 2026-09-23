---
title: SSH Drive
---

# SSH Drive

<div class="hero">
  <img class="hero-icon" src="assets/icon-256.png" alt="" width="112" height="112">
  <div class="hero-text">
    <p class="hero-title" role="heading" aria-level="1">SSH Drive</p>
    <p class="hero-tagline">Your SSH servers in Finder's sidebar, next to iCloud Drive. Files
    download when you open them, and the cache clears itself.</p>
  </div>
</div>

SSH Drive mounts SSH servers through Apple's
[File Provider](https://developer.apple.com/documentation/fileprovider) framework, the one iCloud
Drive and Dropbox use. There is no window: you set a location up with the `sshdrive` command, then
use Finder.

```sh
brew tap alecdwm/tap
brew install --cask sshdrive
sshdrive add nas alec@nas.local
```

## Does it fit?

- **You can already `ssh` into the server.** SSH Drive runs your own `/usr/bin/ssh`, so
  `~/.ssh/config` aliases, `ProxyJump` chains, `Match exec` blocks, `ssh-agent`, 1Password,
  Secretive and FIDO keys all work as they do in a terminal.
- **Nobody needs to be at the keyboard on every connection.** The mount reconnects on its own, so
  `add` refuses a key that asks for a touch, a PIN or a one-time code each time. A key agent, a FIDO
  key made with `no-touch-required`, or a password works instead.
- **You run macOS 14 or newer**, and the server allows SFTP over SSH, which OpenSSH does by default.

## What it does

- **Placeholders until opened.** Folders list without downloading anything; a file is fetched
  when something opens it.
- **A cache that expires.** Downloaded files are dropped after a TTL you set per location, from
  15 minutes to a month, or never.
- **Pinned folders stay downloaded**, including files that appear on the server later. Pinning is
  the same as Finder's "Keep Downloaded".
- **Server changes show up on their own**, by one of three methods depending on what the server
  can run. `sshdrive status` says which. The fastest is a small helper binary that reports changes
  in about a second.
- **Sleep, wake and network loss are handled.** Edits made offline are queued and uploaded when
  the server comes back.
- **No trash.** Deleting in the mount deletes on the server, and Finder says so.

## Where to go next

Using it:

- [Install and use](install.md): installing, the two macOS prompts, your first location, everyday
  commands and uninstalling.
- [Troubleshooting](troubleshooting.md): organised by what `sshdrive doctor` says.

Working on it:

- [Design pages](design/goals.md): how it works and why, starting from goals and platform facts.
- [Measured behaviour](quirks/README.md): what macOS and real servers were measured to do.
- Source and issues: <https://github.com/alecdwm/sshdrive>
