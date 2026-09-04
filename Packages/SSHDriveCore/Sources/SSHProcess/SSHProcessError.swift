import Foundation

public enum SSHProcessError: Error, LocalizedError {
    case notImplemented(milestone: Int)
    case malformedJumpHost(String)
    case spawnFailed(executable: String, code: Int32)
    case timedOut(command: String, stdout: Data, stderr: Data)
    /// `ssh -G` refused the config: usually a keyword only a newer Homebrew OpenSSH has.
    case configurationRejected(String)
    /// The master could not be established, or died. Carries what the agent does next.
    case connectionFailed(classification: SSHExitClassification, stderr: String)
    /// A channel could not be opened on an established master.
    case channelFailed(classification: SSHExitClassification, stderr: String)
    /// The key agent's socket is missing or refusing; `ssh` was never run (section 6.1).
    case keyAgentUnavailable(IdentityAgentCheck.Result)
    /// The sentinel never arrived: the location falls to `poll` and `status` shows the
    /// first bytes received so the user can find the rc file (section 9.2).
    case shellOutputUnusable(prefix: Data)
    /// The exec channel answered with SFTP framing: a `ForceCommand internal-sftp`
    /// account. Reported as "no shell access (ForceCommand)", not as unusable output.
    case noShellAccess(prefix: Data)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case let .notImplemented(milestone):
            return "Not implemented until milestone \(milestone)."
        case let .malformedJumpHost(specification):
            return "Cannot parse the jump host \"\(specification)\"."
        case let .spawnFailed(executable, code):
            return "Could not run \(executable): \(String(cString: strerror(code)))."
        case let .timedOut(command, _, _):
            return "Timed out running \(command)."
        case let .configurationRejected(message):
            return "/usr/bin/ssh rejected the configuration: \(message)"
        case let .connectionFailed(classification, stderr):
            return "ssh failed (\(classification.rawValue)): \(stderr)"
        case let .channelFailed(classification, stderr):
            return "the ssh channel failed (\(classification.rawValue)): \(stderr)"
        case let .keyAgentUnavailable(result):
            return "the key agent is not ready: \(result)"
        case .shellOutputUnusable:
            return "shell output unusable: the account printed something our sentinel could not be found in."
        case .noShellAccess:
            return "no shell access (ForceCommand)."
        case .notConnected:
            return "no ssh master is connected for this location."
        }
    }

    /// What the agent does about it, where that is defined (section 6.1).
    public var classification: SSHExitClassification? {
        switch self {
        case let .connectionFailed(classification, _), let .channelFailed(classification, _):
            return classification
        case .keyAgentUnavailable:
            return .keyAgentNotReady
        case .timedOut:
            return .transient
        default:
            return nil
        }
    }
}
