import Foundation
import AgentCore
import Config
import Index
import SFTP
import XPCProtocols
import Logging

/// The milestone 3 debug hooks: the transfer scheduler of DESIGN.md section 6.2, the
/// channel budget of section 6.1 and the name rules of section 5.4, driven from the CLI
/// without Finder in the way.
///
/// They are here, in a file of their own, for the same reason the S4/S6 hooks are in
/// `SpikeHooks.swift`: the agent is the process that makes these calls for real, and
/// `sshdrive status` (milestone 3's other half) reports the same values.
enum TransportDebug {

    static func run(command: String, arguments: [String: String]) async throws -> Data {
        switch command {
        case "debug.transport":
            return try await report(arguments)
        case "debug.transport.reprobe":
            return try await reprobe(arguments)
        case "debug.transport.hidden":
            return try await hidden(arguments)
        case "debug.transport.fetch":
            return try await fetch(arguments)
        case "debug.transport.upload":
            return try await upload(arguments)
        case "debug.transport.escape":
            return try await escape(arguments)
        default:
            throw SSHDriveAgentError.notImplemented.asNSError("Unknown command \"\(command)\".")
        }
    }

    // MARK: The report

    private static func report(_ arguments: [String: String]) async throws -> Data {
        let location = try await DomainManager.shared.location(named: arguments["name"] ?? "")
        let runtime = try await DomainManager.shared.runtime(for: location)
        let statistics = await runtime.schedulerStatistics()
        var out: [String: Any] = [
            "location": location.displayName,
            "backend": location.backend.rawValue,
            "permissions": location.permissions.rawValue,
            "channels": await runtime.channelReport(),
            "scheduler": [
                "running": statistics.running,
                "waitingForeground": statistics.waitingForeground,
                "waitingBackground": statistics.waitingBackground,
                "peakRunning": statistics.peakRunning,
                "peakHeld": statistics.peakHeld,
                "admitted": statistics.admitted,
                "cancelled": statistics.cancelled,
                "overCeilingAdmissions": statistics.overCeilingAdmissions,
                "windowShare": statistics.windowShare,
                "maximumRunning": TransferScheduler.maximumRunning,
                "ceiling": TransferScheduler.ceiling,
            ] as [String: Any],
        ]
        if let identity = await runtime.identityReport() { out["identity"] = identity }
        return try ControlCommands.json(out)
    }

    private static func reprobe(_ arguments: [String: String]) async throws -> Data {
        let location = try await DomainManager.shared.location(named: arguments["name"] ?? "")
        // Section 6.1 caches the channel budget and re-probes it on demand; the agent
        // never sees a server banner, so "on demand" is the only invalidation there is.
        CapabilityCache.forgetChannelBudget(locationID: location.id)
        await DomainManager.shared.dropRuntime(locationID: location.id)
        let runtime = try await DomainManager.shared.runtime(for: location)
        return try ControlCommands.json([
            "location": location.displayName,
            "channels": await runtime.channelReport(),
            "identity": await runtime.identityReport() ?? [:],
        ])
    }

    // MARK: Names

    private static func hidden(_ arguments: [String: String]) async throws -> Data {
        let location = try await DomainManager.shared.location(named: arguments["name"] ?? "")
        let runtime = try await DomainManager.shared.runtime(for: location)
        let rows = try await runtime.notShown()
        return try ControlCommands.json([
            "location": location.displayName,
            "notShown": rows.map { ["path": $0.path, "reason": $0.reason] },
        ])
    }

    // MARK: Transfers

    /// One fetch, straight through the scheduler, so the queue can be driven without
    /// Finder. `--background` puts it in section 6.2's background class, `--cancel-after`
    /// cancels it mid-way, and `--partial` makes it a range request.
    private static func fetch(_ arguments: [String: String]) async throws -> Data {
        let location = try await DomainManager.shared.location(named: arguments["name"] ?? "")
        let runtime = try await DomainManager.shared.runtime(for: location)
        guard let pathString = arguments["path"] else {
            throw SSHDriveAgentError.notImplemented.asNSError("A --path is required.")
        }
        let (identifier, _) = try await runtime.identifier(forPath: pathString)

        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-debug-fetch-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
        }

