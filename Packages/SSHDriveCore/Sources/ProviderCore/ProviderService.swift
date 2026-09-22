import Foundation
import Logging
import XPCProtocols

/// Everything the File Provider extension decides (docs/design/extension.md).
///
/// One instance per domain, exactly as `NSFileProviderReplicatedExtension` is: the system
/// may host several in one process, so nothing here is global. It holds no state of its
/// own beyond the working set's error latch, opens no sockets and never writes the index.
///
/// `Apps/FileProvider` is the adapter above it - Apple types in, these types out - and
/// `SystemModel.FileProviderD` drives the very same object on Linux, which is what makes
/// scenario A2 a test rather than an afternoon on a VM.
public final class ProviderService {

    public let domainIdentifier: String
    /// The domain's display name, which is the root item's filename (`MQ-050`).
    public let displayName: String
    public let reader: ReaderStoring
    public let agent: AgentChannel
    private let signalling: ProviderDomainSignalling?

    public static let agentMissingMessage =
        "SSH Drive's background agent is not running. Enable it in Login Items or run "
        + "`sshdrive doctor`."

    public init(
        domainIdentifier: String,
        displayName: String,
        reader: ReaderStoring,
        agent: AgentChannel,
        signalling: ProviderDomainSignalling? = nil
    ) {
        self.domainIdentifier = domainIdentifier
        self.displayName = displayName
        self.reader = reader
        self.agent = agent
        self.signalling = signalling
    }

    /// The instance's one piece of start-up work, run from the adapter's `init`
    /// (docs/design/item-index.md).
    ///
    /// How the store asks the agent whether the index is ready to be read. It is asked once
    /// at launch and again by any read that finds the answer was no, rate limited: a
    /// `false` covers a window - a domain restart, an agent mid-restore - and an instance
    /// that could never ask again would answer the working set nothing for the rest of its
    /// life.
    public func start() {
        reader.askAgent = { [weak self] done in
            guard let self else { return done(nil) }
            self.agent.indexReady { ready in
                // A reply of any kind is proof the agent is there, so lift a disconnect a
                // previous instance may have left on the domain. `nil` is not a reply: it
                // is the agent being out of reach.
                if ready != nil { self.noteAgentReachable() }
                done(ready)
            }
        }
        reader.askAgent?({ [weak self] ready in self?.reader.markReady(ready) })
        Log.extensionLog.notice(
            "extension instance for \(self.displayName, privacy: .public) started")
    }

    public func invalidate() {
        reader.close()
    }

    // MARK: The agent's presence

    private let reachabilityLock = NSLock()
    private var disconnected = false

    /// A call to the agent failed. The one case where the extension, not the agent, changes
    /// domain state (docs/design/components.md).
    ///
    /// A dropped connection is *not* on its own a missing agent: the system kills an idle
    /// extension instance (`MQ-073`), and disconnecting the domain from the invalidation
    /// that follows our own teardown would answer every later request `.serverUnreachable`
    /// for good.
    public func noteAgentUnreachable() {
        reachabilityLock.lock()
        let already = disconnected
        disconnected = true
        reachabilityLock.unlock()
        guard !already else { return }
        signalling?.disconnect(reason: Self.agentMissingMessage)
    }

    /// The agent answered, so lift any disconnect on this domain (`MQ-074`).
    ///
    /// Unconditional, not guarded on this instance having set it: the disconnect survives
    /// the instance that set it, so a fresh instance has to clear one it never made.
    public func noteAgentReachable() {
        reachabilityLock.lock()
        disconnected = false
        reachabilityLock.unlock()
        signalling?.reconnect()
    }

    // MARK: The working set's error state

    private let workingSetLock = NSLock()
    private var workingSetFailing = false

