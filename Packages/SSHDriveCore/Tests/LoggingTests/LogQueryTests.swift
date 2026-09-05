import XCTest

@testable import Logging

/// `sshdrive logs` (DESIGN.md section 8). The predicate is the whole command: everything
/// else is `execv`.
final class LogQueryTests: XCTestCase {

    func testUnfilteredPredicateTakesOursAndFileproviderdsLinesAboutUs() {
        let predicate = LogQuery.predicate()
        XCTAssertEqual(
            predicate,
            "(subsystem == 'org.shirls.sshdrive')"
                + " OR (process == 'fileproviderd' AND eventMessage CONTAINS 'org.shirls.sshdrive')")
    }

    /// The system's own view of a domain is only ever in fileproviderd's lines, so a
    /// predicate that named our subsystem alone would answer half of every File Provider
    /// question.
    func testEveryPredicateIncludesFileproviderd() {
        for predicate in [
            LogQuery.predicate(),
            LogQuery.predicate(domainIdentifier: "6F1C-…"),
            LogQuery.predicate(domainIdentifier: "6F1C-…", displayName: "nas"),
        ] {
            XCTAssertTrue(predicate.contains("process == 'fileproviderd'"), predicate)
            XCTAssertTrue(predicate.contains("subsystem == 'org.shirls.sshdrive'"), predicate)
        }
    }

    /// Our own lines carry the location's UUID in most places and its display name in the
    /// ones written for a person, so a named query has to match either or it drops half of
    /// what it was asked for.
    func testNamedPredicateMatchesBothTheIdentifierAndTheDisplayName() {
        let predicate = LogQuery.predicate(
            domainIdentifier: "1B5C5E86-FCA9-4663-9E74-4148BF86FA41", displayName: "nas")
        XCTAssertTrue(
            predicate.contains("eventMessage CONTAINS[c] '1B5C5E86-FCA9-4663-9E74-4148BF86FA41'"))
        XCTAssertTrue(predicate.contains("eventMessage CONTAINS[c] 'nas'"))
        XCTAssertEqual(
            predicate.components(separatedBy: "process == 'fileproviderd'").count - 1, 1)
    }

    /// fileproviderd obfuscates domain identifiers in its own messages (`uuid:63...0B`),
    /// so a predicate that narrowed its half to the UUID matched **none** of its 511 lines
    /// on the VM while the provider identifier matched all of them (2026-09-05). Naming a
    /// location narrows our half and leaves the system's whole.
    func testTheFileproviderdHalfIsNeverNarrowedToOneDomain() {
        let named = LogQuery.predicate(
            domainIdentifier: "1B5C5E86-FCA9-4663-9E74-4148BF86FA41", displayName: "nas")
        let all = LogQuery.predicate()
        let systemClause = "(process == 'fileproviderd' AND eventMessage CONTAINS 'org.shirls.sshdrive')"
        XCTAssertTrue(named.hasSuffix(systemClause), named)
        XCTAssertTrue(all.hasSuffix(systemClause), all)
    }

    /// A location whose nickname is not set displays as its host, and one named by its id
    /// would otherwise be matched twice in the same clause.
    func testDisplayNameEqualToTheIdentifierIsNotRepeated() {
        let predicate = LogQuery.predicate(domainIdentifier: "abc", displayName: "abc")
        XCTAssertEqual(predicate.components(separatedBy: "CONTAINS[c] 'abc'").count - 1, 1)
        XCTAssertEqual(
            LogQuery.predicate(domainIdentifier: "abc", displayName: "nas")
                .components(separatedBy: "CONTAINS[c] ").count - 1, 2)
    }

    func testEmptyIdentifierIsTheUnfilteredQuery() {
        XCTAssertEqual(LogQuery.predicate(domainIdentifier: ""), LogQuery.predicate())
    }

    /// A nickname is user-typed. `sshdrive add "alec's nas"` must not be able to end the
    /// predicate's quoted string early.
    func testQuotingEscapesQuotesAndBackslashes() {
        XCTAssertEqual(LogQuery.quote("nas"), "'nas'")
        XCTAssertEqual(LogQuery.quote("alec's nas"), "'alec\\'s nas'")
        XCTAssertEqual(LogQuery.quote(#"back\slash"#), #"'back\\slash'"#)
    }

    /// `log show` hides the info level unless asked, and most of the transport's detail is
    /// `Log.ssh.info`.
    func testShowArgumentsAskForInfoAndAWindow() {
        let argv = LogQuery.showArguments(last: "30m")
        XCTAssertEqual(argv.first, "/usr/bin/log")
        XCTAssertEqual(argv[1], "show")
        XCTAssertTrue(argv.contains("--info"))
        XCTAssertFalse(argv.contains("--debug"))
        XCTAssertEqual(argv[argv.firstIndex(of: "--last")! + 1], "30m")
        XCTAssertEqual(argv.last, LogQuery.predicate())
    }

    func testStreamArgumentsHaveNoWindowAndCanCarryDebug() {
        let argv = LogQuery.streamArguments(debug: true)
        XCTAssertEqual(argv[1], "stream")
        XCTAssertFalse(argv.contains("--last"))
        XCTAssertTrue(argv.contains("--debug"))
    }

    /// zsh has a `log` builtin that shadows /usr/bin/log (docs/spikes/results.md,
    /// 2026-09-04), so the executable is always the absolute path.
    func testTheExecutableIsAlwaysAbsolute() {
        XCTAssertEqual(LogQuery.executable, "/usr/bin/log")
        XCTAssertEqual(LogQuery.showArguments().first, "/usr/bin/log")
        XCTAssertEqual(LogQuery.streamArguments().first, "/usr/bin/log")
    }
}
