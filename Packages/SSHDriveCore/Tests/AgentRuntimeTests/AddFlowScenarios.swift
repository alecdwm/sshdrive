import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import SFTP
import SSHProcess
import Secrets
import ServerModel
import Testing
import XPCProtocols

/// Suite Q - `add`, askpass and the collect connection
/// (docs/design/testing.md), harness **SV**.
///
/// Every scenario here drives the shipping `sshdrive add` end to end: the real command
/// handler in `AgentRuntime`, the real `AddFlow`, the real `CollectConnection`, the real
/// `AskpassBroker` and the real `SSHMaster`, against `ServerModel.FakeSSH` installed as
/// `SSHProcess.sshBinaryPath` and `ServerModel.FakeSFTPServer` on the other side of a real
/// SFTP v3 wire. The only doubles are the ones this suite already names: the terminal
/// (`ScriptedTerminal`), the askpass program (`AskpassBridge`, which is the shipping
/// broker behind a file mailbox instead of an XPC connection) and the replica.
///
/// What that buys is what can otherwise only be proven on the VM against seven
/// testbed servers: key
/// auth, a relayed and stored password, a second location on the same host that does not
/// prompt, one- and two-hop `ProxyJump` chains with a different password per hop,
/// keyboard-interactive, a fresh host key answered no then yes, and a wrong password. All
/// eight run here with no Mac, no VM, no network and no testbed.
extension AgentScenarios {

    /// `.serialized` is stated here as well as inherited from `AgentScenarios`, because
    /// two of the things this suite installs are **process-wide** and a second test
    /// running beside it would silently take them: `SSHProcess.sshBinaryPath`, which
    /// decides which stub *every* `ssh` in the process is, and
    /// `Config.GroupContainer.locator`.
    @Suite(.serialized) struct AddFlowScenarios {

        // MARK: - The bed

        /// One agent, one `ssh`, one server, one terminal.
        ///
        /// Three of these are process-wide and must be put back: `SSHProcess.sshBinaryPath`
        /// (the stub), `Config.GroupContainer.locator` (the harness's own) and the askpass
        /// mailbox's poller thread. `tearDown()` is what a scenario `defer`s.
        final class Bed: @unchecked Sendable {
            let stub: FakeSSH
            let server: FakeSFTPServer
            let bridge: AskpassBridge
            let store: InMemorySecretsStore
            let secrets: AgentSecrets
            let harness: AgentHarness
            /// One wire per location, from the same server.
            ///
            /// Not one shared wire: a location has its own master and its own SFTP
            /// channels on it (docs/design/ssh.md), so two locations on one host are two clients
            /// against one server, and a harness that pooled them would be modelling a
            /// connection nothing ever makes.
            let transports: [RealSFTPTransport]
            private let wireLock = NSLock()
            private var nextWire = 0

            init(
                profile: ServerProfile,
                hostKeyKnown: Bool = true,
                agentOnlyKey: Bool = false,
                extraPrompt: String? = nil,
                extraPromptHint: String = "",
                remoteRoot: String? = nil,
                seed: (FakeSFTPServer) -> Void = { _ in }
            ) async throws {
                stub = try FakeSSH(
                    profile: profile, hostKeyKnown: hostKeyKnown,
                    agentOnlyKey: agentOnlyKey, extraPrompt: extraPrompt,
                    extraPromptHint: extraPromptHint)
                // Every `SSHInvocation` built after this names the stub - the master's, the
                // `ssh -G` resolutions, and every `ProxyJump` hop the chain builder embeds.
                stub.install()

                server = FakeSFTPServer(profile: profile)
                seed(server)
                // The post-auth mount is a real SFTP wire: `RealSFTPTransport` and the
                // whole of `SFTPClient` run unmodified over `FakeSFTPServer`.
                var transports: [RealSFTPTransport] = []
                for _ in 0 ..< 12 {
                    transports.append(
                        try await RealSFTPTransport.connect(
                            stream: server.makeStream(), root: remoteRoot ?? server.root))
                }
                self.transports = transports

                bridge = try AskpassBridge(sshBinaryPath: stub.executablePath)
                let store = InMemorySecretsStore()
                self.store = store
                // The broker resolves the destination of the `ssh` that is *asking* with
                // `ssh -G` (docs/design/secrets.md); it must be the same `ssh` that is connecting, or
                // a `ProxyJump` hop would be resolved by a binary with no idea of it.
                secrets = AgentSecrets(
                    store: store, askpassPath: bridge.executablePath,
                    resolver: SSHGResolver(sshPath: stub.executablePath))
                bridge.start(broker: secrets.broker)

                harness = try AgentHarness(secrets: secrets) { $0.secrets = store }
                let bed = self
                harness.launcher.transportFactory = { bed.wire(for: $0.id) }
            }

            /// A **fresh** wire for every connect attempt, which is what a connect
            /// attempt is (docs/design/ssh.md): a location that reconnects opens a new master and
            /// new channels on it, and never re-uses the channels of the connection that
            /// went. Handing the same wire back per *location* modelled the opposite, so a
            /// wire that had died once was handed straight back to the reconnect and the
            /// location came up and immediately went offline again with `badMessage` -
            /// a harness artefact that looked exactly like a server fault.
            ///
            /// The pool is pre-connected because `TransportLauncher.connect` hands the
            /// factory back synchronously; the last one is re-used if a scenario ever
            /// out-runs it, which none does.
            func wire(for locationID: String) -> RealSFTPTransport {
                wireLock.lock(); defer { wireLock.unlock() }
                let chosen = transports[min(nextWire, transports.count - 1)]
                nextWire += 1
                return chosen
            }

