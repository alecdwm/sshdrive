import Foundation
import XCTest
import Config
import Index
import ProviderCore
import SystemModel

/// One mount, on Linux, with nothing attached.
///
/// A real SQLite index in a temp group container, the shipping `ProviderCore` decision
/// above it, and `SystemModel.FileProviderD` above that in place of macOS. The only things
/// scripted are the ones a scenario is about: whether the agent is reachable, what it
/// answers to `indexReady`, and how long it takes.
final class ScenarioHarness {
    let locationID: String
    let displayName: String
    let directory: URL
    let clock: VirtualClock
    let writer: IndexWriter
    let agent: ModelAgent
    let system: FileProviderD
    private(set) var domain: ModelDomain!

    /// Set before `addDomain()` to give fileproviderd a working-set enumerator other than
    /// the shipping one - which is how `A2` proves it bites.
    var workingSetEnumeratorOverride: ((ProviderService) -> ProviderEnumerating)?

    /// Set before `addDomain()` to answer the trash question the way version 0.1.0 did,
    /// which is how `B1` proves the `.Trash` hang bites.
    var trashAnswerOverride: ProviderFailure?

    init(macOS version: MacOSVersion = .v26_4, displayName: String = "nas") throws {
        self.locationID = UUID().uuidString
        self.displayName = displayName
        self.directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-scenario-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        GroupContainer.locator = FixedGroupContainerLocator(directory)
        _ = try GroupContainer.createDomainDirectory(locationID: locationID)
        self.writer = try IndexWriter(path: try GroupContainer.indexURL(locationID: locationID).path)
        _ = try writer.ensureRoot()
        self.clock = VirtualClock()
        self.agent = ModelAgent(writer: writer, displayName: displayName, clock: clock)
        self.system = FileProviderD(macOS: version, clock: clock)
    }

    deinit {
        GroupContainer.resetLocator()
        try? FileManager.default.removeItem(at: directory)
    }

    /// `add(domain)`: the system creates the domain, launches an instance and asks the
    /// working-set enumerator where to start.
    ///
    /// The bundle is installed and launched first, because `MQ-061` makes the plugin
    /// registration the precondition for a domain existing at all.
    @discardableResult
    func addDomain(nickname: String? = nil, supportsSyncingTrash: Bool? = nil) throws -> ModelDomain {
        // A scenario that stages its own install - `P3`'s quarantined bundle - keeps it.
        if system.launchd.bundleGeneration == 0 {
            system.launchd.installBundle(quarantined: false)
            system.launchd.launchApp()
        }
        let locationID = self.locationID
        let displayName = nickname ?? self.displayName
        let clock = self.clock
        let agent = self.agent
        let override = self.workingSetEnumeratorOverride
        let domain = try system.addDomain(
            identifier: locationID, displayName: displayName,
            supportsSyncingTrash: supportsSyncingTrash
        ) { [trashAnswerOverride] modelDomain in
            modelDomain.workingSetEnumeratorOverride = override
            modelDomain.trashAnswerOverride = trashAnswerOverride
            let reader = IndexReaderStore(
                locationID: locationID, rootDisplayName: displayName, clock: clock)
            return ProviderService(
                domainIdentifier: locationID, displayName: displayName, reader: reader,
                agent: agent, signalling: modelDomain)
        }
        self.domain = domain
        return domain
    }

    /// Finder, the user.
    var finder: Finder { domain.finder }

    /// A directory appearing on the server and reaching the index.
    @discardableResult
    func serverCreatesDirectory(_ name: String, identifier: String? = nil, parent: String? = nil)
        throws -> String
    {
        let id = identifier ?? "id-\(name)"
        try agent.indexRow(
            identifier: id, name: name, parent: parent ?? IndexWriter.rootIdentifier,
            isDirectory: true)
        return id
    }

    /// A file appearing on the server inside a directory the index already knows.
    @discardableResult
    func serverCreates(_ name: String, in parent: String, identifier: String? = nil) throws -> String {
        let id = identifier ?? "id-\(parent)-\(name)"
        try agent.indexRow(identifier: id, name: name, parent: parent)
        return id
    }

    /// The row for the location root, which the index carries permanently and which the
    /// working set delivers like any other (`MQ-030`'s pin on `/` needs it).
    func touchRootRow() throws {
        _ = try writer.appendAnchor(identifier: IndexWriter.rootIdentifier, kind: .modified)
    }

    func id(_ raw: String) -> ProviderItemIdentifier { ProviderItemIdentifier(raw) }

    /// A row that has stopped carrying the user's tags - section 5.4 as it was written
    /// before S4 corrected it. `L4`'s bite-proof needs an item that returns no `tagData`.
    func forgetStoredTags(of identifier: String) throws {
        guard var row = try writer.item(identifier: identifier) else { return }
        row.xattrs = nil
        try writer.upsert(row)
    }

    // MARK: The server, as far as suite A cares

    /// A file appearing on the server and reaching the agent's index - which is where the
    /// 0.1.2 failure left everything: `debug index dump` listed the rows and Finder never
    /// showed one of them.
    @discardableResult
    func serverCreates(_ name: String, identifier: String? = nil) throws -> String {
        let id = identifier ?? "id-\(name)"
        try agent.indexRow(identifier: id, name: name)
        return id
    }

    func serverDeletes(_ identifier: String) throws {
        try agent.removeIndexRow(identifier: identifier)
    }

    /// What Finder shows in a folder: the replica's listing, answered without the
    /// extension (`MQ-039`).
    func finderListing(of container: ProviderItemIdentifier = .rootContainer) -> [String] {
        domain.replica.listing(of: container)
    }
}

/// The working-set enumerator **as version 0.1.2 shipped it**, kept here and only here so
/// `A2` can prove that it fails and today's passes (`docs/testing-architecture.md`
/// section 8, step 1: "Done when A2 fails on the 0.1.2 code and passes on today's").
///
/// Two lines are the whole defect and both are reproduced:
///
/// - a reader that is not usable has exactly one answer, `.serverUnreachable`, with no
///   fallback to the agent and no log line of any kind;
/// - `currentSyncAnchor` answers `0` when the reader cannot, and a `0` is an expired
///   anchor as soon as the oldest surviving row is past it.
///
/// It is nothing but a copy: nothing in `Sources/` knows it exists, and it is not a flag
/// on the shipping type.
final class LegacyWorkingSetEnumeration: ProviderEnumerating {
    private let service: ProviderService

    init(service: ProviderService) {
        self.service = service
    }

    func invalidate() {}

    func enumerateItems(for observer: EnumerationObserving, startingAt page: ProviderPageToken?) {
        observer.didEnumerate([])
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: ChangeObserving, from anchor: ProviderSyncAnchor) {
        do {
            guard let result = try service.reader.changes(since: anchor.sequence) else {
                observer.finishEnumerating(with: .serverUnreachable)
                return
            }
            observer.didUpdate(result.items)
            observer.didDeleteItems(result.deleted)
            observer.finishEnumeratingChanges(
                upTo: ProviderSyncAnchor(sequence: result.newAnchor), moreComing: result.hasMore)
        } catch ProviderFailure.syncAnchorExpired {
            observer.finishEnumerating(with: .syncAnchorExpired)
        } catch {
            observer.finishEnumerating(with: .serverUnreachable)
        }
    }

    func currentSyncAnchor(_ completion: @escaping (ProviderSyncAnchor?) -> Void) {
        completion(ProviderSyncAnchor(sequence: service.reader.currentSequence() ?? 0))
    }
}
