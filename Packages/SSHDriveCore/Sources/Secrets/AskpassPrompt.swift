import Foundation

/// What `ssh` is asking for, as the agent classifies it (DESIGN.md section 4.2's table).
///
/// The strings are OpenSSH's own format strings, verified against `OpenSSH_10.2p1` on the
/// build VM (`strings /usr/bin/ssh`) and captured live from the testbed with an
/// `SSH_ASKPASS` that logs its argument (docs/spikes/results.md, "S2 askpass"):
///
///     "%s@%s's password: "                        sshconnect2.c, password auth
///     "(%s@%s) %s"                                keyboard-interactive, server text last
///     "Enter passphrase for key '%.100s': "       a key file being decrypted
///     "The authenticity of host '%.200s (%s)' can't be established" ...
///         "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
///     "Warning: the %s host key for '%.200s' differs from the key for the IP address ..."
///     "Confirm user presence for key %s %s"       a FIDO key's touch
///     "Enter PIN for %s key %s: ", "Enter PIN for '%s': "
public enum AskpassPrompt: Equatable, Sendable {
    /// `Enter passphrase for key '<path>': `. The path is `%.100s`-truncated by `ssh`, so
    /// it is a *prefix* of the real identity file, not necessarily the whole of it.
    case passphrase(keyPathPrefix: String)

    /// `<user>@<hostname>'s password: `. The identity in the prompt is `ssh`'s own view
    /// of the destination, with `HostKeyAlias` substituted for the hostname when the
    /// config sets one - which is why the keychain key is built from the `ssh -G`
    /// resolution and not from this text (section 4.2).
    case password(promptUser: String, promptHost: String)

    /// A keyboard-interactive prompt whose server-supplied text is a password question.
    /// Nothing is parsed out of it for keying (section 4.2).
    case keyboardInteractivePassword(promptUser: String, promptHost: String, question: String)

    /// A keyboard-interactive prompt that is *not* a password: a one-time code, a
    /// challenge. Refused, and refused at `add` too (section 4.2).
    case keyboardInteractiveChallenge(question: String)

    /// The host-key question of section 4.3, and any other yes/no confirmation.
    /// `isHostKey` is true when the text is `ssh`'s own host-key question.
    case confirmation(question: String, isHostKey: Bool)

    /// `SSH_ASKPASS_PROMPT=none`: a notification, not a question. The FIDO
    /// user-presence notice is the one that matters (section 4.2).
    case userPresence(keyDescription: String)

    /// Any other notification with `SSH_ASKPASS_PROMPT=none`.
    case notification(text: String)

    /// A smartcard or FIDO PIN. Always refused: it needs a human every time.
    case pin(text: String)

    /// Anything else. Refused.
    case unrecognised(text: String)
}

public enum AskpassPromptClassifier {

    /// `SSH_ASKPASS_PROMPT` values `ssh` sets. Unset (empty) means a secret.
    public static let confirmHint = "confirm"
    public static let noneHint = "none"

