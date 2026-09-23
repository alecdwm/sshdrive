import XCTest
import ProviderCore
import XPCProtocols

/// The decisions behind the File Provider extension, kept in `ProviderCore` so
/// `swift test` can exercise them without building `Apps/FileProvider`.
final class ProviderCoreTests: XCTestCase {

    private func snapshot(
        identifier: String = "id-1", parent: String = ProviderItemIdentifier.rootContainer.rawValue,
        filename: String = "note.txt", isDirectory: Bool = false, isSymlink: Bool = false,
        linkTarget: String? = nil, kept: Bool = false,
        policy: SSHDriveContentPolicy = .unset
    ) -> SSHDriveItemSnapshot {
        SSHDriveItemSnapshot(
            identifier: identifier, parentIdentifier: parent, filename: filename,
            pathBytes: Data(filename.utf8), isDirectory: isDirectory, isSymlink: isSymlink,
            linkTarget: linkTarget, size: 12, mtime: 1_700_000_000, mode: 0o644, uid: 501,
            gid: 20, contentVersion: "12-1700000000-0", metadataVersion: "meta",
            capabilities: UInt64(ProviderCapabilities([.allowsReading, .allowsWriting]).rawValue),
            fileSystemFlags: UInt64(ProviderFileSystemFlags.userReadable.rawValue),
            kept: kept, contentPolicyRawValue: policy.rawValue, extendedAttributes: [:])
    }

    // MARK: ItemView

    /// The root's filename is the domain's display name; every other item's is its own
    /// (`MQ-050`).
    func testTheRootTakesTheDomainsDisplayName() {
        let root = snapshot(
            identifier: ProviderItemIdentifier.rootContainer.rawValue, filename: "",
            isDirectory: true)
        let view = ItemView(snapshot: root, rootDisplayName: "nas")
        XCTAssertEqual(view.filename, "nas")
        XCTAssertEqual(view.identifier, .rootContainer)
        XCTAssertEqual(view.contentTypeHint, .folder)
        XCTAssertNil(view.documentSize, "a folder has no document size")
    }

    /// The content type (docs/design/names-and-attributes.md): a directory is a folder,
    /// a symlink is a symlink (docs/design/symlinks.md), and everything else is named by
    /// its extension.
    func testTheContentTypeHintFollowsTheRow() {
        XCTAssertEqual(
            ItemView(snapshot: snapshot(), rootDisplayName: "nas").contentTypeHint,
            .filenameExtension("txt"))
        XCTAssertEqual(
            ItemView(snapshot: snapshot(filename: "README"), rootDisplayName: "nas")
                .contentTypeHint, .data)
        XCTAssertEqual(
            ItemView(snapshot: snapshot(isDirectory: true), rootDisplayName: "nas")
                .contentTypeHint, .folder)
        let link = ItemView(
            snapshot: snapshot(filename: "bin", isSymlink: true, linkTarget: "../lib"),
            rootDisplayName: "nas")
        XCTAssertEqual(link.contentTypeHint, .symbolicLink)
        XCTAssertEqual(link.symlinkTargetPath, "../lib")
    }

    /// The badge (docs/design/pinning.md) follows the *kept* state, not the marker, and
    /// its identifier is the one declared in the appex's Info.plist - an item that
    /// returns any other gets no badge and no error (`MQ-056`).
    func testTheDecorationFollowsTheKeptState() {
        XCTAssertEqual(ItemView(snapshot: snapshot(), rootDisplayName: "nas").decorations, [])
        let kept = ItemView(
            snapshot: snapshot(kept: true, policy: .downloadEagerlyAndKeepDownloaded),
            rootDisplayName: "nas")
        XCTAssertEqual(kept.decorations, [SSHDriveIdentifiers.keptDecorationID])
        XCTAssertTrue(kept.userInfoKept)
        XCTAssertEqual(kept.contentPolicy, .downloadEagerlyAndKeepDownloaded)
    }

    // MARK: Errors

    /// Every agent error has one answer, and a connection failure is `.serverUnreachable`
    /// so the system queues and retries rather than showing an error
    /// (docs/design/extension.md).
    func testEveryAgentErrorMapsToOneFailure() {
        XCTAssertEqual(ProviderFailure(agentError: .serverUnreachable), .serverUnreachable)
        XCTAssertEqual(ProviderFailure(agentError: .interfaceVersionMismatch), .serverUnreachable)
        XCTAssertEqual(ProviderFailure(agentError: .unknownDomain), .serverUnreachable)
        XCTAssertEqual(ProviderFailure(agentError: .notAuthenticated), .notAuthenticated)
        XCTAssertEqual(ProviderFailure(agentError: .noSuchItem), .noSuchItem)
        XCTAssertEqual(ProviderFailure(agentError: .filenameCollision), .filenameCollision)
        XCTAssertEqual(ProviderFailure(agentError: .insufficientQuota), .insufficientQuota)
        XCTAssertEqual(ProviderFailure(agentError: .deletionRejected), .deletionRejected)
        for held: SSHDriveAgentError in [
            .versionMismatch, .cannotSynchronize, .permissionDenied, .notImplemented,
        ] {
            XCTAssertEqual(ProviderFailure(agentError: held), .cannotSynchronize)
        }
    }

