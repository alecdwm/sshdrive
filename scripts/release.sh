#!/bin/sh
# Build, sign, notarize and package a release of SSH Drive (DESIGN.md section 10).
#
# There is no Swift toolchain on the machine this repo is usually edited from, so every
# step runs on the Mac over ssh, exactly as scripts/mac-build.sh does. Nothing here
# mutates git on either side.
#
# What it does, in order:
#
#   1. sync the tree to the Mac and regenerate the Xcode project
#   2. xcodebuild -configuration Release, unsigned (see mac-build.sh for why)
#   3. embed the helper binaries from Resources/helper, before signing seals them
#   4. sign inside out with the Developer ID Application identity and the hardened
#      runtime, embedding the Developer ID provisioning profile when one is present
#   5. codesign --verify --deep --strict and spctl --assess on the app
#   6. build the DMG with hdiutil: the app plus an /Applications symlink
#   7. xcrun notarytool submit --wait, then stapler staple on the DMG and on the app
#   8. sha256 beside the DMG, and the cask's sha256 line printed
#
# Step 7 takes its credentials in one of two ways, in this order:
#
#   an App Store Connect API key   NOTARY_KEY (a .p8 path *on the Mac*), NOTARY_KEY_ID
#                                  and NOTARY_ISSUER. NOTARY_KEY defaults to the single
#                                  ~/Developer/AuthKey_*.p8 on the Mac when there is
#                                  exactly one. This is the route that works headlessly.
#   a notarytool keychain profile  NOTARY_PROFILE (default sshdrive-notary), used only
#                                  when the three variables above are unset and the
#                                  profile already exists. `notarytool store-credentials`
#                                  cannot create one over ssh - it needs to write to the
#                                  login keychain interactively and fails with "User
#                                  interaction is not allowed" even with the keychain
#                                  unlocked - so the profile has to be made at the
#                                  console, and the API key is the headless route.
#
# With neither available, step 7 is skipped loudly and without failing the run: the script
# prints exactly what material is missing and stops with the unnotarized DMG in place.
#
# The .p8 key stays on the Mac. It is never copied into this repo, into the bundle or into
# the DMG.
#
# Usage:
#   scripts/release.sh                  everything above
#   scripts/release.sh build            1-5 only (a signed Release app, no DMG)
#   scripts/release.sh dmg              1-6 (a signed Release app and a DMG, no notarize)
#   scripts/release.sh notarize         7-8 against the DMG already on the Mac
#   scripts/release.sh install          install the Release app already built on the Mac
#                                       into /Applications over ssh, the way the cask's
#                                       upgrade path does (stop, replace, re-register the
#                                       login item). Also runs after `all` when
#                                       RELEASE_INSTALL=1 is set.
#
# Environment:
#   MAC_HOST, MAC_DIR, XCODEGEN     as in scripts/mac-build.sh
#   VERSION                         the release version; default: from Apps/Agent/Info.plist
#   SIGN_IDENTITY                   default: the Developer ID Application below
#   RELEASE_PROFILE                 the Developer ID provisioning profile *on the Mac*.
#                                   Default: ~/Developer/SSH_Drive_Developer_ID.provisionprofile,
#                                   else the single match of
#                                   ~/Developer/SSH_Drive*Developer*ID*.provisionprofile.
#                                   Embedded only if it exists.
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                                   App Store Connect API key on the Mac (preferred)
#   NOTARY_PROFILE                  notarytool keychain profile; default sshdrive-notary
#   UNLOCK_KEYCHAIN/KEYCHAIN_PASSWORD  as in scripts/mac-build.sh
#   RELEASE_INSTALL                 when 1, `scripts/release.sh` (with no argument, i.e.
#                                   `all`) also runs the `install` step at the end

set -eu