    /// Classify one askpass invocation.
    ///
    /// `promptKind` is `SSH_ASKPASS_PROMPT` exactly as `ssh` set it, or "" when unset.
    ///
    /// **The host-key question does not carry a hint.** Section 4.2 and section 4.3 both
    /// say it arrives with `SSH_ASKPASS_PROMPT=confirm`; on OpenSSH 10.2p1 it does not -
    /// `ssh` only sets the hint for `RP_ASK_PERMISSION` ("confirm") and `notify_start`
    /// ("none"), and the host-key question goes through `read_passphrase(..., RP_ECHO)`
    /// with no hint at all. It therefore looks exactly like a secret prompt, and if it
    /// were classified as one the agent would answer a stored password to
    /// "Are you sure you want to continue connecting". So the text is what decides, and
    /// the hint only confirms (docs/spikes/results.md, "S2 askpass", 2026-09-04).
    public static func classify(prompt: String, promptKind: String) -> AskpassPrompt {
        let kind = promptKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let text = prompt

        // A notification. ssh reads nothing back from us.
        if kind == noneHint {
            if let description = userPresenceKey(in: text) {
                return .userPresence(keyDescription: description)
            }
            return .notification(text: text)
        }

        // The host-key question, by its text, whatever the hint says.
        if isHostKeyQuestion(text) {
            return .confirmation(question: text, isHostKey: true)
        }
        if kind == confirmHint {
            return .confirmation(question: text, isHostKey: false)
        }

        // A user-presence notice that reached us without the hint (a FIDO key under a
        // ProxyCommand, where the environment is rebuilt) is still a notice.
        if let description = userPresenceKey(in: text) {
            return .userPresence(keyDescription: description)
        }

        if text.hasPrefix("Enter PIN for ") || text.hasPrefix("Enter PIN") {
            return .pin(text: text)
        }

        if let path = passphrasePath(in: text) {
            return .passphrase(keyPathPrefix: path)
        }

        if let (user, host) = passwordIdentity(in: text) {
            return .password(promptUser: user, promptHost: host)
        }

        if let (user, host, question) = keyboardInteractive(in: text) {
            if isPasswordQuestion(question) {
                return .keyboardInteractivePassword(
                    promptUser: user, promptHost: host, question: question)
            }
            return .keyboardInteractiveChallenge(question: question)
        }

        // A bare "Password: " with no (user@host) wrapper: some servers' PAM stacks under
        // a ProxyCommand. Treated as a password question; the destination comes from the
        // asking ssh's own resolution either way.
        if isPasswordQuestion(text) {
            return .keyboardInteractivePassword(promptUser: "", promptHost: "", question: text)
        }

        return .unrecognised(text: text)
    }

    // MARK: the individual shapes

    /// `Enter passphrase for key '<path>': `
    static func passphrasePath(in text: String) -> String? {
        let prefix = "Enter passphrase for key '"
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        guard let close = rest.range(of: "': ", options: .backwards)
            ?? rest.range(of: "':", options: .backwards)
        else { return nil }
        let path = String(rest[rest.startIndex..<close.lowerBound])
        return path.isEmpty ? nil : path
    }

    /// `<user>@<host>'s password: `
    static func passwordIdentity(in text: String) -> (user: String, host: String)? {
        let marker = "'s password:"
        guard let range = text.range(of: marker, options: .backwards),
            range.upperBound == text.endIndex
                || text[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let head = String(text[text.startIndex..<range.lowerBound])
        guard let at = head.lastIndex(of: "@") else { return nil }
        let user = String(head[head.startIndex..<at])
        let host = String(head[head.index(after: at)...])
        guard !user.isEmpty, !host.isEmpty, !user.contains(" ") else { return nil }
        return (user, host)
    }

    /// `(<user>@<host>) <server text>` - keyboard-interactive.
    static func keyboardInteractive(in text: String) -> (user: String, host: String, question: String)? {
        guard text.hasPrefix("("), let close = text.firstIndex(of: ")") else { return nil }
        let inside = String(text[text.index(after: text.startIndex)..<close])
        guard let at = inside.lastIndex(of: "@") else { return nil }
        let user = String(inside[inside.startIndex..<at])
        let host = String(inside[inside.index(after: at)...])
        guard !user.isEmpty, !host.isEmpty else { return nil }
        var question = String(text[text.index(after: close)...])
        if question.hasPrefix(" ") { question.removeFirst() }
        return (user, host, question)
    }

    /// `Confirm user presence for key ED25519-SK SHA256:...`
    static func userPresenceKey(in text: String) -> String? {
        let prefix = "Confirm user presence for key "
        guard let range = text.range(of: prefix) else { return nil }
        let description = text[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? nil : description
    }

    /// The host-key question, either the unknown-host form or the differs-from-IP form.
    /// Both end in `Are you sure you want to continue connecting`.
    static func isHostKeyQuestion(_ text: String) -> Bool {
        text.contains("Are you sure you want to continue connecting")
            || text.contains("The authenticity of host ")
    }

    /// Is this server-supplied keyboard-interactive text a password question, or a
    /// one-time code? Section 4.2 refuses the second, attended or not.
    static func isPasswordQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let refusals = [
            "verification code", "one-time", "one time", "otp", "token",
            "authenticator", "duo", "challenge", "response:", "passcode",
        ]
        for refusal in refusals where lower.contains(refusal) { return false }
        return lower.contains("password")
    }
}
