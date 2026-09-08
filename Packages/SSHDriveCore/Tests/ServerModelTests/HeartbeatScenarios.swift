import Foundation
import XCTest

import SSHProcess
@testable import ServerModel

/// Suite J's teardown scenarios: what happens to the things we start on a server when the
/// client goes away, and the process-group regression that made a Tailscale SSH node kill
/// its own sibling sessions (`docs/testing-architecture.md` section 5).
///
/// Every one of these runs a real shell in a real process group, because the whole
/// question is which processes a signal reaches.
final class HeartbeatScenarios: XCTestCase {

    private var servers: [FakeSSHD] = []
    private var markers: [String] = []

    override func tearDown() async throws {
        for server in servers { server.shutdown() }
        servers = []
        for marker in markers { Self.killAll(matching: marker) }
        markers = []
    }

    private func sshd(_ profile: ServerProfile) throws -> FakeSSHD {
        if let reason = FakeSSHD.unavailabilityReason(for: profile) {
            throw XCTSkip("\(profile.name): \(reason)")
        }
        let server = try FakeSSHD(profile: profile)
        servers.append(server)
        return server
    }

    /// A sleep duration nothing else on this box will be using. A fixed marker costs an
    /// hour once: a run that leaves an orphan behind makes every later run count it, which
    /// is exactly the orphan these scenarios are about.
    private func marker() -> String {
        let value = String(Int.random(in: 40_000 ... 49_999))
        markers.append(value)
        return value
    }

    /// Counts live processes whose command line contains `needle`, ignoring zombies:
    /// `pgrep` counts them, so "did I kill it?" is unanswerable from a name match alone
    /// (`SQ-075`); the process state is the one to read. `ProcessTable` reads `ps` rather
    /// than `/proc`, because these scenarios must run on Darwin too.
    private static func count(matching needle: String) -> Int {
        ProcessTable.count(matching: needle)
    }

    private static func killAll(matching needle: String) {
        ProcessTable.killAll(matching: needle)
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool, timeout: TimeInterval = 15
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return condition()
    }

    /// The precondition both Tailscale rows rest on: the session and the bystander really
    /// are in one process group that belongs to **neither** of them - `tailscaled`'s
    /// (`SQ-010`). A platform whose `posix_spawn` declines to join an existing group would
    /// otherwise turn the regression proof into a test of nothing, so it skips by name.
    private static func requireSharedProcessGroup(
        channel: FakeExecChannel, bystander: SpawnedProcess
    ) throws {
        guard ProcessTable.shareAForeignProcessGroup(channel.pid, bystander.pid) else {
            throw XCTSkip(
                "this box's posix_spawn would not put the session into tailscaled's process "
                    + "group (session pgid \(ProcessTable.processGroup(of: channel.pid).map(String.init) ?? "?"), "
                    + "bystander pgid \(ProcessTable.processGroup(of: bystander.pid).map(String.init) ?? "?")); "
                    + "SQ-010 cannot be run here, and is skipped rather than faked")
        }
    }

