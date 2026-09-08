import Foundation
import XCTest

import AgentCore
import SFTP
import SSHProcess
@testable import ServerModel

/// The server-side scenarios that run over the SFTP **wire**
/// (`docs/testing-architecture.md` section 5). `FakeSFTPServer` speaks the protocol, so
/// `SFTPClient` and `RealSFTPTransport` run here unmodified: every byte of the codec, the
/// pipelining and the extension handling is exercised with no network and no server.
final class SFTPWireScenarios: XCTestCase {

    private func transport(
        _ profile: ServerProfile, seed: (FakeSFTPServer) -> Void = { _ in }
    ) async throws -> (FakeSFTPServer, RealSFTPTransport) {
        let server = FakeSFTPServer(profile: profile)
        seed(server)
        let transport = try await RealSFTPTransport.connect(
            stream: server.makeStream(), root: server.root)
        return (server, transport)
    }

    // MARK: - K12 / N2: the extension fingerprint drives the report

    /// **K12** (`SQ-024`, `SQ-025`): Go `pkg/sftp` advertises **exactly**
    /// `hardlink@openssh.com`, `posix-rename@openssh.com` and `statvfs@openssh.com` and
    /// nothing else, and that fingerprint is what names the server. The bug this defends
    /// is an `upgrade:` line telling the user to replace their SSH server because it has
    /// no `fsync` - which no version of `pkg/sftp` has ever had.
    func testK12_thePkgSFTPFingerprintNamesTheServerAndAsksForNoUpgrade() async throws {
        let (_, tailscale) = try await transport(.tailscaleSSH)
        let advertised = await tailscale.extensionNames
        XCTAssertEqual(
            Set(advertised), Set(SFTPExtensionSets.goPkgSFTP),
            "SQ-024: pkg/sftp advertises exactly three extensions, over the wire")

        let software = ServerSoftware(
            banner: ServerProfile.tailscaleSSH.identificationString,
            advertisedExtensions: advertised)
        XCTAssertEqual(software.isOpenSSH, false, "SQ-024: the fingerprint says not OpenSSH")
        XCTAssertTrue(software.isKnownNotOpenSSH)
        XCTAssertTrue(software.summary.contains("Tailscale"), "SQ-036: the banner names it")

        let flags = await tailscale.extensions
        XCTAssertTrue(flags.contains(.posixRename), "posix-rename is there and is used")
        XCTAssertTrue(flags.contains(.statvfs))
        XCTAssertFalse(flags.contains(.fsync), "SQ-024: no pkg/sftp version has fsync")
        XCTAssertFalse(flags.contains(.limits), "SQ-024: nor limits")
    }

    /// **K12** (`SQ-025`, `SQ-026`): anything carrying `fsync`/`lsetstat`/`limits`/
    /// `expand-path` is OpenSSH, and Alpine's `internal-sftp` offers the same set as the
    /// external server, so nothing in the write protocol degrades there. The owner's own
    /// two servers are the two ends of this: a Debian OpenSSH 9.2 and a Tailscale node.
    func testK12_theOpenSSHFingerprintIsTheSameOnEveryOpenSSHShape() async throws {
        for profile in [ServerProfile.debian, .alpine, .alpineExternalSFTP,
                        .ownerDebian, .openSSH9_6] {
            let (_, sftp) = try await transport(profile)
            let names = await sftp.extensionNames
            let software = ServerSoftware(
                banner: profile.identificationString, advertisedExtensions: names)
            XCTAssertEqual(
                software.isOpenSSH, true,
                "\(profile.name): SQ-025 - fsync/lsetstat/limits/expand-path means OpenSSH")
            let flags = await sftp.extensions
            XCTAssertTrue(flags.contains(.fsync), "\(profile.name): SQ-026")
            XCTAssertTrue(flags.contains(.limits), "\(profile.name): SQ-026")
            XCTAssertTrue(flags.contains(.lsetstat), "\(profile.name): SQ-026")
            XCTAssertTrue(flags.contains(.posixRename), "\(profile.name): SQ-026")
        }
    }

