import XCTest
@testable import AgentCore

/// DESIGN.md section 6.1's `MaxSessions` probe: a channel that did not open is only
/// evidence about the server while the connection under it was alive (2026-09-08).
final class ChannelProbeVerdictTests: XCTestCase {

    private func classify(_ text: String, masterIsRunning: Bool = true) -> ChannelProbeVerdict {
        ChannelProbeVerdict.classify(diagnostics: text, masterIsRunning: masterIsRunning)
    }

    /// The one thing a refused session actually prints.
    func testTheMuxRefusalIsASessionRefusal() {
        XCTAssertEqual(
            classify("mux_client_request_session: session request failed: Session open refused"),
            .sessionRefused)
    }

    func testAnAdministrativelyProhibitedOpenIsARefusal() {
        XCTAssertEqual(
            classify("channel 0: open failed: administratively prohibited: open failed"),
            .sessionRefused)
    }

    /// A master that has gone makes every channel open fail, and none of those failures
    /// says anything about `MaxSessions`. This is the case that produced "the server allows
    /// one channel at a time (MaxSessions 1)" against a healthy Debian on a real install.
    func testADeadMasterIsNeverARefusalWhateverTheTextSays() {
        XCTAssertEqual(
            classify("mux_client_request_session: session request failed", masterIsRunning: false),
            .connectionDied)
        XCTAssertEqual(classify("", masterIsRunning: false), .connectionDied)
    }

    /// What `ssh` prints when the socket is gone, the peer went, or nothing answered.
    func testTheConnectionDeathsAreRecognised() {
        let deaths = [
            "Control socket connect(/var/folders/T/sshdrive-3966f55c): No such file or directory",
            "mux_client_hello_exchange: write packet: Broken pipe",
            "Connection closed by remote host",
            "Connection reset by peer",
            "Connection to spike-deb closed by remote host.",
            "connect to host spike-deb port 2201: Connection refused",
            "client_loop: send disconnect: Broken pipe",
            "ssh: connect to host nas port 22: Operation timed out",
            "ssh: connect to host nas port 22: No route to host",
            "connectionLost",
        ]
        for text in deaths {
            XCTAssertEqual(classify(text), .connectionDied, text)
        }
    }

    /// Wording we have never seen, on a master that is still there, still has to produce a
    /// budget: a location that cannot settle on a tier is worse than one that settles on a
    /// pessimistic tier, and `sshdrive debug transport reprobe` is the way out.
    func testAnUnfamiliarRefusalStillCountsAsARefusal() {
        XCTAssertEqual(classify("some sshd nobody here has ever run said no"), .sessionRefused)
    }
}
