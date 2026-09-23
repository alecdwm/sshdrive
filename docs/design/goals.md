# Goals and non-goals

SSH Drive mounts remote SFTP locations into Finder through Apple's File Provider framework, the
mechanism iCloud Drive, Google Drive, OneDrive and Dropbox use on modern macOS. It has no GUI:
everything is driven by the `sshdrive` CLI, and authentication is whatever the user's `ssh` already
does.

## Goals

- **SFTP only.** Each location is its own Finder sidebar entry, named
  `SSH Drive - <nickname, else hostname>`.
- **Zero GUI.** Add, remove, configure and inspect through `sshdrive`.
- **Dataless until opened.** Files are placeholders; opening one downloads it on demand.
- **TTL eviction.** Cached content is evicted after a per-location TTL (15m to 1 month), measured
  from the last time the file was fetched or saved ([eviction](eviction.md)).
- **Survives reboots and network loss** with no user action. Offline, downloaded files stay
  readable and previously browsed folders stay listable. Writes queue and flush when the network
  returns.
- **Remote changes appear by themselves.** Near-instant where the account has shell access and can
  run our helper, polled otherwise. `sshdrive status` shows which level is active and what would
  improve it.
- **Pinning.** Any file or folder can be marked "keep offline", from the CLI or from a "Keep
  Downloaded" entry in Finder's context menu. Kept content is downloaded eagerly, never
  TTL-evicted, and new remote files inside a kept folder are pulled down automatically.

## The auth promise

If `ssh nas` works in a terminal, `sshdrive add nas` works. That covers passwords, keys with or
without passphrases, keys held by `ssh-agent`, 1Password or Secretive, FIDO keys, certificates,
`ProxyJump`, and no credential at all (Tailscale SSH and similar).

The agent always runs `/usr/bin/ssh`, with the `PATH` and `SSH_AUTH_SOCK` of the user's login shell
rather than launchd's, so key agents and `ProxyCommand` tools set up in a shell rc file work too
([SSH process management](ssh.md)).

The exceptions:

| Case | What happens |
|---|---|
| Something needs a human on every connection (a touch-required FIDO key, a one-time code) and `ssh` itself reports the prompt | `add` refuses it with an explanation rather than mount something that breaks on the first reconnect ([secrets](secrets.md)) |
| The prompt is raised inside a key agent (Secretive, 1Password, a FIDO key held by `ssh-agent`) | Invisible to `add`; caught by the authentication deadline instead ([secrets](secrets.md)) |
| The terminal `add` runs from has a different `PATH` or `SSH_AUTH_SOCK` than the agent will use | "Works in a terminal" means "works in a fresh login shell"; `add` says so when the two differ ([secrets](secrets.md)) |
| A shell rc file prints on non-interactive startup (rarer) | It corrupts an external `sftp-server` exactly as it corrupts `sftp(1)`; `add` diagnoses it and works around it where the account has shell access ([security](security.md)) |

## Non-goals (v1)

- Any protocol other than SFTP.
- A menu-bar item, preference pane, windows or notification UI. Finder context-menu entries
  provided through the File Provider action mechanism are allowed: they are menu items handled by
  the extension, not a UI of our own.
- Multi-user or system-wide installs. One user, one login session.
- A Trash. Deleting in Finder deletes on the server, after Finder's own "will be deleted
  immediately" confirmation ([names, permissions and attributes](names-and-attributes.md)).
- Recognising server-side renames as moves when only polling is available. They appear as delete
  plus create ([change detection](change-detection.md)); the helper reports real renames.