    /// A working-set change enumeration answered normally. If the last one did not,
    /// fileproviderd is holding this domain's event stream on a throttle that only
    /// `signalErrorResolved` clears - a signalled enumerator is re-scheduled, not
    /// un-throttled (`MQ-037`) - so one call goes out here, once per recovery.
    public func noteWorkingSetSucceeded() {
        workingSetLock.lock()
        let recovering = workingSetFailing
        workingSetFailing = false
        workingSetLock.unlock()
        guard recovering else { return }
        Log.extensionLog.notice(
            "workingSet recovered; clearing the domain's serverUnreachable throttle")
        signalling?.signalErrorResolved(.serverUnreachable)
    }

    public func noteWorkingSetFailed() {
        workingSetLock.lock()
        workingSetFailing = true
        workingSetLock.unlock()
    }

    /// Whether this instance is currently holding a failed working-set enumeration.
    /// Read by tests; the system has no equivalent.
    public var isWorkingSetFailing: Bool {
        workingSetLock.lock(); defer { workingSetLock.unlock() }
        return workingSetFailing
    }

    // MARK: Anchors

    /// The newest sync anchor: the reader when it can answer, the agent when it cannot.
    ///
    /// The old version was `readerStore.currentSequence() ?? 0`, and the `0` is a trap -
    /// it is an expired anchor as soon as the oldest surviving row is past it, so a
    /// readiness race turned into an expiry and a full sweep.
    public func currentAnchor(_ completion: @escaping (ProviderSyncAnchor) -> Void) {
        if let sequence = reader.currentSequence() {
            completion(ProviderSyncAnchor(sequence: sequence))
            return
        }
        agent.currentAnchor { anchor in
            completion(ProviderSyncAnchor(anchor ?? "0"))
        }
    }

    /// The extension tells the agent it has answered `.syncAnchorExpired` and handed out a
    /// fresh anchor, one call per expiry (docs/design/item-index.md).
    public func reportAnchorExpired(freshAnchor: String) {
        agent.workingSetAnchorExpired(freshAnchor: freshAnchor)
    }

    // MARK: item(for:)

    /// Answered from the index by the extension itself, with no agent involved, because the
    /// system issues this in bulk and it must be answered from local state
    /// (docs/design/platform.md).
    public func item(
        for identifier: ProviderItemIdentifier,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        // No trash (docs/design/names-and-attributes.md). Answered here, from nothing, so
        // that neither the reader nor the agent is asked for a row that can never exist: a
        // domain added before `supportsSyncingTrash = false` still has a trash the system
        // may stat (`MQ-008`, `MQ-075`), and a slow answer to that is what a `ls -la` waits
        // on.
        if identifier == .trashContainer {
            completion(.failure(.noSuchItem))
            return
        }
        do {
            if let view = try reader.item(identifier: identifier) {
                completion(.success(view))
                return
            }
        } catch let failure as ProviderFailure {
            completion(.failure(failure))
            return
        } catch {
            completion(.failure(.serverUnreachable))
            return
        }
        // No reader, or a schema this build does not understand: ask the agent.
        agent.item(identifier: identifier, completion)
    }

    // MARK: Enumeration

    /// The trash contract (docs/design/names-and-attributes.md), in one place.
    ///
    /// `NSFeatureUnsupportedError` is what `NSFileProviderReplicatedExtension.h` prescribes
    /// for an extension that does not support trashing. It must not be `.noSuchItem`: the
    /// system reads that as "the container was deleted", tries to delete it from disk,
    /// fails because the trash is its own, and retries about once a second for ever
    /// (`MQ-009`), which hangs `ls -la` on the mount. The feature error makes it give up
    /// after two attempts and remove `.Trash` (`MQ-010`).
    public func enumerator(for container: ProviderItemIdentifier) throws -> ProviderEnumerating {
        if container == .workingSet {
            return WorkingSetEnumeration(service: self)
        }
        if container == .trashContainer {
            throw ProviderFailure.featureUnsupported
        }
        return ContainerEnumeration(container: container, service: self)
    }

