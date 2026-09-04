import Foundation
import XCTest
@testable import AgentCore

/// DESIGN.md section 6.4's tier 1 invocations and section 9.2's rule that nothing from the
/// user is ever in the script text.
final class SweepPlanTests: XCTestCase {

    private func plan(shallow: [String] = ["a"], recursive: [String] = [], excluded: [String] = [],
                      flavour: FindFlavour = .gnu, takesCmin: Bool = true, takesPrintf: Bool = true,
                      windowMinutes: Int? = 3) -> SweepPlan {
        SweepPlan(shallowRoots: shallow, recursiveRoots: recursive, excluded: excluded,
                  flavour: flavour, takesCmin: takesCmin, takesPrintf: takesPrintf,
                  windowMinutes: windowMinutes)
    }

    // MARK: Batching

    func testRootsAreBatchedAtTheSixtyFourKilobyteArgvBudget() {
        // Section 6.4: "each is run in batches of at most 64 KB of root arguments, since
        // the roots reach find as its argv and a few thousand materialized roots would
        // otherwise brush a kernel's argument limit."
        let roots = (0..<2000).map { String(repeating: "d", count: 99) + "\($0)" }
        let batches = plan(shallow: roots).batches
        XCTAssertGreaterThan(batches.count, 1)
        for batch in batches {
            let bytes = batch.roots.reduce(0) { $0 + $1.utf8.count + 1 }
            XCTAssertLessThanOrEqual(bytes, SweepPlan.argumentByteBudget)
            XCTAssertFalse(batch.roots.isEmpty)
        }
        XCTAssertEqual(batches.flatMap(\.roots), roots)
    }

