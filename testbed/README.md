# SSH Drive testbed

Twelve real SSH servers for the transport and change-detection work: Debian and Alpine
targets, every login-shell shape, an external `sftp-server`, keyboard-interactive,
`MaxSessions 2`, a busybox `find` without `-cmin`, a two-hop `ProxyJump` chain and a real
Tailscale SSH node. Run it with Docker Compose (OrbStack is fine) **on the Mac that hosts
the build VM**: the VM reaches every published service at `192.168.64.1:<port>` and nothing
else reaches them at all, which is what [Reachability](#reachability) below is about.

```sh
cd testbed
cp .env.example .env       # and put a Tailscale auth key in it: see below
docker compose up -d
docker compose ps          # wait for healthy
docker compose logs -f deb # sshd runs in the foreground with -D -e
```

**The `.env` step is not optional.** The twelfth service, `ts-ssh`, is a
Tailscale SSH node and its `TS_AUTHKEY` is declared with compose's required form
`${TS_AUTHKEY:?…}`, so with no key in `testbed/.env` *every* compose command in
this directory fails, not just that one service. See
[Tailscale SSH](#tailscale-ssh-ts-ssh).

Nothing is built. Every service runs `entrypoint.sh` over a stock `debian:12-slim`
or `alpine:3.20` image and installs its packages on first start, so the first
`up` needs internet and takes a couple of minutes (`deb-shells` pulls zsh, fish
and tcsh; `deb` seeds 15,000 files). Later starts are seconds.

Host keys are generated on first start into the `hostkeys` volume and reused
afterwards, so `known_hosts` on the VM stays stable across `up`/`down`/`restart`.
**`docker compose down -v` destroys them** - every host key then changes and the
VM's `known_hosts` entries for `[<ip>]:22xx` must be removed.

Files: `compose.yaml`, `entrypoint.sh` (shared by every service, driven entirely
by environment variables), `ts-entrypoint.sh` (the `ts-ssh` wrapper: seed, then
hand over to the Tailscale image's own `containerboot`), `.env.example`, this
README. Nothing else.

## Reachability

Every port is published on `${TESTBED_BIND:-192.168.64.1}`, and `192.168.64.1` is
the Mac's own address on the vmnet segment Apple's Virtualization framework hands
the VM - `bridge100` on the Mac, the default gateway inside the VM. macOS routes
it neither to the LAN nor to the tailnet, so these servers answer the build VM and
processes on the Mac, and nothing else. Nothing goes the other way: no container is
privileged, none is on the host network, none has the docker socket, and the only
host path any of them mounts is `entrypoint.sh`, read-only.

```sh
docker compose up -d                          # 192.168.64.1, the default
TESTBED_BIND=127.0.0.1 docker compose up -d   # Mac only; the VM is locked out
```

Never publish these without a bind address: docker's default is `0.0.0.0`, and
`deb`'s `nopw` account has an empty password on purpose.

Check it on the Mac, then from the VM:

```sh
sudo lsof -nP -iTCP -sTCP:LISTEN | grep ':22[01]'   # every line must say 192.168.64.1
nc -z 192.168.64.1 2201 && echo reachable           # on the VM
```

The bind fails with `cannot assign requested address` while `bridge100` is down,
which is what "no VM is running" looks like - boot the VM first. The gateway
address survives VM reboots; the VM's own lease (`192.168.64.11` today) is DHCP,
not a reservation.

**Other VMs on this Mac share that segment** and can reach the same ports. If that
matters, narrow it to the build VM with pf on the Mac - put these in
`/etc/pf.anchors/sshdrive-testbed`, reference the anchor from `/etc/pf.conf`, and
load it with `sudo pfctl -f /etc/pf.conf -e`:

```
pass in quick on bridge100 proto tcp from 192.168.64.11 to any port 2201:2210
block drop in quick on bridge100 proto tcp from any to any port 2201:2210
```

Order matters (`quick` takes the first match) and the source is that DHCP lease,
so re-check it if the VM's address moves. macOS also rewrites `/etc/pf.conf` on
system updates.

## First contact

**An open port is not a running server.** Docker's proxy completes the TCP handshake before
sshd is listening, so `nc -z` says "open" for a container that is still installing packages.
Readiness is the banner:

```sh
nc -G 3 -w 4 192.168.64.1 2201 </dev/null | head -1     # SSH-2.0-OpenSSH_9.2p1 ...
```

The VM's `known_hosts` needs one entry per service - `[192.168.64.1]:2201`-`2208` and
`:2210` - plus `bastion-b` and `inner`, which are reachable only through the chain.

### Five things that will waste an hour if you do not know them

1. **A published port can be dead while the container is healthy.** The shape is a port
   that accepts TCP and answers nothing while sshd inside is listening and has logged no
   `Connection from` line at all: that is OrbStack's forward, not the server.
   `docker compose up -d --force-recreate <service>` rebuilds it, and the volumes keep the
   tree and the host keys, so there is no re-seed and no `known_hosts` churn.
2. **`bashbg` hangs anything that reads to EOF.** Its rc leaves `( sleep 300 & )` holding
   stdout, so `ssh ... sh -s | cat` never returns - which is the whole point: only the
   closing sentinel ends the read (`docs/design/security.md`). Put a deadline on every
   exec-channel read, harnesses included. macOS has no `timeout`;
   `perl -e 'alarm(shift); exec @ARGV' 15 ssh ...` is the shortest substitute.
3. **`-J` does not pass your `-o` flags to the jump hops.** A first connection over the chain stops
   at `The authenticity of host 'bastion-b' ... can't be established` no matter what
   `StrictHostKeyChecking=accept-new` you put on the command line, because the `-W` child gets a
   fresh option set - and if an askpass is armed it will be asked that question thousands of times.
   Record the key by reaching the hop as a destination once:
   `ssh -o StrictHostKeyChecking=accept-new -J hop@192.168.64.1:2210 hop@bastion-b true`.
   With the `~/.ssh/config` below installed, the `spike-*` block covers the hops instead.
4. **Killing an `ssh` or `sftp` that used `-J` leaves the `-W` children running**, holding the pipe
   open behind it - the same orphan the agent must clean up after
   (`docs/design/ssh.md`). `pkill -f 'ssh .*-W'`.
5. **Every connection reaches a container from the docker bridge gateway**, `192.168.117.1` under
   OrbStack, never from the VM's own address. That is what `sshd -e` logs and what any `Match
   Address` would see, so nothing here can distinguish clients by IP.

For the password accounts without a tty, arm an askpass rather than typing:

```sh
cat >/tmp/spike-askpass.sh <<'EOF'
#!/bin/sh
case "$1" in
  *bastion-b*)  echo spike-password-b ;;
  *hop@*)       echo spike-password-a ;;
  *passphrase*) echo spike-passphrase ;;
  *)            echo spike-password ;;
