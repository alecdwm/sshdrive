import AgentRuntime
import Darwin
import Foundation
import Logging

/// Which of our four executables a peer is (DESIGN.md section 5.2).
///
/// The code requirement, set on the connection before it is resumed, has already
/// established that the peer is one of ours and is the only security boundary here. This
/// says only *which* one, so that the process that relays `ssh`'s prompts is handed the
/// one-method askpass interface, and the process that types on a terminal is handed the
/// callback interface the collect connection prompts through.
struct PeerExecutable: PeerIdentifying {

    func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            Log.agent.error("could not read the path of peer pid \(pid, privacy: .public)")
            return nil
        }
        return String(cString: buffer)
    }

    /// `Contents/MacOS/sshdrive`, whatever symlink was used to reach it: `proc_pidpath`
    /// answers the resolved executable, which is why the Homebrew symlink does not confuse
    /// this.
    func isCLI(pid: Int32) -> Bool {
        guard let path = executablePath(pid: pid) else { return false }
        return (path as NSString).lastPathComponent == "sshdrive"
    }
}