            /// Synchronous, and run under `defer`.
            ///
            /// Three of the things a bed installs are process-wide and must be put back
            /// *before* the scenario returns: `SSHProcess.sshBinaryPath`, the stub's own
            /// directory and the askpass mailbox's poller. Leaving that to a detached
            /// `Task` deletes the stub out from under the **next** scenario, and `defer`
            /// cannot await - so the process-wide half is done here and now, and only the
            /// per-bed half (this agent's own timers, this bed's own wire) is handed to a
            /// task. `defer` is LIFO, so a scenario holding two beds unwinds them in the
            /// order they installed themselves.
            ///
            /// **The order is the whole point, and it was a real flake.** Handing the
            /// shutdown to a detached `Task` let the previous scenario's `DomainManager`
            /// outlive its own bed: its locations went on reconnecting on the breaker's
            /// schedule, and by then `SSHProcess.sshBinaryPath` named the **next**
            /// scenario's stub, so a master built for one profile dialled another's `ssh`,
            /// failed to authenticate, and spent that bed's wires and its prompt log on
            /// the way out. It surfaced as `serverUnreachable` in two or three of the
            /// nine, a different two or three every run, and never when a scenario was run
            /// on its own. So the agent is stopped **before** the process-wide restore,
            /// on a bounded wait, because `defer` cannot await and a teardown may not hang
            /// a suite.
            func tearDown() {
                let manager = harness.manager
                let wires = transports
                let finished = DispatchSemaphore(value: 0)
                Task.detached(priority: .userInitiated) {
                    await manager.shutdownAll()
                    for wire in wires { await wire.shutdown() }
                    finished.signal()
                }
                _ = finished.wait(timeout: .now() + 10)
                bridge.shutdown()
                stub.uninstall()
            }

            /// `sshdrive add`, with a terminal attached. `verbose` is `sshdrive add -v`:
            /// without it the agent relays warnings and prompts and none of the narration.
            @discardableResult
            func add(
                _ destination: String, _ terminal: ScriptedTerminal,
                nickname: String? = nil, remotePath: String? = nil,
                jump: String? = nil, sshOptions: [String] = [], verbose: Bool = false
            ) async throws -> [String: Any] {
                var arguments = ["destination": destination]
                if let nickname { arguments["nickname"] = nickname }
                if let remotePath { arguments["remotePath"] = remotePath }
                if let jump { arguments["jump"] = jump }
                if verbose { arguments["verbose"] = "true" }
                if !sshOptions.isEmpty {
                    arguments["sshOptions"] = sshOptions.joined(separator: "\u{1}")
                }
                return try await harness.control("add", arguments, relay: terminal)
            }

            var locations: [Location] {
                get async throws { try await harness.manager.configuration().locations }
            }

            /// Nothing of this location exists: no `config.json` entry, no domain, no
            /// domain directory. "`add` must fail cleanly … without leaving a half-added
            /// location" (docs/design/secrets.md, docs/design/cli.md).
            func expectNothingHalfAdded(
                _ scenario: String, sourceLocation: SourceLocation = #_sourceLocation
            ) async throws {
                let locations = try await self.locations
                #expect(
                    locations.isEmpty, "\(scenario): config.json has no location",
                    sourceLocation: sourceLocation)
                let domains = try await harness.replica.domains()
                #expect(
                    domains.isEmpty, "\(scenario): no domain",
                    sourceLocation: sourceLocation)
                let domainRoot = harness.container.appendingPathComponent("domains")
                let left = (try? FileManager.default.contentsOfDirectory(atPath: domainRoot.path))
                    ?? []
                #expect(
                    left.isEmpty, "\(scenario): no domain directory left behind",
                    sourceLocation: sourceLocation)
            }

            /// The master command lines the stub was actually run with, in order. `-G`
            /// resolutions, `-O` control commands and `-W` hops are not masters.
            var masterInvocations: [[String]] {
                stub.invocations.filter {
                    $0.contains("-N") && !$0.contains("-G") && !$0.contains("-W")
                }
            }
        }

        /// A password-authenticating `deb`, on the port the testbed publishes it on.
        static func passwordProfile(_ password: String = "spike-password") -> ServerProfile {
            ServerProfile.debian.with(auth: .password(password))
        }



        // MARK: - Q1

        /// **Q1** - key auth, and not one prompt.
        ///
        /// The plainest `add` there is, and the one the whole askpass path has to stay out
        /// of the way of: a server that accepts a key (`SQ-061`'s family - a key, or
        /// Tailscale's `none` method, is the same "no prompt at all" from `ssh`'s side)
        /// needs no askpass invocation, stores no secret, and creates and mounts the
        /// location. If anything here prompts, the promise (docs/design/secrets.md) that "a location that
        /// passes `add` works from the agent" is being bought with a secret the user typed
        /// and nobody needed.
        @Test func q1KeyAuthPromptsForNothingAndMounts() async throws {
            let bed = try await Bed(profile: .debian) { server in
                server.put("notes.txt", contents: Data("hello".utf8))
                server.putDirectory("Work")
            }
            defer { bed.tearDown() }
            let terminal = ScriptedTerminal()

            let report = try await bed.add("alec@nas:2201", terminal, nickname: "nas")

            #expect(bed.bridge.records.isEmpty, "Q1: askpass was never invoked")
            #expect(terminal.prompts.isEmpty, "Q1: nothing was put to the terminal")
            #expect(try bed.store.keys().isEmpty, "Q1: no secret is stored")
            #expect(bed.stub.askpassPrompts.isEmpty, "Q1: ssh raised no prompt of any kind")

            let locations = try await bed.locations
            #expect(locations.count == 1)
            #expect(locations.first?.displayName == "nas")
            #expect(locations.first?.agentDependent == false, "Q1: the first pass carried it")
            #expect(locations.first?.secrets.isEmpty == true)
            #expect(report["entries"] as? Int == 2, "Q1: the mount listed the real wire")

            let domains = try await bed.harness.replica.domains()
            #expect(domains.count == 1, "Q1: the domain was added")
            #expect(domains.first?.identifier == locations.first?.id)
        }
    }
}