esac
EOF
chmod +x /tmp/spike-askpass.sh
export SSH_ASKPASS=/tmp/spike-askpass.sh SSH_ASKPASS_REQUIRE=force
```

### busybox `find` has no `-cmin`

BusyBox v1.36.1, as shipped by Alpine 3.20, answers `find: unrecognized: -cmin` on `alp`,
`alp-ext` and `alp-nocmin` alike; its `find` offers `-mmin` and `-newer FILE` and nothing
else of use here. The `-mmin` fallback is therefore what every busybox server takes, and
the ctime-versus-mtime consequence comes with it: a rename or a chmod moves ctime but not
mtime, so `-mmin` misses changes `-cmin` would catch. `-newer <stamp>` is the one
mtime-precise alternative busybox does offer, and it needs a writable stamp file on the
server. Recorded as `SQ-001` and `SQ-005` in `docs/quirks/servers.md`.

## Services and ports

| Port | Service | Base | Shell / `find` | Notes |
|---|---|---|---|---|
| 2201 | `deb` | debian:12-slim | bash / GNU (`-cmin`, `-printf`) | main target, data tree, `ClientAliveInterval 15` |
| 2202 | `deb-shells` | debian:12-slim | zsh, fish, tcsh, dash, bash / GNU | login-shell shapes, `ForceCommand internal-sftp` |
| 2203 | `deb-extsftp` | debian:12-slim | bash / GNU | `Subsystem sftp /usr/lib/openssh/sftp-server` |
| 2204 | `deb-kbdint` | debian:12-slim | bash / GNU | keyboard-interactive password only (`UsePAM yes`) |
| 2205 | `deb-maxsess` | debian:12-slim | bash / GNU | `MaxSessions 2` |
| 2206 | `alp` | alpine:3.20 | busybox ash / busybox | `internal-sftp`, small data tree |
| 2207 | `alp-ext` | alpine:3.20 | busybox ash / busybox | `Subsystem sftp /usr/lib/ssh/sftp-server` |
| 2208 | `alp-nocmin` | alpine:3.20 | busybox ash / busybox + a `find` shim | meant to emulate pre-1.34 busybox (Synology DSM); **currently adds nothing** - stock busybox 1.36.1 already rejects `-cmin` and `-printf` (measured 2026-09-04) |
| 2210 | `bastion-a` | debian:12-slim | bash | hop 1, password auth, the only door onto `backnet` |
| — | `bastion-b` | debian:12-slim | bash | hop 2, password auth, no published port |
| — | `inner` | debian:12-slim | bash | destination behind both hops, no published port |
| — | `ts-ssh` | tailscale/tailscale | bash / GNU (`-cmin`, `-printf`) | **Tailscale SSH**, not sshd: `none` auth, Go `pkg/sftp` subsystem. No port at all - reached over the tailnet as `sshdrive-testbed`. Needs `TS_AUTHKEY` and an ACL rule ([below](#tailscale-ssh-ts-ssh)) |

`bastion-b` and `inner` sit on the `backnet` network with no port mapping, so the
VM can reach them **only** through `bastion-a`. Inside the compose network every
sshd listens on port 22 and is addressed by its service name (`bastion-b`,
`inner`).

**`ClientAliveInterval` is set only on `deb`** (15 s / 3). Everywhere else it is
unset, the OpenSSH default. The two settings exist side by side so that an abrupt
client kill can be tried against both, and against busybox.

Measured 2026-09-04: a bare `sleep &` started by a session whose client was then
`SIGKILL`ed was still running three minutes later on `deb-shells` (unset), on `deb`
(15/3) **and** on `alp` (busybox, unset). sshd reaping the session does not reach a
child that has left the foreground job, so `ClientAliveInterval` buys nothing here and
no server in this testbed will clean up after us. The heartbeat wrapper of
`docs/design/change-detection.md` is the whole mechanism, and `TestbedHeartbeatTests`
is where it is proven.

## Accounts

Every key account authorises **both** testbed keys
(`~/.ssh/sshdrive-spike` and `~/.ssh/sshdrive-spike-enc`, passphrase
`spike-passphrase`). Key-only accounts have `*` in the shadow field, so password
auth genuinely cannot succeed for them.

| Service | Account | Auth | Secret | Shell | Purpose |
|---|---|---|---|---|---|
| `deb` | `alec` | key | — | bash | main target; `data/` tree for sweep timing and throughput |
| `deb` | `pw` | password | `spike-password` | bash | password prompt → keychain item `password:pw@<host>:2201` |
| `deb` | `keypass` | key **or** password | `spike-password` | bash | server accepts both: the two-pass collect connection, the "key did not authenticate and the server accepts passwords" branch (`docs/design/secrets.md`) |
| `deb` | `nopw` | **none** (empty password, `PermitEmptyPasswords`) | — | bash | the closest Docker gets to Tailscale SSH's `none` method: sshd's `none` userauth succeeds outright |
| `deb-shells` | `bashnoisy` | key | — | bash | `.bashrc` prints on every non-interactive exec, so the sentinel must discard it (`docs/design/security.md`) |
| `deb-shells` | `bashbg` | key | — | bash | `.bashrc` prints **and** leaves `( sleep 300 & )` holding stdout → EOF never arrives, only the closing sentinel ends the read |
| `deb-shells` | `zshuser` | key | — | zsh | `.zshenv` prints (zsh reads it for every invocation) |
| `deb-shells` | `fishuser` | key | — | fish | `config.fish` prints (fish runs it for `fish -c`) |
| `deb-shells` | `tcshuser` | key | — | tcsh | `.cshrc` prints |
| `deb-shells` | `dashuser` | key | — | dash | no `read -t`: the sleep-and-mtime watchdog branch of the heartbeat wrapper |
| `deb-shells` | `forcesftp` | key **or** password | `spike-password` | bash + `ForceCommand internal-sftp` | the exec channel answers with SFTP framing; the probe must report "no shell access (ForceCommand)", not "shell output unusable" (`docs/design/security.md`) |
| `deb-extsftp` | `extnoisy` | key | — | bash (noisy `.bashrc`) | rc output lands in front of the SFTP `VERSION` reply → `sftp(1)` fails with "Received message too long"; our client must fall back to `sftp-server` on an exec channel |
| `deb-extsftp` | `extquiet` | key | — | bash (quiet) | external `sftp-server` with a clean stream: the control case |
| `deb-kbdint` | `kbd` | keyboard-interactive password | `spike-password` | bash | the `(kbd@host) Password:` prompt shape in the prompt classification table of `docs/design/secrets.md` |
| `deb-maxsess` | `alec` | key or password | `spike-password` | bash | `MaxSessions 2`: channel-limit probe, bulk SFTP channel dropped, sweep-stops-the-helper |
| `alp` | `alec` | key | — | busybox ash | busybox `find` (**no `-cmin`**, no `-printf`; `-mmin` and `-newer` only), small tree |
| `alp` | `pw` | password | `spike-password` | busybox ash | password auth against musl/busybox |
| `alp-ext` | `alec` | key | — | busybox ash | external `sftp-server` on Alpine |
| `alp-nocmin` | `alec` | key | — | busybox ash | `find` rejects `-cmin`/`-printf` → probe must select `-mmin` and `status` must carry the note. The shim is redundant today; stock busybox behaves the same |
| `bastion-a` | `hop` | password | `spike-password-a` | bash | hop 1 of the ProxyJump chain |
| `bastion-b` | `hop` | password | `spike-password-b` | bash | hop 2 — a **different** password, so per-host keychain keying (`password:<user>@<hostname>:<port>`) is visibly doing its job |
| `inner` | `alec` | key or password | `spike-password` | bash | the destination; small `data/` tree for an end-to-end sweep over the chain |
| `ts-ssh` | `alec` | **none** (tailnet ACL) | — | bash | Tailscale SSH: no `authorized_keys`, no PAM, no password check. The ACL decides admission and this account only has to *exist*. Its password is set (`spike-password`) so the account is not locked and `su - alec` works from a root shell; nothing on the wire ever uses it |

## The data tree

`deb:~alec/data/` (persisted in the `home-deb` volume, seeded once):

- `tree/d0000…d0249/f000…f019.bin` — 5,000 files, 2 KiB each, for sweep timing
- `many/m000000…m009999.bin` — 10,000 flat files for the small-file throughput run
- `weird/` — one directory each named `space in name`, `quote'name`,
  `$(echo pwned)`, `[bracket]`, `back\slash`, `*star*`, a name containing a
  **newline**, `utf8-café`, a **non-UTF-8** name (`latin1-caf\xff`), and
  `.hidden`; each holds `inside.txt`. These exercise the `set --` quoting rule of
  `docs/design/security.md`, the `-path ... -prune` glob escaping, NUL-delimited
  parsing, and the name handling of `docs/design/names-and-attributes.md`.
