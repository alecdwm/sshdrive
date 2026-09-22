# Goals and non-goals

SSH Drive mounts remote SFTP locations into Finder using Apple's File Provider
framework (the same mechanism iCloud Drive, Google Drive, OneDrive and Dropbox
use on modern macOS). It has no GUI; everything is driven by the `sshdrive` CLI.

**Goals**

- SFTP-only remote locations, each shown as its own Finder sidebar entry named
  `SSH Drive - <nickname, else hostname>`.
- Zero GUI. Add / remove / configure / inspect via `sshdrive`.
- Files are placeholders ("dataless") until opened; opening downloads on demand.
- Locally cached content is evicted after a per-location TTL (15m … 1 month)
  measured from the last time the file was fetched or saved
  ([eviction](eviction.md)).
- Mounts survive reboots and network loss without user intervention. Offline,
  already-downloaded files stay readable and previously browsed folders stay
  listable. Writes queue and flush when the network returns.
- Auth is whatever the user's `ssh` already does: passwords, keys with or
  without passphrases, keys held by `ssh-agent`, 1Password or Secretive,
  FIDO keys, certificates, `ProxyJump`, or no credential at all (Tailscale
  SSH and similar). If `ssh nas` works in a terminal, `sshdrive add nas`
  works, with one class of exception: anything that needs a human on every
  connection (a touch-required FIDO key, a one-time code) cannot run
  unattended. `add` refuses the ones `ssh` itself reports, with an
  explanation, rather than mounting something that breaks on the first
  reconnect; prompts raised inside a key agent (Secretive, 1Password, a
  FIDO key held by `ssh-agent`) are invisible to `add` and are caught by
  the authentication deadline instead ([secrets](secrets.md)). The agent
  always runs `/usr/bin/ssh`, with the `PATH` and `SSH_AUTH_SOCK` of the
  user's login shell rather than launchd's, so key agents and
  `ProxyCommand` tools set up in a shell rc file work too
  ([SSH process management](ssh.md)). "Works in a terminal" means "works in
  a fresh login shell"; `add` says so when the terminal it is run from
  carries a different `PATH` or `SSH_AUTH_SOCK` than the agent will use
  ([secrets](secrets.md)). One more exception is rarer than the
  human-on-every-connection one: a shell rc file that prints on
  non-interactive startup corrupts an external `sftp-server` exactly as it
  corrupts `sftp(1)`, and `add` diagnoses it and works around it where the
  account has shell access ([security](security.md)).
- Remote changes appear in Finder without the user doing anything. How fast
  depends on the server: near-instant where the SSH account has shell access
  and can run our helper, polled otherwise. `sshdrive status` always
  shows which level is active and what would improve it.
- Pinning: any folder or file can be marked "keep offline", from the CLI or
  from a "Keep Downloaded" entry in Finder's context menu. Kept content is
  downloaded eagerly, never TTL-evicted, and new remote files appearing
  inside a kept folder are pulled down automatically.

**Non-goals (v1)**

- Any protocol other than SFTP.
- A menu-bar item, preference pane, windows, or notification UI. Finder
  context-menu entries provided through the File Provider action mechanism are
  allowed: they are menu items handled by the extension, not a UI of our own.
- Multi-user / system-wide installs. One user, one login session.
- A Trash. Deleting in Finder deletes on the server, after Finder's own
  "will be deleted immediately" confirmation
  ([names, permissions and attributes](names-and-attributes.md)).
- Recognising renames made on the server as moves when only polling is
  available. They appear as delete + create
  ([change detection](change-detection.md)); the helper reports real renames.
