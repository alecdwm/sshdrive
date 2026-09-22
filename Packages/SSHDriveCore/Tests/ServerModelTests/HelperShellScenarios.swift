import Foundation
import XCTest

import AgentCore
import Logging
import SFTP
import SSHProcess
@testable import ServerModel

/// Suite J's tier 2 half: the helper binary on the server, and what an exec channel's
/// death looks like from here (`docs/design/testing.md` sections 4.2 and 5).
///
/// Three of these run the **real** `sshdrive-helper` - the Rust crate in `helper/`, which
/// `cargo` builds on this box - because the claims are about what that binary does with
/// its own bytes and about what the kernel does with a running executable, and neither is
/// a claim a stub could answer. A tree with no built helper skips **by name** and says
/// which command builds one.
final class HelperShellScenarios: XCTestCase {

    private var servers: [FakeSSHD] = []
    private var stubs: [FakeSSH] = []
    private var masters: [SSHMaster] = []
    private var runningChildren: [SpawnedProcess] = []

    override func tearDown() async throws {
        for child in runningChildren {
            kill(child.pid, SIGKILL)
            _ = Spawn.wait(pid: child.pid)
        }
        runningChildren = []
        for master in masters { await master.shutdown() }
        masters = []
        for stub in stubs { stub.uninstall() }
        stubs = []
        for server in servers { server.shutdown() }
        servers = []
    }

    private func sshd(_ profile: ServerProfile) throws -> FakeSSHD {
        if let reason = FakeSSHD.unavailabilityReason(for: profile) {
            throw XCTSkip("\(profile.name): \(reason)")
        }
        let server = try FakeSSHD(profile: profile)
        servers.append(server)
        return server
    }

    /// The records a script prints, NUL-separated - `SweepScenarios`' shape, so a claim
    /// about a remote command is read back exactly the way the sweep's is.
    private func records(
        _ server: FakeSSHD, body: String, arguments: [String] = [], expecting: Int,
        timeout: TimeInterval = 30
    ) async throws -> [String] {
        let script = RemoteScript(arguments: arguments, body: body)
        let channel = try await server.openExecChannel(script: script, readinessDeadline: timeout)
        defer { channel.close() }
        let payload = try await channel.readPayload(until: expecting, timeout: timeout)
        return payload.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - The real helper binary

    /// The repository root, from this file.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ServerModelTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SSHDriveCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repo root
    }

    /// A built `sshdrive-helper` this box can actually execute, or nil.
    ///
    /// The static musl build is preferred where the architecture matches, because that is
    /// the shape the app ships and the one `SQ-066` is about: **one static binary that
    /// runs on both a glibc and a musl userland**, reporting the same self-computed digest
    /// on each. Running it here, on a glibc box, is one half of that row; the Alpine half
    /// was measured on `alp` and cannot be staged on this machine.
    private static func helperBinary() -> URL? {
        var relative: [String] = []
        #if os(Linux) && arch(x86_64)
            relative.append("helper/target/x86_64-unknown-linux-musl/release/sshdrive-helper")
        #elseif os(Linux) && arch(arm64)
            relative.append("helper/target/aarch64-unknown-linux-musl/release/sshdrive-helper")
        #elseif os(macOS) && arch(arm64)
            relative.append("helper/target/aarch64-apple-darwin/release/sshdrive-helper")
        #endif
        relative += ["helper/target/release/sshdrive-helper", "helper/target/debug/sshdrive-helper"]
        for path in relative {
            let url = repositoryRoot.appendingPathComponent(path)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            // Executable on this box is the claim, so it is tested by running it: a
            // cross-built binary for another architecture is a file, not a helper.
            guard let result = try? Spawn.capture(
                executable: url.path, argv: [url.path, "--version"],
                environment: ProcessInfo.processInfo.environment, timeout: 20),
                result.exit.isClean,
                HelperDeployment.parseVersionLine(
                    String(decoding: result.stdout, as: UTF8.self)) != nil
            else { continue }
            return url
        }
        return nil
    }

    private func helperBinaryOrSkip() throws -> URL {
        guard let url = Self.helperBinary() else {
            throw XCTSkip(
                "no `sshdrive-helper` this box can run under `helper/target/` - build one with "
                    + "`cargo build --release` in `helper/`, or `scripts/build-helper.sh`; "
                    + "the row is skipped, not faked")
        }
        return url
    }

