import Foundation
import Logging

/// A ring of the last few hundred File Provider calls that reached the agent, with the
/// wall-clock time each arrived and what it answered.
///
/// It exists for spike S5, which is almost entirely questions of the form "how long does
/// the system wait before calling again" and "does anything reach the extension while
/// every call fails fast". Neither can be answered from `os_log`, because the agent does
/// not log a line per call and would not be allowed to on the hot path anyway; and neither
/// can be answered from the system side at all, since `fileproviderctl` reports state, not
/// traffic.
///
/// Bounded, lock-guarded and off every allocation path that matters: one append of a small
/// struct per XPC method. `sshdrive debug calls <name>` prints it with the gap since the
/// previous call of the same kind, which is the number S5 is actually after.
final class CallJournal: @unchecked Sendable {
    static let shared = CallJournal()

    /// Enough to hold a ten-minute retry storm at the rates measured in milestone 4.
    static let capacity = 2000

    struct Entry: Sendable {
        var time: Date
        var domain: String
        var method: String
        var subject: String
        var outcome: String
        var milliseconds: Double
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var enabled = true

    func record(
        domain: String, method: String, subject: String, outcome: String, milliseconds: Double
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        entries.append(
            Entry(
                time: Date(), domain: domain, method: method, subject: subject,
                outcome: outcome, milliseconds: milliseconds))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    func snapshot(domain: String?, limit: Int) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        let matching = domain.map { id in entries.filter { $0.domain == id } } ?? entries
        return Array(matching.suffix(limit))
    }

    func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// The report `debug calls` prints: every entry with the gap in seconds since the
    /// previous entry of the same method **and** subject, which is exactly "how long did
    /// the system wait before calling again for this item".
    func report(domain: String?, limit: Int) -> [String: Any] {
        let rows = snapshot(domain: domain, limit: limit)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var previous: [String: Date] = [:]
        var out: [[String: Any]] = []
        for entry in rows {
            let key = "\(entry.method)|\(entry.subject)"
            var row: [String: Any] = [
                "time": formatter.string(from: entry.time),
                "method": entry.method,
                "subject": entry.subject,
                "outcome": entry.outcome,
                "ms": entry.milliseconds.rounded(toPlaces: 1),
            ]
            if let last = previous[key] {
                row["sincePreviousSameCall"] =
                    entry.time.timeIntervalSince(last).rounded(toPlaces: 3)
            }
            previous[key] = entry.time
            out.append(row)
        }
        var summary: [String: Int] = [:]
        for entry in rows { summary[entry.method, default: 0] += 1 }
        return ["calls": out, "count": rows.count, "byMethod": summary]
    }
}


/// One call, from arrival to reply. `AgentService` makes one per XPC method and finishes
/// it in both branches of the `do`/`catch`, so the journal carries the outcome as well as
/// the arrival time.
final class CallTiming: @unchecked Sendable {
    private let started = Date()
    private let domain: String
    private let method: String
    private let subject: String
    private var finished = false
    private let lock = NSLock()

    init(domain: String, method: String, subject: String) {
        self.domain = domain
        self.method = method
        self.subject = subject
        // Arrival is recorded straight away, because the gap between arrivals is what S5
        // measures and a call that never returns would otherwise never appear.
        CallJournal.shared.record(
            domain: domain, method: method, subject: subject, outcome: "arrived",
            milliseconds: 0)
    }

    func finish(_ outcome: String) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        CallJournal.shared.record(
            domain: domain, method: method, subject: subject, outcome: outcome,
            milliseconds: Date().timeIntervalSince(started) * 1000)
    }

    func finish(error: Error) {
        finish("error: \((error as NSError).localizedDescription)")
    }
}
