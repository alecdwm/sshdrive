#!/bin/sh
# One version for the whole product, stamped from the repository's VERSION file.
#
#   scripts/set-version.sh 0.2.0      write VERSION and stamp every derived location
#   scripts/set-version.sh            stamp the derived locations from VERSION as it is
#   scripts/set-version.sh --check    exit non-zero, naming every location that disagrees
#
# VERSION is the only file a human edits. The derived locations are:
#
#   project.yml                       MARKETING_VERSION and CURRENT_PROJECT_VERSION under
#                                     settings.base, which xcodebuild substitutes into the
#                                     four hand-written Info.plists ($(MARKETING_VERSION)
#                                     and $(CURRENT_PROJECT_VERSION)). The plists carry no
#                                     literal, and --check fails if one reappears.
#                                     CURRENT_PROJECT_VERSION is CFBundleVersion, which
#                                     LaunchServices compares as a number to pick between
#                                     two copies of a bundle, so it is the integer
#                                     major*10000 + minor*100 + patch (0.1.4 is 104):
#                                     one value per release, always increasing.
#   helper/Cargo.toml                 the crate version, which is what `--version` prints,
#                                     what names the uploaded binary and what the app's
#                                     helper manifest is keyed on
#   helper/Cargo.lock                 cargo's own entry for the crate. Cargo rewrites it on
#                                     the next build; it is stamped here so the tree is
#                                     consistent without one.
#   Packages/SSHDriveCore/Sources/Config/Version.swift
#                                     SSHDriveVersion.string, which every Swift target
#                                     reports from
#   packaging/cask/sshdrive.rb        the cask's version. Its sha256 belongs to a built
#                                     DMG and is not this script's business:
#                                     .github/workflows/release.yml fills it in when it
#                                     pushes the cask to alecdwm/homebrew-tap.
#
# scripts/release.sh and scripts/mac-build.sh run --check before they build.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"

PROJECT_YML="$REPO_ROOT/project.yml"
CARGO_TOML="$REPO_ROOT/helper/Cargo.toml"
CARGO_LOCK="$REPO_ROOT/helper/Cargo.lock"
SWIFT_VERSION_FILE="$REPO_ROOT/Packages/SSHDriveCore/Sources/Config/Version.swift"
CASK="$REPO_ROOT/packaging/cask/sshdrive.rb"
PLISTS="Apps/Agent/Info.plist Apps/Askpass/Info.plist Apps/CLI/Info.plist Apps/FileProvider/Info.plist"

MODE=stamp
NEW=""
case "${1:-}" in
--check) MODE=check ;;
-h | --help)
	sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
	;;
"") ;;
-*)
	echo "unknown option: $1" >&2
	exit 2
	;;
*) NEW="$1" ;;
esac

# Three dotted integers, nothing else. CURRENT_PROJECT_VERSION is CFBundleVersion, which
# LaunchServices reads as a number: a "-beta" suffix there is rejected by the App Store's
# validation and compares in ways nobody predicts.
if [ -n "$NEW" ]; then
	case "$NEW" in
	*[!0-9.]* | *..* | .* | *.) echo "not a version: $NEW (want X.Y.Z)" >&2; exit 2 ;;
	esac
	if [ "$(printf %s "$NEW" | tr -cd . | wc -c | tr -d ' ')" != 2 ]; then
		echo "not a version: $NEW (want X.Y.Z)" >&2
		exit 2
	fi
	printf '%s\n' "$NEW" >"$VERSION_FILE"
fi

[ -f "$VERSION_FILE" ] || { echo "missing $VERSION_FILE" >&2; exit 1; }
VERSION="$(tr -d ' \t\r\n' <"$VERSION_FILE")"
[ -n "$VERSION" ] || { echo "$VERSION_FILE is empty" >&2; exit 1; }
BUILD="$(printf %s "$VERSION" | awk -F. '{ print $1 * 10000 + $2 * 100 + $3 }')"

# sed -i is spelled differently on BSD and GNU, so every edit goes through a temp file.
replace() { # file, sed script
	tmp="$1.set-version.$$"
	sed "$2" "$1" >"$tmp"
	if cmp -s "$tmp" "$1"; then rm -f "$tmp"; else mv "$tmp" "$1"; fi
}

