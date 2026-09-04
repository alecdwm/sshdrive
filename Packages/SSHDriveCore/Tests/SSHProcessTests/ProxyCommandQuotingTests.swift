import XCTest
@testable import SSHProcess

/// The agent-built `ProxyJump` chain (DESIGN.md section 6.1) and the single-quoting rule
/// (section 9.2) it shares with remote scripts.
final class ProxyCommandQuotingTests: XCTestCase {

    func testSingleQuotingIsTotal() {
        XCTAssertEqual(ShellQuoting.singleQuoted("plain"), "'plain'")
        XCTAssertEqual(ShellQuoting.singleQuoted(""), "''")
        XCTAssertEqual(ShellQuoting.singleQuoted("space in name"), "'space in name'")
        XCTAssertEqual(ShellQuoting.singleQuoted("quote'name"), "'quote'\\''name'")
        XCTAssertEqual(ShellQuoting.singleQuoted("$(echo pwned)"), "'$(echo pwned)'")
        XCTAssertEqual(ShellQuoting.singleQuoted("back\\slash"), "'back\\slash'")
        XCTAssertEqual(ShellQuoting.singleQuoted("a\nb"), "'a\nb'")
    }

    func testJumpHostParsing() throws {
        XCTAssertEqual(try JumpHop.parse("bastion"), JumpHop(host: "bastion"))
        XCTAssertEqual(try JumpHop.parse("hop@bastion"), JumpHop(host: "bastion", user: "hop"))
        XCTAssertEqual(
            try JumpHop.parse("hop@192.168.64.1:2210"),
            JumpHop(host: "192.168.64.1", user: "hop", port: 2210)
        )
        XCTAssertEqual(try JumpHop.parse("[2001:db8::1]:22"), JumpHop(host: "2001:db8::1", port: 22))
        XCTAssertEqual(
            try JumpHop.parseChain("spike-bastion-a,spike-bastion-b"),
            [JumpHop(host: "spike-bastion-a"), JumpHop(host: "spike-bastion-b")]
        )
        XCTAssertEqual(try JumpHop.parseChain("none"), [])
        XCTAssertThrowsError(try JumpHop.parse("@host"))
    }

    /// A hop needs no socket of its own, and `ControlMaster=no` alone is not enough to
    /// keep it off the user's: with `no`, ssh still attaches to an existing socket at
    /// whatever `ControlPath` the config names. Only `ControlPath=none` clears it.
    func testHopCarriesControlMasterNoAndControlPathNone() {
        let arguments = ProxyChainBuilder.hopArguments(
            JumpHop(host: "bastion", user: "hop", port: 2210),
            identityAgentNone: true, innerProxyCommand: nil
        )
        XCTAssertEqual(arguments.first, "/usr/bin/ssh")
        XCTAssertEqual(Array(arguments[1 ... 2]), ["-W", "%h:%p"])
        XCTAssertTrue(arguments.contains("ControlMaster=no"))
        XCTAssertTrue(arguments.contains("ControlPath=none"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("ControlPersist") })
        // The same session-shape and host-key overrides as the master.
        for pair in ["StrictHostKeyChecking=yes", "UpdateHostKeys=no", "RequestTTY=no",
                     "ForwardAgent=no", "PermitLocalCommand=no", "ClearAllForwardings=yes",
                     "ForkAfterAuthentication=no", "IdentityAgent=none"] {
            XCTAssertTrue(arguments.contains(pair), pair)
        }
        XCTAssertEqual(Array(arguments.suffix(5)), ["-l", "hop", "-p", "2210", "bastion"])
    }

    /// A bare alias goes through untouched so the hop's own host block still applies,
    /// exactly as it would under `ssh -J`.
    func testAliasHopGetsNoDashLOrDashP() {
        let arguments = ProxyChainBuilder.hopArguments(
            JumpHop(host: "spike-bastion-a"), identityAgentNone: true, innerProxyCommand: nil
        )
        XCTAssertFalse(arguments.contains("-l"))
        XCTAssertFalse(arguments.contains("-p"))
        XCTAssertEqual(arguments.last, "spike-bastion-a")
    }

