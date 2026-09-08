import Foundation
import XCTest

import AgentCore
import Secrets
import XPCProtocols
import SSHProcess
@testable import ServerModel

/// Suite K: the `ssh` command lines, the master, the mux clients and the auth prompts,
/// run against `FakeSSH` (`docs/testing-architecture.md` sections 4.2 and 5).
///
/// `SSHMaster` spawns the stub by the same `posix_spawn` and the same argv it spawns
/// `/usr/bin/ssh` with, so `SSHInvocation`'s assembly, `ControlSocket`, `Spawn` and
/// `SSHExitClassifier` all run for real on a box with no server.
final class TransportScenarios: XCTestCase {

    private var stubs: [FakeSSH] = []
    private var masters: [SSHMaster] = []

    override func tearDown() async throws {
        for master in masters { await master.shutdown() }
        masters = []
        for stub in stubs { stub.uninstall() }
        stubs = []
    }

    private func fakeSSH(
        _ profile: ServerProfile, hostKeyKnown: Bool = true, authenticationDelay: TimeInterval = 0
    ) throws -> FakeSSH {
        if let reason = FakeSSHD.unavailabilityReason(for: profile) {
            throw XCTSkip("\(profile.name): \(reason)")
        }
        let stub = try FakeSSH(profile: profile, hostKeyKnown: hostKeyKnown,
                               authenticationDelay: authenticationDelay)
        stub.install()
        stubs.append(stub)
        return stub
    }

    /// The host as `ssh` would see it: a profile name that carries an account (`deb/pw`)
    /// is a testbed label, not a hostname.
    private func hostName(_ profile: ServerProfile) -> String {
        profile.name.replacingOccurrences(of: "/", with: "-")
    }

    private func master(
        _ profile: ServerProfile, controlPath: String, proxyCommand: String? = nil,
        environment extra: [String: String] = [:], capturesRemoteVersion: Bool = false,
        user: String = "alec"
    ) -> SSHMaster {
        var environment = ProcessInfo.processInfo.environment
        environment["USER"] = user
        for (key, value) in extra { environment[key] = value }
        let target = SSHTarget(host: hostName(profile), user: user, port: profile.port)
        let master = SSHMaster(configuration: .init(
            locationID: UUID().uuidString,
            target: target,
            environment: environment,
            proxyCommand: proxyCommand,
            authenticationDeadline: 15,
            controlPath: controlPath,
            capturesRemoteVersion: capturesRemoteVersion))
        masters.append(master)
        return master
    }

    private func controlPath(_ stub: FakeSSH) -> String {
        stub.directory.appendingPathComponent("ctl").path
    }

    // MARK: - K1: ProxyCommand first, then the cancellation

    /// **K1** (`SQ-038`): `-o ProxyJump=none` written **before** `-o ProxyCommand=…`
    /// silently discards the ProxyCommand - readconf takes the first setting of the field
    /// and `ProxyJump none` marks it set - and the master then resolves the inner hostname
    /// itself and dies `Could not resolve hostname`. Both orders are run for real here, so
    /// the ordering rule is defended by the failure it prevents and not by a comment.
    func testK1_theProxyCommandIsWrittenFirstAndTheReversedOrderReallyDiscardsIt() async throws {
        let stub = try fakeSSH(.debian)
        let invocation = SSHCommandBuilder.master(
            target: SSHTarget(host: "deb", user: "alec"),
            controlPath: controlPath(stub), proxyCommand: "/bin/true")
        let proxyIndex = invocation.arguments.firstIndex(of: "ProxyCommand=/bin/true")
        let jumpIndex = invocation.arguments.firstIndex(of: "ProxyJump=none")
        XCTAssertNotNil(proxyIndex)
        XCTAssertNotNil(jumpIndex)
        XCTAssertLessThan(proxyIndex!, jumpIndex!,
                          "SQ-038: the ProxyCommand must be written first")

        // The order we ship: the ProxyCommand really runs and the master comes up. The
        // master is `-N` with `ControlPersist=no`, so it stays in the foreground as our
        // own child (SQ-041) and only its control socket says it authenticated.
        let live = self.master(.debian, controlPath: controlPath(stub), proxyCommand: "/bin/true")
        try await live.connect()
        XCTAssertEqual(stub.proxyCommandsRun, ["/bin/true"],
                       "SQ-038: with the right order the ProxyCommand is honoured")
        await live.shutdown()

        // The order that used to ship: readconf keeps `none` and the ProxyCommand is gone.
        var reversed = ["-N"]
        reversed += ["-o", "ControlMaster=yes", "-o", "ControlPath=\(controlPath(stub))-2",
                     "-o", "ControlPersist=no"]
        reversed += ["-o", "ProxyJump=none", "-o", "ProxyCommand=/bin/true"]
        reversed += ["-o", "User=alec", "deb-inner"]
        let bad = try Spawn.capture(
            executable: stub.executablePath, argv: [stub.executablePath] + reversed,
            environment: ["USER": "alec", "PATH": "/usr/bin:/bin"], timeout: 15)
        XCTAssertEqual(bad.exit.status, 255)
        let stderr = String(decoding: bad.stderr, as: UTF8.self)
        XCTAssertTrue(stderr.contains("Could not resolve hostname deb-inner"),
                      "SQ-038: the master resolved the inner hostname itself and died")
        XCTAssertEqual(stub.proxyCommandsRun.last, "discarded")
        // And every line of it ends CRLF, which is `SQ-035`'s whole point.
        XCTAssertTrue(stderr.contains("\r\n"), "SQ-035: ssh's stderr lines end CRLF")
    }