- `big/1g.bin` — **not created by default**. Set `BIG_FILE: "1"` on the `deb`
  service and `docker compose up -d --force-recreate deb` for the 1 GB
  throughput comparison against `sftp(1)` and `rsync`.

Scaling to a million files in 200 roots: set `SEED_TREE_DIRS: "2000"`,
`SEED_TREE_FILES: "500"`, `SEED_BYTES: "0"` on `deb`, then `docker compose down -v
deb`-style recreation (or delete `~alec/.testbed-seeded` inside the container and
restart it). Seeding a million files takes a few minutes and roughly 4 GB of inodes.

**With no `docker compose` to hand, seed it beside the existing tree instead**, over
ssh: a nine-line perl script writing `~alec/bigtree` makes 2,000 directories of 500
empty files - 1,000,000 files - in 11 seconds and leaves 13 GB free on `/home`, with
`data/` untouched for everything else. Delete it afterwards: `rm -rf ~/bigtree
~/seedbig.*`. Timings taken against a container on the same Mac are a floor, not a
NAS: the page cache cannot be dropped from inside.

`alp` and `alp-nocmin` get the same layout at 2,000 / 500 files. `inner` gets 200.

**Seeding uses perl where it exists and a shell loop where it does not**, and the stock
Alpine image has no perl. Both branches produce the same tree: padded names
(`tree/d0000`, `f000.bin`), `SEED_BYTES`-sized files, and all ten `weird/` names
including `utf8-café`.

