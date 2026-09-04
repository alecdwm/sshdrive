import XCTest
import SFTP
@testable import AgentCore

/// DESIGN.md section 6.2's transfer scheduler, driven against `FakeTransport` - the test
/// double milestone 1 built for exactly this (section 12).
final class TransferSchedulerTests: XCTestCase {

    /// A body that blocks until it is released, so several transfers can be in flight at
    /// once and the concurrency is observable rather than inferred.
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            open = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    /// Counts how many bodies were inside at once.
    private final class Concurrency: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var current = 0
        private(set) var peak = 0
        private(set) var order: [String] = []

        func enter(_ label: String) {
            lock.lock()
            current += 1
            peak = max(peak, current)
            order.append(label)
            lock.unlock()
        }

        func leave() {
            lock.lock()
            current -= 1
            lock.unlock()
        }
    }

    /// Section 6.2: "the agent runs at most four at once per location ... and holds the
    /// rest with their XPC calls open". Six arrive; four run, two wait.
    func testFourRunAtOnceAndTheRestWait() async throws {
        let scheduler = TransferScheduler(locationID: "test")
        let gate = Gate()
        let concurrency = Concurrency()

        let started = expectation(description: "four started")
        started.expectedFulfillmentCount = 4
        // The queued two run once the gate opens, so over-fulfilment is expected.
        started.assertForOverFulfill = false
        var tasks: [Task<Void, Error>] = []
        for index in 0..<6 {
            tasks.append(
                Task {
                    try await scheduler.run(transferID: "t\(index)", kind: .foreground) { _ in
                        concurrency.enter("t\(index)")
                        started.fulfill()
                        await gate.wait()
                        concurrency.leave()
                    }
                })
        }
        await fulfillment(of: [started], timeout: 5)

        let midway = await scheduler.stats()
        XCTAssertEqual(midway.running, 4, "section 6.2's four")
        XCTAssertEqual(midway.waitingForeground, 2)
        XCTAssertEqual(concurrency.peak, 4)
        XCTAssertEqual(
            midway.overCeilingAdmissions, 0,
            "four running plus two waiting is exactly the six-fetch ceiling, not above it")

        await gate.release()
        for task in tasks { try await task.value }
        let final = await scheduler.stats()
        XCTAssertEqual(final.running, 0)
        XCTAssertEqual(final.admitted, 6)
        XCTAssertEqual(final.peakRunning, 4)
    }

    /// "Background transfers ... start only while no foreground transfer is waiting, and
    /// a running one is never pre-empted, so a double-click during a 50 GB pin waits for
    /// at most one background transfer's share of the window rather than for the pin."
    func testForegroundJumpsAheadOfQueuedBackground() async throws {
        let scheduler = TransferScheduler(locationID: "test")
        let concurrency = Concurrency()

        // Four background transfers fill every slot, each on a gate of its own so exactly
        // one slot can be freed. Releasing all four at once was the old shape of this
        // test, and it raced: with four slots free both queued transfers are admitted and
        // which of their bodies reaches `enter` first is the executor's business, not the
        // scheduler's. One slot means only one can be admitted, and the class is then the
        // only thing that can choose (2026-09-04).
        let holders = (0..<4).map { _ in Gate() }
        let running = expectation(description: "four background running")
        running.expectedFulfillmentCount = 4
        running.assertForOverFulfill = false
        var tasks: [Task<Void, Error>] = []
        for index in 0..<4 {
            let holder = holders[index]
            tasks.append(
                Task {
                    try await scheduler.run(transferID: "bg\(index)", kind: .background) { _ in
                        running.fulfill()
                        await holder.wait()
                    }
                })
        }
        await fulfillment(of: [running], timeout: 5)

        // Now a background and a foreground both queue up. Order of arrival is background
        // first, so only the class can put the foreground in front.
        let queued = Gate()
        let queuedBackground = Task {
            try await scheduler.run(transferID: "bg-late", kind: .background) { _ in
                concurrency.enter("background")
                await queued.wait()
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let foreground = Task {
            try await scheduler.run(transferID: "fg", kind: .foreground) { _ in
                concurrency.enter("foreground")
                await queued.wait()
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let waiting = await scheduler.stats()
        XCTAssertEqual(waiting.waitingForeground, 1)
        XCTAssertEqual(waiting.waitingBackground, 1)

        // Free exactly one slot. Only one of the two waiting transfers can be admitted,
        // so the assertion is about the scheduler's choice and about nothing else.
        await holders[0].release()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            concurrency.order, ["foreground"],
            "a queued foreground transfer is admitted before a queued background one")

        for holder in holders.dropFirst() { await holder.release() }
        await queued.release()
        for task in tasks { try await task.value }
        try await queuedBackground.value
        try await foreground.value
    }

    /// "splits the pipelined window between them". Sixteen requests, four transfers,
    /// four each; never below two, so a fifth would still pipeline.
    func testWindowIsSplitBetweenRunningTransfers() async throws {
        let scheduler = TransferScheduler(locationID: "test")
        let gate = Gate()
        let shares = Concurrency()
        let observed = ObservedShares()

        let started = expectation(description: "started")
        started.expectedFulfillmentCount = 4
        started.assertForOverFulfill = false
        var tasks: [Task<Void, Error>] = []
        for index in 0..<4 {
            tasks.append(
                Task {
                    try await scheduler.run(transferID: "t\(index)", kind: .foreground) { window in
                        observed.add(window)
                        shares.enter("t\(index)")
                        started.fulfill()
                        await gate.wait()
                    }
                })
        }
        await fulfillment(of: [started], timeout: 5)
        // The first gets the whole window, the fourth a quarter of it: the share is
        // computed at admission and a running transfer is never re-sized. Compared sorted,
        // because the shares are handed out in a defined order but four concurrent bodies
        // record them in whatever order the executor runs them, which used to make this
        // assertion flaky in its own right (2026-09-04).
        XCTAssertEqual(observed.values.sorted(), [4, 5, 8, 16])
        XCTAssertTrue(observed.values.allSatisfy { $0 >= 2 })
        await gate.release()
        for task in tasks { try await task.value }
    }

    /// A `MaxSessions 2` location shares the metadata channel, so a transfer takes half
    /// the pipeline and leaves the rest of the channel's request slots for the metadata
    /// calls that are served ahead of it.
    func testDegradedLocationHalvesTheWindow() async throws {
        let scheduler = TransferScheduler(locationID: "test", sharesMetadataChannel: true)
        let observed = ObservedShares()
        try await scheduler.run(transferID: "t", kind: .foreground) { window in
            observed.add(window)
        }
        XCTAssertEqual(observed.values, [8])
    }

    /// A metadata call is never queued, even with every transfer slot full: on a degraded
    /// location it is what has to get through (section 6.2).
    func testMetadataIsNeverQueued() async throws {
        let scheduler = TransferScheduler(locationID: "test", sharesMetadataChannel: true)
        let gate = Gate()
        var tasks: [Task<Void, Error>] = []
        let running = expectation(description: "full")
        running.expectedFulfillmentCount = 4
        running.assertForOverFulfill = false
        for index in 0..<4 {
            tasks.append(
                Task {
                    try await scheduler.run(transferID: "t\(index)", kind: .foreground) { _ in
                        running.fulfill()
                        await gate.wait()
                    }
                })
        }
        await fulfillment(of: [running], timeout: 5)

        var answered = false
        _ = try await scheduler.run(transferID: "meta", kind: .metadata) { _ in answered = true }
        XCTAssertTrue(answered, "a metadata call goes straight through a full scheduler")

        await gate.release()
        for task in tasks { try await task.value }
    }

    /// Cancelling the extension's `Progress` cancels a queued transfer without it ever
    /// touching the server (section 5.2).
    func testCancellingAQueuedTransferNeverRunsIt() async throws {
        let scheduler = TransferScheduler(locationID: "test")
        let gate = Gate()
        var tasks: [Task<Void, Error>] = []
        let running = expectation(description: "full")
        running.expectedFulfillmentCount = 4
        running.assertForOverFulfill = false
        for index in 0..<4 {
            tasks.append(
                Task {
                    try await scheduler.run(transferID: "t\(index)", kind: .foreground) { _ in
                        running.fulfill()
                        await gate.wait()
                    }
                })
        }
        await fulfillment(of: [running], timeout: 5)

        let ran = Concurrency()
        let queued = Task {
            try await scheduler.run(transferID: "doomed", kind: .foreground) { _ in
                ran.enter("doomed")
            }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        await scheduler.cancel(transferID: "doomed")

        do {
            try await queued.value
            XCTFail("a cancelled transfer must not succeed")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(ran.order.isEmpty, "it never started")

        await gate.release()
        for task in tasks { try await task.value }
    }

    /// Cancelling a *running* transfer cancels its Task, and the wire client's own
    /// cancellation check is what turns that into `.cancelled` (section 6.2). Here the
    /// body stands in for the client and reports what it saw.
    func testCancellingARunningTransferCancelsItsTask() async throws {
        let scheduler = TransferScheduler(locationID: "test")
        let sawCancellation = Concurrency()
        let task = Task {
            try await scheduler.run(transferID: "live", kind: .foreground) { _ in
                for _ in 0..<200 {
                    if Task.isCancelled {
                        sawCancellation.enter("cancelled")
                        throw SFTPError.cancelled
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        await scheduler.cancel(transferID: "live")
        do {
            try await task.value
            XCTFail("a cancelled transfer must not succeed")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(sawCancellation.order, ["cancelled"])
        let stats = await scheduler.stats()
        XCTAssertEqual(stats.running, 0, "the slot is given back")
    }

    /// A seventh transfer is admitted rather than refused - the six-fetch ceiling is an
    /// observation, not a contract - and counted, so `status` can say the observation
    /// stopped holding.
    func testASeventhIsCountedRatherThanRefused() async throws {
        let scheduler = TransferScheduler(locationID: "test")
        let gate = Gate()
        var tasks: [Task<Void, Error>] = []
        let running = expectation(description: "started")
        running.expectedFulfillmentCount = 4
        running.assertForOverFulfill = false
        for index in 0..<7 {
            tasks.append(
                Task {
                    try await scheduler.run(transferID: "t\(index)", kind: .foreground) { _ in
                        running.fulfill()
                        await gate.wait()
                    }
                })
        }
        await fulfillment(of: [running], timeout: 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        let stats = await scheduler.stats()
        XCTAssertEqual(stats.running, 4)
        XCTAssertEqual(stats.waitingForeground, 3)
        XCTAssertGreaterThanOrEqual(stats.overCeilingAdmissions, 1)
        await gate.release()
        for task in tasks { try await task.value }
    }

    /// End to end against the milestone 1 fake backend: eight files, all fetched through
    /// the scheduler, every byte delivered, never more than four transfers in flight.
    func testTheFakeBackendStreamsThroughTheScheduler() async throws {
        let transport = FakeTransport(root: "/srv/fake")
        for index in 0..<8 {
            try await transport.write(
                try RelativePath(string: "f\(index).bin"),
                contents: Data(repeating: UInt8(index), count: 300_000), mode: 0o644)
        }
        let scheduler = TransferScheduler(locationID: "fake")
        let totals = ObservedShares()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let path = try RelativePath(string: "f\(index).bin")
                    let counter = ByteCounter()
                    try await scheduler.run(transferID: "t\(index)", kind: .foreground) { window in
                        _ = try await transport.readStreaming(
                            path, offset: 0, length: nil, window: window
                        ) { _, data in counter.add(data.count) }
                    }
                    totals.add(counter.total)
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(totals.values.count, 8)
        XCTAssertTrue(totals.values.allSatisfy { $0 == 300_000 }, "every byte arrived")
        let stats = await scheduler.stats()
        XCTAssertEqual(stats.admitted, 8)
        XCTAssertLessThanOrEqual(stats.peakRunning, 4)
    }
}

/// Collects integers from concurrent bodies.
final class ObservedShares: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    func add(_ value: Int) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add(_ bytes: Int) {
        lock.lock()
        count += bytes
        lock.unlock()
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