        let transferID = UUID().uuidString
        let kind: TransferScheduler.Kind =
            (arguments["background"] == "1") ? .background : .foreground
        if let after = arguments["cancelAfterMilliseconds"].flatMap(Int.init), after > 0 {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(after) * 1_000_000)
                await runtime.cancel(transferID: transferID)
            }
        }

        let started = Date()
        var bytes: Int64 = 0
        var failure = ""
        var snapshotVersion = ""
        do {
            let snapshot: SSHDriveItemSnapshot
            if let partial = arguments["partial"] {
                let parts = partial.split(separator: ":").compactMap { Int64($0) }
                guard parts.count == 2 else {
                    throw SSHDriveAgentError.notImplemented.asNSError(
                        "--partial takes offset:length.")
                }
                snapshot = try await runtime.fetchPartialContents(
                    identifier: identifier, offset: parts[0], length: parts[1],
                    into: handle, transferID: transferID)
            } else {
                snapshot = try await runtime.fetchContents(
                    identifier: identifier, into: handle, transferID: transferID, kind: kind)
            }
            snapshotVersion = snapshot.contentVersion
            bytes =
                Int64(
                    (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]
                        as? Int) ?? 0)
        } catch {
            failure = error.localizedDescription
            bytes =
                Int64(
                    (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]
                        as? Int) ?? 0)
        }
        let statistics = await runtime.schedulerStatistics()
        return try ControlCommands.json([
            "path": pathString,
            "class": kind == .background ? "background" : "foreground",
            "bytes": bytes,
            "seconds": Date().timeIntervalSince(started).rounded(toPlaces: 3),
            "contentVersion": snapshotVersion,
            "error": failure,
            "peakRunning": statistics.peakRunning,
            "peakHeld": statistics.peakHeld,
            "windowShare": statistics.windowShare,
        ])
    }

    /// The section 9.1 chokepoint, exercised where the system's own filenames arrive:
    /// `createItem` with a filename of our choosing, and with a symlink target of our
    /// choosing. Nothing here goes near a string path - that is the point - so the only
    /// question is what the `RelativePath` constructor does with what it is handed.
    private static func escape(_ arguments: [String: String]) async throws -> Data {
        let location = try await DomainManager.shared.location(named: arguments["name"] ?? "")
        let runtime = try await DomainManager.shared.runtime(for: location)
        let filename = arguments["filename"] ?? ".."
        var parentIdentifier = IndexWriter.rootIdentifier
        if let parent = arguments["parent"], !parent.isEmpty {
            parentIdentifier = try await runtime.identifier(forPath: parent).identifier
        }
        var refused = ""
        var created = ""
        do {
            let snapshot = try await runtime.createItem(
                parentIdentifier: parentIdentifier,
                filename: filename,
                isDirectory: arguments["directory"] == "1",
                symlinkTarget: arguments["symlinkTarget"],
                contents: nil)
            created = String(decoding: snapshot.pathBytes, as: UTF8.self)
        } catch {
            refused = error.localizedDescription
        }
        return try ControlCommands.json([
            "filename": filename,
            "parent": arguments["parent"] ?? "",
            "symlinkTarget": arguments["symlinkTarget"] ?? "",
            "refused": refused,
            "createdAtPath": created,
        ])
    }

    /// One upload of `--size` MiB of zeroes, through the same scheduler and the same
    /// temp-file-plus-rename path a `createItem` takes.
    private static func upload(_ arguments: [String: String]) async throws -> Data {
        let location = try await DomainManager.shared.location(named: arguments["name"] ?? "")
        let runtime = try await DomainManager.shared.runtime(for: location)
        guard let pathString = arguments["path"] else {
            throw SSHDriveAgentError.notImplemented.asNSError("A --path is required.")
        }
        let path = try RelativePath(string: pathString)
        guard let filename = path.lastComponent.map({ String(decoding: $0, as: UTF8.self) }) else {
            throw SSHDriveAgentError.notImplemented.asNSError("A --path with a filename is required.")
        }
        let parentIdentifier: String
        if let parent = path.parent, !parent.isRoot {
            parentIdentifier = try await runtime.identifier(forPath: parent.description).identifier
        } else {
            parentIdentifier = IndexWriter.rootIdentifier
        }

        let megabytes = Int(arguments["megabytes"] ?? "64") ?? 64
        let source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-debug-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: source)
        let block = Data(count: 1024 * 1024)
        for _ in 0..<max(1, megabytes) { try writeHandle.write(contentsOf: block) }
        try writeHandle.close()
        let readHandle = try FileHandle(forReadingFrom: source)
        defer {
            try? readHandle.close()
            try? FileManager.default.removeItem(at: source)
        }

        let transferID = UUID().uuidString
        if let after = arguments["cancelAfterMilliseconds"].flatMap(Int.init), after > 0 {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(after) * 1_000_000)
                await runtime.cancel(transferID: transferID)
            }
        }
        let started = Date()
        var failure = ""
        var size: Int64 = 0
        do {
            let snapshot = try await runtime.createItem(
                parentIdentifier: parentIdentifier, filename: filename, isDirectory: false,
                symlinkTarget: nil, contents: readHandle, transferID: transferID)
            size = snapshot.size
        } catch {
            failure = error.localizedDescription
        }
        let seconds = Date().timeIntervalSince(started)
        return try ControlCommands.json([
            "path": pathString,
            "megabytes": megabytes,
            "size": size,
            "seconds": seconds.rounded(toPlaces: 3),
            "mibPerSecond": (Double(size) / 1_048_576 / max(seconds, 0.001)).rounded(toPlaces: 1),
            "error": failure,
        ])
    }
}