    /// **N2** (`SQ-025`, `SQ-036`): 9.2's and 9.6's extension **sets** are identical -
    /// every name in them predates 9.2 - so the fingerprint cannot tell the two apart and
    /// the identification string is the only thing that can. A report that tried to read a
    /// version out of the extension list would be reading noise.
    func testN2_theNineTwoAndNineSixSetsAreIdenticalAndOnlyTheBannerMoves() async throws {
        XCTAssertEqual(SFTPExtensionSets.openSSH9_2, SFTPExtensionSets.openSSH9_6, "SQ-025")
        let nine2 = ServerSoftware(
            banner: ServerProfile.ownerDebian.identificationString,
            advertisedExtensions: SFTPExtensionSets.openSSH9_2)
        let nine6 = ServerSoftware(
            banner: ServerProfile.openSSH9_6.identificationString,
            advertisedExtensions: SFTPExtensionSets.openSSH9_6)
        XCTAssertEqual(nine2.isOpenSSH, nine6.isOpenSSH)
        XCTAssertNotEqual(nine2.summary, nine6.summary, "SQ-036: the banner is the difference")
    }

    /// **N2** (`SQ-024`): an extension the server did **not** advertise is refused on the
    /// wire, so a client that ignored the fingerprint and called `limits` anyway would be
    /// caught here rather than degrading a feature silently.
    func testN2_anUnadvertisedExtensionIsRefusedOnTheWire() async throws {
        let (_, tailscale) = try await transport(.tailscaleSSH) {
            $0.put("note.txt", contents: Data("hi".utf8))
        }
        let client = tailscale.client
        let limits = await client.limits
        XCTAssertNil(limits, "SQ-024: pkg/sftp has no limits@openssh.com to read")
        // statvfs it does have, and it answers.
        let stats = try await tailscale.statvfs(.root)
        XCTAssertGreaterThan(stats.totalBlocks, 0)
    }

    /// `SQ-027`: `limits@openssh.com` sizes the request, not the window. The measured
    /// values are the ones a client may believe; the pipeline depth of sixteen is its own.
    func testSQ027_theLimitsValuesAreTheMeasuredOnes() async throws {
        let (_, deb) = try await transport(.debian)
        let limits = await deb.client.limits
        XCTAssertEqual(limits?.maxPacketLength, 262_144)
        XCTAssertEqual(limits?.maxReadLength, 261_120)
        XCTAssertEqual(limits?.maxWriteLength, 261_120)
        XCTAssertEqual(limits?.maxOpenHandles, 20_475)
    }

    // MARK: - L1: containment, and the symlink `opendir` follows

    /// **L1** (`SQ-030`): a directory swapped on the server for a link to `/etc` is read
    /// **straight through** by `opendir` - eighty names outside the account's tree land in
    /// the listing. The defence is that every listing re-`lstat`s its own directory before
    /// `readdir`, and this asserts both halves: that the server really does follow the
    /// link, and that the `lstat` that must come first sees a symlink and refuses.
    func testL1_opendirFollowsASymlinkSwappedForEtc() async throws {
        let (server, deb) = try await transport(.debian) { server in
            server.putDirectory("projects")
            server.put("projects/readme.md", contents: Data("mine".utf8))
            // The swap: what was a directory is now a link to /etc.
            server.putDirectory("/etc")
            server.put("/etc/passwd", contents: Data("root:x:0:0".utf8))
            server.put("/etc/shadow", contents: Data("root:!".utf8))
            server.remove("projects")
            server.putSymlink("projects", target: "/etc")
        }
        server.clearRequestLog()

        // The server follows it. This is the measurement, not an assumption.
        let followed = try await deb.readdir(try RelativePath(string: "projects"))
        let names = followed.map { String(decoding: $0.name, as: UTF8.self) }.sorted()
        XCTAssertEqual(names, ["passwd", "shadow"],
                       "SQ-030: opendir followed the link into /etc")

        // The containment rule: the listing's own `lstat` comes first and says symlink,
        // which is what section 9.1 makes every enumeration do before it descends.
        let attributes = try await deb.lstat(try RelativePath(string: "projects"))
        XCTAssertEqual(attributes.type, .symlink,
                       "section 9.1: the re-lstat before readdir is what catches the swap")

        // And the target escapes the root, so `SymlinkPolicy` omits it with a reason -
        // zero rows under the swapped path.
        let target = try await deb.readlink(try RelativePath(string: "projects"))
        let decision = SymlinkPolicy.evaluate(
            target: target, linkDirectory: .root, roots: .init(canonical: server.root))
        guard case let .hide(reason) = decision else {
            return XCTFail("section 9.1: a link out of the root is never shown: \(decision)")
        }
        XCTAssertTrue(reason.contains("outside this location"),
                      "section 5.7: the reason names the escape: \(reason)")
    }

