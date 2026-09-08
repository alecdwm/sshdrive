import Foundation

// The non-Darwin backend and the capture hook. Compiled on both platforms; only `Log`'s
// loggers differ (see `LogFacade.swift`).

/// One line, as the backend saw it.
public struct LogEntry: Sendable, Equatable {
    public let date: Date
    public let level: LogLevel
    public let subsystem: String
    public let category: String
    /// The rendered message, privacy already applied by `SSHDriveLogMessage`.
    public let message: String

    public init(
        date: Date, level: LogLevel, subsystem: String, category: String, message: String
    ) {
        self.date = date
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.message = message
    }

    /// The stderr line: `2026-09-08T14:03:11.482Z notice  org.shirls.sshdrive:agent  message`.
    ///
    /// Fixed-width level and a UTC timestamp with milliseconds, so a run is greppable by
    /// level, by subsystem or by category, and two runs diff.
    public var line: String {
        let level = self.level.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
        return "\(LogTimestamp.utc(date)) \(level) \(subsystem):\(category)  \(message)"
    }
}

/// UTC timestamps without a `DateFormatter`: the formatter types differ between Foundation
/// implementations and a log line has to render identically on every platform we build on.
enum LogTimestamp {
    /// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` for a `Date`, in UTC.
    static func utc(_ date: Date) -> String {
        utc(secondsSince1970: date.timeIntervalSince1970)
    }

    static func utc(secondsSince1970 seconds: Double) -> String {
        let whole = seconds.rounded(.down)
        var milliseconds = Int(((seconds - whole) * 1000).rounded(.down))
        var epochSeconds = Int(whole)
        if milliseconds >= 1000 {  // only reachable through rounding at the boundary
            milliseconds -= 1000
            epochSeconds += 1
        }
        var days = epochSeconds / 86400
        var secondOfDay = epochSeconds % 86400
        if secondOfDay < 0 {  // before 1970: floor the division
            secondOfDay += 86400
            days -= 1
        }
        let (year, month, day) = civilFromDays(days)
        let hour = secondOfDay / 3600
        let minute = (secondOfDay % 3600) / 60
        let second = secondOfDay % 60
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
            + "T\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2)).\(pad(milliseconds, 3))Z"
    }

    /// Days since 1970-01-01 to a civil date (Howard Hinnant's `civil_from_days`).
    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        return (month <= 2 ? year + 1 : year, month, day)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width
            ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}

/// Where an `SSHDriveLogger`'s lines go: stderr, and every installed `LogCapture`.
///
/// One lock serialises the whole emit, so lines from several threads never interleave and a
/// capture's order is the order they were written in.
final class LogBackend: @unchecked Sendable {
    static let shared = LogBackend()

    private let lock = NSLock()
    private var captures: [LogCapture] = []
    /// The lowest level written to stderr; `SSHDRIVE_LOG_LEVEL` raises it. Internal for the test.
    let stderrFloor: LogLevel

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        // Nothing is dropped by default: a Linux run is a developer or a test, and the
        // `.debug`-is-not-persisted rule is a unified-log rule, not ours. `SSHDRIVE_LOG_LEVEL`
        // raises the stderr floor; a capture always sees everything.
        stderrFloor =
            environment["SSHDRIVE_LOG_LEVEL"].flatMap { LogLevel(rawValue: $0.lowercased()) }
            ?? .debug
    }

    func emit(_ entry: LogEntry) {
        lock.lock()
        defer { lock.unlock() }
        var writeToStderr = entry.level >= stderrFloor
        for capture in captures {
            capture.storage.append(entry)
            if capture.silencesStderr { writeToStderr = false }
        }
        if writeToStderr {
            FileHandle.standardError.write(Data((entry.line + "\n").utf8))
        }
    }

    func add(_ capture: LogCapture) {
        lock.lock()
        defer { lock.unlock() }
        guard !captures.contains(where: { $0 === capture }) else { return }
        captures.append(capture)
    }

    func remove(_ capture: LogCapture) {
        lock.lock()
        defer { lock.unlock() }
        captures.removeAll { $0 === capture }
    }

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// An in-memory sink a test installs to read back what was logged.
///
/// ```swift
/// LogCapture.capturing { capture in
///     SSHDriveLogger(subsystem: Log.subsystem, category: Log.Category.agent)
///         .notice("mounted \(name, privacy: .public)")
///     XCTAssertEqual(capture.messages(level: .notice), ["mounted nas"])
/// }
/// ```
///
/// **Platforms.** The capture sees every line written through an `SSHDriveLogger`, at every
/// level including `.debug` - the unified log's "debug is not persisted" rule is Darwin's, and
/// nothing here re-implements it. On Linux that is every `Log.*` line as well, because `Log`'s
/// loggers *are* `SSHDriveLogger`s there. On Darwin `Log.*` is `os.Logger` and its lines go to
/// the unified log and never to a capture, by design: `sshdrive logs` and its predicates must
/// keep working unchanged. A test that has to pass on both platforms therefore logs through an
/// `SSHDriveLogger` it constructs itself, which is what the future `SystemModel` will hold.
///
/// An installed capture is retained by the backend until `uninstall()`; use `capturing(_:)`,
/// or a `defer`, so a failed test does not leave one collecting.
public final class LogCapture: @unchecked Sendable {
    /// While this capture is installed, lines are not also written to stderr. On by default:
    /// a test that asserts on lines rarely wants them in the test log too.
    public let silencesStderr: Bool

    /// Guarded by `LogBackend.shared`'s lock.
    fileprivate var storage: [LogEntry] = []

    public init(silencesStderr: Bool = true) {
        self.silencesStderr = silencesStderr
    }

    /// Start collecting. Idempotent.
    public func install() { LogBackend.shared.add(self) }

    /// Stop collecting. What was collected stays readable.
    public func uninstall() { LogBackend.shared.remove(self) }

    /// Everything collected so far, in the order it was written.
    public var entries: [LogEntry] {
        LogBackend.shared.withLock { storage }
    }

    /// Forget everything collected so far, staying installed.
    public func clear() {
        LogBackend.shared.withLock { storage.removeAll() }
    }

    /// Entries narrowed by category and/or level - the usual shape of an assertion.
    public func entries(
        subsystem: String? = nil, category: String? = nil, level: LogLevel? = nil
    ) -> [LogEntry] {
        entries.filter {
            (subsystem == nil || $0.subsystem == subsystem)
                && (category == nil || $0.category == category)
                && (level == nil || $0.level == level)
        }
    }

    /// The rendered messages of `entries(subsystem:category:level:)`.
    public func messages(
        subsystem: String? = nil, category: String? = nil, level: LogLevel? = nil
    ) -> [String] {
        entries(subsystem: subsystem, category: category, level: level).map(\.message)
    }

    /// Install a capture for the duration of `body`, and uninstall it however `body` ends.
    @discardableResult
    public static func capturing<T>(
        silencesStderr: Bool = true, _ body: (LogCapture) throws -> T
    ) rethrows -> T {
        let capture = LogCapture(silencesStderr: silencesStderr)
        capture.install()
        defer { capture.uninstall() }
        return try body(capture)
    }
}