A tree that is already seeded is never re-seeded, so an Alpine volume seeded by an
older `entrypoint.sh` keeps whatever shape it was given. Ask for a new one by deleting
the marker:

```sh
docker compose exec alp rm -f /home/alec/.testbed-seeded   # also alp-nocmin
docker compose restart alp alp-nocmin
```

`alp-ext` seeds nothing, so it needs no re-seed.

## Tailscale SSH (`ts-ssh`)

The twelfth service is not an sshd at all. `tailscaled` serves SSH itself, so a
client sees `remote software version Tailscale`, authenticates with the **`none`**
method, and gets an SFTP subsystem written in Go with `pkg/sftp` - which
advertises `hardlink@openssh.com`, `posix-rename@openssh.com` and
`statvfs@openssh.com` and nothing else. That is the shape of a real Tailscale SSH
server, which is why this service exists.

**`tailscaled` puts every session of every client in one shared process group, its
own** - `cat /proc/$$/stat` on this node gives the pgid, and it is `tailscaled`'s pid
- so `kill -TERM 0` from any one session signals all of them and the connections
under them. The heartbeat wrapper names `-$$`, the group it leads, which is the same group
under sshd and a harmless `ESRCH` here (`SQ-010` in `docs/quirks/servers.md`). A
session killed by an ambient group kill leaves a zombie behind, because
`containerboot` is PID 1 and does not reap; `ps` shows them as bracketed names, they
are inert, and `docker compose restart ts-ssh` clears them.

It is reached **over the tailnet, not over `192.168.64.1`**. There is no
published port and in userspace mode there cannot be one; the build VM
(`100.114.204.5`) is on the same tailnet and that is the whole route.

### Setting it up, in order

**1. Tailnet policy file** (Admin console -> Access controls). Two additions -
`tag:testbed` needs an owner before any key may apply it, and Tailscale SSH is
decided *here and nowhere else*:

```jsonc
	// A tag needs an owner before an auth key can apply it.
	"tagOwners": {
		"tag:testbed": ["autogroup:admin"],
	},

	// Tailscale SSH admission.  There is no authorized_keys, no password and no
	// sshd_config on the node; this rule is the entire auth decision.
	"ssh": [
		{
			"action": "accept",
			"src":    ["autogroup:member"],
			"dst":    ["tag:testbed"],
			"users":  ["alec", "root"],
		},
	],
```