    /// Flips one byte **in place**, leaving the size and the inode exactly as they were:
    /// what a corrupted binary on a server really looks like, and the case a size check
    /// cannot see (`SQ-067`). The last byte is chosen because an ELF's tail is section
    /// names and debug data, so the file still runs and can still be asked what it is.
    @discardableResult
    private func corruptInPlace(_ url: URL) throws -> (size: Int64, inode: UInt64) {
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (before[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(size, 0)
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: UInt64(size - 1))
        let last = try handle.read(upToCount: 1) ?? Data([0])
        try handle.seek(toOffset: UInt64(size - 1))
        try handle.write(contentsOf: Data([last[0] ^ 0xFF]))
        try handle.close()
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((after[.size] as? NSNumber)?.int64Value, size,
                       "SQ-067: the corruption is the same size - that is the whole point")
        XCTAssertEqual(after[.systemFileNumber] as? NSNumber,
                       before[.systemFileNumber] as? NSNumber,
                       "the same inode: written *in place*, not replaced")
        return (size, (after[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    /// The three records the deployment's verification asks a server for: what the binary
    /// says about itself, what `sha256sum` says about it, and whether the server has a
    /// checksum tool at all.
    private struct Verification {
        var versionLine: String
        var sha256: String
        var hasAChecksumTool: Bool
    }

    private func verify(
        _ server: FakeSSHD, binary: String, withoutTools emptyPATH: String
    ) async throws -> Verification {
        let body = """
            __v=$("$1" --version 2>/dev/null | head -1)
            printf '%s\\000' "$__v"
            __s=$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)
            printf '%s\\000' "$__s"
            __t=$( PATH=$2 ; command -v sha256sum >/dev/null 2>&1 && echo yes || echo no )
            printf '%s\\000' "$__t"
            """
        let out = try await records(server, body: body, arguments: [binary, emptyPATH], expecting: 3)
        XCTAssertGreaterThanOrEqual(out.count, 3, "the verification script printed \(out)")
        return Verification(versionLine: out[0], sha256: out[1], hasAChecksumTool: out[2] == "yes")
    }

    // MARK: - J9: `--version` digests its own executable

    /// The check as it would be if docs/design/change-detection.md's fallback were read as
    /// "size" and not as "size **plus running it with `--version`**". A copy lives here
    /// and nowhere in `Sources/`, exactly as `HeartbeatScenarios` keeps a copy of the
    /// legacy wrapper (gotcha 100): a rule is only worth something if the reading it
    /// rules out really does fail (`SQ-067`).
    private func legacyVerdictBySizeAlone(
        binary: HelperManifest.Binary, evidence: HelperDeployment.RemoteEvidence
    ) -> HelperDeployment.Verdict {
        guard let size = evidence.size else { return .upload(reason: "not there yet") }
        return size == binary.size ? .keep : .upload(reason: "wrong size")
    }

    /// **J9** (`SQ-066`, `SQ-067`): the helper prints the SHA-256 of **its own executable**
    /// for `--version`, computed at startup - because a hash the build embedded in the
    /// file could not be the hash of that file. So a binary corrupted **in place**, at
    /// exactly the same size, is caught by the `--version` path just as it is by
    /// `sha256sum`, which is what makes the checksum-less server's fallback the good
    /// path's check rather than a weaker one (docs/design/change-detection.md tier 2,
    /// docs/design/security.md).
    ///
    /// Run against the real Rust helper through a real shell: the digest is the binary's
    /// own claim about its own bytes, and no stub can make that claim.
    func testJ9_theVersionLineDigestsItsOwnExecutableAndCatchesASameSizeCorruption() async throws {
        let source = try helperBinaryOrSkip()
        let server = try sshd(.debian)
        let emptyPATH = try server.emptyToolDirectory()

        // The helper as deployed: its own directory, 0700, and the name
        // docs/design/change-detection.md gives it on the server.
        let directory = server.directory.appendingPathComponent("cache/sshdrive")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shipped = try XCTUnwrap(
            HelperDeployment.parseVersionLine(
                String(decoding: try Spawn.capture(
                    executable: source.path, argv: [source.path, "--version"],
                    environment: ProcessInfo.processInfo.environment, timeout: 20).stdout,
                    as: UTF8.self)),
            "the built helper answered `--version` with something we do not parse")
        let name = "sshdrive-helper-\(shipped.version)-\(shipped.target.os)-\(shipped.target.arch)"
        let deployed = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: deployed)
        try FileManager.default.copyItem(at: source, to: deployed)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: deployed.path)
        let size = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: deployed.path)[.size]
                as? NSNumber)?.int64Value)

        // What the app ships: the manifest CI wrote, hashing the file it built.
        let good = try await verify(server, binary: deployed.path, withoutTools: emptyPATH)
        let goodLine = try XCTUnwrap(
            HelperDeployment.parseVersionLine(good.versionLine),
            "SQ-067: `--version` must be one parseable line: \(good.versionLine)")
        XCTAssertEqual(
            goodLine.digest, good.sha256,
            "SQ-067: the binary's own digest is the same claim `sha256sum` makes about it")
        XCTAssertEqual(good.sha256.count, 64, "the ordinary PATH has a checksum tool")
        XCTAssertFalse(
            good.hasAChecksumTool,
            "SQ-067: with no tools on `PATH` the server has neither `sha256sum` nor "
                + "`shasum`, which is the world the `--version` fallback exists for")
        let manifest = HelperManifest(
            version: goodLine.version,
            binaries: [.init(os: goodLine.target.os, arch: goodLine.target.arch, file: name,
                             sha256: good.sha256, size: size)])
        let binary = try XCTUnwrap(manifest.binaries.first)

        // SQ-066: `uname -sm` carries no libc, and the manifest has no libc column - one
        // entry answers a glibc server and a musl one, which is the whole row. This
        // static build is running on a glibc box right now.
        XCTAssertEqual(manifest.binary(forUname: "Linux \(goodLine.target.arch)")?.sha256,
                       binary.sha256)
        XCTAssertEqual(manifest.binary(forUname: "Linux x86_64")?.file,
                       manifest.binary(forUname: "Linux amd64")?.file,
                       "SQ-066: the same file whatever the userland spells it")

        // Nothing is wrong yet: both routes say keep.
        XCTAssertEqual(
            HelperDeployment.verdict(
                for: binary, evidence: .init(size: size, sha256: good.sha256)),
            .keep, "the good path: `sha256sum` agrees")
        XCTAssertEqual(
            HelperDeployment.verdict(
                for: binary,
                evidence: .init(size: size, reportedDigest: goodLine.digest,
                                reportedVersion: goodLine.version)),
            .keep, "SQ-067: and so does the fallback, on its own")

        // The corruption: one byte, in place, same size, same inode.
        let corrupted = try corruptInPlace(deployed)
        XCTAssertEqual(corrupted.size, size)
        let bad = try await verify(server, binary: deployed.path, withoutTools: emptyPATH)
        let badLine = try XCTUnwrap(
            HelperDeployment.parseVersionLine(bad.versionLine),
            "SQ-067: the corrupted binary still runs and still answers: \(bad.versionLine)")

        XCTAssertNotEqual(bad.sha256, good.sha256, "sha256sum sees it")
        XCTAssertNotEqual(badLine.digest, goodLine.digest,
                          "SQ-067: and so does the binary's own `--version`")
        XCTAssertEqual(badLine.digest, bad.sha256,
                       "SQ-067: the two agree about the corrupted bytes as well")
        XCTAssertEqual(
            HelperDeployment.verdict(
                for: binary, evidence: .init(size: size, sha256: bad.sha256)),
            .upload(reason: "the copy on the server does not match this build"))
        XCTAssertEqual(
            HelperDeployment.verdict(
                for: binary, evidence: .init(size: size, reportedDigest: badLine.digest)),
            .upload(reason: "the copy on the server does not match this build"),
            "SQ-067: the checksum-less server catches it too, which is the whole point")

        // A server with neither tool and a binary that will not answer: size is all there
        // is, and docs/design/change-detection.md replaces rather than runs it.
        XCTAssertEqual(
            HelperDeployment.verdict(for: binary, evidence: .init(size: size)),
            .upload(reason: "the server could not verify the helper's contents"))

        // The bite-proof: the size-only reading keeps the corrupted binary and runs it.
        XCTAssertEqual(
            legacyVerdictBySizeAlone(binary: binary, evidence: .init(size: size)),
            .keep,
            "SQ-067: a size check cannot see a same-size corruption - which is why the "
                + "fallback runs the binary rather than measuring it")

        // And the second bite-proof, for the other half of SQ-067: a `--version` that
        // prints a digest the *build* baked in says exactly the same thing after the
        // corruption as before it, so the fallback would keep a corrupted helper.
        let staleTeller = server.directory.appendingPathComponent("baked-in-version")
        // The padding is the last line, so the byte flipped in place lands in a comment:
        // the file changes, the program does not.
        let bakedIn = """
            #!/bin/sh
            printf '%s\\n' 'sshdrive-helper 0.1.0 linux/x86_64 sha256=\(good.sha256)'
            # a hash the build embedded, which cannot be the hash of this file: \(String(repeating: "x", count: 64))
            """
        let bakedSize = Int64(bakedIn.utf8.count)
        try bakedIn.write(to: staleTeller, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: staleTeller.path)
        let bakedBefore = try await verify(
            server, binary: staleTeller.path, withoutTools: emptyPATH)
        try corruptInPlace(staleTeller)   // one byte of the padding comment
        let bakedAfter = try await verify(
            server, binary: staleTeller.path, withoutTools: emptyPATH)
        XCTAssertEqual(
            bakedAfter.versionLine, bakedBefore.versionLine,
            "SQ-067: a baked-in hash still names the bytes the build had, not the bytes there now")
        XCTAssertNotEqual(bakedAfter.sha256, bakedBefore.sha256, "the file really did change")
        XCTAssertEqual(
            HelperDeployment.verdict(
                for: .init(os: "linux", arch: "x86_64", file: "x", sha256: good.sha256,
                           size: bakedSize),
                evidence: .init(
                    size: bakedSize,
                    reportedDigest: try XCTUnwrap(
                        HelperDeployment.parseVersionLine(bakedAfter.versionLine)).digest)),
            .keep,
            "SQ-067: which a verification would have believed - the digest has to be "
                + "computed by the binary at startup, and the real helper's is")
    }

