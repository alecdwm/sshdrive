import XCTest
import SFTP

@testable import AgentCore

/// DESIGN.md section 5.7's table, line by line, plus the two directions section 5.7 adds
/// on top of it: what `createItem` accepts from the Mac, and what a move re-checks.
final class SymlinkPolicyTests: XCTestCase {

    private let roots = SymlinkPolicy.Roots(
        canonical: "/var/home/alec", alternate: "/home/alec")

    private func path(_ text: String) throws -> RelativePath { try RelativePath(string: text) }

    // MARK: The four rows of section 5.7's table

    func testRelativeTargetInsideTheRootKeepsItsOwnString() throws {
        let decision = SymlinkPolicy.evaluate(
            target: "../Media/clip.mov", linkDirectory: try path("Documents"), roots: roots)
        XCTAssertEqual(decision, .show(macTarget: "../Media/clip.mov"))
    }

    func testRelativeTargetThatClimbsAboveTheRootIsHidden() throws {
        let decision = SymlinkPolicy.evaluate(
            target: "../../etc/passwd", linkDirectory: try path("Documents"), roots: roots)
        guard case .hide = decision else { return XCTFail("expected the link to be hidden") }
    }

    func testAbsoluteTargetInsideTheRootIsRewrittenRelative() throws {
        // The NAS case section 5.7 names: `media -> /volume1/media` under a root of
        // `/volume1`. Here the link lives two levels down, so the rewrite climbs.
        let decision = SymlinkPolicy.evaluate(
            target: "/var/home/alec/Media/clip.mov",
            linkDirectory: try path("Documents/Reports"), roots: roots)
        XCTAssertEqual(decision, .show(macTarget: "../../Media/clip.mov"))
    }

    func testAbsoluteTargetOutsideTheRootIsHidden() throws {
        let decision = SymlinkPolicy.evaluate(
            target: "/etc", linkDirectory: .root, roots: roots)
        guard case .hide = decision else { return XCTFail("expected the link to be hidden") }
    }

    // MARK: The two spellings of the root

    func testTheUserTypedSpellingOfTheRootIsAcceptedToo() throws {
        // `/home` is itself a symlink to `/var/home`, so every absolute link the user ever
        // made says `/home/alec/…` while the canonical root is `/var/home/alec`. Checked
        // against the canonical spelling alone, all of them would be hidden.
        let decision = SymlinkPolicy.evaluate(
            target: "/home/alec/Media/clip.mov", linkDirectory: try path("Documents"),
            roots: roots)
        XCTAssertEqual(decision, .show(macTarget: "../Media/clip.mov"))
    }

    func testARootWithNoSecondSpellingStillWorks() throws {
        let only = SymlinkPolicy.Roots(canonical: "/srv/share")
        XCTAssertNil(only.alternate)
        XCTAssertEqual(
            SymlinkPolicy.evaluate(target: "/srv/share/a", linkDirectory: .root, roots: only),
            .show(macTarget: "a"))
    }

    func testAnAlternateEqualToTheCanonicalOneIsNotKept() {
        let roots = SymlinkPolicy.Roots(canonical: "/srv", alternate: "/srv")
        XCTAssertNil(roots.alternate)
    }

    // MARK: Lexical, never resolved

    func testDotSegmentsAreCollapsedWithoutTouchingTheServer() throws {
        XCTAssertEqual(
            SymlinkPolicy.evaluate(
                target: "./a/../b", linkDirectory: try path("x"), roots: roots),
            .show(macTarget: "./a/../b"))
        // ... and the same string one level higher is still inside.
        XCTAssertEqual(
            SymlinkPolicy.resolve(relative: "./a/../b", from: try path("x")), ["x", "b"])
    }

    func testALinkToItsOwnDirectoryIsSpelledDot() throws {
        let decision = SymlinkPolicy.evaluate(
            target: "/var/home/alec/Documents", linkDirectory: try path("Documents"),
            roots: roots)
        XCTAssertEqual(decision, .show(macTarget: "."))
    }

    func testAnEmptyTargetIsHidden() {
        guard case .hide = SymlinkPolicy.evaluate(target: "", linkDirectory: .root, roots: roots)
        else { return XCTFail("expected the link to be hidden") }
    }

    func testAnAbsoluteTargetThatClimbsAboveSlashIsClampedNotResolved() {
        // `..` above `/` is `/` on every Unix; the point is that nothing here asks the
        // server, so a target full of `..` cannot steer a remote operation (section 9.1).
        XCTAssertNil(
            SymlinkPolicy.componentsInsideRoot(absolute: "/../../etc", roots: roots))
    }

    // MARK: Creating a link from the Mac

    func testCreateAcceptsARelativeTargetInsideTheShare() throws {
        let target = try SymlinkPolicy.targetForCreate(
            "../Media/clip.mov", in: try path("Documents"), roots: roots)
        XCTAssertEqual(target, "../Media/clip.mov")
    }

    func testCreateRefusesAnAbsoluteTargetEvenInsideTheMount() throws {
        // An absolute target from the Mac is a *Mac* path and means nothing on the server,
        // so it is refused even when it points inside the mount (section 5.7).
        XCTAssertThrowsError(
            try SymlinkPolicy.targetForCreate(
                "/var/home/alec/Media", in: try path("Documents"), roots: roots)
        ) { XCTAssertEqual($0 as? SymlinkPolicy.Refusal, SymlinkPolicy.Refusal()) }
    }

    func testCreateRefusesATargetThatEscapes() throws {
        XCTAssertThrowsError(
            try SymlinkPolicy.targetForCreate("../../etc", in: try path("a"), roots: roots))
    }

    func testTheRefusalCarriesTheMessageTheUserSees() {
        XCTAssertEqual(
            SymlinkPolicy.Refusal().errorDescription, SymlinkPolicy.escapingTargetMessage)
    }

    // MARK: Moving a link

    func testMovingALinkRecheckesItsTargetFromTheDestination() throws {
        // `../Media/clip.mov` is fine in `Documents` and escapes from the root.
        XCTAssertEqual(
            try SymlinkPolicy.targetForMove(
                "../Media/clip.mov", to: try path("Documents"), roots: roots),
            "../Media/clip.mov")
        XCTAssertThrowsError(
            try SymlinkPolicy.targetForMove("../Media/clip.mov", to: .root, roots: roots))
    }

    func testAnAbsoluteInRootTargetGetsANewRelativeSpellingWhereverItLands() throws {
        XCTAssertEqual(
            try SymlinkPolicy.targetForMove(
                "/var/home/alec/Media/clip.mov", to: .root, roots: roots),
            "Media/clip.mov")
        XCTAssertEqual(
            try SymlinkPolicy.targetForMove(
                "/var/home/alec/Media/clip.mov", to: try path("a/b"), roots: roots),
            "../../Media/clip.mov")
    }
}
