import Foundation

/// The output of `ssh -G <host>`: resolved values only, with no indication of where each
/// came from (DESIGN.md section 4.1).
public struct SSHConfigResolution: Sendable, Equatable {
    /// Lower-cased keyword to its values, in the order `ssh` printed them. Keywords that
    /// may repeat (`identityfile`, `sendenv`, `setenv`, `localforward`) keep every value.
    public var values: [String: [String]]

    public init(values: [String: [String]] = [:]) { self.values = values }

    public subscript(_ keyword: String) -> String? { values[keyword.lowercased()]?.first }

    public var hostname: String? { self["hostname"] }
    public var user: String? { self["user"] }
    public var port: Int? { self["port"].flatMap(Int.init) }
    public var identityFiles: [String] { values["identityfile"] ?? [] }
    /// `ssh -G` prints this with `~` already expanded.
    public var identityAgent: String? { self["identityagent"] }
    public var proxyJump: String? { self["proxyjump"] }
    public var proxyCommand: String? { self["proxycommand"] }
    public var controlMaster: String? { self["controlmaster"] }
    public var controlPath: String? { self["controlpath"] }

    /// The chain the agent must rebuild as its own `ProxyCommand`. Empty when there is none.
    public func jumpChain() throws -> [JumpHop] {
        guard let proxyJump else { return [] }
        return try JumpHop.parseChain(proxyJump)
    }

    /// The keychain key for a password prompt from this destination:
    /// `password:<user>@<hostname>:<port>`, lower-cased hostname, never the alias
    /// (section 4.2). Defined here because this is where the resolution lives; the
    /// keychain itself is `Secrets`.
    public var passwordKeychainKey: String? {
        guard let user, let hostname else { return nil }
        return "password:\(user)@\(hostname.lowercased()):\(port ?? 22)"
    }

    static func parse(_ output: String) -> SSHConfigResolution {
        var values: [String: [String]] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            guard let space = text.firstIndex(of: " ") else {
                let keyword = text.trimmingCharacters(in: .whitespaces).lowercased()
                if !keyword.isEmpty { values[keyword, default: []].append("") }
                continue
            }
            let keyword = String(text[text.startIndex ..< space]).lowercased()
            let value = String(text[text.index(after: space)...])
            values[keyword, default: []].append(value)
        }
        return SSHConfigResolution(values: values)
    }
}

/// Which values a config file supplied, from diffing `ssh -G` against
/// `ssh -F /dev/null -G` (DESIGN.md section 4.1). `-F` silences `/etc/ssh/ssh_config` as
/// well as the user's file, so the label reads "from ssh config" and `show` names both
/// paths rather than crediting `~/.ssh/config` with a value Apple's system file set.
public struct SSHConfigAttribution: Sendable {
    public var resolved: SSHConfigResolution
    public var withoutConfigFiles: SSHConfigResolution

    public init(resolved: SSHConfigResolution, withoutConfigFiles: SSHConfigResolution) {
        self.resolved = resolved
        self.withoutConfigFiles = withoutConfigFiles
    }

    /// Keywords whose value differs between the two runs.
    public var fromConfigFiles: Set<String> {
        var out: Set<String> = []
        for (keyword, value) in resolved.values where withoutConfigFiles.values[keyword] != value {
            out.insert(keyword)
        }
        for keyword in withoutConfigFiles.values.keys where resolved.values[keyword] == nil {
            out.insert(keyword)
        }
        return out
    }

    /// The control-socket and session-shape settings the config would have applied and the
    /// agent overrode. `sshdrive show` prints these so the user can see they were
    /// overridden (section 6.1).
    public var overriddenByUs: [(keyword: String, configValue: String)] {
        let watched = SSHCommandBuilder.Overrides.all.map { $0.lowercased() }
        return watched.compactMap { keyword in
            guard fromConfigFiles.contains(keyword), let value = resolved[keyword] else { return nil }
            return (keyword, value)
        }
    }
}

public enum SSHConfigResolver {
    /// Runs `ssh -G`. A config written for a newer Homebrew OpenSSH may use a keyword
    /// Apple's build rejects, and `ssh -G` then fails with `Bad configuration option`;
    /// `add` reports that together with `/usr/bin/ssh -V` (section 4.1).
    public static func resolve(
        target: SSHTarget,
        environment: [String: String],
        ignoringConfigFiles: Bool = false,
        timeout: TimeInterval = 10
    ) throws -> SSHConfigResolution {
        let invocation = SSHCommandBuilder.resolve(target: target, ignoringConfigFiles: ignoringConfigFiles)
        let result = try Spawn.capture(
            executable: invocation.executable, argv: invocation.argv,
            environment: environment, timeout: timeout
        )
        guard result.exit.isClean else {
            throw SSHProcessError.configurationRejected(
                String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return SSHConfigResolution.parse(String(decoding: result.stdout, as: UTF8.self))
    }

    public static func attribution(
        target: SSHTarget,
        environment: [String: String],
        timeout: TimeInterval = 10
    ) throws -> SSHConfigAttribution {
        SSHConfigAttribution(
            resolved: try resolve(target: target, environment: environment,
                                  ignoringConfigFiles: false, timeout: timeout),
            withoutConfigFiles: try resolve(target: target, environment: environment,
                                            ignoringConfigFiles: true, timeout: timeout)
        )
    }
}
