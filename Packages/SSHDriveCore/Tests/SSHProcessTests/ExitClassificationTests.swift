import XCTest
@testable import SSHProcess

/// The exit classification (docs/design/ssh.md) that decides whether the agent
/// reconnects, stops until the user acts, or waits for a key agent.
final class ExitClassificationTests: XCTestCase {

    private func classify(
        role: SSHRole = .master, status: Int32 = 255, stderr: String,
        channelOpened: Bool = true, deadlineExpired: Bool = false, agentDependent: Bool = false,
        keyAgentSocketFailed: Bool = false, sentPassword: Bool = false
    ) -> SSHExitClassification {
        SSHExitClassifier.classify(
            role: role, exitStatus: status, stderr: stderr,
            channelOpened: channelOpened, deadlineExpired: deadlineExpired,
            agentDependent: agentDependent, keyAgentSocketFailed: keyAgentSocketFailed,
            sentPassword: sentPassword
        )
    }

    func testAuthenticationFailuresStopReconnection() {
        for text in [
            "alec@nas: Permission denied (publickey,password).",
            "Received disconnect from 10.0.0.1 port 22:2: Too many authentication failures",
            "nas: No supported authentication methods available (server sent: publickey)",
        ] {
            let result = classify(stderr: text)
            XCTAssertEqual(result, .authenticationFailed, text)
            XCTAssertTrue(result.stopsReconnection)
            XCTAssertFalse(result.isReArmable, "refusals are never re-armed")
            XCTAssertTrue(result.retriesSlowly, "a refusal is retried on the slow schedule")
        }
        XCTAssertTrue(SSHExitClassification.hostKeyFailed.retriesSlowly)
        XCTAssertFalse(
            SSHExitClassification.authenticationDeadline.retriesSlowly,
            "an unattended attempt at a deadline stop can raise a prompt nobody answers")
    }

    /// Gotcha 40: a missing, dead or locked key agent all end in the same bare
    /// `Permission denied (publickey)`, and so does a key the server refused. Only the
    /// socket check tells them apart: with the socket missing or refusing it is the key
    /// agent not being ready, on its own backoff; with the socket there it is a refusal,
    /// on the slow retry.
    func testABarePublickeyDenialIsTheKeyAgentOnlyWhenItsSocketFailed() {
        for text in [
            "alec@nas: Permission denied (publickey).\r\n",
            "Permission denied (publickey).",
            "alec@nas: Permission denied (publickey).\r\nalec@nas: Permission denied (publickey).\r\n",
        ] {
            XCTAssertEqual(
                classify(stderr: text, agentDependent: true, keyAgentSocketFailed: true),
                .keyAgentNotReady, text)
            XCTAssertEqual(
                classify(stderr: text, agentDependent: true), .authenticationFailed,
                "a socket that answered: the server refused the key - \(text)")
            XCTAssertEqual(classify(stderr: text, agentDependent: false), .authenticationFailed, text)
        }
        // Anything more than the bare line is a server answering about something else.
        for text in [
            "alec@nas: Permission denied (publickey,password).",
            "Received disconnect from 10.0.0.1 port 22:2: Too many authentication failures\r\nalec@nas: Permission denied (publickey).",
        ] {
            XCTAssertEqual(
                classify(stderr: text, agentDependent: true, keyAgentSocketFailed: true),
                .authenticationFailed, text)
        }
        // A mux client never authenticates, so the rule is the master's alone.
        XCTAssertEqual(
            classify(
                role: .collect, stderr: "Permission denied (publickey).", agentDependent: true,
                keyAgentSocketFailed: true),
            .authenticationFailed)
    }

    /// A refusal after the broker served a password or keyboard-interactive prompt is a
    /// failed password on the server's count, and nothing retries it on its own. The
    /// method list in stderr does not decide: `(publickey,password)` is what the server
    /// allows, and says nothing about what this connection sent.
    func testARefusalAfterAPasswordPromptIsPasswordRefused() {
        for text in [
            "alec@nas: Permission denied (publickey,password).",
            "alec@nas: Permission denied (keyboard-interactive).",
            "Received disconnect from 10.0.0.1 port 22:2: Too many authentication failures",
        ] {
            let result = classify(stderr: text, sentPassword: true)
            XCTAssertEqual(result, .passwordRefused, text)
            XCTAssertTrue(result.stopsReconnection)
            XCTAssertFalse(result.retriesSlowly, "no slow retry and no early retry")
            XCTAssertFalse(result.isReArmable)
            XCTAssertEqual(classify(stderr: text), .authenticationFailed, text)
        }
        XCTAssertEqual(
            classify(stderr: "Host key verification failed.", sentPassword: true), .hostKeyFailed)
        XCTAssertEqual(
            classify(stderr: "ssh: connect to host nas port 22: Connection refused", sentPassword: true),
            .transient)
    }