// MARK: - Q2 .. Q9

extension AgentScenarios.AddFlowScenarios {

    /// **Q2** (`SQ-060`, `SQ-047`) - a password relayed, stored, and never asked for twice.
    ///
    /// Three separate rules, and they only mean anything together:
    ///
    /// - the prompt is `<user>@<host>'s password: ` **with its trailing space**
    ///   (`SQ-060`), and it reaches the terminal because the keychain had no answer;
    /// - what is stored is keyed `password:<user>@<hostname>:<port>` off the `ssh -G`
    ///   resolution of the asking `ssh` - never the alias the user typed, and never
    ///   anything parsed out of the prompt text, which here deliberately names a
    ///   `HostKeyAlias` instead (docs/design/secrets.md);
    /// - a **second location on the same host prompts for nothing**, because that item is
    ///   what the broker finds. That is the whole point of keying by destination rather
    ///   than by location, and it is what makes it work against real password-authenticating hosts.
    ///
    /// The bite-proof is the last two together: the two keys a wrong implementation would
    /// have written are asserted absent, and the second `add` proves the key that *was*
    /// written is the one the broker looks up.
    @Test func q2APasswordIsRelayedStoredOnTheResolvedHostAndAskedForOnce() async throws {
        let bed = try await Bed(profile: Self.passwordProfile()) { server in
            server.put("notes.txt", contents: Data("hello".utf8))
        }
        defer { bed.tearDown() }
        // The alias the user types, the hostname `ssh -G` resolves it to, and the name the
        // prompt says - three different strings, exactly as a `HostKeyAlias` in the user's
        // config produces.
        try bed.stub.setResolvedHostname("nas.example.internal", forAlias: "nas")

        let first = ScriptedTerminal([.init(match: "password", answer: "spike-password")])
        _ = try await bed.add(
            "alec@nas:2201", first, nickname: "nas",
            sshOptions: ["HostKeyAlias=nas-alias"])

        // SQ-060: the captured OpenSSH 10.2 string, trailing space included.
        #expect(first.prompts.count == 1)
        let shown = try #require(first.prompts.first)
        #expect(shown.kind == "password")
        #expect(shown.prompt == OpenSSHPrompts.password(user: "alec", host: "nas-alias"))
        #expect(shown.secret, "a password is read hidden")
        #expect(first.unscripted.isEmpty)

        // The keying rule (docs/design/secrets.md), off the `ssh -G` resolution.
        let expected = SecretKey.password(
            SSHDestination(user: "alec", hostname: "nas.example.internal", port: 2201))
        #expect(try bed.store.accounts() == [expected.account])
        #expect(try bed.store.secret(for: expected) == "spike-password")
        let stored = try await bed.locations.first?.secrets
        #expect(stored == [expected.account], "the location records the item it wrote")

        // The bite-proof. Both of these are keys a previous implementation could plausibly
        // have written, and both are wrong: `nas` is the alias the user typed, and
        // `nas-alias` is what the prompt text says. Neither is in the store.
        #expect(
            try bed.store.secret(
                for: .password(SSHDestination(user: "alec", hostname: "nas", port: 2201))) == nil,
            "Q2: keying on the alias would file it under `nas`")
        let fromPromptText = AskpassPromptClassifier.classify(
            prompt: shown.prompt, promptKind: "")
        guard case let .password(promptUser, promptHost) = fromPromptText else {
            Issue.record("Q2: the prompt classifies as a password prompt")
            return
        }
        #expect(promptHost == "nas-alias", "the prompt text names the HostKeyAlias")
        #expect(
            try bed.store.secret(
                for: .password(
                    SSHDestination(user: promptUser, hostname: promptHost, port: 2201))) == nil,
            "Q2: parsing the host out of the prompt text would file it under the alias")

        // And the rule those two exist for: a second location on the same host asks for
        // nothing at all.
        let second = ScriptedTerminal()
        _ = try await bed.add("alec@nas:2201", second, nickname: "nas-docs",
                              sshOptions: ["HostKeyAlias=nas-alias"])
        #expect(second.prompts.isEmpty, "Q2: the second location prompts for nothing")
        #expect(second.unscripted.isEmpty)
        #expect(bed.stub.askpassPrompts.count == 2, "ssh still asked; the agent answered")
        #expect(try bed.store.accounts() == [expected.account], "and stored nothing new")
        #expect(try await bed.locations.count == 2)
    }

    /// **Q3** (`SQ-063`, `SQ-060`) - a `ProxyJump` chain is keyed **per hop**.
    ///
    /// "Keying passwords by `<user>@<hostname>:<port>` rather than by location is what
    /// makes `ProxyJump` work with password auth on both hops: each hop's prompt names its
    /// own host and gets its own item" (docs/design/secrets.md). The agent never sees a hop start:
    /// the hops inherit the master's token through the environment and are told apart by
    /// the argv the askpass sends, which is resolved with its own `ssh -G`.
    ///
    /// The **port** is what makes this a real test rather than a coincidence. `ssh` puts
    /// no port in any prompt, so a hop's `password:…:2301` can only have come from the
    /// `-p` on that hop's own command line (docs/design/secrets.md, docs/design/ssh.md). Both hops carry a
    /// deliberately different password, exactly as `bastion-a` and `bastion-b` each need
    /// their own item.
    @Test func q3EachProxyJumpHopIsKeyedFromItsOwnArgv() async throws {
        let bed = try await Bed(profile: Self.passwordProfile("destination-password")) {
            $0.put("notes.txt")
        }
        defer { bed.tearDown() }
        try bed.stub.setPassword("hop-a-password", forHost: "bastion-a")
        try bed.stub.setPassword("hop-b-password", forHost: "bastion-b")

        // One hop first.
        let single = ScriptedTerminal([
            .init(match: "alec@bastion-a's password: ", answer: "hop-a-password"),
            .init(match: "alec@nas's password: ", answer: "destination-password"),
        ])
        _ = try await bed.add(
            "alec@nas:2201", single, nickname: "one-hop", jump: "alec@bastion-a:2301")
        #expect(single.unscripted.isEmpty, "Q3: every prompt was one we expected")
        #expect(
            single.prompts.map(\.prompt) == [
                OpenSSHPrompts.password(user: "alec", host: "bastion-a"),
                OpenSSHPrompts.password(user: "alec", host: "nas"),
            ],
            "Q3: the hop is asked first, then the destination")

        let hopA = SecretKey.password(
            SSHDestination(user: "alec", hostname: "bastion-a", port: 2301))
        let destination = SecretKey.password(
            SSHDestination(user: "alec", hostname: "nas", port: 2201))
        #expect(try bed.store.secret(for: hopA) == "hop-a-password")
        #expect(try bed.store.secret(for: destination) == "destination-password")

        // Now two, with a third password. The destination's item is already stored, so
        // only the new hop prompts - which is the per-hop keying saying so out loud.
        let chain = ScriptedTerminal([
            .init(match: "alec@bastion-b's password: ", answer: "hop-b-password"),
        ])
        _ = try await bed.add(
            "alec@nas:2201", chain, nickname: "two-hop",
            jump: "alec@bastion-a:2301,alec@bastion-b:2302")
        #expect(chain.unscripted.isEmpty)
        #expect(
            chain.prompts.map(\.prompt)
                == [OpenSSHPrompts.password(user: "alec", host: "bastion-b")],
            "Q3: hop a and the destination were answered from their own stored items")

        let hopB = SecretKey.password(
            SSHDestination(user: "alec", hostname: "bastion-b", port: 2302))
        #expect(try bed.store.secret(for: hopB) == "hop-b-password")
        #expect(
            Set(try bed.store.accounts())
                == [hopA.account, hopB.account, destination.account],
            "Q3: three hosts, three items, and no item keyed on the location")

        // SQ-063: told apart by the argv, never by the prompt text. Each hop's request
        // carried its own command line, `-p` included, and that is where the port in the
        // key came from - the prompt text has no port in it at all.
        let hopRequests = bed.bridge.records.filter {
            $0.parentArguments.contains("-W")
        }
        #expect(hopRequests.count == 3, "Q3: one hop prompt in the first add, two in the second")
        for request in hopRequests {
            let host = try #require(request.parentArguments.last)
            let port = request.parentArguments.firstIndex(of: "-p")
                .map { request.parentArguments[$0 + 1] }
            #expect(
                port == (host == "bastion-a" ? "2301" : "2302"),
                "Q3: the hop's own `-p` is on the hop's own argv")
            #expect(!request.promptText.contains(port ?? "?"),
                    "Q3: and nowhere in the prompt text")
        }
    }

    /// **Q4** (`SQ-062`, `SQ-060`) - keyboard-interactive, under the same key.
    ///
    /// `ssh` presents a keyboard-interactive password as `(<user>@<host>) Password: `, and
    /// nothing is parsed out of it: the item is keyed by the destination of the asking
    /// `ssh`, so a `deb-kbdint` account and a plain-password account on the same host
    /// share one item. A classifier that treated the two prompt shapes as two kinds of
    /// secret would store a second copy under a key nothing else ever looks up.
    @Test func q4KeyboardInteractiveSharesThePlainPasswordKey() async throws {
        let bed = try await Bed(
            profile: ServerProfile.debianKbdInt.with(
                auth: .keyboardInteractive("spike-password"), port: 2204)
        ) { $0.put("notes.txt") }
        defer { bed.tearDown() }

        let terminal = ScriptedTerminal([.init(match: "Password: ", answer: "spike-password")])
        _ = try await bed.add("kbd@kbdint:2204", terminal, nickname: "kbdint")

        #expect(
            terminal.prompts.map(\.prompt)
                == [OpenSSHPrompts.keyboardInteractive(user: "kbd", host: "kbdint")],
            "SQ-062: `(<user>@<host>) Password: `")
        #expect(terminal.prompts.first?.kind == "password",
                "the CLI shows it as a password, not as a challenge")

        let key = SecretKey.password(
            SSHDestination(user: "kbd", hostname: "kbdint", port: 2204))
        #expect(try bed.store.accounts() == [key.account],
                "SQ-062: the same `password:` key a plain password would have used")
        #expect(try bed.store.secret(for: key) == "spike-password")

        // And the shape really was the keyboard-interactive one, not a plain password
        // prompt that happens to read the same.
        let record = try #require(bed.bridge.records.first)
        #expect(
            AskpassPromptClassifier.classify(prompt: record.promptText, promptKind: record.hint)
                == .keyboardInteractivePassword(
                    promptUser: "kbd", promptHost: "kbdint", question: "Password: "))
    }

    /// **Q5** (`SQ-047`, `SQ-049`, `SQ-060`) - the host key answered no, then yes.
    ///
    /// The question arrives with `SSH_ASKPASS_PROMPT` **unset**, indistinguishable by hint
    /// from a password prompt, so its own text is what classifies it. Answered anything but
    /// `yes` the location is not created *at all*: no `config.json` entry, no domain, no
    /// domain directory. Answered `yes`, `ssh` writes it to the user's own `known_hosts`
    /// and `add` carries on.
    ///
    /// The bite-proof guards against classifying by the hint alone: read only by its hint
    /// (which arrives unset, indistinguishable from a password prompt's own unset hint), this
    /// prompt is a secret, and the broker answers a secret prompt for this destination with
    /// the stored password. So the two calls are made side by side - the same broker, the
    /// same token, the same empty hint - and only the text tells them apart.
    @Test func q5TheHostKeyQuestionIsClassifiedByItsTextAndRefusingItAddsNothing() async throws {
        let declined = try await Bed(profile: Self.passwordProfile(), hostKeyKnown: false) {
            $0.put("notes.txt")
        }
        defer { declined.tearDown() }
        // A password for this very destination is already in the keychain, which is what
        // makes the misclassification dangerous rather than merely wrong.
        let key = SecretKey.password(SSHDestination(user: "alec", hostname: "nas", port: 2201))
        try declined.store.setSecret("spike-password", for: key)

        let no = ScriptedTerminal([.init(match: "continue connecting", answer: "no")])
        await #expect(throws: (any Error).self) {
            _ = try await declined.add("alec@nas:2201", no, nickname: "nas")
        }

        let question = try #require(no.prompts.first)
        #expect(question.kind == "hostkey")
        #expect(!question.secret, "docs/design/secrets.md: read visible, against the fingerprint shown")
        #expect(
            question.prompt.hasSuffix(
                "Are you sure you want to continue connecting (yes/no/[fingerprint])? "),
            "SQ-060: the exact wording, trailing space included")
        #expect(question.prompt.hasPrefix("The authenticity of host 'nas' can't be established."))

        let record = try #require(declined.bridge.records.first)
        #expect(record.hint == "", "SQ-047: SSH_ASKPASS_PROMPT is unset for it")
        #expect(
            AskpassPromptClassifier.classify(prompt: record.promptText, promptKind: record.hint)
                == .confirmation(question: record.promptText, isHostKey: true),
            "the text is what classifies it, never the hint")
        // The stored password was never handed to the question.
        #expect(record.reply == .answer("no"))
        for other in declined.bridge.records {
            #expect(other.reply != .answer("spike-password"),
                    "Q5: a stored password is never answered to the host-key question")
        }
        try await declined.expectNothingHalfAdded("Q5")

        // The bite-proof, run against the live broker: the *same* token, the *same* empty
        // hint, and the only difference is the text.
        let broker = declined.secrets.broker
        let harness = AskpassHarness(
            broker: broker, purpose: .collect,
            resolution: SSHResolution(destination: SSHDestination(
                user: "alec", hostname: "nas", port: 2201)))
        #expect(
            harness.prompt(OpenSSHPrompts.password(user: "alec", host: "nas"), kind: "")
                == .answer("spike-password"),
            "a secret prompt with no hint is answered from the keychain - as it must be")
        let asHostKey = harness.prompt(OpenSSHPrompts.hostKey(host: "nas"), kind: "")
        #expect(
            asHostKey != .answer("spike-password"),
            "Q5: classifying on the hint would answer that password to `Are you sure …`")
        guard case .refuse = asHostKey else {
            Issue.record("Q5: outside a relayed `add` the question is refused")
            return
        }
        broker.forget(token: harness.token)

        // And answered `yes`, the same server adds cleanly.
        let accepted = try await Bed(profile: Self.passwordProfile(), hostKeyKnown: false) {
            $0.put("notes.txt")
        }
        defer { accepted.tearDown() }
        let yes = ScriptedTerminal([
            .init(match: "continue connecting", answer: "yes"),
            .init(match: "password", answer: "spike-password"),
        ])
        _ = try await accepted.add("alec@nas:2201", yes, nickname: "nas")
        #expect(yes.unscripted.isEmpty)
        #expect(try await accepted.locations.count == 1, "Q5: `yes` adds the location")
        #expect(try await accepted.harness.replica.domains().count == 1)
    }

    /// **Q6** (`SQ-052`, `SQ-053`) - a wrong password stores nothing, and adds nothing.
    ///
    /// "When the connection succeeds, every answer that was actually used is written to
    /// the keychain; **a wrong password is never stored**" (docs/design/secrets.md). The commit is on
    /// the success path and nowhere else, so an attempt that ends in `Permission denied`
    /// leaves the keychain exactly as it found it - and `add` leaves no half-added
    /// location either, because the location is created only after authentication.
    ///
    /// `SQ-052`: what `ssh` prints is the same bare sentence for a wrong password, a
    /// missing key agent, a dead one and a locked one, so the outcome cannot be read off
    /// the wording; it is read off the exit.
    @Test func q6AWrongPasswordStoresNothingAndAddsNothing() async throws {
        let bed = try await Bed(profile: Self.passwordProfile()) { $0.put("notes.txt") }
        defer { bed.tearDown() }

        // Twice, because a failed first pass earns the key-agent pass of docs/design/secrets.md and
        // that one asks again.
        let terminal = ScriptedTerminal([
            .init(match: "password", answer: "not-the-password", uses: 2)
        ])
        var message = ""
        do {
            _ = try await bed.add("alec@nas:2201", terminal, nickname: "nas")
            Issue.record("Q6: a wrong password must not add a location")
        } catch {
            message = error.localizedDescription
        }

        #expect(message.contains("Could not authenticate"))
        #expect(message.contains("Permission denied"), "SQ-052: ssh's own sentence is shown")
        #expect(try bed.store.accounts().isEmpty, "Q6: the secrets store is empty")
        #expect(try bed.store.keys().isEmpty)
        try await bed.expectNothingHalfAdded("Q6")
        #expect(terminal.prompts.count == 2, "the two passes each asked once")
    }

    /// **Q7** - a bad remote path rolls back.
    ///
    /// This is the one failure that happens *after* authentication, so it is the only one
    /// with something to roll back: the location is in `config.json`, its domain
    /// directory exists, and its domain has been asked for. "`add` must fail cleanly …
    /// without leaving a half-added location" - so the runtime is dropped, the domain
    /// removed, the entry deleted and the directory taken with it.
    ///
    /// The wire carries status classes and no errno (`SQ-028`), so the one useful thing
    /// `add` can say about a `NO_SUCH_FILE` here is **which path**: at this point
    /// authentication has already succeeded, and a missing root is a typo and nothing else.
    @Test func q7ABadRemotePathRollsBackAndNamesThePath() async throws {
        let bed = try await Bed(profile: .debian, remoteRoot: "/srv/typo") {
            $0.put("notes.txt")
        }
        defer { bed.tearDown() }
        let terminal = ScriptedTerminal()

        var message = ""
        do {
            _ = try await bed.add(
                "alec@nas:2201", terminal, nickname: "nas", remotePath: "/srv/typo",
                verbose: true)
            Issue.record("Q7: a root the server does not have must not add a location")
        } catch {
            message = error.localizedDescription
        }

        #expect(message.contains("/srv/typo"), "Q7: the message names the path")
        #expect(message.contains("Nothing was added."))
        // Authentication had already succeeded when this failed, which is what makes it a
        // rollback rather than a refusal.
        #expect(
            terminal.notes.contains("Connecting for real, from the stored answers."),
            "Q7: the collect connection authenticated first")
        try await bed.expectNothingHalfAdded("Q7")
    }

    /// **Q8** (`SQ-047`, `SQ-048`, `SQ-060`, `SQ-062`) - the token's life, and the whole
    /// classification table.
    ///
    /// The token (docs/design/secrets.md) is minted per `ssh`, put in that process's environment, attached
    /// to its pid, used for as long as that process lives, committed on success and then
    /// retired and forgotten - "an askpass invocation with no token, a retired one, or one
    /// whose caller is not a descendant of the `ssh` it was issued to gets no answer". All
    /// four of those are asserted against the broker the `add` actually ran on.
    ///
    /// The classification table (docs/design/secrets.md) covers every row, including the host-key
    /// question with **no** hint (`SQ-047`) - and the two rows no testbed service can
    /// raise, a PIN and a user-presence touch, which are run end to end against a stub that
    /// raises them and refuse the location rather than creating one that fails every
    /// reconnect.
    @Test func q8TheTokenIsMintedUsedCommittedAndRetiredAndEveryPromptClassifies() async throws {
        let bed = try await Bed(profile: Self.passwordProfile()) { $0.put("notes.txt") }
        defer { bed.tearDown() }

        let terminal = ScriptedTerminal([.init(match: "password", answer: "spike-password")])
        _ = try await bed.add("alec@nas:2201", terminal, nickname: "nas")

        let record = try #require(bed.bridge.records.first)
        let session = try #require(record.session)
        #expect(!record.token.isEmpty, "one token, minted for this spawn")
        #expect(session.purpose == .collect, "and marked *collect*, so prompts are relayed")
        let sshPID = try #require(session.sshPID)
        #expect(sshPID > 0, "attached to the pid of the ssh it was issued to")
        #expect(record.callerPID > 0)
        #expect(
            record.callerWasADescendant,
            """
            and the askpass that used it really was a descendant of that ssh - asked             while both were alive, which is the only time it can be asked
            """)

        // Committed on success, then forgotten: the token cannot be replayed.
        let key = SecretKey.password(SSHDestination(user: "alec", hostname: "nas", port: 2201))
        #expect(try bed.store.secret(for: key) == "spike-password")
        let broker = bed.secrets.broker
        #expect(broker.info(token: record.token) == nil, "the session is gone")
        #expect(
            broker.answer(
                token: record.token, promptKind: "",
                prompt: OpenSSHPrompts.password(user: "alec", host: "nas"))
                == .refuse(reason: "unknown token"),
            "Q8: a forgotten token gets no answer, stored item or not")

        // A live token whose caller is not a descendant of its `ssh` is refused too.
        let stranger = broker.mint(
            locationID: "q8", purpose: .collect,
            resolution: SSHResolution(destination: SSHDestination(
                user: "alec", hostname: "nas", port: 2201)),
            argv: ["/usr/bin/ssh", "nas"])
        broker.attach(pid: 1, to: stranger)
        let reply = broker.answer(
            token: stranger, promptKind: "",
            prompt: OpenSSHPrompts.password(user: "alec", host: "nas"),
            callerPID: ProcessInfo.processInfo.processIdentifier)
        guard case let .refuse(reason) = reply, reason.contains("descendant") else {
            Issue.record("Q8: a caller outside the ssh's process tree gets no answer")
            return
        }
        broker.forget(token: stranger)

        // The classification table (docs/design/secrets.md), row by row.
        let hostKey = OpenSSHPrompts.hostKey(host: "nas")
        #expect(
            AskpassPromptClassifier.classify(
                prompt: OpenSSHPrompts.passphrase(keyPath: "/home/alec/.ssh/id_ed25519"),
                promptKind: "")
                == .passphrase(keyPathPrefix: "/home/alec/.ssh/id_ed25519"))
        #expect(
            AskpassPromptClassifier.classify(
                prompt: OpenSSHPrompts.password(user: "alec", host: "nas"), promptKind: "")
                == .password(promptUser: "alec", promptHost: "nas"))
        #expect(
            AskpassPromptClassifier.classify(
                prompt: OpenSSHPrompts.keyboardInteractive(user: "alec", host: "nas"),
                promptKind: "")
                == .keyboardInteractivePassword(
                    promptUser: "alec", promptHost: "nas", question: "Password: "))
        #expect(
            AskpassPromptClassifier.classify(prompt: hostKey, promptKind: "")
                == .confirmation(question: hostKey, isHostKey: true),
            "SQ-047: no hint, and the text decides")
        #expect(
            AskpassPromptClassifier.classify(prompt: hostKey, promptKind: "confirm")
                == .confirmation(question: hostKey, isHostKey: true),
            "and the hint only corroborates")
        #expect(
            AskpassPromptClassifier.classify(
                prompt: "Confirm user presence for key ED25519-SK SHA256:abc", promptKind: "none")
                == .userPresence(keyDescription: "ED25519-SK SHA256:abc"))
        #expect(
            AskpassPromptClassifier.classify(prompt: "Enter PIN for ED25519-SK key: ", promptKind: "")
                == .pin(text: "Enter PIN for ED25519-SK key: "))
        #expect(
            AskpassPromptClassifier.classify(
                prompt: "(alec@nas) Enter your one-time code: ", promptKind: "")
                == .keyboardInteractiveChallenge(question: "Enter your one-time code: "))
        #expect(
            AskpassPromptClassifier.classify(prompt: "Something new: ", promptKind: "")
                == .unrecognised(text: "Something new: "))
        // SQ-048: the passphrase prompt truncates at 100 bytes, so its text alone can
        // never be the key; the prefix is mapped onto the asking ssh's identityfile list.
        let long = "/home/alec/.ssh/" + String(repeating: "d", count: 120) + "/id_ed25519"
        let truncated = OpenSSHPrompts.passphrase(keyPath: long)
        #expect(
            AskpassPromptClassifier.classify(prompt: truncated, promptKind: "")
                == .passphrase(keyPathPrefix: String(long.prefix(100))),
            "SQ-048: what arrives is a prefix, not the path")

        // A PIN is never relayed and refuses the location: it needs a human on every
        // connection, and one that mounted once would fail into `.notAuthenticated` on the
        // first unattended reconnect.
        let pinned = try await Bed(
            profile: Self.passwordProfile(),
            extraPrompt: "Enter PIN for ED25519-SK key SHA256:abc: ")
        defer { pinned.tearDown() }
        let pinTerminal = ScriptedTerminal([
            .init(match: "PIN", answer: "1234"), .init(match: "password", answer: "spike-password"),
        ])
        var message = ""
        do {
            _ = try await pinned.add("alec@nas:2201", pinTerminal, nickname: "nas")
            Issue.record("Q8: a PIN prompt must refuse the location")
        } catch {
            message = error.localizedDescription
        }
        #expect(
            pinTerminal.prompts.isEmpty,
            "Q8: a PIN is never relayed - answering it once buys nothing")
        #expect(message.contains("would need a human on every connection"))
        #expect(try pinned.store.accounts().isEmpty)
        try await pinned.expectNothingHalfAdded("Q8 (PIN)")

        // And a user-presence notice refuses the location even though the connection
        // itself authenticated: `add` cannot detect a touch that comes from a key agent's
        // own UI, but it can detect this one, and refusing up front is kinder.
        let touched = try await Bed(
            profile: .debian, extraPrompt: "Confirm user presence for key ED25519-SK SHA256:abc",
            extraPromptHint: "none")
        defer { touched.tearDown() }
        let touchTerminal = ScriptedTerminal()
        var touchMessage = ""
        do {
            _ = try await touched.add("alec@nas:2201", touchTerminal, nickname: "nas")
            Issue.record("Q8: a touch-required key must refuse the location")
        } catch {
            touchMessage = error.localizedDescription
        }
        #expect(touchMessage.contains("asked for a touch"))
        #expect(touchMessage.contains("ED25519-SK SHA256:abc"), "the refusal names the key")
        try await touched.expectNothingHalfAdded("Q8 (touch)")
    }

    /// **Q9** (`SQ-064`) and **K10**'s agent-side half - the two-pass collect connection.
    ///
    /// "The collect connection is made twice at most. The first attempt runs with
    /// `-o IdentityAgent=none`, so `ssh` can use only key files, passphrases … and
    /// passwords, and every passphrase it needs is seen and stored… If that attempt fails
    /// to authenticate, the second runs with the agent socket" (docs/design/secrets.md). The order is
    /// asserted against the argv `FakeSSH` recorded, because that is the only place it is
    /// visible: a location that passed on the second attempt is `agentDependent` and keeps
    /// the config's `IdentityAgent` for ever.
    ///
    /// `SQ-064` is the row that makes the interesting branch reachable: a server that
    /// accepts **both** a key and a password. Without it the first pass would simply fail,
    /// and the user would never be offered the choice; with it the first pass reaches a
    /// password prompt, the CLI says so, and an empty answer is a refusal of that prompt
    /// (`SQ-053`) which fails the attempt over rather than quietly authenticating by
    /// password.
    ///
    /// **K10**: the collect connection runs to 300 s because somebody is at the keyboard;
    /// the master `add` brings up afterwards carries the ordinary 60 s, because that is the
    /// connection that has to work unattended.
    @Test func q9TheCollectConnectionRunsIdentityAgentNoneFirstAndAtThreeHundredSeconds()
        async throws
    {
        let bed = try await Bed(
            profile: ServerProfile.debian.with(auth: .keyOrPassword("spike-password")),
            agentOnlyKey: true
        ) { $0.put("notes.txt") }
        defer { bed.tearDown() }

        // An empty answer is the deliberate refusal of docs/design/secrets.md: "press Enter to skip
        // this and try your key agent instead".
        let terminal = ScriptedTerminal([.init(match: "password", answer: "")])
        let report = try await bed.add("alec@nas:2201", terminal, nickname: "nas")

        #expect(report["agentDependent"] as? Bool == true,
                "Q9: only the key-agent pass authenticated")
        #expect(try await bed.locations.first?.agentDependent == true)
        #expect(try bed.store.accounts().isEmpty,
                "SQ-053: an empty answer is a refusal; nothing is stored")
        #expect(
            terminal.prompts.first?.detail.contains(
                "press Enter to skip this and try your key agent instead") == true,
            "Q9: the CLI says why, or the user types a password and gets a password location")
        #expect(
            terminal.notes.contains {
                $0.contains("trying your key agent")
            },
            "Q9: and `add` narrates the fail-over as it happens")

        // The order, off the argv the stub actually ran.
        let masters = bed.masterInvocations
        #expect(masters.count == 2, "Q9: two collect connections, and no more")
        #expect(
            masters[0].contains("IdentityAgent=none"),
            "Q9: pass 1 forbids the key agent, so every passphrase is seen and stored")
        #expect(
            !masters[1].contains("IdentityAgent=none"),
            "Q9: pass 2 is the only one that may consult it")
        #expect(
            masters.allSatisfy { $0.contains("StrictHostKeyChecking=ask") },
            "docs/design/secrets.md: the collect connection runs `ask` so the question can be relayed")

        // K10: 300 s while a human is typing, and 60 s for the master that follows.
        let session = try #require(bed.bridge.records.first?.session)
        #expect(
            session.expiresAt.timeIntervalSince(session.mintedAt) == 300,
            "K10: the collect connection's token lives 300 s")
        #expect(bed.secrets.broker.collectDeadline == 300)
        #expect(bed.secrets.broker.authenticationDeadline == 60)
        let created = try #require(try await bed.locations.first)
        let configuration = try SSHProcess.masterConfiguration(
            for: created, environment: ProcessInfo.processInfo.environment)
        #expect(
            configuration.authenticationDeadline == 60,
            "K10: the master `add` brings up afterwards is the unattended one, at 60 s")
        #expect(configuration.agentDependent, "and it is the location that waits for the agent")
    }
}

