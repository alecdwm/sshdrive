#!/bin/sh
# SSH Drive testbed - shared entrypoint for every service in compose.yaml.
#
# Everything is driven by environment variables set per service:
#   SVC               service name (also the host-key subdirectory)
#   PKGS              extra packages to install
#   AUTHORIZED_KEYS   public keys authorised on every key account
#   PASSWORD          password for this service's password accounts
#   USERS             one record per line: name:uid:shell:auth:flags
#                       auth  = key | pass | both | none
#                       flags = comma separated, or "-":
#                               data       seed a data tree in this home
#                               noisy      rc file that prints to stdout
#                               bg         rc file that prints and leaves a
#                                          background child holding stdout
#                               forcesftp  Match User ... ForceCommand internal-sftp
#                               emptypw    Match User ... PermitEmptyPasswords yes
#   SSHD_EXTRA        sshd_config lines placed FIRST (sshd: first value wins)
#   SFTP_SUBSYSTEM    internal-sftp (default) or a path to an external sftp-server
#   FIND_SHIM         1 = replace find with a shim that rejects -cmin/-printf
#   SEED_TREE_DIRS SEED_TREE_FILES SEED_MANY SEED_BYTES BIG_FILE
set -eu

SVC="${SVC:-unnamed}"
HK="/hostkeys/$SVC"
CONF="/etc/ssh/sshd_config.spike"
MATCH="/tmp/sshd_match.spike"
PASSWORD="${PASSWORD:-spike-password}"

log() { printf '[testbed:%s] %s\n' "$SVC" "$*" >&2; }
is_alpine() { [ -f /etc/alpine-release ]; }

# --------------------------------------------------------------- packages ---
if [ ! -x /usr/sbin/sshd ]; then
	log "installing packages (first start only) ..."
	if is_alpine; then
		apk add --no-cache openssh-server openssh-keygen openssh-sftp-server ${PKGS:-} >/dev/null
	else
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq >/dev/null
		apt-get install -y -qq --no-install-recommends openssh-server ${PKGS:-} >/dev/null
	fi
fi
mkdir -p /run/sshd /etc/ssh

# -------------------------------------------------- host keys (persisted) ---
mkdir -p "$HK"
for t in ed25519 rsa; do
	if [ ! -f "$HK/ssh_host_${t}_key" ]; then
		log "generating $t host key in the hostkeys volume"
		ssh-keygen -q -t "$t" -N '' -C "sshdrive-testbed-$SVC" -f "$HK/ssh_host_${t}_key"
	fi
done
chmod 700 "$HK"
chmod 600 "$HK"/ssh_host_*_key
chmod 644 "$HK"/ssh_host_*_key.pub

# ------------------------------------------------------------- find shim ----
# Emulates a busybox older than 1.34 (as shipped by some Synology DSM builds):
# no -cmin, no -printf, so the sweep has to fall back to -mmin (DESIGN 6.4).
if [ "${FIND_SHIM:-0}" = "1" ]; then
	rm -f /usr/bin/find                    # it is a busybox symlink; do not write through it
	cat >/usr/bin/find <<'SHIM'
#!/bin/sh
for a in "$@"; do
	case "$a" in
	-cmin|-printf|-newerct|-newermt)
		printf 'find: unrecognized: %s\n' "$a" >&2
		printf 'BusyBox v1.31.1 () multi-call binary.\n' >&2
		exit 1
		;;
	esac
done
exec busybox find "$@"
SHIM
	chmod 755 /usr/bin/find
fi

