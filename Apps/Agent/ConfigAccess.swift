import Foundation
import Config
import Logging

/// `config.json`'s file I/O, kept off every actor's executor.
///
/// `Data.write(to:options: .atomic)` inside the app-group container is not a quick call.
/// With a File Provider domain present, fileproviderd coordinates on that container, and
/// during S1 one such write blocked for about three minutes
/// (`docs/spikes/results.md`, 2026-09-04). A blocking call made from inside an actor holds
/// that actor's executor for its whole duration, so every other call to `DomainManager`
/// queued behind it and the CLI reported the agent unreachable for commands the agent had
/// never begun. The blocking half therefore runs on a serial queue of its own, and the
/// actor only ever suspends on it.
///
/// The queue is serial, which is the serialisation `ConfigStore` documents it needs.
final class ConfigAccess: @unchecked Sendable {
    private let store: ConfigStore
    private let queue = DispatchQueue(label: "org.shirls.sshdrive.config", qos: .userInitiated)

    init(store: ConfigStore) {
        self.store = store
    }

    convenience init() throws {
        self.init(store: try ConfigStore())
    }

    func load() async throws -> ConfigFile {
        try await perform { try $0.load() }
    }

    func location(named name: String) async throws -> Location {
        try await perform { try $0.location(named: name) }
    }

    @discardableResult
    func mutate(_ body: @escaping (inout ConfigFile) throws -> Void) async throws -> ConfigFile {
        try await perform { try $0.mutate(body) }
    }

    private func perform<T>(_ body: @escaping (ConfigStore) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            // `self`, not `store`: this class is @unchecked Sendable because the queue is
            // the serialisation, and capturing the store directly would warn.
            queue.async { [self] in
                do {
                    continuation.resume(returning: try body(store))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
