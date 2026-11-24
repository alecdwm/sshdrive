import XCTest
@testable import SSHProcess

/// Every child `Spawn.run` starts is reaped when it exits, whether or not its owner ever
/// asks, and the exit it had is still what `poll` and `wait` report afterwards.
final class SpawnReapingTests: XCTestCase {

    private func spawn(_ script: String, newProcessGroup: Bool = false) throws -> SpawnedProcess {
        try Spawn.run(
            executable: "/bin/sh", argv: ["/bin/sh", "-c", script],
            environment: ProcessInfo.processInfo.environment,
            stdinFromDevNull: true, newProcessGroup: newProcessGroup)
    }

    /// A zombie still answers `kill(pid, 0)`; only a reaped pid is `ESRCH`.
    private func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            usleep(20_000)
        }
        return false
    }

    func testAChildNobodyPollsIsReapedAndKeepsItsStatus() throws {
        let process = try spawn("exit 7")
        XCTAssertTrue(waitUntilGone(process.pid), "an exited child nobody waited on is not left a zombie")
        // The pid is free a moment before the reaper stores the exit, so wait for that first.
        XCTAssertEqual(Spawn.wait(pid: process.pid), ProcessExit(status: 7), "a late wait reads the real exit")
        XCTAssertEqual(Spawn.poll(pid: process.pid), ProcessExit(status: 7))
        XCTAssertEqual(process.poll(), ProcessExit(status: 7))
    }

    func testATerminatedChildNobodyPollsIsReaped() throws {
        let process = try spawn("exec sleep 30")
        XCTAssertNil(process.poll())
        Spawn.terminate(process, grace: 0.5)
        XCTAssertTrue(waitUntilGone(process.pid), "terminate's target is reaped without anyone polling it")
        XCTAssertEqual(process.wait().signal, SIGTERM)
    }

    func testASignalDeathReportsTheSignal() throws {
        let process = try spawn("exec sleep 30")
        kill(process.pid, SIGKILL)
        XCTAssertEqual(process.wait(), ProcessExit(status: -1, signal: SIGKILL))
    }

    func testPollingTwiceKeepsTheExit() throws {
        let process = try spawn("exit 3")
        let first = process.wait()
        XCTAssertEqual(first, ProcessExit(status: 3))
        XCTAssertEqual(Spawn.poll(pid: process.pid), first, "a second reader does not get ECHILD's -1")
    }

    func testCaptureStillReportsTheExitStatus() throws {
        let result = try Spawn.capture(
            executable: "/bin/sh", argv: ["/bin/sh", "-c", "echo out; echo err >&2; exit 5"],
            environment: ProcessInfo.processInfo.environment, timeout: 5)
        XCTAssertEqual(result.exit, ProcessExit(status: 5))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err\n")
    }
}
