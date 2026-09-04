import Foundation
import XPCProtocols
import Logging

/// The terminal, as the agent sees it (DESIGN.md section 4.2).
///
/// "The CLI does not run `ssh`. It asks the agent to make the verification connection …
/// For every prompt the agent has no stored answer for, it calls back to the CLI over the
/// same XPC connection." This is that call, made synchronous: the askpass broker's
/// `collectResponder` is a plain closure because `ssh` is blocked on the askpass process,
/// which is blocked on the agent, so there is nothing to be gained by making the wait
/// asynchronous and a great deal to be lost by letting the reply arrive after `ssh` has
/// given up.
///
/// A relay only exists while a CLI command of the user's own making is in flight. Nothing
/// the extension or a timer does can reach a terminal.
final class CLIRelay: @unchecked Sendable {

    /// Long enough for a person to read a fingerprint off the screen and type a password,
    /// and shorter than the collect token's own 300 s.
    static let promptTimeout: TimeInterval = 240

    private let proxy: SSHDriveCLIProtocol

    init?(connection: NSXPCConnection?) {
        guard let connection else { return nil }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            Log.cli.error("callback to the CLI failed: \(error, privacy: .public)")
        }) as? SSHDriveCLIProtocol else { return nil }
        self.proxy = proxy
    }

    /// A line for the terminal while a long command runs. Fire and forget: a `add` that
    /// cannot narrate itself is still an `add`.
    func note(_ text: String) {
        proxy.cliNote(text)
    }

    /// One prompt, answered on the terminal. Nil means the CLI could not be asked, which
    /// the broker treats exactly as "no stored answer and nobody to ask".
    func prompt(kind: String, prompt text: String, detail: String, secret: Bool) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var answer: String?
        var answered = false
        proxy.cliPrompt(kind: kind, prompt: text, detail: detail, secret: secret) { reply in
            answer = reply
            answered = true
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + CLIRelay.promptTimeout) == .timedOut {
            Log.cli.error("the terminal did not answer a relayed prompt in time")
            return nil
        }
        return answered ? answer : nil
    }
}
