#!/bin/sh
# Sync this repo to a Mac, regenerate the Xcode project and build it there.
#
# There is no Swift toolchain on the machine this repo is usually edited from, so the
# build happens over ssh. Nothing here mutates git on either side.
#
# Usage:
#   scripts/mac-build.sh              sync, generate, swift test, xcodebuild, ad-hoc sign
#   scripts/mac-build.sh test         sync, generate, swift build + swift test only
#   scripts/mac-build.sh app          sync, generate, xcodebuild, then ad-hoc sign
#   scripts/mac-build.sh sign         sync, generate, ad-hoc sign only
#   scripts/mac-build.sh signed       sync, generate, xcodebuild, then sign for real with
#                                     the Apple Development identity and the provisioning
#                                     profiles under ~/Developer on the Mac
#
# Override the host or the remote directory from the environment:
#   MAC_HOST=alec@100.114.204.5 MAC_DIR=~/sshdrive scripts/mac-build.sh

set -eu

MAC_HOST="${MAC_HOST:-alec@100.114.204.5}"
MAC_DIR="${MAC_DIR:-~/sshdrive}"
XCODEGEN="${XCODEGEN:-~/bin/xcodegen/bin/xcodegen}"
SCHEME="${SCHEME:-SSH Drive}"
CONFIGURATION="${CONFIGURATION:-Debug}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Signed mode (see below). The identity is matched by name against the login keychain.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: Alec Woodward-Mitchell (73XULXLK48)}"
TEAM_ID="${TEAM_ID:-RWGDZAYBM8}"
# The app's development profile. Embedded at Contents/embedded.provisionprofile, which is
# what makes the restricted keychain-access-groups entitlement acceptable to AMFI.
# Left empty here on purpose: it is resolved against the *Mac's* home directory below.
APP_PROFILE="${APP_PROFILE:-}"
# Optional. A profile for org.shirls.sshdrive.fileprovider carrying
# com.apple.developer.fileprovider.testing-mode. If it is absent the appex is signed
# without that key and without an embedded profile, which is still a valid signature.
# Two names are accepted because the App ID it was created under may be called either.
EXT_PROFILE="${EXT_PROFILE:-}"
# `codesign` over ssh fails with errSecInternalComponent when the login keychain is
# locked, because it cannot put a password dialog on a screen nobody is at. Set
# UNLOCK_KEYCHAIN=1 to have `signed` mode unlock it first with KEYCHAIN_PASSWORD (the
# build VM's login keychain has an empty password, which is the default here). Never set
# a real password on a command line that ends up in a shell history.
UNLOCK_KEYCHAIN="${UNLOCK_KEYCHAIN:-1}"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-}"

WHAT="${1:-all}"

echo "==> syncing $REPO_ROOT to $MAC_HOST:$MAC_DIR"
rsync -a --delete --exclude .git "$REPO_ROOT/" "$MAC_HOST:$MAC_DIR/"

echo "==> generating the Xcode project"
ssh -o BatchMode=yes "$MAC_HOST" "cd $MAC_DIR && $XCODEGEN generate"

if [ "$WHAT" = "all" ] || [ "$WHAT" = "test" ]; then
	echo "==> swift build and swift test (SSHDriveCore)"
	ssh -o BatchMode=yes "$MAC_HOST" \
		"cd $MAC_DIR/Packages/SSHDriveCore && swift build && swift test"
fi

if [ "$WHAT" = "all" ] || [ "$WHAT" = "app" ] || [ "$WHAT" = "signed" ]; then
	# xcodebuild cannot sign this project itself: com.apple.security.application-groups
	# and keychain-access-groups are restricted entitlements and it demands a
	# provisioning profile it can manage, which is not how the profiles here were made.
	# So every mode builds unsigned and signs afterwards, ad-hoc or for real.
	echo "==> xcodebuild ($SCHEME, $CONFIGURATION, unsigned; signing happens below)"
	ssh -o BatchMode=yes "$MAC_HOST" "cd $MAC_DIR && xcodebuild \
		-project 'SSH Drive.xcodeproj' \
		-scheme '$SCHEME' \
		-configuration '$CONFIGURATION' \
		-derivedDataPath build \
		CODE_SIGN_IDENTITY=- \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		ENABLE_HARDENED_RUNTIME=NO \
		DEVELOPMENT_TEAM= \
		CODE_SIGN_STYLE=Manual \
		build"
fi

