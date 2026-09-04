import Foundation

/// One entry of a `ProxyJump` chain: `[user@]host[:port]`, or a bare `~/.ssh/config`
/// alias, which is the usual case.
///
/// User and port stay separate from the host because `ssh` does not parse the
/// `user@host:port` form itself — `ssh -G alec@10.0.0.1:2222` resolves the host to the
/// literal `10.0.0.1:2222` — so the agent splits it and passes `-l` and `-p`
/// (DESIGN.md section 6.1). When the entry names an alias with neither, the alias is
/// passed through untouched so the hop's own host block still applies, exactly as it
/// would under `ssh -J`.
public struct JumpHop: Sendable, Equatable {
    public var host: String
    public var user: String?
    public var port: Int?

    public init(host: String, user: String? = nil, port: Int? = nil) {
        self.host = host
        self.user = user
        self.port = port
    }

    /// Parses one comma-separated element of a resolved `proxyjump` value, or of the
    /// `--jump` sugar the CLI accepts. IPv6 literals are written `[::1]:22` as `ssh`
    /// writes them.
    public static func parse(_ specification: String) throws -> JumpHop {
        var rest = specification.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, rest != "none" else { throw SSHProcessError.malformedJumpHost(specification) }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[rest.startIndex ..< at])
            rest = String(rest[rest.index(after: at)...])
            if user?.isEmpty ?? true { throw SSHProcessError.malformedJumpHost(specification) }
        }
        var port: Int?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else {
                throw SSHProcessError.malformedJumpHost(specification)
            }
            let host = String(rest[rest.index(after: rest.startIndex) ..< close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") {
                guard let value = Int(after.dropFirst()), value > 0, value < 65536 else {
                    throw SSHProcessError.malformedJumpHost(specification)
                }
                port = value
            } else if !after.isEmpty {
                throw SSHProcessError.malformedJumpHost(specification)
            }
            guard !host.isEmpty else { throw SSHProcessError.malformedJumpHost(specification) }
            return JumpHop(host: host, user: user, port: port)
        }
        if let colon = rest.lastIndex(of: ":") {
            let tail = String(rest[rest.index(after: colon)...])
            if let value = Int(tail), value > 0, value < 65536 {
                port = value
                rest = String(rest[rest.startIndex ..< colon])
            }
        }
        guard !rest.isEmpty else { throw SSHProcessError.malformedJumpHost(specification) }
        return JumpHop(host: rest, user: user, port: port)
    }

    /// Splits a resolved `proxyjump` value: `spike-bastion-a,spike-bastion-b`.
    public static func parseChain(_ value: String) throws -> [JumpHop] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return [] }
        return try trimmed.split(separator: ",").map { try parse(String($0)) }
    }
}

/// Builds the agent's own `ProxyCommand` for a `ProxyJump` chain (DESIGN.md section 6.1).
///
/// `ssh` is never given the `ProxyJump`: left to itself it spawns the hop as
/// `<argv[0]> -W '[%h]:%p' … <jump>`, and that child reads the config files but receives
/// none of the parent's command-line `-o` options — so it would attach to a
/// `ControlMaster auto` socket from the user's terminal, run with
/// `StrictHostKeyChecking=ask`, and sign through the key agent during the
/// `IdentityAgent=none` pass. So the chain is cancelled with `ProxyJump=none` and rebuilt
/// here, hop by hop, innermost first.
public enum ProxyChainBuilder {

    /// The overrides a hop carries: the master's set with `ControlMaster=no` **and**
    /// `ControlPath=none` in place of the mux settings. `no` alone is not enough — with
    /// it `ssh` still attaches to an existing socket at whatever `ControlPath` the config
    /// names for the bastion, and `ssh -G` prints the config's `controlpath` unchanged
    /// under `-o ControlMaster=no`. Only `ControlPath=none` clears it.
    static func hopOptions(identityAgentNone: Bool, hostKeyChecking: String = "yes")
        -> [(String, String)]
    {
        var pairs: [(String, String)] = [("ControlMaster", "no"), ("ControlPath", "none")]
        pairs += SSHCommandBuilder.commonOptions(hostKeyChecking: hostKeyChecking)
        if identityAgentNone { pairs.append(("IdentityAgent", "none")) }
        return pairs
    }

