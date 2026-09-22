import Foundation
import XCTest

@testable import Logging

/// The logging facade (docs/design/testing.md).
///
/// These tests run on Darwin and on Linux. Anything asserted about *content* goes through an
/// `SSHDriveLogger` the test constructs, because that is the one backend both platforms have:
/// on Linux it is also what `Log.agent` and friends are, while on Darwin `Log.*` stays
/// `os.Logger` and its lines go to the unified log, where only `sshdrive logs` can read them.
final class LogFacadeTests: XCTestCase {

    private func logger(_ category: String = Log.Category.agent) -> SSHDriveLogger {
        SSHDriveLogger(subsystem: Log.subsystem, category: category)
    }

    // MARK: - The capture hook

    func testTheCaptureReceivesTheSubsystemCategoryLevelAndMessage() {
        LogCapture.capturing { capture in
            logger().notice("mounted \("nas", privacy: .public)")

            XCTAssertEqual(capture.entries.count, 1)
            let entry = try? XCTUnwrap(capture.entries.first)
            XCTAssertEqual(entry?.subsystem, "org.shirls.sshdrive")
            XCTAssertEqual(entry?.category, "agent")
            XCTAssertEqual(entry?.level, .notice)
            XCTAssertEqual(entry?.message, "mounted nas")
        }
    }

    /// Every level reaches a capture, `.debug` included: "debug is not persisted" is a
    /// unified-log rule and belongs to Darwin, where `os.Logger` still enforces it.
    func testEveryLevelIsCapturedIncludingDebug() {
        LogCapture.capturing { capture in
            let log = logger()
            log.debug("d")
            log.info("i")
            log.notice("n")
            log.warning("w")
            log.error("e")
            log.fault("f")

            XCTAssertEqual(capture.entries.map(\.level), [.debug, .info, .notice, .warning, .error, .fault])
            XCTAssertEqual(capture.entries.map(\.message), ["d", "i", "n", "w", "e", "f"])
            XCTAssertEqual(capture.messages(level: .debug), ["d"])
        }
    }

    /// `log(_:)` is the default level, which is `notice`; `trace` is `debug` and `critical` is
    /// `fault`. Same aliases as `os.Logger`, so a call site can move either way.
    func testTheOSLoggerAliasesMapToTheSameLevels() {
        LogCapture.capturing { capture in
            let log = logger()
            log.log("default")
            log.trace("trace")
            log.critical("critical")

            XCTAssertEqual(capture.entries.map(\.level), [.notice, .debug, .fault])
        }
    }

    func testEntriesAreNarrowedBySubsystemCategoryAndLevel() {
        LogCapture.capturing { capture in
            logger(Log.Category.ssh).error("ssh died")
            logger(Log.Category.sftp).notice("sftp opened")
            SSHDriveLogger(subsystem: "org.example.other", category: "agent").notice("theirs")

            XCTAssertEqual(capture.messages(category: "ssh"), ["ssh died"])
            XCTAssertEqual(capture.messages(level: .notice).count, 2)
            XCTAssertEqual(capture.messages(subsystem: Log.subsystem).count, 2)
            XCTAssertEqual(
                capture.messages(subsystem: Log.subsystem, category: "sftp", level: .notice),
                ["sftp opened"])
        }
    }

    func testClearKeepsCollectingAndUninstallStops() {
        let capture = LogCapture()
        capture.install()
        defer { capture.uninstall() }

        logger().notice("first")
        capture.clear()
        XCTAssertEqual(capture.entries.count, 0)

        logger().notice("second")
        XCTAssertEqual(capture.messages(), ["second"])

        capture.uninstall()
        logger().notice("third")
        XCTAssertEqual(capture.messages(), ["second"], "an uninstalled capture keeps what it had")
    }

    func testTwoCapturesBothSeeALineAndInstallIsIdempotent() {
        LogCapture.capturing { outer in
            LogCapture.capturing { inner in
                inner.install()  // twice: still one copy
                logger().notice("once")
                XCTAssertEqual(inner.messages(), ["once"])
            }
            XCTAssertEqual(outer.messages(), ["once"])
        }
    }

    // MARK: - Interpolation and privacy

