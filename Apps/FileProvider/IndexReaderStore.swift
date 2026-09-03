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
/// Whether this survives at all is S3's measurement (section 5.2). `useReader` is the
/// switch the spike flips, so both paths can be timed against the same 50,000-entry
/// listing without a rebuild.
final class IndexReaderStore {
    private let locationID: String
    private var reader: IndexReader?
    private let lock = NSLock()
    /// False forces every read through the agent, which is the fallback path anyway.
    var useReader = true
    /// Set until the agent has answered `indexReady`; an instance that has not asked yet
    /// opens nothing (section 5.3).
    private var readyChecked = false

    init(locationID: String) {
        self.locationID = locationID
    }

    /// One XPC call per instance launch, not per item: before an instance opens the index
    /// for the first time it asks the agent whether the index is ready, and an agent
    /// mid-restore answers no. An agent that cannot be reached at all leaves the instance
    /// free to open the reader, since a missing agent is the case the direct reader
    /// exists for.
    func markReady(_ ready: Bool) {
        lock.lock()
        readyChecked = ready
        if !ready { reader = nil }
        lock.unlock()
    }

    func close() {
        lock.lock()
        reader?.close()
        reader = nil
        lock.unlock()
    }

    func reopen() {
        lock.lock()
        reader = nil
        lock.unlock()
    }

    private func open() throws -> IndexReader {
        if let reader { return reader }
        guard let url = try? GroupContainer.indexURL(locationID: locationID) else {
            throw NSFileProviderError(.serverUnreachable)
        }
        let opened = try IndexReader(path: url.path)
        reader = opened
        return opened
    }

    /// Reads one row, or nil when the reader is not usable and the caller should ask the
    /// agent instead. Throws only what the system should see.
    func item(identifier: String) throws -> SSHDriveItemSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard useReader, readyChecked else { return nil }
        do {
            return try open().item(identifier: identifier).snapshot
        } catch IndexError.noSuchItem {
            throw NSFileProviderError(.noSuchItem)
        } catch IndexError.schemaTooNew {
            // A mid-upgrade mismatch degrades to the slow path rather than failing.
            useReader = false
            return nil
        } catch IndexError.reconciling {
            throw NSFileProviderError(.serverUnreachable)
        } catch {
            Log.extensionLog.error("index reader failed: \(error, privacy: .public)")
            throw NSFileProviderError(.serverUnreachable)
        }
    }

    /// The working-set change stream, read in the extension. Never touches the network.
    func changes(since anchor: Int64, limit: Int = 500) throws
        -> (entries: [IndexAnchorEntry], items: [SSHDriveItemSnapshot], deleted: [String],
            newAnchor: Int64, hasMore: Bool)?
    {
        lock.lock()
        defer { lock.unlock() }
        guard useReader, readyChecked else { return nil }
        do {
            let reader = try open()
            let result = try reader.changes(since: anchor, limit: limit)
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
            throw NSFileProviderError(.serverUnreachable)
        } catch IndexError.schemaTooNew {
            useReader = false
            return nil
        } catch let error as NSError where error.domain == NSFileProviderErrorDomain {
            throw error
        } catch {
            Log.extensionLog.error("index reader failed: \(error, privacy: .public)")
            throw NSFileProviderError(.serverUnreachable)
        }
    }

    func currentSequence() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard useReader, readyChecked else { return nil }
        return try? open().currentSequence()
    }
}
