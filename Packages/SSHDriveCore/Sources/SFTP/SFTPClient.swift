import Foundation
import Logging
import SSHProcess

/// An absolute path on the server, in server bytes.
///
/// It exists so that DESIGN.md section 9.1's chokepoint holds at the type level: the
/// initialiser is internal, so no module outside `SFTP` can make one, and inside `SFTP`
/// the only thing that makes one is `RealSFTPTransport`, by joining a validated
/// `RelativePath` to the canonical root. The wire client therefore has no API that takes
/// a string path, exactly as section 9.1 requires, while still being a complete SFTP
/// client underneath.
public struct SFTPServerPath: Sendable, Hashable, CustomStringConvertible {
    public let bytes: Data

    init(bytes: Data) { self.bytes = bytes }

    /// A lossy display form, for logs. Never sent to a server.
    public var description: String { String(decoding: bytes, as: UTF8.self) }
}

/// An open file or directory handle. Opaque server bytes.
public struct SFTPFileHandle: Sendable, Hashable {
    let raw: Data
}

/// The reply to `limits@openssh.com`, which is what sizes the pipelining window
/// (section 6.2).
public struct SFTPLimits: Sendable, Equatable {
    public var maxPacketLength: UInt64
    public var maxReadLength: UInt64
    public var maxWriteLength: UInt64
    public var maxOpenHandles: UInt64
}

