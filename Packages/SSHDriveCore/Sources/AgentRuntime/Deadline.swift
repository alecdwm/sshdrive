import Foundation
import XPCProtocols

/// A bounded wait for a call that has no timeout of its own.
///
/// `NSFileProviderManager.remove(domain)` on a user-disabled domain did not return within
/// three minutes when it was measured on 2026-09-04, and neither the CLI nor the extension
/// has any way to tell "still working" from "wedged". Every call the agent makes into File
/// Provider therefore runs under a deadline, so the caller gets a sentence naming the
/// operation instead of the CLI's own timeout and a wrong "cannot reach the agent".
///
/// The stalled call is abandoned rather than killed: `NSFileProviderManager`'s completion
/// handlers do not observe cancellation, so the child task is left to finish on its own.
/// It holds no actor, which is the point of doing this off the actor's executor.
public enum Deadline {
    /// How long the agent waits on one File Provider call. Shorter than the CLI's own
    /// 30 s wait, so the CLI receives this error rather than timing out itself.
    static let fileProviderSeconds: Double = 20

    /// How long `sshdrive status` waits for one location's section. Well inside the CLI's
    /// own 120 s overall timeout, so a wedged location costs the user a
    /// note on that row rather than the whole command: a report about four locations is
    /// worth having when the fourth is the one that has gone.
    public static let statusSeconds: Double = 20

    public struct Expired: Error, LocalizedError {
        public let operation: String
        public let seconds: Double
        public var errorDescription: String? {
            "\(operation) did not complete within \(Int(seconds)) seconds. "
                + "This is usually a File Provider domain the system has disabled: check "
                + "System Settings > General > Login Items & Extensions > File Providers."
        }
        /// The short form a `status` row carries in place of its sections, where the
        /// sentence above would be a paragraph in the middle of a table.
        public var shortDescription: String {
            "\(operation) did not answer within \(Int(seconds)) s"
        }
    }

    /// The timer is a sleep on `clock`, so a scenario's driven clock decides when it
    /// fires. A cancelled sleep returns rather than throwing, so the timer checks for
    /// cancellation itself: a cancelled caller sees `CancellationError`, never `Expired`.
    static func run<T: Sendable>(
        _ operation: String,
        seconds: Double = fileProviderSeconds,
        clock: any AgentClock = SystemAgentClock(),
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                await clock.sleep(seconds: seconds)
                try Task.checkCancellation()
                throw Expired(operation: operation, seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw Expired(operation: operation, seconds: seconds)
            }
            return first
        }
    }

    /// The same bound, with the work abandoned rather than awaited when the timer wins.
    ///
    /// `status` runs one of these per location, on the agent's clock, so a scenario sees
    /// a stuck location print its note without living through twenty real seconds
    /// (docs/design/testing.md: there is no real sleeping in the suite).
    ///
    /// It is not a task group, and that is deliberate: a task group awaits its children
    /// before it returns, so a section wedged on something that does not observe
    /// cancellation would hold the whole call open past its bound. The two tasks are
    /// unstructured and the loser is abandoned.
    static func race<T: Sendable>(
        _ operation: String, seconds: Double, clock: any AgentClock,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = RaceBox<T>()
        let work = Task {
            do { await box.finish(.success(try await body())) } catch {
                await box.finish(.failure(error))
            }
        }
        let timer = Task {
            await clock.sleep(seconds: seconds)
            await box.finish(.failure(Expired(operation: operation, seconds: seconds)))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await box.take().get()
    }

    /// Whichever of the two finished first, once.
    private actor RaceBox<T: Sendable> {
        private var result: Result<T, Error>?
        private var waiter: CheckedContinuation<Result<T, Error>, Never>?

        func finish(_ value: Result<T, Error>) {
            guard result == nil else { return }
            result = value
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: value)
            }
        }

        func take() async -> Result<T, Error> {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    waiter = continuation
                }
            }
        }
    }
}