    /// `SQ-031`: `readdir` carries attributes but **no** link target, so every symlink a
    /// listing reports costs a `readlink` before its row can be built.
    func testM2_readdirCarriesNoLinkTargetSoEachLinkCostsAReadlink() async throws {
        let (server, deb) = try await transport(.debian) { server in
            server.put("note.txt", contents: Data("x".utf8))
            server.putSymlink("link-a", target: "note.txt")
            server.putSymlink("link-b", target: "note.txt")
        }
        server.clearRequestLog()
        let entries = try await deb.readdir(.root)
        let links = entries.filter { $0.attributes.type == .symlink }
        XCTAssertEqual(links.count, 2)
        for link in links {
            XCTAssertNil(link.attributes.symlinkTarget,
                         "SQ-031: v3's readdir has nowhere to put a target")
        }
        for link in links {
            let name = String(decoding: link.name, as: UTF8.self)
            _ = try await deb.readlink(try RelativePath(string: name))
        }
        XCTAssertEqual(
            server.requests.filter { $0.hasPrefix("readlink ") }.count, 2,
            "SQ-031: one readlink per link, and no way round it")
    }

    /// `SQ-029`: OpenSSH's `SSH2_FXP_SYMLINK` takes its two paths in the **opposite order
    /// from the draft** - target first, then link path. Getting it round the wrong way
    /// makes a link that points at itself, which no unit test above the wire can see.
    func testSQ029_symlinkArgumentsAreTargetThenLinkPath() async throws {
        let (server, deb) = try await transport(.debian) {
            $0.put("note.txt", contents: Data("x".utf8))
        }
        try await deb.symlink(target: "note.txt", at: try RelativePath(string: "alias"))
        XCTAssertEqual(server.node("alias")?.type, .symlink)
        XCTAssertEqual(server.node("alias")?.target, Data("note.txt".utf8),
                       "SQ-029: the first string on the wire is the target")
        let resolved = try await deb.readlink(try RelativePath(string: "alias"))
        XCTAssertEqual(resolved, "note.txt")
    }

    // MARK: - SQ-028: nine status codes and no errno

    /// `SQ-028`: `ENOSPC`, `EEXIST`, `ENOTEMPTY` and `EXDEV` all arrive as a bare
    /// `FAILURE` with the literal message "Failure", so a second question - `lstat`,
    /// `statvfs`, `readdir` - is the only way to tell them apart.
    func testSQ028_everyErrnoArrivesAsABareFailure() async throws {
        let (server, deb) = try await transport(.debian) { server in
            server.putDirectory("full")
            server.put("full/child.txt", contents: Data("x".utf8))
            server.put("taken.txt", contents: Data("x".utf8))
        }

        // ENOTEMPTY.
        await assertFailure(
            "ENOTEMPTY", try await deb.rmdir(try RelativePath(string: "full")))
        // Only a readdir can say why.
        let children = try await deb.readdir(try RelativePath(string: "full"))
        XCTAssertEqual(children.count, 1, "the second question is what explains the FAILURE")

        // EEXIST, through the exclusive open the upload protocol relies on.
        await assertFailure("EEXIST", try await deb.writeExclusive(
            try RelativePath(string: "taken.txt"), mode: 0o644, window: 4,
            source: { Data() }, progress: { _ in }))

        // ENOSPC. Same bare FAILURE; only statvfs can explain it.
        server.availableBlocks = 0
        await assertFailure("ENOSPC", try await deb.write(
            try RelativePath(string: "new.txt"), contents: Data("hello".utf8), mode: 0o644))
        let stats = try await deb.statvfs(.root)
        XCTAssertTrue(stats.isFull, "SQ-028: statvfs is the only thing that says 'full'")
    }