    func testHostKeyFailuresStopReconnection() {
        for text in [
            "Host key verification failed.",
            "@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@",
            "Unable to negotiate with 10.0.0.1 port 22: no matching host key type found.",
        ] {
            let result = classify(stderr: text)
            XCTAssertEqual(result, .hostKeyFailed, text)
            XCTAssertTrue(result.stopsReconnection)
        }
    }

    func testConnectionErrorsAreTransient() {
        for text in [
            "ssh: connect to host nas port 22: Connection refused",
            "ssh: connect to host nas port 22: Operation timed out",
            "kex_exchange_identification: Connection closed by remote host",
            "ssh: Could not resolve hostname nas: nodename nor servname provided",
            "client_loop: send disconnect: Broken pipe",
        ] {
            let result = classify(stderr: text)
            XCTAssertEqual(result, .transient, text)
            XCTAssertFalse(result.stopsReconnection)
            XCTAssertEqual(result.backoffCapSeconds, 60)
        }
    }

    /// `agent refused operation` is what 1Password and Secretive produce between login and
    /// their first unlock. Retried, with the backoff cap raised to five minutes.
    func testKeyAgentNotReadyIsRetriedWithARaisedCap() {
        let result = classify(stderr: "sign_and_send_pubkey: signing failed for ED25519 \"key\": agent refused operation")
        XCTAssertEqual(result, .keyAgentNotReady)
        XCTAssertFalse(result.stopsReconnection)
        XCTAssertEqual(result.backoffCapSeconds, 300)
    }

    /// A mux client that exits before its channel opened is always master lost, never an
    /// authentication failure: it runs BatchMode=yes with no token, so anything that
    /// reads like auth is really the missing socket.
    func testMuxClientWithoutAChannelIsAlwaysMasterLost() {
        for text in [
            "ssh: connect to host nas port 22: Connection refused",
            "alec@nas: Permission denied (publickey).",
            "Host key verification failed.",
            "",
        ] {
            XCTAssertEqual(
                classify(role: .muxClient, stderr: text, channelOpened: false),
                .masterLost, text
            )
        }
    }

    func testAMuxClientThatDidOpenItsChannelIsClassifiedNormally() {
        XCTAssertEqual(
            classify(role: .muxClient, status: 0, stderr: "", channelOpened: true),
            .clean
        )
    }

    /// MaxSessions: the refusal must not read as master lost, or the agent would drop and
    /// rebuild the master only for the same channel to be refused again.
    func testChannelLimitBeatsTheMuxRule() {
        XCTAssertEqual(
            classify(role: .muxClient,
                     stderr: "mux_client_request_session: session request failed: Session open refused by peer",
                     channelOpened: false),
            .channelLimitReached
        )
        XCTAssertFalse(SSHExitClassification.channelLimitReached.stopsReconnection)
    }

    /// The 60 s deadline stops an agentDependent location, and is the one stop that is
    /// re-armed. For a first-pass location, which no key agent can be holding up, the
    /// same timeout is transient.
    func testDeadlineDependsOnWhetherAKeyAgentCouldBeHoldingItUp() {
        let dependent = classify(stderr: "", deadlineExpired: true, agentDependent: true)
        XCTAssertEqual(dependent, .authenticationDeadline)
        XCTAssertTrue(dependent.stopsReconnection)
        XCTAssertTrue(dependent.isReArmable)

        let firstPass = classify(stderr: "", deadlineExpired: true, agentDependent: false)
        XCTAssertEqual(firstPass, .transient)
        XCTAssertFalse(firstPass.stopsReconnection)
    }

    func testCleanExit() {
        XCTAssertEqual(classify(status: 0, stderr: ""), .clean)
        XCTAssertEqual(
            SSHExitClassifier.classify(role: .master, exitStatus: -1, terminationSignal: SIGKILL, stderr: ""),
            .transient
        )
    }
}
