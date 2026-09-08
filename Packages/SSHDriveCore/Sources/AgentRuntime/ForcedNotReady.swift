import Foundation

/// `sshdrive debug reader <name> --not-ready <seconds>`: while this is in the future the
/// agent answers `indexReady` no, so the extension's readiness race of DESIGN.md
/// section 5.2 can be reproduced on purpose rather than waited for.
///
/// Process-lifetime only, and a decision rather than an adapter: the XPC method in
/// `Apps/Agent` asks it and does nothing else with the answer. It is what suite A's
/// `A3` drives on the extension side.
public final class ForcedNotReady: @unchecked Sendable {
    public static let shared = ForcedNotReady()

    private let lock = NSLock()
    private var until: [String: Date] = [:]

    public init() {}

    public func set(domainIdentifier: String, seconds: TimeInterval) {
        lock.lock()
        until[domainIdentifier] = Date().addingTimeInterval(seconds)
        lock.unlock()
    }

    public func isActive(_ domainIdentifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let deadline = until[domainIdentifier] else { return false }
        return deadline > Date()
    }
}
