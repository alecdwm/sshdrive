# The location model

A location is one entry in `config.json` and one File Provider domain. It stores only what the user
chose to override; everything else comes from `~/.ssh/config`, which the system `ssh` reads on every
connection.

## `config.json` entry

```jsonc
{
  "id": "6f1c…",                     // UUID, doubles as the File Provider domain identifier
  "nickname": "homelab",             // optional
  "host": "nas",                     // exactly what the user typed: an ssh_config alias or a hostname
  "user": "alec",                    // optional override, passed as -o User=
  "port": 22,                        // optional override, passed as -o Port=
  "identityFile": "~/.ssh/id_nas",   // optional override, passed as -o IdentityFile= -o IdentitiesOnly=yes
  "sshOptions": ["Ciphers=aes256-gcm@openssh.com"],
                                     // optional extra -o options, verbatim; a ProxyJump here is
                                     // consumed by the agent like one from the config (ssh.md)
  "remotePath": "/srv/media",        // optional; default is the SFTP realpath of "." (the user's home)
  "secrets": ["password:alec@nas.tail1234.ts.net:22"],
                                     // which keychain items exist:
                                     // password:<user>@<hostname>:<port>, passphrase:<keypath>;
                                     // user, hostname and port as resolved by ssh -G, never
                                     // the alias (secrets.md); an item is shared by every
                                     // location naming it and deleted with the last one (cli.md)
  "agentDependent": false,           // set by add when only the key agent could authenticate (secrets.md)
  "cacheTTL": "1h",                  // 15m | 1h | 12h | 1d | 1w | 1mo | never
  "permissions": "mode",             // mode | none: whether server mode bits become Finder capabilities
                                     // (names-and-attributes.md)
  "watchMode": "auto",               // auto | poll | sweep | helper (change-detection.md)
  "helper": true,                    // default on: deploy the remote helper where the server supports it
                                     // (change-detection.md, tier 2)
  "mounted": true                    // whether a File Provider domain currently exists for it
}
```

- The user is resolved the usual way (`~/.ssh/config`, then the local user). `add` accepts
  `user@host:port` and stores the parts as overrides.
- `remotePath` exists because without it every mount is the user's home directory, which is rarely
  what people want for a NAS.
- Several locations may name the same host, each with its own connection
  ([SSH process management](ssh.md)).
- No password and no key needs nothing from us: `ssh` offers `none` first, and a server that
  accepts it (Tailscale SSH does) lets us in.
- Pins are not in `config.json`; they live in the domain's index ([pinning](pinning.md)).
- There is no stored host key. `ssh` uses the user's `known_hosts`
  ([secrets and host keys](secrets.md)).

## Display name

Display name = `nickname ?? host`, **never prefixed**: the system prepends the app name itself, to
the mount directory and to the sidebar label (MQ-050, [platform facts](platform.md)).

`add(domain)` with an identifier the system already holds and a new `displayName` renames the
domain in place, mount directory included (MQ-051). The materialized set survives, nothing is
re-fetched, and a pending upload stays pending and still flushes. So `set nickname` is neither
refused nor cache-dropping ([the CLI](cli.md)).

## Reusing `~/.ssh/config`

The agent runs the system `ssh`, which reads `~/.ssh/config` on every connection. `Include`,
`Match`, wildcards, `ProxyJump`, `ProxyCommand`, `IdentityAgent`, `CertificateFile` and everything
else behave as they do for `ssh`, and config edits take effect on the next reconnect with no
snapshot to keep honest. Mux clients read no config at all.

Explicit flags on `add` become overrides stored in the location and passed as `-o` options, which
take precedence over the config file, as they do for `ssh`.

### What the agent always overrides

The fixed override set is listed in [SSH process management](ssh.md). Its groups and their reasons:

| Keywords | Why |
|---|---|
| Connection sharing and timeouts | The agent never shares a TCP connection with the user's terminal sessions |
| `UpdateHostKeys` | An `ask` in the config would raise a question on an unattended connection |
| `RemoteCommand`, `RequestTTY`, `StdinNull`, `ForkAfterAuthentication`, `BatchMode`, `PermitLocalCommand`, `ForwardAgent` | They would detach the master or break a `ProxyJump` hop |
| `IdentityAgent=none`, for a location that authenticated without a key agent at `add` | A 1Password or Secretive agent named in the config is never asked to sign for a mount with its own stored passphrase. A location that needed the agent at `add` keeps the config's value ([secrets](secrets.md), [SSH process management](ssh.md)) |

### The environment and the binary

- The environment `ssh` sees is launchd's, with `PATH` and `SSH_AUTH_SOCK` replaced by the login
  shell's ([SSH process management](ssh.md)).
- The binary is always `/usr/bin/ssh`. A config written for a newer Homebrew OpenSSH may use a
  keyword Apple's build rejects; `ssh -G` then fails with `Bad configuration option`, and `add`
  reports it with `/usr/bin/ssh -V`, so the mismatch shows at `add` rather than at the first
  reconnect.

### `ssh -G` and attribution

The agent runs `ssh -G <host>` at `add` and for `sshdrive show`, so the user sees what the location
resolves to ("user: alec, port: 2222, identity: ~/.ssh/id_nas (from ssh config)").

`ssh -G` prints resolved values with no hint of where each came from, and lists the default
identity files whether or not the config named one. So attribution comes from diffing
`ssh -G <host>` against `ssh -F /dev/null -G <host>`: a value that differs came from a config file.
`-F` silences `/etc/ssh/ssh_config` as well as the user's file, so the label reads "from ssh config"
and `show` names both paths rather than credit `~/.ssh/config` with a value Apple's system file set.

A `proxyjump` in the resolved output is never handed back to `ssh`: the agent builds the hop chain
itself ([SSH process management](ssh.md)).

## macOS as a server

A macOS server exposes `~/Documents`, `~/Desktop` and `~/Downloads` over SFTP only when "Allow full
disk access for remote users" is enabled in its Remote Login settings. Otherwise they list as empty
or refuse with `PERMISSION_DENIED`, which `add` cannot tell from an ordinary permission problem. The
user docs say so under "macOS as a server".