    func testInterpolationRendersLiteralsAndValues() {
        LogCapture.capturing { capture in
            let identifier = UUID(uuidString: "1B5C5E86-FCA9-4663-9E74-4148BF86FA41")!
            logger().notice(
                "\(identifier, privacy: .public): fetched \(3, privacy: .public) of \(10, privacy: .public) at \(1.5, privacy: .public) MiB/s, done=\(true, privacy: .public)"
            )

            XCTAssertEqual(
                capture.messages().first,
                "1B5C5E86-FCA9-4663-9E74-4148BF86FA41: fetched 3 of 10 at 1.5 MiB/s, done=true")
        }
    }

    /// The Darwin defaults, reproduced: a string is `.auto` and redacts, a number and a `Bool`
    /// are public. Every call site in this repo says `privacy: .public` for exactly that
    /// reason (docs/design/security.md).
    func testPrivacyRedactsTheWayTheUnifiedLogDoes() {
        LogCapture.capturing { capture in
            let log = logger()
            log.notice("\("secret")")
            log.notice("\("secret", privacy: .private)")
            log.notice("\("secret", privacy: .sensitive)")
            log.notice("\("secret", privacy: .private(mask: .hash))")
            log.notice("\("secret", privacy: .public)")
            log.notice("\(42)")
            log.notice("\(42, privacy: .private)")

            XCTAssertEqual(
                capture.messages(),
                [
                    "<private>", "<private>", "<private>", "<private>", "secret", "42",
                    "<private>",
                ])
        }
    }

    /// A multi-line message with `\` continuations, which is how the longer agent lines are
    /// written, and a nested plain-string interpolation inside an interpolated expression,
    /// which is how an optional is rendered.
    func testMultiLineMessagesAndNestedInterpolationRender() {
        LogCapture.capturing { capture in
            let seconds: Double? = 30
            let changedFields: UInt32 = 0x2C
            logger().notice(
                """
                modifyItem \("a/b", privacy: .public) \
                changedFields=0x\(String(changedFields, radix: 16), privacy: .public) \
                ttl=\(seconds.map { "\($0)s" } ?? "off", privacy: .public)
                """
            )

            XCTAssertEqual(
                capture.messages().first, "modifyItem a/b changedFields=0x2c ttl=30.0s")
        }
    }

    // MARK: - Every call form the codebase uses

    /// Mirrors each distinct shape found by
    /// `grep -rn 'Log\.' Apps Packages/SSHDriveCore/Sources` (206 calls, 17 logger/level
    /// pairs): if this compiles, so does every call site, on whichever platform is running it.
    /// It logs through `Log` itself - on Darwin the lines go to the unified log and are not
    /// asserted on, which is the point: the *compile* is the assertion.
    func testEveryCallFormUsedInTheCodebaseCompiles() {
        struct Failure: Error, CustomStringConvertible { var description: String { "boom" } }
        enum Classification: String { case refused }

        let identifier = UUID()
        let path = "docs/a b/café.txt"
        let count = 7
        let bytes: Int64 = 48 * 1024 * 1024
        let errnoCode: Int32 = 32
        let duration = 0.5
        let truncated = true
        let optionalMessage: String? = nil
        let error = Failure()

        // The six logger/level pairs the extension, CLI and askpass use.
        Log.extensionLog.notice("item \(identifier, privacy: .public)")
        Log.extensionLog.error("no row for \(identifier, privacy: .public)")
        Log.cli.error("could not reach the agent: \(String(describing: error), privacy: .public)")
        Log.askpass.notice("prompt relayed")
        Log.askpass.error("token refused")

        // The agent's five.
        Log.agent.debug("accepted a peer connection")
        Log.agent.info("cache totals \(bytes, privacy: .public) bytes")
        Log.agent.notice(
            "\(identifier, privacy: .public): evicted \(count, privacy: .public) item(s)")
        Log.agent.warning("index older than the replica")
        Log.agent.error(
            "\(identifier, privacy: .public): reconcile failed: \(String(describing: error), privacy: .public)"
        )

        // ssh and sftp.
        Log.ssh.debug("mux client exited 0")
        Log.ssh.info("master alive after \(duration, privacy: .public)s")
        Log.ssh.notice("connecting to \(path, privacy: .public)")
        Log.ssh.error("identity agent socket \(path, privacy: .public) refused: \(errnoCode)")
        Log.sftp.debug("packet \(count, privacy: .public)")
        Log.sftp.notice(
            "sweep: \(count, privacy: .public) hit(s) in \(String(format: "%.2f", duration), privacy: .public)s\(truncated ? " (TRUNCATED)" : "", privacy: .public)"
        )
        Log.sftp.error("read failed: \(optionalMessage ?? "?", privacy: .public)")

        // The value shapes: rawValue, a ternary, a Bool, a description, a byte count, a
        // radix conversion, an errno with no privacy label at all, and an existential Error.
        Log.agent.notice(
            """
            classification=\(Classification.refused.rawValue, privacy: .public) \
            held=\(truncated ? "yes" : "no", privacy: .public) \
            ok=\(truncated, privacy: .public) \
            path=\(path.description, privacy: .public) \
            size=\(bytes, privacy: .public) \
            mask=0x\(String(count, radix: 16), privacy: .public) \
            errno=\(errnoCode) \
            error=\(error, privacy: .public)
            """
        )
    }

