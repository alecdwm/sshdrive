#!/bin/sh
# SSH Drive testbed - entrypoint for the `ts-ssh` service (compose.yaml).
#
# The tailscale/tailscale image's own entrypoint is
#
#     ENTRYPOINT ["/usr/local/bin/containerboot"]
#
# which reads the TS_* environment, starts tailscaled and runs `tailscale up`.
# We override it so the container gets a seeded Unix account first, because
# Tailscale SSH will not let anyone in for a user that does not exist locally:
# the tailnet ACL decides *whether* you may connect, and getpwnam decides
# *what* you land in.  There is no sshd here and no authorized_keys anywhere -
# tailscaled serves SSH itself.
#
#   1. run the shared entrypoint.sh in its NO_SSHD mode (packages, the `alec`
#      account, the data tree) - it returns instead of exec'ing sshd;
#   2. exec containerboot, so it is still PID 1 and still gets the signals.
#
# Nothing here is Tailscale configuration; that is all TS_* in compose.yaml.
set -eu

NO_SSHD=1 /bin/sh /entrypoint.sh

BOOT=/usr/local/bin/containerboot
if [ ! -x "$BOOT" ]; then
	BOOT=$(command -v containerboot 2>/dev/null || true)
fi
if [ -z "$BOOT" ]; then
	echo "[testbed:ts-ssh] containerboot not found - is this really the" \
		"tailscale/tailscale image?  Check the image's ENTRYPOINT with:" \
		"docker inspect -f '{{json .Config.Entrypoint}}' tailscale/tailscale:<tag>" >&2
	exit 1
fi

echo "[testbed:ts-ssh] handing over to $BOOT" >&2
exec "$BOOT" "$@"
