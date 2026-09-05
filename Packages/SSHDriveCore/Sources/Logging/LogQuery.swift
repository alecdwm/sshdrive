import Foundation

/// The `sshdrive logs` query (DESIGN.md section 8).
///
/// Section 8 spells the command out: "our subsystem's unified log, through
/// `/usr/bin/log show` and `log stream` with a subsystem predicate, since `OSLogStore`'s
/// local store is not open to a standard user". `OSLogStore(scope: .system)` needs an
/// entitlement a standard user's process does not have, so the CLI shells out to
/// `/usr/bin/log` and lets it do the reading.
///
/// Two things make the predicate more than `subsystem == …`:
///
/// - **fileproviderd is half the story.** Everything the *system* decides about a domain
///   - the enumerations it asks for, the items it refuses, `FP -2011`, the disconnection
///   states - is logged by `fileproviderd`, under Apple's own subsystem, and never
///   reaches ours. Every File Provider diagnosis in `docs/spikes/` was made by reading
///   the two side by side, so `logs` reads them side by side too. The filter for those
///   lines is our own bundle identifier, which fileproviderd prints because it is the
///   provider's. It is **not** narrowed by location, and cannot be: fileproviderd
///   obfuscates domain identifiers in its messages (`uuid:63...0B`, `domain: 1{34}1
///   (n{1}s)`), so a predicate naming the UUID matches none of its 500-odd lines while
///   the provider identifier matches all of them (measured 2026-09-05). Naming a location
///   therefore narrows our half and leaves the system's whole.
/// - **A location is named by two strings.** Our own lines carry the location's UUID
///   (`Log.agent.notice("\(location.id, privacy: .public): …")`) and, in the places that
///   are addressed to a person, its display name. Filtering on the id alone would drop
///   the second kind, so a named query matches either.
///
/// Everything here is a pure string builder so the predicate can be tested without a Mac.
public enum LogQuery {

    /// `Log.subsystem`, which is also the app's bundle identifier (section 3.1). The two
    /// being the same string is what lets one constant serve as both our subsystem filter
    /// and the needle in fileproviderd's messages.
    public static let subsystem = Log.subsystem

    /// The process whose lines carry the system's own view of our domains.
    public static let systemProcess = "fileproviderd"

    /// The predicate handed to `log show --predicate` / `log stream --predicate`.
    ///
    /// - Parameters:
    ///   - domainIdentifier: the location's UUID, which is also its File Provider domain
    ///     identifier (section 4). `nil` means every location.
    ///   - displayName: the location's display name, matched as well as the identifier so
    ///     that lines written for a person are not dropped.
    public static func predicate(domainIdentifier: String? = nil, displayName: String? = nil)
        -> String
    {
        let ours = "subsystem == \(quote(subsystem))"
        let system = "process == \(quote(systemProcess))"

        guard let domainIdentifier, !domainIdentifier.isEmpty else {
            // Unfiltered: all of ours, plus the fileproviderd lines that name us at all.
            return "(\(ours)) OR (\(system) AND eventMessage CONTAINS \(quote(subsystem)))"
        }

        var needles = [domainIdentifier]
        if let displayName, !displayName.isEmpty, displayName != domainIdentifier {
            needles.append(displayName)
        }
        let oursFiltered = needles
            .map { "eventMessage CONTAINS[c] \(quote($0))" }
            .joined(separator: " OR ")
        // The system half stays unfiltered: fileproviderd never prints the domain
        // identifier in the clear, so narrowing it would drop all of it.
        return "(\(ours) AND (\(oursFiltered)))"
            + " OR (\(system) AND eventMessage CONTAINS \(quote(subsystem)))"
    }

    /// `/usr/bin/log`, by absolute path. `zsh` has a `log` builtin that shadows it and
    /// answers `zsh:log:1: too many arguments` (docs/spikes/results.md, 2026-09-04), so
    /// nothing here ever spells the bare name.
    public static let executable = "/usr/bin/log"

    /// `log show`. `--info` is not optional: `Log.agent.info` and `Log.ssh.info` carry
    /// most of the transport's detail and `log show` hides the info level unless asked.
    public static func showArguments(
        domainIdentifier: String? = nil, displayName: String? = nil,
        last: String = "1h", debug: Bool = false
    ) -> [String] {
        var argv = [executable, "show", "--style", "compact", "--info"]
        if debug { argv.append("--debug") }
        argv += ["--last", last]
        argv += ["--predicate", predicate(domainIdentifier: domainIdentifier, displayName: displayName)]
        return argv
    }

    /// `log stream`, which is `--follow`. It has no `--last`: a stream starts now.
    public static func streamArguments(
        domainIdentifier: String? = nil, displayName: String? = nil, debug: Bool = false
    ) -> [String] {
        var argv = [executable, "stream", "--style", "compact", "--info"]
        if debug { argv.append("--debug") }
        argv += ["--predicate", predicate(domainIdentifier: domainIdentifier, displayName: displayName)]
        return argv
    }

    /// NSPredicate string quoting: single quotes, with a backslash before a quote or a
    /// backslash. A display name is user-typed and can carry either.
    static func quote(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if character == "\\" || character == "'" { escaped.append("\\") }
            escaped.append(character)
        }
        return "'\(escaped)'"
    }
}
