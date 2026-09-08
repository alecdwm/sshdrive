#if !canImport(Darwin)

    import Foundation
    import Glibc

    /// `/proc`, standing in for the `sysctl(KERN_PROC…)` calls of `ControlSocket`.
    ///
    /// macOS has no `/proc` and Linux has no `KERN_PROC`, so the two spellings of "what is
    /// this process called, who owns it, and what was its argv" sit side by side. Nothing
    /// here is reachable on Darwin (docs/testing-architecture.md section 8, step 1.2).
    enum ProcFS {
        private static let root = "/proc"

        /// Every process id `/proc` lists.
        static func pids() -> [pid_t] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            return names.compactMap { pid_t($0) }
        }

        /// `/proc/<pid>/comm`, which is the same short name `p_comm` carries.
        static func processName(of pid: pid_t) -> String? {
            guard let text = try? String(contentsOfFile: "\(root)/\(pid)/comm", encoding: .utf8)
            else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// The real uid on `/proc/<pid>/status`, compared with ours.
        static func isOwnedByThisUser(_ pid: pid_t) -> Bool {
            guard let text = try? String(contentsOfFile: "\(root)/\(pid)/status", encoding: .utf8)
            else { return false }
            for line in text.split(separator: "\n") where line.hasPrefix("Uid:") {
                let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                if fields.count > 1, let uid = UInt32(fields[1]) { return uid == getuid() }
            }
            return false
        }

        /// `/proc/<pid>/cmdline`, NUL-separated, joined with spaces the way the
        /// `KERN_PROCARGS2` reader joins its own.
        static func commandLine(of pid: pid_t) -> String? {
            guard let data = FileManager.default.contents(atPath: "\(root)/\(pid)/cmdline"),
                !data.isEmpty
            else { return nil }
            return String(
                decoding: data.map { $0 == 0 ? UInt8(ascii: " ") : $0 }, as: UTF8.self)
        }
    }

#endif
