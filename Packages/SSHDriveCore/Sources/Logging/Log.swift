import Foundation
import os

/// os.Logger subsystems and categories, fixed by DESIGN.md section 3.1.
///
/// Hostnames and paths are logged `.public` by decision (DESIGN.md section 9), so
/// `sshdrive logs` is readable without a debugger attached. Secrets never reach a log
/// line at all: they are not interpolated, redacted or otherwise.
public enum Log {
    public static let subsystem = "org.shirls.sshdrive"

    public static let extensionLog = Logger(subsystem: subsystem, category: "extension")
    public static let agent = Logger(subsystem: subsystem, category: "agent")
    public static let cli = Logger(subsystem: subsystem, category: "cli")
    public static let sftp = Logger(subsystem: subsystem, category: "sftp")
    public static let ssh = Logger(subsystem: subsystem, category: "ssh")

    /// The askpass tool logs under the ssh category: its lines only ever describe a
    /// prompt that ssh raised.
    public static let askpass = Logger(subsystem: subsystem, category: "ssh")
}

/// Writes a line to stderr. Used by the CLI and askpass, which have a terminal but also
/// log to the unified log through `Log`.
public func standardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
