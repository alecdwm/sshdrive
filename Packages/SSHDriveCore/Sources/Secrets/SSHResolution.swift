import Foundation
import Logging
import XPCProtocols

/// What the agent needs to know about the `ssh` process that is asking: where it is
/// authenticating to, and which identity files it will offer.
public struct SSHResolution: Equatable, Sendable {
    public var destination: SSHDestination
    /// `identityfile` lines from `ssh -G`, absolute and `~`-expanded, in offer order.
    public var identityFiles: [String]

    public init(destination: SSHDestination, identityFiles: [String] = []) {
        self.destination = destination
        self.identityFiles = identityFiles
    }
}

/// Resolving the asking `ssh`'s destination (DESIGN.md section 4.2). The master's own
/// destination is known to the agent, which spawned it; this exists for the `ProxyJump`
/// hops, which the agent never sees start and tells apart from the master by the argv the
/// askpass sends.
public protocol SSHResolving: AnyObject, Sendable {
    func resolve(argv: [String]) -> SSHResolution?
}

/// `ssh -G` over the hop's own argv. `-G` resolves and prints; it opens no connection
/// (canonicalisation aside) and never runs the `ProxyCommand`.
public final class SSHGResolver: SSHResolving, @unchecked Sendable {
    private let sshPath: String
    private let timeout: TimeInterval
    private var cache: [[String]: SSHResolution] = [:]
    private let lock = NSLock()

    public init(sshPath: String = "/usr/bin/ssh", timeout: TimeInterval = 10) {
        self.sshPath = sshPath
        self.timeout = timeout
    }

    public func resolve(argv: [String]) -> SSHResolution? {
        guard argv.count > 1 else { return nil }
        let arguments = Array(argv.dropFirst())
        lock.lock()
        if let cached = cache[arguments] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let output = runSSHG(arguments) else { return nil }
        guard let resolution = SSHGResolver.parse(output) else { return nil }
        lock.lock()
        cache[arguments] = resolution
        lock.unlock()
        return resolution
    }

    /// `ssh -G` prints one lowercased keyword per line. Only four lines matter here.
    public static func parse(_ output: String) -> SSHResolution? {
        var user: String?
        var hostname: String?
        var port: Int?
        var identityFiles: [String] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let keyword = parts[0].lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            switch keyword {
            case "user": user = value
            case "hostname": hostname = value
            case "port": port = Int(value)
            case "identityfile": identityFiles.append(expandTilde(value))
            default: continue
            }
        }

        guard let user, let hostname, let port else { return nil }
        return SSHResolution(
            destination: SSHDestination(user: user, hostname: hostname, port: port),
            identityFiles: identityFiles)
    }

    /// `ssh -G` prints `identityfile` unexpanded (`~/.ssh/id_ed25519`); the passphrase
    /// prompt carries the expanded path.
    public static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst(1)) }
        return (path as NSString).expandingTildeInPath
    }

    private func runSSHG(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = ["-G"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // An askpass in the environment here would make `ssh -G` able to prompt, which it
        // must never do; -G does not authenticate, but the belt is cheap.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: AskpassEnvironment.tokenVariable)
        environment.removeValue(forKey: "SSH_ASKPASS")
        environment.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        process.environment = environment

        do {
            try process.run()
        } catch {
            Log.ssh.error("ssh -G could not be started: \(error, privacy: .public)")
            return nil
        }

        // Bounded: nothing on this path may hang the askpass reply, which ssh is waiting
        // on inside the 60 s authentication deadline (section 4.2).
        let deadline = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            Log.ssh.error("ssh -G did not finish within the deadline; killing it")
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A resolver for tests and for the fake backend: answers from a table, runs nothing.
public final class StaticSSHResolver: SSHResolving, @unchecked Sendable {
    private var table: [[String]: SSHResolution]
    private let fallback: SSHResolution?
    private let lock = NSLock()

    public init(fallback: SSHResolution? = nil, table: [[String]: SSHResolution] = [:]) {
        self.fallback = fallback
        self.table = table
    }

    public func set(_ resolution: SSHResolution, for argv: [String]) {
        lock.lock(); defer { lock.unlock() }
        table[argv] = resolution
    }

    public func resolve(argv: [String]) -> SSHResolution? {
        lock.lock(); defer { lock.unlock() }
        return table[argv] ?? fallback
    }
}