    func testAgentDependentHopKeepsTheConfigsIdentityAgent() {
        let arguments = ProxyChainBuilder.hopArguments(
            JumpHop(host: "bastion"), identityAgentNone: false, innerProxyCommand: nil
        )
        XCTAssertFalse(arguments.contains("IdentityAgent=none"))
    }

    func testSingleHopProxyCommandIsFullyQuoted() throws {
        let command = ProxyChainBuilder.proxyCommand(
            for: try JumpHop.parseChain("hop@192.168.64.1:2210"), identityAgentNone: true
        )
        let command2 = try XCTUnwrap(command)
        XCTAssertTrue(command2.hasPrefix("'/usr/bin/ssh' '-W' '%h:%p'"), command2)
        XCTAssertTrue(command2.hasSuffix("'-l' 'hop' '-p' '2210' '192.168.64.1'"), command2)
        // Nothing unquoted can reach /bin/sh -c.
        XCTAssertEqual(unquote(command2).first, "/usr/bin/ssh")
    }

    /// Two hops: the outer hop carries the inner one as its own ProxyCommand, quoted a
    /// second time. This is what a `spike-bastion-a,spike-bastion-b` chain becomes.
    func testTwoHopChainNestsAndRequotes() throws {
        let command = try XCTUnwrap(ProxyChainBuilder.proxyCommand(
            for: try JumpHop.parseChain("hop@192.168.64.1:2210,hop@bastion-b"),
            identityAgentNone: true
        ))
        let outer = unquote(command)
        XCTAssertEqual(outer.last, "bastion-b")
        XCTAssertEqual(outer.first, "/usr/bin/ssh")
        XCTAssertTrue(outer.contains("ProxyJump=none"), "the inner hop's own ProxyJump is cancelled")
        let index = try XCTUnwrap(outer.firstIndex(where: { $0.hasPrefix("ProxyCommand=") }))
        let inner = unquote(String(outer[index].dropFirst("ProxyCommand=".count)))
        XCTAssertEqual(inner.first, "/usr/bin/ssh")
        XCTAssertEqual(Array(inner.suffix(5)), ["-l", "hop", "-p", "2210", "192.168.64.1"])
        XCTAssertTrue(inner.contains("ControlPath=none"))
        XCTAssertFalse(inner.contains { $0.hasPrefix("ProxyCommand=") }, "hop 1 is reached directly")
        // The outer hop's own -W is expanded by the master; the inner hop's must survive
        // that expansion and be expanded by the outer hop instead, so it is written %%h:%%p.
        XCTAssertEqual(outer[2], "%h:%p")
        XCTAssertEqual(inner[2], "%%h:%%p")
    }

    /// The identity-path-with-a-space-and-a-quote case: it survives two levels of shell.
    func testIdentityPathWithASpaceAndAQuoteSurvivesTwoLevels() throws {
        let awkward = "/Users/alec/.ssh/spike key's copy"
        let hop = JumpHop(host: "bastion", user: "hop")
        let inner = ShellQuoting.commandLine(
            ProxyChainBuilder.hopArguments(hop, identityAgentNone: true, innerProxyCommand: nil)
                + ["-i", awkward]
        )
        let outer = ShellQuoting.commandLine(
            ProxyChainBuilder.hopArguments(
                JumpHop(host: "bastion-b"), identityAgentNone: true, innerProxyCommand: inner
            )
        )
        let outerArguments = unquote(outer)
        let index = try XCTUnwrap(outerArguments.firstIndex(where: { $0.hasPrefix("ProxyCommand=") }))
        let innerArguments = unquote(String(outerArguments[index].dropFirst("ProxyCommand=".count)))
        XCTAssertEqual(innerArguments.last, awkward)
    }

