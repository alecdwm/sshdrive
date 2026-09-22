# The location model

A location is one entry in `config.json` and one File Provider domain.

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

Display name = nickname ?? host, **never prefixed**: the system prepends the
app name itself, in the mount directory and in the sidebar label alike
(measured 2026-09-04; [platform facts](platform.md)). It is not fixed at
creation: `add(domain)` with an identifier the system already holds and a new
`displayName` renames the domain in place, mount directory included. The
materialized set survives, nothing is re-fetched, and an upload the system was
holding stays pending and still flushes, so `set nickname` is neither refused
nor cache-dropping ([the CLI](cli.md)).

Notes on the spec:

- The spec lists hostname/IP + port but SSH also needs a username. `ssh`
  resolves it the usual way (`~/.ssh/config`, then the local user); we
  accept `user@host:port` syntax and store the parts as overrides.
- `remotePath` is an addition: without it every mount is the user's home
  directory, which is rarely what people want for a NAS.
- Several locations may name the same host, each with its own connection
  ([SSH process management](ssh.md)).
- "No password" and "no key" together needs nothing from us: `ssh` offers
  `none` first, and if the server accepts (Tailscale SSH does) we're in.
- Pins are not in `config.json`. They live in the domain's index
  ([pinning](pinning.md)).
- There is no stored host key. `ssh` uses the user's `known_hosts`
  ([secrets and host keys](secrets.md)).
- A macOS server exposes `~/Documents`, `~/Desktop` and `~/Downloads` over
  SFTP only when "Allow full disk access for remote users" is enabled in
  its Remote Login settings; otherwise they list as empty or refuse with
  `PERMISSION_DENIED`, which `add` cannot tell from an ordinary
  permission problem. The user docs say so under "macOS as a server".

## Reusing `~/.ssh/config`

Nothing to do: the agent runs the system `ssh`, which reads
`~/.ssh/config` on every connection, so `Include`, `Match`, wildcards,
`ProxyJump`, `ProxyCommand`, `IdentityAgent`, `CertificateFile` and
everything else behave exactly as they do for `ssh`. Edits to the config
take effect on the next reconnect, with no snapshot to keep honest. The one
deliberate exception is the fixed set of keywords the agent always
overrides ([SSH process management](ssh.md)): connection sharing and
timeouts, so it never shares a TCP connection with the user's terminal
sessions; `UpdateHostKeys`, so an `ask` in the config cannot raise a
question on an unattended connection; and the session-shape keywords
(`RemoteCommand`, `RequestTTY`, `StdinNull`, `ForkAfterAuthentication`,
`BatchMode`, `PermitLocalCommand`, `ForwardAgent`) that would detach the
master or break a `ProxyJump` hop. One more keyword is overridden for most
locations: `IdentityAgent` is forced to `none` on every runtime
connection of a location that authenticated without a key agent at
`add`, so that a 1Password or Secretive agent named in the config is
never asked to sign for a mount that has its own stored passphrase
([secrets](secrets.md), [SSH process management](ssh.md)); a location that
needed the agent at `add` keeps the config's value. Mux clients read no
config at all.

The agent runs `ssh -G <host>` at `add` time and for `sshdrive show`, so
the user can see what the location resolves to ("user: alec, port: 2222,
identity: ~/.ssh/id_nas (from ssh config)"). `ssh -G` prints resolved
values only, with no indication of where each came from, and lists the
default identity files whether or not the config named one; the "from
~/.ssh/config" attribution comes from diffing `ssh -G <host>` against
`ssh -F /dev/null -G <host>`, since a value that differs between the two
came from a config file. `-F` silences `/etc/ssh/ssh_config` as well as
the user's file, so the label reads "from ssh config" and `show` names
both paths rather than crediting `~/.ssh/config` with a value Apple's
system file set. A `proxyjump` in the resolved output is not handed back
to `ssh`: the agent builds the hop chain itself
([SSH process management](ssh.md)). Explicit flags on `add` become
overrides stored in the location and passed as `-o` options, which take
precedence over the config file, as they do for `ssh`. The environment
`ssh` sees is launchd's, with `PATH` and `SSH_AUTH_SOCK` replaced by the
login shell's ([SSH process management](ssh.md)). The binary is always
`/usr/bin/ssh`, so a config written for a newer Homebrew OpenSSH may use a
keyword Apple's build rejects; `ssh -G` then fails with
`Bad configuration option`, and `add` reports it together with
`/usr/bin/ssh -V`, so the mismatch is found at `add` rather than at the
first reconnect.
