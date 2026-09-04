import Foundation

/// One `ssh` command line, ready to spawn.
///
/// `argv0` is carried separately and is always `/usr/bin/ssh`, because OpenSSH reuses its
/// own `argv[0]` for any `ProxyJump` hop it builds itself and falls back to a `PATH`
/// lookup of `ssh` when that is not an executable path (DESIGN.md section 6.1).
public struct SSHInvocation: Sendable, Equatable {
    public var executable: String
    public var argv0: String
    public var arguments: [String]

    public init(executable: String = SSHProcess.sshBinaryPath,
                argv0: String = SSHProcess.sshBinaryPath,
                arguments: [String]) {
        self.executable = executable
        self.argv0 = argv0
        self.arguments = arguments
    }

    /// The full vector as `posix_spawn` sees it.
    public var argv: [String] { [argv0] + arguments }

    /// The value of `-o <keyword>=…` this invocation carries, last one written wins for
    /// display purposes only; `ssh` itself takes the first. Test and `sshdrive show` helper.
    public func option(_ keyword: String) -> String? {
        var found: String?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "-o", index + 1 < arguments.count {
                let pair = arguments[index + 1]
                if let eq = pair.firstIndex(of: "="),
                   String(pair[pair.startIndex ..< eq]).caseInsensitiveCompare(keyword) == .orderedSame {
                    if found == nil { found = String(pair[pair.index(after: eq)...]) }
                }
                index += 2
            } else {
                index += 1
            }
        }
        return found
    }

    public func hasFlag(_ flag: String) -> Bool { arguments.contains(flag) }
}

/// Where a location's own values go on the command line. `add` stores explicit flags as
/// overrides and they are passed as `-o` options, which beat the config file exactly as
/// they do for `ssh` (section 4.1).
public struct SSHTarget: Sendable, Equatable {
    /// Exactly what the user typed: an ssh_config alias or a hostname.
    public var host: String
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    /// Verbatim extra `-o` options from `add`.
    public var sshOptions: [String]
    /// False only for an `agentDependent` location (section 4.2).
    public var identityAgentNone: Bool

    public init(host: String, user: String? = nil, port: Int? = nil,
                identityFile: String? = nil, sshOptions: [String] = [],
                identityAgentNone: Bool = true) {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.identityAgentNone = identityAgentNone
    }
}

/// Assembles every `ssh` command line the agent runs (DESIGN.md section 6.1).
///
/// Nothing here spawns anything: it is pure so the option set can be asserted in a unit
/// test, which is the only way to keep a twenty-option override list honest.
public enum SSHCommandBuilder {

    /// The keywords the agent forces on the master and on every `ProxyJump` hop,
    /// whatever the user's config says. Split in three because the reasons differ and
    /// `sshdrive show` reports them separately (section 6.1, section 4.1).
    public enum Overrides {
        /// Ours alone: our own TCP connection, our own keepalive and timeouts.
        public static let connectionSharing = ["ControlMaster", "ControlPath", "ControlPersist"]
        public static let timeouts = ["ConnectTimeout", "ServerAliveInterval", "ServerAliveCountMax"]
        /// A host block written for interactive use breaks a master and a hop both.
        public static let sessionShape = [
            "RemoteCommand", "RequestTTY", "StdinNull", "ForkAfterAuthentication",
            "BatchMode", "PermitLocalCommand", "ForwardAgent", "ForwardX11",
            "ClearAllForwardings",
        ]
        /// An `ask` here raises a question nobody is there to answer (section 4.3).
        public static let hostKeys = ["StrictHostKeyChecking", "UpdateHostKeys"]

        public static var all: [String] {
            connectionSharing + timeouts + hostKeys + sessionShape
                + ["NumberOfPasswordPrompts", "LogLevel", "IdentityAgent", "ProxyJump", "ProxyCommand"]
        }
    }

    /// The options shared by the master and every hop: everything except the mux settings
    /// and the destination overrides.
    static func commonOptions() -> [(String, String)] {
        [
            ("StrictHostKeyChecking", "yes"),
            ("UpdateHostKeys", "no"),
            ("ConnectTimeout", "15"),
            ("ServerAliveInterval", "15"),
            ("ServerAliveCountMax", "2"),
            ("NumberOfPasswordPrompts", "1"),
            ("LogLevel", "ERROR"),
            ("RemoteCommand", "none"),
            ("RequestTTY", "no"),
            ("StdinNull", "no"),
            ("ForkAfterAuthentication", "no"),
            ("BatchMode", "no"),
            ("PermitLocalCommand", "no"),
            ("ForwardAgent", "no"),
            ("ForwardX11", "no"),
            ("ClearAllForwardings", "yes"),
        ]
    }

    static func flatten(_ pairs: [(String, String)]) -> [String] {
        pairs.flatMap { ["-o", "\($0.0)=\($0.1)"] }
    }