MAC_HOST="${MAC_HOST:-alec@100.114.204.5}"
MAC_DIR="${MAC_DIR:-~/sshdrive}"
XCODEGEN="${XCODEGEN:-~/bin/xcodegen/bin/xcodegen}"
SCHEME="${SCHEME:-SSH Drive}"
CONFIGURATION=Release
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The Developer ID Application certificate in the Mac's login keychain, by SHA-1 hash
# rather than by name: two certificates can share a name, and `codesign` then refuses with
# "ambiguous (matches multiple identities)".
SIGN_IDENTITY="${SIGN_IDENTITY:-6C055553C6A361398A3CC48654E1FADC14660D05}"
TEAM_ID="${TEAM_ID:-RWGDZAYBM8}"
NOTARY_PROFILE="${NOTARY_PROFILE:-sshdrive-notary}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
UNLOCK_KEYCHAIN="${UNLOCK_KEYCHAIN:-1}"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-}"
# Resolved against the *Mac's* home directory below when left empty.
RELEASE_PROFILE="${RELEASE_PROFILE:-${APP_PROFILE:-}}"

VERSION="${VERSION:-$(/usr/bin/awk '/<key>CFBundleShortVersionString<\/key>/{getline; gsub(/.*<string>|<\/string>.*/,""); print; exit}' "$REPO_ROOT/Apps/Agent/Info.plist" 2>/dev/null || echo 0.1.0)}"
DMG_NAME="SSH-Drive-${VERSION}.dmg"

WHAT="${1:-all}"

# ---------------------------------------------------------------- 1. sync and generate

if [ "$WHAT" != "notarize" ] && [ "$WHAT" != "install" ]; then
	echo "==> syncing $REPO_ROOT to $MAC_HOST:$MAC_DIR"
	rsync -a --delete --exclude .git --exclude helper/target "$REPO_ROOT/" "$MAC_HOST:$MAC_DIR/"

	echo "==> generating the Xcode project"
	ssh -o BatchMode=yes "$MAC_HOST" "cd $MAC_DIR && $XCODEGEN generate"
fi

# ---------------------------------------------------------------- 2-5. build and sign

