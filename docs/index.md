---
title: SSH Drive
---

# SSH Drive

![SSH Drive](assets/icon-256.png){ width="112" }

SSH Drive mounts remote SFTP locations into Finder through Apple's
[File Provider](https://developer.apple.com/documentation/fileprovider) framework, the
same mechanism iCloud Drive and Dropbox use: a real entry in the sidebar, files that are
placeholders until you open them, and a cache that clears itself. There is no window.
Everything is `sshdrive`, a command-line tool, and Finder. The background agent runs your
own `/usr/bin/ssh`, so a server you can already `ssh` into is a server SSH Drive can
mount, with `~/.ssh/config` aliases, `ProxyJump` chains, `ssh-agent`, 1Password,
Secretive, FIDO keys and `Match exec` blocks all working, because none of it is
reimplemented. The exception is anything that needs a person on every connection: a key
that asks for a touch, a PIN, or a one-time code. The mount reconnects on its own, with
nobody there to answer, so `add` refuses such a location and says what works unattended
instead: a key held by a key agent, a FIDO key made with `no-touch-required`, or a
password.

```sh
brew tap alecdwm/tap
brew install --cask sshdrive
sshdrive add nas alec@nas.local
```

## What it does

- **Files are dataless placeholders** until something opens them, and are downloaded on
  demand. Nothing is copied down in bulk unless you ask.
- **Cached content is evicted on a TTL** you set per location, 15 minutes to a month, or
  never.
- **Pinned folders stay offline-complete.** `sshdrive pin nas /Projects` downloads the
  whole subtree and keeps it, including files that appear on the server later. It is the
  same thing as "Keep Downloaded" in Finder's context menu.
- **Changes on the server show up.** Three tiers, chosen per server: an SFTP poll, a
  `find` sweep over an ssh exec channel, or a small static helper binary that pushes
  changes in about a second. SSH Drive picks the best one the server can do and says
  which in `sshdrive status`.
- **Sleep, wake and network loss are handled.** Writes made offline are queued by the
  system and flushed when the server comes back; a lost connection is retried on a
  backoff.
- **No trash, no multi-user, no GUI.** Deleting inside the mount deletes on the server,
  and Finder says so.

## Requirements

macOS 14 or newer. SFTP only: this is not `sshfs`, and not a general SSH client.
Authentication that `ssh` can complete without a person at the keyboard: `add` refuses a
key that needs a touch, a PIN, or a one-time code on every connection.

## Next

- [Install and use](install.md) covers installing, the two macOS prompts, your first
  location and the everyday commands.
- [Troubleshooting](troubleshooting.md) is organised by what `sshdrive doctor` says.
- The [design pages](design/goals.md) are how it works, from the platform facts up.
- Source and issues: <https://github.com/alecdwm/sshdrive>
