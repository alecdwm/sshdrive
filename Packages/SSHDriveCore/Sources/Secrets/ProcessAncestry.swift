import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// "An askpass invocation ... whose caller is not a descendant of the `ssh` it was issued
/// to gets no answer" (DESIGN.md section 4.2).
///
/// `ssh` forks the askpass directly, so the caller's parent is normally the `ssh` the
/// token was minted for; a `ProxyJump` hop is a grandchild, and its askpass a
/// great-grandchild, so the check has to walk rather than compare one pid.
public protocol ProcessAncestryChecking: AnyObject, Sendable {
    /// The parent pid of `pid`, or nil when it cannot be read (the process is gone).
    func parent(of pid: Int32) -> Int32?
}

extension ProcessAncestryChecking {
    /// Is `pid` `ancestor`, or a descendant of it? Bounded: a pid whose chain reaches
    /// launchd (1) or 0 without meeting the ancestor is not one.
    public func isDescendant(_ pid: Int32, of ancestor: Int32, maxDepth: Int = 16) -> Bool {
        guard pid > 0, ancestor > 0 else { return false }
        var current = pid
        var depth = 0
        while depth < maxDepth {
            if current == ancestor { return true }
            guard let next = parent(of: current), next > 1 else { return false }
            current = next
            depth += 1
        }
        return false
    }
}

/// The real check, over `sysctl(KERN_PROC_PID)`.
public final class SysctlProcessAncestry: ProcessAncestryChecking, @unchecked Sendable {
    public init() {}

    public func parent(of pid: Int32) -> Int32? {
        #if canImport(Darwin)
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            let result = sysctl(&name, u_int(name.count), &info, &size, nil, 0)
            guard result == 0, size > 0 else { return nil }
            let parent = info.kp_eproc.e_ppid
            return parent > 0 ? parent : nil
        #else
            return nil
        #endif
    }
}

/// A table for tests: pid -> parent pid.
public final class StaticProcessAncestry: ProcessAncestryChecking, @unchecked Sendable {
    private let table: [Int32: Int32]
    public init(_ table: [Int32: Int32]) { self.table = table }
    public func parent(of pid: Int32) -> Int32? { table[pid] }
}
