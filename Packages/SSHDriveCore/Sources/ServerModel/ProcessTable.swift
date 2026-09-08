import Foundation
import SSHProcess

/// "Is that process still running?", answered portably and without counting zombies.
///
/// `SQ-075`: `pgrep` counts **zombies** - an `ssh` mux client killed with `-9` stays in
/// `pgrep -f` output as `Z` until it is reaped - so "did I kill it?" is unanswerable from
/// a name match alone; `ps -o stat` is the one to read. `/proc` would do it on Linux and
/// does not exist on Darwin, and these scenarios run on both.
public enum ProcessTable {

    public struct Entry: Sendable, Equatable {
        public var pid: pid_t
        /// The `ps` state letter: `Z` for a zombie, anything else for a live process.
        public var state: String
        public var commandLine: String
        public var isZombie: Bool { state.hasPrefix("Z") }
    }

    /// Every process this user can see, zombies included and marked.
    public static func snapshot() -> [Entry] {
        guard let result = try? Spawn.capture(
            executable: "/bin/ps",
            argv: ["/bin/ps", "-axo", "pid=,stat=,command="],
            environment: ["PATH": "/bin:/usr/bin"],
            timeout: 15)
        else { return [] }
        return String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                let fields = line.split(
                    separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard fields.count == 3, let pid = pid_t(fields[0]) else { return nil }
                return Entry(pid: pid, state: String(fields[1]),
                             commandLine: String(fields[2]))
            }
    }

    /// The process group a live process is in, or nil.
    ///
    /// The one thing that decides whether `SQ-010` can be *run* on a given box: the model
    /// puts every session of a `.sharedWith` profile into one group with
    /// `posix_spawn`'s `POSIX_SPAWN_SETPGROUP`, and a platform that quietly declines would
    /// turn the regression scenario into a scenario about nothing.
    public static func processGroup(of pid: pid_t) -> pid_t? {
        guard let result = try? Spawn.capture(
            executable: "/bin/ps",
            argv: ["/bin/ps", "-o", "pgid=", "-p", String(pid)],
            environment: ["PATH": "/bin:/usr/bin"],
            timeout: 15)
        else { return nil }
        return pid_t(String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True when both processes are in the same process group, and that group is neither
    /// process's own - which is what `tailscaled` does to its sessions (`SQ-010`).
    public static func shareAForeignProcessGroup(_ first: pid_t, _ second: pid_t) -> Bool {
        guard let a = processGroup(of: first), let b = processGroup(of: second) else {
            return false
        }
        return a == b && a != first && a != second
    }

    /// Live, non-zombie processes whose command line contains `needle`.
    public static func live(matching needle: String) -> [Entry] {
        snapshot().filter { !$0.isZombie && $0.commandLine.contains(needle) }
    }

    public static func count(matching needle: String) -> Int { live(matching: needle).count }

    /// Cleanup for a scenario that left something behind. A run that leaves an orphan makes
    /// every later run count it, which is exactly the orphan these scenarios are about.
    public static func killAll(matching needle: String) {
        for entry in snapshot() where entry.commandLine.contains(needle) {
            kill(entry.pid, SIGKILL)
        }
    }
}
