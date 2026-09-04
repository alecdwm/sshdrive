import XCTest

@testable import Secrets

/// The prompt strings are not invented: every one below was captured from
/// `OpenSSH_10.2p1, LibreSSL 3.3.6` on the build VM by pointing `SSH_ASKPASS` at a script
/// that logged `argv[1]` and `SSH_ASKPASS_PROMPT`, running against the spike testbed
/// (docs/spikes/results.md, "S2 askpass", 2026-09-04). The trailing spaces are real and
/// are part of OpenSSH's own format strings.
final class AskpassPromptTests: XCTestCase {

    // MARK: the captured strings

    /// `%s@%s's password: ` - sshconnect2.c, password auth. Captured against
    /// `pw@192.168.64.1:2201`.
    static let passwordPrompt = "pw@192.168.64.1's password: "
    /// `Enter passphrase for key '%.100s': `. Captured for `~/.ssh/sshdrive-spike-enc`,
    /// which `ssh` prints expanded.
    static let passphrasePrompt =
        "Enter passphrase for key '/Users/alec/.ssh/sshdrive-spike-enc': "
    /// `(%s@%s) %s` - keyboard-interactive, the tail supplied by the server's PAM stack.
    /// Captured against `kbd@192.168.64.1:2204`.
    static let keyboardInteractivePrompt = "(kbd@192.168.64.1) Password: "
    /// The host-key question, captured with an empty `known_hosts` and
    /// `StrictHostKeyChecking=ask`. **`SSH_ASKPASS_PROMPT` was unset**, not "confirm".
    static let hostKeyPrompt = """
        The authenticity of host '[192.168.64.1]:2201 ([192.168.64.1]:2201)' can't be established.
        ED25519 key fingerprint is: SHA256:sZBoBnxDlU39oYKVYqzjq1RLWQPpnryr1+EXhXWDt3w
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
    /// `Confirm user presence for key %s %s`, from `strings /usr/bin/ssh`. No FIDO key is
    /// attached to the VM, so this one is the format string rather than a live capture.
    static let userPresencePrompt =
        "Confirm user presence for key ED25519-SK SHA256:sZBoBnxDlU39oYKVYqzjq1RLWQPpnryr1+EXhXWDt3w"

    // MARK: classification

    func testPasswordPrompt() {
        let classified = AskpassPromptClassifier.classify(
            prompt: Self.passwordPrompt, promptKind: "")
        XCTAssertEqual(classified, .password(promptUser: "pw", promptHost: "192.168.64.1"))
    }

    func testPasswordPromptWithAHostKeyAliasStillClassifiesAsAPassword() {
        // With HostKeyAlias set, ssh prints the alias. The classifier reports what the
        // prompt said; the key is built from the ssh -G resolution, never from this.
        let classified = AskpassPromptClassifier.classify(
            prompt: "alec@nas-alias's password: ", promptKind: "")
        XCTAssertEqual(classified, .password(promptUser: "alec", promptHost: "nas-alias"))
    }

    func testPassphrasePrompt() {
        let classified = AskpassPromptClassifier.classify(
            prompt: Self.passphrasePrompt, promptKind: "")
        XCTAssertEqual(
            classified, .passphrase(keyPathPrefix: "/Users/alec/.ssh/sshdrive-spike-enc"))
    }

    func testKeyboardInteractivePasswordPrompt() {
        let classified = AskpassPromptClassifier.classify(
            prompt: Self.keyboardInteractivePrompt, promptKind: "")
        XCTAssertEqual(
            classified,
            .keyboardInteractivePassword(
                promptUser: "kbd", promptHost: "192.168.64.1", question: "Password: "))
    }

    func testKeyboardInteractiveOneTimeCodeIsAChallengeAndIsRefused() {
        let classified = AskpassPromptClassifier.classify(
            prompt: "(alec@nas) Verification code: ", promptKind: "")
        XCTAssertEqual(
            classified, .keyboardInteractiveChallenge(question: "Verification code: "))
    }

    /// The finding that matters: section 4.2 and section 4.3 both say the host-key
    /// question arrives with `SSH_ASKPASS_PROMPT=confirm`. On OpenSSH 10.2p1 it arrives
    /// with the variable **unset**, so it is indistinguishable from a secret prompt by
    /// the hint alone - and a classifier that trusted the hint would answer a stored
    /// password to "Are you sure you want to continue connecting".
    func testHostKeyQuestionIsRecognisedWithNoHint() {
        let classified = AskpassPromptClassifier.classify(
            prompt: Self.hostKeyPrompt, promptKind: "")
        XCTAssertEqual(classified, .confirmation(question: Self.hostKeyPrompt, isHostKey: true))
    }

    func testHostKeyQuestionIsNotMistakenForAPassword() {
        let classified = AskpassPromptClassifier.classify(
            prompt: Self.hostKeyPrompt, promptKind: "")
        if case .password = classified { XCTFail("the host-key question read as a password") }
        if case .keyboardInteractivePassword = classified {
            XCTFail("the host-key question read as a keyboard-interactive password")
        }
    }

    func testTheDiffersFromIPHostKeyQuestionIsAlsoAConfirmation() {
        let prompt = """
            Warning: the ED25519 host key for 'nas' differs from the key for the IP address '10.0.0.4'
            Are you sure you want to continue connecting (yes/no)?
            """
        XCTAssertEqual(
            AskpassPromptClassifier.classify(prompt: prompt, promptKind: ""),
            .confirmation(question: prompt, isHostKey: true))
    }

    func testAConfirmHintIsAConfirmationEvenWithUnknownText() {
        XCTAssertEqual(
            AskpassPromptClassifier.classify(prompt: "Allow use of key nas?", promptKind: "confirm"),
            .confirmation(question: "Allow use of key nas?", isHostKey: false))
    }

    func testUserPresenceNoticeUnderTheNoneHint() {
        XCTAssertEqual(
            AskpassPromptClassifier.classify(prompt: Self.userPresencePrompt, promptKind: "none"),
            .userPresence(
                keyDescription:
                    "ED25519-SK SHA256:sZBoBnxDlU39oYKVYqzjq1RLWQPpnryr1+EXhXWDt3w"))
    }

    func testUserPresenceNoticeIsRecognisedWithoutTheHintToo() {
        XCTAssertEqual(
            AskpassPromptClassifier.classify(prompt: Self.userPresencePrompt, promptKind: ""),
            .userPresence(
                keyDescription:
                    "ED25519-SK SHA256:sZBoBnxDlU39oYKVYqzjq1RLWQPpnryr1+EXhXWDt3w"))
    }

    func testAnyOtherNoneHintIsANotification() {
        XCTAssertEqual(
            AskpassPromptClassifier.classify(prompt: "User presence confirmed", promptKind: "none"),
            .notification(text: "User presence confirmed"))
    }

    func testPINPrompts() {
        // Both of OpenSSH 10.2's PIN format strings.
        XCTAssertEqual(
            AskpassPromptClassifier.classify(
                prompt: "Enter PIN for ED25519-SK key /Users/alec/.ssh/id_ed25519_sk: ",
                promptKind: ""),
            .pin(text: "Enter PIN for ED25519-SK key /Users/alec/.ssh/id_ed25519_sk: "))
        XCTAssertEqual(
            AskpassPromptClassifier.classify(prompt: "Enter PIN for 'token': ", promptKind: ""),
            .pin(text: "Enter PIN for 'token': "))
    }

    func testAnythingElseIsUnrecognised() {
        XCTAssertEqual(
            AskpassPromptClassifier.classify(prompt: "Something new: ", promptKind: ""),
            .unrecognised(text: "Something new: "))
    }

    func testABarePasswordQuestionIsTreatedAsKeyboardInteractive() {
        XCTAssertEqual(
            AskpassPromptClassifier.classify(prompt: "Password: ", promptKind: ""),
            .keyboardInteractivePassword(promptUser: "", promptHost: "", question: "Password: "))
    }
}
