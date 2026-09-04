import XCTest
@testable import AgentCore

/// DESIGN.md section 6.4 tier 2, steps 1 and 2: which binary a server gets, whether the
/// copy already there is ours, and what may be deleted from a directory two Macs share.
final class HelperDeploymentTests: XCTestCase {

    private func manifest() -> HelperManifest {
        HelperManifest(
            version: "0.1.0",
            binaries: [
                .init(os: "linux", arch: "x86_64", file: "sshdrive-helper-0.1.0-linux-x86_64",
                      sha256: String(repeating: "a", count: 64), size: 500_000),
                .init(os: "linux", arch: "aarch64", file: "sshdrive-helper-0.1.0-linux-aarch64",
                      sha256: String(repeating: "b", count: 64), size: 440_000),
                .init(os: "linux", arch: "armv7", file: "sshdrive-helper-0.1.0-linux-armv7",
                      sha256: String(repeating: "c", count: 64), size: 410_000),
                .init(os: "darwin", arch: "aarch64", file: "sshdrive-helper-0.1.0-darwin-aarch64",
                      sha256: String(repeating: "d", count: 64), size: 460_000),
                .init(os: "freebsd", arch: "x86_64", file: "sshdrive-helper-0.1.0-freebsd-x86_64",
                      sha256: String(repeating: "e", count: 64), size: 470_000),
            ])
    }

    // MARK: uname -sm

    /// The spellings real servers print, which are not the ones the build system uses:
    /// FreeBSD says `amd64`, macOS says `arm64`, a 32-bit Synology says `armv7l`. Getting
    /// this wrong leaves every NAS at the sweep tier silently.
    func testUnameMapsOntoTheTargetsSection6_4Names() {
        let cases: [(String, String, String)] = [
            ("Linux x86_64", "linux", "x86_64"),
            ("Linux aarch64", "linux", "aarch64"),
            ("Linux armv7l", "linux", "armv7"),
            ("Darwin arm64", "darwin", "aarch64"),
            ("FreeBSD amd64", "freebsd", "x86_64"),
        ]
        for (uname, os, arch) in cases {
            XCTAssertEqual(HelperTarget(uname: uname), HelperTarget(os: os, arch: arch), uname)
            XCTAssertEqual(manifest().binary(forUname: uname)?.os, os, uname)
            XCTAssertEqual(manifest().binary(forUname: uname)?.arch, arch, uname)
        }
    }

    /// "A platform outside that list is the one case where a server with shell access
    /// stays at the sweep tier" - an ordinary outcome, not an error.
    func testAnUnsupportedPlatformHasNoBinaryAndDoesNotThrow() {
        XCTAssertNil(HelperTarget(uname: "Linux mips64"))
        XCTAssertNil(HelperTarget(uname: "SunOS i86pc"))
        XCTAssertNil(HelperTarget(uname: ""))
        XCTAssertNil(HelperTarget(uname: "Linux"))
        XCTAssertNil(manifest().binary(forUname: "Linux mips64"))
        XCTAssertNil(manifest().binary(forUname: "Darwin x86_64"), "no Intel Mac target ships")
    }