`"action": "accept"` and not `"check"`: `check` demands a browser re-auth every
12 h, which a headless VM cannot do. The ordinary `acls` section must also allow
your devices to reach `tag:testbed` on TCP 22 - the default allow-all rule does.

**2. Auth key** (Admin console -> Settings -> Keys -> Generate auth key):
**reusable**, **pre-approved** (only matters if device approval is on),
tagged **`tag:testbed`**, ephemeral optional (an ephemeral node removes itself
from the console shortly after the container stops). A tagged key **applies the
tag by itself**, which is why `TS_EXTRA_ARGS` carries no `--advertise-tags` by
default; set `TS_TAGS=--advertise-tags=tag:testbed` in `.env` to be explicit
about it. Keys expire after 90 days at most; a rotated key goes in `.env` and
`docker compose up -d ts-ssh` picks it up.

**3. `testbed/.env`** - `cp .env.example .env`, paste the key into `TS_AUTHKEY`.
The file is gitignored; `.env.example` is not.

**4. Bring it up**, on the Mac as usual:

```sh
docker compose up -d ts-ssh
docker compose logs -f ts-ssh   # containerboot + tailscaled: a bad key or a
                                # refused tag says so here, in words
```

**5. Find the node**, once it is up:

```sh
docker compose exec ts-ssh tailscale ip -4     # 100.x.y.z
docker compose exec ts-ssh tailscale status    # state, and who it can see
```

or just use the MagicDNS name **`sshdrive-testbed`** from anything on the
tailnet, the VM included.

**6. Smoke test from the VM.** The point of the first one is the two debug
lines; there is no key and no password anywhere in it:

```sh
ssh -v alec@sshdrive-testbed true 2>&1 | grep -E 'remote software version|Authenticated to'
#   debug1: Remote protocol version 2.0, remote software version Tailscale
#   debug1: Authenticated to sshdrive-testbed ([100.x.y.z]:22) using "none".

ssh alec@sshdrive-testbed 'id; uname -sm; find data/tree -maxdepth 1 -cmin -60 -printf "%p\0" | tr "\0" "\n" | wc -l'
echo "ls data" | sftp -b - alec@sshdrive-testbed
sftp -v alec@sshdrive-testbed </dev/null 2>&1 | grep -i 'server supports extension'
#   hardlink@openssh.com, posix-rename@openssh.com, statvfs@openssh.com - and
#   nothing else, which is how a real Tailscale SSH node answers too

# a long exec channel that says `ready` and then only reads.  It is the control case:
# a session on its own survives here, and only a second wrapper-run command ending
# beside it can take it down.  Time it anyway.
start=$(date +%s); ssh alec@sshdrive-testbed 'echo ready; exec sleep 600' </dev/null; \
  echo "exit=$? after $(( $(date +%s) - start ))s"
```

**7. Tear down.** `docker compose exec ts-ssh tailscale logout` **before**
`docker compose down`, or delete the machine in the admin console afterwards -
see trap 3.

### What is inside the container

The image is `tailscale/tailscale:v1.86.2` (Alpine-based; its own entrypoint is
`/usr/local/bin/containerboot`, which reads the `TS_*` environment, starts
`tailscaled` and runs `tailscale up`). `ts-entrypoint.sh` replaces that
entrypoint, runs the shared `entrypoint.sh` in a new **`NO_SSHD=1`** mode -
packages, accounts, rc files, data tree; no openssh packages, no host keys, no
`sshd_config`, no `sshd` - and then **execs `containerboot`**, so containerboot
is still PID 1 and still gets the signals. To bump the pin, look at
`docker run --rm --entrypoint tailscale tailscale/tailscale:stable version`.

`PKGS: bash zsh coreutils findutils` buys the two things the sweep and the login-shell
snapshot care about: **GNU `find`** (so `-cmin` and `-printf` work, as on `deb`) and a
**bash** login shell for `alec`, plus GNU `stat`/`date`/`ls`.
**What stays busybox:** `/bin/sh` (ash - and so `sh -s` scripts run under ash),
`awk`, `sed`, `grep`, `tar`, `ps`, `wget`, `adduser`. And the base is
Alpine/musl, not Debian: no PAM, no `sudo`, no systemd, and **no perl**, so the
data tree comes from `entrypoint.sh`'s shell fallback exactly as `alp`'s does.
It is a Debian-*shaped* userland for the sweep, not a Debian. (That seeding
step assumes the image stays Alpine-based, because it installs with `apk`. If a
future tag stops being one, the container fails on the first start and says so
in `docker compose logs ts-ssh`.)

`~alec/data/` gets the `alp`-sized tree: `tree/d0000…d0099/f000…f019.bin`
(2,000 files), the ten `weird/` names, no `many/`. It lives in the `home-ts`
volume and is seeded once, like every other service's.

