import Foundation
import SFTP
import Logging

/// DESIGN.md section 6.2's transfer scheduler.
///
/// "Transfers are scheduled, not queued." Every transfer of a location runs on the bulk
/// channel, and SFTP requests are independent per handle, so transfers interleave: the
/// agent runs at most **four** at once per location, splits the pipelined window between
/// them, and holds the rest with their XPC calls open.
///
/// The four are chosen from two classes. **Foreground** comes first: a `fetchContents`
/// whose `NSFileProviderRequest` is a file-viewer request or is not a system request (an
/// app or the user opening the file), every `createItem` and `modifyItem` upload, and
/// every `fetchPartialContents`. **Background** - the eager downloads of a kept subtree
/// and anything else the system issues on its own - starts only while no foreground
/// transfer is waiting, and a running one is never pre-empted.
///
/// The queue is bounded by the six-fetch ceiling S6 measured (2026-09-04, macOS 26.4: 38
/// transfers ran in strict batches of six): four running plus at most two waiting is
/// everything the agent ever holds. A seventh arrival is not refused - refusing a request
/// the system did make would fail a user's open for a ceiling that is an observation, not
/// a contract - it is admitted and counted, and `overCeilingAdmissions` is what `status`
/// shows if the observation ever stops holding.
public actor TransferScheduler {

    /// Which of section 6.2's two classes a transfer belongs to, plus the metadata class
    /// that only exists on a `MaxSessions 2` location, where the same scheduler runs on
    /// the metadata channel and metadata requests are served ahead of both.
    public enum Kind: Sendable {
        case metadata
        case foreground
        case background

        public var isTransfer: Bool { self != .metadata }
    }

    public struct Statistics: Sendable {
        public var running = 0
        public var waitingForeground = 0
        public var waitingBackground = 0
        public var peakRunning = 0
        public var peakHeld = 0
        public var admitted = 0
        public var cancelled = 0
        public var overCeilingAdmissions = 0
        public var windowShare = 0
    }

    /// Section 6.2: at most four at once per location.
    public static let maximumRunning = 4
    /// S6's ceiling: four running plus at most two waiting.
    public static let ceiling = 6
    /// The client's own pipeline depth (section 6.2). The share is this divided between
    /// the running transfers, never below two, so a fourth transfer still pipelines.
    public static let pipelineDepth = 16

    private struct Waiter {
        let transferID: String
        let kind: Kind
        let continuation: CheckedContinuation<Void, Error>
    }

    private let locationID: String
    /// Set on a `MaxSessions 2` location: transfers share the metadata channel, so their
    /// share of the pipeline is halved to leave the channel's request slots free for the
    /// metadata calls that are served ahead of them (section 6.2).
    private var sharesMetadataChannel: Bool

    private var waiting: [Waiter] = []
    private var running: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var cancelledIDs: Set<String> = []
    private var statistics = Statistics()

    public init(locationID: String, sharesMetadataChannel: Bool = false) {
        self.locationID = locationID
        self.sharesMetadataChannel = sharesMetadataChannel
    }

    public func setSharesMetadataChannel(_ shared: Bool) {
        sharesMetadataChannel = shared
    }

    /// The window share a transfer admitted right now would get: the pipeline depth split
    /// between everything running, never below two.
    public var windowShare: Int {
        let depth = sharesMetadataChannel ? TransferScheduler.pipelineDepth / 2 : TransferScheduler.pipelineDepth
        return max(2, depth / max(1, running.count))
    }

    public func stats() -> Statistics {
        var out = statistics
        out.running = running.count
        out.waitingForeground = waiting.filter { $0.kind == .foreground }.count
        out.waitingBackground = waiting.filter { $0.kind == .background }.count
        out.windowShare = windowShare
        return out
    }

    /// Runs `body` under the scheduler. `body` is handed its share of the pipelined
    /// window. The call suspends - with its XPC call held open, which is the point - until
    /// a slot is free.
    ///
    /// A metadata call is never queued: on a `MaxSessions 2` location it is what has to
    /// get through while four transfers are running, and on every other location it is on
    /// a channel of its own and the scheduler is not in its way at all.
    public func run<T: Sendable>(
        transferID: String,
        kind: Kind,
        body: @escaping @Sendable (Int) async throws -> T
    ) async throws -> T {
        guard kind.isTransfer else { return try await body(windowShare) }

        try await admit(transferID: transferID, kind: kind)
        defer { finish(transferID: transferID) }

        if cancelledIDs.contains(transferID) {
            cancelledIDs.remove(transferID)
            throw SFTPError.cancelled
        }

        let share = windowShare
        let box = ResultBox<T>()
        // The Task is what `cancel(transferID:)` reaches: cancelling it makes every
        // SFTP request the transfer has not yet sent throw `.cancelled` (section 5.2,
        // section 6.2), and the transport removes any temp file it had started.
        // Detached on purpose: a plain `Task {}` inside an actor inherits that actor's
        // executor, and four transfers would then run one after another on the
        // scheduler itself rather than interleaving on the bulk channel.
        let task = Task.detached { [box] in
            do {
                box.set(.success(try await body(share)))
            } catch is CancellationError {
                // Whatever inside the transfer noticed the cancel first - the wire
                // client, or a `Task.sleep` in a deadline race - the caller is owed the
                // transport's own error, not Swift's, because that is what the extension
                // maps to an `NSFileProviderError` (sections 5.2, 6.2).
                box.set(.failure(SFTPError.cancelled))
            } catch {
                box.set(.failure(error))
            }
        }
        tasks[transferID] = task
        await task.value
        tasks.removeValue(forKey: transferID)
        guard let result = box.value else { throw SFTPError.cancelled }
        return try result.get()
    }

    /// Cancelling the extension's `Progress`, or its connection going away (section 5.2).
    /// A transfer still waiting is dropped from the queue; a running one has its Task
    /// cancelled and abandons its SFTP requests.
    public func cancel(transferID: String) {
        statistics.cancelled += 1
        if let index = waiting.firstIndex(where: { $0.transferID == transferID }) {
            let waiter = waiting.remove(at: index)
            waiter.continuation.resume(throwing: SFTPError.cancelled)
            return
        }
        if let task = tasks[transferID] {
            task.cancel()
            return
        }
        // The cancel raced the admission: remember it so the transfer throws the moment
        // it is admitted rather than downloading a file nobody is waiting for.
        cancelledIDs.insert(transferID)
    }

    public func isCancelled(transferID: String) -> Bool { cancelledIDs.contains(transferID) }

    // MARK: Admission

    private func admit(transferID: String, kind: Kind) async throws {
        let held = running.count + waiting.count
        if held >= TransferScheduler.ceiling {
            statistics.overCeilingAdmissions += 1
            Log.agent.notice(
                "\(self.locationID, privacy: .public): \(held, privacy: .public) transfers held, above the six-fetch ceiling"
            )
        }
        if canStart(kind: kind) {
            start(transferID: transferID)
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(Waiter(transferID: transferID, kind: kind, continuation: continuation))
            statistics.peakHeld = max(statistics.peakHeld, running.count + waiting.count)
            Log.agent.info(
                "\(self.locationID, privacy: .public): transfer queued (\(self.running.count, privacy: .public) running, \(self.waiting.count, privacy: .public) waiting)"
            )
        }
    }

    /// Background starts only while no foreground transfer is waiting. Nothing else has
    /// to be checked: a free slot with a non-empty queue cannot exist, because `pump`
    /// drains the queue inside the same actor step that freed the slot.
    private func canStart(kind: Kind) -> Bool {
        guard running.count < TransferScheduler.maximumRunning else { return false }
        guard kind == .background else { return true }
        return !waiting.contains { $0.kind == .foreground }
    }

    private func start(transferID: String) {
        running.insert(transferID)
        statistics.admitted += 1
        statistics.peakRunning = max(statistics.peakRunning, running.count)
        statistics.peakHeld = max(statistics.peakHeld, running.count + waiting.count)
    }

    private func finish(transferID: String) {
        running.remove(transferID)
        tasks.removeValue(forKey: transferID)
        cancelledIDs.remove(transferID)
        pump()
    }

    /// Foreground first, then background, and only while no foreground is waiting. A
    /// running transfer is never pre-empted, so this only ever fills freed slots.
    private func pump() {
        while running.count < TransferScheduler.maximumRunning, !waiting.isEmpty {
            // Foreground first; a background waiter is only reached when there is no
            // foreground waiter at all, which is exactly section 6.2's rule.
            let index = waiting.firstIndex(where: { $0.kind == .foreground })
                ?? waiting.firstIndex(where: { $0.kind == .background })
            guard let index else { return }
            let waiter = waiting.remove(at: index)
            start(transferID: waiter.transferID)
            waiter.continuation.resume()
        }
    }
}

/// A box for a Task's result, so the scheduler can await a cancellable child Task and
/// still rethrow what it threw. `Task<T, Error>.value` would do it, but a Task the
/// scheduler cancels reports `CancellationError` rather than the transport's own
/// `.cancelled`, and the difference reaches the user as the wrong Finder error.
public final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?

    public func set(_ result: Result<T, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    public var value: Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