    /// Each level of nesting doubles again: a three-hop chain's innermost -W is %%%%h:%%%%p.
    func testThreeHopChainDoublesPercentsPerLevel() throws {
        let command = try XCTUnwrap(ProxyChainBuilder.proxyCommand(
            for: try JumpHop.parseChain("a,b,c"), identityAgentNone: true
        ))
        let third = unquote(command)
        XCTAssertEqual(third.last, "c")
        XCTAssertEqual(third[2], "%h:%p")
        let secondCommand = try XCTUnwrap(third.first { $0.hasPrefix("ProxyCommand=") })
        let second = unquote(String(secondCommand.dropFirst("ProxyCommand=".count)))
        XCTAssertEqual(second.last, "b")
        XCTAssertEqual(second[2], "%%h:%%p")
        let firstCommand = try XCTUnwrap(second.first { $0.hasPrefix("ProxyCommand=") })
        let first = unquote(String(firstCommand.dropFirst("ProxyCommand=".count)))
        XCTAssertEqual(first.last, "a")
        XCTAssertEqual(first[2], "%%%%h:%%%%p")
    }

    func testHandWrittenSSHProxyCommandIsDetected() {
        XCTAssertTrue(ProxyChainBuilder.isHandWrittenSSHProxyCommand("ssh -W %h:%p bastion"))
        XCTAssertTrue(ProxyChainBuilder.isHandWrittenSSHProxyCommand("/opt/homebrew/bin/ssh -W %h:%p b"))
        XCTAssertFalse(ProxyChainBuilder.isHandWrittenSSHProxyCommand("cloudflared access ssh --hostname x"))
        XCTAssertFalse(ProxyChainBuilder.isHandWrittenSSHProxyCommand("none"))
        XCTAssertFalse(ProxyChainBuilder.isHandWrittenSSHProxyCommand(nil))
    }

    /// The quoting rule, checked against a real `/bin/sh -c`, which is what ssh runs a
    /// ProxyCommand through. Every awkward name from the testbed's `weird/` tree plus the
    /// identity path with a space and a quote.
    func testRealShAgreesWithOurQuoting() throws {
        let awkward = [
            "space in name", "quote'name", "$(echo pwned)", "[bracket]", "back\\slash",
            "*star*", "line\nbreak", "utf8-caf\u{e9}", ".hidden", "~/.ssh/spike key's copy",
            "a\"double\"quote", "semi;colon", "back`tick`", "!bang",
        ]
        let line = ShellQuoting.commandLine(["/usr/bin/printf", "%s\\000"] + awkward)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
            .dropLast().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(records, awkward)
    }

    /// Two levels of shell: the outer ProxyCommand is run by ssh through /bin/sh -c, and
    /// the inner one by the hop's own ssh through another /bin/sh -c.
    func testRealShAgreesAfterTwoRoundsOfQuoting() throws {
        let awkward = "~/.ssh/spike key's copy"
        let inner = ShellQuoting.commandLine(["/usr/bin/printf", "%s\\000", awkward])
        let outer = ShellQuoting.commandLine(["/bin/sh", "-c", inner])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", outer]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: data.dropLast(), as: UTF8.self), awkward)
    }

    /// A minimal `/bin/sh` word splitter, so the tests read the command line the way sh
    /// will rather than the way it was written: single quotes are literal, and a
    /// backslash outside them escapes the next character - which is exactly how the
    /// `'\''` of a re-quoted inner ProxyCommand gets its quote back.
    private func unquote(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var started = false
        var escaped = false
        for character in line {
            if escaped { current.append(character); escaped = false; started = true; continue }
            if !inQuotes, character == "\\" { escaped = true; started = true; continue }
            if character == "'" { inQuotes.toggle(); started = true; continue }
            if character == " ", !inQuotes {
                if started { out.append(current) }
                current = ""; started = false
                continue
            }
            current.append(character); started = true
        }
        if started { out.append(current) }
        return out
    }
}
