import XCTest
import Config
@testable import XPCProtocols

/// NSXPC rebuilds an NSError from domain, code and userInfo, and a Swift LocalizedError's
/// description is not in userInfo, so it does not survive the trip: the CLI saw
/// "Config.ConfigStoreError error 1" instead of the message (docs/spikes/results.md,
/// 2026-09-04). `sshDriveXPCError` is what puts it there.
final class XPCErrorTests: XCTestCase {

    func testLocalizedErrorDescriptionIsWrittenIntoUserInfo() {
        let error = ConfigStoreError.unknownLocation("nas")
        let flattened = sshDriveXPCError(error)

        // This is the assertion that fails without the fix: a bridged Swift error has an
        // empty userInfo, so the far side falls back to "<domain> error <code>".
        XCTAssertEqual(
            flattened.userInfo[NSLocalizedDescriptionKey] as? String,
            "No location matches \"nas\".")
        XCTAssertEqual(flattened.localizedDescription, "No location matches \"nas\".")

        // Rebuilding it the way NSXPC does must keep the message.
        let rebuilt = NSError(
            domain: flattened.domain, code: flattened.code, userInfo: flattened.userInfo)
        XCTAssertEqual(rebuilt.localizedDescription, "No location matches \"nas\".")
    }

    func testAgentErrorKeepsItsDomainAndCode() {
        let error = SSHDriveAgentError.unknownDomain.asNSError("No location abc.")
        let flattened = sshDriveXPCError(error)
        XCTAssertEqual(flattened.sshDriveAgentError, .unknownDomain)
        XCTAssertEqual(flattened.localizedDescription, "No location abc.")
    }

    func testNonStringUserInfoValuesAreDropped() {
        let original = NSError(
            domain: "org.shirls.test", code: 7,
            userInfo: ["message": "kept", "object": NSObject()])
        let flattened = sshDriveXPCError(original)
        XCTAssertEqual(flattened.userInfo["message"] as? String, "kept")
        XCTAssertNil(flattened.userInfo["object"])
    }

    func testUnderlyingErrorIsFlattenedToo() {
        let inner = ConfigStoreError.ambiguousLocation("na", ["nas", "nash"])
        let outer = NSError(
            domain: "org.shirls.test", code: 1, userInfo: [NSUnderlyingErrorKey: inner])
        let flattened = sshDriveXPCError(outer)
        let underlying = flattened.userInfo[NSUnderlyingErrorKey] as? NSError
        XCTAssertEqual(
            underlying?.userInfo[NSLocalizedDescriptionKey] as? String,
            "\"na\" matches nas, nash.")
    }
}
