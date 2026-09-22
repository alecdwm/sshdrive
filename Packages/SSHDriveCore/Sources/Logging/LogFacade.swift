import Foundation

// The portable half of the logging facade (docs/design/testing.md).
//
// `Log`'s loggers are `os.Logger` on Darwin and `SSHDriveLogger` everywhere else, chosen by
// `#if canImport(os)` in `Log.swift`. Call sites never name either type: they write
// `Log.agent.notice("… \(value, privacy: .public) …")`, which compiles against both because
// `SSHDriveLogger`'s methods take an `SSHDriveLogMessage` whose interpolation accepts the same
// `privacy:` labels as `OSLogMessage`'s.
//
// Everything in this file is compiled on **both** platforms. Only the `Log.*` loggers differ,
// so a test can construct an `SSHDriveLogger`, install a `LogCapture` and assert on the lines
// it produces on Linux and on macOS alike.

/// A level, ordered as the unified log orders them.
///
/// `SSHDriveLogger.trace` is `debug` and `critical` is `fault`, as on `os.Logger`.
public enum LogLevel: String, Sendable, CaseIterable, Comparable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    /// Rank, for `SSHDRIVE_LOG_LEVEL` and for `<`.
    public var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .warning: return 3
        case .error: return 4
        case .fault: return 5
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// How a value is rendered, mirroring `OSLogPrivacy` so that a call site's `privacy:` label
/// means the same thing on both platforms.
///
/// The Darwin defaults are reproduced: a string or an arbitrary value is `.auto`, which
/// redacts, and a number or a `Bool` is public. `.private` and `.sensitive` always render
/// `<private>` here - masks are accepted so the label compiles, but nothing is hashed, since
/// the only readers of a Linux line are a developer and a test.
public enum LogPrivacy: Sendable, Equatable {
    case auto
    case `public`
    case `private`
    case sensitive

    /// `OSLogPrivacy.Mask`. Accepted and ignored; see the type's note.
    public enum Mask: Sendable, Equatable {
        case hash
        case none
    }

    public static func `private`(mask: Mask) -> LogPrivacy { .private }
    public static func sensitive(mask: Mask) -> LogPrivacy { .sensitive }
    public static func auto(mask: Mask) -> LogPrivacy { .auto }

    /// What `.auto` means for this kind of value: strings and objects redact, scalars do not.
    func renders(scalar: Bool) -> Bool {
        switch self {
        case .public: return true
        case .private, .sensitive: return false
        case .auto: return scalar
        }
    }
}

/// The message an `SSHDriveLogger` method takes: `OSLogMessage`'s portable twin.
///
/// It is a plain string builder. The value is rendered when the message is built, not when it
/// is written, which is the one behavioural difference from `os_log` and is invisible to a
/// call site.
public struct SSHDriveLogMessage: ExpressibleByStringInterpolation, CustomStringConvertible,
    Sendable
{
    /// The rendered line, privacy already applied.
    public let text: String

    public init(stringLiteral value: String) { text = value }
    public init(stringInterpolation: Interpolation) { text = stringInterpolation.text }
    public init(_ text: String) { self.text = text }

    public var description: String { text }

    /// The interpolation. Every overload here exists because a call site in this repo uses
    /// that shape; `align:` and `format:` are deliberately absent, since no call site uses
    /// them and an unused overload is one more chance of an ambiguity. Add them when a call
    /// site needs one.
    public struct Interpolation: StringInterpolationProtocol {
        var text: String

        public init(literalCapacity: Int, interpolationCount: Int) {
            text = ""
            text.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) { text += literal }

        public mutating func appendInterpolation(
            _ value: @autoclosure () -> String, privacy: LogPrivacy = .auto
        ) {
            append(privacy.renders(scalar: false) ? value() : Self.redacted)
        }

        public mutating func appendInterpolation(
            _ value: @autoclosure () -> StaticString, privacy: LogPrivacy = .public
        ) {
            append(privacy.renders(scalar: true) ? "\(value())" : Self.redacted)
        }

        public mutating func appendInterpolation<Value: BinaryInteger>(
            _ value: @autoclosure () -> Value, privacy: LogPrivacy = .public
        ) {
            append(privacy.renders(scalar: true) ? "\(value())" : Self.redacted)
        }

        public mutating func appendInterpolation<Value: BinaryFloatingPoint>(
            _ value: @autoclosure () -> Value, privacy: LogPrivacy = .public
        ) {
            append(privacy.renders(scalar: true) ? "\(value())" : Self.redacted)
        }

        public mutating func appendInterpolation(
            _ value: @autoclosure () -> Bool, privacy: LogPrivacy = .public
        ) {
            append(privacy.renders(scalar: true) ? "\(value())" : Self.redacted)
        }

        /// The catch-all: an `Error`, a `UUID`, an enum, anything with a description. Ranked
        /// below the overloads above, because a conversion to `Any` is ranked below a generic
        /// binding, so `\(count, privacy: .public)` still takes the integer overload.
        public mutating func appendInterpolation(
            _ value: @autoclosure () -> Any, privacy: LogPrivacy = .auto
        ) {
            append(privacy.renders(scalar: false) ? "\(value())" : Self.redacted)
        }

        static let redacted = "<private>"

        private mutating func append(_ rendered: String) { text += rendered }
    }
}

/// The Linux (and any non-Darwin) logger: `os.Logger`'s surface over the stderr backend and
/// the in-memory `LogCapture`s.
///
/// Construction is the same - `SSHDriveLogger(subsystem:category:)` - so `Log`'s five
/// subsystem/category pairs are spelled once, for both platforms.
public struct SSHDriveLogger: Sendable {
    public let subsystem: String
    public let category: String

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    public func trace(_ message: SSHDriveLogMessage) { emit(.debug, message) }
    public func debug(_ message: SSHDriveLogMessage) { emit(.debug, message) }
    public func info(_ message: SSHDriveLogMessage) { emit(.info, message) }
    /// `os.Logger.log(_:)` writes at the default level, which is `notice`.
    public func log(_ message: SSHDriveLogMessage) { emit(.notice, message) }
    public func notice(_ message: SSHDriveLogMessage) { emit(.notice, message) }
    public func warning(_ message: SSHDriveLogMessage) { emit(.warning, message) }
    public func error(_ message: SSHDriveLogMessage) { emit(.error, message) }
    public func critical(_ message: SSHDriveLogMessage) { emit(.fault, message) }
    public func fault(_ message: SSHDriveLogMessage) { emit(.fault, message) }

    private func emit(_ level: LogLevel, _ message: SSHDriveLogMessage) {
        LogBackend.shared.emit(
            LogEntry(
                date: Date(), level: level, subsystem: subsystem, category: category,
                message: message.text))
    }
}
