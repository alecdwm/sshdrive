import Foundation
import Logging
import SSHProcess

/// One `ssh -s <destination> sftp` subprocess and the byte stream over its pipes.
///
/// **A test path, not a production one.** Production opens the SFTP subsystem on a mux
/// client of the `-N` master (`SSHMaster.openSFTPChannel`, DESIGN.md section 6.1) and
/// hands the wire client that channel's `ByteStream`; this spawns an `ssh` of its own,
/// which the agent must never do, because such a connection carries none of section 6.1's
/// overrides and nothing supervises it. It survives because it is what let the codec be
/// written and tested against a real `sftp-server` before `SSHProcess` existed, and
/// `SFTPIntegrationTests` still drives it that way. Nothing here knows about masters,
/// `ProxyJump` or askpass; the argument list is handed in whole.
///
/// `ssh` is named by absolute path with `argv[0]` set to it, never through `PATH`
/// (section 6.1).
public final class SFTPSubprocess: @unchecked Sendable {

    public enum SpawnError: Error, LocalizedError {
        case couldNotSpawn(String)

        public var errorDescription: String? {
            switch self {
            case .couldNotSpawn(let message): return "Could not spawn ssh: \(message)"
            }
        }
    }

    public static let defaultSSHPath = "/usr/bin/ssh"

    public let stream: PipeByteStream
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe
    private let stderrLock = NSLock()
    private var stderrBytes = Data()

    /// Spawns `<sshPath> <options> -s <destination> sftp`.
    ///
    /// `options` is everything the agent wants in front of the destination; it is passed
    /// through untouched so section 6.1 owns the command line and this file owns none of
    /// it.
    public static func sshSubsystem(
        destination: String,
        options: [String] = [],
        sshPath: String = SFTPSubprocess.defaultSSHPath
    ) throws -> SFTPSubprocess {
        try SFTPSubprocess(
            executable: sshPath, arguments: options + ["-s", destination, "sftp"])
    }

    public init(executable: String, arguments: [String]) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        stdin = Pipe()
        stdout = Pipe()
        stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw SpawnError.couldNotSpawn(error.localizedDescription)
        }

        // Our own copies of the parent ends, so the stream may close them without
        // fighting the Pipe's own FileHandles for ownership.
        let readFD = dup(stdout.fileHandleForReading.fileDescriptor)
        let writeFD = dup(stdin.fileHandleForWriting.fileDescriptor)
        stream = PipeByteStream(readFD: readFD, writeFD: writeFD, label: "sftp-subprocess")

        // `ssh`'s diagnostics are the only explanation of a failed handshake, so they are
        // kept and handed back with the error rather than dropped on the floor.
        let handle = stderr.fileHandleForReading
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.stderrLock.lock()
            if self.stderrBytes.count < 64 * 1024 { self.stderrBytes.append(chunk) }
            self.stderrLock.unlock()
        }
    }

    public var isRunning: Bool { process.isRunning }

    /// The exit status once the process has gone, or nil while it is running.
    public var terminationStatus: Int32? { process.isRunning ? nil : process.terminationStatus }

    /// Whatever `ssh` wrote to stderr so far, trimmed. This is what turns "the channel
    /// died" into a sentence a user can act on (section 6.1's exit classification).
    public var diagnostics: String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return String(decoding: stderrBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Closes the stream and kills `ssh`. Killing it is not optional: an `ssh` that used
    /// `-J` leaves its `-W` children holding the pipe open otherwise (testbed/README.md,
    /// and the same orphan problem section 6.1 describes for our own masters).
    public func terminate() async {
        stream.close()
        if process.isRunning { process.terminate() }
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
    }

    /// Waits for the process to exit, bounded. Returns false if it is still running.
    @discardableResult
    public func waitUntilExit(within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return !process.isRunning
    }
}
