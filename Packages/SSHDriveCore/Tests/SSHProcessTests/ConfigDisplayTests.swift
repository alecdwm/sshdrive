import XCTest

@testable import SSHProcess

/// The `ssh -G` display and its config attribution (DESIGN.md sections 4.1, 6.1, 8).
///
/// `ssh -G` prints resolved values only, with no indication of where each came from, so
/// the attribution is the diff against `ssh -F /dev/null -G`. Nothing here runs `ssh`: the
/// two resolutions are the input, which is the whole point of keeping the diff pure.
final class ConfigDisplayTests: XCTestCase {

    /// The shape of the testbed's `spike-deb` block: an alias whose config supplies the
    /// hostname, the port and the identity, resolved against defaults that supply none of
    /// them.
    private func attribution(
        resolved: String, withoutConfig: String
    ) -> SSHConfigAttribution {
        SSHConfigAttribution(
            resolved: SSHConfigResolution.parse(resolved),
            withoutConfigFiles: SSHConfigResolution.parse(withoutConfig))
    }

    func testAValueThatDiffersBetweenTheTwoRunsCameFromAConfigFile() {
        let diff = attribution(
            resolved: """
                user alec
                hostname 192.168.64.1
                port 2201
                identityfile ~/.ssh/sshdrive-spike
                """,
            withoutConfig: """
                user alec
                hostname spike-deb
                port 22
                identityfile ~/.ssh/id_rsa
                """)
        XCTAssertEqual(diff.fromConfigFiles, ["hostname", "port", "identityfile"])
        // `user` is the same in both, so it is the local account and not a config value.
        XCTAssertFalse(diff.fromConfigFiles.contains("user"))
    }

    func testAKeywordOnlyTheDefaultsCarryIsStillReportedAsADifference() {
        // A config that *removes* a keyword (`IdentityFile none`) differs just as much as
        // one that adds it, and the display must not silently credit the default.
        let diff = attribution(
            resolved: "user alec\nhostname nas",
            withoutConfig: "user alec\nhostname nas\nproxyjump bastion")
        XCTAssertEqual(diff.fromConfigFiles, ["proxyjump"])
    }

    func testTheDisplayLabelsEachSource() {
        let diff = attribution(
            resolved: """
                user pw
                hostname 192.168.64.1
                port 2201
                identityfile /Users/alec/.ssh/sshdrive-spike
                """,
            withoutConfig: """
                user alec
                hostname spike-deb
                port 22
                identityfile /Users/alec/.ssh/id_rsa
                """)
        // `user` and `port` are the location's own overrides here: `add pw@…:2201` stores
        // them and they reach `ssh` as `-o`, which beats the config file.
        let display = SSHConfigDisplay.make(
            attribution: diff, overrideKeywords: ["user", "port"])
        let byKeyword = Dictionary(
            uniqueKeysWithValues: display.lines.map { ($0.keyword, $0) })
        XCTAssertEqual(byKeyword["user"]?.source, .override)
        XCTAssertEqual(byKeyword["port"]?.source, .override)
        XCTAssertEqual(byKeyword["hostname"]?.source, .configFile)
        XCTAssertEqual(byKeyword["identityfile"]?.source, .configFile)
        XCTAssertEqual(byKeyword["hostname"]?.text, "hostname 192.168.64.1 (from ssh config)")
        XCTAssertEqual(byKeyword["user"]?.text, "user pw (from this location)")
    }

    func testAValueNeitherSideChangedIsSshsOwnDefault() {
        let diff = attribution(
            resolved: "user alec\nhostname nas\nport 22\nstricthostkeychecking ask",
            withoutConfig: "user alec\nhostname nas\nport 22\nstricthostkeychecking ask")
        let display = SSHConfigDisplay.make(attribution: diff, overrideKeywords: [])
        XCTAssertTrue(display.lines.allSatisfy { $0.source == .builtIn })
        XCTAssertTrue(display.text.contains("(ssh default)"))
    }

    func testEveryIdentityFileIsShownInOfferOrder() {
        // Section 4.2's refusal turns on the order: a touch-required FIDO key that sits
        // first is used, and asks for its touch, before the key that would have worked.
        let diff = attribution(
            resolved: """
                user alec
                hostname nas
                port 22
                identityfile /Users/alec/.ssh/id_ed25519_sk
                identityfile /Users/alec/.ssh/id_nas
                """,
            withoutConfig: "user alec\nhostname nas\nport 22")
        let display = SSHConfigDisplay.make(attribution: diff, overrideKeywords: [])
        let identities = display.lines.filter { $0.keyword == "identityfile" }.map(\.value)
        XCTAssertEqual(
            identities,
            ["/Users/alec/.ssh/id_ed25519_sk", "/Users/alec/.ssh/id_nas"])
    }

    func testTheOverriddenKeywordsAreReportedSeparately() {
        // Section 6.1: `show` prints the connection-sharing and session-shape settings the
        // config would have applied and the agent overrode. `spike-deb-shapes` is exactly
        // this case in the testbed.
        let diff = attribution(
            resolved: """
                user alec
                hostname 192.168.64.1
                port 2201
                remotecommand echo this must never run under sshdrive
                requesttty force
                controlmaster auto
                controlpath /Users/alec/.ssh/cm-%r@%h-%p
                """,
            withoutConfig: """
                user alec
                hostname spike-deb-shapes
                port 22
                remotecommand none
                requesttty no
                controlmaster false
                """)
        let display = SSHConfigDisplay.make(attribution: diff, overrideKeywords: [])
        let overridden = Set(display.overridden.map(\.keyword))
        XCTAssertTrue(overridden.contains("remotecommand"))
        XCTAssertTrue(overridden.contains("requesttty"))
        XCTAssertTrue(overridden.contains("controlmaster"))
        XCTAssertTrue(overridden.contains("controlpath"))
        XCTAssertTrue(display.text.contains("overridden by SSH Drive"))
    }

