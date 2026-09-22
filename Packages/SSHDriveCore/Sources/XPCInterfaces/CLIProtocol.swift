#if canImport(Darwin)

import Foundation

/// The CLI's own exported interface, for the one thing the agent has to ask a terminal
/// (docs/design/secrets.md, docs/design/cli.md).
///
/// The CLI does not run `ssh`. It asks the agent to make the verification connection. For
/// every prompt the agent has no stored answer for, the agent calls back to the CLI over
/// the same XPC connection; the CLI shows the prompt on the terminal, reads the answer
/// (hidden for secrets, visible for the host-key question), and returns it.
///
/// So this is a callback interface and not a second request channel: the agent only ever
/// speaks on it while a `control` command of the CLI's own making is in flight. The CLI
/// exports it before it resumes the connection; the listener hands a `sshdrive` peer this
/// as its `remoteObjectInterface` and everyone else the extension's, exactly as it hands
/// `sshdrive-askpass` the askpass interface (docs/design/extension.md).
@objc public protocol SSHDriveCLIProtocol {

    /// One prompt from the collect connection, relayed to the terminal.
    ///
    /// - Parameters:
    ///   - kind: `password`, `passphrase`, `hostkey`, `confirm` or `notice`. The CLI uses
    ///     it only to decide the wording around the prompt; the prompt text itself is
    ///     `ssh`'s, verbatim.
    ///   - prompt: `ssh`'s own prompt text.
    ///   - detail: an extra line the agent wants above the prompt (which keychain item the
    ///     answer will be stored under, or the Enter-to-skip explanation of
    ///     docs/design/secrets.md).
    ///   - secret: read with a hidden tty read. The host-key question is read visible
    ///     (docs/design/secrets.md).
    ///   - reply: the user's answer, or nil if the terminal could not be read. An empty
    ///     string is a deliberate refusal of that prompt, which is `ssh`'s "skip this
    ///     identity" and the flow's "fail this attempt over".
    @objc(cliPromptOfKind:prompt:detail:secret:reply:)
    func cliPrompt(
        kind: String,
        prompt: String,
        detail: String,
        secret: Bool,
        reply: @escaping (String?) -> Void
    )

    /// A line to print on the terminal while a long command runs, so `add` can narrate the
    /// resolution, the environment warning and each pass rather than falling silent for
    /// half a minute.
    @objc(cliNote:)
    func cliNote(_ text: String)
}

extension SSHDriveXPCInterface {
    /// The interface a `sshdrive` peer exports and the agent calls back on.
    public static var cli: NSXPCInterface {
        NSXPCInterface(with: SSHDriveCLIProtocol.self)
    }
}

#endif
