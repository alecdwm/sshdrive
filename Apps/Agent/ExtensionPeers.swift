import Foundation
import XPCProtocols
import Logging

/// Every live File Provider extension connection, so the agent can reach the readers.
///
/// DESIGN.md section 5.3's restore has one step that needs this: when SQLite cannot open
/// the index at all, the agent truncates the database and its `-wal`/`-shm` sidecars under
/// their own inodes, and **the reader has to close first** - it holds the `-shm` mapped,
/// and truncating a mapped file under a live process faults it on its next access. The
/// callback interface for that (`closeIndexReader` / `reopenIndexReader`) is already on
/// every extension connection; what was missing was a way to find those connections from
/// outside the one that happens to be making the current call.
///
/// Weak references and no ownership: the listener registers a connection when it accepts
/// it and drops it in the invalidation handler, and a connection that dies in between is
/// simply gone from the table.
final class ExtensionPeers: @unchecked Sendable {
    static let shared = ExtensionPeers()

    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    func add(_ connection: NSXPCConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
    }

    func remove(_ connection: NSXPCConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }

    private var live: [NSXPCConnection] {
        lock.lock(); defer { lock.unlock() }
        return Array(connections.values)
    }

    /// Asks every reader to close and waits for their replies, bounded.
    ///
    /// An extension that is not running cannot be waiting on anything, so a peer that does
    /// not answer inside the deadline is not a reason to abandon the restore - the agent
    /// goes ahead. What it must never do is truncate *before* asking (section 5.3).
    func closeReaders(timeout: TimeInterval = 20) async {
        let peers = live
        guard !peers.isEmpty else { return }
        Log.agent.notice(
            "asking \(peers.count, privacy: .public) extension reader(s) to close before a restore")
        await withTaskGroup(of: Void.self) { group in
            for connection in peers {
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let settled = Settled()
                        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                            Log.agent.error(
                                "closeIndexReader failed: \(error, privacy: .public)")
                            if settled.claim() { continuation.resume() }
                        } as? SSHDriveExtensionProtocol
                        guard let proxy else {
                            if settled.claim() { continuation.resume() }
                            return
                        }
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                            if settled.claim() { continuation.resume() }
                        }
                        proxy.closeIndexReader { if settled.claim() { continuation.resume() } }
                    }
                }
            }
        }
    }

    func reopenReaders() {
        for connection in live {
            (connection.remoteObjectProxyWithErrorHandler { error in
                Log.agent.error("reopenIndexReader failed: \(error, privacy: .public)")
            } as? SSHDriveExtensionProtocol)?.reopenIndexReader()
        }
    }

    /// One-shot latch: the reply, the error handler and the deadline all race, and a
    /// continuation resumed twice is a crash.
    private final class Settled: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
