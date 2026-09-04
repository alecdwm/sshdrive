import XCTest

@testable import AgentCore
import Config
import Secrets
import SSHProcess
import XPCProtocols

/// The `sshdrive add` state machine (DESIGN.md sections 4.2, 4.3, 8) and the askpass
/// broker behind it, driven with no `ssh` anywhere.
///
/// The flow's decisions are checked against a stub runner; the answers a collect
/// connection actually gives `ssh` are checked against `AskpassHarness`, which is the same
/// seam the milestone 2 tests use.
final class AddFlowTests: XCTestCase {

    // MARK: the state machine

    /// One scripted attempt per call, in order, so a test reads as the sequence of
    /// connections `add` is expected to make.
    private final class ScriptedRunner: AddFlow.AttemptRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [AddFlow.AttemptResult]
        private(set) var attempts: [AddFlow.Attempt] = []

        init(_ results: [AddFlow.AttemptResult]) { self.results = results }

        func run(_ attempt: AddFlow.Attempt) async -> AddFlow.AttemptResult {
            lock.lock()
            defer { lock.unlock() }
            attempts.append(attempt)
            guard !results.isEmpty else {
                return AddFlow.AttemptResult(authenticated: false, classification: .transient)
            }
            return results.removeFirst()
        }
    }

    func testTheFirstPassRunsWithoutTheKeyAgentAndIsEnoughOnSuccess() async {
        // Section 4.2: "The first attempt runs with `-o IdentityAgent=none` … A location
        // that passes only the second attempt is recorded as `agentDependent`."
        let runner = ScriptedRunner([AddFlow.AttemptResult(authenticated: true)])
        let result = await AddFlow.run(runner: runner)
        XCTAssertTrue(result.authenticated)
        XCTAssertFalse(result.agentDependent)
        XCTAssertEqual(runner.attempts.count, 1)
        XCTAssertTrue(runner.attempts[0].identityAgentNone)
        XCTAssertEqual(runner.attempts[0].hostKeyChecking, "ask")
    }

    func testAnAuthenticationFailureEarnsTheKeyAgentPassAndMarksTheLocationAgentDependent() async {
        let runner = ScriptedRunner([
            AddFlow.AttemptResult(
                authenticated: false, classification: .authenticationFailed,
                stderr: "Permission denied (publickey)."),
            AddFlow.AttemptResult(authenticated: true),
        ])
        let result = await AddFlow.run(runner: runner)
        XCTAssertTrue(result.authenticated)
        XCTAssertTrue(result.agentDependent)
        XCTAssertEqual(runner.attempts.map(\.pass), [1, 2])
        XCTAssertEqual(runner.attempts.map(\.identityAgentNone), [true, false])
        XCTAssertTrue(result.notes.contains { $0.contains("key agent") })
    }

    func testAStaleStoredSecretIsMaskedAndTheSamePassRepeated() async {
        // Section 4.2: "a second location on a host whose password has since changed finds
        // the shared item, `ssh` uses it for its single prompt and is refused. `add` then
        // repeats the collect connection with the stored items for that host masked."
        let account = "password:pw@192.168.64.1:2201"
        let runner = ScriptedRunner([
            AddFlow.AttemptResult(
                authenticated: false, classification: .authenticationFailed,
                accountsAnsweredFromStore: [account]),
            AddFlow.AttemptResult(authenticated: true),
        ])
        let result = await AddFlow.run(runner: runner)
        XCTAssertTrue(result.authenticated)
        XCTAssertFalse(result.agentDependent)
        XCTAssertEqual(runner.attempts.count, 2)
        XCTAssertEqual(runner.attempts[1].pass, 1)
        XCTAssertEqual(runner.attempts[1].maskedAccounts, [account])
        XCTAssertTrue(result.notes.contains { $0.contains(account) })
    }

    func testATouchRequiredKeyRefusesTheLocationEvenWhenTheConnectionSucceeded() async {
        // Section 4.2: "Mounting such a location would succeed once and then fail into
        // `.notAuthenticated` on the first unattended reconnect … refusing up front is
        // kinder."
        let runner = ScriptedRunner([
            AddFlow.AttemptResult(
                authenticated: true,
                touchRequiredKeys: ["ED25519-SK SHA256:abc123"])
        ])
        let result = await AddFlow.run(runner: runner)
        XCTAssertFalse(result.authenticated)
        XCTAssertEqual(runner.attempts.count, 1)
        guard case .needsAHumanEveryTime(_, let keys)? = result.failure else {
            return XCTFail("expected a touch refusal, got \(String(describing: result.failure))")
        }
        XCTAssertEqual(keys, ["ED25519-SK SHA256:abc123"])
    }

    func testADeclinedHostKeyStopsTheFlowWithNoSecondPass() async {
        // Section 4.3: answering anything but yes ends `add`; a key agent would not have
        // changed the answer.
        let runner = ScriptedRunner([
            AddFlow.AttemptResult(
                authenticated: false, classification: .hostKeyFailed,
                stderr: "Host key verification failed.", hostKeyDeclined: true)
        ])
        let result = await AddFlow.run(runner: runner)
        XCTAssertFalse(result.authenticated)
        XCTAssertEqual(result.failure, .hostKeyDeclined)
        XCTAssertEqual(runner.attempts.count, 1)
        XCTAssertTrue(
            result.failure!.message(identityHint: nil).contains("known_hosts"))
    }

    func testAOneTimeCodeIsRefusedAndNothingElseIsTried() async {
        let runner = ScriptedRunner([
            AddFlow.AttemptResult(
                authenticated: false, classification: .authenticationFailed,
                refusalReason: "a prompt that needs a human every time",
                unansweredPrompts: ["Verification code: "])
        ])
        let result = await AddFlow.run(runner: runner)
        XCTAssertFalse(result.authenticated)
        XCTAssertEqual(runner.attempts.count, 1)
        guard case .needsAHumanEveryTime(let prompt, _)? = result.failure else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(prompt, "Verification code: ")
    }

    func testAnUnreachableServerIsNotRetriedWithTheKeyAgent() async {
        // Only an authentication failure earns the second pass; a server that could not be
        // reached will not be reached with a key agent either.
        let runner = ScriptedRunner([
            AddFlow.AttemptResult(
                authenticated: false, classification: .transient,
                stderr: "ssh: connect to host 192.168.64.1 port 2299: Connection refused")
        ])
        let result = await AddFlow.run(runner: runner)
        XCTAssertEqual(runner.attempts.count, 1)
        guard case .transport(let text)? = result.failure else {
            return XCTFail("expected a transport failure")
        }
        XCTAssertTrue(text.contains("Connection refused"))
    }

    func testTrustFirstPassesAcceptNewToEveryAttempt() async {
        let runner = ScriptedRunner([
            AddFlow.AttemptResult(authenticated: false, classification: .authenticationFailed),
            AddFlow.AttemptResult(authenticated: true),
        ])
        _ = await AddFlow.run(hostKeyChecking: "accept-new", runner: runner)
        XCTAssertEqual(runner.attempts.map(\.hostKeyChecking), ["accept-new", "accept-new"])
    }

    func testTheTouchRefusalNamesTheKeyAndTheIdentityThatSkipsIt() {
        // Section 4.2: "`~/.ssh/id_ed25519_sk` needs a touch on every connection; run
        // `sshdrive add --identity ~/.ssh/id_nas nas` …"
        let hint = AddFlow.identityHint(
            touchKeys: ["ED25519-SK SHA256:XYZ"],
            identityFiles: ["/Users/alec/.ssh/id_ed25519_sk", "/Users/alec/.ssh/id_nas"],
            fingerprints: [
                "/Users/alec/.ssh/id_ed25519_sk": "SHA256:XYZ",
                "/Users/alec/.ssh/id_nas": "SHA256:OTHER",
            ],
            destination: "nas")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("id_ed25519_sk needs a touch"))
        XCTAssertTrue(hint!.contains("--identity /Users/alec/.ssh/id_nas nas"))
    }

    // MARK: the broker, through the askpass harness

    /// An in-memory store, so nothing here needs the keychain entitlement.
    private final class MemoryStore: SecretsStore, @unchecked Sendable {
        private let lock = NSLock()
        var items: [String: String] = [:]
        func secret(forKey key: String) throws -> String? {
            lock.lock(); defer { lock.unlock() }
            return items[key]
        }
        func setSecret(_ value: String, forKey key: String) throws {
            lock.lock(); defer { lock.unlock() }
            items[key] = value
        }
        func removeSecret(forKey key: String) throws {
            lock.lock(); defer { lock.unlock() }
            items.removeValue(forKey: key)
        }
        func accounts() throws -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(items.keys)
        }
    }

    private func broker(_ store: MemoryStore, destination: SSHDestination)
        -> (AskpassBroker, AskpassHarness)
    {
        let broker = AskpassBroker(
            store: store,
            resolver: StaticSSHResolver(
                fallback: SSHResolution(
                    destination: destination,
                    identityFiles: ["/Users/alec/.ssh/sshdrive-spike-enc"])),
            ancestry: AlwaysDescendant())
        let harness = AskpassHarness(
            broker: broker, locationID: "L", purpose: .collect,
            resolution: SSHResolution(
                destination: destination,
                identityFiles: ["/Users/alec/.ssh/sshdrive-spike-enc"]))
        return (broker, harness)
    }

    /// Every caller is its own parent, so the descendant check always passes: the
    /// harness has no real process tree.
    private final class AlwaysDescendant: ProcessAncestryChecking, @unchecked Sendable {
        func parent(of pid: Int32) -> Int32? { pid }
    }

    func testACollectConnectionRelaysAPasswordPromptAndStoresWhatWasTyped() throws {
        let destination = SSHDestination(user: "pw", hostname: "192.168.64.1", port: 2201)
        let store = MemoryStore()
        let (broker, harness) = broker(store, destination: destination)

        var asked: [String] = []
        broker.collectResponder = { request in
            asked.append(request.promptText)
            return "spike-password"
        }
        let reply = harness.prompt("pw@192.168.64.1's password: ")
        XCTAssertEqual(reply, .answer("spike-password"))
        XCTAssertEqual(asked.count, 1)
        // Nothing is stored until the connection has authenticated (section 4.2).
        XCTAssertTrue(store.items.isEmpty)

        let written = try broker.commit(token: harness.token)
        XCTAssertEqual(written.map(\.account), ["password:pw@192.168.64.1:2201"])
        XCTAssertEqual(store.items["password:pw@192.168.64.1:2201"], "spike-password")
    }

    func testASecondAddOnTheSameHostAnswersFromTheKeychainWithNoPrompt() {
        // The point of keying by `user@hostname:port` rather than by location: "two
        // locations on one host share one" item (sections 4, 4.2, 8).
        let destination = SSHDestination(user: "pw", hostname: "192.168.64.1", port: 2201)
        let store = MemoryStore()
        store.items["password:pw@192.168.64.1:2201"] = "spike-password"
        let (broker, harness) = broker(store, destination: destination)

        var relayed = 0
        broker.collectResponder = { _ in relayed += 1; return "typed-again" }
        XCTAssertEqual(
            harness.prompt("pw@192.168.64.1's password: "), .answer("spike-password"))
        XCTAssertEqual(relayed, 0)
        XCTAssertTrue(harness.misses.isEmpty)
    }

    func testAStaleItemIsMaskedSoThePromptReachesTheTerminal() {
        // The masked-account retry the state machine schedules, as the broker sees it.
        let destination = SSHDestination(user: "pw", hostname: "192.168.64.1", port: 2201)
        let store = MemoryStore()
        store.items["password:pw@192.168.64.1:2201"] = "the-old-password"
        let broker = AskpassBroker(
            store: store,
            resolver: StaticSSHResolver(fallback: SSHResolution(destination: destination)),
            ancestry: AlwaysDescendant())
        let token = broker.mint(
            locationID: "L", purpose: .collect,
            resolution: SSHResolution(destination: destination),
            maskedAccounts: ["password:pw@192.168.64.1:2201"])
        broker.collectResponder = { _ in "the-new-password" }
        let reply = broker.answer(
            token: token, promptKind: "", prompt: "pw@192.168.64.1's password: ")
        XCTAssertEqual(reply, .answer("the-new-password"))
        XCTAssertEqual(
            try? broker.commit(token: token).map(\.account),
            ["password:pw@192.168.64.1:2201"])
        XCTAssertEqual(store.items["password:pw@192.168.64.1:2201"], "the-new-password")
    }

    func testTheHostKeyQuestionIsRelayedDuringAddAndTheAnswerGoesStraightToSsh() {
        // Section 4.3: the question arrives with `SSH_ASKPASS_PROMPT` unset and is
        // recognised by its text; during `add` it is relayed, and `ssh` writes the answer
        // to the user's own `known_hosts`.
        let destination = SSHDestination(user: "alec", hostname: "192.168.64.1", port: 2206)
        let store = MemoryStore()
        let (broker, harness) = broker(store, destination: destination)
        let question = """
            The authenticity of host '[192.168.64.1]:2206 ([192.168.64.1]:2206)' can't be \
            established.
            ED25519 key fingerprint is SHA256:abc.
            Are you sure you want to continue connecting (yes/no/[fingerprint])?
            """
        var wasSecret = true
        broker.collectResponder = { request in
            wasSecret = request.isSecret
            return "yes"
        }
        XCTAssertEqual(harness.prompt(question), .answer("yes"))
        // Read visible, not hidden (section 4.2's collect paragraph).
        XCTAssertFalse(wasSecret)
        // Nothing is stored for a host-key answer: we keep no host-key state of our own.
        XCTAssertEqual(try? broker.commit(token: harness.token).count, 0)
    }

    func testDecliningTheHostKeyAnswersNoAndStoresNothing() {
        let destination = SSHDestination(user: "alec", hostname: "192.168.64.1", port: 2206)
        let store = MemoryStore()
        let (broker, harness) = broker(store, destination: destination)
        broker.collectResponder = { _ in "no" }
        XCTAssertEqual(
            harness.prompt(
                "The authenticity of host 'x' can't be established.\n"
                    + "Are you sure you want to continue connecting (yes/no/[fingerprint])? "),
            .answer("no"))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testOutsideAddTheSameQuestionIsRefused() {
        // "otherwise refused" (section 4.2's table): a master token relays nothing.
        let destination = SSHDestination(user: "alec", hostname: "192.168.64.1", port: 2206)
        let store = MemoryStore()
        let broker = AskpassBroker(
            store: store,
            resolver: StaticSSHResolver(fallback: SSHResolution(destination: destination)),
            ancestry: AlwaysDescendant())
        let harness = AskpassHarness(broker: broker, locationID: "L", purpose: .master)
        broker.collectResponder = { _ in "yes" }
        guard case .refuse = harness.prompt(
            "The authenticity of host 'x' can't be established.\n"
                + "Are you sure you want to continue connecting (yes/no/[fingerprint])? ")
        else { return XCTFail("a master token must never be relayed a host-key question") }
    }

    func testAnEmptyAnswerIsARefusalOfThatPromptAndStoresNothing() {
        // Section 4.2: "An empty answer is a refusal of that prompt: nothing is stored, and
        // the attempt fails over." For a passphrase this is `ssh`'s skip-this-identity.
        let destination = SSHDestination(user: "alec", hostname: "192.168.64.1", port: 2201)
        let store = MemoryStore()
        let (broker, harness) = broker(store, destination: destination)
        broker.collectResponder = { _ in "" }
        XCTAssertEqual(
            harness.prompt("Enter passphrase for key '/Users/alec/.ssh/sshdrive-spike-enc': "),
            .empty)
        XCTAssertEqual(try? broker.commit(token: harness.token).count, 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testAWrongPasswordIsNeverStoredBecauseCommitIsOnlyCalledOnSuccess() {
        // The rule is structural: `commit` is what writes, and the flow only calls it for
        // an attempt that authenticated (section 4.2).
        let destination = SSHDestination(user: "pw", hostname: "192.168.64.1", port: 2201)
        let store = MemoryStore()
        let (broker, harness) = broker(store, destination: destination)
        broker.collectResponder = { _ in "wrong" }
        _ = harness.prompt("pw@192.168.64.1's password: ")
        XCTAssertTrue(store.items.isEmpty, "nothing may be written before the connection succeeds")
        broker.forget(token: harness.token)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testEachHopOfAChainGetsItsOwnKeyedItem() {
        // Section 4.2: "Keying passwords by `<user>@<hostname>:<port>` rather than by
        // location is what makes `ProxyJump` work with password auth on both hops."
        // The testbed's two bastions have deliberately different passwords.
        let store = MemoryStore()
        let hopA = SSHDestination(user: "hop", hostname: "192.168.64.1", port: 2210)
        let hopB = SSHDestination(user: "hop", hostname: "bastion-b", port: 22)
        let resolver = StaticSSHResolver(fallback: SSHResolution(destination: hopA))
        resolver.set(
            SSHResolution(destination: hopB),
            for: ["/usr/bin/ssh", "-W", "%h:%p", "-l", "hop", "bastion-b"])
        let broker = AskpassBroker(store: store, resolver: resolver, ancestry: AlwaysDescendant())
        let token = broker.mint(
            locationID: "L", purpose: .collect,
            resolution: SSHResolution(destination: hopA),
            argv: ["/usr/bin/ssh", "-N", "inner"])

        var answers = ["spike-password-a", "spike-password-b"]
        broker.collectResponder = { _ in answers.removeFirst() }
        // The master's own prompt: its argv matches, so the known resolution is used.
        _ = broker.answer(
            token: token, promptKind: "", prompt: "hop@192.168.64.1's password: ",
            parentArguments: ["/usr/bin/ssh", "-N", "inner"])
        // A hop: a different argv, resolved on its own.
        _ = broker.answer(
            token: token, promptKind: "", prompt: "hop@bastion-b's password: ",
            parentArguments: ["/usr/bin/ssh", "-W", "%h:%p", "-l", "hop", "bastion-b"])

        let written = (try? broker.commit(token: token).map(\.account).sorted()) ?? []
        XCTAssertEqual(
            written, ["password:hop@192.168.64.1:2210", "password:hop@bastion-b:22"])
        XCTAssertEqual(store.items["password:hop@192.168.64.1:2210"], "spike-password-a")
        XCTAssertEqual(store.items["password:hop@bastion-b:22"], "spike-password-b")
    }

    func testACollectTokenOutlivesTheSixtySecondUnattendedDeadline() {
        // A person is at the keyboard for a collect connection; section 4.2's 60 s is
        // about the unattended reconnect the master makes afterwards.
        let broker = AskpassBroker(
            store: MemoryStore(),
            resolver: StaticSSHResolver(),
            ancestry: AlwaysDescendant())
        let master = broker.mint(locationID: "L", purpose: .master)
        let collect = broker.mint(locationID: "L", purpose: .collect)
        let masterExpiry = broker.info(token: master)!.expiresAt
            .timeIntervalSince(broker.info(token: master)!.mintedAt)
        let collectExpiry = broker.info(token: collect)!.expiresAt
            .timeIntervalSince(broker.info(token: collect)!.mintedAt)
        XCTAssertEqual(masterExpiry, 60, accuracy: 1)
        XCTAssertGreaterThan(collectExpiry, masterExpiry)
    }
}
