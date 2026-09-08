import Foundation
import XPCProtocols

/// A bounded wait for a call that has no timeout of its own.
///
/// `NSFileProviderManager.remove(domain)` on a user-disabled domain did not return within
/// three minutes during S1 (`docs/spikes/results.md`, 2026-09-04), and neither the CLI nor
/// the extension has any way to tell "still working" from "wedged". Every call the agent
/// makes into File Provider therefore runs under a deadline, so the caller gets a sentence
/// naming the operation instead of the CLI's own timeout and a wrong "cannot reach the
/// agent".
///
/// The stalled call is abandoned rather than killed: `NSFileProviderManager`'s completion
/// handlers do not observe cancellation, so the child task is left to finish on its own.
/// It holds no actor, which is the point of doing this off the actor's executor.
enum Deadline {
    /// How long the agent waits on one File Provider call. Shorter than the CLI's own
    /// 30 s wait, so the CLI receives this error rather than timing out itself.
    static let fileProviderSeconds: Double = 20

    struct Expired: Error, LocalizedError {
        let operation: String
        let seconds: Double
        var errorDescription: String? {
            "\(operation) did not complete within \(Int(seconds)) seconds. "
                + "This is usually a File Provider domain the system has disabled: check "
                + "System Settings > General > Login Items & Extensions > File Providers."
        }
    }

    static func run<T: Sendable>(
        _ operation: String,
        seconds: Double = fileProviderSeconds,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Expired(operation: operation, seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw Expired(operation: operation, seconds: seconds)
            }
            return first
        }
    }
}
