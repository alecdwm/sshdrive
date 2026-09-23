<h1 align="center">
  <img src="docs/assets/icon-256.png" alt="" width="112"><br>
  SSH Drive
</h1>

<p align="center">
  Your SSH servers in Finder's sidebar, next to iCloud Drive.<br>
  <a href="https://sshdrive.shirls.org/">Docs</a> ·
  <a href="https://sshdrive.shirls.org/install/">Install and use</a> ·
  <a href="https://sshdrive.shirls.org/troubleshooting/">Troubleshooting</a>
</p>

Folders list without downloading anything. A file downloads when you open it, and the cache
clears itself later. There is no window: you set a location up with `sshdrive` in a terminal, then
use Finder.

It connects with your own `/usr/bin/ssh`, so if `ssh nas` works in a terminal, so does this:
`~/.ssh/config` aliases, `ProxyJump` chains, `ssh-agent`, 1Password, Secretive, FIDO keys. A key
that needs a touch, a PIN or a one-time code on every connection is the exception, because the
mount reconnects with nobody there to answer.

## Requirements

- macOS 14 or newer.
- A server you can reach over SSH, with the SFTP subsystem enabled (OpenSSH enables it by default).

## Install

```sh
brew tap alecdwm/tap
brew install --cask sshdrive
sshdrive add nas alec@nas.local
```

`nas` becomes the name in Finder's sidebar; the rest is anything `ssh` understands, including a
`Host` alias. `add` connects once while you watch, so a host-key question, password or passphrase
is asked at your terminal and stored in your keychain. If the connection fails, nothing is saved.

macOS then shows two prompts, once each. Answer **Allow** to the Local Network one.
[Install and use](https://sshdrive.shirls.org/install/) explains both, plus installing without
Homebrew and uninstalling (run `sshdrive remove --all` before `brew uninstall`).

## Everyday commands

```sh
sshdrive list                     # every location, its state and its TTL
sshdrive status nas               # errors, hidden names, change detection, what the server can do
sshdrive pin nas /Projects        # keep a folder downloaded
sshdrive evict nas --all          # drop the cache now
sshdrive set nas cache-ttl 12h    # 15m | 1h | 12h | 1d | 1w | 1mo | never
sshdrive doctor                   # check the install and say what to fix
```

Commands that change something print nothing on success; put `-v` after the subcommand for the
full report. `sshdrive --help` lists the rest.

## More

- [Documentation](https://sshdrive.shirls.org/): install, everyday use, troubleshooting.
- [Design pages](https://sshdrive.shirls.org/design/goals/): how it works, for contributors.
  `scripts/mac-build.sh` builds and tests on a Mac over ssh; `docs/release.md` is the release
  procedure.
- Source and issues: <https://github.com/alecdwm/sshdrive>
