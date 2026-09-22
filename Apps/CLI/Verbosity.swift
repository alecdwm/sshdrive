import ArgumentParser
import Foundation
import Logging

/// `-v` / `--verbose`, accepted by every command.
///
/// A command that changes something prints nothing on success: the exit status is the
/// answer, and what the user must still read - a prompt that needs an answer, a warning,
/// an error - is printed whatever the flag says. `-v` prints the command's full report,
/// including the parts the agent relays over the connection while the command runs.
///
/// Reporting commands (`list`, `show`, `status`, `pins`, `doctor`, `logs`) print their
/// report either way and accept the flag so it can be typed anywhere.
///
/// It is an `@OptionGroup` on each subcommand rather than a flag on the root, so it is
/// written after the subcommand: `sshdrive add -v alec@nas`.
struct GlobalOptions: ParsableArguments {
    @Flag(name: [.customShort("v"), .customLong("verbose")],
          help: "Print what the command did, and what the agent said while doing it.")
    var verbose = false

    /// A line that belongs to the command's own report: printed only under `-v`.
    func detail(_ text: String) {
        if verbose { print(text) }
    }

    /// A warning, a refusal, or a command that found nothing to do. Printed whatever the
    /// flag says, on stderr, so a script reading stdout for results is not fed prose.
    func warn(_ text: String) {
        standardError(text)
    }
}