    // MARK: Content

    public func fetchContents(
        identifier: ProviderItemIdentifier, requestedVersion: String?,
        isFileViewerRequest: Bool, isSystemRequest: Bool, into destination: FileHandle,
        transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        // The transfer scheduler's two classes travel to the agent unchanged: a file-viewer
        // request, or anything that is not a system request, is the user or an app opening
        // the file and goes in the foreground (docs/design/sftp.md).
        agent.fetchContents(
            identifier: identifier, requestedVersion: requestedVersion,
            isFileViewerRequest: isFileViewerRequest, isSystemRequest: isSystemRequest,
            into: destination, transferID: transferID, completion)
    }

    public func fetchPartialContents(
        identifier: ProviderItemIdentifier, alignedOffset: Int64, alignedLength: Int64,
        into destination: FileHandle, transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        agent.fetchPartialContents(
            identifier: identifier, offset: alignedOffset, length: alignedLength,
            into: destination, transferID: transferID, completion)
    }

    /// The range widened to the alignment the system asked for, which is what lets it
    /// stitch neighbouring windows together rather than re-fetching them. A decision, and a
    /// pure one, so it is here and not in the adapter.
    public static func alignedRange(location: Int, length: Int, alignment: Int)
        -> (location: Int, length: Int)
    {
        let stride = max(alignment, 1)
        let start = (location / stride) * stride
        let end = ((location + length + stride - 1) / stride) * stride
        return (start, max(end - start, stride))
    }

    // MARK: Mutations

    public func createItem(
        template: ItemTemplate, contents: FileHandle?, transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        // With `supportsSyncingTrash = false` the system decides how to handle a trashing
        // operation, and the header does not guarantee what it decides. Whatever it is, it
        // is not a `.Trash` directory of ours on someone's server
        // (docs/design/names-and-attributes.md).
        if template.parentIdentifier == .rootContainer,
            SSHDriveTrash.isTrash(filename: template.filename)
        {
            completion(.failure(.featureUnsupported))
            return
        }
        agent.createItem(template: template, contents: contents, transferID: transferID, completion)
    }

    public func modifyItem(
        identifier: ProviderItemIdentifier, baseVersion: String?,
        changedFields: ProviderItemFields, changes: ItemChanges, contents: FileHandle?,
        transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        agent.modifyItem(
            identifier: identifier, baseVersion: baseVersion, changedFields: changedFields,
            changes: changes, contents: contents, transferID: transferID, completion)
    }

    public func deleteItem(
        identifier: ProviderItemIdentifier, baseVersion: String?, recursive: Bool,
        _ completion: @escaping (ProviderFailure?) -> Void
    ) {
        agent.deleteItem(
            identifier: identifier, baseVersion: baseVersion, recursive: recursive, completion)
    }

    // MARK: Signals and actions

    /// Forwarded so the agent can refresh its root set (docs/design/root-set.md) and the
    /// pin safety net (docs/design/pinning.md).
    public func materializedItemsDidChange() {
        agent.materializedItemsDidChange()
    }

    /// "Keep Downloaded" and "Don't Keep Downloaded" (docs/design/pinning.md).
    ///
    /// The extension does nothing of its own: it holds no state and cannot write the index
    /// (docs/design/components.md), so the action is forwarded to the agent, which is where
    /// every pin change from the CLI lands too - one writer, one code path, no second store
    /// to keep in sync.
    public func performAction(
        actionIdentifier: String, itemIdentifiers: [ProviderItemIdentifier],
        _ completion: @escaping (ProviderFailure?) -> Void
    ) {
        Log.extensionLog.notice(
            "performAction \(actionIdentifier, privacy: .public) on \(itemIdentifiers.count, privacy: .public) item(s)"
        )
        agent.performAction(
            actionIdentifier: actionIdentifier, itemIdentifiers: itemIdentifiers, completion)
    }
}
