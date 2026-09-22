import Foundation
import AgentCore
import Config
import Logging
import SFTP
import SSHProcess

/// Puts the remote helper on the server, checks it is ours, and takes it away again
/// (docs/design/change-detection.md, tier 2 steps 1 and 2; docs/design/security.md).
///
/// Everything that is a *decision* lives in `AgentCore` as `HelperDeployment` and
/// `HelperManifest` and is unit-tested there; this is the I/O around it - one exec channel
/// for the questions only a shell can answer, and the SFTP metadata channel for the bytes.
///
/// Deployment failures are never fatal: the location silently continues at the next tier
/// and the status report says why the helper is not running.
enum HelperDeployer {

    /// Where the app keeps the binaries and the manifest CI wrote
    /// (docs/design/packaging.md).
    ///
    /// Set from `BundleInspecting.helperResourcesURL` by `AgentRuntimeBootstrap.install`,
    /// because `Contents/Resources/helper/` is a fact about the bundle and the bundle is a
    /// seam. Nil in a `swift test` run, which is not an error: the location runs at the
    /// sweep tier and says so.
    nonisolated(unsafe) static var resourcesDirectory: URL?

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
        /// The reason `status` prints on the change-detection line, and whether it will
        /// still be true on the next connection.
        ///
        /// `permanent` is the fixed list - no shell, no exec channel, no writable or
        /// executable directory, an unsupported architecture, a hash that did not match
        /// after a redeploy - and it is what costs the location the tier for the session. A
        /// helper that simply did not answer this time is `permanent: false` and is retried
        /// on a bounded backoff: an outage read as a verdict about the server parks the
        /// mount at the sweep tier for the session.
        case unavailable(String, permanent: Bool = true)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason, _): return reason
            }
        }

        var isPermanent: Bool {
            switch self {
            case .unavailable(_, let permanent): return permanent
            }
        }
    }

    /// Steps 1 and 2 of the deployment, on one exec channel and the metadata SFTP
    /// channel.
    static func ensureDeployed(
        connection: any LiveConnection,
        locationID: String
    ) async throws -> Deployment {
        let probe = connection.probe
        // Before anything about the *server*: is there a channel to do it on right now?
        // A connection with no exec channel and no SFTP client is an outage, not a
        // verdict; read as a verdict it parks the mount at the sweep tier until the agent
        // restarts.
        guard let master = connection.execMaster, let sftp = connection.metadataTransport else {
            throw SFTPError.noConnection
        }
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

        // `mkdir -m 700`, and it has to be ours: `/tmp/sshdrive-<uid>` is a predictable
        // name on a shared host, so a directory someone else pre-created there is refused,
        // not adopted.
        try await sftp.helperMkdir(directory, mode: 0o700)
        var directoryAttributes = try await sftp.helperLstat(directory)
        if probe.identity.isKnown, directoryAttributes.uid != probe.identity.uid {
            throw Failure.unavailable(
                "\(directory.path) is owned by uid \(directoryAttributes.uid), not by this account")
        }
        // Ours but too open - a server umask that widened our `mkdir`, or a directory an
        // older build left at 0755. The mode wanted is 0700 and we may set it, so it is
        // set rather than made a refusal; only a directory that is not ours, or that will
        // not take the mode, is refused.
        if directoryAttributes.mode & 0o077 != 0 {
            try? await sftp.helperSetstat(directory, mode: 0o700)
            directoryAttributes = (try? await sftp.helperLstat(directory)) ?? directoryAttributes
            Log.agent.notice(
                "\(locationID, privacy: .public): tightened \(directory.path, privacy: .public) to 0700"
            )
        }
        if directoryAttributes.mode & 0o022 != 0 {
            throw Failure.unavailable(
                "\(directory.path) is writable by others and would not take mode 0700")
        }

        var evidence = HelperDeployment.RemoteEvidence()
        let listing = (try? await sftp.helperReaddir(directory)) ?? []
        let existing = listing.first { $0.name == Data(binary.file.utf8) }
        evidence.size = existing.map { $0.attributes.size }
        var verifiedBy = "size"
        if existing != nil {
            let answers = await interrogate(master: master, file: target)
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
            // The helper is verified before every launch, and an upload is the one
            // moment where a failure would otherwise be silent.
            let answers = await interrogate(master: master, file: target)
            let after = HelperDeployment.RemoteEvidence(
                size: (try? await sftp.helperLstat(target)).map(\.size),
                sha256: answers.checksum, reportedDigest: answers.digest,
                reportedVersion: answers.version)
            if case .upload(let why) = HelperDeployment.verdict(for: binary, evidence: after) {
                try? await sftp.helperRemove(target)
                // A hash that came back and disagreed is a mismatch after a redeploy,
                // and is permanent. **No** hash coming back at all is not: the channel
                // that would have run `sha256sum` or `--version` is the suspect, and a
                // connection going away is exactly how that happens. A location whose
                // exec channel is broken by an orphaned master reports "the server could
                // not verify the helper's contents"; read as permanent, that parks it at
                // the sweep tier for the session against a server that is fine a minute
                // later.
                throw Failure.unavailable(
                    "helper upload failed: \(why)",
                    permanent: HelperDeployment.uploadFailureIsPermanent(after: after))
            }
            verifiedBy = answers.checksum != nil ? answers.tool
                : (answers.digest != nil ? "--version" : "size")
        }

        // Versions other than ours whose mtime is older than seven days are removed, so
        // two Macs on one account each keep their own file.
        let files = listing.compactMap { entry -> HelperDeployment.RemoteFile? in
            guard let name = String(data: entry.name, encoding: .utf8) else { return nil }
            return HelperDeployment.RemoteFile(
                name: name, size: entry.attributes.size, mtime: entry.attributes.mtime)
        }
        var removed: [String] = []
        for name in HelperDeployment.stale(
            files, keeping: manifest.fileNames, serverNow: await serverTime(master))
        {
            guard let file = directory.file(name) else { continue }
            if (try? await sftp.helperRemove(file)) != nil { removed.append(name) }
        }

        return Deployment(
            path: target.path, version: manifest.version, directory: directory.path,
            uploaded: uploaded, verifiedBy: verifiedBy, removedStale: removed)
    }

    /// `helper off`, and `sshdrive remove`'s last connection.
    ///
    /// Only ever removes files this app's manifest names. Another Mac's helper of another
    /// version is left where it is - it may be running - and the directory is removed only
    /// when taking ours out left it empty.
    @discardableResult
    static func remove(connection: any LiveConnection, locationID: String) async -> [String] {
        guard !connection.probe.cacheDirectory.isEmpty,
            let directory = HelperDirectory(absolute: connection.probe.cacheDirectory),
            let manifest = manifest(),
            let sftp = connection.metadataTransport
        else { return [] }
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
    /// the background, so there is nothing that could outlive the channel: the lifetime
    /// rule is about children we leave running.
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

    /// The server's own clock, for the seven-day staleness rule. A server mtime compared
    /// against the Mac's wall clock measures the two clocks' disagreement as well as the
    /// file's age.
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

    /// Temp name, then rename into place - never written over the existing file. A helper
    /// of the same version may be running from that path for another Mac, writing over a
    /// running executable fails with `ETXTBSY` on Linux, and the rename leaves the old
    /// inode to the process using it.
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