    /// **K11** (`SQ-035`): in Swift `"\r\n"` is one `Character`, so `split(separator:
    /// "\n")` finds no separator in `ssh -v` output at all and the whole transcript is one
    /// "line". The captured version became `Tailscale` followed by a hundred `debug1:`
    /// lines, which `status` then printed. Line endings are normalised on **unicode
    /// scalars** first, and this runs that on stderr a real process really wrote.
    func testK11andK12_theIdentificationStringIsOneTokenOutOfCRLFStderr() async throws {
        let stub = try fakeSSH(.tailscaleSSH)
        let path = controlPath(stub)
        let master = self.master(.tailscaleSSH, controlPath: path, capturesRemoteVersion: true)
        try await master.connect()
        let version = await master.remoteSoftwareVersion
        XCTAssertEqual(version, "Tailscale",
                       "SQ-035/SQ-036: one token, not the whole transcript")
        let stderr = await master.lastStderr
        XCTAssertFalse(stderr.contains("debug1:"),
                       "the debug lines are stripped before anything else reads it")
        await master.shutdown()
    }

    // MARK: - K2: %h/%p doubled once per level

    /// **K2** (`SQ-039`, `SQ-040`): `ssh` percent-expands the **whole** `ProxyCommand`
    /// before `/bin/sh -c` sees it, including the `%h:%p` belonging to a hop nested inside
    /// it. Without the doubling, hop 1 dials the *destination's* host and port instead of
    /// hop 2's - which is what the testbed measured as hop 2 talking to `inner` while
    /// checking `bastion-b`'s host key. Every hop also carries `ControlPath=none`, because
    /// `ControlMaster=no` alone still attaches to the config's socket.
    func testK2_theNestedHopsPercentsAreDoubledOncePerLevel() async throws {
        let stub = try fakeSSH(.debian)
        let hops = [JumpHop(host: "bastion-a", user: "hop", port: 2210),
                    JumpHop(host: "bastion-b", user: "hop")]
        let chain = ProxyChainBuilder.proxyCommand(for: hops, identityAgentNone: true)
        let proxyCommand = try XCTUnwrap(chain)
        XCTAssertTrue(proxyCommand.contains("%%h:%%p"),
                      "SQ-039: the inner hop's marker is doubled once for the level it sits below")
        XCTAssertEqual(
            proxyCommand.components(separatedBy: "ControlPath=none").count - 1, 2,
            "SQ-040: ControlMaster=no alone is not enough - every hop carries ControlPath=none")

        let live = self.master(
            .debian.with(name: "inner", port: 2222), controlPath: controlPath(stub),
            proxyCommand: proxyCommand)
        try await live.connect()
        await live.shutdown()

        let targets = stub.hopInvocations.compactMap { argv -> String? in
            guard let index = argv.firstIndex(of: "-W"), index + 1 < argv.count else { return nil }
            return argv[index + 1]
        }
        XCTAssertTrue(targets.contains("inner:2222"),
                      "the outermost hop dials the destination, which is right")
        XCTAssertTrue(
            targets.contains("bastion-b:22"),
            "SQ-039: hop 1 dials **hop 2**, not the destination. Got \(targets)")
        XCTAssertFalse(
            targets.filter { $0 == "inner:2222" }.count > 1,
            "SQ-039: without the doubling both hops would dial the destination")
    }

