import XCTest

@testable import Secrets

/// The token lifecycle and the section 4.2 answer table, driven through the same entry
/// point the XPC service uses. No `ssh` is involved: `AskpassHarness` is the seam
/// `SSHProcess` gets too.
final class AskpassBrokerTests: XCTestCase {

    private let nas = SSHDestination(user: "alec", hostname: "nas.example", port: 2222)

    private func makeBroker(
        secrets: [String: String] = [:],
        resolution: SSHResolution? = nil,
        ancestry: ProcessAncestryChecking = StaticProcessAncestry([:]),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> (AskpassBroker, InMemorySecretsStore) {
        let store = InMemorySecretsStore(secrets)
        let broker = AskpassBroker(
            store: store,
            resolver: StaticSSHResolver(fallback: resolution),
            ancestry: ancestry,
            now: clock)
        return (broker, store)
    }

    // MARK: token lifecycle

    func testATokenTheAgentNeverMintedIsRefused() {
        let (broker, _) = makeBroker()
        let reply = broker.answer(
            token: "not-a-token", promptKind: "", prompt: "alec@nas.example's password: ")
        XCTAssertEqual(reply, .refuse(reason: "unknown token"))
    }

    func testEveryTokenIsDistinctAndLongEnough() {
        let (broker, _) = makeBroker()
        var tokens = Set<String>()
        for _ in 0..<64 {
            let token = broker.mint(locationID: "nas", purpose: .master)
            XCTAssertGreaterThanOrEqual(token.count, 40)
            XCTAssertTrue(tokens.insert(token).inserted)
        }
    }

    func testARetiredTokenIsRefused() {
        let (broker, _) = makeBroker(
            secrets: [SecretKey.password(nas).account: "hunter2"],
            resolution: SSHResolution(destination: nas))
        let token = broker.mint(
            locationID: "nas", purpose: .master, resolution: SSHResolution(destination: nas))
        XCTAssertEqual(
            broker.answer(token: token, promptKind: "", prompt: "alec@nas.example's password: "),
            .answer("hunter2"))
        broker.retire(token: token)
        XCTAssertEqual(
            broker.answer(token: token, promptKind: "", prompt: "alec@nas.example's password: "),
            .refuse(reason: "retired token"))
    }

    func testATokenExpiresWithTheAuthenticationDeadline() {
        let clock = MutableClock()
        let (broker, _) = makeBroker(
            secrets: [SecretKey.password(nas).account: "hunter2"],
            resolution: SSHResolution(destination: nas),
            clock: clock.read)
        let token = broker.mint(
            locationID: "nas", purpose: .master, resolution: SSHResolution(destination: nas))
        clock.advance(59)
        XCTAssertEqual(
            broker.answer(token: token, promptKind: "", prompt: "alec@nas.example's password: "),
            .answer("hunter2"))
        clock.advance(2)  // past the 60 s deadline of section 4.2
        XCTAssertEqual(
            broker.answer(token: token, promptKind: "", prompt: "alec@nas.example's password: "),
            .refuse(reason: "expired token"))
        // And it stays refused, because the expiry retires it.
        clock.advance(-30)
        XCTAssertEqual(
            broker.answer(token: token, promptKind: "", prompt: "alec@nas.example's password: "),
            .refuse(reason: "retired token"))
    }

    func testACallerThatIsNotADescendantOfTheSSHIsRefused() {
        // 900 is the ssh; 901 is its askpass; 500 is somebody else's process.
        let ancestry = StaticProcessAncestry([901: 900, 500: 1])
        let (broker, _) = makeBroker(
            secrets: [SecretKey.password(nas).account: "hunter2"],
            resolution: SSHResolution(destination: nas),
            ancestry: ancestry)
        let token = broker.mint(
            locationID: "nas", purpose: .master, resolution: SSHResolution(destination: nas))
        broker.attach(pid: 900, to: token)

        XCTAssertEqual(
            broker.answer(
                token: token, promptKind: "", prompt: "alec@nas.example's password: ",
                callerPID: 901),
            .answer("hunter2"))
        XCTAssertEqual(
            broker.answer(
                token: token, promptKind: "", prompt: "alec@nas.example's password: ",
                callerPID: 500),
            .refuse(reason: "caller is not a descendant of the ssh the token was issued to"))
    }

    func testAProxyJumpHopsAskpassIsADescendantTwoLevelsDown() {
        // master 900 -> ProxyCommand ssh -W 950 -> its askpass 951 (section 4.2).
        let ancestry = StaticProcessAncestry([951: 950, 950: 900])
        let (broker, _) = makeBroker(
            secrets: [SecretKey.password(nas).account: "hunter2"],
            resolution: SSHResolution(destination: nas),
            ancestry: ancestry)
        let token = broker.mint(
            locationID: "nas", purpose: .master, resolution: SSHResolution(destination: nas))
        broker.attach(pid: 900, to: token)
        XCTAssertEqual(
            broker.answer(
                token: token, promptKind: "", prompt: "alec@nas.example's password: ",
                callerPID: 951),
            .answer("hunter2"))
    }

    func testOneSpawnMayRaiseSeveralPromptsButNotEndlessly() {
        let (broker, _) = makeBroker(resolution: SSHResolution(destination: nas))
        broker.maximumInvocations = 3
        let harness = AskpassHarness(
            broker: broker, locationID: "nas", resolution: SSHResolution(destination: nas))
        // A passphrase and then a password on the same connection is ordinary.
        XCTAssertEqual(harness.prompt("Enter passphrase for key '/k': "), .empty)
        XCTAssertEqual(harness.prompt("alec@nas.example's password: "), .empty)
        XCTAssertEqual(harness.prompt("alec@nas.example's password: "), .empty)
        if case .refuse = harness.prompt("alec@nas.example's password: ") {} else {
            XCTFail("the invocation cap did not fire")
        }
    }

    // MARK: the answer table

    func testAStoredPassphraseIsAnswered() {
        let (broker, _) = makeBroker(
            secrets: ["passphrase:/Users/alec/.ssh/id_nas": "open sesame"])
        let harness = AskpassHarness(broker: broker, resolution: SSHResolution(destination: nas))
        XCTAssertEqual(
            harness.prompt("Enter passphrase for key '/Users/alec/.ssh/id_nas': "),
            .answer("open sesame"))
        XCTAssertTrue(harness.misses.isEmpty)
    }

    func testAPassphraseWithNoStoredItemIsAnsweredEmptySoSSHMovesOn() {
        // Section 4.2: ssh gives up on that key after its single attempt and moves on to
        // the next identity, and nothing is stopped. Verified live against the testbed.
        let (broker, _) = makeBroker()
        let harness = AskpassHarness(broker: broker, resolution: SSHResolution(destination: nas))
        XCTAssertEqual(
            harness.prompt("Enter passphrase for key '/Users/alec/.ssh/other': "), .empty)
        XCTAssertEqual(harness.misses.count, 1)
        XCTAssertEqual(harness.misses[0].key, .passphrase(path: "/Users/alec/.ssh/other"))
        XCTAssertFalse(harness.misses[0].refused)
    }

    func testAPasswordIsKeyedByTheResolvedDestinationNotByThePromptText() {
        // The prompt says the HostKeyAlias; the item is the resolved user@hostname:port.
        let (broker, _) = makeBroker(secrets: [SecretKey.password(nas).account: "hunter2"])
        let harness = AskpassHarness(broker: broker, resolution: SSHResolution(destination: nas))
        XCTAssertEqual(harness.prompt("alec@nas-alias's password: "), .answer("hunter2"))
    }

    func testAKeyboardInteractivePasswordUsesTheSameItem() {
        let (broker, _) = makeBroker(secrets: [SecretKey.password(nas).account: "hunter2"])
        let harness = AskpassHarness(broker: broker, resolution: SSHResolution(destination: nas))
        XCTAssertEqual(harness.prompt("(alec@nas.example) Password: "), .answer("hunter2"))
    }

    func testAPasswordWithNoStoredItemIsAnsweredEmpty() {
        let (broker, _) = makeBroker()
        let harness = AskpassHarness(broker: broker, resolution: SSHResolution(destination: nas))
        XCTAssertEqual(harness.prompt("alec@nas.example's password: "), .empty)
        XCTAssertEqual(harness.misses.first?.key, .password(nas))
    }

    func testTheHostKeyQuestionIsRefusedOutsideAdd() {
        let (broker, _) = makeBroker()
        let harness = AskpassHarness(broker: broker, resolution: SSHResolution(destination: nas))
        let reply = harness.prompt(AskpassPromptTests.hostKeyPrompt)
        guard case .refuse = reply else { return XCTFail("the host-key question was not refused") }
        XCTAssertEqual(harness.misses.count, 1)
        XCTAssertTrue(harness.misses[0].refused)
        XCTAssertNotNil(harness.info?.refusalReason)
    }

    func testTheHostKeyQuestionIsRelayedDuringCollect() {
        let (broker, _) = makeBroker()
        broker.collectResponder = { request in
            XCTAssertFalse(request.isSecret)  // read visible on the terminal (section 4.3)
            return "yes"
        }
        let harness = AskpassHarness(
            broker: broker, purpose: .collect, resolution: SSHResolution(destination: nas))
        XCTAssertEqual(harness.prompt(AskpassPromptTests.hostKeyPrompt), .answer("yes"))
    }

    func testAPINAndAOneTimeCodeAreRefused() {
        let (broker, _) = makeBroker()
        let harness = AskpassHarness(broker: broker, resolution: SSHResolution(destination: nas))
        guard case .refuse = harness.prompt("Enter PIN for ED25519-SK key /k: ") else {
            return XCTFail("a PIN prompt was not refused")
        }
        guard case .refuse = harness.prompt("(alec@nas.example) Verification code: ") else {
            return XCTFail("a one-time code was not refused")
        }
    }

    func testAUserPresenceNoticeIsAcknowledgedAndRecorded() {
        let (broker, _) = makeBroker()
        let harness = AskpassHarness(broker: broker, resolution: SSHResolution(destination: nas))
        XCTAssertEqual(
            harness.prompt(AskpassPromptTests.userPresencePrompt, kind: "none"), .empty)
        XCTAssertEqual(
            harness.info?.touchRequiredKeys,
            ["ED25519-SK SHA256:sZBoBnxDlU39oYKVYqzjq1RLWQPpnryr1+EXhXWDt3w"])
    }

    // MARK: the collect flow

    func testCollectAsksTheCLIAndOnlyStoresWhatWasUsed() throws {
        let (broker, store) = makeBroker()
        var asked: [String] = []
        broker.collectResponder = { request in
            asked.append(request.key?.account ?? request.promptText)
            return request.isSecret ? "typed-secret" : "yes"
        }
        let harness = AskpassHarness(
            broker: broker, locationID: "nas", purpose: .collect,
            resolution: SSHResolution(destination: nas))
        XCTAssertEqual(
            harness.prompt("Enter passphrase for key '/Users/alec/.ssh/id_nas': "),
            .answer("typed-secret"))
        XCTAssertEqual(harness.prompt("alec@nas.example's password: "), .answer("typed-secret"))
        XCTAssertEqual(
            asked, ["passphrase:/Users/alec/.ssh/id_nas", SecretKey.password(nas).account])

        // Nothing is written until the connection has succeeded.
        XCTAssertTrue(try store.accounts().isEmpty)
        let written = try broker.commit(token: harness.token)
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(try store.secret(forKey: "passphrase:/Users/alec/.ssh/id_nas"), "typed-secret")
        XCTAssertEqual(try store.secret(for: .password(nas)), "typed-secret")
    }

    func testAnEmptyAnswerAtCollectIsARefusalOfThatPromptAndStoresNothing() throws {
        // "press Enter to skip this and try your key agent instead" (section 4.2).
        let (broker, store) = makeBroker()
        broker.collectResponder = { _ in "" }
        let harness = AskpassHarness(
            broker: broker, purpose: .collect, resolution: SSHResolution(destination: nas))
        XCTAssertEqual(harness.prompt("Enter passphrase for key '/k': "), .empty)
        XCTAssertEqual(try broker.commit(token: harness.token).count, 0)
        XCTAssertTrue(try store.accounts().isEmpty)
    }

    func testMaskingAStoredItemMakesThePromptReachTheTerminalAgain() {
        // The stale-password case: add repeats the collect connection with the stored
        // items for that host masked (section 4.2).
        let (broker, _) = makeBroker(secrets: [SecretKey.password(nas).account: "stale"])
        broker.collectResponder = { _ in "fresh" }
        let token = broker.mint(
            locationID: "nas", purpose: .collect,
            resolution: SSHResolution(destination: nas),
            maskedAccounts: [SecretKey.password(nas).account])
        XCTAssertEqual(
            broker.answer(token: token, promptKind: "", prompt: "alec@nas.example's password: "),
            .answer("fresh"))
    }

    func testCommitStoresOnlyTheAnswersThatWereActuallyUsed() throws {
        let (broker, store) = makeBroker(secrets: ["passphrase:/k": "from-keychain"])
        let harness = AskpassHarness(
            broker: broker, purpose: .collect, resolution: SSHResolution(destination: nas))
        XCTAssertEqual(harness.prompt("Enter passphrase for key '/k': "), .answer("from-keychain"))
        // Re-writing an item that came out of the keychain is harmless and keeps the
        // "every answer that was actually used" rule simple.
        XCTAssertEqual(try broker.commit(token: harness.token), [.passphrase(path: "/k")])
        XCTAssertEqual(try store.secret(forKey: "passphrase:/k"), "from-keychain")
    }

    // MARK: hops

    func testAHopIsResolvedFromItsOwnArgvNotTheMastersDestination() {
        let hop = SSHDestination(user: "hop", hostname: "bastion", port: 2210)
        let resolver = StaticSSHResolver(fallback: nil)
        let hopArgv = ["/usr/bin/ssh", "-W", "inner:22", "-p", "2210", "hop@bastion"]
        resolver.set(SSHResolution(destination: hop), for: hopArgv)
        let store = InMemorySecretsStore([
            SecretKey.password(nas).account: "master-password",
            SecretKey.password(hop).account: "hop-password",
        ])
        let broker = AskpassBroker(
            store: store, resolver: resolver, ancestry: StaticProcessAncestry([:]))
        let masterArgv = ["/usr/bin/ssh", "-N", "alec@nas.example"]
        let token = broker.mint(
            locationID: "nas", purpose: .master,
            resolution: SSHResolution(destination: nas), argv: masterArgv)

        XCTAssertEqual(
            broker.answer(
                token: token, promptKind: "", prompt: "alec@nas.example's password: ",
                parentArguments: masterArgv),
            .answer("master-password"))
        XCTAssertEqual(
            broker.answer(
                token: token, promptKind: "", prompt: "hop@bastion's password: ",
                parentArguments: hopArgv),
            .answer("hop-password"))
    }

    // MARK: the %.100s truncation

    func testATruncatedIdentityPathIsMappedBackOntoTheResolvedIdentityFile() {
        let long = "/Users/alec/Library/Application Support/some/deeply/nested/directory/"
            + String(repeating: "x", count: 40) + "/id_ed25519"
        let truncated = String(long.prefix(100))
        XCTAssertNotEqual(truncated, long)
        let resolution = SSHResolution(destination: nas, identityFiles: [long])
        let (broker, _) = makeBroker(secrets: ["passphrase:\(long)": "open sesame"])
        let harness = AskpassHarness(broker: broker, resolution: resolution)
        XCTAssertEqual(
            harness.prompt("Enter passphrase for key '\(truncated)': "), .answer("open sesame"))
    }

    func testAnUntruncatedPathIsUsedAsIs() {
        XCTAssertEqual(
            AskpassBroker.identityPath(
                matching: "/k", in: SSHResolution(destination: nas, identityFiles: ["/k", "/k2"])),
            "/k")
    }
}

/// A clock the tests move by hand.
final class MutableClock: @unchecked Sendable {
    private var offset: TimeInterval = 0
    private let base = Date()
    private let lock = NSLock()

    func advance(_ seconds: TimeInterval) {
        lock.lock(); offset += seconds; lock.unlock()
    }

    var read: @Sendable () -> Date {
        { [self] in
            lock.lock(); defer { lock.unlock() }
            return base.addingTimeInterval(offset)
        }
    }
}
