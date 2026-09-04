import Foundation
import Config
import Logging
import SFTP

/// Errors that are ours rather than the wire's. The SFTP status reply carries no errno
/// (section 6.2), so every one of these is the answer to a *second* question the writer
/// asked - an `lstat` of a destination, a `readdir` of a directory - and not a status
/// code read off the wire.
public enum RemoteWriteError: Error, Equatable, LocalizedError {
    /// The destination name is taken. Confirmed with an `lstat` after the rename's bare
    /// `FAILURE` (section 5.5), or found by the preflight on a server whose plain
    /// `rename` overwrites.
    case filenameCollision(String)
    /// A non-empty directory the system did not ask to remove recursively (section 5.5).
    case deletionRejected(String)
    /// A symlink target that leaves the share (section 5.7).
    case escapingSymlinkTarget

    public var errorDescription: String? {
        switch self {
        case let .filenameCollision(name):
            return "\"\(name)\" already exists on the server."
        case let .deletionRejected(name):
            return "\"\(name)\" is not empty."
        case .escapingSymlinkTarget:
            return SymlinkPolicy.escapingTargetMessage
        }
    }
}

/// The server half of DESIGN.md section 5.5: the temp-file-plus-rename upload protocol,
/// the conflict check that sits between the bytes landing and the rename, the conflict
/// copy, the stale-temp-file rule, and the delete rules.
///
/// It owns the transport and the **in-flight set**, and nothing else. In particular it
/// never touches the index: the agent reads the row, hands the writer the three fields
/// the conflict check needs, and writes the result back itself, so there is exactly one
/// writer of the index and it is still `LocationRuntime` (section 5.3). That is also
/// what makes every rule here testable against `FakeTransport` with no database at all.
public actor RemoteWriter {

    public struct Options: Sendable {
        /// The first eight hex digits of the identifier minted once per install and kept
        /// at the top level of `config.json` (section 5.5), so every temp file says which
        /// Mac made it.
        public var macID: String
        /// This Mac's `LocalHostName`. It is the Mac's content that is being set aside,
        /// so it is the Mac that names the conflict copy (section 5.5).
        public var localHostName: String
        /// `sshdrive set <name> create-check lstat` forces the preflight on a server the
        /// user does not trust to refuse an overwriting `rename` (section 5.5).
        public var createCheck: CreateCheck
        /// A debug hold between the bytes landing in the temp file and the destination
        /// `lstat` - which is exactly section 5.5's conflict window. `sshdrive debug
        /// fault --upload-delay MS` opens it so a spike can change the file on the server
        /// inside it and get a real conflict rather than a simulated one. Zero in
        /// ordinary use.
        public var conflictWindowHoldMilliseconds: Int

        public init(
            macID: String, localHostName: String, createCheck: CreateCheck = .auto,
            conflictWindowHoldMilliseconds: Int = 0
        ) {
            self.macID = macID
            self.localHostName = localHostName
            self.createCheck = createCheck
            self.conflictWindowHoldMilliseconds = conflictWindowHoldMilliseconds
        }
    }

    /// What the conflict check of section 5.5 compares against: size and mtime from the
    /// `baseVersion` the system passed us, and `generation` from the row, because the
    /// wire cannot carry a generation (section 5.3).
    public struct BaseVersion: Equatable, Sendable {
        public var size: Int64
        public var mtime: Int64
        public var generation: Int64

        public init(size: Int64, mtime: Int64, generation: Int64) {
            self.size = size
            self.mtime = mtime
            self.generation = generation
        }

        /// Parses `"size-mtime-generation"`, the one version format at every tier
        /// (section 5.3). Nil for anything else, which is how a version we did not write
        /// - a reconciled row, a build that changed the format - skips the check rather
        /// than reporting a conflict against a string it cannot read.
        public init?(contentVersion: String) {
            let parts = contentVersion.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3,
                let size = Int64(parts[0]), let mtime = Int64(parts[1]),
                let generation = Int64(parts[2])
            else { return nil }
            self.size = size
            self.mtime = mtime
            self.generation = generation
        }
    }

    /// How an upload ended.
    public enum UploadOutcome: Sendable {
        /// The bytes took the destination's name. The attributes are the post-upload
        /// `lstat`, which is what the row's content version must be built from: a version
        /// we invent is a version the next sweep will not recognise (section 5.5).
        case landed(SFTPFileAttributes)
        /// The remote changed underneath the user. The temp file, which already holds the
        /// local content, was renamed beside the original and the destination was left
        /// alone. The caller returns the **remote** item and then evicts it, because the
        /// system believes whatever version a `modifyItem` reply carries (S3,
        /// 2026-09-04).
        case conflicted(
            copy: RelativePath, copyAttributes: SFTPFileAttributes, remote: SFTPFileAttributes)
    }

    private let transport: any SFTPTransport
    private var options: Options

    /// Section 5.5's in-flight set: "every path with an upload in flight sits in a
    /// per-location in-flight set; the differ skips dirty paths in it". It also
    /// serialises two saves of one file in quick succession, so the second
    /// `modifyItem`'s conflict check runs against the first's result rather than racing
    /// it, and it is what tells a live temp file from a stale one.
    private var inFlight: Set<Data> = []
    /// Temp files this process currently has open, by path bytes. A temp name in here is
    /// live; any other of ours is stale by definition (section 5.5).
    private var liveTemporaries: Set<Data> = []
    /// Continuations waiting for a path to leave the in-flight set.
    private var waiters: [Data: [CheckedContinuation<Void, Never>]] = [:]

    /// Whether a plain `rename` refuses an existing name on this server. Nil until the
    /// probe has run. OpenSSH implements `rename` as `link` + `unlink` and refuses;
    /// servers that are not OpenSSH may overwrite, and where they do, every create and
    /// rename gets an `lstat` preflight instead (section 5.5).
    private var renameRefusesExisting: Bool?

    public init(transport: any SFTPTransport, options: Options) {
        self.transport = transport
        self.options = options
    }

    public func setOptions(_ options: Options) { self.options = options }

    // MARK: The in-flight set

    /// The paths change detection must skip, so our own writes never come back as remote
    /// changes (section 5.5).
    public func inFlightPaths() -> Set<Data> { inFlight }

    public func isInFlight(_ path: RelativePath) -> Bool { inFlight.contains(path.bytes) }

    /// Takes the path, waiting if another save of the same file is still landing.
    private func enter(_ path: RelativePath) async {
        while inFlight.contains(path.bytes) {
            await withCheckedContinuation { continuation in
                waiters[path.bytes, default: []].append(continuation)
            }
        }
        inFlight.insert(path.bytes)
    }

    private func leave(_ path: RelativePath) {
        inFlight.remove(path.bytes)
        for continuation in waiters.removeValue(forKey: path.bytes) ?? [] {
            continuation.resume()
        }
    }

    // MARK: Names

    /// `.sshdrive-upload-<mac8>-<uuid>` (section 5.5).
    public func temporaryName() -> String {
        ".sshdrive-upload-\(options.macID)-\(UUID().uuidString.lowercased())"
    }

    /// True for any of our upload temp files, whoever made it.
    public static func isTemporaryName(_ name: String) -> Bool {
        name.hasPrefix(".sshdrive-upload-")
    }

    /// True for a temp file carrying **this** Mac's tag.
    public func isOurTemporaryName(_ name: String) -> Bool {
        name.hasPrefix(".sshdrive-upload-\(options.macID)-")
    }

    /// `<name> (conflicted copy from <Mac name> <date>).<ext>` (section 5.5).
    public static func conflictCopyName(
        for filename: String, hostName: String, date: Date,
        calendar: TimeZone = TimeZone.current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar
        // Dots rather than colons in the time: a colon is legal on the server but macOS
        // shows it back to the user as a slash.
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: date)
        let suffix = " (conflicted copy from \(hostName) \(stamp))"
        let (base, ext) = splitExtension(filename)
        return ext.isEmpty ? base + suffix : base + suffix + "." + ext
    }

    /// Splits a filename into stem and extension. A leading dot is part of the stem, so
    /// `.profile` keeps its name and does not become `(conflicted copy …).profile`.
    static func splitExtension(_ filename: String) -> (base: String, ext: String) {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex,
            dot != filename.index(before: filename.endIndex)
        else { return (filename, "") }
        return (String(filename[filename.startIndex..<dot]),
                String(filename[filename.index(after: dot)...]))
    }

    // MARK: The upload protocol

    /// Section 5.5, end to end.
    ///
    /// 1. Stream the bytes into `.sshdrive-upload-<mac8>-<uuid>` beside the destination,
    ///    opened with the Mac file's permission bits as `sftp put` does.
    /// 2. `lstat` the destination. This comes **after** the upload and immediately before
    ///    the rename, so the conflict window is one round trip rather than the length of
    ///    the upload.
    /// 3. If `base` is given and size, mtime or generation moved, rename the temp file -
    ///    which already holds the local content - to the conflict copy beside the
    ///    original and stop.
    /// 4. Otherwise take the name: a plain, non-overwriting `rename` for a create,
    ///    `posix-rename@openssh.com` for a replacement.
    /// 5. `setstat` the mode back, and the mtime the system passed in, truncated to whole
    ///    seconds since SFTP v3 carries no more.
    /// 6. `lstat` the result and hand it back: that, and not a version of our own, is the
    ///    content version the row records.
    public func upload(
        to path: RelativePath,
        mode: UInt32,
        modificationDate: Int64?,
        replacingExisting: Bool,
        base: BaseVersion?,
        currentGeneration: Int64,
        window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> UploadOutcome {
        guard let parent = path.parent else {
            throw SFTPError.failure("The location root is not a file.")
        }
        let temporary = try parent.appending(component: temporaryName())

        await enter(path)
        liveTemporaries.insert(temporary.bytes)
        defer {
            liveTemporaries.remove(temporary.bytes)
            leave(path)
        }

        do {
            try await transport.writeExclusive(
                temporary, mode: mode, window: window, source: source, progress: progress)
        } catch {
            // A cancel or a lost connection between the open and the close leaves nothing
            // behind: `writeExclusive` removes its own partial file. Anything it could
            // not remove is caught by the stale-temp rule on the next listing.
            throw error
        }

        // Step 2. `lstat` after the upload, immediately before the rename.
        if options.conflictWindowHoldMilliseconds > 0 {
            Log.agent.notice(
                "holding the conflict window open on \(path.description, privacy: .public) for \(self.options.conflictWindowHoldMilliseconds, privacy: .public) ms (debug fault --upload-delay)"
            )
            try? await Task.sleep(
                nanoseconds: UInt64(options.conflictWindowHoldMilliseconds) * 1_000_000)
        }
        let existing = try? await transport.lstat(path)

        // Step 3. The conflict check compares all three fields, but from two sources:
        // size and mtime from this `lstat`, and generation from the row (section 5.3).
        if let base, let existing, existing.type != .directory {
            let moved =
                existing.size != base.size || existing.mtime != base.mtime
                || currentGeneration != base.generation
            if moved {
                Log.agent.notice(
                    "conflict on \(path.description, privacy: .public): base \(base.size, privacy: .public)-\(base.mtime, privacy: .public)-\(base.generation, privacy: .public), server \(existing.size, privacy: .public)-\(existing.mtime, privacy: .public)-\(currentGeneration, privacy: .public)"
                )
                let copy = try await divertToConflictCopy(temporary, beside: path)
                let copyAttributes = try await transport.lstat(copy)
                return .conflicted(
                    copy: copy, copyAttributes: copyAttributes, remote: existing)
            }
        }

        // Step 4.
        do {
            if replacingExisting, existing != nil {
                try await replace(temporary, with: path)
            } else {
                try await claim(temporary, as: path, knownExisting: existing)
            }
        } catch {
            try? await transport.remove(temporary)
            throw error
        }

        // Step 5. The temp file was created with `mode`, but the server's umask may have
        // taken bits off it, so the mode is restored after the rename. Owner and group
        // cannot be restored - that needs root - and both are documented.
        try? await transport.setstat(path, mode: mode, mtime: modificationDate)

        // Step 6.
        return .landed(try await transport.lstat(path))
    }

    /// The create half of step 4: a plain, non-overwriting `rename`. OpenSSH implements
    /// it as `link` + `unlink`, so it fails atomically if anything now holds the name.
    /// The refusal arrives as a bare `FAILURE` (section 6.2), so it is confirmed with an
    /// `lstat` of the destination before it is reported as a collision, and reported as
    /// an ordinary sync error when nothing is there.
    private func claim(
        _ temporary: RelativePath, as path: RelativePath, knownExisting: SFTPFileAttributes?
    ) async throws {
        if knownExisting != nil {
            // The `lstat` this call already made is the preflight; there is no point
            // asking the server to refuse what we can see.
            throw RemoteWriteError.filenameCollision(path.description)
        }
        if try await needsPreflight(), (try? await transport.lstat(path)) != nil {
            throw RemoteWriteError.filenameCollision(path.description)
        }
        do {
            try await transport.rename(temporary, to: path)
        } catch let error as SFTPError {
            if case .failure = error, (try? await transport.lstat(path)) != nil {
                throw RemoteWriteError.filenameCollision(path.description)
            }
            throw error
        }
    }

    /// The overwrite half of step 4. `posix-rename@openssh.com` is `rename(2)` and is
    /// atomic; without it there is `remove` + `rename`, a non-atomic window that
    /// `status` reports as a degraded capability (sections 5.5, 8.1).
    private func replace(_ temporary: RelativePath, with path: RelativePath) async throws {
        if await transport.extensions.contains(.posixRename) {
            try await transport.posixRename(temporary, to: path)
            return
        }
        try await transport.remove(path)
        try await transport.rename(temporary, to: path)
    }

    /// Renames the temp file, which already holds the local content, to
    /// `<name> (conflicted copy from <Mac name> <date>).<ext>` beside the original. The
    /// rename is non-overwriting, so a second conflict in the same second gets a counter
    /// rather than eating the first copy.
    private func divertToConflictCopy(
        _ temporary: RelativePath, beside path: RelativePath
    ) async throws -> RelativePath {
        guard let parent = path.parent else { throw SFTPError.failure("Failure") }
        let filename = String(decoding: path.lastComponent ?? Data(), as: UTF8.self)
        let base = RemoteWriter.conflictCopyName(
            for: filename, hostName: options.localHostName, date: Date())
        for attempt in 0..<32 {
            let name: String
            if attempt == 0 {
                name = base
            } else {
                let (stem, ext) = RemoteWriter.splitExtension(base)
                name = ext.isEmpty ? "\(stem) \(attempt + 1)" : "\(stem) \(attempt + 1).\(ext)"
            }
            let candidate = try parent.appending(component: name)
            do {
                try await transport.rename(temporary, to: candidate)
                Log.agent.notice(
                    "conflict copy \(candidate.description, privacy: .public) kept the local content"
                )
                return candidate
            } catch let error as SFTPError {
                guard case .failure = error else { throw error }
                continue
            }
        }
        throw SFTPError.failure("Could not name a conflict copy beside \(path.description)")
    }

    // MARK: The rename-semantics probe

    /// Section 5.5: "Servers that are not OpenSSH may overwrite on a plain `rename`; the
    /// probe tests this once, in the location root, and where it overwrites every create
    /// and rename gets an `lstat` preflight instead." Two temp files of our own, one
    /// renamed over the other, and both removed afterwards whatever happens.
    @discardableResult
    public func probeRenameSemantics() async -> Bool {
        if let known = renameRefusesExisting { return known }
        let sourceName = temporaryName()
        let targetName = temporaryName()
        guard let source = try? RelativePath.root.appending(component: sourceName),
            let target = try? RelativePath.root.appending(component: targetName)
        else { return true }
        var refuses = true
        do {
            try await transport.writeExclusive(
                source, mode: 0o600, window: 1, source: { Data() }, progress: { _ in })
            try await transport.writeExclusive(
                target, mode: 0o600, window: 1, source: { Data() }, progress: { _ in })
            do {
                try await transport.rename(source, to: target)
                // It took the name that was already there: this server overwrites.
                refuses = false
            } catch {
                refuses = true
            }
        } catch {
            // The root is not writable, or the connection went. Assume the safe answer -
            // OpenSSH's - and let `createCheck` force the preflight if the user wants it.
            try? await transport.remove(source)
            try? await transport.remove(target)
            return true
        }
        try? await transport.remove(source)
        try? await transport.remove(target)
        renameRefusesExisting = refuses
        if !refuses {
            Log.agent.notice(
                "this server's plain rename overwrites; every create and rename gets an lstat preflight (section 5.5)"
            )
        }
        return refuses
    }

    /// Whether a create must `lstat` before it renames.
    private func needsPreflight() async throws -> Bool {
        if options.createCheck == .lstat { return true }
        return !(renameRefusesExisting ?? true)
    }

    /// For `status` (section 8.1) and the debug hooks: what the probe found, without
    /// running it.
    public func renameSemantics() -> Bool? { renameRefusesExisting }

    // MARK: Stale temp files

    /// Section 5.5: "A temp file carrying this Mac's `<mac8>` that is not in the in-flight
    /// set is stale by definition and is removed as soon as the agent lists its
    /// directory, however new it is. A temp file from another Mac is left alone until it
    /// is 30 days old."
    ///
    /// This is the only cleanup there is for an upload that died with a connection or an
    /// agent, and it is why the temp name carries the Mac that made it. Returns the
    /// paths it removed.
    @discardableResult
    public func sweepTemporaries(
        in directory: RelativePath, entries: [SFTPDirectoryEntry], now: Date = Date()
    ) async -> [RelativePath] {
        var removed: [RelativePath] = []
        for entry in entries {
            let name = String(decoding: entry.name, as: UTF8.self)
            guard RemoteWriter.isTemporaryName(name) else { continue }
            guard let path = try? directory.appending(component: entry.name) else { continue }
            if isOurTemporaryName(name) {
                guard !liveTemporaries.contains(path.bytes) else { continue }
            } else {
                let age = now.timeIntervalSince1970 - Double(entry.attributes.mtime)
                guard age > 30 * 86400 else { continue }
            }
            do {
                try await transport.remove(path)
                removed.append(path)
                Log.agent.notice(
                    "removed a stale upload temp file: \(path.description, privacy: .public)")
            } catch {
                Log.agent.debug(
                    "could not remove \(path.description, privacy: .public): \(error, privacy: .public)"
                )
            }
        }
        return removed
    }

    // MARK: The rest of the write matrix

    public func makeDirectory(_ path: RelativePath, mode: UInt32) async throws {
        do {
            try await transport.mkdir(path, mode: mode)
        } catch let error as SFTPError {
            // mkdir's EEXIST is a bare FAILURE too (section 6.2); ask the second question.
            if case .failure = error, (try? await transport.lstat(path)) != nil {
                throw RemoteWriteError.filenameCollision(path.description)
            }
            throw error
        }
    }

    /// Section 5.7: `ln -s` inside the mount arrives here, and the target is accepted
    /// only if it passes the lexical inside-the-share check. Otherwise it is refused,
    /// because the resulting link would be hidden the moment it was created.
    public func makeSymlink(
        target: String, at path: RelativePath, roots: SymlinkPolicy.Roots
    ) async throws -> String {
        let checked: String
        do {
            checked = try SymlinkPolicy.targetForCreate(
                target, in: path.parent ?? .root, roots: roots)
        } catch {
            throw RemoteWriteError.escapingSymlinkTarget
        }
        do {
            try await transport.symlink(target: checked, at: path)
        } catch let error as SFTPError {
            if case .failure = error, (try? await transport.lstat(path)) != nil {
                throw RemoteWriteError.filenameCollision(path.description)
            }
            throw error
        }
        return checked
    }

    /// A rename or move of an existing item. Always the plain, non-overwriting `rename`,
    /// with the case-only exception below.
    ///
    /// **Case-only renames** (section 5.5). `Makefile` to `makefile` is an ordinary
    /// rename on a case-sensitive server. On a case-insensitive one - macOS, or a
    /// Samba-backed share - `link` fails with `EEXIST`, the confirming `lstat` finds a
    /// file at the destination, and the rule above would report a collision for a
    /// legitimate rename. So when the two names differ only by case or by Unicode
    /// normalisation, the agent asks SFTP `realpath` for both; if they agree the names
    /// are one file, and the rename is redone with `posix-rename@openssh.com`, which is
    /// `rename(2)` and changes case in place.
    public func move(_ source: RelativePath, to destination: RelativePath) async throws {
        if try await needsPreflight(), (try? await transport.lstat(destination)) != nil {
            if try await isSameFileUnderAnotherSpelling(source, destination) {
                try await renameInPlace(source, to: destination)
                return
            }
            throw RemoteWriteError.filenameCollision(destination.description)
        }
        do {
            try await transport.rename(source, to: destination)
        } catch let error as SFTPError {
            guard case .failure = error else { throw error }
            guard (try? await transport.lstat(destination)) != nil else { throw error }
            if try await isSameFileUnderAnotherSpelling(source, destination) {
                try await renameInPlace(source, to: destination)
                return
            }
            throw RemoteWriteError.filenameCollision(destination.description)
        }
    }

    /// True when the two paths differ only by case or normalisation **and** the server
    /// says they are the same file. Both halves matter: the first is what makes it worth
    /// asking, the second is the answer.
    private func isSameFileUnderAnotherSpelling(
        _ source: RelativePath, _ destination: RelativePath
    ) async throws -> Bool {
        guard source != destination else { return true }
        guard
            let a = NameVisibility.localKey(for: source.bytes),
            let b = NameVisibility.localKey(for: destination.bytes),
            a == b
        else { return false }
        guard let resolvedSource = try? await transport.realpath(source),
            let resolvedDestination = try? await transport.realpath(destination)
        else { return false }
        return resolvedSource == resolvedDestination
    }

    /// The case-only rename itself. `posix-rename@openssh.com` is `rename(2)`; where the
    /// server lacks it the rename goes through a temporary third name (section 5.5).
    private func renameInPlace(_ source: RelativePath, to destination: RelativePath) async throws {
        if await transport.extensions.contains(.posixRename) {
            try await transport.posixRename(source, to: destination)
            return
        }
        guard let parent = source.parent else { throw SFTPError.failure("Failure") }
        let waypoint = try parent.appending(component: temporaryName())
        try await transport.rename(source, to: waypoint)
        do {
            try await transport.rename(waypoint, to: destination)
        } catch {
            try? await transport.rename(waypoint, to: source)
            throw error
        }
    }

    /// Section 5.5's deletes.
    ///
    /// - A non-empty directory is refused with `.deletionRejected` unless the system
    ///   passed the recursive option. `ENOTEMPTY` arrives as a bare `FAILURE`, so the
    ///   `readdir` is the second question that tells it apart from a permission problem.
    /// - The recursive walk comes from the **server**, not the index: folders Finder
    ///   never opened have no rows, and an index-driven `rmdir` would fail on the first
    ///   unexplored subfolder. Every directory is re-`lstat`ed before descending, so one
    ///   replaced by a symlink after it was enumerated is noticed first (section 9.1).
    /// - Deleting something already gone succeeds: `ENOENT` is reported as success, so a
    ///   user who deletes a ghost gets what they asked for rather than an error.
    public func delete(_ path: RelativePath, isDirectory: Bool, recursive: Bool) async throws {
        do {
            if isDirectory {
                if recursive {
                    try await removeRecursively(path)
                } else {
                    try await removeEmptyDirectory(path)
                }
            } else {
                try await transport.remove(path)
            }
        } catch SFTPError.noSuchFile {
            // Already gone: that is the state the user asked for.
            return
        }
    }

    private func removeEmptyDirectory(_ path: RelativePath) async throws {
        do {
            try await transport.rmdir(path)
        } catch let error as SFTPError {
            guard case .failure = error else { throw error }
            let entries = (try? await transport.readdir(path)) ?? []
            if !entries.isEmpty {
                throw RemoteWriteError.deletionRejected(path.description)
            }
            throw error
        }
    }

    private func removeRecursively(_ path: RelativePath) async throws {
        let attributes = try await transport.lstat(path)
        guard attributes.type == .directory else {
            try await transport.remove(path)
            return
        }
        for entry in try await transport.readdir(path) {
            let name = entry.name
            if name == Data(".".utf8) || name == Data("..".utf8) { continue }
            let child = try path.appending(component: name)
            if entry.attributes.type == .directory {
                try await removeRecursively(child)
            } else {
                try await transport.remove(child)
            }
        }
        try await transport.rmdir(path)
    }

    /// A `modifyItem` whose `changedFields` carries `.fileSystemFlags` - a `chmod +x`
    /// inside the mount - sets or clears the execute bits and re-records the mode. The
    /// read and write bits are never changed that way, since `allowsWriting` already
    /// expresses them (section 5.4).
    public static func modeAfterExecutableChange(current: UInt32, userExecutable: Bool) -> UInt32 {
        let executeBits: UInt32 = 0o111
        if userExecutable {
            // Mirror the read bits, as `chmod +x` does: every class that may read may run.
            let readBits = current & 0o444
            let derived = (readBits >> 2) & executeBits
            return current | (derived == 0 ? 0o100 : derived)
        }
        return current & ~executeBits
    }

    /// Applies a mode change to the server and hands back the fresh `lstat`.
    public func setMode(_ path: RelativePath, mode: UInt32) async throws -> SFTPFileAttributes {
        try await transport.setstat(path, mode: mode, mtime: nil)
        return try await transport.lstat(path)
    }

    public func stat(_ path: RelativePath) async throws -> SFTPFileAttributes {
        try await transport.lstat(path)
    }
}
