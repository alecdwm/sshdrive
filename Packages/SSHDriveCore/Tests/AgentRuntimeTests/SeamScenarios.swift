import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Index
import SFTP
import SSHProcess
import ServerModel
import Testing

/// The seams the resilience scenarios stand on: the driven clock's cancellable sleep, the
/// change detector's loop on that clock, and the connect path after authentication run
/// against an in-process master (docs/design/testing.md).
extension AgentScenarios {

    @Suite struct SeamScenarios {

        // MARK: The driven clock

        /// A cancelled sleep returns at once and leaves nothing parked, without the clock
        /// moving.
        @Test func aCancelledVirtualSleepReturns() async throws {
            let clock = VirtualAgentClock()
            let start = clock.uptime()
            let sleeper = Task { await clock.sleep(seconds: 60) }
            try await Self.waitFor { clock.sleeperCount == 1 }
            #expect(clock.nextDeadline == start + 60)

            sleeper.cancel()
            await sleeper.value
            #expect(clock.sleeperCount == 0)
            #expect(clock.nextDeadline == nil)
            #expect(clock.uptime() == start, "nothing advanced the clock")
        }

        /// A task cancelled before it sleeps does not park at all.
        @Test func aSleepInACancelledTaskDoesNotPark() async {
            let clock = VirtualAgentClock()
            let sleeper = Task {
                while !Task.isCancelled { await Task.yield() }
                await clock.sleep(seconds: 60)
            }
            sleeper.cancel()
            await sleeper.value
            #expect(clock.sleeperCount == 0)
        }

        /// `advanceToNextDeadline` moves exactly to the earliest parked sleeper.
        @Test func advancingToTheNextDeadlineReleasesTheEarliestSleeper() async throws {
            let clock = VirtualAgentClock()
            let start = clock.uptime()
            let short = Task { await clock.sleep(seconds: 2) }
            let long = Task { await clock.sleep(seconds: 30) }
            try await Self.waitFor { clock.sleeperCount == 2 }

            #expect(await clock.advanceToNextDeadline())
            await short.value
            #expect(clock.uptime() == start + 2)
            #expect(clock.sleeperCount == 1)
            #expect(clock.nextDeadline == start + 30)

            long.cancel()
            await long.value
            #expect(await clock.advanceToNextDeadline() == false)
        }

        // MARK: The detector's loop

        /// The loop's sleep is on the agent's clock: advancing it past the idle interval
        /// runs the next cycle with no real waiting, and `stop()` ends a parked sleep.
        @Test func theDetectorLoopRunsOnTheAgentClock() async throws {
            let clock = VirtualAgentClock()
            let harness = try AgentHarness(clock: clock)
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let fake = FakeTransport(root: "/srv/fake")
            let runtime = try harness.makeRuntime(location: location, transport: fake)
            try await runtime.start()

            let detector = ChangeDetector(
                locationID: location.id, runtime: runtime, location: location,
                capabilities: ChangeDetectionLadder.ServerCapabilities(),
                environment: harness.environment)
            await detector.start()
            try await Self.waitFor { await detector.status()["cycles"] as? Int == 1 }
            try await Self.waitFor { clock.nextDeadline != nil }

            // Untouched, the interval is the idle one, and the loop wakes at most every
            // minute to re-read the schedule.
            let firstCycleAt = clock.now()
            try await Self.drive(clock) { await detector.status()["cycles"] as? Int == 2 }
            #expect(await detector.status()["cycles"] as? Int == 2)
            #expect(clock.now() - firstCycleAt >= PollSchedule.idleInterval)

            await detector.stop()
            #expect(clock.sleeperCount == 0, "stop() cancelled the loop's sleep")
        }

        // MARK: The connect path after authentication

        /// `establish` runs channel 1, the real channel probe, the real server probe and
        /// the capability cache over an in-process master whose SFTP channels are a real
        /// SFTP v3 wire stream to `FakeSFTPServer`.
        @Test func establishRunsOverAnInProcessMaster() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let server = FakeSFTPServer(profile: .debian, root: "/srv/fake")
            server.put("hello.txt", contents: Data("hi".utf8))
            let master = StubMaster { server.makeStream() }