/// The SFTP version 3 wire client (DESIGN.md section 6.2).
///
/// Owns one byte stream, one request-id space and one pipeline. Requests are matched to
/// replies by id, so several may be outstanding at once; the pipelining window is
/// bounded, every request carries a deadline, and a request that misses its deadline
/// takes the whole channel down with it, because a channel that missed one deadline has
/// nothing useful left to say (section 6.2, section 6.1's exit classification).
public actor SFTPClient {

    public struct Configuration: Sendable {
        /// Section 6.2: 20 s for metadata.
        public var metadataDeadline: Duration = .seconds(20)
        /// The fixed part of a transfer deadline, before the size scaling.
        public var transferBaseDeadline: Duration = .seconds(20)
        /// The size scaling: a request for N bytes gets `base + N / this` extra. Slow
        /// enough to survive a bad link, and re-armed by every chunk that lands, which is
        /// section 6.2's "extended while bytes keep arriving".
        public var transferBytesPerSecond: Int = 32 * 1024
        /// Section 6.2's conservative window when the server offers no
        /// `limits@openssh.com`: 32 KB x 16.
        public var fallbackChunkSize = 32 * 1024
        public var windowRequests = 16
        /// A ceiling on everything outstanding on this channel at once, whatever the
        /// callers ask for. Soft: it is a gate on new requests, not a hard reservation.
        public var maxOutstandingRequests = 64
        /// How many `readdir` pages are asked for back to back (section 6.2). Ordering
        /// does not matter because the pages are merged.
        public var readdirPipelineDepth = 2
        /// How often the deadline sweeper looks. Small enough that a 20 s deadline is
        /// accurate, large enough that a 1 GB transfer does not spend its time here.
        public var deadlineTick: Duration = .milliseconds(200)
        /// A packet larger than this is a desynchronised stream, not a big directory.
        public var maximumPacketLength = 64 * 1024 * 1024

        public init() {}
    }

    // MARK: State

    private let stream: any ByteStream
    private let configuration: Configuration
    private let log = Log.sftp

    private var nextRequestID: UInt32 = 1
    private var pending: [UInt32: PendingRequest] = [:]
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    private var inbound = [UInt8]()
    private var inboundStart = 0

    private var outbox: [Data] = []
    private var pumping = false

    private var readerTask: Task<Void, Never>?
    private var sweeperTask: Task<Void, Never>?

    private var versionWaiter: CheckedContinuation<UInt32, Error>?
    private var versionDeadline: ContinuousClock.Instant?
    /// SSH_FXP_VERSION carries no request id, so it cannot be registered before it is
    /// sent for the way every other reply is. It can therefore land while `connect` is
    /// still suspended inside the write of SSH_FXP_INIT, in which case there is no
    /// continuation to resume yet and the version has to be kept until there is. Losing
    /// it looked exactly like a server that never answered the handshake.
    private var receivedVersion: UInt32?

    private var deathError: SFTPError?
    private var handshakeDone = false

    public private(set) var serverVersion: UInt32 = 0
    /// Every extension name the server advertised, for the section 8.1 capability report.
    public private(set) var serverExtensionNames: [String] = []
    public private(set) var extensions: SFTPServerExtensions = []
    public private(set) var limits: SFTPLimits?

    private struct PendingRequest {
        let continuation: CheckedContinuation<SFTPReply, Error>
        let deadline: ContinuousClock.Instant
    }

    public init(stream: any ByteStream, configuration: Configuration = Configuration()) {
        self.stream = stream
        self.configuration = configuration
    }

    // MARK: Lifecycle

    /// Sends SSH_FXP_INIT, reads SSH_FXP_VERSION, records the extensions and, when the
    /// server offers it, asks for `limits@openssh.com`.
    public func connect() async throws {
        guard !handshakeDone else { return }
        startReader()
        startSweeper()

        var writer = SFTPPacketWriter(.initialize)
        writer.writeUInt32(3)
        versionDeadline = ContinuousClock.now.advanced(by: configuration.metadataDeadline)
        let version: UInt32
        do {
            try await stream.write(writer.finish())
            version = try await withCheckedThrowingContinuation { continuation in
                if let deathError {
                    continuation.resume(throwing: deathError)
                } else if let receivedVersion {
                    continuation.resume(returning: receivedVersion)
                } else {
                    versionWaiter = continuation
                }
            }
        } catch {
            die(with: (error as? SFTPError) ?? .connectionLost)
            throw error
        }
        versionDeadline = nil
        guard version >= 3 else {
            die(with: .badMessage)
            throw SFTPError.badMessage
        }
        serverVersion = version
        handshakeDone = true

        if extensions.contains(.limits) {
            // A server may advertise it and still refuse it; that is not fatal.
            limits = try? await requestLimits()
        }
        let names = serverExtensionNames.joined(separator: " ")
        log.info("SFTP v\(version, privacy: .public) ready; extensions: \(names, privacy: .public)")
    }

    /// True until the channel dies.
    public var isAlive: Bool { deathError == nil }

    /// Closes the channel and fails everything outstanding.
    public func shutdown() async {
        die(with: .connectionLost)
        stream.close()
    }

    private func startReader() {
        guard readerTask == nil else { return }
        let stream = self.stream
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let chunk = try await stream.read(upTo: 256 * 1024)
                    guard let self else { return }
                    if chunk.isEmpty {
                        await self.die(with: .connectionLost)
                        return
                    }
                    await self.ingest(chunk)
                } catch {
                    await self?.die(with: (error as? SFTPError) ?? .connectionLost)
                    return
                }
            }
        }
    }

    private func startSweeper() {
        guard sweeperTask == nil else { return }
        let tick = configuration.deadlineTick
        sweeperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard let self else { return }
                await self.expireOverdueRequests()
            }
        }
    }

    /// Section 6.2: a request that misses its deadline fails and reports its channel
    /// dead. The agent maps that to `.serverUnreachable` and drops the master (section
    /// 6.1); nothing here knows about masters.
    private func expireOverdueRequests() {
        let now = ContinuousClock.now
        if let versionDeadline, now >= versionDeadline {
            self.versionDeadline = nil
            let waiter = versionWaiter
            versionWaiter = nil
            waiter?.resume(throwing: SFTPError.deadlineExceeded)
            die(with: .connectionLost)
            return
        }
        guard pending.values.contains(where: { now >= $0.deadline }) else { return }
        let overdue = pending.filter { now >= $0.value.deadline }
        for (id, request) in overdue {
            pending.removeValue(forKey: id)
            request.continuation.resume(throwing: SFTPError.deadlineExceeded)
        }
        log.error("SFTP request deadline missed; the channel is dead")
        // The request that missed reports `.deadlineExceeded` to its own caller, which
        // the agent turns into `.serverUnreachable`; everything after it sees a dead
        // channel, which is what section 6.2 means by "reports its channel dead".
        die(with: .connectionLost)
    }

    private func die(with error: SFTPError) {
        guard deathError == nil else { return }
        deathError = error
        readerTask?.cancel()
        sweeperTask?.cancel()
        // The reader thread is parked in read(2) until the stream goes; closing it is
        // what actually ends the loop, cancellation only stops the next iteration.
        stream.close()
        let waiter = versionWaiter
        versionWaiter = nil
        waiter?.resume(throwing: error)
        let outstanding = pending
        pending.removeAll()
        for (_, request) in outstanding {
            request.continuation.resume(throwing: SFTPError.connectionLost)
        }
        let waiters = slotWaiters
        slotWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Inbound

    private func ingest(_ chunk: Data) {
        inbound.append(contentsOf: chunk)
        while true {
            let available = inbound.count - inboundStart
            guard available >= 4 else { break }
            let length =
                Int(inbound[inboundStart]) << 24 | Int(inbound[inboundStart + 1]) << 16
                | Int(inbound[inboundStart + 2]) << 8 | Int(inbound[inboundStart + 3])
            guard length > 0, length <= configuration.maximumPacketLength else {
                log.error("SFTP packet length \(length, privacy: .public) is out of range")
                die(with: .badMessage)
                return
            }
            guard available >= 4 + length else { break }
            let body = Array(inbound[(inboundStart + 4)..<(inboundStart + 4 + length)])
            inboundStart += 4 + length
            dispatch(body)
            if deathError != nil { return }
        }
        if inboundStart == inbound.count {
            inbound.removeAll(keepingCapacity: true)
            inboundStart = 0
        } else if inboundStart > 1024 * 1024 {
            inbound.removeFirst(inboundStart)
            inboundStart = 0
        }
    }

    private func dispatch(_ body: [UInt8]) {
        var reader = SFTPPacketReader(body)
        do {
            let rawType = try reader.readByte()
            guard let type = SFTPPacketType(rawValue: rawType) else {
                // An unknown reply type we cannot attribute to a request would desync the
                // pipeline, so it is fatal rather than ignored.
                throw SFTPError.badMessage
            }
            if type == .version {
                let version = try reader.readUInt32()
                var names: [String] = []
                var set: SFTPServerExtensions = []
                while reader.remaining > 0 {
                    let name = try reader.readText()
                    _ = try reader.readString()
                    names.append(name)
                    switch name {
                    case SFTPExtensionName.posixRename: set.insert(.posixRename)
                    case SFTPExtensionName.statvfs: set.insert(.statvfs)
                    case SFTPExtensionName.fsync: set.insert(.fsync)
                    case SFTPExtensionName.limits: set.insert(.limits)
                    case SFTPExtensionName.lsetstat: set.insert(.lsetstat)
                    default: break
                    }
                }
                serverExtensionNames = names
                extensions = set
                receivedVersion = version
                let waiter = versionWaiter
                versionWaiter = nil
                waiter?.resume(returning: version)
                return
            }

            let id = try reader.readUInt32()
            let reply: SFTPReply
            switch type {
            case .status:
                let rawCode = try reader.readUInt32()
                // Some servers stop after the code; both shapes are legal in the wild.
                let message = reader.remaining > 0 ? ((try? reader.readText()) ?? "") : ""
                let code = SFTPStatusCode(rawValue: rawCode) ?? .failure
                reply = .status(code, message)
            case .handle:
                reply = .handle(try reader.readString())
            case .data:
                reply = .data(try reader.readString())
            case .attrs:
                reply = .attributes(try reader.readAttributes())
            case .name:
                let count = try reader.readUInt32()
                var entries: [SFTPNameReplyEntry] = []
                entries.reserveCapacity(Int(min(count, 4096)))
                for _ in 0..<count {
                    let filename = try reader.readString()
                    let longname = try reader.readString()
                    let attributes = try reader.readAttributes()
                    entries.append(
                        SFTPNameReplyEntry(
                            filename: filename, longname: longname, attributes: attributes))
                }
                reply = .name(entries)
            case .extendedReply:
                reply = .extendedReply(Data(body[reader.consumedCount...]))
            default:
                throw SFTPError.badMessage
            }
            complete(id: id, with: .success(reply))
        } catch {
            log.error("SFTP reply could not be parsed; the channel is dead")
            die(with: .badMessage)
        }
    }

    private func complete(id: UInt32, with result: Result<SFTPReply, Error>) {
        guard let request = pending.removeValue(forKey: id) else {
            // A reply to a request that already failed its deadline. Dropping it is safe:
            // the channel is dead by then anyway.
            return
        }
        request.continuation.resume(with: result)
        releaseSlots()
    }

    private func releaseSlots() {
        while !slotWaiters.isEmpty && pending.count < configuration.maxOutstandingRequests {
            slotWaiters.removeFirst().resume()
        }
    }

    // MARK: Outbound

    private func allocateRequestID() -> UInt32 {
        let id = nextRequestID
        // 0 is reserved by nothing in particular, but skipping it keeps logs readable.
        nextRequestID = nextRequestID == UInt32.max ? 1 : nextRequestID + 1
        return id
    }

    private func acquireSlot() async {
        guard pending.count >= configuration.maxOutstandingRequests else { return }
        await withCheckedContinuation { continuation in
            slotWaiters.append(continuation)
        }
    }

    /// Enqueues a finished packet. The outbox preserves the order requests were made in
    /// and coalesces whatever piled up during one write into a single `write`, which is
    /// most of the difference between a pipelined transfer and a slow one.
    private func enqueue(_ packet: Data) {
        outbox.append(packet)
        guard !pumping else { return }
        pumping = true
        Task { await self.pump() }
    }

    private func pump() async {
        while !outbox.isEmpty {
            let batch = outbox
            outbox.removeAll(keepingCapacity: true)
            var joined = Data()
            joined.reserveCapacity(batch.reduce(0) { $0 + $1.count })
            for packet in batch { joined.append(packet) }
            do {
                try await stream.write(joined)
            } catch {
                pumping = false
                die(with: .connectionLost)
                return
            }
        }
        pumping = false
    }

    /// The one place a request goes out and a reply comes back.
    private func send(
        _ writer: SFTPPacketWriter, id: UInt32, deadline: Duration
    ) async throws -> SFTPReply {
        if let deathError { throw deathError }
        await acquireSlot()
        if let deathError { throw deathError }
        let packet = writer.finish()
        let instant = ContinuousClock.now.advanced(by: deadline)
        return try await withCheckedThrowingContinuation { continuation in
            // Registering before the packet reaches the outbox is what makes a reply
            // that arrives during the write impossible to lose.
            pending[id] = PendingRequest(continuation: continuation, deadline: instant)
            enqueue(packet)
        }
    }

    private func metadataRequest(_ type: SFTPPacketType, _ build: (inout SFTPPacketWriter) -> Void)
        async throws -> SFTPReply
    {
        let id = allocateRequestID()
        var writer = SFTPPacketWriter(type, requestID: id)
        build(&writer)
        return try await send(writer, id: id, deadline: configuration.metadataDeadline)
    }

    private func transferDeadline(forBytes bytes: Int) -> Duration {
        configuration.transferBaseDeadline
            + .seconds(Double(bytes) / Double(max(1, configuration.transferBytesPerSecond)))
    }

    // MARK: Metadata operations

    public func realpath(_ path: SFTPServerPath) async throws -> Data {
        let reply = try await metadataRequest(.realpath) { $0.writeString(path.bytes) }
        guard let first = try reply.expectNames().first else { throw SFTPError.badMessage }
        return first.filename
    }

    public func lstat(_ path: SFTPServerPath) async throws -> SFTPFileAttributes {
        let reply = try await metadataRequest(.lstat) { $0.writeString(path.bytes) }
        return try reply.expectAttributes().fileAttributes()
    }

    public func stat(_ path: SFTPServerPath) async throws -> SFTPFileAttributes {
        let reply = try await metadataRequest(.stat) { $0.writeString(path.bytes) }
        return try reply.expectAttributes().fileAttributes()
    }

    public func fstat(_ handle: SFTPFileHandle) async throws -> SFTPFileAttributes {
        let reply = try await metadataRequest(.fstat) { $0.writeString(handle.raw) }
        return try reply.expectAttributes().fileAttributes()
    }

    public func setstat(_ path: SFTPServerPath, _ attributes: SFTPSettableAttributes) async throws {
        let reply = try await metadataRequest(.setstat) {
            $0.writeString(path.bytes)
            $0.writeAttributes(attributes)
        }
        try reply.expectOK()
    }

    public func fsetstat(_ handle: SFTPFileHandle, _ attributes: SFTPSettableAttributes) async throws
    {
        let reply = try await metadataRequest(.fsetstat) {
            $0.writeString(handle.raw)
            $0.writeAttributes(attributes)
        }
        try reply.expectOK()
    }

    /// `lsetstat@openssh.com`: setstat that does not follow a symlink. Falls back to
    /// nothing: the caller decides whether a plain setstat is acceptable.
    public func lsetstat(_ path: SFTPServerPath, _ attributes: SFTPSettableAttributes) async throws {
        guard extensions.contains(.lsetstat) else { throw SFTPError.operationUnsupported }
        let reply = try await metadataRequest(.extended) {
            $0.writeString(SFTPExtensionName.lsetstat)
            $0.writeString(path.bytes)
            $0.writeAttributes(attributes)
        }
        try reply.expectOK()
    }

    public func mkdir(_ path: SFTPServerPath, mode: UInt32) async throws {
        let reply = try await metadataRequest(.mkdir) {
            $0.writeString(path.bytes)
            $0.writeAttributes(SFTPSettableAttributes(permissions: mode))
        }
        try reply.expectOK()
    }

    public func rmdir(_ path: SFTPServerPath) async throws {
        let reply = try await metadataRequest(.rmdir) { $0.writeString(path.bytes) }
        try reply.expectOK()
    }

    public func remove(_ path: SFTPServerPath) async throws {
        let reply = try await metadataRequest(.remove) { $0.writeString(path.bytes) }
        try reply.expectOK()
    }

    /// The plain, non-overwriting rename of section 5.5.
    public func rename(_ source: SFTPServerPath, to destination: SFTPServerPath) async throws {
        let reply = try await metadataRequest(.rename) {
            $0.writeString(source.bytes)
            $0.writeString(destination.bytes)
        }
        try reply.expectOK()
    }

    /// `posix-rename@openssh.com`: overwrites the destination atomically.
    public func posixRename(_ source: SFTPServerPath, to destination: SFTPServerPath) async throws {
        guard extensions.contains(.posixRename) else { throw SFTPError.operationUnsupported }
        let reply = try await metadataRequest(.extended) {
            $0.writeString(SFTPExtensionName.posixRename)
            $0.writeString(source.bytes)
            $0.writeString(destination.bytes)
        }
        try reply.expectOK()
    }

    public func readlink(_ path: SFTPServerPath) async throws -> Data {
        let reply = try await metadataRequest(.readlink) { $0.writeString(path.bytes) }
        guard let first = try reply.expectNames().first else { throw SFTPError.badMessage }
        return first.filename
    }

    /// Section 6.2: OpenSSH's SSH2_FXP_SYMLINK takes `targetpath` first and `linkpath`
    /// second, the opposite order from the draft that defines it. A client that talks to
    /// `sftp-server` has to match OpenSSH, so that is what goes on the wire here, and it
    /// is the one place in this file where the draft is deliberately disobeyed.
    public func symlink(target: Data, at linkPath: SFTPServerPath) async throws {
        let reply = try await metadataRequest(.symlink) {
            $0.writeString(target)
            $0.writeString(linkPath.bytes)
        }
        try reply.expectOK()
    }

    /// `statvfs@openssh.com`. This is the second question section 6.2 says to ask when a
    /// bare FAILURE might have been ENOSPC or EDQUOT.
    public func statvfs(_ path: SFTPServerPath) async throws -> SFTPFilesystemStats {
        guard extensions.contains(.statvfs) else { throw SFTPError.operationUnsupported }
        let reply = try await metadataRequest(.extended) {
            $0.writeString(SFTPExtensionName.statvfs)
            $0.writeString(path.bytes)
        }
        var reader = SFTPPacketReader(try reply.expectExtendedReply())
        let blockSize = try reader.readUInt64()
        _ = try reader.readUInt64()  // f_frsize
        let totalBlocks = try reader.readUInt64()
        _ = try reader.readUInt64()  // f_bfree
        let availableBlocks = try reader.readUInt64()
        let totalInodes = try reader.readUInt64()
        _ = try reader.readUInt64()  // f_ffree
        let availableInodes = try reader.readUInt64()
        return SFTPFilesystemStats(
            blockSize: blockSize, totalBlocks: totalBlocks, availableBlocks: availableBlocks,
            totalInodes: totalInodes, availableInodes: availableInodes)
    }

    /// `fsync@openssh.com`, on an open handle. Used at the end of an upload so the
    /// rename that follows cannot promote a half-written file (section 5.5).
    public func fsync(_ handle: SFTPFileHandle) async throws {
        guard extensions.contains(.fsync) else { throw SFTPError.operationUnsupported }
        let reply = try await metadataRequest(.extended) {
            $0.writeString(SFTPExtensionName.fsync)
            $0.writeString(handle.raw)
        }
        try reply.expectOK()
    }

    private func requestLimits() async throws -> SFTPLimits {
        let reply = try await metadataRequest(.extended) {
            $0.writeString(SFTPExtensionName.limits)
        }
        var reader = SFTPPacketReader(try reply.expectExtendedReply())
        return SFTPLimits(
            maxPacketLength: try reader.readUInt64(),
            maxReadLength: try reader.readUInt64(),
            maxWriteLength: try reader.readUInt64(),
            maxOpenHandles: try reader.readUInt64())
    }

    // MARK: Handles

    public func open(
        _ path: SFTPServerPath, flags: SFTPOpenFlags,
        attributes: SFTPSettableAttributes = .none
    ) async throws -> SFTPFileHandle {
        let reply = try await metadataRequest(.open) {
            $0.writeString(path.bytes)
            $0.writeUInt32(flags.rawValue)
            $0.writeAttributes(attributes)
        }
        return SFTPFileHandle(raw: try reply.expectHandle())
    }

    public func opendir(_ path: SFTPServerPath) async throws -> SFTPFileHandle {
        let reply = try await metadataRequest(.opendir) { $0.writeString(path.bytes) }
        return SFTPFileHandle(raw: try reply.expectHandle())
    }

    public func close(_ handle: SFTPFileHandle) async throws {
        let reply = try await metadataRequest(.close) { $0.writeString(handle.raw) }
        try reply.expectOK()
    }

    // MARK: Directory listing

    /// One `readdir` page. `nil` means the server said EOF.
    private func readdirPage(_ handle: SFTPFileHandle) async throws -> [SFTPNameReplyEntry]? {
        let reply = try await metadataRequest(.readdir) { $0.writeString(handle.raw) }
        if case .status(let code, let message) = reply {
            if code == .endOfFile { return nil }
            if let error = code.asError(message: message) { throw error }
        }
        return try reply.expectNames()
    }

    /// The whole of a directory. Pages are asked for back to back (section 6.2); their
    /// order does not matter because they are merged, and `.` and `..` are dropped here
    /// rather than by every caller.
    public func listDirectory(_ path: SFTPServerPath) async throws -> [SFTPDirectoryEntry] {
        let handle = try await opendir(path)
        do {
            let entries = try await pagedReaddir(handle)
            try? await close(handle)
            return entries
        } catch {
            try? await close(handle)
            throw error
        }
    }

    private func pagedReaddir(_ handle: SFTPFileHandle) async throws -> [SFTPDirectoryEntry] {
        let depth = max(1, configuration.readdirPipelineDepth)
        var out: [SFTPDirectoryEntry] = []
        var finished = false
        try await withThrowingTaskGroup(of: [SFTPNameReplyEntry]?.self) { group in
            var inFlight = 0
            for _ in 0..<depth {
                group.addTask { try await self.readdirPage(handle) }
                inFlight += 1
            }
            while inFlight > 0 {
                guard let page = try await group.next() else { break }
                inFlight -= 1
                guard let page else {
                    finished = true
                    continue
                }
                for entry in page {
                    if entry.filename == Data(".".utf8) || entry.filename == Data("..".utf8) {
                        continue
                    }
                    out.append(
                        SFTPDirectoryEntry(
                            name: entry.filename,
                            attributes: entry.attributes.fileAttributes(
                                fallbackType: entry.typeFromLongname)))
                }
                if !finished {
                    group.addTask { try await self.readdirPage(handle) }
                    inFlight += 1
                }
            }
        }
        return out
    }

    // MARK: Transfers

    private struct ChunkResult: Sendable {
        let offset: UInt64
        let requested: Int
        let data: Data
        let atEnd: Bool
    }

    private var readChunkSize: Int {
        guard let limits, limits.maxReadLength > 0 else { return configuration.fallbackChunkSize }
        return Int(min(limits.maxReadLength, 255 * 1024))
    }

    private var writeChunkSize: Int {
        guard let limits, limits.maxWriteLength > 0 else { return configuration.fallbackChunkSize }
        var size = Int(min(limits.maxWriteLength, 255 * 1024))
        if limits.maxPacketLength > 1024 {
            size = min(size, Int(limits.maxPacketLength) - 1024)
        }
        return max(1024, size)
    }

    private func readChunk(handle: SFTPFileHandle, offset: UInt64, length: Int) async throws
        -> ChunkResult
    {
        let id = allocateRequestID()
        var writer = SFTPPacketWriter(.read, requestID: id)
        writer.writeString(handle.raw)
        writer.writeUInt64(offset)
        writer.writeUInt32(UInt32(length))
        let reply = try await send(writer, id: id, deadline: transferDeadline(forBytes: length))
        switch reply {
        case .data(let data):
            return ChunkResult(offset: offset, requested: length, data: data, atEnd: false)
        case .status(let code, let message):
            if code == .endOfFile {
                return ChunkResult(offset: offset, requested: length, data: Data(), atEnd: true)
            }
            throw code.asError(message: message) ?? SFTPError.badMessage
        default:
            throw SFTPError.badMessage
        }
    }

    /// Pipelined read. `length` of nil means "to end of file".
    ///
    /// `receiver` is called with the absolute offset of each chunk, in whatever order the
    /// chunks land: the window is what bounds memory, so a caller streaming to disk never
    /// holds the whole file. Returns the number of bytes delivered.
    @discardableResult
    public func read(
        handle: SFTPFileHandle,
        offset: UInt64,
        length: UInt64?,
        receiver: (UInt64, Data) async -> Void
    ) async throws -> UInt64 {
        let chunk = readChunkSize
        let window = max(1, configuration.windowRequests)
        let end: UInt64? = length.map { offset + $0 }
        var nextOffset = offset
        var endOfFileAt: UInt64?
        var delivered: UInt64 = 0

        func nextRequest() -> (UInt64, Int)? {
            if let end, nextOffset >= end { return nil }
            if let endOfFileAt, nextOffset >= endOfFileAt { return nil }
            var size = chunk
            if let end { size = Int(min(UInt64(size), end - nextOffset)) }
            guard size > 0 else { return nil }
            let start = nextOffset
            nextOffset += UInt64(size)
            return (start, size)
        }

        try await withThrowingTaskGroup(of: ChunkResult.self) { group in
            var inFlight = 0
            while inFlight < window, let request = nextRequest() {
                group.addTask {
                    try await self.readChunk(
                        handle: handle, offset: request.0, length: request.1)
                }
                inFlight += 1
            }
            while inFlight > 0 {
                guard let result = try await group.next() else { break }
                inFlight -= 1
                if result.atEnd {
                    endOfFileAt = min(endOfFileAt ?? UInt64.max, result.offset)
                }
                if !result.data.isEmpty {
                    delivered += UInt64(result.data.count)
                    await receiver(result.offset, result.data)
                    // A short read is legal before EOF; ask for the rest before anything
                    // new, so the gap cannot be mistaken for the end of the file.
                    if result.data.count < result.requested {
                        let resumeOffset = result.offset + UInt64(result.data.count)
                        let resumeLength = result.requested - result.data.count
                        group.addTask {
                            try await self.readChunk(
                                handle: handle, offset: resumeOffset, length: resumeLength)
                        }
                        inFlight += 1
                        continue
                    }
                }
                while inFlight < window, let request = nextRequest() {
                    group.addTask {
                        try await self.readChunk(
                            handle: handle, offset: request.0, length: request.1)
                    }
                    inFlight += 1
                }
            }
        }
        return delivered
    }

    /// Pipelined read into one `Data`, in offset order.
    public func readAll(handle: SFTPFileHandle, offset: UInt64, length: UInt64?) async throws -> Data
    {
        let box = ChunkBox()
        try await read(handle: handle, offset: offset, length: length) { chunkOffset, data in
            box.add(offset: chunkOffset, data: data)
        }
        return box.assembled()
    }

    private func writeChunk(handle: SFTPFileHandle, offset: UInt64, data: Data) async throws {
        let id = allocateRequestID()
        var writer = SFTPPacketWriter(.write, requestID: id)
        writer.writeString(handle.raw)
        writer.writeUInt64(offset)
        writer.writeString(data)
        let reply = try await send(
            writer, id: id, deadline: transferDeadline(forBytes: data.count))
        try reply.expectOK()
    }

    /// Pipelined write, `windowRequests` chunks in flight.
    public func write(handle: SFTPFileHandle, offset: UInt64, data: Data) async throws {
        let chunk = writeChunkSize
        let window = max(1, configuration.windowRequests)
        var cursor = 0

        func nextRequest() -> (UInt64, Data)? {
            guard cursor < data.count else { return nil }
            let size = min(chunk, data.count - cursor)
            let start = data.index(data.startIndex, offsetBy: cursor)
            let piece = Data(data[start..<data.index(start, offsetBy: size)])
            let at = offset + UInt64(cursor)
            cursor += size
            return (at, piece)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var inFlight = 0
            while inFlight < window, let request = nextRequest() {
                group.addTask {
                    try await self.writeChunk(
                        handle: handle, offset: request.0, data: request.1)
                }
                inFlight += 1
            }
            while inFlight > 0 {
                _ = try await group.next()
                inFlight -= 1
                while inFlight < window, let request = nextRequest() {
                    group.addTask {
                        try await self.writeChunk(
                            handle: handle, offset: request.0, data: request.1)
                    }
                    inFlight += 1
                }
            }
        }
    }

    // MARK: Test seams

    /// How many requests are outstanding right now. The pipelining tests assert on this.
    var outstandingRequestCount: Int { pending.count }
}

/// Collects out-of-order chunks and puts them back in offset order.
private final class ChunkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pieces: [(UInt64, Data)] = []

    func add(offset: UInt64, data: Data) {
        lock.lock()
        pieces.append((offset, data))
        lock.unlock()
    }

    func assembled() -> Data {
        lock.lock()
        let sorted = pieces.sorted { $0.0 < $1.0 }
        lock.unlock()
        var out = Data()
        out.reserveCapacity(sorted.reduce(0) { $0 + $1.1.count })
        for (_, data) in sorted { out.append(data) }
        return out
    }
}
