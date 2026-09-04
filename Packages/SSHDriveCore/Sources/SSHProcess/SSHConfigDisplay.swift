import Foundation

/// The "what does this host resolve to" display `sshdrive add` shows before it connects,
/// and `sshdrive show` prints afterwards (DESIGN.md sections 4.1, 6.1, 8).
///
/// `ssh -G` prints resolved values only, with no indication of where each came from, so
/// the attribution is the diff against `ssh -F /dev/null -G`: a value that differs between
/// the two came from a config file. `-F` silences `/etc/ssh/ssh_config` as well as the
/// user's file, so the label reads "from ssh config" and never credits `~/.ssh/config`
/// with a value Apple's system file set.
///
/// Nothing here spawns anything. It takes the two resolutions and the location's own
/// overrides and produces lines, which is what makes the whole display unit-testable.
public struct SSHConfigDisplay: Sendable, Equatable {

    /// Where one resolved value came from. The three sources are exactly the three
    /// precedence levels `ssh` itself has: our `-o` overrides beat a config file, which
    /// beats the compiled-in default.
    public enum Source: String, Sendable, Equatable {
        /// An explicit flag on `sshdrive add`, stored on the location and passed as `-o`.
        case override
        /// A `~/.ssh/config` or `/etc/ssh/ssh_config` stanza.
        case configFile = "ssh config"
        /// `ssh`'s own default.
        case builtIn = "ssh default"
    }

    public struct Line: Sendable, Equatable {
        public var keyword: String
        public var value: String
        public var source: Source
        /// True for a keyword the agent forces regardless (section 6.1), which is printed
        /// separately so the user can see it was overridden.
        public var overriddenByUs: Bool

        public init(keyword: String, value: String, source: Source, overriddenByUs: Bool = false) {
            self.keyword = keyword
            self.value = value
            self.source = source
            self.overriddenByUs = overriddenByUs
        }

        /// "port 2201 (from ssh config)".
        public var text: String {
            var out = "\(keyword) \(value)"
            switch source {
            case .override: out += " (from this location)"
            case .configFile: out += " (from ssh config)"
            case .builtIn: out += " (ssh default)"
            }
            if overriddenByUs { out += " - overridden by SSH Drive" }
            return out
        }
    }

    /// The keywords `add` shows by default, in the order section 8.1's example prints
    /// them. `identityfile` repeats, and every repetition is shown, because the order is
    /// the offer order and a touch-required FIDO key sitting first is exactly what
    /// section 4.2's refusal is about.
    public static let displayedKeywords = [
        "user", "hostname", "port", "identityfile", "identitiesonly", "identityagent",
        "proxyjump", "proxycommand", "preferredauthentications", "pubkeyauthentication",
        "passwordauthentication", "kbdinteractiveauthentication", "certificatefile",
        "userknownhostsfile", "stricthostkeychecking",
    ]

    public var lines: [Line]
    /// Keywords the agent always overrides that a config file had set (section 6.1).
    public var overridden: [Line]
    /// A hand-written `ProxyCommand` that invokes `ssh` escapes every override we apply
    /// (section 6.1); `add` says so and recommends `ProxyJump`.
    public var handWrittenProxyCommand: String?
    /// The chain the agent will rebuild as its own `ProxyCommand`.
    public var jumpChain: [JumpHop]

    public init(
        lines: [Line], overridden: [Line], handWrittenProxyCommand: String?,
        jumpChain: [JumpHop]
    ) {
        self.lines = lines
        self.overridden = overridden
        self.handWrittenProxyCommand = handWrittenProxyCommand
        self.jumpChain = jumpChain
    }

    /// Builds the display from the attribution diff and the location's own overrides.
    ///
    /// - Parameter overrideKeywords: the keywords the location itself supplies, lowercased
    ///   (`user`, `port`, `identityfile`, plus anything in its `sshOptions`). These beat
    ///   the config file for `ssh` and must therefore be labelled as ours even though the
    ///   diff sees them in both runs.
    public static func make(
        attribution: SSHConfigAttribution,
        overrideKeywords: Set<String>,
        keywords: [String] = displayedKeywords
    ) -> SSHConfigDisplay {
        let fromConfig = attribution.fromConfigFiles
        var lines: [Line] = []
        for keyword in keywords {
            guard let values = attribution.resolved.values[keyword], !values.isEmpty else { continue }
            for value in values where !value.isEmpty {
                let source: Source
                if overrideKeywords.contains(keyword) {
                    source = .override
                } else if fromConfig.contains(keyword) {
                    source = .configFile
                } else {
                    source = .builtIn
                }
                lines.append(Line(keyword: keyword, value: value, source: source))
            }
        }

        let overridden = attribution.overriddenByUs.map {
            Line(keyword: $0.keyword, value: $0.configValue, source: .configFile, overriddenByUs: true)
        }
        let hand = ProxyChainBuilder.isHandWrittenSSHProxyCommand(attribution.resolved.proxyCommand)
            ? attribution.resolved.proxyCommand
            : nil
        let chain = (try? attribution.resolved.jumpChain()) ?? []
        return SSHConfigDisplay(
            lines: lines, overridden: overridden, handWrittenProxyCommand: hand, jumpChain: chain)
    }

    /// The keywords a location's own values occupy, for `overrideKeywords` above.
    public static func overrideKeywords(for target: SSHTarget) -> Set<String> {
        var out: Set<String> = []
        if target.user != nil { out.insert("user") }
        if target.port != nil { out.insert("port") }
        if target.identityFile != nil { out.insert("identityfile") }
        var index = 0
        while index < target.sshOptions.count {
            let word = target.sshOptions[index]
            if word == "-o", index + 1 < target.sshOptions.count {
                let pair = target.sshOptions[index + 1]
                if let equals = pair.firstIndex(of: "=") {
                    out.insert(String(pair[pair.startIndex ..< equals]).lowercased())
                }
                index += 2
                continue
            }
            // `sshOptions` is stored either as ["-o", "K=V"] pairs or as bare "K=V", which
            // is what `debug ssh add` wrote; both are accepted.
            if let equals = word.firstIndex(of: "=") {
                out.insert(String(word[word.startIndex ..< equals]).lowercased())
            }
            index += 1
        }
        return out
    }

    /// The whole display as text, for the CLI.
    public var text: String {
        var out = lines.map { "  " + $0.text }
        if !jumpChain.isEmpty {
            let hops = jumpChain.map { hop -> String in
                var text = hop.host
                if let user = hop.user { text = "\(user)@\(text)" }
                if let port = hop.port { text += ":\(port)" }
                return text
            }
            out.append("  jump chain " + hops.joined(separator: " -> ")
                + " (rebuilt as SSH Drive's own ProxyCommand; never handed to ssh)")
        }
        if let handWrittenProxyCommand {
            out.append(
                "  warning: the resolved ProxyCommand runs ssh itself (\(handWrittenProxyCommand)); "
                    + "that inner ssh escapes every option SSH Drive sets. Prefer ProxyJump.")
        }
        for line in overridden {
            out.append("  " + line.text)
        }
        return out.joined(separator: "\n")
    }
}