    func testAJumpChainIsReadAndNeverHandedBackToSsh() {
        let diff = attribution(
            resolved: "user alec\nhostname inner\nport 22\nproxyjump spike-bastion-a,spike-bastion-b",
            withoutConfig: "user alec\nhostname spike-inner\nport 22")
        let display = SSHConfigDisplay.make(attribution: diff, overrideKeywords: [])
        XCTAssertEqual(display.jumpChain.map(\.host), ["spike-bastion-a", "spike-bastion-b"])
        XCTAssertTrue(display.text.contains("never handed to ssh"))
    }

    func testAHandWrittenSshProxyCommandIsCalledOut() {
        // Section 6.1: that inner `ssh` is found through PATH, reads the config
        // unmodified, and signs through the key agent during the IdentityAgent=none pass.
        let diff = attribution(
            resolved: "user alec\nhostname nas\nport 22\nproxycommand ssh -W %h:%p bastion",
            withoutConfig: "user alec\nhostname nas\nport 22")
        let display = SSHConfigDisplay.make(attribution: diff, overrideKeywords: [])
        XCTAssertNotNil(display.handWrittenProxyCommand)
        XCTAssertTrue(display.text.contains("Prefer ProxyJump"))

        let netcat = attribution(
            resolved: "user alec\nhostname nas\nport 22\nproxycommand /usr/bin/nc %h %p",
            withoutConfig: "user alec\nhostname nas\nport 22")
        XCTAssertNil(
            SSHConfigDisplay.make(attribution: netcat, overrideKeywords: []).handWrittenProxyCommand)
    }

    func testOverrideKeywordsComeOffTheTarget() {
        let target = SSHTarget(
            host: "nas", user: "alec", port: 2201,
            identityFile: "/Users/alec/.ssh/id_nas",
            sshOptions: ["-o", "IdentitiesOnly=yes", "-o", "ProxyJump=hop@bastion:2210"])
        XCTAssertEqual(
            SSHConfigDisplay.overrideKeywords(for: target),
            ["user", "port", "identityfile", "identitiesonly", "proxyjump"])
    }

    // MARK: `set option remove`

    func testRemovingAnOptionByKeywordOrByWholePair() {
        let options = ["-o", "Ciphers=aes256-gcm@openssh.com", "-o", "IdentitiesOnly=yes"]
        XCTAssertEqual(
            SSHCommandBuilder.removingOption("Ciphers", from: options),
            ["-o", "IdentitiesOnly=yes"])
        XCTAssertEqual(
            SSHCommandBuilder.removingOption("Ciphers=aes256-gcm@openssh.com", from: options),
            ["-o", "IdentitiesOnly=yes"])
        XCTAssertEqual(SSHCommandBuilder.removingOption("Compression", from: options), options)
    }

    // MARK: the collect connection's command line

    func testTheCollectConnectionIsTheMastersOwnCommandLineWithAskInPlaceOfYes() {
        // Section 4.2: "the agent runs the exact command it will use later". The only
        // difference is section 4.3's host-key setting, so that the fingerprint question
        // is raised and can be relayed to the terminal.
        let target = SSHTarget(host: "nas", user: "alec", port: 2201)
        let runtime = SSHCommandBuilder.master(target: target, controlPath: "/tmp/s")
        let collect = SSHCommandBuilder.master(
            target: target, controlPath: "/tmp/c", hostKeyChecking: "ask")
        XCTAssertEqual(runtime.option("StrictHostKeyChecking"), "yes")
        XCTAssertEqual(collect.option("StrictHostKeyChecking"), "ask")
        XCTAssertEqual(runtime.option("UpdateHostKeys"), "no")
        XCTAssertEqual(collect.option("UpdateHostKeys"), "no")
        XCTAssertEqual(collect.option("IdentityAgent"), "none")
        // Everything else is word for word the same but the socket.
        let normalise: ([String]) -> [String] = { arguments in
            arguments.map { $0.hasPrefix("ControlPath=") ? "ControlPath=" : $0 }
                .map { $0 == "yes" ? $0 : $0 }
        }
        XCTAssertEqual(
            normalise(runtime.arguments).filter { !$0.hasPrefix("StrictHostKeyChecking=") },
            normalise(collect.arguments).filter { !$0.hasPrefix("StrictHostKeyChecking=") })
    }

    func testEveryHopOfTheChainGetsTheSameHostKeySetting() {
        // testbed/README.md's third trap: `-J` does not pass `-o` flags to the hops, which
        // is why the chain is rebuilt with the options written out per hop.
        let hops = [JumpHop(host: "bastion-a", user: "hop", port: 2210), JumpHop(host: "bastion-b")]
        let command = ProxyChainBuilder.proxyCommand(
            for: hops, identityAgentNone: true, hostKeyChecking: "ask")
        XCTAssertNotNil(command)
        XCTAssertEqual(
            command!.components(separatedBy: "StrictHostKeyChecking=ask").count - 1, 2)
        XCTAssertFalse(command!.contains("StrictHostKeyChecking=yes"))
    }
}