    /// `.syncAnchorExpired` off the working-set fallback is already the answer and has to
    /// survive the trip back through the adapter (docs/design/item-index.md).
    func testFailureCodesRoundTrip() {
        for failure: ProviderFailure in [
            .serverUnreachable, .noSuchItem, .cannotSynchronize, .syncAnchorExpired,
            .filenameCollision, .notAuthenticated, .insufficientQuota, .deletionRejected,
            .nonEvictable, .excludedFromSync,
        ] {
            XCTAssertEqual(ProviderFailure(appleErrorCode: failure.appleErrorCode), failure)
        }
        // Anything unrecognised leaves the item in place rather than deleting it.
        XCTAssertEqual(ProviderFailure(appleErrorCode: -1234), .cannotSynchronize)
    }

    // MARK: Ranges

    /// The range is widened to the alignment the system asked for, which is what lets it
    /// stitch neighbouring windows together rather than re-fetching them
    /// (docs/design/extension.md).
    func testAPartialFetchIsWidenedToTheAlignment() {
        let widened = ProviderService.alignedRange(
            location: 5_000, length: 100, alignment: 4_096)
        XCTAssertEqual(widened.location, 4_096)
        XCTAssertEqual(widened.length, 4_096)

        let spanning = ProviderService.alignedRange(
            location: 4_000, length: 200, alignment: 4_096)
        XCTAssertEqual(spanning.location, 0)
        XCTAssertEqual(spanning.length, 8_192)

        // An alignment of 0 must not divide by zero.
        let unaligned = ProviderService.alignedRange(location: 10, length: 5, alignment: 0)
        XCTAssertEqual(unaligned.location, 10)
        XCTAssertEqual(unaligned.length, 5)
    }

    // MARK: The trash contract

    /// The trash contract (docs/design/names-and-attributes.md) in three places: the
    /// enumerator refusal (`MQ-009`/`MQ-010`), the `item(for:)` refusal, and a `.Trash`
    /// create under the root.
    func testTheTrashContract() {
        let service = ProviderService(
            domainIdentifier: "d", displayName: "nas", reader: UnusableReader(),
            agent: RefusingAgent())

        XCTAssertThrowsError(try service.enumerator(for: .trashContainer)) {
            XCTAssertEqual($0 as? ProviderFailure, .featureUnsupported)
        }

        var itemAnswer: Result<ItemView, ProviderFailure>?
        service.item(for: .trashContainer) { itemAnswer = $0 }
        guard case .failure(let itemFailure) = itemAnswer else {
            return XCTFail("item(for: .trashContainer) must answer")
        }
        XCTAssertEqual(itemFailure, .noSuchItem)

        for spelling in [".Trash", ".trash", ".TRASH"] {
            var createAnswer: Result<ItemView, ProviderFailure>?
            service.createItem(
                template: ItemTemplate(
                    parentIdentifier: .rootContainer, filename: spelling, isDirectory: true,
                    isSymlink: false),
                contents: nil, transferID: "t"
            ) { createAnswer = $0 }
            guard case .failure(let createFailure) = createAnswer else {
                return XCTFail("a \(spelling) create must be refused")
            }
            XCTAssertEqual(createFailure, .featureUnsupported)
        }

        // And a `.Trash` anywhere else is an ordinary name the server may well have.
        var elsewhere: Result<ItemView, ProviderFailure>?
        service.createItem(
            template: ItemTemplate(
                parentIdentifier: ProviderItemIdentifier("id-dir"), filename: ".Trash",
                isDirectory: true, isSymlink: false),
            contents: nil, transferID: "t"
        ) { elsewhere = $0 }
        guard case .failure(let elsewhereFailure) = elsewhere else {
            return XCTFail("the agent must have been asked")
        }
        XCTAssertEqual(elsewhereFailure, .cannotSynchronize, "the agent answered, not the refusal")
    }