    /// The `-N` ControlMaster. No session, only the mux socket; `ControlPersist=no` keeps
    /// it in the foreground as our own child, which is the only way the agent has a pid to
    /// supervise, stderr to read and an exit to watch (section 6.1).
    ///
    /// `proxyCommand` is the chain the agent built itself; when it is non-nil the resolved
    /// `ProxyJump` is cancelled with `ProxyJump=none` and never handed to `ssh`.
    public static func master(
        target: SSHTarget,
        controlPath: String,
        proxyCommand: String? = nil
    ) -> SSHInvocation {
        var arguments = ["-N"]
        arguments += flatten([
            ("ControlMaster", "yes"),
            ("ControlPath", controlPath),
            ("ControlPersist", "no"),
        ])
        arguments += flatten(commonOptions())
        if target.identityAgentNone {
            arguments += ["-o", "IdentityAgent=none"]
        }
        if let proxyCommand {
            // ProxyCommand FIRST, then the cancellation. Both keywords write the same
            // field in `ssh`, and `-o ProxyJump=none` ahead of `-o ProxyCommand=…` makes
            // OpenSSH 10.2 drop our ProxyCommand silently: `ssh -G` then prints neither,
            // and the connection resolves the destination hostname itself, which behind a
            // bastion does not exist. Measured on macOS 26.4, see section 13.
            arguments += ["-o", "ProxyCommand=\(proxyCommand)", "-o", "ProxyJump=none"]
        }
        arguments += destinationOverrides(target)
        // "`ProxyJump` is never handed to `ssh`" holds for one given in the location's own
        // `sshOptions` too (section 6.1): it reaches `ssh -G`, where the chain builder
        // picks it up like one from the config, and it is dropped here. `ssh` takes the
        // first value it sees, so the `ProxyJump=none` above would already have won, but
        // leaving it on the line would make `sshdrive show` read as though we passed it.
        arguments += SSHCommandBuilder.withoutProxyJump(target.sshOptions)
        arguments.append(target.host)
        return SSHInvocation(arguments: arguments)
    }

    /// Drops every `-o ProxyJump=…` pair (and the `-J` flag) from a verbatim option list.
    static func withoutProxyJump(_ options: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < options.count {
            let word = options[index]
            if word == "-J", index + 1 < options.count { index += 2; continue }
            if word == "-o", index + 1 < options.count {
                let pair = options[index + 1]
                if let equals = pair.firstIndex(of: "="),
                   String(pair[pair.startIndex ..< equals])
                       .caseInsensitiveCompare("ProxyJump") == .orderedSame {
                    index += 2
                    continue
                }
            }
            out.append(word)
            index += 1
        }
        return out
    }

    /// `-o User=`, `-o Port=`, `-o IdentityFile=`. These come after the fixed set and
    /// before the user's verbatim `sshOptions`, so the fixed set wins over both: `ssh`
    /// takes the *first* value it sees for a keyword, command line included.
    static func destinationOverrides(_ target: SSHTarget) -> [String] {
        var pairs: [(String, String)] = []
        if let user = target.user { pairs.append(("User", user)) }
        if let port = target.port { pairs.append(("Port", String(port))) }
        if let identity = target.identityFile { pairs.append(("IdentityFile", identity)) }
        return flatten(pairs)
    }

    /// Every mux client: `-F /dev/null` so it reads no config at all, `BatchMode=yes` so
    /// it can never prompt, and `ProxyCommand=/usr/bin/false` so the direct connection
    /// `ssh` would otherwise make when the socket is missing dies before a byte is
    /// exchanged (section 6.1). The host argument is a placeholder; the mux protocol uses
    /// nothing from it.
    public static func muxOptions(controlPath: String) -> [String] {
        ["-F", "/dev/null", "-S", controlPath, "-o", "BatchMode=yes", "-o", "ProxyCommand=/usr/bin/false"]
    }

    /// `ssh $MUX -s <host> sftp`: an SFTP channel over the master's socket.
    public static func sftpChannel(controlPath: String, host: String) -> SSHInvocation {
        SSHInvocation(arguments: muxOptions(controlPath: controlPath) + ["-s", host, "sftp"])
    }

    /// `ssh $MUX <host> sh -s`: an exec channel. The command line is constant and nothing
    /// from the user, the config or the server ever appears on it (section 9.2).
    public static func execChannel(controlPath: String, host: String) -> SSHInvocation {
        SSHInvocation(arguments: muxOptions(controlPath: controlPath) + [host, "sh", "-s"])
    }

    /// `ssh $MUX -O check|exit <host>`. `check` asks our own child, over the socket,
    /// whether it is alive; it says nothing about the server (section 6.1).
    public static func control(_ command: String, controlPath: String, host: String) -> SSHInvocation {
        SSHInvocation(arguments: muxOptions(controlPath: controlPath) + ["-O", command, host])
    }

    /// `ssh -G`, for the resolution `add` and `show` display and for the ProxyJump chain
    /// (section 4.1). `ignoreConfigFiles` is the `-F /dev/null` half of the attribution
    /// diff: a value that differs between the two came from a config file, and `-F`
    /// silences `/etc/ssh/ssh_config` as well as the user's file.
    public static func resolve(target: SSHTarget, ignoringConfigFiles: Bool) -> SSHInvocation {
        var arguments: [String] = []
        if ignoringConfigFiles { arguments += ["-F", "/dev/null"] }
        arguments.append("-G")
        arguments += destinationOverrides(target)
        // `ssh -G` keeps whatever `ProxyJump` the options carry, unlike the master line
        // below: resolving it is exactly how the chain builder learns about it.
        arguments += target.sshOptions
        arguments.append(target.host)
        return SSHInvocation(arguments: arguments)
    }
}