    /// **K2** (`SQ-039`): the counter-example, run for real. A chain built without the
    /// per-level doubling has hop 1 dialling the destination, which is the failure the
    /// escaping exists to prevent.
    func testK2_withoutTheDoublingHopOneDialsTheDestination() async throws {
        let stub = try fakeSSH(.debian)
        // A hand-built two-hop chain with the inner %h:%p left undoubled.
        let inner = ShellQuoting.commandLine(
            [stub.executablePath, "-W", "%h:%p", "-o", "ControlPath=none", "-l", "hop",
             "-p", "2210", "bastion-a"])
        let outer = ShellQuoting.commandLine(
            [stub.executablePath, "-W", "%h:%p", "-o", "ControlPath=none",
             "-o", "ProxyCommand=\(inner)", "-o", "ProxyJump=none", "-l", "hop", "bastion-b"])
        let live = self.master(
            .debian.with(name: "inner", port: 2222), controlPath: controlPath(stub),
            proxyCommand: outer)
        try await live.connect()
        await live.shutdown()

        let targets = stub.hopInvocations.compactMap { argv -> String? in
            guard let index = argv.firstIndex(of: "-W"), index + 1 < argv.count else { return nil }
            return argv[index + 1]
        }
        XCTAssertEqual(
            targets.filter { $0 == "inner:2222" }.count, 2,
            "SQ-039: undoubled, one expansion reaches both hops and hop 1 dials the destination")
    }

    // MARK: - K13 / K14: a dead master is not a refusal

    /// **K13 / K14** (`SQ-079`, `SQ-021`): a channel open that failed because the master
    /// died is not distinguishable from a refused session by anything but the master.
    /// A refusal `ssh` really prints, on a master that is still running, may be cached as
    /// the location's channel budget; everything a dead master produces must not be - the
    /// field failure was a location stuck at "MaxSessions 1, SFTP-only" against a healthy
    /// server, across every restart, because nothing re-probes.
    func testK13andK14_aDeadMasterIsNeverCachedAsAMaxSessionsBudget() async throws {
        let stub = try fakeSSH(.debianMaxSessions)
        let path = controlPath(stub)
        let master = self.master(.debianMaxSessions, controlPath: path)
        try await master.connect()

        // A real refusal, from a master that is still there: MaxSessions 2 means the
        // master's own session plus one - so the second exec channel is refused.
        var refusal = ""
        var held: ExecChannel?
        do {
            held = try await master.openExecChannel(
                script: RemoteScript(body: "printf '%s\\000' one; sleep 30"),
                readinessDeadline: 10)
            _ = try await master.openExecChannel(
                script: RemoteScript(body: "printf '%s\\000' two"), readinessDeadline: 10)
            XCTFail("SQ-021: MaxSessions 2 leaves exactly one spare channel")
        } catch let error as SSHProcessError {
            refusal = "\(error)"
            XCTAssertEqual(error.classification, .channelLimitReached,
                           "SQ-021: a refused session is not 'master lost'")
        }
        XCTAssertTrue(refusal.contains("session request failed"), "SQ-021: ssh's own wording")
        XCTAssertEqual(
            ChannelProbeVerdict.classify(diagnostics: refusal, masterIsRunning: true),
            .sessionRefused,
            "SQ-079: a refusal on a live master is a fact about the server and may be cached")
        held?.close()

        // Now the master goes. The mux client's stderr is completely different, and
        // caching it as a budget is the 0.1.2 field failure.
        await master.shutdown()
        var deathDiagnostics = ""
        do {
            _ = try await master.openExecChannel(
                script: RemoteScript(body: "true"), readinessDeadline: 5)
            XCTFail("a mux client with no socket must fail rather than connect")
        } catch let error as SSHProcessError {
            deathDiagnostics = "\(error)"
            XCTAssertEqual(error.classification, .masterLost,
                           "SQ-042: a mux client that never opened its channel is master lost")
        }
        XCTAssertTrue(deathDiagnostics.contains("Control socket connect"), "SQ-079")
        XCTAssertEqual(
            ChannelProbeVerdict.classify(diagnostics: deathDiagnostics, masterIsRunning: false),
            .connectionDied,
            "SQ-079: nothing is recorded when the connection is what failed")
        // Even with the master wrongly believed alive, the wording alone is enough.
        XCTAssertEqual(
            ChannelProbeVerdict.classify(diagnostics: deathDiagnostics, masterIsRunning: true),
            .connectionDied)
    }