### Five Tailscale-specific things that will waste an hour

1. **`TS_AUTHKEY` is required for the whole file, not just this service.**
   `${TS_AUTHKEY:?…}` is evaluated for every `docker compose` invocation in this
   directory, so with no `.env` even `docker compose logs deb` fails. That is
   deliberate - a silently keyless `up` would leave a dead service behind - but
   it is the first thing that will bite a fresh checkout.
2. **Userspace mode has no inbound ports except Tailscale SSH.** `TS_USERSPACE=true`
   means no `/dev/net/tun`, no `NET_ADMIN`, and nothing in the container can be
   reached from the tailnet except the SSH server `tailscaled` runs itself. There
   is nothing to publish and no `ports:` entry to add; the other eleven services
   are untouched by this and are still on `192.168.64.1`.
3. **The node is a machine in the admin console and outlives the container.**
   `docker compose down` leaves it listed (offline); `down -v` also destroys the
   `ts-state` volume, so the identity can never be reclaimed and the entry has to
   be deleted by hand. Log out first - `docker compose exec ts-ssh tailscale
   logout` - or use an ephemeral auth key, which cleans up by itself.
4. **A fresh state volume is a new machine.** Recreate the container with
   `ts-state` gone and the tailnet gets a *second* node: MagicDNS names it
   `sshdrive-testbed-1` while the dead one keeps `sshdrive-testbed`, and the SSH
   host key is new, so the VM's `known_hosts` needs
   `ssh-keygen -R sshdrive-testbed`. Keep the volume and none of that happens.
5. **The ACL and the local user are two separate halves.** `users: ["alec","root"]`
   only says which names are *permitted*; Tailscale SSH creates nobody, and a
   name with no `getpwnam` entry fails after authentication has already
   succeeded. `alec` exists because `ts-entrypoint.sh` seeds it. The other half
   of the same trap is `src`: **a tagged node is not `autogroup:member`**, so if
   the build VM is itself tagged, `src` must name its tag instead.

One more that is not a trap but is worth knowing: `TS_ACCEPT_DNS=false` only
stops the *container* from taking tailnet DNS. MagicDNS still resolves
`sshdrive-testbed` on the VM.

## `~/.ssh/config` for the Mac VM

`192.168.64.1` is the Mac's vmnet address; change it only if you changed
`TESTBED_BIND`. Install this on the build VM along with `~/.ssh/spike key's copy`, and
give `known_hosts` every port plus `bastion-b` and `inner`, after which every alias
below connects without a prompt. It is shaped to be awkward on purpose: an unencrypted
key by default, `ControlMaster auto` **set for the bastion** so that "our hop must not
attach to the user's socket" (`docs/design/ssh.md`) can be falsified, and a separate
alias for the session-shape overrides.

```sshconfig
Host spike-deb
    HostName 192.168.64.1
    Port 2201

# Same server, with the host-block shapes docs/design/ssh.md says must be overridden.
# `ssh spike-deb-shapes` works; the agent must still get a foreground -N master.
Host spike-deb-shapes
    HostName 192.168.64.1
    Port 2201
    RemoteCommand echo this must never run under sshdrive
    RequestTTY force
    ForkAfterAuthentication yes
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h-%p

Host spike-shells
    HostName 192.168.64.1
    Port 2202
    User bashnoisy

Host spike-extsftp
    HostName 192.168.64.1
    Port 2203
    User extnoisy

Host spike-kbdint
    HostName 192.168.64.1
    Port 2204
    User kbd
    PreferredAuthentications keyboard-interactive

Host spike-maxsess
    HostName 192.168.64.1
    Port 2205

Host spike-alp
    HostName 192.168.64.1
    Port 2206

Host spike-alp-ext
    HostName 192.168.64.1
    Port 2207

Host spike-alp-nocmin
    HostName 192.168.64.1
    Port 2208

# --- the two-hop chain -------------------------------------------------------
# Hop 1 deliberately carries ControlMaster/ControlPath: the agent's rebuilt hop
# must run with ControlMaster=no AND ControlPath=none and touch neither socket.
Host spike-bastion-a
    HostName 192.168.64.1
    Port 2210
    User hop
    PubkeyAuthentication no
    PreferredAuthentications password
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h-%p

# Hop 2 is only resolvable and reachable from hop 1 (docker DNS name).
Host spike-bastion-b
    HostName bastion-b
    Port 22
    User hop
    PubkeyAuthentication no
    PreferredAuthentications password

Host spike-inner
    HostName inner
    Port 22
    User alec
    ProxyJump spike-bastion-a,spike-bastion-b

# The identity-path-with-a-space-and-a-quote case. The key file is
# ~/.ssh/spike key's copy, a copy of sshdrive-spike; ssh_config takes it in double
# quotes, and the agent must pass it to `ssh -i` without a shell in the way.
Host spike-deb-spacekey
    HostName 192.168.64.1
    Port 2201
    User alec
    IdentityFile "~/.ssh/spike key's copy"
    IdentitiesOnly yes

# --- Tailscale SSH -----------------------------------------------------------
# Over the tailnet, not 192.168.64.1: no port, no key, no password.  The tailnet
# ACL is the whole auth decision and ssh(1) gets in with the `none` method.  Use
# the 100.x.y.z address from `tailscale ip -4` if MagicDNS is off.
Host spike-ts
    HostName sshdrive-testbed
    User alec
    PubkeyAuthentication no

# Defaults for every alias above.  ssh takes the FIRST value it obtains for a
# keyword, so this catch-all block must come LAST or it would override the
# per-host User lines above it.
Host spike-*
    User alec
    IdentityFile ~/.ssh/sshdrive-spike
    IdentitiesOnly yes
    StrictHostKeyChecking ask
    UserKnownHostsFile ~/.ssh/known_hosts
```

