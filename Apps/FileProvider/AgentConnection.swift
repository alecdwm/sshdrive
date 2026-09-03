import FileProvider
import Foundation
import XPCProtocols
import Logging

/// The extension's XPC client (DESIGN.md section 5.2).
///
/// The extension connects to the agent's mach service on first use. launchd starts the
/// agent on demand if it is registered, so the extension does not care whether the agent
/// was already running.
///
/// If the connection cannot be made, which in practice means the user disabled the login
/// item in System Settings > General > Login Items, the extension calls
/// `NSFileProviderManager.disconnect(reason:)` on its domain and every call returns
/// serverUnreachable. It reconnects, and lifts the disconnect, the next time the
/// connection succeeds. (Whether `disconnect(reason:)` can be called from inside the
/// extension at all is one of S5's questions; if it cannot, the message lives only in
/// `sshdrive doctor`.)
final class AgentConnection: NSObject {
    static let agentMissingMessage =
        "SSH Drive's background agent is not running. Enable it in Login Items or run "
        + "`sshdrive doctor`."

    private let domain: NSFileProviderDomain
    private let callbacks: ExtensionCallbacks
    private var connection: NSXPCConnection?
    private var disconnected = false
    private let lock = NSLock()

    init(domain: NSFileProviderDomain, callbacks: ExtensionCallbacks) {
        self.domain = domain
        self.callbacks = callbacks
    }

    /// A proxy, or nil when the agent cannot be reached. `onError` fires for a connection
    /// that drops after the call was made.
    func proxy(onError: @escaping (Error) -> Void) -> SSHDriveAgentProtocol? {
        lock.lock()
        defer { lock.unlock() }

        if connection == nil {
            let created = NSXPCConnection(
                machServiceName: SSHDriveIdentifiers.machServiceName, options: [])
            created.remoteObjectInterface = SSHDriveXPCInterface.agent
            created.exportedInterface = SSHDriveXPCInterface.fileProviderExtension
            created.exportedObject = callbacks
            created.invalidationHandler = { [weak self] in
                self?.connectionWentAway()
            }
            created.interruptionHandler = { [weak self] in
                self?.connectionWentAway()
            }
            created.resume()
            connection = created
        }

        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.reportAgentMissing()
            onError(error)
        } as? SSHDriveAgentProtocol
    }

    /// The connection dropped. That is *not* on its own a missing agent: the system
    /// kills an idle extension instance, and the invalidation that follows our own
    /// teardown used to call `disconnect(reason:)` on the way out, which left the domain
    /// disconnected for every later instance and answered every request
    /// `.serverUnreachable` for good (docs/spikes/results.md, 2026-09-04 signed pass).
    /// Only a call that actually fails reports a missing agent; the next call rebuilds
    /// the connection.
    private func connectionWentAway() {
        lock.lock()
        connection = nil
        lock.unlock()
    }

    /// The one case where the extension, not the agent, changes domain state (section 3).
    private func reportAgentMissing() {
        guard !disconnected else { return }
        disconnected = true
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.disconnect(reason: Self.agentMissingMessage, options: []) { error in
            if let error {
                Log.extensionLog.error(
                    "disconnect(reason:) failed: \(error, privacy: .public)")
            }
        }
    }

    /// The agent answered, so lift any disconnect on this domain.
    ///
    /// Unconditional, not guarded on this instance having set it: the disconnect survives
    /// the instance that set it, so a fresh instance has to clear one it never made. It
    /// is one call to fileproviderd per instance launch, on the reply to `indexReady`.
    func noteAgentReachable() {
        lock.lock()
        disconnected = false
        lock.unlock()
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.reconnect { error in
            if let error {
                Log.extensionLog.error("reconnect() failed: \(error, privacy: .public)")
            }
        }
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
    }

    /// Every agent error becomes an NSFileProviderError before it reaches the system
    /// (section 5.1). A connection failure is serverUnreachable, so the system queues and
    /// retries rather than showing an error.
    static func fileProviderError(from error: Error) -> Error {
        let nsError = error as NSError
        guard let agentError = nsError.sshDriveAgentError else {
            return NSFileProviderError(.serverUnreachable)
        }
        switch agentError {
        case .serverUnreachable, .interfaceVersionMismatch, .unknownDomain:
            return NSFileProviderError(.serverUnreachable)
        case .notAuthenticated:
            return NSFileProviderError(.notAuthenticated)
        case .noSuchItem:
            return NSFileProviderError(.noSuchItem)
        case .filenameCollision:
            return NSFileProviderError(.filenameCollision)
        case .insufficientQuota:
            return NSFileProviderError(.insufficientQuota)
        case .versionMismatch, .cannotSynchronize, .permissionDenied, .notImplemented:
            return NSFileProviderError(.cannotSynchronize)
        }
    }
}

/// The object the agent calls back on: transfer progress and the close-and-reopen
/// protocol of section 5.3.
final class ExtensionCallbacks: NSObject, SSHDriveExtensionProtocol {
    private let lock = NSLock()
    private var progresses: [String: Progress] = [:]
    /// Set while the agent is rebuilding the index, so the reader stays shut.
    private(set) var readerIsClosed = false
    var onReaderClose: (() -> Void)?
    var onReaderReopen: (() -> Void)?

    func register(_ progress: Progress, for transferID: String) {
        lock.lock()
        progresses[transferID] = progress
        lock.unlock()
    }

    func unregister(transferID: String) {
        lock.lock()
        progresses.removeValue(forKey: transferID)
        lock.unlock()
    }

    func transferProgress(transferID: String, bytesCompleted: Int64, bytesTotal: Int64) {
        lock.lock()
        let progress = progresses[transferID]
        lock.unlock()
        progress?.totalUnitCount = max(bytesTotal, 1)
        progress?.completedUnitCount = bytesCompleted
    }

    func closeIndexReader(reply: @escaping () -> Void) {
        readerIsClosed = true
        onReaderClose?()
        reply()
    }

    func reopenIndexReader() {
        readerIsClosed = false
        onReaderReopen?()
    }
}
