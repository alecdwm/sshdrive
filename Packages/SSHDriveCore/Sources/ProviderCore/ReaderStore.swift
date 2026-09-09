import Foundation
import Config
import Index
import Logging

/// The extension's own read-only view of the domain's index (DESIGN.md section 5.2).
///
/// One rule governs every failure here: any SQLite error, a corrupt page, a
/// not-a-database header during the truncate window, a missing table, is answered as
/// "ask the agent", never as noSuchItem, so a rebuild in progress can never look like a
/// deletion (section 5.3).
///
/// **Readiness is not a latch.** It used to be: an instance asked the agent `indexReady`
/// once in its `init`, and a `false` - which the agent answers for any location whose
/// runtime is not up yet, and for any index it cannot read at that instant - left that
/// instance answering the working set `.serverUnreachable` for the whole of its life,
/// with nothing that would ever re-ask. fileproviderd throttles a change enumeration that
/// keeps failing (`MQ-005`), so a few seconds of "not ready" during a domain restart became
/// an event stream backed off to tens of minutes and a mount that took no server-side
/// change at all (2026-09-08). The rule lives in `IndexReaderReadiness`, which is a value
/// and has tests; here it is wired to an XPC round trip and to the file `doctor` reads.
public final class IndexReaderStore: ReaderStoring {
    private let locationID: String
    private let rootDisplayName: String
    private let clock: ProviderClock
    private var reader: IndexReader?
    private let lock = NSLock()
    /// False forces every read through the agent, which is the fallback path anyway.
    public private(set) var useReader = true
    private var readiness: IndexReaderReadiness
    private var lastGeneration: Int64?
    private var writtenState: String?
    private var lastWriteAt: Double?
    /// How the store asks the agent again. Set by the provider, which owns the channel.
    /// The answer is `nil` when the agent could not be reached at all.
    public var askAgent: ((@escaping (Bool?) -> Void) -> Void)?

    public init(
        locationID: String, rootDisplayName: String, clock: ProviderClock = SystemProviderClock(),
        retryInterval: Double = 2
    ) {
        self.locationID = locationID
        self.rootDisplayName = rootDisplayName
        self.clock = clock
        self.readiness = IndexReaderReadiness(retryInterval: retryInterval)
    }

