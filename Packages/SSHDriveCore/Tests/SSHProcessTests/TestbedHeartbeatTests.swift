import XCTest
@testable import SSHProcess

/// Spike S7's half of milestone 2: nothing we start on a server outlives the connection
/// by more than a minute (DESIGN.md section 6.4). `ClientAliveInterval` is unset
/// everywhere but `deb`, so sshd itself will not notice for hours; the wrapper is what
/// kills the child. Run under bash, dash and busybox ash.
final class TestbedHeartbeatTests: XCTestCase {

    private var masters: [SSHMaster] = []

    override func tearDown() async throws {
        for master in masters { await master.shutdown() }
        masters = []
        Testbed.reapHopChildren()
    }

    /// A sleep duration nothing else on the server will be using. Fixed markers cost an
    /// hour once already: a run that leaves an orphan behind makes every later run count
    /// it and fail, which is exactly the orphan this test is about.
    private func marker() -> String { String(Int.random(in: 30_000 ... 39_999)) }

    private func master(host: String, user: String? = nil) async throws -> SSHMaster {
        let master = try Testbed.master(host: host, user: user)
        masters.append(master)
        try await master.connect()
        return master
    }

    /// Counts processes whose command line contains `needle`, read from /proc so the same
    /// script works under Debian's procps and busybox alike.
    private func sleeperCount(on master: SSHMaster, marker: String) async throws -> Int {
        let body = """
        __n=0
        for __f in /proc/[0-9]*/cmdline; do
          __c=$(tr '\\000' ' ' < "$__f" 2>/dev/null) || continue
          case "$__c" in *"$1"*) __n=$((__n + 1)) ;; esac
        done
        printf '%s\\000' "$__n"
        """
        let (payload, _) = try await Testbed.runScript(
            on: master, body: body, arguments: [marker], timeout: 30
        )
        let text = String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self)
        return Int(text) ?? -1
    }

    /// Kill the mux client and the wrapper sees stdin EOF, which is the same signal as a
    /// dead agent. The background sleeper must be gone within a minute.
    private func assertSleeperDies(host: String, user: String? = nil, marker: String) async throws {
        let master = try await master(host: host, user: user)
        let script = RemoteScript(body: "sleep \(marker)", heartbeat: .standard)
        let channel = try await master.openExecChannel(script: script, readinessDeadline: 30)

        try await Task.sleep(nanoseconds: 1_500_000_000)
        let before = try await sleeperCount(on: master, marker: "sleep \(marker)")
        XCTAssertGreaterThanOrEqual(before, 1, "\(host): the sleeper should be running")

        // Kill the client abruptly: no -O exit, no close, exactly what a crashed agent
        // leaves behind.
        kill(channel.pid, SIGKILL)
        channel.stream.close()

        var remaining = before
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            remaining = try await sleeperCount(on: master, marker: "sleep \(marker)")
            if remaining == 0 { break }
        }
        XCTAssertEqual(remaining, 0, "\(host): the heartbeat wrapper must kill its child within a minute")
    }

    /// `deb`, whose accounts log in with bash - but an exec channel runs `sh -s`, and
    /// Debian's `/bin/sh` is dash, so this is the sleep-and-mtime watchdog branch. That is
    /// the ordinary Linux case, not a fringe one (section 6.4).
    func testHeartbeatWrapperOnDebianWhereShIsDash() async throws {
        try Testbed.skipUnlessEnabled()
        try await assertSleeperDies(host: "spike-deb", marker: marker())
    }

    /// busybox ash: `read -t` exists, so this is the other branch.
    func testHeartbeatWrapperOnAlpineBusybox() async throws {
        try Testbed.skipUnlessEnabled()
        try await assertSleeperDies(host: "spike-alp", marker: marker())
    }

    /// An account whose *login* shell is dash as well, so nothing in the chain has
    /// `read -t`.
    func testHeartbeatWrapperUnderADashLoginShell() async throws {
        try Testbed.skipUnlessEnabled()
        try await assertSleeperDies(host: "spike-shells", user: "dashuser", marker: marker())
    }

    /// The silence branch rather than the EOF branch: the channel stays open and the agent
    /// simply stops writing. Short settings so the test is seconds rather than a minute.
    func testSilenceAloneKillsTheChildEvenWithTheChannelOpen() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try await master(host: "spike-deb")
        let sleeper = marker()
        // The watchdog compares mtimes at one-second granularity (dash's `test -nt` reads
        // st_mtime, not st_mtim), so the tick has to be comfortably longer than a second
        // or a heartbeat inside the same second reads as a miss.
        let script = RemoteScript(
            body: "sleep \(sleeper)", heartbeat: .init(intervalSeconds: 5, timeoutSeconds: 20)
        )
        let channel = try await master.openExecChannel(script: script, readinessDeadline: 30)
        defer { channel.close() }

        try await Task.sleep(nanoseconds: 2_000_000_000)
        // Heartbeats keep it alive well past the 20 s timeout.
        for index in 0 ..< 8 {
            do {
                try await channel.sendHeartbeat()
            } catch {
                XCTFail("heartbeat \(index) failed: \(error); channel stderr: \(channel.stderrText); exit: \(String(describing: channel.exitStatus()))")
                return
            }
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
        let aliveUnderHeartbeats = try await sleeperCount(on: master, marker: "sleep \(sleeper)")
        XCTAssertGreaterThanOrEqual(aliveUnderHeartbeats, 1, "heartbeats must keep the child alive")
        // Then stop, without closing the channel.
        var remaining = 1
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            remaining = try await sleeperCount(on: master, marker: "sleep \(sleeper)")
            if remaining == 0 { break }
        }
        XCTAssertEqual(remaining, 0, "silence alone must kill the child")
    }

    /// Milestone 9: the wrapper's stdin relay, under a **real** `sh`.
    ///
    /// The shape assertions in `RemoteScriptTests` are not enough here, and this test
    /// exists because they were not: the first relay wrapper put a `;` after
    /// `relayWrite`, which already ends in one, and dash answered
    /// `Syntax error: ";;" unexpected` at line 31 - the channel died on the spot and the
    /// ladder read it as a helper that would not start (2026-09-05, `deb`).
    ///
    /// So this runs the wrapper on Debian's dash and on Alpine's busybox ash, feeds a
    /// line down the channel exactly as the agent feeds the root set, and requires the
    /// child on the far side of the FIFO to have received it.
    func testTheStdinRelayReachesTheChildOnARealShell() async throws {
        try Testbed.skipUnlessEnabled()
        for host in ["spike-deb", "spike-alp"] {
            let master = try await master(host: host)
            let relay = "/tmp/sshdrive-relay-test-\(Int.random(in: 100_000...999_999))"
            // The child copies whatever reaches its stdin straight back out, so anything
            // the wrapper relays appears in the channel's own output.
            let script = RemoteScript(
                body: "exec cat", heartbeat: .standard, stdinRelay: relay)
            let channel = try await master.openExecChannel(script: script, readinessDeadline: 30)
            defer { channel.close() }

            try await Task.sleep(nanoseconds: 1_000_000_000)
            let line = Data("{\"op\":\"roots\",\"shallow\":[\"a b\"]}\n".utf8)
            try await channel.stream.write(line)

            var seen = Data()
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, !seen.contains(0x0A) {
                let chunk = try await channel.stream.read(upTo: 4096, deadline: deadline)
                if chunk.isEmpty { break }
                seen.append(chunk)
            }
            let text = String(decoding: seen, as: UTF8.self)
            XCTAssertTrue(
                text.contains("{\"op\":\"roots\",\"shallow\":[\"a b\"]}"),
                "\(host): the wrapper did not relay the line; got \(text.debugDescription), "
                    + "stderr \(channel.stderrText.debugDescription)")
            // And nothing the shell itself said: a syntax error would land here.
            XCTAssertFalse(channel.stderrText.contains("Syntax error"), host)
        }
    }
}
