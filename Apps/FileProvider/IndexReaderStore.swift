import FileProvider
import Foundation
import Config
import Index
import XPCProtocols
import Logging

/// The extension's own read-only view of the domain's index (DESIGN.md section 5.2).
///
/// One rule governs every failure here: any SQLite error, a corrupt page, a
/// not-a-database header during the truncate window, a missing table, is answered as
/// serverUnreachable, never as noSuchItem, so a rebuild in progress can never look like a
/// deletion (section 5.3).
///
/// **Readiness is not a latch.** It used to be: an instance asked the agent `indexReady`
/// once in its `init`, and a `false` - which the agent answers for any location whose
/// runtime is not up yet, and for any index it cannot read at that instant - left that
/// instance answering the working set `.serverUnreachable` for the whole of its life,
/// with nothing that would ever re-ask. fileproviderd throttles a change enumeration that
/// keeps failing, so a few seconds of "not ready" during a domain restart became an
/// event stream backed off to tens of minutes and a mount that took no server-side change
/// at all (2026-09-08). The rule now lives in `IndexReaderReadiness`, which is a value and
/// has tests; here it is wired to an XPC round trip and to the file `doctor` reads.
///
/// Every method that cannot answer returns nil rather than throwing, because the caller
/// has somewhere else to go: the agent has the same rows.
final class IndexReaderStore {
    private let locationID: String
    private var reader: IndexReader?
    private let lock = NSLock()
    /// False forces every read through the agent, which is the fallback path anyway.
    var useReader = true
    private var readiness = IndexReaderReadiness(retryInterval: 2)
    private var lastGeneration: Int64?
    private var writtenState: String?
    private var lastWriteAt: Date?
    /// How the store asks the agent again. Set by the extension, which owns the proxy.
    /// The answer is `nil` when the agent could not be reached at all.
    var askAgent: ((@escaping (Bool?) -> Void) -> Void)?

    init(locationID: String) {
        self.locationID = locationID
    }

    /// The agent's answer to `indexReady`.
    func markReady(_ ready: Bool?) {
        lock.lock()
        readiness.answered(ready, at: Date().timeIntervalSince1970)
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

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return useReader && readiness.canRead
    }

    var stateName: String {
        lock.lock(); defer { lock.unlock() }
        return useReader ? readiness.state.rawValue : "\(readiness.state.rawValue) (reader off)"
    }

    func close() {
        lock.lock()
        reader?.close()
        reader = nil
        readiness.close()
        lock.unlock()
        Log.extensionLog.notice(
            "index reader for \(self.locationID, privacy: .public) closed for a restore")
        publishState()
    }

    func reopen() {
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
        let due = readiness.shouldAsk(at: Date().timeIntervalSince1970)
        let ask = askAgent
        lock.unlock()
        guard due, let ask else { return }
        ask { [weak self] ready in self?.markReady(ready) }
    }

    private func open() throws -> IndexReader {
        if let reader { return reader }
        let url = try GroupContainer.indexURL(locationID: locationID)
        let opened = try IndexReader(path: url.path)
        reader = opened
        return opened
    }

    /// A read that failed. The reader is dropped and the agent is asked again; the caller
    /// falls back to the agent for this call.
    private func failed(_ error: Error) {
        readiness.failed(String(describing: error), at: Date().timeIntervalSince1970)
        reader = nil
    }

    /// Reads one row, or nil when the reader is not usable and the caller should ask the
    /// agent instead. Throws only what the system should see: `.noSuchItem`, which is a
    /// real answer about a real identifier.
    func item(identifier: String) throws -> SSHDriveItemSnapshot? {
        askAgainIfDue()
        lock.lock()
        defer { lock.unlock() }
        guard useReader, readiness.canRead else { return nil }
        do {
            let reader = try open()
            let row = try reader.item(identifier: identifier)
            lastGeneration = try? reader.generation()
            return row.snapshot
        } catch IndexError.noSuchItem {
            throw NSFileProviderError(.noSuchItem)
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
    func changes(since anchor: Int64, limit: Int = 500) throws
        -> (entries: [IndexAnchorEntry], items: [SSHDriveItemSnapshot], deleted: [String],
            newAnchor: Int64, hasMore: Bool)?
    {
        askAgainIfDue()
        lock.lock()
        defer { lock.unlock() }
        guard useReader, readiness.canRead else { return nil }
        do {
            let reader = try open()
            let result = try reader.changes(since: anchor, limit: limit)
            lastGeneration = try? reader.generation()
            var items: [SSHDriveItemSnapshot] = []
            var deleted: [String] = []
            for entry in result.entries {
                switch entry.kind {
                case .deleted:
                    deleted.append(entry.identifier)
                case .modified:
                    // An anchor whose identifier no longer has a row is reported as a
                    // deletion: only a deletion removes a row (section 5.3).
                    if let row = try? reader.item(identifier: entry.identifier) {
                        items.append(row.snapshot)
                    } else {
                        deleted.append(entry.identifier)
                    }
                }
            }
            return (result.entries, items, deleted, result.newAnchor, result.hasMore)
        } catch IndexError.syncAnchorExpired {
            throw NSFileProviderError(.syncAnchorExpired)
        } catch IndexError.reconciling {
            failed(IndexError.reconciling)
            return nil
        } catch IndexError.schemaTooNew {
            useReader = false
            readiness.foundSchemaTooNew("the index schema is newer than this build")
            reader = nil
            return nil
        } catch let error as NSError where error.domain == NSFileProviderErrorDomain {
            throw error
        } catch {
            Log.extensionLog.error("index reader failed: \(error, privacy: .public)")
            failed(error)
            return nil
        }
    }

    func currentSequence() -> Int64? {
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
        let stale = lastWriteAt.map { Date().timeIntervalSince($0) > 60 } ?? true
        guard fingerprint != writtenState || stale else {
            lock.unlock()
            return
        }
        writtenState = fingerprint
        lastWriteAt = Date()
        let payload: [String: Any] = [
            "state": readiness.state.rawValue,
            "useReader": useReader,
            "path": (try? GroupContainer.indexURL(locationID: locationID))?.path ?? "",
            "generation": lastGeneration ?? -1,
            "lastError": readiness.lastError ?? "",
            "at": Date().timeIntervalSince1970,
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