    /// The agent's answer to `indexReady`.
    public func markReady(_ ready: Bool?) {
        lock.lock()
        readiness.answered(ready, at: clock.now())
        if readiness.canRead {
            // Read `meta.generation` here rather than only on the first row, so the state
            // file says something useful about an index nothing has read yet.
            if let opened = try? open() {
                lastGeneration = (try? opened.generation()) ?? lastGeneration
            }
        } else {
            reader = nil
        }
        let snapshot = readiness.state
        lock.unlock()
        Log.extensionLog.notice(
            "index reader for \(self.locationID, privacy: .public) is \(snapshot.rawValue, privacy: .public) (indexReady answered \(ready.map { $0 ? "yes" : "no" } ?? "nothing", privacy: .public))"
        )
        publishState()
    }

    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return useReader && readiness.canRead
    }

    public var stateName: String {
        lock.lock(); defer { lock.unlock() }
        return useReader ? readiness.state.rawValue : "\(readiness.state.rawValue) (reader off)"
    }

    public func close() {
        lock.lock()
        reader?.close()
        reader = nil
        readiness.close()
        lock.unlock()
        Log.extensionLog.notice(
            "index reader for \(self.locationID, privacy: .public) closed for a restore")
        publishState()
    }

    public func reopen() {
        lock.lock()
        reader = nil
        readiness.reopen()
        lock.unlock()
        Log.extensionLog.notice(
            "index reader for \(self.locationID, privacy: .public) reopened after a restore")
        publishState()
    }

    /// Re-asks the agent when this instance is holding a non-ready answer, no more often
    /// than the readiness interval. Called from every read path, so an instance launched
    /// during a domain restart recovers by itself.
    private func askAgainIfDue() {
        lock.lock()
        let due = readiness.shouldAsk(at: clock.now())
        let ask = askAgent
        lock.unlock()
        guard due, let ask else { return }
        ask { [weak self] ready in self?.markReady(ready) }
    }

    private func open() throws -> IndexReader {
        if let reader { return reader }
        let url = try GroupContainer.indexURL(locationID: locationID)
        let opened = try IndexReader(path: url.path)
        opened.observeStatements(statementObserver)
        opened.observeCompilations(compileObserver)
        reader = opened
        return opened
    }

    /// A read that failed. The reader is dropped and the agent is asked again; the caller
    /// falls back to the agent for this call.
    private func failed(_ error: Error) {
        readiness.failed(String(describing: error), at: clock.now())
        reader = nil
    }

    /// Reads one row, or nil when the reader is not usable and the caller should ask the
    /// agent instead. Throws only what the system should see: `.noSuchItem`, which is a
    /// real answer about a real identifier.
    public func item(identifier: ProviderItemIdentifier) throws -> ItemView? {
        askAgainIfDue()
        lock.lock()
        defer { lock.unlock() }
        guard useReader, readiness.canRead else { return nil }
        do {
            let reader = try open()
            // One meta read and one row read, and no third statement for the generation:
            // the meta check has already read it, and `item(for:)` arrives in bulk
            // (section 5.2).
            let (row, generation) = try reader.itemAndGeneration(identifier: identifier.rawValue)
            lastGeneration = generation
            return ItemView(snapshot: row.snapshot, rootDisplayName: rootDisplayName)
        } catch IndexError.noSuchItem {
            throw ProviderFailure.noSuchItem
        } catch IndexError.schemaTooNew {
            // A mid-upgrade mismatch degrades to the slow path rather than failing.
            useReader = false
            readiness.foundSchemaTooNew("the index schema is newer than this build")
            reader = nil
            return nil
        } catch IndexError.reconciling {
            // Not an error to the system from here: the agent knows it is reconciling and
            // refuses the call itself, with the message section 5.3 wants shown.
            failed(IndexError.reconciling)
            return nil
        } catch {
            Log.extensionLog.error("index reader failed: \(error, privacy: .public)")
            failed(error)
            return nil
        }
    }

    /// The working-set change stream, read in the extension. Never touches the network.
    ///
    /// Returns nil when the reader cannot answer at all, which is the caller's cue to ask
    /// the agent. The only error it throws is `.syncAnchorExpired`, which is a real answer
    /// about the anchor the system holds and not a failure of this reader.
    public func changes(since anchor: Int64, limit: Int = 500) throws -> ReaderChangePage? {
        askAgainIfDue()
        lock.lock()
        defer { lock.unlock() }
        guard useReader, readiness.canRead else { return nil }
        do {
            let reader = try open()
            let result = try reader.changes(since: anchor, limit: limit)
            lastGeneration = try? reader.generation()
            var items: [ItemView] = []
            var deleted: [ProviderItemIdentifier] = []
            for entry in result.entries {
                switch entry.kind {
                case .deleted:
                    deleted.append(ProviderItemIdentifier(entry.identifier))
                case .modified:
                    // An anchor whose identifier no longer has a row is reported as a
                    // deletion: only a deletion removes a row (section 5.3).
                    if let row = try? reader.item(identifier: entry.identifier) {
                        items.append(
                            ItemView(snapshot: row.snapshot, rootDisplayName: rootDisplayName))
                    } else {
                        deleted.append(ProviderItemIdentifier(entry.identifier))
                    }
                }
            }
            return ReaderChangePage(
                items: items, deleted: deleted, newAnchor: result.newAnchor,
                hasMore: result.hasMore)
        } catch IndexError.syncAnchorExpired {
            throw ProviderFailure.syncAnchorExpired
        } catch IndexError.reconciling {
            failed(IndexError.reconciling)
            return nil
        } catch IndexError.schemaTooNew {
            useReader = false
            readiness.foundSchemaTooNew("the index schema is newer than this build")
            reader = nil
            return nil
        } catch let failure as ProviderFailure {
            throw failure
        } catch {
            Log.extensionLog.error("index reader failed: \(error, privacy: .public)")
            failed(error)
            return nil
        }
    }

    public func currentSequence() -> Int64? {
        askAgainIfDue()
        lock.lock()
        defer { lock.unlock() }
        guard useReader, readiness.canRead else { return nil }
        do {
            return try open().currentSequence()
        } catch {
            failed(error)
            return nil
        }
    }

    // MARK: The test seam of section 5.2's statement cache

    /// `IndexReader.observeStatements` and `.observeCompilations`, reachable from a
    /// scenario, and kept here so a reader opened later in the store's life is observed
    /// too. `E7` is what reads them: an `item(for:)` storm must cost one statement a call
    /// and a constant number of compilations however long it runs.
    /// Both are nil in the shipping extension.
    public func observeStatements(_ observer: (@Sendable (_ sql: String, _ depth: Int) -> Void)?) {
        lock.lock()
        statementObserver = observer
        reader?.observeStatements(observer)
        lock.unlock()
    }

    public func observeCompilations(_ observer: (@Sendable (_ sql: String, _ depth: Int) -> Void)?) {
        lock.lock()
        compileObserver = observer
        reader?.observeCompilations(observer)
        lock.unlock()
    }

    private var statementObserver: (@Sendable (_ sql: String, _ depth: Int) -> Void)?
    private var compileObserver: (@Sendable (_ sql: String, _ depth: Int) -> Void)?

    // MARK: The state file

    /// What the extension knows about its own reader, written where `sshdrive doctor` can
    /// read it (section 5.2).
    ///
    /// This is the one thing the extension writes into the group container besides the
    /// `-shm` its read-only connection needs, and it is deliberately a file rather than an
    /// XPC push: the question it answers - "is the reader in that other, sandboxed,
    /// short-lived process working?" - is asked when something is already wrong, often
    /// when the extension is not running at all, and the last thing it said is then the
    /// only evidence there is.
    private func publishState() {
        lock.lock()
        let fingerprint =
            "\(readiness.state.rawValue)|\(useReader)|\(readiness.lastError ?? "")|\(lastGeneration ?? -1)"
        let now = clock.now()
        let stale = lastWriteAt.map { now - $0 > 60 } ?? true
        guard fingerprint != writtenState || stale else {
            lock.unlock()
            return
        }
        writtenState = fingerprint
        lastWriteAt = now
        let payload: [String: Any] = [
            "state": readiness.state.rawValue,
            "useReader": useReader,
            "path": (try? GroupContainer.indexURL(locationID: locationID))?.path ?? "",
            "generation": lastGeneration ?? -1,
            "lastError": readiness.lastError ?? "",
            "at": now,
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        lock.unlock()

        guard let url = try? GroupContainer.readerStateURL(locationID: locationID),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // A container the extension cannot write is itself the finding, and it is one
            // the log has to carry, because the file that would have carried it is the one
            // that could not be written.
            Log.extensionLog.error(
                "could not write the reader state file: \(error, privacy: .public)")
        }
    }
}