    private func assertFailure(
        _ label: String, _ expression: @autoclosure () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("\(label): the wire should have answered FAILURE", file: file, line: line)
        } catch let error as SFTPError {
            guard case let .failure(message) = error else {
                return XCTFail("\(label): \(error) is finer than the wire can be",
                               file: file, line: line)
            }
            XCTAssertEqual(message, "Failure",
                           "SQ-028: the literal message, with no errno in it",
                           file: file, line: line)
        } catch {
            XCTFail("\(label): \(error)", file: file, line: line)
        }
    }

    // MARK: - SQ-032 / SQ-033: the helper's deployment

    /// **J8 / J10** (`SQ-032`, `SQ-033`): the helper directory is made 0700, and the two
    /// server behaviours that make that harder than it sounds are both here - `mkdir`'s
    /// attributes go through the **umask**, so the asked-for 0700 lands 0755 and the mode
    /// has to be asserted with a `setstat` afterwards; and a write over a **running**
    /// executable is `ETXTBSY`, which on the wire is the same bare FAILURE as everything
    /// else, so the upload has to go to a temp name and rename.
    func testJ8_theHelperDirectoryIsMade0700ThroughAUmaskAndATempNameRename() async throws {
        let (server, deb) = try await transport(.debian)
        let helperDirectory = try RelativePath(string: ".cache/sshdrive")
        try await deb.mkdir(try RelativePath(string: ".cache"), mode: 0o755)
        try await deb.mkdir(helperDirectory, mode: 0o700)

        // SQ-033: the umask took the group and other bits off the *asked-for* mode, so
        // 0700 asked for landed as 0700 & ~022 - which is still not what a mkdir alone
        // guarantees on a server whose umask is looser.
        XCTAssertEqual(server.mode(of: ".cache/sshdrive"), 0o700 & ~ServerProfile.debian.umask)
        let loose = FakeSFTPServer(profile: ServerProfile.debian.with(umask: 0))
        let looseTransport = try await RealSFTPTransport.connect(
            stream: loose.makeStream(), root: loose.root)
        try await looseTransport.mkdir(try RelativePath(string: "cache"), mode: 0o777)
        XCTAssertEqual(loose.mode(of: "cache"), 0o777,
                       "SQ-033: with no umask the asked-for mode lands whole")

        // So the mode is asserted afterwards, which is the rule the deployment follows.
        try await deb.setstat(helperDirectory, mode: 0o700, mtime: nil)
        XCTAssertEqual(server.mode(of: ".cache/sshdrive"), 0o700,
                       "SQ-033: a setstat is what makes 0700 true")

        // SQ-032: opening the *running* helper for write is ETXTBSY, which the wire
        // carries as the same bare FAILURE as everything else (SQ-028).
        let binary = ".cache/sshdrive/sshdrive-helper"
        server.put(binary, contents: Data("old".utf8), mode: 0o755)
        server.runningExecutables.insert("\(server.root)/\(binary)")
        do {
            _ = try await deb.open(try RelativePath(string: binary), flags: [.write, .truncate])
            XCTFail("SQ-032: a write over a running executable must fail")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .failure("Failure"), "SQ-032 arrives as SQ-028's bare FAILURE")
        }
        XCTAssertEqual(server.contents(of: binary), Data("old".utf8))

        // The temp-name-and-rename path gets past it, which is why the upload uses one.
        let temporary = ".cache/sshdrive/\(HelperDeployment.temporaryName(macID: "abcd1234"))"
        try await deb.write(try RelativePath(string: temporary),
                            contents: Data("new".utf8), mode: 0o755)
        try await deb.posixRename(try RelativePath(string: temporary),
                                  to: try RelativePath(string: binary))
        XCTAssertEqual(server.contents(of: binary), Data("new".utf8))
    }

    /// **J11** (`SQ-069`): the wrapper's `EXIT` trap does not run when it is `SIGKILL`ed -
    /// which is every abrupt client kill, the case the wrapper exists for - so its relay
    /// FIFO is left behind and the next deployment must sweep it with **no age rule**. A
    /// FIFO with no writer is inert, and one left from five seconds ago is as dead as one
    /// left from a week ago.
    func testJ11_theStaleRelayFIFOsAreSweptWithNoAgeRule() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let (server, deb) = try await transport(.debian) { server in
            server.putDirectory(".cache")
            server.putDirectory(".cache/sshdrive", mode: 0o700)
            server.putSpecial(".cache/sshdrive/\(HelperDeployment.relayPrefix)fresh", type: .fifo)
            server.putSpecial(".cache/sshdrive/\(HelperDeployment.relayPrefix)old", type: .fifo)
            server.put(".cache/sshdrive/sshdrive-helper", contents: Data("bin".utf8), mode: 0o755)
        }
        let listing = try await deb.readdir(try RelativePath(string: ".cache/sshdrive"))
        let files = listing.map { entry in
            HelperDeployment.RemoteFile(
                name: String(decoding: entry.name, as: UTF8.self),
                size: entry.attributes.size,
                mtime: entry.attributes.mtime)
        }
        let stale = HelperDeployment.stale(files, keeping: ["sshdrive-helper"], serverNow: now)
        XCTAssertEqual(
            Set(stale), Set(["\(HelperDeployment.relayPrefix)fresh",
                             "\(HelperDeployment.relayPrefix)old"]),
            "SQ-069: both FIFOs go, whatever their age; the helper binary stays")
        XCTAssertFalse(stale.contains("sshdrive-helper"))

        for name in stale {
            try await deb.remove(try RelativePath(string: ".cache/sshdrive/\(name)"))
        }
        XCTAssertEqual(server.names(in: ".cache/sshdrive"), ["sshdrive-helper"])
    }

    /// `SQ-034`: a server's plain `rename` may refuse an existing name or may overwrite
    /// it, and the probe is what decides. `posix-rename@openssh.com` always overwrites,
    /// which is why the write protocol picks between the two rather than assuming either.
    func testD7_renameRefusesOrOverwritesByProfileAndPosixRenameAlwaysOverwrites() async throws {
        for profile in [ServerProfile.alpine, ServerProfile.debian.with(renameOverwrites: true)] {
            let (server, sftp) = try await transport(profile) { server in
                server.put("a.txt", contents: Data("A".utf8))
                server.put("b.txt", contents: Data("B".utf8))
            }
            let source = try RelativePath(string: "a.txt")
            let destination = try RelativePath(string: "b.txt")
            if profile.renameOverwrites {
                try await sftp.rename(source, to: destination)
                XCTAssertEqual(server.contents(of: "b.txt"), Data("A".utf8))
            } else {
                await assertFailure("EEXIST via rename",
                                    try await sftp.rename(source, to: destination))
                XCTAssertEqual(server.contents(of: "b.txt"), Data("B".utf8),
                               "SQ-034: a refusing server left the incumbent alone")
                // posix-rename is the one that always overwrites (section 5.5).
                try await sftp.posixRename(source, to: destination)
                XCTAssertEqual(server.contents(of: "b.txt"), Data("A".utf8))
            }
        }
    }
}