if [ "$WHAT" = "all" ] || [ "$WHAT" = "app" ] || [ "$WHAT" = "sign" ]; then
	# xcodebuild refuses to sign the app and the appex without a provisioning profile,
	# because com.apple.security.application-groups and keychain-access-groups are
	# restricted entitlements. So the build above is unsigned (CODE_SIGNING_ALLOWED=NO,
	# which leaves only a linker-signed ad-hoc signature with the wrong identifier, no
	# entitlements and no sealed resources) and we ad-hoc sign the tree here ourselves,
	# innermost first, with the real identifiers and the real entitlement files.
	#
	# An ad-hoc signature has no Apple anchor and no team OU, so it does NOT satisfy the
	# agent's peer code requirement (Sources/XPCProtocols/CodeRequirement.swift). Write a
	# replacement into ~/.sshdrive-spike-peer-requirement on the Mac to relax it for a
	# spike; see docs/spikes/milestone-1.md. `signed` mode needs no such override.
	#
	# keychain-access-groups is stripped from the agent's entitlements here. AMFI kills an
	# ad-hoc signed binary that carries a restricted entitlement at exec ("The file is
	# adhoc signed but contains restricted entitlements", AMFI error -424), so the agent
	# would not launch at all with it. `signed` mode keeps it, which is the whole point of
	# having a profile.
	echo "==> ad-hoc signing the bundle with its entitlements"
	ssh -o BatchMode=yes "$MAC_HOST" "sh -eu -c '
		cd $MAC_DIR
		APP=\"build/Build/Products/$CONFIGURATION/SSH Drive.app\"
		cp Apps/Agent/SSHDrive.entitlements /tmp/sshdrive-adhoc-agent.plist
		plutil -remove keychain-access-groups /tmp/sshdrive-adhoc-agent.plist
		codesign --force --sign - --identifier org.shirls.sshdrive.cli \
			--entitlements Apps/CLI/sshdrive.entitlements \"\$APP/Contents/MacOS/sshdrive\"
		codesign --force --sign - --identifier org.shirls.sshdrive.askpass \
			--entitlements Apps/Askpass/sshdrive-askpass.entitlements \"\$APP/Contents/MacOS/sshdrive-askpass\"
		codesign --force --sign - --identifier org.shirls.sshdrive.fileprovider \
			--entitlements Apps/FileProvider/SSHDriveFileProvider.debug.entitlements \
			\"\$APP/Contents/PlugIns/SSHDriveFileProvider.appex\"
		codesign --force --sign - --identifier org.shirls.sshdrive \
			--entitlements /tmp/sshdrive-adhoc-agent.plist \"\$APP\"
		codesign --verify --deep --strict \"\$APP\"
	'"
fi

