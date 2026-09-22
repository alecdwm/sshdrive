import Foundation

#if canImport(os)
    import os
#endif

#if canImport(os)
    /// The logger type behind `Log`: Apple's, on any platform that has `os`.
    ///
    /// The subsystem, the five categories and the `os_log` machinery (its lazy
    /// interpolation, its privacy handling and its persistence rules) are Apple's, which is
    /// what `sshdrive logs`' predicates match on (docs/design/cli.md).
    public typealias SSHDriveLog = os.Logger
#else
    /// The logger type behind `Log` where there is no `os`: the stderr backend of
    /// `LogFacade.swift`, with the same method names and the same `privacy:` labels.
    public typealias SSHDriveLog = SSHDriveLogger
#endif

/// Logging subsystems and categories (docs/design/components.md).
///
/// Hostnames and paths are logged `.public` on purpose (docs/design/security.md), so
/// `sshdrive logs` is readable without a debugger attached. Secrets never reach a log
/// line at all: they are not interpolated, redacted or otherwise.
///
/// The loggers are `os.Logger` on Darwin and `SSHDriveLogger` elsewhere, selected by
/// `canImport(os)`. A call site sees no difference: both take a message built by string
/// interpolation with the same `privacy:` labels.
public enum Log {
    public static let subsystem = "org.shirls.sshdrive"

    /// The category strings, named so a test can assert them on either platform
    /// (`os.Logger` does not give its category back).
    public enum Category {
        public static let extensionLog = "extension"
        public static let agent = "agent"
        public static let cli = "cli"
        public static let sftp = "sftp"
        public static let ssh = "ssh"

        /// Every category `sshdrive logs` can show, in the order the components design
        /// page lists them.
        public static let all = [extensionLog, agent, cli, sftp, ssh]
    }

    public static let extensionLog = SSHDriveLog(subsystem: subsystem, category: Category.extensionLog)
    public static let agent = SSHDriveLog(subsystem: subsystem, category: Category.agent)
    public static let cli = SSHDriveLog(subsystem: subsystem, category: Category.cli)
    public static let sftp = SSHDriveLog(subsystem: subsystem, category: Category.sftp)
    public static let ssh = SSHDriveLog(subsystem: subsystem, category: Category.ssh)

    /// The askpass tool logs under the ssh category: its lines only ever describe a
    /// prompt that ssh raised.
    public static let askpass = SSHDriveLog(subsystem: subsystem, category: Category.ssh)
}

/// Writes a line to stderr. Used by the CLI and askpass, which have a terminal but also
/// log to the unified log through `Log`.
public func standardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