    /// **N3 / J12** (`SQ-021`, `SQ-022`): the probe asks "may I hold three at once", and a
    /// `MaxSessions 2` server leaves exactly one spare beside the metadata channel - so
    /// the bulk channel is dropped and the spare is kept for exec, which the sweep, the
    /// probe and the helper cannot share. With that one exec channel **held**, tier 2 has
    /// nothing left, and `status` says so rather than the location retrying for ever.
    func testN3andJ12_theSpareChannelIsSingularAndAHeldOneLeavesNothingForTierTwo() async throws {
        let stub = try fakeSSH(.debianMaxSessions)
        let path = controlPath(stub)
        let master = self.master(.debianMaxSessions, controlPath: path)
        try await master.connect()

        let held = try await master.openExecChannel(
            script: RemoteScript(body: "printf '%s\\000' held; sleep 30"),
            readinessDeadline: 10)
        defer { held.close() }
        _ = try await Testbedish.read(held)

        // Tier 2 wants a channel of its own and there is none.
        do {
            _ = try await master.openExecChannel(
                script: RemoteScript(body: "printf '%s\\000' helper", heartbeat: .standard),
                readinessDeadline: 10)
            XCTFail("SQ-021: there is exactly one spare and it is already held")
        } catch let error as SSHProcessError {
            XCTAssertEqual(error.classification, .channelLimitReached)
        }

        // Release it and the same channel opens, which is what makes the budget a budget
        // and not a verdict about the server's software.
        held.close()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let after = try await master.openExecChannel(
            script: RemoteScript(body: "printf '%s\\000' free"), readinessDeadline: 10)
        defer { after.close() }
        let payload = try await Testbedish.read(after)
        XCTAssertEqual(String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self), "free")
    }

    // MARK: - The `add` flow's prompts

    /// **K7 / K10** (`SQ-060`, `SQ-047`, `SQ-062`): the `add` flow against a server whose
    /// password prompt strings are the captured OpenSSH 10.2 ones, **trailing spaces
    /// included**. The host-key question arrives with `SSH_ASKPASS_PROMPT` unset, exactly
    /// like a password, so classifying on the hint would answer a stored password to "Are
    /// you sure you want to continue connecting"; the text is what decides.
    func testK7andK10_theAddFlowsPromptsAreTheCapturedOpenSSHStrings() async throws {
        let stub = try fakeSSH(.debianPassword, hostKeyKnown: false)
        let askpass = try stub.makeAskpass(answers: [
            (match: "continue connecting", answer: "yes"),
            (match: "password:", answer: "spike-password"),
        ])
        let path = controlPath(stub)
        let master = self.master(
            .debianPassword, controlPath: path,
            environment: [AskpassEnvironment.askpassVariable: askpass.path,
                          AskpassEnvironment.requireVariable: AskpassEnvironment.requireForce,
                          "USER": "alec"])
        try await master.connect()
        await master.shutdown()

        let prompts = stub.askpassPrompts
        XCTAssertEqual(prompts.count, 2, "one host-key question, then one password")

        // SQ-047: the host-key question carries no hint.
        XCTAssertTrue(prompts[0].prompt.hasSuffix(
            "Are you sure you want to continue connecting (yes/no/[fingerprint])? "),
            "SQ-060: the exact wording, trailing space included")
        XCTAssertEqual(prompts[0].hint, "", "SQ-047: SSH_ASKPASS_PROMPT is unset for it")
        XCTAssertEqual(
            AskpassPromptClassifier.classify(prompt: prompts[0].prompt, promptKind: prompts[0].hint),
            .confirmation(question: prompts[0].prompt, isHostKey: true),
            "the text is what classifies it, never the hint")

        // SQ-060: `<user>@<host>'s password: `.
        XCTAssertEqual(prompts[1].prompt,
                       OpenSSHPrompts.password(
                        user: "alec", host: hostName(ServerProfile.debianPassword)))
        XCTAssertEqual(prompts[1].hint, "")
        XCTAssertEqual(
            AskpassPromptClassifier.classify(prompt: prompts[1].prompt, promptKind: prompts[1].hint),
            .password(promptUser: "alec", promptHost: hostName(ServerProfile.debianPassword)),
            "SQ-060: and the password prompt names the account the keychain keys on")
    }

    /// **K7** (`SQ-062`): a keyboard-interactive password reaches askpass as
    /// `(<user>@<host>) Password: ` and is stored under the same key as a plain password.
    func testK7_keyboardInteractiveHasItsOwnPromptShapeAndTheSameKeychainKey() async throws {
        let stub = try fakeSSH(.debianKbdInt)
        let askpass = try stub.makeAskpass(answers: [(match: "Password:", answer: "spike-password")])
        let master = self.master(
            .debianKbdInt, controlPath: controlPath(stub),
            environment: [AskpassEnvironment.askpassVariable: askpass.path,
                          AskpassEnvironment.requireVariable: AskpassEnvironment.requireForce,
                          "USER": "kbd"], user: "kbd")
        try await master.connect()
        await master.shutdown()
        let prompts = stub.askpassPrompts
        XCTAssertEqual(prompts.first?.prompt,
                       OpenSSHPrompts.keyboardInteractive(
                        user: "kbd", host: hostName(ServerProfile.debianKbdInt)),
                       "SQ-062: `(<user>@<host>) Password: `")
    }

    /// **K9** (`SQ-052`): a wrong password, a missing key agent, a dead one and a *locked*
    /// one all produce the same bare `Permission denied (publickey,password).` at
    /// `LogLevel=ERROR` - so stderr distinguishes no key-agent state and the pre-spawn
    /// socket probe is the only signal there is. The classification is an authentication
    /// stop either way, which is what keeps a stale password out of a `fail2ban` ban.
    func testK9_aWrongPasswordIsTheSameSentenceAsEveryKeyAgentStateAndStopsReconnection()
        async throws
    {
        let stub = try fakeSSH(.debianPassword)
        let askpass = try stub.makeAskpass(answers: [], fallback: "not-the-password")
        let master = self.master(
            .debianPassword, controlPath: controlPath(stub),
            environment: [AskpassEnvironment.askpassVariable: askpass.path,
                          AskpassEnvironment.requireVariable: AskpassEnvironment.requireForce,
                          "USER": "alec"])
        do {
            try await master.connect()
            XCTFail("the wrong password must not authenticate")
        } catch let error as SSHProcessError {
            XCTAssertEqual(error.classification, .authenticationFailed)
        }
        let stderr = await master.lastStderr
        XCTAssertTrue(stderr.contains(OpenSSHPrompts.permissionDenied), "SQ-052: the bare sentence")
        let classification = await master.lastClassification
        XCTAssertEqual(classification?.stopsReconnection, true,
                       "section 6.1: a stale password retried every minute is a ban within the hour")
    }

    /// **K10** (`SQ-041`, section 4.2): the authentication deadline is signalled by the
    /// control socket appearing, and it is the *whole* budget - the 15 s `ConnectTimeout`
    /// is contained in it, never added. A master that never authenticates inside it is
    /// stopped, and for a first-pass location that stop is transient, not an auth refusal.
    func testK10_theAuthenticationDeadlineIsTheControlSocketsAppearance() async throws {
        let stub = try fakeSSH(.debian, authenticationDelay: 30)
        var environment = ProcessInfo.processInfo.environment
        environment["USER"] = "alec"
        let master = SSHMaster(configuration: .init(
            locationID: UUID().uuidString,
            target: SSHTarget(host: "deb", user: "alec"),
            environment: environment,
            authenticationDeadline: 2,
            controlPath: controlPath(stub)))
        masters.append(master)
        let started = Date()
        do {
            try await master.connect()
            XCTFail("the socket never appeared inside the deadline")
        } catch let error as SSHProcessError {
            XCTAssertEqual(error.classification, .transient,
                           "section 6.1: only an agentDependent location's deadline is an auth stop")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "the deadline is the budget, not a floor")
    }
}

/// The two-line reader every exec-channel test needs. Every read has a deadline, harnesses
/// included: `bashbg` never sends EOF (`SQ-016`).
enum Testbedish {
    static func read(_ channel: ExecChannel, timeout: TimeInterval = 15) async throws -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = try await channel.stream.read(upTo: 64 * 1024, deadline: deadline)
            if chunk.isEmpty { break }
            out.append(chunk)
            if out.contains(0) { break }
        }
        return out
    }
}