Notes:

- `ssh -G spike-inner` prints `proxyjump spike-bastion-a,spike-bastion-b`; that
  is the input to the agent's own `ProxyCommand` chain builder
  (`docs/design/ssh.md`). Nothing in this file may be handed to `ssh` as
  `-o ProxyJump=...`.
- The "identity path with a space and a quote" case is the `spike-deb-spacekey`
  block above; its key file, `~/.ssh/spike key's copy`, is a copy of
  `sshdrive-spike`. Note that the `spike-*` catch-all
  still appends `sshdrive-spike` as a second identity, so `ssh -G` shows two -
  which is itself the realistic case.
- For the encrypted-key/askpass path use
  `IdentityFile ~/.ssh/sshdrive-spike-enc` with `IdentitiesOnly yes`
  (passphrase `spike-passphrase`).
- Host keys are `[192.168.64.1]:22xx` entries in `known_hosts`; every
  service has its own ed25519 and RSA key.

## Smoke tests

One `ssh` and one `sftp` per service, without needing the config file above.
Set `IP=192.168.64.1` and `K="-i ~/.ssh/sshdrive-spike -o IdentitiesOnly=yes"`.
Password accounts prompt; the passwords are in the account table, or arm the
askpass from [First contact](#first-contact) - which is also where the reasons live
for the two of these that will otherwise hang on you (`bashbg` in test 2, and the
chain in test 9 before `bastion-b`'s key is known).

```sh
IP=192.168.64.1; K="-i $HOME/.ssh/sshdrive-spike -o IdentitiesOnly=yes"

# 1. deb - GNU find, data tree, and the sweep's exact two invocations
ssh $K -p 2201 alec@$IP 'uname -sm; find data/tree -maxdepth 1 \( -type d -o -type f \) -cmin -60 -printf "%p\0%y\0%s\0%T@\0%i\0%m\0%U\0%G\0" | wc -c'
echo "ls data" | sftp -b - $K -P 2201 alec@$IP
ssh -p 2201 pw@$IP true                                  # password: spike-password
ssh -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=0 -p 2201 nopw@$IP id  # succeeds via the `none` method

# 2. deb-shells - every login shell, sentinel test (rc noise before our output)
for u in bashnoisy bashbg zshuser fishuser tcshuser dashuser; do
  printf 'printf "SENTINEL\\n"; id -un; echo done\n' | ssh $K -p 2202 $u@$IP sh -s; done
echo "ls" | sftp -b - $K -P 2202 forcesftp@$IP           # works; `ssh … sh -s` must not
ssh $K -p 2202 forcesftp@$IP sh -s </dev/null | head -c 32 | xxd | head -2   # SSH_FXP_VERSION framing

# 3. deb-extsftp - external sftp-server behind rc noise
ssh $K -p 2203 extnoisy@$IP 'echo shell-ok'
echo "ls" | sftp -b - $K -P 2203 extnoisy@$IP            # EXPECTED to fail: "Received message too long"
echo "ls" | sftp -b - $K -P 2203 extquiet@$IP            # succeeds

# 4. deb-kbdint - the "(kbd@host) Password:" prompt
ssh -o PreferredAuthentications=keyboard-interactive -p 2204 kbd@$IP 'echo kbdint-ok'
echo "ls" | sftp -o PreferredAuthentications=keyboard-interactive -P 2204 kbd@$IP

# 5. deb-maxsess - third concurrent channel must be refused
ssh $K -p 2205 -M -S /tmp/cm-maxsess -o ControlPersist=no -N alec@$IP &
ssh -S /tmp/cm-maxsess -o BatchMode=yes -F /dev/null -o ProxyCommand=/usr/bin/false $IP sleep 60 &
ssh -S /tmp/cm-maxsess -o BatchMode=yes -F /dev/null -o ProxyCommand=/usr/bin/false $IP sleep 60 &
ssh -S /tmp/cm-maxsess -o BatchMode=yes -F /dev/null -o ProxyCommand=/usr/bin/false $IP true   # expect: session request failed
echo "ls" | sftp -b - $K -P 2205 alec@$IP

# 6. alp - busybox find
# NB: -cmin is rejected here too; busybox 1.36.1 has only -mmin and -newer.
ssh $K -p 2206 alec@$IP 'busybox | head -1; find data/tree -maxdepth 1 -mmin -60 -print0 | tr "\0" "\n" | wc -l'
echo "ls data" | sftp -b - $K -P 2206 alec@$IP

# 7. alp-ext - external sftp-server, quiet shell
ssh $K -p 2207 alec@$IP 'echo shell-ok'
echo "ls" | sftp -b - $K -P 2207 alec@$IP

# 8. alp-nocmin - -cmin must be rejected, -mmin must work
ssh $K -p 2208 alec@$IP 'find data -cmin -60 -print0; echo "rc=$?"; find data -mmin -60 -print0 | tr "\0" "\n" | wc -l'
echo "ls data" | sftp -b - $K -P 2208 alec@$IP

# 9-11. the chain (passwords: spike-password-a, then spike-password-b)
ssh -p 2210 hop@$IP 'echo hop1-ok'
echo "ls" | sftp -P 2210 hop@$IP
ssh -J hop@$IP:2210,hop@bastion-b $K alec@inner 'echo inner-ok; ls data'
echo "ls data" | sftp -b - -J hop@$IP:2210,hop@bastion-b $K alec@inner

# 12. ts-ssh - over the tailnet, no key and no password; see "Tailscale SSH"
ssh -v alec@sshdrive-testbed true 2>&1 | grep -E 'remote software version|Authenticated to'
ssh alec@sshdrive-testbed 'uname -sm; find data/tree -maxdepth 1 -cmin -60 -printf "%p\0" | tr "\0" "\n" | wc -l'
echo "ls data" | sftp -b - alec@sshdrive-testbed
```

Handy while iterating: `docker compose logs -f <service>` shows `sshd -e` at
`LogLevel VERBOSE` (which key was offered, which method succeeded);
`docker compose exec <service> sh` gets a root shell inside a target;
`docker compose restart <service>` keeps everything, `down -v` resets host keys
and data.

## What this testbed cannot provide

- **BSD `find` and FreeBSD.** Docker shares the Linux kernel, so there is no
  FreeBSD, macOS or true BSD `find` here. A `-cmin`/`-printf` check against **BSD**
  find, a kqueue measurement of the tier-2 helper on a 100,000-file tree, and the
  `darwin/arm64` helper target all need a real FreeBSD/TrueNAS box or VM and a real
  Mac. `alp-nocmin` covers the *old-busybox* half of that matrix; nothing here
  covers the BSD half.
- **A real Synology DSM box.** `alp-nocmin` emulates its `find` (no `-cmin`, no
  `-printf`) with a shim, not its kernel, its `sh`, or its `max_user_watches`. And as
  of busybox 1.36.1 the shim is indistinguishable from stock busybox, so it is not
  currently a separate case at all - to make it one, have it reject something stock
  busybox supports (`-mmin`, `-print0`) instead.
- **A server whose clock is five minutes behind.** Containers share the host's
  clock and Docker has no time namespace, so the server-clock sweep window must
  be tested by shifting the **Mac VM's** clock instead (or the compose host's).
- **Any particular Tailscale SSH server.** `ts-ssh` is a real
  `tailscale/tailscale` node with `--ssh`, so a real `tailscaled` SSH server, a real
  `none` userauth and a real Go `pkg/sftp` subsystem, and `deb`'s `nopw` account
  (sshd's own `none` method) is the OpenSSH-side control case. What it cannot stand
  in for is another node's kernel, filesystem or local policy: a behaviour that
  reproduces on `ts-ssh` is evidence about Tailscale SSH, and one that does not
  reproduce is no evidence about a specific server.
- **Anything Mac-side**: 1Password/Secretive/`ssh-agent` key agents,
  `IdentityAgent`, FIDO/`sk` keys and user-presence prompts, Apple's `UseKeychain`,
  the login-shell `env -0` snapshot under fish/tcsh, the 60 s authentication
  deadline and its screen-unlock re-arm, `ControlPath` length limits under
  `$TMPDIR`, and the mux-client-without-a-socket behaviour. Those run against these
  servers but are tested on the VM.
- **Scale, out of the box.** The default trees are thousands of files, not a
  million-file tree or 5,000 roots; see the scaling knobs above. Sweep timings
  measured on a container on the same Mac are a floor, not a NAS.
- **A helper build.** These servers provide what the tier-2 helper needs - a
  writable, exec-capable `~/.cache`, `sha256sum` on Debian and busybox's
  `sha256sum` on Alpine - and nothing about the binary itself.