// MARK: - The rule of silence

extension AgentScenarios.AddFlowScenarios {

    /// `sshdrive add` prints nothing about its own progress unless `-v` asked for it.
    ///
    /// The narration is written in the agent and relayed to the terminal, so the agent is
    /// the only place that can hold it back; the CLI's `-v` reaches it as the `verbose`
    /// argument. What the flag does **not** touch is anything the user has to read: the
    /// prompts of docs/design/secrets.md, and the notes `AddFlow` makes when an attempt fails and
    /// another is tried, which `q9` asserts arrive with no flag at all.
    @Test func addNarratesOnlyUnderVerbose() async throws {
        let bed = try await Bed(profile: .debian) { server in
            server.put("notes.txt", contents: Data("hello".utf8))
        }
        defer { bed.tearDown() }

        let quiet = ScriptedTerminal()
        _ = try await bed.add("alec@nas:2201", quiet, nickname: "nas")
        for narration in ["resolves to:", "Connecting once to check", "Connecting for real"] {
            #expect(
                !quiet.notes.contains { $0.contains(narration) },
                "a plain `add` says nothing about \"\(narration)\"")
        }

        let loud = ScriptedTerminal()
        _ = try await bed.add("alec@nas:2201", loud, nickname: "nas-again", verbose: true)
        for narration in ["resolves to:", "Connecting once to check", "Connecting for real"] {
            #expect(
                loud.notes.contains { $0.contains(narration) },
                "`add -v` says \"\(narration)\"")
        }
    }
}
