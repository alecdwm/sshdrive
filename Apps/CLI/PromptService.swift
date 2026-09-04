import Foundation
import Darwin
import XPCProtocols

/// The terminal, exported to the agent for the length of one command (DESIGN.md
/// section 4.2).
///
/// "The CLI shows the prompt on the terminal, reads the answer (hidden for secrets,
/// visible for the host-key question), and returns it." That is the whole of it: the CLI
/// runs no `ssh`, holds no secret beyond the prompt, and never sees the keychain. The
/// answer goes straight back to the agent, which hands it to `ssh` and keeps it in memory
/// until the connection succeeds.
final class PromptService: NSObject, SSHDriveCLIProtocol {

    /// Everything the CLI prints while a command runs goes through here, so a note and a
    /// prompt cannot interleave halfway through a line.
    private static let lock = NSLock()

    func cliNote(_ text: String) {
        PromptService.lock.lock()
        defer { PromptService.lock.unlock() }
        PromptService.write(text + "\n")
    }

    /// Everything is written through the file handle rather than `print`, because `print`
    /// goes through stdio, which is fully buffered when stdout is a pipe: a `print` of the
    /// explanation followed by a handle write of the prompt puts them on the terminal in
    /// the wrong order, which is exactly how a transcript stops matching what happened
    /// (measured driving `add` over ssh, 2026-09-04).
    static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    func cliPrompt(
        kind: String, prompt: String, detail: String, secret: Bool,
        reply: @escaping (String?) -> Void
    ) {
        PromptService.lock.lock()
        defer { PromptService.lock.unlock() }

        if !detail.isEmpty { PromptService.write(detail + "\n") }
        // `ssh`'s own prompt text, verbatim. The host-key question already ends in "? ".
        PromptService.write(prompt.hasSuffix(" ") || prompt.hasSuffix("\n") ? prompt : prompt + " ")

        let answer = secret ? PromptService.readHidden() : readLine(strippingNewline: true)
        // On a terminal the user's own Return ends the line (and `readHidden` puts one
        // back where echo was off). On a pipe - a transcript, `script -q`, an expect-style
        // feed - nothing does, and the next line the agent writes lands on the same line
        // as the prompt, which makes a transcript unreadable.
        if isatty(STDIN_FILENO) != 1 { PromptService.write("\n") }
        reply(answer)
    }

    /// A hidden tty read (section 8: "All prompts use a hidden tty read"). On a pipe -
    /// `script -q`, an expect-style feed, a test harness - there is no terminal to turn
    /// echo off on, and the read is an ordinary line read, which is what makes the CLI
    /// scriptable at all.
    static func readHidden() -> String? {
        guard isatty(STDIN_FILENO) == 1 else {
            return readLine(strippingNewline: true)
        }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return readLine(strippingNewline: true)
        }
        var quiet = original
        quiet.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet)
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            PromptService.write("\n")
        }
        return readLine(strippingNewline: true)
    }

    /// A visible confirmation the CLI asks on its own account, for `remove`'s
    /// "are you sure" (section 8). Not a relayed prompt: nothing on the agent side is
    /// waiting on it.
    static func confirm(_ question: String) -> Bool {
        write("\(question) [y/N] ")
        let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
        if isatty(STDIN_FILENO) != 1 { write("\n") }
        return answer.lowercased() == "y" || answer.lowercased() == "yes"
    }
}