# What each location currently says, or an empty string when the location is missing or
# unrecognisable.
read_project_yml() { sed -n 's/^    MARKETING_VERSION: *//p' "$PROJECT_YML" | head -1; }
read_project_yml_build() { sed -n 's/^    CURRENT_PROJECT_VERSION: *//p' "$PROJECT_YML" | head -1; }
read_cargo_toml() { sed -n '/^\[package\]/,/^\[/s/^version = "\(.*\)"$/\1/p' "$CARGO_TOML" | head -1; }
read_cargo_lock() {
	awk '/^name = "sshdrive-helper"$/ {found=1; next}
	     found && /^version = "/ {gsub(/^version = "|"$/, ""); print; exit}' "$CARGO_LOCK"
}
read_swift() { sed -n 's/.*static let string = "\(.*\)".*/\1/p' "$SWIFT_VERSION_FILE" | head -1; }
read_cask() { sed -n 's/^  version "\(.*\)"$/\1/p' "$CASK" | head -1; }
# A plist is stamped by xcodebuild, so what is checked is that the placeholder is there.
read_plist() { # file, key
	awk -v key="$2" '
		$0 ~ "<key>" key "</key>" { getline; gsub(/^[ \t]*<string>|<\/string>[ \t]*$/, ""); print; exit }
	' "$REPO_ROOT/$1"
}

FAILED=0
fail() {
	echo "	$1" >&2
	FAILED=1
}

if [ "$MODE" = check ]; then
	echo "==> checking every version against $VERSION (VERSION)"
	[ "$(read_project_yml)" = "$VERSION" ] ||
		fail "project.yml MARKETING_VERSION is \"$(read_project_yml)\""
	[ "$(read_project_yml_build)" = "$BUILD" ] ||
		fail "project.yml CURRENT_PROJECT_VERSION is \"$(read_project_yml_build)\", not $BUILD"
	[ "$(read_cargo_toml)" = "$VERSION" ] ||
		fail "helper/Cargo.toml version is \"$(read_cargo_toml)\""
	[ "$(read_cargo_lock)" = "$VERSION" ] ||
		fail "helper/Cargo.lock sshdrive-helper is \"$(read_cargo_lock)\" (run cargo build)"
	[ "$(read_swift)" = "$VERSION" ] ||
		fail "Config/Version.swift is \"$(read_swift)\""
	[ "$(read_cask)" = "$VERSION" ] ||
		fail "the cask's version is \"$(read_cask)\""
	for p in $PLISTS; do
		[ "$(read_plist "$p" CFBundleShortVersionString)" = '$(MARKETING_VERSION)' ] ||
			fail "$p CFBundleShortVersionString is \"$(read_plist "$p" CFBundleShortVersionString)\", not \$(MARKETING_VERSION)"
		[ "$(read_plist "$p" CFBundleVersion)" = '$(CURRENT_PROJECT_VERSION)' ] ||
			fail "$p CFBundleVersion is \"$(read_plist "$p" CFBundleVersion)\", not \$(CURRENT_PROJECT_VERSION)"
	done
	if [ "$FAILED" = 1 ]; then
		echo >&2
		echo "	Run scripts/set-version.sh to stamp them from VERSION." >&2
		exit 1
	fi
	echo "==> all versions agree"
	exit 0
fi

echo "==> stamping $VERSION"
replace "$PROJECT_YML" "s/^    MARKETING_VERSION: .*/    MARKETING_VERSION: $VERSION/"
replace "$PROJECT_YML" "s/^    CURRENT_PROJECT_VERSION: .*/    CURRENT_PROJECT_VERSION: $BUILD/"
replace "$CARGO_TOML" "/^\[package\]/,/^\[\[/s/^version = \".*\"$/version = \"$VERSION\"/"
replace "$CARGO_LOCK" "/^name = \"sshdrive-helper\"$/{n;s/^version = \".*\"$/version = \"$VERSION\"/;}"
replace "$SWIFT_VERSION_FILE" "s/static let string = \".*\"/static let string = \"$VERSION\"/"
replace "$CASK" "s/^  version \".*\"$/  version \"$VERSION\"/"

# Same output as --check, and the same exit status, so stamping a tree that has drifted in
# a way this script cannot fix (a literal back in an Info.plist) still fails loudly.
exec "$0" --check