    func testTheManifestRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(manifest())
        XCTAssertEqual(try HelperManifest.decode(data), manifest())
    }

    // MARK: the verdict

    private var linux: HelperManifest.Binary { manifest().binaries[1] }

    func testAMissingFileIsUploaded() {
        let verdict = HelperDeployment.verdict(for: linux, evidence: .init())
        XCTAssertEqual(verdict, .upload(reason: "the helper is not on the server yet"))
    }

    func testAMatchingChecksumIsKept() {
        let evidence = HelperDeployment.RemoteEvidence(size: 440_000, sha256: linux.sha256)
        XCTAssertEqual(HelperDeployment.verdict(for: linux, evidence: evidence), .keep)
    }

    /// A hash the *binary* computed of itself is the same claim as one `sha256sum` made
    /// about it, which is what makes section 6.4's "size plus `--version`" fallback a real
    /// check rather than a weaker one (2026-09-05, section 13).
    func testTheBinarysOwnDigestIsAcceptedWhereThereIsNoChecksumTool() {
        let evidence = HelperDeployment.RemoteEvidence(
            size: 440_000, sha256: nil, reportedDigest: linux.sha256, reportedVersion: "0.1.0")
        XCTAssertEqual(HelperDeployment.verdict(for: linux, evidence: evidence), .keep)
    }

    func testACorruptedCopyOfTheRightSizeIsReplaced() {
        // The case the size check alone cannot see: same length, different bytes.
        let evidence = HelperDeployment.RemoteEvidence(
            size: linux.size, sha256: String(repeating: "f", count: 64))
        XCTAssertEqual(
            HelperDeployment.verdict(for: linux, evidence: evidence),
            .upload(reason: "the copy on the server does not match this build"))
    }

    func testAWrongSizeIsReplacedEvenWithNothingToHashWith() {
        let evidence = HelperDeployment.RemoteEvidence(size: 12)
        XCTAssertEqual(
            HelperDeployment.verdict(for: linux, evidence: evidence),
            .upload(reason: "the copy on the server is 12 bytes, not 440000"))
    }

    /// Right size, and nothing on the server could vouch for the contents - no checksum
    /// tool, and the binary would not run. Replacing it is the honest answer; running it is
    /// not.
    func testAnUnverifiableCopyIsReplacedRatherThanRun() {
        let evidence = HelperDeployment.RemoteEvidence(size: linux.size)
        XCTAssertEqual(
            HelperDeployment.verdict(for: linux, evidence: evidence),
            .upload(reason: "the server could not verify the helper's contents"))
    }

    // MARK: sharing a directory with another Mac

    func testOursIsNeverDeletedHoweverOldItIs() {
        let now: Int64 = 1_800_000_000
        let files = manifest().binaries.map {
            HelperDeployment.RemoteFile(
                name: $0.file, size: $0.size, mtime: now - 400 * 24 * 3600)
        }
        XCTAssertEqual(
            HelperDeployment.stale(files, keeping: manifest().fileNames, serverNow: now), [])
    }

    /// "Versions other than ours whose mtime is older than seven days are removed: two
    /// Macs sharing one account may run different app versions, and each keeps its own file
    /// without deleting the other's while it is in use."
    func testAnotherVersionSurvivesSevenDaysAndThenGoes() {
        let now: Int64 = 1_800_000_000
        let other = "sshdrive-helper-0.0.9-linux-aarch64"
        let fresh = [HelperDeployment.RemoteFile(name: other, size: 1, mtime: now - 6 * 24 * 3600)]
        XCTAssertEqual(HelperDeployment.stale(fresh, keeping: manifest().fileNames, serverNow: now), [])

        let old = [HelperDeployment.RemoteFile(name: other, size: 1, mtime: now - 8 * 24 * 3600)]
        XCTAssertEqual(
            HelperDeployment.stale(old, keeping: manifest().fileNames, serverNow: now), [other])
    }

    /// The directory may be `$XDG_CACHE_HOME/sshdrive` on a shared account. Anything that
    /// is not a helper of ours is never touched, whatever its age.
    func testNothingThatIsNotAHelperIsEverDeleted() {
        let now: Int64 = 1_800_000_000
        let files = [
            HelperDeployment.RemoteFile(name: "notes.txt", size: 1, mtime: 0),
            HelperDeployment.RemoteFile(name: "sshdrive", size: 1, mtime: 0),
            HelperDeployment.RemoteFile(name: "helper.log", size: 1, mtime: 0),
        ]
        XCTAssertEqual(HelperDeployment.stale(files, keeping: [], serverNow: now), [])
    }

    /// A relay FIFO is litter with no age rule. The wrapper's EXIT trap removes its own,
    /// but the trap does not run when the wrapper is SIGKILLed - which is every abrupt
    /// client kill, the case the wrapper exists for - so `helper off` on a real mount left
    /// two of them behind and the directory could not be removed (2026-09-05, `deb`).
    func testARelayFifoIsSweptWhateverItsAge() {
        let now: Int64 = 1_800_000_000
        let files = [
            HelperDeployment.RemoteFile(name: ".sshdrive-helper-in-2020583176", size: 0, mtime: now),
            HelperDeployment.RemoteFile(name: ".sshdrive-helper-in-3182005498", size: 0, mtime: now - 1),
        ]
        XCTAssertEqual(
            HelperDeployment.stale(files, keeping: manifest().fileNames, serverNow: now),
            [".sshdrive-helper-in-2020583176", ".sshdrive-helper-in-3182005498"])
    }

    // MARK: the version line

    func testTheVersionLineIsParsedIntoItsThreeClaims() {
        let parsed = HelperDeployment.parseVersionLine(
            "sshdrive-helper 0.1.0 linux/aarch64 sha256=" + String(repeating: "a", count: 64))
        XCTAssertEqual(parsed?.version, "0.1.0")
        XCTAssertEqual(parsed?.target, HelperTarget(os: "linux", arch: "aarch64"))
        XCTAssertEqual(parsed?.digest, String(repeating: "a", count: 64))
    }

    /// Anything else is a binary that is not ours, or is not a binary. A guess here would
    /// be a guess about whether to run code on someone's server.
    func testAnythingElseIsRefused() {
        for line in [
            "",
            "bash: sshdrive-helper: cannot execute binary file",
            "sshdrive-helper 0.1.0 linux/aarch64",
            "sshdrive-helper 0.1.0 linux sha256=" + String(repeating: "a", count: 64),
            "sshdrive-helper 0.1.0 linux/aarch64 sha256=short",
            "sshdrive-helper 0.1.0 linux/aarch64 sha256=" + String(repeating: "z", count: 64),
        ] {
            XCTAssertNil(HelperDeployment.parseVersionLine(line), line)
        }
    }

    /// Section 5.5's temp-file shape, so a half-written helper looks like every other
    /// half-written upload and the helper's own ignore list already covers it.
    func testTheTemporaryNameIsSection5_5s() {
        let name = HelperDeployment.temporaryName(macID: "0123456789abcdef", uuid: "UUID")
        XCTAssertEqual(name, ".sshdrive-upload-01234567-UUID")
    }
}
