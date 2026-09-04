import Foundation
import AgentCore
import Config
import Logging
import SFTP
import SSHProcess

/// Puts the remote helper on the server, checks it is ours, and takes it away again
/// (DESIGN.md section 6.4 tier 2, steps 1 and 2; section 9's last bullet).
///
/// Everything that is a *decision* lives in `AgentCore` as `HelperDeployment` and
/// `HelperManifest` and is unit-tested there; this is the I/O around it - one exec channel
/// for the questions only a shell can answer, and the SFTP metadata channel for the bytes.
///
/// Deployment failures are never fatal: "the location silently continues at the next tier
/// and the status report says why the helper is not running" (section 6.4).
enum HelperDeployer {

    /// Where the app keeps the binaries and the manifest CI wrote (sections 3, 10.1).
    static var resourcesDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("helper", isDirectory: true)
    }

    /// The manifest, or nil in a build with no helpers embedded - a `swift test` run, or a
    /// developer build made before `scripts/mac-build.sh` found a locally built binary.
    /// That is not an error either: the location runs at the sweep tier and says so.
    static func manifest() -> HelperManifest? {
        guard let directory = resourcesDirectory else { return nil }
        let url = directory.appendingPathComponent(HelperManifest.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? HelperManifest.decode(data)
    }

    struct Deployment: Sendable {
        /// The absolute path the helper runs from, exactly as `status` prints it.
        var path: String
        var version: String
        var directory: String
        /// True when this connection actually uploaded, for the runbook and the log.
        var uploaded: Bool
        /// What verified it: "sha256sum", "shasum", "--version" or "size".
        var verifiedBy: String
        var removedStale: [String]
    }

    enum Failure: Error, LocalizedError {
        /// The reason `status` prints on the change-detection line (section 8.1).
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            }
        }
    }

    /// Section 6.4's steps 1 and 2, on one exec channel and the metadata SFTP channel.
    static func ensureDeployed(
        connection: SSHBackedTransport,
        locationID: String
    ) async throws -> Deployment {
        let probe = connection.probe
        guard probe.hasShellAccess else {
            throw Failure.unavailable("the account has no shell access")
        }
        guard connection.budget.allowsPersistentExecChannel else {
            throw Failure.unavailable(
                "the server will not give the helper a channel of its own (MaxSessions \(connection.budget.concurrentChannels))")
        }
        guard !probe.cacheDirectory.isEmpty else {
            throw Failure.unavailable(
                probe.cacheNote.isEmpty ? "no writable directory for helper" : probe.cacheNote)
        }
        guard let directory = HelperDirectory(absolute: probe.cacheDirectory) else {
            throw Failure.unavailable("the helper directory \(probe.cacheDirectory) is not usable")
        }
        guard let manifest = manifest() else {
            throw Failure.unavailable("this build ships no helper binaries")
        }
        guard let binary = manifest.binary(forUname: probe.uname) else {
            throw Failure.unavailable(
                "helper unsupported: \(probe.uname.isEmpty ? "unknown" : probe.uname)")
        }
        guard let resources = resourcesDirectory,
            let bytes = try? Data(contentsOf: resources.appendingPathComponent(binary.file))
        else {
            throw Failure.unavailable("this build ships no helper for \(binary.os)/\(binary.arch)")
        }
        guard let target = directory.file(binary.file) else {
            throw Failure.unavailable("the helper's file name is not usable on this server")
        }

        let sftp = connection.metadataTransport
        // `mkdir -m 700`, and it has to be ours: "/tmp/sshdrive-<uid> is a predictable name
        // on a shared host, and a directory someone else pre-created there is refused, not
        // adopted" (section 6.4).
        try await sftp.helperMkdir(directory, mode: 0o700)
        let directoryAttributes = try await sftp.helperLstat(directory)
        if probe.identity.isKnown, directoryAttributes.uid != probe.identity.uid {
            throw Failure.unavailable(
                "\(directory.path) is owned by uid \(directoryAttributes.uid), not by this account")
        }
        if directoryAttributes.mode & 0o022 != 0 {
            throw Failure.unavailable("\(directory.path) is writable by others")
        }

        var evidence = HelperDeployment.RemoteEvidence()
        let listing = (try? await sftp.helperReaddir(directory)) ?? []
        let existing = listing.first { $0.name == Data(binary.file.utf8) }
        evidence.size = existing.map { $0.attributes.size }
        var verifiedBy = "size"
        if existing != nil {
            let answers = await interrogate(master: connection.master, file: target)
            evidence.sha256 = answers.checksum
            evidence.reportedDigest = answers.digest
            evidence.reportedVersion = answers.version
            if answers.checksum != nil { verifiedBy = answers.tool }
            else if answers.digest != nil { verifiedBy = "--version" }
        }

        var uploaded = false
        switch HelperDeployment.verdict(for: binary, evidence: evidence) {
        case .keep:
            break
        case .upload(let reason):
            Log.agent.notice(
                "\(locationID, privacy: .public): uploading the helper to \(target.path, privacy: .public) - \(reason, privacy: .public)"
            )
            try await upload(bytes, to: target, in: directory, sftp: sftp, macID: connection.uploadTag)
            uploaded = true
            // "It is verified before every launch" (section 9), and an upload is the one
            // moment where a failure would otherwise be silent.
            let answers = await interrogate(master: connection.master, file: target)
            let after = HelperDeployment.RemoteEvidence(
                size: (try? await sftp.helperLstat(target)).map(\.size),
                sha256: answers.checksum, reportedDigest: answers.digest,
                reportedVersion: answers.version)
            if case .upload(let why) = HelperDeployment.verdict(for: binary, evidence: after) {
                try? await sftp.helperRemove(target)
                throw Failure.unavailable("helper upload failed: \(why)")
            }
            verifiedBy = answers.checksum != nil ? answers.tool
                : (answers.digest != nil ? "--version" : "size")
        }

        // Section 6.4: "Versions other than ours whose mtime is older than seven days are
        // removed", so two Macs on one account each keep their own file.
        let files = listing.compactMap { entry -> HelperDeployment.RemoteFile? in
            guard let name = String(data: entry.name, encoding: .utf8) else { return nil }
            return HelperDeployment.RemoteFile(
                name: name, size: entry.attributes.size, mtime: entry.attributes.mtime)
        }
        var removed: [String] = []
        for name in HelperDeployment.stale(
            files, keeping: manifest.fileNames, serverNow: await serverTime(connection.master))
        {
            guard let file = directory.file(name) else { continue }
            if (try? await sftp.helperRemove(file)) != nil { removed.append(name) }
        }

        return Deployment(
            path: target.path, version: manifest.version, directory: directory.path,
            uploaded: uploaded, verifiedBy: verifiedBy, removedStale: removed)
    }

    /// `helper off`, and `sshdrive remove`'s last connection (section 8).
    ///
    /// Only ever removes files this app's manifest names. Another Mac's helper of another
    /// version is left where it is - it may be running - and the directory is removed only
    /// when taking ours out left it empty.
    @discardableResult
    static func remove(connection: SSHBackedTransport, locationID: String) async -> [String] {
        guard !connection.probe.cacheDirectory.isEmpty,
            let directory = HelperDirectory(absolute: connection.probe.cacheDirectory),
            let manifest = manifest()
        else { return [] }
        let sftp = connection.metadataTransport
        guard let listing = try? await sftp.helperReaddir(directory) else { return [] }
        var removed: [String] = []
        for entry in listing {
            guard let name = String(data: entry.name, encoding: .utf8),
                manifest.fileNames.contains(name)
                    || name.hasPrefix(HelperDeployment.relayPrefix),
                let file = directory.file(name)
            else { continue }
            if (try? await sftp.helperRemove(file)) != nil { removed.append(name) }
        }
        let left = (try? await sftp.helperReaddir(directory)) ?? []
        if left.isEmpty { try? await sftp.helperRmdir(directory) }
        if !removed.isEmpty {
            Log.agent.notice(
                "\(locationID, privacy: .public): removed \(removed.count, privacy: .public) helper file(s) from \(directory.path, privacy: .public)"
            )
        }
        return removed
    }

    // MARK: The two things only a shell can answer

    struct Answers {
        var checksum: String?
        var tool = "sha256sum"
        var digest: String?
        var version: String?
    }

    /// One exec channel, one script, three answers: the checksum tool's digest, the
    /// binary's own `--version` line, and which tool answered.
    ///
    /// No heartbeat wrapper: this runs to completion in milliseconds and starts nothing in
    /// the background, so there is nothing that could outlive the channel (section 6.4's
    /// lifetime rule is about children we leave running).
    static func interrogate(master: SSHMaster, file: HelperFile) async -> Answers {
        let body = """
            __sd_f="$1"
            if command -v sha256sum >/dev/null 2>&1; then
              printf '%s\\000' sha256sum
              printf '%s\\000' "$(sha256sum "$__sd_f" 2>/dev/null | cut -d' ' -f1)"
            elif command -v shasum >/dev/null 2>&1; then
              printf '%s\\000' shasum
              printf '%s\\000' "$(shasum -a 256 "$__sd_f" 2>/dev/null | cut -d' ' -f1)"
            else
              printf '%s\\000' none
              printf '%s\\000' ''
            fi
            printf '%s\\000' "$("$__sd_f" --version 2>/dev/null)"
            """
        let script = RemoteScript(arguments: [file.path], body: body)
        guard let channel = try? await master.openExecChannel(script: script, readinessDeadline: 20)
        else { return Answers() }
        defer { channel.close() }
        var payload = Data()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, payload.filter({ $0 == 0 }).count < 3 {
            guard let chunk = try? await channel.stream.read(upTo: 8 * 1024, deadline: deadline),
                !chunk.isEmpty
            else { break }
            payload.append(chunk)
        }
        let records = payload.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        var answers = Answers()
        if records.count > 0 { answers.tool = records[0] }
        if records.count > 1, records[1].count == 64, records[1].allSatisfy(\.isHexDigit) {
            answers.checksum = records[1]
        }
        if records.count > 2, let parsed = HelperDeployment.parseVersionLine(records[2]) {
            answers.digest = parsed.digest
            answers.version = parsed.version
        }
        return answers
    }

    /// The server's own clock, for the seven-day staleness rule. Comparing a server mtime
    /// against the Mac's wall clock is the mistake section 6.4 spends a paragraph on.
    static func serverTime(_ master: SSHMaster) async -> Int64 {
        let script = RemoteScript(body: "printf '%s\\000' \"$(date +%s)\"")
        guard let channel = try? await master.openExecChannel(script: script, readinessDeadline: 15)
        else { return Int64(Date().timeIntervalSince1970) }
        defer { channel.close() }
        let deadline = Date().addingTimeInterval(15)
        var payload = Data()
        while Date() < deadline, !payload.contains(0) {
            guard let chunk = try? await channel.stream.read(upTo: 256, deadline: deadline),
                !chunk.isEmpty
            else { break }
            payload.append(chunk)
        }
        let text = String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self)
        return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? Int64(Date().timeIntervalSince1970)
    }

    /// Temp name, then rename into place - never written over the existing file, because
    /// "a helper of the same version may be running from that path for another Mac,
    /// writing over a running executable fails with `ETXTBSY` on Linux, and the rename
    /// leaves the old inode to the process using it" (section 6.4).
    private static func upload(
        _ bytes: Data, to target: HelperFile, in directory: HelperDirectory,
        sftp: RealSFTPTransport, macID: String
    ) async throws {
        let temporaryName = HelperDeployment.temporaryName(macID: macID)
        guard let temporary = directory.file(temporaryName) else {
            throw Failure.unavailable("could not name a temporary file in \(directory.path)")
        }
        try await sftp.helperWriteExclusive(temporary, contents: bytes, mode: 0o700)
        do {
            try await sftp.helperRename(temporary, to: target)
        } catch {
            try? await sftp.helperRemove(temporary)
            throw error
        }
    }
}