if [ "$WHAT" = "all" ] || [ "$WHAT" = "build" ] || [ "$WHAT" = "dmg" ]; then
	echo "==> xcodebuild ($SCHEME, Release, unsigned; signing happens below)"
	ssh -o BatchMode=yes "$MAC_HOST" "cd $MAC_DIR && xcodebuild \
		-project 'SSH Drive.xcodeproj' \
		-scheme '$SCHEME' \
		-configuration Release \
		-derivedDataPath build \
		CODE_SIGN_IDENTITY=- \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		ENABLE_HARDENED_RUNTIME=NO \
		DEVELOPMENT_TEAM= \
		CODE_SIGN_STYLE=Manual \
		build"

	# The helper binaries go in before the signature, because signing the app seals
	# whatever is inside it (section 6.4 tier 2, section 10.1).
	echo "==> embedding the helper"
	ssh -o BatchMode=yes "$MAC_HOST" "sh -eu -c '
		cd $MAC_DIR
		APP=\"build/Build/Products/Release/SSH Drive.app\"
		if [ -f Resources/helper/manifest.json ]; then
			mkdir -p \"\$APP/Contents/Resources/helper\"
			ditto Resources/helper \"\$APP/Contents/Resources/helper\"
			ls \"\$APP/Contents/Resources/helper\"
		else
			echo \"WARNING: no Resources/helper/manifest.json; this release ships no helper\"
			echo \"         (run scripts/build-helper.sh, or take CI'\''s artifacts)\"
		fi
	'"

	if [ "$UNLOCK_KEYCHAIN" = "1" ]; then
		echo "==> unlocking the login keychain for codesign"
		ssh -o BatchMode=yes "$MAC_HOST" \
			"security unlock-keychain -p '$KEYCHAIN_PASSWORD' ~/Library/Keychains/login.keychain-db"
	fi

	# Release signing. The differences from mac-build.sh's `signed` mode, all of them
	# deliberate:
	#
	#   Developer ID, not Apple Development   the only identity Gatekeeper accepts off
	#                                         the network, and the only one notarization
	#                                         takes.
	#   --timestamp (not --timestamp=none)    notarization rejects a signature with no
	#                                         secure timestamp. This needs the Mac to
	#                                         reach timestamp.apple.com.
	#   the appex's *release* entitlements    no com.apple.developer.fileprovider.testing-mode:
	#                                         it is a debug-only key (section 3.1) and a
	#                                         release build has no profile granting it.
	#   the agent keeps keychain-access-groups
	#                                         which is the whole reason the bundle embeds
	#                                         a Developer ID profile (section 3.1).
	#   still no com.apple.application-identifier on the agent
	#                                         an executable carrying one may only be
	#                                         launched as an app, and AMFI refuses to let
	#                                         launchd start it (S1 a1, 2026-09-04).
	# Resolve the Developer ID profile on the Mac, and check that it actually authorises
	# this signature before embedding it.
	#
	# AMFI matches the *certificate*: a profile carries the DeveloperCertificates it was
	# created for, and one made against a different Developer ID Application certificate
	# than the one signing here is not merely ignored - every restricted entitlement in
	# the bundle becomes unsatisfied, amfid answers "No matching profile found" (-413) and
	# the agent is SIGKILLed at exec. Such a build notarizes perfectly and then will not
	# launch, which is the worst possible order to find out in (measured 2026-09-05; see
	# docs/spikes/milestone-10.md). So it is checked here, before signing.
	#
	# The glob deliberately requires both "Developer" and "ID" in the name: the other
	# profile in that directory is SSH_Drive_FileProvider_Testing, which grants
	# com.apple.developer.fileprovider.testing-mode - a debug-only key (section 3.1) that
	# must never be embedded in, or signed into, a release.
	RESOLVED_PROFILE="$(ssh -o BatchMode=yes "$MAC_HOST" "sh -c '
		p=\"$RELEASE_PROFILE\"
		if [ -z \"\$p\" ]; then
			p=\"\$HOME/Developer/SSH_Drive_Developer_ID.provisionprofile\"
			if [ ! -f \"\$p\" ]; then
				set -- \$HOME/Developer/SSH_Drive*Developer*ID*.provisionprofile
				if [ \$# -eq 1 ] && [ -f \"\$1\" ]; then p=\"\$1\"; else p=; fi
			fi
		fi
		[ -f \"\$p\" ] && printf %s \"\$p\"
	'")"
	PROFILE_CERTS=""
	if [ -n "$RESOLVED_PROFILE" ]; then
		PROFILE_CERTS="$(ssh -o BatchMode=yes "$MAC_HOST" \
			"security cms -D -i '$RESOLVED_PROFILE' | plutil -convert xml1 -o - - | \
			 python3 -c 'import hashlib,plistlib,sys; print(\" \".join(hashlib.sha1(c).hexdigest().upper() for c in plistlib.loads(sys.stdin.buffer.read()).get(\"DeveloperCertificates\",[])))'")"
	fi
	EMBED_PROFILE=""
	case " $PROFILE_CERTS " in
	*" $(printf %s "$SIGN_IDENTITY" | tr 'a-f' 'A-F') "*) EMBED_PROFILE="$RESOLVED_PROFILE" ;;
	esac
	if [ -z "$EMBED_PROFILE" ]; then
		echo
		echo "	WARNING -------------------------------------------------------"
		if [ -z "$RESOLVED_PROFILE" ]; then
			echo "	No Developer ID provisioning profile found on $MAC_HOST at"
			echo "	  ~/Developer/SSH_Drive_Developer_ID.provisionprofile"
			echo "	(or a single ~/Developer/SSH_Drive*Developer*ID*.provisionprofile)."
		else
			echo "	$RESOLVED_PROFILE does not authorise the signing identity."
			echo "	  signing certificate: $SIGN_IDENTITY"
			echo "	  profile certificates: ${PROFILE_CERTS:-(none)}"
			echo "	Re-create the Developer ID profile at developer.apple.com for"
			echo "	org.shirls.sshdrive, selecting the certificate above. A profile"
			echo "	naming a different Developer ID certificate does not merely fail to"
			echo "	help: it makes AMFI kill the agent at exec (-413)."
		fi
		echo "	Signing WITHOUT keychain-access-groups. The build runs, mounts and"
		echo "	syncs; it cannot reach the keychain, so no stored password or key"
		echo "	passphrase is usable (DESIGN.md section 3.1)."
		echo "	---------------------------------------------------------------"
		echo
	fi

	echo "==> signing Release with $SIGN_IDENTITY"
	ssh -o BatchMode=yes "$MAC_HOST" "sh -eu -c '
		cd $MAC_DIR
		APP=\"build/Build/Products/Release/SSH Drive.app\"
		IDENTITY=\"$SIGN_IDENTITY\"
		APP_PROFILE=\"$EMBED_PROFILE\"
		WORK=/tmp/sshdrive-release
		rm -rf \$WORK && mkdir -p \$WORK

		cp Apps/Agent/SSHDrive.entitlements \$WORK/agent.plist
		cp Apps/FileProvider/SSHDriveFileProvider.entitlements \$WORK/ext.plist

		# The caller has already decided whether this profile authorises this identity;
		# an empty APP_PROFILE means it does not, and the restricted entitlement goes.
		if [ -n \"\$APP_PROFILE\" ] && [ -f \"\$APP_PROFILE\" ]; then
			cp \"\$APP_PROFILE\" \"\$APP/Contents/embedded.provisionprofile\"
			echo \"embedded \$APP_PROFILE\"
		else
			echo \"signing without keychain-access-groups (no usable Developer ID profile)\"
			/usr/libexec/PlistBuddy -c \"Delete :keychain-access-groups\" \$WORK/agent.plist
			rm -f \"\$APP/Contents/embedded.provisionprofile\"
		fi
		rm -f \"\$APP/Contents/PlugIns/SSHDriveFileProvider.appex/Contents/embedded.provisionprofile\"

		# Inside out: the CLI, askpass and the appex first, then the app.
		codesign --force --sign \"\$IDENTITY\" --options runtime --timestamp \
			--identifier org.shirls.sshdrive.cli \"\$APP/Contents/MacOS/sshdrive\"
		codesign --force --sign \"\$IDENTITY\" --options runtime --timestamp \
			--identifier org.shirls.sshdrive.askpass \"\$APP/Contents/MacOS/sshdrive-askpass\"
		codesign --force --sign \"\$IDENTITY\" --options runtime --timestamp \
			--identifier org.shirls.sshdrive.fileprovider --entitlements \$WORK/ext.plist \
			\"\$APP/Contents/PlugIns/SSHDriveFileProvider.appex\"
		codesign --force --sign \"\$IDENTITY\" --options runtime --timestamp \
			--identifier org.shirls.sshdrive --entitlements \$WORK/agent.plist \"\$APP\"

		echo \"--- codesign --verify --deep --strict\"
		codesign --verify --deep --strict --verbose=2 \"\$APP\"
		echo \"--- spctl --assess\"
		# Unnotarized, this says \"rejected (source=Unnotarized Developer ID)\" and that
		# is the expected pre-notarization state, not a failure of the run.
		spctl --assess --type execute --verbose=4 \"\$APP\" || true
		echo \"--- identities and entitlements\"
		for x in \"\$APP\" \"\$APP/Contents/MacOS/sshdrive\" \
			\"\$APP/Contents/PlugIns/SSHDriveFileProvider.appex\"; do
			echo \"### \$x\"
			codesign -dvv \"\$x\" 2>&1 | grep -E \"^(Identifier|Authority|TeamIdentifier|Timestamp|Runtime)\" || true
			codesign -d --entitlements - --xml \"\$x\" 2>/dev/null | plutil -p - || echo \"(no entitlements)\"
		done
	'"
fi

# ---------------------------------------------------------------- 6. the DMG

if [ "$WHAT" = "all" ] || [ "$WHAT" = "dmg" ]; then
	# Section 10's DMG: the app and a symlink to /Applications, so the window is a
	# drag-and-drop install for anyone who opens it by hand. The cask uses the app
	# directly and never sees the window.
	#
	# UDZO is the compressed read-only format every cask expects; `hdiutil create -srcfolder`
	# on a staging directory is used rather than attaching and detaching a read-write
	# image, because a headless VM has no Finder to lay icons out with and the layout
	# would not survive anyway.
	echo "==> building $DMG_NAME"
	ssh -o BatchMode=yes "$MAC_HOST" "sh -eu -c '
		cd $MAC_DIR
		APP=\"build/Build/Products/Release/SSH Drive.app\"
		STAGE=/tmp/sshdrive-dmg
		rm -rf \$STAGE && mkdir -p \$STAGE
		ditto \"\$APP\" \"\$STAGE/SSH Drive.app\"
		ln -s /Applications \"\$STAGE/Applications\"
		mkdir -p dist
		rm -f \"dist/$DMG_NAME\"
		hdiutil create -volname \"SSH Drive\" -srcfolder \$STAGE \
			-fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet \"dist/$DMG_NAME\"
		rm -rf \$STAGE
		# The disk image is signed too, not only the app inside it. A stapled but unsigned
		# DMG is refused by Gatekeeper on the download path: spctl -a -t open --context
		# context:primary-signature answers \"rejected / source=no usable signature\"
		# whatever the stapled ticket says (measured 2026-09-05). Homebrew does not care -
		# it reads the app out of the image - but a person who double-clicks the download
		# does.
		codesign --force --sign \"$SIGN_IDENTITY\" --timestamp \"dist/$DMG_NAME\"
		ls -l \"dist/$DMG_NAME\"
		hdiutil verify \"dist/$DMG_NAME\" >/dev/null && echo \"hdiutil verify: ok\"
	'"
fi

# ---------------------------------------------------------------- 7-8. notarize

if [ "$WHAT" = "all" ] || [ "$WHAT" = "notarize" ]; then
	echo "==> notarization"

	# Route 1: an App Store Connect API key on the Mac. Preferred, because it is the only
	# one that can be set up without sitting at the machine.
	if [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ] && [ -z "$NOTARY_KEY" ]; then
		# Exactly one ~/Developer/AuthKey_*.p8 on the Mac, or nothing: two keys is an
		# ambiguity the caller has to resolve, not a guess this script should make.
		NOTARY_KEY="$(ssh -o BatchMode=yes "$MAC_HOST" \
			'set -- $HOME/Developer/AuthKey_*.p8; [ $# -eq 1 ] && [ -f "$1" ] && printf %s "$1"' \
			2>/dev/null || true)"
	fi

	NOTARY_ARGS=""
	NOTARY_ROUTE=""
	if [ -n "$NOTARY_KEY" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ]; then
		NOTARY_ARGS="--key '$NOTARY_KEY' --key-id '$NOTARY_KEY_ID' --issuer '$NOTARY_ISSUER'"
		NOTARY_ROUTE="App Store Connect API key $NOTARY_KEY_ID ($NOTARY_KEY)"
	elif ssh -o BatchMode=yes "$MAC_HOST" \
		"xcrun notarytool history --keychain-profile '$NOTARY_PROFILE' >/dev/null 2>&1"; then
		NOTARY_ARGS="--keychain-profile '$NOTARY_PROFILE'"
		NOTARY_ROUTE="notarytool keychain profile $NOTARY_PROFILE"
	fi

	if [ -z "$NOTARY_ARGS" ]; then
		cat <<EOF

	------------------------------------------------------------------
	Notarization skipped: no credentials.

	The DMG is built and signed with the Developer ID identity, and is
	the expected pre-notarization state: Gatekeeper will refuse it on
	another Mac with "Apple could not verify ... free of malware".

	Give it either of these and re-run \`scripts/release.sh notarize\`.

	1. An App Store Connect API key (works headlessly; preferred).
	   Put the .p8 on the Mac ($MAC_HOST), for example at
	   ~/Developer/AuthKey_<KEYID>.p8, and run:

	     NOTARY_KEY_ID=<KEYID> NOTARY_ISSUER=<ISSUER-UUID> \\
	         scripts/release.sh notarize

	   NOTARY_KEY defaults to the single ~/Developer/AuthKey_*.p8 on
	   the Mac; pass it explicitly if there is more than one.

	2. A notarytool keychain profile named "$NOTARY_PROFILE". This one
	   must be created **at the Mac's console**, not over ssh: the
	   command below writes to the login keychain and fails with "User
	   interaction is not allowed" from an ssh session even when the
	   keychain is unlocked.

	     xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
	         --apple-id "<apple-id-email>" \\
	         --team-id "$TEAM_ID" \\
	         --password "<app-specific-password>"
	------------------------------------------------------------------

EOF
		echo "==> stopping cleanly after the DMG. Nothing else failed."
		exit 0
	fi

	echo "==> notarizing with the $NOTARY_ROUTE"
	# The app is submitted and stapled first, then the DMG is rebuilt around the stapled
	# app and notarized in its own right: stapling a DMG staples the image, not the app
	# inside it, so a copy dragged out of an un-rebuilt DMG would carry no ticket.
	ssh -o BatchMode=yes "$MAC_HOST" "sh -eu -c '
		cd $MAC_DIR
		APP=\"build/Build/Products/Release/SSH Drive.app\"
		mkdir -p dist
		rm -f dist/SSH-Drive-app.zip
		/usr/bin/ditto -c -k --keepParent \"\$APP\" dist/SSH-Drive-app.zip
		xcrun notarytool submit dist/SSH-Drive-app.zip $NOTARY_ARGS --wait
		xcrun stapler staple \"\$APP\"
		xcrun stapler validate \"\$APP\"
		rm -f dist/SSH-Drive-app.zip

		STAGE=/tmp/sshdrive-dmg
		rm -rf \$STAGE && mkdir -p \$STAGE
		ditto \"\$APP\" \"\$STAGE/SSH Drive.app\"
		ln -s /Applications \"\$STAGE/Applications\"
		rm -f \"dist/$DMG_NAME\"
		hdiutil create -volname \"SSH Drive\" -srcfolder \$STAGE \
			-fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet \"dist/$DMG_NAME\"
		rm -rf \$STAGE
		codesign --force --sign \"$SIGN_IDENTITY\" --timestamp \"dist/$DMG_NAME\"

		xcrun notarytool submit \"dist/$DMG_NAME\" $NOTARY_ARGS --wait
		xcrun stapler staple \"dist/$DMG_NAME\"
		xcrun stapler validate \"dist/$DMG_NAME\"
		echo \"--- spctl on the stapled app\"
		spctl --assess --type execute --verbose=4 \"\$APP\"
		echo \"--- spctl on the stapled DMG, the way a download is checked\"
		spctl --assess --type open --context context:primary-signature --verbose=4 \"dist/$DMG_NAME\"
	'"
fi

# ---------------------------------------------------------------- the sha256 the cask needs

if [ "$WHAT" != "build" ] && [ "$WHAT" != "install" ]; then
	echo "==> sha256"
	ssh -o BatchMode=yes "$MAC_HOST" "sh -eu -c '
		cd $MAC_DIR
		shasum -a 256 \"dist/$DMG_NAME\" | tee \"dist/$DMG_NAME.sha256\"
		echo
		echo \"packaging/homebrew-tap/Casks/ssh-drive.rb wants:\"
		echo \"  version \\\"$VERSION\\\"\"
		echo \"  sha256 \\\"\$(shasum -a 256 \"dist/$DMG_NAME\" | cut -d\" \" -f1)\\\"\"
	'"
fi

# ---------------------------------------------------------------- install: the upgrade path

INSTALL_NOW=0
if [ "$WHAT" = "install" ]; then
	INSTALL_NOW=1
elif [ "$WHAT" = "all" ] && [ "${RELEASE_INSTALL:-0}" = "1" ]; then
	INSTALL_NOW=1
fi

if [ "$INSTALL_NOW" = "1" ]; then
	# Installs the Release app already built on the Mac (build/Build/Products/Release)
	# into /Applications over ssh, the way the cask's `uninstall`/`postflight` upgrade path
	# does it (docs/spikes/results.md, "the upgrade path"): stop the currently installed
	# agent, kill it outright, replace the bundle, `unregister` + `open -g` to bring the
	# login item back, then print the same lines a person would check by hand.
	echo "==> installing the Release build on $MAC_HOST"
	ssh -o BatchMode=yes "$MAC_HOST" "sh -eu -c '
		cd $MAC_DIR
		APP=\"build/Build/Products/Release/SSH Drive.app\"
		INSTALLED=\"/Applications/SSH Drive.app\"
		if [ -d \"\$INSTALLED\" ]; then
			\"\$INSTALLED/Contents/MacOS/sshdrive\" agent stop || true
		fi
		launchctl kill TERM gui/\$(id -u)/org.shirls.sshdrive.agent || true
		sleep 2
		rm -rf \"\$INSTALLED\"
		ditto \"\$APP\" \"\$INSTALLED\"
		SSHDRIVE_AGENT_ROLE=unregister \"\$INSTALLED/Contents/MacOS/SSH Drive\"
		sleep 2
		open -g \"\$INSTALLED\"
		sleep 6
		echo \"--- launchd state\"
		launchctl print gui/\$(id -u)/org.shirls.sshdrive.agent | grep \"state =\"
		echo \"--- sshdrive doctor (keychain / login item / extension)\"
		\"\$INSTALLED/Contents/MacOS/sshdrive\" doctor | grep -E \"keychain|login item|extension\"
	'"
fi

echo "==> done ($WHAT)"
