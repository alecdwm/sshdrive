#!/bin/sh
# Build the remote helper (change detection tier 2, docs/design/change-detection.md) and
# lay the result out the way the bundle and the release expect
# (docs/design/components.md, docs/design/packaging.md):
#
#   Resources/helper/sshdrive-helper-<version>-<os>-<arch>   one static binary per target
#   Resources/helper/manifest.json                           version + sha256 + size for each
#
# That directory is copied into `SSH Drive.app/Contents/Resources/helper/` by the build
# (see project.yml). It is deliberately NOT in git - the release binaries come from CI
# (.github/workflows/helper.yml) - so a developer build simply has fewer targets in it, or
# none, and the agent then reports the sweep tier and says why.
#
# Usage:
#   scripts/build-helper.sh                 the host's own musl target
#   scripts/build-helper.sh aarch64-unknown-linux-musl x86_64-unknown-linux-musl
#   HELPER_OUT=/tmp/x scripts/build-helper.sh …
#   scripts/build-helper.sh --manifest          rebuild manifest.json only
#
# No cross C toolchain is needed for the musl targets: helper/.cargo/config.toml links them
# with rustc's own `rust-lld` and its bundled self-contained objects, so `rustup target add`
# is the whole of the setup. The FreeBSD and Apple targets cannot be linked that way and
# are built by CI on their own runners.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$REPO_ROOT/helper"
OUT="${HELPER_OUT:-$REPO_ROOT/Resources/helper}"
CARGO="${CARGO:-cargo}"

VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$CRATE/Cargo.toml" | head -1)"
[ -n "$VERSION" ] || { echo "could not read the helper's version"; exit 1; }

# `--manifest` rebuilds manifest.json over whatever is already in the directory and builds
# nothing; release.sh uses it after signing the darwin binary, which changes its bytes.
if [ "${1:-}" = --manifest ]; then
	TARGETS=""
elif [ "$#" -gt 0 ]; then
	TARGETS="$*"
else
	TARGETS="$(uname -m)-unknown-linux-musl"
fi

mkdir -p "$OUT"

# `uname -sm` spellings, which are what the manifest is keyed on and what a server prints.
target_os() {
	case "$1" in
	*-linux-*) echo linux ;;
	*-apple-darwin) echo darwin ;;
	*-freebsd) echo freebsd ;;
	*) echo "unknown target $1" >&2; exit 1 ;;
	esac
}

target_arch() {
	case "$1" in
	aarch64-*) echo aarch64 ;;
	x86_64-*) echo x86_64 ;;
	armv7-*) echo armv7 ;;
	*) echo "unknown target $1" >&2; exit 1 ;;
	esac
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

size_of() {
	# BSD and GNU stat disagree about everything except this working.
	wc -c <"$1" | tr -d ' '
}

for TARGET in $TARGETS; do
	echo "==> building $TARGET"
	( cd "$CRATE" && "$CARGO" build --release --target "$TARGET" )
	OS="$(target_os "$TARGET")"
	ARCH="$(target_arch "$TARGET")"
	NAME="sshdrive-helper-$VERSION-$OS-$ARCH"
	cp "$CRATE/target/$TARGET/release/sshdrive-helper" "$OUT/$NAME"
	chmod 755 "$OUT/$NAME"
	# arm64 macOS refuses to run unsigned code, even over ssh.
	if [ "$OS" = darwin ] && command -v codesign >/dev/null 2>&1; then
		codesign --force --sign - --timestamp=none "$OUT/$NAME" >/dev/null 2>&1 || true
	fi
done

# The manifest is rebuilt from whatever is in the directory, so adding a target is one more
# invocation of this script and never an edit here.
{
	printf '{\n  "version": "%s",\n  "binaries": [\n' "$VERSION"
	FIRST=1
	for FILE in "$OUT"/sshdrive-helper-*; do
		[ -f "$FILE" ] || continue
		NAME="$(basename "$FILE")"
		OS="$(echo "$NAME" | sed "s/^sshdrive-helper-$VERSION-//; s/-[^-]*$//")"
		ARCH="$(echo "$NAME" | sed 's/.*-//')"
		[ "$FIRST" = 1 ] || printf ',\n'
		FIRST=0
		printf '    {"os": "%s", "arch": "%s", "file": "%s", "sha256": "%s", "size": %s}' \
			"$OS" "$ARCH" "$NAME" "$(sha256_of "$FILE")" "$(size_of "$FILE")"
	done
	printf '\n  ]\n}\n'
} >"$OUT/manifest.json"

echo "==> $OUT"
ls -l "$OUT"
cat "$OUT/manifest.json"