# ------------------------------------------------------------- data trees ---
seed_data() {
	u="$1"
	home="/home/$u"
	d="$home/data"
	[ -f "$home/.testbed-seeded" ] && return 0
	dirs="${SEED_TREE_DIRS:-250}"
	files="${SEED_TREE_FILES:-20}"
	many="${SEED_MANY:-10000}"
	bytes="${SEED_BYTES:-2048}"
	log "seeding $d: tree ${dirs}x${files}, many ${many}, ${bytes} bytes each ..."
	mkdir -p "$d/tree" "$d/many" "$d/weird"
	if command -v perl >/dev/null 2>&1; then
		perl -e '
my ($base,$D,$F,$M,$B) = @ARGV;
my $buf = "s" x $B;
for my $i (0 .. $D-1) {
	my $dir = sprintf("%s/tree/d%04d", $base, $i);
	mkdir $dir;
	for my $j (0 .. $F-1) {
		open my $fh, ">", sprintf("%s/f%03d.bin", $dir, $j) or die $!;
		print $fh $buf; close $fh;
	}
}
for my $k (0 .. $M-1) {
	open my $fh, ">", sprintf("%s/many/m%06d.bin", $base, $k) or die $!;
	print $fh $buf; close $fh;
}
my @weird = (q{space in name}, q{quote} . chr(39) . q{name}, q{$(echo pwned)},
             q{[bracket]}, q{back\slash}, q{*star*}, qq{new\nline},
             qq{utf8-caf\xc3\xa9}, qq{latin1-caf\xff}, q{.hidden});
for my $w (@weird) {
	mkdir "$base/weird/$w";
	open my $fh, ">", "$base/weird/$w/inside.txt" or next;
	print $fh "x"; close $fh;
}
' "$d" "$dirs" "$files" "$many" "$bytes"
	else
		# No perl (the stock Alpine image has none). This branch must produce the
		# same tree as the perl one above: same zero-padded names, same file size,
		# and the same ten weird names -- anything else and a spike measured on
		# Alpine is not comparable with the same measurement on Debian.
		buf=$(awk -v n="$bytes" 'BEGIN { s = ""; while (length(s) < n) s = s "s"; printf "%s", substr(s, 1, n) }')
		i=0
		while [ "$i" -lt "$dirs" ]; do
			sub=$(printf '%s/tree/d%04d' "$d" "$i")
			mkdir -p "$sub"
			j=0
			while [ "$j" -lt "$files" ]; do
				printf '%s' "$buf" >"$(printf '%s/f%03d.bin' "$sub" "$j")"
				j=$((j + 1))
			done
			i=$((i + 1))
		done
		k=0
		while [ "$k" -lt "$many" ]; do
			printf '%s' "$buf" >"$(printf '%s/many/m%06d.bin' "$d" "$k")"
			k=$((k + 1))
		done
		nb=$(printf 'latin1-caf\377')
		utf8=$(printf 'utf8-caf\303\251')
		for w in 'space in name' 'quote'"'"'name' '$(echo pwned)' '[bracket]' 'back\slash' '*star*' '.hidden' "$utf8" "$nb"; do
			mkdir -p "$d/weird/$w" && echo x >"$d/weird/$w/inside.txt"
		done
		mkdir -p "$d/weird/new
line" && echo x >"$d/weird/new
line/inside.txt"
	fi
	if [ "${BIG_FILE:-0}" = "1" ] && [ ! -f "$d/big/1g.bin" ]; then
		log "writing $d/big/1g.bin (1 GiB, this takes a while) ..."
		mkdir -p "$d/big"
		dd if=/dev/urandom of="$d/big/1g.bin" bs=1M count=1024 2>/dev/null
	fi
	chown -R "$u:$u" "$home"
	: >"$home/.testbed-seeded"
	chown "$u:$u" "$home/.testbed-seeded"
	log "seeded $(find "$d" | wc -l) paths under $d"
}

# --------------------------------------------------------------- rc files ---
# The point of these is DESIGN 9.2: rc output lands in front of the script's
# own bytes, and the sentinel is what discards it.
write_rc() {
	u="$1"; sh_path="$2"; mode="$3"
	home="/home/$u"
	msg="testbed rc noise from $SVC for $u -- everything before the sentinel must be discarded"
	case "$sh_path" in
	*/zsh)
		printf 'echo "%s (.zshenv)"\n' "$msg" >"$home/.zshenv"
		rc="$home/.zshenv"
		;;
	*/fish)
		mkdir -p "$home/.config/fish"
		printf 'echo "%s (config.fish)"\n' "$msg" >"$home/.config/fish/config.fish"
		rc="$home/.config/fish/config.fish"
		;;
	*/tcsh | */csh)
		printf 'echo "%s (.cshrc)"\n' "$msg" >"$home/.cshrc"
		rc="$home/.cshrc"
		;;
	*/bash)
		printf 'echo "%s (.bashrc)"\n' "$msg" >"$home/.bashrc"
		rc="$home/.bashrc"
		;;
	*)
		# dash and busybox ash read no rc file for a non-interactive shell,
		# so this one is inert on purpose; it documents itself.
		printf '# %s (never sourced non-interactively)\n' "$msg" >"$home/.profile"
		rc="$home/.profile"
		;;
	esac
	if [ "$mode" = "bg" ]; then
		# A background child that keeps stdout open after the script finished:
		# EOF never arrives, so only the closing sentinel ends the read.
		printf '( sleep 300 & )\n' >>"$rc"
	fi
	chown "$u:$u" "$rc" 2>/dev/null || true
}