    /// The **positive control** the bite-proof rests on, and it is deliberately not the
    /// code under test: one session that does nothing but `kill -TERM 0`, and a bystander
    /// in the same shared group. If that does not reach the bystander, this box cannot
    /// stage `SQ-010` at all - what `tailscaled` does to its sessions is not reproducible
    /// here - and the row skips with that sentence rather than passing for the wrong
    /// reason. On Linux it reaches it, and the regression proof below is live.
    private static func requireASharedGroupKillIsDeliverable(on server: FakeSSHD) async throws {
        let bystander = try server.openBystander(sleepSeconds: 30)
        defer {
            kill(bystander.pid, SIGKILL)
            _ = Spawn.wait(pid: bystander.pid)
        }
        let channel = try await server.openExecChannel(
            script: RemoteScript(body: "printf '%s\\000' ready; kill -TERM 0 2>/dev/null"),
            readinessDeadline: 10)
        _ = try await channel.readPayload(timeout: 10)
        var reached = false
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if !FakeSSHD.isAlive(bystander.pid) { reached = true; break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        channel.close()
        guard reached else {
            throw XCTSkip(
                "a plain `kill -TERM 0` from one session did not reach a sibling in the same "
                    + "shared process group on this box, so the blast radius `tailscaled` "
                    + "gives its sessions cannot be staged here; SQ-010's bite-proof is "
                    + "skipped rather than passed for the wrong reason (Linux is the gate)")
        }
    }

    // MARK: - J1: the Tailscale `kill -TERM 0` regression

    /// The wrapper as it stood **before 2026-09-08**, naming `0` instead of `-$$`.
    ///
    /// A copy lives here and nowhere in `Sources/`, exactly as `SystemModelTests` keeps a
    /// copy of the 0.1.2 working-set enumerator: a regression scenario is only worth
    /// something if the old code really does fail it.
    private func legacyWrapperBody(marker: String) -> String {
        """
        sleep \(marker) </dev/null &
        __c=$!
        printf '%s\\000' started
        while IFS= read -r __l; do :; done
        trap '' TERM
        kill -TERM "$__c" 2>/dev/null
        /usr/bin/pkill -TERM -P "$__c" 2>/dev/null || true
        kill -TERM 0 2>/dev/null
        """
    }

    /// **J1** (`SQ-010`, `SQ-070`): `tailscaled` puts every session of every client in
    /// **its own** process group, so the old wrapper's `kill -TERM 0` signalled all of
    /// them - the account's other sessions and the connections under them. This is the
    /// bite-proof: the old wrapper is run for real against a real shared process group and
    /// a real bystander session, and the bystander dies.
    func testJ1_theOldWrapperKillsASiblingSessionOnAServerThatSharesAProcessGroup() async throws {
        let server = try sshd(.tailscaleSSH)
        XCTAssertTrue(ServerProfile.tailscaleSSH.sessionGrouping.isShared, "SQ-010")

        try await Self.requireASharedGroupKillIsDeliverable(on: server)
        let bystander = try server.openBystander(sleepSeconds: 120)
        let victim = marker()
        let script = RemoteScript(body: legacyWrapperBody(marker: victim))
        let channel = try await server.openExecChannel(script: script, readinessDeadline: 10)
        _ = try await channel.readPayload(timeout: 10)
        try Self.requireSharedProcessGroup(channel: channel, bystander: bystander)
        XCTAssertTrue(FakeSSHD.isAlive(bystander.pid), "the bystander was up before the kill")

        channel.endInput()   // the wrapper's EOF: exactly what a dead agent looks like
        let bystanderDied = await waitUntil({ !FakeSSHD.isAlive(bystander.pid) })
        XCTAssertTrue(
            bystanderDied,
            "SQ-010: `kill -TERM 0` in tailscaled's shared group takes the sibling session with it")
        channel.close()
    }

    /// **J1** (`SQ-010`, `SQ-012`): the shipping wrapper names `-$$`, *the group this
    /// shell leads*. Under sshd that is identical to `0`, because the session is its own
    /// group leader; under Tailscale SSH it is an `ESRCH`, because the shell leads no
    /// group there. Either way the child and its children die by pid, so the tier 2
    /// guarantee - nothing we start outlives the connection - holds on both.
    func testJ1_theShippingWrapperSparesTheSiblingAndStillKillsItsOwnChild() async throws {
        let server = try sshd(.tailscaleSSH)
        let bystander = try server.openBystander(sleepSeconds: 120)
        let victim = marker()

        let script = RemoteScript(
            body: "printf '%s\\000' started; exec sleep \(victim)",
            heartbeat: .init(intervalSeconds: 2, timeoutSeconds: 6))
        XCTAssertTrue(script.text.contains("kill -TERM -$$"), "gotcha 100: the group is named -$$")
        XCTAssertFalse(script.text.contains("kill -TERM 0"), "and never 0")

        let channel = try await server.openExecChannel(script: script, readinessDeadline: 10)
        _ = try await channel.readPayload(timeout: 10)
        try Self.requireSharedProcessGroup(channel: channel, bystander: bystander)
        let childStarted = await waitUntil({ Self.count(matching: "sleep \(victim)") >= 1 },
                                           timeout: 5)
        XCTAssertTrue(childStarted, "the child is running")

        channel.endInput()
        let childGone = await waitUntil({ Self.count(matching: "sleep \(victim)") == 0 },
                                       timeout: 20)
        XCTAssertTrue(
            childGone,
            "section 6.4: nothing we started outlives the connection, shared group or not")
        XCTAssertTrue(
            FakeSSHD.isAlive(bystander.pid),
            "SQ-010: and the sibling session survives, which is the whole fix")
        channel.close()
    }

    /// **J1** (`SQ-012`): on an OpenSSH server the session *is* its own process group, so
    /// `-$$` and `0` name the same set - which is why the bug above was invisible for four
    /// milestones. The same wrapper still takes the child and everything it started.
    func testJ1_onOpenSSHTheSameWrapperStillTakesTheChildAndItsChildren() async throws {
        let server = try sshd(.debian)
        let victim = marker()
        let script = RemoteScript(
            body: "printf '%s\\000' started; sleep \(victim)",
            heartbeat: .init(intervalSeconds: 2, timeoutSeconds: 6))
        let channel = try await server.openExecChannel(script: script, readinessDeadline: 10)
        XCTAssertEqual(channel.processGroup, channel.pid,
                       "SQ-012: sshd gives a session a group of its own, so -$$ == 0")
        _ = try await channel.readPayload(timeout: 10)
        let running = await waitUntil({ Self.count(matching: "sleep \(victim)") >= 1 }, timeout: 5)
        XCTAssertTrue(running)

        channel.endInput()
        let gone = await waitUntil({ Self.count(matching: "sleep \(victim)") == 0 }, timeout: 20)
        XCTAssertTrue(gone, "SQ-012: the group kill reaches the child and its background children")
        channel.close()
    }

    // MARK: - J2 / J3: what the server will not do for us

    /// **J2** (`SQ-008`) and **J3** (`SQ-009`): a bare background process started by a
    /// session **survives an abrupt client kill** - sshd reaping the session does not
    /// reach a child that has left the foreground job - and `ClientAliveInterval` changes
    /// nothing about it, set or unset. The heartbeat wrapper is therefore the only
    /// mechanism there is, not a workaround for a misconfiguration.
    func testJ2andJ3_aBareBackgroundChildSurvivesAKillWithOrWithoutClientAlive() async throws {
        for profile in [ServerProfile.debian,                                  // 15/3 set
                        ServerProfile.debianShells.with(loginShell: .bashQuiet)] {  // unset
            let server = try sshd(profile)
            let survivor = marker()
            // Bare: no wrapper, no heartbeat - the shape section 6.4 measured.
            let script = RemoteScript(
                body: "sleep \(survivor) </dev/null & printf '%s\\000' started")
            let channel = try await server.openExecChannel(script: script, readinessDeadline: 10)
            _ = try await channel.readPayload(timeout: 10)
            let started = await waitUntil({ Self.count(matching: "sleep \(survivor)") >= 1 },
                                          timeout: 5)
            XCTAssertTrue(started)

            channel.killClientAbruptly()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            XCTAssertGreaterThanOrEqual(
                Self.count(matching: "sleep \(survivor)"), 1,
                "\(profile.name) (ClientAliveInterval \(profile.clientAliveInterval.map(String.init) ?? "unset")): "
                    + "SQ-008/SQ-009 - the server does not clean up after us")
        }
    }
}