    func testASmallRootSetIsOneBatchAndTheTwoShapesAreSeparate() {
        let batches = plan(shallow: ["a", "b"], recursive: ["Photos"]).batches
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0], SweepPlan.Batch(roots: ["a", "b"], recursive: false))
        XCTAssertEqual(batches[1], SweepPlan.Batch(roots: ["Photos"], recursive: true))
    }

    func testASingleOversizedRootStillGetsABatchRatherThanBeingDropped() {
        let huge = String(repeating: "x", count: SweepPlan.argumentByteBudget * 2)
        let batches = plan(shallow: [huge, "b"]).batches
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].roots, [huge])
        XCTAssertEqual(batches[1].roots, ["b"])
    }

    // MARK: The two invocation shapes

    func testTheShallowInvocationTakesMaxdepthOneAndTheRecursiveOneDoesNot() {
        let body = plan(shallow: ["a"], recursive: ["Photos"]).script().body
        let lines = body.split(separator: "\n").map(String.init).filter { $0.contains("-type d") }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("-maxdepth 1"))
        XCTAssertFalse(lines[1].contains("-maxdepth 1"))
        // Both files and directories: a directory's ctime changes on create, delete and
        // rename inside it, but an in-place edit changes only the file's own.
        for line in lines { XCTAssertTrue(line.contains("'(' -type d -o -type f ')'")) }
        // No -xdev: a NAS root routinely contains separate mounts.
        XCTAssertFalse(body.contains("-xdev"))
    }

    func testTheGnuPrintfStringIsByteForByteWhatSectionSixFourStates() {
        XCTAssertEqual(SweepPlan.gnuPrintfFormat, #"%p\0%y\0%s\0%T@\0%i\0%m\0%U\0%G\0"#)
        let plan = self.plan(flavour: .gnu, takesCmin: true, takesPrintf: true)
        XCTAssertTrue(plan.usesPrintf)
        let body = plan.script().body
        XCTAssertTrue(body.contains(#"-printf '%p\0%y\0%s\0%T@\0%i\0%m\0%U\0%G\0'"#))
        XCTAssertFalse(body.contains("-print0"))
    }

    func testOnlyGnuGetsPrintfHoweverTheProbeAnswered() {
        // -printf is a GNU extension; a BSD find that somehow probed true would fail
        // outright rather than lose a field.
        let bsd = plan(flavour: .bsd, takesCmin: true, takesPrintf: true)
        XCTAssertFalse(bsd.usesPrintf)
        XCTAssertTrue(bsd.script().body.contains("-print0"))
    }

    func testBusyboxTakesMminAndPrintZero() {
        // Section 6.4: "busybox has no -cmin at all ... BusyBox v1.36.1 as shipped by
        // current Alpine answers `find: unrecognized: -cmin`".
        let plan = self.plan(flavour: .busybox, takesCmin: false, takesPrintf: false, windowMinutes: 7)
        XCTAssertFalse(plan.usesCmin)
        let body = plan.script().body
        XCTAssertTrue(body.contains("-mmin -7"))
        XCTAssertFalse(body.contains("-cmin"))
        XCTAssertTrue(body.contains("-print0"))
    }

    func testBusyboxNeverGetsCminEvenIfTheProbeSaidItCould() {
        let plan = self.plan(flavour: .busybox, takesCmin: true, takesPrintf: false, windowMinutes: 7)
        XCTAssertFalse(plan.usesCmin)
        XCTAssertTrue(plan.script().body.contains("-mmin -7"))
    }

    func testGnuAndBsdTakeCmin() {
        for flavour in [FindFlavour.gnu, .bsd] {
            let plan = self.plan(flavour: flavour, takesCmin: true, takesPrintf: false, windowMinutes: 12)
            XCTAssertTrue(plan.usesCmin)
            XCTAssertTrue(plan.script().body.contains("-cmin -12"))
        }
    }

    func testAnUnboundedWindowDropsTheTimeTestEntirely() {
        // Section 6.4's full sweep with no stored server timestamp: every file under the
        // roots is reported.
        let body = plan(windowMinutes: nil).script().body
        XCTAssertFalse(body.contains("-cmin"))
        XCTAssertFalse(body.contains("-mmin"))
        XCTAssertTrue(body.contains("-type f"))
    }

    // MARK: Exclusions

    func testGlobEscapingOfTheFourCharactersPathTreatsSpecially() {
        // Section 6.4: "-path takes a glob, so *, ?, [ and \ in an excluded path are
        // backslash-escaped before the pattern is embedded: `-path 't/[x]'` does not match
        // a directory named `[x]`".
        XCTAssertEqual(SweepPlan.escapeGlob("t/[x]"), #"t/\[x]"#)
        XCTAssertEqual(SweepPlan.escapeGlob("a*b"), #"a\*b"#)
        XCTAssertEqual(SweepPlan.escapeGlob("a?b"), #"a\?b"#)
        XCTAssertEqual(SweepPlan.escapeGlob(#"a\b"#), #"a\\b"#)
        // The backslash is escaped first, or it would escape the escapes added after it.
        XCTAssertEqual(SweepPlan.escapeGlob(#"\*"#), #"\\\*"#)
        // Everything else is left alone: ] and { are not glob metacharacters to find.
        XCTAssertEqual(SweepPlan.escapeGlob("plain/name-1.txt"), "plain/name-1.txt")
    }

    func testTheExcludedPruneComesBeforeTheTypeTest() {
        let plan = self.plan(shallow: ["a"], excluded: ["Photos/Raw", "b*c"])
        let (body, arguments) = plan.script()
        guard let line = body.split(separator: "\n").map(String.init).first(where: { $0.contains("-type d") }),
              let prune = line.range(of: "-prune"),
              let type = line.range(of: "-type d")
        else { return XCTFail("expected one find expression line") }
        XCTAssertLessThan(prune.lowerBound, type.lowerBound)
        // -o-joined, so a pruned directory is neither descended into nor printed.
        XCTAssertTrue(line.contains(#"-path "$__sd_x1" -prune -o"#))
        XCTAssertTrue(line.contains(#"-path "$__sd_x2" -prune -o"#))
        // The patterns themselves are values, not text in the body: they are the user's.
        XCTAssertEqual(Array(arguments.prefix(2)), ["Photos/Raw", #"b\*c"#])
        XCTAssertFalse(body.contains("Photos/Raw"))
        XCTAssertEqual(plan.excluded, ["Photos/Raw", #"b\*c"#])
    }

    func testNoExclusionsMeansNoPruneAtAll() {
        let body = plan(excluded: []).script().body
        XCTAssertFalse(body.contains("-prune"))
        XCTAssertFalse(body.contains("__sd_x"))
    }

    // MARK: Section 9.2 - nothing from the user is in the body

    func testARootIsNeverEmbeddedInTheBodyHoweverItIsSpelled() {
        // Section 9.2: "a directory on a shared NAS named `$(rm -rf ~)` must never reach
        // that shell". It reaches find through `set --` as "$@" and nowhere else.
        let nasty = "$(rm -rf ~)"
        let newline = "two\nlines"
        let quote = "it's"
        let plan = self.plan(shallow: [nasty, newline], recursive: [quote], excluded: ["ex'cluded"])
        let (body, arguments) = plan.script()
        for value in [nasty, newline, quote, "ex'cluded"] {
            XCTAssertFalse(body.contains(value), "\(value) leaked into the script body")
            XCTAssertTrue(arguments.contains(value), "\(value) never reached the arguments")
        }
        // The body refers to positional parameters and to nothing else the user owns.
        XCTAssertTrue(body.contains("find \"$@\""))
    }

    func testTheArgumentsCarryEachBatchBehindItsOwnCount() {
        let plan = self.plan(shallow: ["a", "b"], recursive: ["Photos"], excluded: ["x"])
        let (_, arguments) = plan.script()
        // Excluded globs first, then count-led batches.
        XCTAssertEqual(arguments, ["x", "2", "a", "b", "1", "Photos"])
    }

    // MARK: The server's clock, and surviving one bad root

    func testTheServersOwnClockIsPrintedBeforeAnyFindRuns() {
        // Section 6.4: "N is computed from the server's clock, never the Mac's: every
        // sweep script prints `date +%s` first."
        let body = plan().script().body
        guard let date = body.range(of: "date +%s"), let find = body.range(of: "find \"$@\"") else {
            return XCTFail("expected both a date and a find")
        }
        XCTAssertLessThan(date.lowerBound, find.lowerBound)
        // NUL-delimited, never newline-delimited (section 9.2).
        XCTAssertTrue(body.contains(#"printf '\000'"#))
    }

    func testEveryInvocationToleratesAFindThatExitsNonZero() {
        // One unreadable root must not lose the whole sweep.
        let body = plan(shallow: ["a"], recursive: ["b"]).script().body
        XCTAssertEqual(body.components(separatedBy: "find \"$@\" || true").count - 1, 2)
        XCTAssertEqual(body.components(separatedBy: ") || true").count - 1, 2)
    }
}

/// DESIGN.md section 6.4's window arithmetic. It lives here rather than in a file of its
/// own because the window is one field of the plan and the two are always read together.
final class SweepWindowTests: XCTestCase {

    func testNoStoredStampIsUnbounded() {
        // A fresh or rebuilt index has nothing to open the window back to, so every file
        // under the roots is reported and the -cmin test is dropped entirely.
        XCTAssertEqual(SweepWindow.compute(lastAppliedServerTime: nil, serverNow: 1_756_900_000, full: false),
                       SweepWindow(minutes: nil))
        XCTAssertNil(SweepWindow.compute(lastAppliedServerTime: nil, serverNow: 0, full: true).minutes)
        XCTAssertFalse(SweepWindow.compute(lastAppliedServerTime: nil, serverNow: 0, full: true).clockWentBackwards)
    }

    func testNinetySecondsIsThreeMinutes() {
        // "the minutes between the stored value and the new one, rounded up, plus one
        // minute of overlap": ceil(90 / 60) is 2, plus 1.
        let window = SweepWindow.compute(lastAppliedServerTime: 1000, serverNow: 1090, full: false)
        XCTAssertEqual(window.minutes, 3)
        XCTAssertFalse(window.clockWentBackwards)
    }

    func testTheRoundingAndTheOverlap() {
        // Exactly one minute is one minute plus the overlap.
        XCTAssertEqual(SweepWindow.compute(lastAppliedServerTime: 0, serverNow: 60, full: false).minutes, 2)
        // One second past it rounds up.
        XCTAssertEqual(SweepWindow.compute(lastAppliedServerTime: 0, serverNow: 61, full: false).minutes, 3)
        // No time at all is still a whole minute: N is never zero.
        XCTAssertEqual(SweepWindow.compute(lastAppliedServerTime: 0, serverNow: 0, full: false).minutes, 1)
        XCTAssertEqual(SweepWindow.compute(lastAppliedServerTime: 0, serverNow: 1, full: false).minutes, 2)
    }

    func testAStampInTheFutureClampsToOneAndSaysTheClockMoved() {
        // The server's clock went backwards, or ours did. A negative or zero N would turn
        // the sweep into a no-op for as long as the jump lasted.
        let window = SweepWindow.compute(lastAppliedServerTime: 2000, serverNow: 1000, full: false)
        XCTAssertEqual(window.minutes, 1)
        XCTAssertTrue(window.clockWentBackwards)
    }

    func testAFullSweepUsesTheSameArithmetic() {
        // `full` changes which stamp the caller passes and whether tier 0's rotation is
        // suspended, not how the minutes are counted.
        XCTAssertEqual(SweepWindow.compute(lastAppliedServerTime: 1000, serverNow: 1090, full: true),
                       SweepWindow.compute(lastAppliedServerTime: 1000, serverNow: 1090, full: false))
    }

    func testAnUnboundedWindowReachesThePlanAsNoTimeTest() {
        let window = SweepWindow.compute(lastAppliedServerTime: nil, serverNow: 0, full: true)
        let plan = SweepPlan(shallowRoots: ["a"], recursiveRoots: [], flavour: .gnu,
                             takesCmin: true, takesPrintf: true, windowMinutes: window.minutes)
        XCTAssertFalse(plan.script().body.contains("-cmin"))
    }
}