            let transport = try await SSHBackedTransport.establish(
                master: master, location: location, uploadTag: "t0000000",
                clock: harness.clock)

            #expect(await master.sftpOpened == 3, "channel 1, then the probe's two")
            #expect(transport.budget == .unrestricted)
            #expect(!transport.transfersShareMetadataChannel)
            #expect(await master.execOpened == 1, "one server probe")
            #expect(!transport.probe.hasShellAccess)
            #expect(transport.execMaster != nil)
            #expect(CapabilityCache.channelBudget(locationID: location.id) == .unrestricted)
            let names = try await transport.readdir(.root).map(\.name)
            #expect(names.contains(Data("hello.txt".utf8)))
            await transport.shutdown()
            #expect(await master.shutdowns == 1)
        }

        /// With the driven clock in the SFTP configuration, a server that never answers the
        /// handshake fails `establish` in model time, and the master is shut down.
        @Test func aSilentServerFailsTheHandshakeInModelTime() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            // A clock of its own, so the only sleeper on it is the SFTP client's sweeper
            // and every advance is one of its ticks.
            let clock = VirtualAgentClock()
            let master = StubMaster { SilentStream() }
            var configuration = SFTPClient.Configuration()
            configuration.clock = clock

            let attempt = Task {
                try await SSHBackedTransport.establish(
                    master: master, location: location, uploadTag: "t0000000",
                    clock: clock, sftpConfiguration: configuration)
            }
            let start = clock.now()
            try await Self.drive(clock) { await master.shutdowns > 0 }
            try #require(await master.shutdowns == 1)
            await #expect(throws: (any Error).self) { try await attempt.value }
            #expect(clock.now() - start >= 20, "the 20 s metadata deadline, in model time")
            #expect(clock.now() - start < 21)
        }

        // MARK: Helpers

        /// Advances the driven clock to each next deadline until `done` holds, polling in
        /// real time while nothing is parked. Bounded in real time, not in steps: under a
        /// loaded suite the task being driven can take many turns to park its next sleep.
        private static func drive(
            _ clock: VirtualAgentClock, until done: @Sendable () async -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if await done() { return }
                if !(await clock.advanceToNextDeadline()) {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            Issue.record("the condition never held")
        }

        /// Real-time polling for a condition another task brings about.
        private static func waitFor(
            _ condition: @Sendable () async -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if await condition() { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            Issue.record("the condition never held")
        }
    }
}

/// An authenticated master with no `ssh` behind it: every SFTP channel is a stream the
/// test hands out, and every exec channel is refused the way a `ForceCommand` account
/// refuses one.
private actor StubMaster<S: ByteStream>: RemoteMaster {
    private let makeStream: @Sendable () -> S
    private(set) var sftpOpened = 0
    private(set) var execOpened = 0
    private(set) var shutdowns = 0

    init(makeStream: @escaping @Sendable () -> S) { self.makeStream = makeStream }

    var isRunning: Bool { shutdowns == 0 }
    var lastStderr: String { "" }
    func check() -> Bool { shutdowns == 0 }
    func shutdown() { shutdowns += 1 }

    func openSFTPChannel(readinessDeadline: TimeInterval) -> StubSFTPChannel<S> {
        sftpOpened += 1
        return StubSFTPChannel(stream: makeStream())
    }

    func openExecChannel(script: RemoteScript, readinessDeadline: TimeInterval) throws
        -> ExecChannel
    {
        execOpened += 1
        throw SSHProcessError.noShellAccess(prefix: Data(OpenSSHPrompts.forceCommandSentence.utf8))
    }
}

private final class StubSFTPChannel<S: ByteStream>: RemoteSFTPChannel, @unchecked Sendable {
    let stream: S
    init(stream: S) { self.stream = stream }
    var stderrText: String { "" }
    func close() { stream.close() }
}

/// A stream whose server never says anything; it ends only when closed.
private final class SilentStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    func read(upTo count: Int, deadline: Date) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(returning: Data())
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func write(_ data: Data) async throws {}
    func closeWrite() {}

    func close() {
        lock.lock()
        closed = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume(returning: Data()) }
    }
}