# --------------------------------------------------------------- accounts ---
set_password() {
	if is_alpine; then
		printf '%s:%s\n' "$1" "$2" | chpasswd -m >/dev/null 2>&1 ||
			printf '%s:%s\n' "$1" "$2" | chpasswd >/dev/null
	else
		printf '%s:%s\n' "$1" "$2" | chpasswd >/dev/null
	fi
}

# "!" in the shadow field makes OpenSSH refuse the account outright
# ("not allowed because account is locked") under UsePAM no, key auth included.
shadow_field() { sed -i "s|^$1:[^:]*:|$1:$2:|" /etc/shadow; }

add_user() {
	name="$1"; uid="$2"; shell="$3"; auth="$4"; flags="$5"
	sh_path=$(command -v "$shell" 2>/dev/null || true)
	[ -n "$sh_path" ] || { log "WARNING: shell '$shell' not found, using /bin/sh for $name"; sh_path=/bin/sh; }
	home="/home/$name"
	if ! id -u "$name" >/dev/null 2>&1; then
		if is_alpine; then
			addgroup -g "$uid" "$name" 2>/dev/null || true
			adduser -D -u "$uid" -G "$name" -h "$home" -s "$sh_path" "$name" >/dev/null
		else
			useradd -m -u "$uid" -d "$home" -s "$sh_path" "$name" >/dev/null
		fi
	fi
	mkdir -p "$home"
	chown "$name:$name" "$home"
	chmod 755 "$home"

	case "$auth" in
	pass | both) set_password "$name" "$PASSWORD" ;;
	none) shadow_field "$name" "" ;;
	*) shadow_field "$name" "*" ;;
	esac
	case "$auth" in
	key | both)
		mkdir -p "$home/.ssh"
		printf '%s\n' "${AUTHORIZED_KEYS:-}" >"$home/.ssh/authorized_keys"
		chmod 700 "$home/.ssh"
		chmod 600 "$home/.ssh/authorized_keys"
		chown -R "$name:$name" "$home/.ssh"
		;;
	esac

	OIFS="$IFS"; IFS=,
	for f in $flags; do
		IFS="$OIFS"
		case "$f" in
		noisy) write_rc "$name" "$sh_path" print ;;
		bg) write_rc "$name" "$sh_path" bg ;;
		data) seed_data "$name" ;;
		forcesftp)
			{
				echo "Match User $name"
				echo "    ForceCommand internal-sftp"
				echo "    AllowTcpForwarding no"
				echo "    PermitTTY no"
			} >>"$MATCH"
			;;
		emptypw)
			{
				echo "Match User $name"
				echo "    PermitEmptyPasswords yes"
			} >>"$MATCH"
			;;
		- | "") ;;
		*) log "WARNING: unknown flag '$f' for $name" ;;
		esac
		IFS=,
	done
	IFS="$OIFS"
	log "account $name uid=$uid shell=$sh_path auth=$auth flags=$flags"
}

: >"$MATCH"
printf '%s\n' "${USERS:-}" | while IFS=: read -r name uid shell auth flags; do
	case "$name" in "" | \#*) continue ;; esac
	add_user "$name" "$uid" "$shell" "$auth" "${flags:--}"
done

# ------------------------------------------------------------ sshd_config ---
# sshd takes the FIRST value for each keyword, so SSHD_EXTRA goes above the
# defaults and the generated Match blocks go last.
{
	echo "# generated by the sshdrive testbed entrypoint for $SVC"
	echo "Port 22"
	echo "HostKey $HK/ssh_host_ed25519_key"
	echo "HostKey $HK/ssh_host_rsa_key"
	echo "PidFile /run/sshd.pid"
	printf '%s\n' "${SSHD_EXTRA:-}"
	cat <<EOF
LogLevel VERBOSE
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM no
StrictModes yes
PrintMotd no
PrintLastLog no
X11Forwarding no
AllowTcpForwarding yes
PermitTunnel no
AcceptEnv LANG LC_*
Subsystem sftp ${SFTP_SUBSYSTEM:-internal-sftp}
EOF
	cat "$MATCH"
} >"$CONF"
chmod 600 "$CONF"

case "${SSHD_EXTRA:-}" in
*"UsePAM yes"*)
	# pam_loginuid cannot work in a container and would fail the session.
	[ -f /etc/pam.d/sshd ] && sed -i 's|^\(session[[:space:]]*required[[:space:]]*pam_loginuid.so\)|#\1|' /etc/pam.d/sshd
	;;
esac

/usr/sbin/sshd -t -f "$CONF" || { log "sshd_config rejected:"; cat "$CONF" >&2; exit 1; }
log "sshd starting on container port 22 (subsystem: ${SFTP_SUBSYSTEM:-internal-sftp})"
exec /usr/sbin/sshd -D -e -f "$CONF"