if [ "$WHAT" = "signed" ]; then
	# Real signing, with the Apple Development identity in the Mac's login keychain and
	# the development provisioning profiles under ~/Developer.
	#
	# What each piece is for:
	#
	#   embedded.provisionprofile   AMFI accepts a restricted entitlement only when the
	#                               bundle embeds a profile whose own entitlements allow
	#                               it and whose ProvisionedDevices list this Mac. That
	#                               is what unblocks keychain-access-groups on the agent
	#                               (S1 d1/d2), and testing-mode on the appex.
	#   com.apple.application-identifier / team-identifier
	#                               written into the signed entitlements to match the
	#                               profile, the way Xcode does it. Both are themselves
	#                               restricted and both appear in the profiles.
	#   --options runtime           the hardened runtime section 3.1 requires on every
	#                               executable.
	#   --timestamp=none            no notarization here, and the VM is not always able
	#                               to reach Apple's timestamp server. Milestone 10's
	#                               Developer ID + notarize path must NOT pass this.
	#   inside-out order            the CLI, askpass and the appex first, then the app,
	#                               because signing the wrapper seals whatever is inside.
	#
	# The extension keeps only the sandbox, the app group and (with its profile) the
	# testing-mode key. It never gets keychain-access-groups: the agent is the only
	# process with keychain access (section 3.1).
	if [ "$UNLOCK_KEYCHAIN" = "1" ]; then
		echo "==> unlocking the login keychain for codesign"
		ssh -o BatchMode=yes "$MAC_HOST" \
			"security unlock-keychain -p '$KEYCHAIN_PASSWORD' ~/Library/Keychains/login.keychain-db"
	fi
	echo "==> signing with \"$SIGN_IDENTITY\""
	ssh -o BatchMode=yes "$MAC_HOST" "sh -eu -c '
		cd $MAC_DIR
		APP=\"build/Build/Products/$CONFIGURATION/SSH Drive.app\"
		IDENTITY=\"$SIGN_IDENTITY\"
		APP_PROFILE=\"$APP_PROFILE\"
		EXT_PROFILE=\"$EXT_PROFILE\"
		[ -n \"\$APP_PROFILE\" ] || APP_PROFILE=\"\$HOME/Developer/SSH_Drive.provisionprofile\"
		[ -n \"\$EXT_PROFILE\" ] || EXT_PROFILE=\"\$(ls \$HOME/Developer/SSH_Drive_FileProvider*.provisionprofile 2>/dev/null | head -1)\"
		WORK=/tmp/sshdrive-signed
		rm -rf \$WORK && mkdir -p \$WORK

		test -f \"\$APP_PROFILE\" || { echo \"missing \$APP_PROFILE\"; exit 1; }

		# --- agent/app entitlements: exactly the file, with nothing added.
		#
		# In particular NOT com.apple.application-identifier. Xcode writes that key for a
		# profile-signed app, and adding it here makes AMFI refuse to let *launchd* start
		# the agent -- AMFI logs a Launch Constraint Violation, launch type 0. The
		# agent is the main executable of the app bundle itself (section 3), and an executable
		# carrying an application identifier may only be launched as an app, not as a
		# launchd job. Without the key the same bundle, the same profile and the same
		# restricted keychain-access-groups entitlement all work.
		# See docs/spikes/results.md, 2026-09-04 signed pass, S1(a1).
		cp Apps/Agent/SSHDrive.entitlements \$WORK/agent.plist
		PB=/usr/libexec/PlistBuddy

		# --- extension entitlements: sandbox + app group, plus testing-mode only when a
		#     profile that grants it is present.
		if [ -n \"\$EXT_PROFILE\" ] && [ -f \"\$EXT_PROFILE\" ]; then
			cp Apps/FileProvider/SSHDriveFileProvider.debug.entitlements \$WORK/ext.plist
			\$PB -c \"Delete :com.apple.application-identifier\" \$WORK/ext.plist >/dev/null 2>&1 || true
			\$PB -c \"Delete :com.apple.developer.team-identifier\" \$WORK/ext.plist >/dev/null 2>&1 || true
			\$PB -c \"Add :com.apple.application-identifier string $TEAM_ID.org.shirls.sshdrive.fileprovider\" \$WORK/ext.plist
			\$PB -c \"Add :com.apple.developer.team-identifier string $TEAM_ID\" \$WORK/ext.plist
			cp \"\$EXT_PROFILE\" \"\$APP/Contents/PlugIns/SSHDriveFileProvider.appex/Contents/embedded.provisionprofile\"
			echo \"appex: File Provider Testing Mode, profile \$EXT_PROFILE\"
		else
			cp Apps/FileProvider/SSHDriveFileProvider.entitlements \$WORK/ext.plist
			rm -f \"\$APP/Contents/PlugIns/SSHDriveFileProvider.appex/Contents/embedded.provisionprofile\"
			echo \"appex: no File Provider profile found; signing without testing-mode\"
		fi

		cp \"\$APP_PROFILE\" \"\$APP/Contents/embedded.provisionprofile\"

		# --- inside out. The CLI and askpass carry no entitlements at all (section 3.1)
		#     and are signed with their explicit identifiers, because a bare tool would
		#     otherwise be signed as its product name and fail the peer requirement.
		codesign --force --sign \"\$IDENTITY\" --options runtime --timestamp=none \
			--identifier org.shirls.sshdrive.cli \"\$APP/Contents/MacOS/sshdrive\"
		codesign --force --sign \"\$IDENTITY\" --options runtime --timestamp=none \
			--identifier org.shirls.sshdrive.askpass \"\$APP/Contents/MacOS/sshdrive-askpass\"
		codesign --force --sign \"\$IDENTITY\" --options runtime --timestamp=none \
			--identifier org.shirls.sshdrive.fileprovider --entitlements \$WORK/ext.plist \
			\"\$APP/Contents/PlugIns/SSHDriveFileProvider.appex\"
		codesign --force --sign \"\$IDENTITY\" --options runtime --timestamp=none \
			--identifier org.shirls.sshdrive --entitlements \$WORK/agent.plist \"\$APP\"

		echo \"--- codesign --verify --deep --strict\"
		codesign --verify --deep --strict --verbose=2 \"\$APP\"
		for x in \"\$APP\" \
			\"\$APP/Contents/MacOS/SSH Drive\" \
			\"\$APP/Contents/MacOS/sshdrive\" \
			\"\$APP/Contents/MacOS/sshdrive-askpass\" \
			\"\$APP/Contents/PlugIns/SSHDriveFileProvider.appex\"; do
			echo \"--- \$x\"
			codesign -dvv \"\$x\" 2>&1 | grep -E \"^(Identifier|Authority|TeamIdentifier|Signature)\" || true
			codesign -d --entitlements - --xml \"\$x\" 2>/dev/null | plutil -p - || echo \"(no entitlements)\"
		done
	'"
fi