    // MARK: - The line written to stderr

    func testTheStderrLineCarriesTimestampLevelSubsystemAndCategory() {
        let entry = LogEntry(
            date: Date(timeIntervalSince1970: 1_757_000_000.482), level: .notice,
            subsystem: Log.subsystem, category: Log.Category.agent, message: "mounted nas")

        XCTAssertEqual(
            entry.line, "2025-09-04T15:33:20.482Z notice  org.shirls.sshdrive:agent  mounted nas")
    }

    func testTheTimestampIsUTCAndFloorsBefore1970() {
        XCTAssertEqual(LogTimestamp.utc(secondsSince1970: 0), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(LogTimestamp.utc(secondsSince1970: -1), "1969-12-31T23:59:59.000Z")
        XCTAssertEqual(LogTimestamp.utc(secondsSince1970: 1_757_000_000), "2025-09-04T15:33:20.000Z")
        // A leap day, since the civil-date conversion is the only arithmetic here.
        XCTAssertEqual(LogTimestamp.utc(secondsSince1970: 1_709_164_800), "2024-02-29T00:00:00.000Z")
    }

    func testTheStderrFloorComesFromTheEnvironmentAndDefaultsToEverything() {
        XCTAssertEqual(LogBackend(environment: [:]).stderrFloor, .debug)
        XCTAssertEqual(
            LogBackend(environment: ["SSHDRIVE_LOG_LEVEL": "ERROR"]).stderrFloor, .error)
        XCTAssertEqual(
            LogBackend(environment: ["SSHDRIVE_LOG_LEVEL": "nonsense"]).stderrFloor, .debug)
        XCTAssertTrue(LogLevel.debug < LogLevel.info)
        XCTAssertTrue(LogLevel.error < LogLevel.fault)
    }

    // MARK: - The identifiers `sshdrive logs` matches on

    /// The subsystem and categories (docs/design/components.md), which the `logs`
    /// predicates are written against. `os.Logger` will not give a category back, so the
    /// constants are asserted instead - and, where the loggers are ours, that they were
    /// built from them.
    func testSubsystemAndCategoryConstantsMatchTheLogsPredicates() {
        XCTAssertEqual(Log.subsystem, "org.shirls.sshdrive")
        XCTAssertEqual(Log.Category.all, ["extension", "agent", "cli", "sftp", "ssh"])
        XCTAssertEqual(Log.Category.extensionLog, "extension")
        XCTAssertEqual(LogQuery.subsystem, Log.subsystem)

        #if !canImport(os)
            XCTAssertEqual(Log.agent.subsystem, Log.subsystem)
            XCTAssertEqual(Log.agent.category, "agent")
            XCTAssertEqual(Log.extensionLog.category, "extension")
            XCTAssertEqual(Log.cli.category, "cli")
            XCTAssertEqual(Log.sftp.category, "sftp")
            XCTAssertEqual(Log.ssh.category, "ssh")
            XCTAssertEqual(Log.askpass.category, "ssh", "askpass logs under ssh")
        #endif
    }

    /// Where there is no `os`, `Log.*` is the portable backend, so the capture sees the
    /// product's own lines - which is what the `SystemModel` scenarios will assert on.
    func testOnLinuxTheProductsOwnLoggersFeedTheCapture() throws {
        #if canImport(os)
            throw XCTSkip("Log.* is os.Logger on Darwin; its lines go to the unified log")
        #else
            LogCapture.capturing { capture in
                Log.agent.error("reconcile failed: \(42, privacy: .public)")
                XCTAssertEqual(
                    capture.entries(category: "agent", level: .error).map(\.message),
                    ["reconcile failed: 42"])
            }
        #endif
    }
}