    // MARK: - J10: writing over a running helper

    /// **J10** (`SQ-032`, `SQ-028`): a write over a **running** executable fails
    /// `ETXTBSY`, so an upload never writes over the file it is replacing. It goes to a
    /// temp name and is renamed into place (docs/design/writes.md's protocol,
    /// docs/design/change-detection.md's rule),
    /// which the kernel allows while the old inode stays with the process still running
    /// from it.
    ///
    /// Both halves are run for real: the kernel's refusal on this box's own filesystem,
    /// with the real helper running from the file; and the same refusal over the SFTP
    /// wire, where `ETXTBSY` has no status code of its own and arrives as the bare
    /// `FAILURE` of `SQ-028` - which is exactly why the client cannot handle it by
    /// recognising it, and must not produce it in the first place.
    func testJ10_writingOverARunningHelperIsETXTBSYAndTheTempNameRenameGetsPastIt() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-j10-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The file the "server" is running the helper from. The real binary where the
        // tree has one - the row is about our own helper - and any other real executable
        // otherwise, because `ETXTBSY` is the kernel's rule about a running ELF and not
        // about ours.
        let installed = directory.appendingPathComponent("sshdrive-helper-0.1.0-linux-x86_64")
        var argumentsAfterPath: [String] = []
        let sourceName: String
        if let helper = Self.helperBinary() {
            try FileManager.default.copyItem(at: helper, to: installed)
            argumentsAfterPath = ["watch", "--json", "--root", directory.path]
            sourceName = "the built sshdrive-helper"
        } else {
            let stand = ["/usr/bin/sleep", "/bin/sleep"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            }
            guard let stand else {
                throw XCTSkip("no `sleep` and no built helper on this box; skipped, not faked")
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: stand), to: installed)
            argumentsAfterPath = ["120"]
            sourceName = "a copy of \(stand) (no helper built; ETXTBSY is the kernel's rule, not ours)"
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: installed.path)
        let originalBytes = try Data(contentsOf: installed)

        let running = try Spawn.run(
            executable: installed.path, argv: [installed.path] + argumentsAfterPath,
            environment: ProcessInfo.processInfo.environment,
            wantsStdout: true, stdinFromDevNull: true, newProcessGroup: true)
        runningChildren.append(running)
        // It is running before anything is claimed about writing over it.
        var alive = false
        for _ in 0 ..< 40 {
            if Spawn.poll(pid: running.pid) == nil { alive = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(alive, "\(sourceName) is running from \(installed.lastPathComponent)")

        // The old logic, run for real: write straight over the path.
        errno = 0
        let descriptor = open(installed.path, O_WRONLY | O_TRUNC)
        let failure = errno
        if descriptor >= 0 {
            close(descriptor)
            throw XCTSkip(
                "this platform allowed a write over a running executable (no ETXTBSY), so "
                    + "SQ-032 cannot be staged here; skipped rather than passed for the wrong reason")
        }
        XCTAssertEqual(
            failure, ETXTBSY,
            "SQ-032: writing over a running executable is `Text file busy`, not a permission error")
        XCTAssertEqual(try Data(contentsOf: installed), originalBytes,
                       "and the incumbent bytes were left alone")

        // The path the deployment takes instead: a temp name of docs/design/writes.md's
        // shape, then a rename into place. The process keeps the inode it is running from.
        let temporary = directory.appendingPathComponent(
            HelperDeployment.temporaryName(macID: "abcd1234"))
        let replacement = originalBytes + Data(repeating: 0x0A, count: 1)
        try replacement.write(to: temporary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        XCTAssertTrue(temporary.lastPathComponent.hasPrefix(".sshdrive-upload-"),
                      "the same ignore rule as every other half-written upload (docs/design/writes.md)")
        XCTAssertEqual(rename(temporary.path, installed.path), 0,
                       "SQ-032: the rename is what the kernel allows: errno \(errno)")
        XCTAssertEqual(try Data(contentsOf: installed), replacement)
        XCTAssertNil(Spawn.poll(pid: running.pid),
                     "SQ-032: the old inode stays with the process still running from it")

        // The same refusal over the wire, where it has no code of its own.
        let sftpServer = FakeSFTPServer(profile: .debian)
        sftpServer.putDirectory(".cache")
        sftpServer.putDirectory(".cache/sshdrive", mode: 0o700)
        let remote = ".cache/sshdrive/sshdrive-helper-0.1.0-linux-x86_64"
        sftpServer.put(remote, contents: Data("old".utf8), mode: 0o755)
        sftpServer.runningExecutables.insert("\(sftpServer.root)/\(remote)")
        let transport = try await RealSFTPTransport.connect(
            stream: sftpServer.makeStream(), root: sftpServer.root)
        do {
            _ = try await transport.open(try RelativePath(string: remote), flags: [.write, .truncate])
            XCTFail("SQ-032: the server must refuse a write over the running helper")
        } catch let error as SFTPError {
            XCTAssertEqual(
                error, .failure("Failure"),
                "SQ-028: ETXTBSY has no status code of its own - the client cannot even name it")
        }
        XCTAssertEqual(sftpServer.contents(of: remote), Data("old".utf8))

        let remoteTemporary = ".cache/sshdrive/\(HelperDeployment.temporaryName(macID: "abcd1234"))"
        try await transport.write(try RelativePath(string: remoteTemporary),
                                  contents: Data("new".utf8), mode: 0o755)
        try await transport.posixRename(try RelativePath(string: remoteTemporary),
                                        to: try RelativePath(string: remote))
        XCTAssertEqual(sftpServer.contents(of: remote), Data("new".utf8),
                       "SQ-032: temp name and rename is the only upload there is")
    }

    // MARK: - J13: the exec channel dies 255 with no stderr

    /// The classifier as it would be if the channel's own history were not an input: any
    /// 255 from a mux client is the mux client's error. A copy lives here and nowhere in
    /// `Sources/`, so what the rule buys is visible.
    private func legacyClassifyIgnoringWhetherTheChannelOpened(
        exitStatus: Int32, stderr: String
    ) -> SSHExitClassification {
        SSHExitClassifier.classify(
            role: .muxClient, exitStatus: exitStatus, stderr: stderr, channelOpened: false)
    }

    private func fakeSSH(_ profile: ServerProfile) throws -> FakeSSH {
        if let reason = FakeSSHD.unavailabilityReason(for: profile) {
            throw XCTSkip("\(profile.name): \(reason)")
        }
        let stub = try FakeSSH(profile: profile)
        stub.install()
        stubs.append(stub)
        return stub
    }

    private func master(_ profile: ServerProfile, stub: FakeSSH) -> SSHMaster {
        var environment = ProcessInfo.processInfo.environment
        environment["USER"] = "alec"
        let master = SSHMaster(configuration: .init(
            locationID: UUID().uuidString,
            target: SSHTarget(host: profile.name.replacingOccurrences(of: "/", with: "-"),
                              user: "alec", port: profile.port),
            environment: environment,
            authenticationDeadline: 15,
            controlPath: stub.directory.appendingPathComponent("ctl").path))
        masters.append(master)
        return master
    }

    /// **J13** (`SQ-011`, `SQ-035`): a remote command killed by a signal makes `ssh` exit
    /// **255 with nothing on stderr** - the same exit code a mux client that could not get
    /// a channel produces, and the same one a dead master produces. The two mean opposite
    /// things: one is the wrapper on the server dying with a healthy connection under it,
    /// the other is the connection itself. What tells them apart is that this channel had
    /// **opened**, and nothing else can.
    ///
    /// Run end to end: `SSHMaster` spawns the stub exactly as it spawns `/usr/bin/ssh`, a
    /// real shell on the far end kills itself with a signal, and the exit is read and
    /// classified by the shipping code.
    func testJ13_aSignalKilledRemoteCommandIs255WithNoStderrAndIsTheWrappersDeath() async throws {
        let stub = try fakeSSH(.tailscaleSSH)
        let master = self.master(.tailscaleSSH, stub: stub)
        try await master.connect()

        // The signal is `SIGKILL`, and the choice is not arbitrary: it is the one signal
        // that can be neither caught, blocked nor **ignored**, so it kills a real shell
        // identically on every box. The two that a process could merely inherit as
        // harmless are both unusable here - `SIGPIPE` is inherited ignored from this
        // process (Foundation ignores it), and on Darwin `SIGINT` is inherited ignored
        // too, because SwiftPM ignores it while a test child runs, so `kill -INT $$`
        // leaves the shell alive and the channel exits 0.
        //
        // Every *other* signal is unusable for a different reason: the stub's own shell
        // would write a job report - `Killed`, `Terminated` - onto the channel's stderr,
        // an artifact of this harness and a byte no sshd sends. That is suppressed at
        // its source (`SQ-084`, `FakeSSH.run_session`), so the signal can be chosen for
        // what it proves rather than for what it does not print. What the row is about is
        // what `ssh` then makes of the death, and that is the same for any signal: 255,
        // and nothing on stderr.
        let script = RemoteScript(body: "printf '%s\\000' ready; kill -KILL $$")
        let channel = try await master.openExecChannel(script: script, readinessDeadline: 20)
        defer { channel.close() }
        let payload = try await channel.stream.read(
            upTo: 4096, deadline: Date().addingTimeInterval(10))
        XCTAssertEqual(String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self),
                       "ready", "the channel opened, which is the fact the rule turns on")

        // The capture is installed *around* the call that logs, so what the product wrote
        // is what is read back. `reportDeath` is also the only reaper: a `waitpid` from
        // the test would take the status the report needs with it.
        let capture = LogCapture()
        capture.install()
        let death = await channel.reportDeath(reason: "the helper's stream ended", grace: 10)
        capture.uninstall()
        Self.assertTheLogCarriesTheDeath(capture, containing: ["255"])

        let exit = try XCTUnwrap(death.exit, "the mux client must have exited")
        XCTAssertEqual(exit.status, 255,
                       "SQ-011: a signal-killed remote command comes back as ssh's own 255")
        XCTAssertNil(exit.signal, "SQ-011: `ssh` itself was not signalled; it exited")
        XCTAssertEqual(
            death.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "",
            "SQ-011: and it printed nothing at all, which is what makes it indistinguishable "
                + "from a mux-client error by the exit code alone")

        XCTAssertTrue(death.isSignalKilledRemoteCommand,
                      "SQ-011: 255, no signal on `ssh`, nothing on stderr")
        XCTAssertEqual(death.classification, .transient,
                       "SQ-011: the wrapper died; the connection under it did not")
        XCTAssertNotEqual(death.classification, .masterLost,
                          "SQ-011: and this is never read as the mux client's own failure")
        XCTAssertFalse(death.classification.stopsReconnection)
        XCTAssertTrue(death.summary.contains("the channel exited 255"),
                      "the status is in the line: \(death.summary)")
        XCTAssertTrue(death.summary.contains("nothing on stderr"),
                      "and so is the fact that there was nothing to say: \(death.summary)")

        // The bite-proof: the same exit read without the channel's history is master lost,
        // which drops the master and rebuilds the whole connection - once a cycle, for a
        // server that is perfectly healthy.
        XCTAssertEqual(
            legacyClassifyIgnoringWhetherTheChannelOpened(exitStatus: 255, stderr: ""),
            .masterLost,
            "SQ-011: which is what the channel-opened input is worth")
        // And the reading that *is* right for a channel that never opened, unchanged.
        XCTAssertEqual(
            SSHExitClassifier.classify(
                role: .muxClient, exitStatus: 255,
                stderr: "Control socket connect(/x): No such file or directory\r\n",
                channelOpened: false),
            .masterLost, "SQ-079: a channel that never opened is still master lost")
    }

    /// **J13** (`SQ-011`): the other half of the same rule - a remote command that dies
    /// **with** something to say. The exit status and the stderr both reach the log,
    /// because "an outage that is silently swallowed" is the failure this defends
    /// against: a helper that dies with no status, no signal and no stderr leaves only
    /// one sentence in the log and no way to say why.
    func testJ13_theDeathIsReportedWithItsExitStatusAndItsStderrInTheLine() async throws {
        let stub = try fakeSSH(.debian)
        let master = self.master(.debian, stub: stub)
        try await master.connect()

        let script = RemoteScript(
            body: "printf '%s\\000' ready; echo 'helper: inotify_add_watch: No space left' >&2; exit 3")
        let channel = try await master.openExecChannel(script: script, readinessDeadline: 20)
        defer { channel.close() }
        _ = try await channel.stream.read(upTo: 4096, deadline: Date().addingTimeInterval(10))

        let capture = LogCapture()
        capture.install()
        let death = await channel.reportDeath(reason: "the helper's stream ended", grace: 10)
        capture.uninstall()
        Self.assertTheLogCarriesTheDeath(capture, containing: ["3", "inotify_add_watch"])

        XCTAssertEqual(try XCTUnwrap(death.exit).status, 3,
                       "the remote command's own status travels through ssh")
        XCTAssertFalse(death.isSignalKilledRemoteCommand,
                       "SQ-011 is the *silent* shape; this one spoke")
        XCTAssertTrue(death.summary.contains("the channel exited 3"), death.summary)
        XCTAssertTrue(death.summary.contains("inotify_add_watch"),
                      "the stderr is in the line, which is the whole point: \(death.summary)")
        XCTAssertEqual(death.classification, .transient)
    }

    /// The log assertion both `J13` rows share.
    ///
    /// On Darwin `Log.*` is `os.Logger` and its lines go to the unified log, which no
    /// capture can read back in process - `sshdrive logs`' predicates must keep matching,
    /// so the product does not log through the portable backend there. The row says so and
    /// skips the assertion rather than pretending; Linux is the gate, exactly as it is for
    /// `J1`'s bite-proof.
    private static func assertTheLogCarriesTheDeath(
        _ capture: LogCapture, containing needles: [String]
    ) {
        #if canImport(os)
            print("J13: the log assertion is Linux-only - `Log.ssh` is os.Logger here and "
                + "writes to the unified log, which a LogCapture cannot read back")
        #else
            let lines = capture.messages(subsystem: Log.subsystem,
                                         category: Log.Category.ssh, level: .error)
            XCTAssertFalse(lines.isEmpty, "the death must be reported, not swallowed")
            let line = lines.joined(separator: "\n")
            XCTAssertTrue(line.contains("the exec channel died"), line)
            for needle in needles {
                XCTAssertTrue(line.contains(needle),
                              "the log line must carry `\(needle)`: \(line)")
            }
        #endif
    }

}