    /// The system tearing an instance down shuts the reader down; `close()` is the
    /// restore's alone, and a teardown that called it would report the restore's `closed`
    /// to `doctor` for every location.
    func testInvalidateShutsTheReaderDownRatherThanClosingIt() {
        let reader = UnusableReader()
        let service = ProviderService(
            domainIdentifier: "d", displayName: "nas", reader: reader, agent: RefusingAgent())
        service.invalidate()
        XCTAssertEqual(reader.calls, ["shutdown"])
    }

    /// The working set is only a change stream: an `enumerateItems` on it returns nothing
    /// and finishes with no page token (`MQ-002`).
    func testTheWorkingSetEnumeratesNothing() throws {
        let service = ProviderService(
            domainIdentifier: "d", displayName: "nas", reader: UnusableReader(),
            agent: RefusingAgent())
        let enumerator = try service.enumerator(for: .workingSet)
        let observer = CollectingEnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: nil)
        XCTAssertTrue(observer.items.isEmpty)
        XCTAssertTrue(observer.didFinish)
        XCTAssertNil(observer.finishedUpTo)
    }
}

// MARK: Doubles

/// A reader that can never answer, which is the state the whole 0.1.2 defect was about.
final class UnusableReader: ReaderStoring {
    var stateName: String { "not-ready" }
    var isReady: Bool { false }
    var askAgent: ((@escaping (Bool?) -> Void) -> Void)?
    func markReady(_ ready: Bool?) {}
    private(set) var calls: [String] = []
    func close() { calls.append("close") }
    func reopen() { calls.append("reopen") }
    func shutdown() { calls.append("shutdown") }
    func item(identifier: ProviderItemIdentifier) throws -> ItemView? { nil }
    func changes(since anchor: Int64, limit: Int) throws -> ReaderChangePage? { nil }
    func currentSequence() -> Int64? { nil }
}

/// An agent that answers everything with the one failure that leaves an item in place, so
/// a test can tell "the provider refused it itself" from "the provider asked".
final class RefusingAgent: AgentChannel {
    func indexReady(_ completion: @escaping (Bool?) -> Void) { completion(false) }
    func enumerateItems(
        container: ProviderItemIdentifier, pageToken: ProviderPageToken?,
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void
    ) { completion(.failure(.cannotSynchronize)) }
    func enumerateChanges(
        container: ProviderItemIdentifier, anchor: ProviderSyncAnchor,
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void
    ) { completion(.failure(.cannotSynchronize)) }
    func enumerateWorkingSetChanges(
        anchor: ProviderSyncAnchor,
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void
    ) { completion(.failure(.cannotSynchronize)) }
    func currentAnchor(_ completion: @escaping (String?) -> Void) { completion(nil) }
    func item(
        identifier: ProviderItemIdentifier,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) { completion(.failure(.cannotSynchronize)) }
    func fetchContents(
        identifier: ProviderItemIdentifier, requestedVersion: String?,
        isFileViewerRequest: Bool, isSystemRequest: Bool, into destination: FileHandle,
        transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) { completion(.failure(.cannotSynchronize)) }
    func fetchPartialContents(
        identifier: ProviderItemIdentifier, offset: Int64, length: Int64,
        into destination: FileHandle, transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) { completion(.failure(.cannotSynchronize)) }
    func createItem(
        template: ItemTemplate, contents: FileHandle?, transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) { completion(.failure(.cannotSynchronize)) }
    func modifyItem(
        identifier: ProviderItemIdentifier, baseVersion: String?,
        changedFields: ProviderItemFields, changes: ItemChanges, contents: FileHandle?,
        transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) { completion(.failure(.cannotSynchronize)) }
    func deleteItem(
        identifier: ProviderItemIdentifier, baseVersion: String?, recursive: Bool,
        _ completion: @escaping (ProviderFailure?) -> Void
    ) { completion(.cannotSynchronize) }
    func cancelTransfer(transferID: String) {}
    func materializedItemsDidChange() {}
    func workingSetAnchorExpired(freshAnchor: String) {}
    func performAction(
        actionIdentifier: String, itemIdentifiers: [ProviderItemIdentifier],
        _ completion: @escaping (ProviderFailure?) -> Void
    ) { completion(.cannotSynchronize) }
}

final class CollectingEnumerationObserver: EnumerationObserving {
    var items: [ItemView] = []
    var didFinish = false
    var finishedUpTo: ProviderPageToken?
    var failure: ProviderFailure?

    func didEnumerate(_ items: [ItemView]) { self.items.append(contentsOf: items) }
    func finishEnumerating(upTo token: ProviderPageToken?) {
        didFinish = true
        finishedUpTo = token
    }
    func finishEnumerating(with failure: ProviderFailure) { self.failure = failure }
}