    /// The argv of one hop, as a vector. Not quoted: `commandLine` does that.
    ///
    /// The destination's own `IdentityFile`/`User`/`Port` overrides are deliberately not
    /// forwarded here — they describe the far end, not the bastion. A hop takes its
    /// identity from the config, and its user and port from the chain entry.
    public static func hopArguments(
        _ hop: JumpHop,
        identityAgentNone: Bool,
        innerProxyCommand: String?,
        hostKeyChecking: String = "yes"
    ) -> [String] {
        var arguments = [SSHProcess.sshBinaryPath, "-W", "%h:%p"]
        arguments += SSHCommandBuilder.flatten(
            hopOptions(identityAgentNone: identityAgentNone, hostKeyChecking: hostKeyChecking))
        if let innerProxyCommand {
            // This hop is reached through the one before it. Cancel any ProxyJump its own
            // host block may carry, since we are supplying the route - and put the
            // ProxyCommand first, because `ProxyJump=none` ahead of it drops it (see
            // SSHCommandBuilder.master and section 13).
            arguments += ["-o", "ProxyCommand=\(innerProxyCommand)", "-o", "ProxyJump=none"]
        }
        if let user = hop.user { arguments += ["-l", user] }
        if let port = hop.port { arguments += ["-p", String(port)] }
        arguments.append(hop.host)
        return arguments
    }

    /// `%` doubled, so one round of `ssh`'s percent expansion leaves the string as it was.
    ///
    /// This is the second escaping a nested hop needs and the one that is easy to miss.
    /// `ssh` percent-expands the **whole** `ProxyCommand` string before handing it to
    /// `/bin/sh -c`, including the `%h:%p` belonging to a hop nested inside it, so an
    /// unescaped two-hop chain has hop 1 dialling the *destination's* host and port
    /// instead of hop 2's: measured against the testbed on 2026-09-04, where hop 2 then
    /// found itself talking to `inner` while checking `bastion-b`'s host key and failed
    /// with "REMOTE HOST IDENTIFICATION HAS CHANGED". Every embedding doubles again, so a
    /// three-hop chain's innermost `-W` is written `%%%%h:%%%%p`.
    static func escapingPercentsForOneExpansion(_ command: String) -> String {
        command.replacingOccurrences(of: "%", with: "%%")
    }

    /// The whole chain as the single `ProxyCommand` string the master carries. Nil when
    /// there is no chain at all.
    ///
    /// `ssh` runs a `ProxyCommand` through `/bin/sh -c`, so every element is
    /// single-quoted (section 9.2's rule), and the nested `ProxyCommand` of an inner hop
    /// is quoted again as it is embedded — which is what makes an identity path
    /// containing a space and a quote survive two levels of shell — and percent-escaped
    /// once more for each level it descends.
    public static func proxyCommand(
        for hops: [JumpHop], identityAgentNone: Bool, hostKeyChecking: String = "yes"
    ) -> String? {
        guard !hops.isEmpty else { return nil }
        var inner: String?
        for hop in hops {
            let nested = inner.map(escapingPercentsForOneExpansion)
            let arguments = hopArguments(
                hop, identityAgentNone: identityAgentNone, innerProxyCommand: nested,
                hostKeyChecking: hostKeyChecking)
            inner = ShellQuoting.commandLine(arguments)
        }
        return inner
    }

    /// A hand-written `ProxyCommand` that itself invokes `ssh` escapes every override the
    /// agent applies: that inner `ssh` is found through `PATH`, reads the config
    /// unmodified, attaches to any `ControlMaster auto` socket for the bastion, and signs
    /// through the key agent during the `IdentityAgent=none` collect pass. `add` detects
    /// it, says so, and recommends `ProxyJump`; the location is still created (section 6.1).
    public static func isHandWrittenSSHProxyCommand(_ resolved: String?) -> Bool {
        guard let resolved else { return false }
        let trimmed = resolved.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return false }
        guard let first = trimmed.split(separator: " ").first.map(String.init) else { return false }
        return first == "ssh" || first.hasSuffix("/ssh")
    }
}
