# The cask alecdwm/homebrew-tap publishes as Casks/sshdrive.rb, which is the file name
# `brew install --cask sshdrive` resolves the token to.
#
# This copy is the source of truth. `scripts/set-version.sh` stamps the `version` line from
# the repository's VERSION file, and .github/workflows/release.yml rewrites `version` and
# `sha256` for the DMG it has just notarized and pushes the result to the tap. The sha256
# here is the last released one, so the file is always a cask Homebrew can install; it is
# not a value anyone edits by hand.

cask "sshdrive" do
  version "0.1.5"
  sha256 "2be8cbc6ece8ee439859a2b90f1a2a4128885f5b5da635c0f63d5edb0d61bd3e"

  url "https://github.com/alecdwm/sshdrive/releases/download/v#{version}/SSH-Drive-#{version}.dmg"
  name "SSH Drive"
  desc "Mount SFTP locations in Finder through the File Provider framework"
  homepage "https://github.com/alecdwm/sshdrive"

  # Minimum macOS 14 (docs/design/platform.md). The symbol form is a minimum in current
  # Homebrew.
  depends_on macos: :sonoma

  app "SSH Drive.app"

  # The CLI is symlinked out of the bundle rather than installed separately. It is a pure
  # XPC client of the agent, so it works through any path, including this symlink; it just
  # cannot be the thing that registers the app (docs/design/packaging.md).
  binary "#{appdir}/SSH Drive.app/Contents/MacOS/sshdrive"

  # Launching the app is what registers the File Provider extension with PlugInKit and the
  # login item through SMAppService, and both must be done from the app's own bundle.
  # macOS then posts its "background item added" notification, with the item already
  # enabled. That notification is the only UI a user sees.
  #
  # The quarantine attribute has to go first, and this is not cosmetic. Homebrew leaves
  # `com.apple.quarantine` on the installed bundle, and LaunchServices registers no plugin
  # of a quarantined bundle that has never been assessed through a user-visible launch -
  # which `open -g` is not. The agent still runs (launchd starts it directly) while
  # `pluginkit -m` prints nothing, `sshdrive doctor` fails "extension registered", and
  # fileproviderd answers `getDomainsForProviderIdentifier((null)) failed: FP -2001
  # Underlying FP -2014`. `pluginkit -a` registers the appex by hand and the next launch
  # wipes it again; stripping the attribute and opening the app registers it durably
  # (measured on macOS 26.6.2, 2026-09-05).
  #
  # Nothing is skipped by removing it. The DMG was assessed on the download path, its
  # notarization ticket is stapled to the app inside it, and `spctl --assess` is run here
  # on the installed copy and logged, so the verification Gatekeeper would do at first
  # open has already been done - by us, before the attribute goes. What the user loses is
  # the one-time "downloaded from the Internet" dialog, which they cannot answer anyway:
  # `open -g` shows it to nobody.
  #
  # The unregister first is not belt and braces. Homebrew deletes the old app and installs
  # the new one, and a login item whose bundle has been deleted and put back keeps its
  # enabled status while launchd can no longer resolve the program: every spawn fails with
  # "Could not find and/or execute program specified by service" on a 10 s retry, for ever,
  # and SMAppService.register() keeps returning success throughout because as far as it is
  # concerned the item is still enabled. Only unregister() clears it (measured 2026-09-04).
  # On a first install there is nothing to unregister and the call is a no-op.
  postflight_steps do
    # Homebrew's declarative steps cannot branch, so the assessment's verdict is printed
    # (print_stdout) rather than summarised; a failed assessment does not abort the install.
    run "/usr/sbin/spctl",
        args: ["--assess", "--type", "execute", "--verbose=4", "{{appdir}}/SSH Drive.app"],
        print_stdout: true,
        must_succeed: false
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/SSH Drive.app"],
        must_succeed: false
    run "SSH Drive.app/Contents/MacOS/SSH Drive",
        base: :appdir,
        env: { "SSHDRIVE_AGENT_ROLE" => "unregister" },
        must_succeed: false
    run "/usr/bin/open",
        args: ["-g", "{{appdir}}/SSH Drive.app"],
        must_succeed: false
  end

  # Homebrew runs `uninstall` on `brew upgrade` and `brew reinstall` as well as on
  # `brew uninstall`, so nothing destructive may live here.
  #
  # The label is `org.shirls.sshdrive.agent`, the agent's launchd label
  # (docs/design/components.md), and not the bundle id: Homebrew matches this string against
  # `launchctl list` output, where only the label ever appears (measured 2026-09-04). The
  # agent handles TERM itself - it shuts every
  # location's ssh master down and exits 0, which is what keeps `KeepAlive` with
  # `SuccessfulExit` false from restarting it out of the bundle being replaced.
  #
  # Deliberately no `launchctl:` here. That directive boots the label out of launchd while
  # SMAppService and the background-task database still consider the login item enabled, so
  # the next launch would register "only if needed", do nothing, and leave the mach service
  # dead until the next login.
  uninstall signal: ["TERM", "org.shirls.sshdrive.agent"]

  # `zap` runs after the app has already been deleted, so nothing here can call
  # `sshdrive remove --all`: by this point there is no CLI and no provider left to call
  # NSFileProviderManager.remove(domain), which is why the caveats and `sshdrive doctor`
  # both say to run it first.
  #
  # `launchctl:` is right here, unlike in `uninstall`, because nothing is coming back.
  # The group container is where config.json, every domain's index.sqlite,
  # capabilities.json and pins.json live (docs/design/components.md).
  #
  # What `zap` cannot reach, and what the caveats therefore have to say:
  #   - the keychain items. They live in the data-protection keychain under access group
  #     RWGDZAYBM8.org.shirls.sshdrive; no file removal reaches them and no cask directive
  #     addresses them. `sshdrive remove --all` is what deletes them, and skipping it
  #     leaves orphaned items that a later install's `add` simply overwrites.
  #   - the File Provider domains, and so the sidebar entries and the cached content under
  #     ~/Library/CloudStorage. Deleting those directories from here would throw away any
  #     upload the system still has pending, so they are left alone; the system drops them
  #     once it finds the provider gone, sometimes not before the next login.
  zap launchctl: "org.shirls.sshdrive.agent",
      trash:     [
        "~/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive",
        "~/Library/Caches/org.shirls.sshdrive",
        "~/Library/HTTPStorages/org.shirls.sshdrive",
        "~/Library/Preferences/org.shirls.sshdrive.plist",
      ]

  caveats <<~EOS
    Add your first location with:

      sshdrive add nas alec@nas.example

    Two prompts to expect, both from macOS and neither avoidable:

      * "Background Items Added" - SSH Drive registered its login agent. It is
        already enabled; the notification is telling you, not asking you.

      * "Allow "SSH Drive" to find devices on local networks?" - the first time
        it connects to a server on your own network, which is the ordinary case
        for a NAS. Answer Allow, or the mount cannot reach it. If you miss it:
        System Settings > Privacy & Security > Local Network.

    Before uninstalling, run:

      sshdrive remove --all

    Homebrew cannot remove File Provider domains or keychain items for you, and
    by the time `brew zap` runs the app that could is already gone.
  EOS
end
