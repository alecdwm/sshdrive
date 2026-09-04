import Foundation

/// POSIX `sh` single-quoting, the one quoting rule this project has (DESIGN.md section 9.2).
///
/// Used in two places that look unrelated and are not: the values a remote `sh -s` script
/// embeds through `set --`, and the `ProxyCommand` string the agent builds for a
/// `ProxyJump` hop, which `ssh` hands to `/bin/sh -c` (section 6.1). Both are "a string
/// that a POSIX shell must see verbatim", so both go through here.
public enum ShellQuoting {

    /// Wraps `value` in single quotes, writing an embedded `'` as `'\''`.
    ///
    /// The empty string quotes to `''`, which is a real argument rather than nothing.
    /// Nothing else is special inside single quotes, not `$`, not a backslash, not a
    /// newline, so this is total: there is no input it cannot carry.
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A whole argument vector as one `sh -c` command line.
    public static func commandLine(_ arguments: [String]) -> String {
        arguments.map(singleQuoted).joined(separator: " ")
    }
}
