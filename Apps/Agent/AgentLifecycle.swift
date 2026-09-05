import Foundation
import Logging
import XPCProtocols

/// The two ways the launchd-started agent is asked to go away that are not
/// `sshdrive agent stop`: a TERM from the Homebrew cask, and the bundle underneath it
/// being replaced by an upgrade (DESIGN.md sections 10, 10.1).
enum AgentLifecycle {

    /// Both, armed once from `main.swift` in the launchd role.
    static func install() {
        installTerminationHandler()
        installBundleWatch()
    }

    // MARK: TERM

    private static var termSource: DispatchSourceSignal?

    /// The cask's `uninstall` stanza is `signal: ["TERM", "org.shirls.sshdrive.agent"]`,
    /// and Homebrew runs it on `brew upgrade` and `brew reinstall` as well as on
    /// `brew uninstall` (section 10). Section 10 also says the agent "exits with status 0
    /// on TERM", and that matters exactly as much as it sounds: the plist sets `KeepAlive`
    /// with `SuccessfulExit` false, and the **default** disposition for SIGTERM is death
    /// by signal, which launchd reads as an unsuccessful exit and restarts at once - from
    /// whatever bundle sits at the path at that moment, which mid-upgrade is the old one
    /// about to be deleted. So TERM is handled, not defaulted: masters down, status 0.
    private static func installTerminationHandler() {
        // The default action has to be disabled explicitly or it races the source.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Log.agent.notice("SIGTERM: shutting down and exiting 0")
            Task {
                await DomainManager.shared.shutdownAll()
                exit(0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                Log.agent.error("shutdown did not finish in 20 s; exiting anyway")
                exit(0)
            }
        }
        source.resume()
        termSource = source
    }

    // MARK: the bundle underneath us

    private static var bundleSource: DispatchSourceFileSystemObject?

    /// Section 10.1: "The agent watches its own executable with a vnode dispatch source;
    /// when it is deleted or replaced, the agent waits until the bundle at its path is
    /// readable, its `Info.plist` parses, and its main executable is a different inode
    /// from the one the agent is running, so it never hands over to a half-copied bundle
    /// and never waits forever on a `brew reinstall` of the same version, and then exits
    /// cleanly, and the next mach lookup starts the new build."
    ///
    /// The "different inode" test is what makes a `brew reinstall` of the same version
    /// terminate: `ditto` of an identical tree still produces a new file, so the inode
    /// moves even when nothing else does. A replacement that never appears - somebody
    /// deleting the app and stopping there - leaves the agent running on the old inode,
    /// which is the right answer: there is nothing to hand over to.
    private static func installBundleWatch() {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        guard let originalInode = inode(of: executable.path) else {
            Log.agent.error("cannot stat my own executable; the upgrade watch is off")
            return
        }
        let descriptor = open(executable.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.agent.error("cannot open my own executable for events; the upgrade watch is off")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.delete, .rename, .write, .revoke],
            queue: .main)
        source.setEventHandler {
            Log.agent.notice("my own executable was replaced; waiting for the new bundle")
            source.cancel()
            waitForReplacement(executable: executable, originalInode: originalInode, attempt: 0)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        bundleSource = source
        Log.agent.info("watching \(executable.path, privacy: .public) for an upgrade")
    }

    /// Polls rather than watching the directory: the window is seconds, the check is three
    /// `stat`s and a plist parse, and a vnode source on a directory that is itself being
    /// replaced is its own problem. Gives up after five minutes and keeps running, which
    /// is the honest answer when no new bundle ever arrives.
    private static func waitForReplacement(executable: URL, originalInode: UInt64, attempt: Int) {
        let bundle = executable
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // SSH Drive.app

        if replacementIsReady(executable: executable, bundle: bundle, originalInode: originalInode) {
            Log.agent.notice("a new bundle is in place; exiting so the next lookup starts it")
            Task {
                await DomainManager.shared.shutdownAll()
                exit(0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) }
            return
        }
        guard attempt < 300 else {
            Log.agent.error("no replacement bundle appeared in five minutes; staying up")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            waitForReplacement(
                executable: executable, originalInode: originalInode, attempt: attempt + 1)
        }
    }

    static func replacementIsReady(executable: URL, bundle: URL, originalInode: UInt64) -> Bool {
        guard let current = inode(of: executable.path), current != originalInode else {
            return false
        }
        guard FileManager.default.isReadableFile(atPath: executable.path) else { return false }
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let parsed = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
            parsed["CFBundleIdentifier"] as? String == SSHDriveIdentifiers.appBundleID
        else { return false }
        return true
    }

    static func inode(of path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }
}
