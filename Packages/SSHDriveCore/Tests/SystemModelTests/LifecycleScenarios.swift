import XCTest
import Config
import Index
import ProviderCore
import SystemModel

/// **Suite C - extension lifecycle**, the system half of **suite P - packaging and
/// lifecycle**, and `H9`'s system half (`docs/testing-architecture.md` section 5).
///
/// `P1` and `P2` have an agent-side row each in `Tests/AgentRuntimeTests`, asserting what
/// the *agent* decides against `FakeLoginItem`/`FakeLaunchd`. These are the other half:
/// what launchd and `SMAppService` actually do, which is what makes those decisions
/// necessary. The two must agree, and they are keyed on the same `MQ-062` and `MQ-063`.
final class LifecycleScenarios: XCTestCase {

    // MARK: C1 - disconnect-in-invalidation

    /// A provider instance with a live agent channel, killed while idle.
    ///
    /// `MQ-073`: the system kills an idle instance and the extension's XPC connection
    /// invalidates **as part of that teardown**, so an invalidation handler cannot be read
    /// as "the agent has gone". The domain must not be disconnected, and the next
    /// instance's `indexReady` calls `reconnect()` unconditionally - because the
    /// disconnect outlives the instance that made it (`MQ-074`).
    func testC1_KillingAnIdleInstanceDoesNotDisconnectTheDomain() throws {
        let harness = try ScenarioHarness()
        try harness.serverCreates("a.txt")
        let domain = try harness.addDomain()
        domain.openFolder()

        domain.killIdleInstance()
        XCTAssertFalse(domain.isDisconnected, "MQ-073: an invalidation is not a missing agent")

        // The next call brings up a fresh instance, which lifts anything left behind.
        domain.signalWorkingSet()
        XCTAssertFalse(domain.isDisconnected)
        XCTAssertTrue(domain.calls.contains(.reconnect), "MQ-074: unconditionally")
        XCTAssertEqual(harness.finderListing(), ["a.txt"])
    }

    /// **The bite-proof.** The one line version 0.1.0 had: the invalidation handler called
    /// `noteAgentUnreachable()`, which is the extension's own `disconnect(reason:)`.
    ///
    /// `MQ-040`: the domain goes permanently disconnected. `MQ-041`: the replica listing
    /// and a queued write survive it, so nothing looks broken - and every fetch fails for
    /// good, which is exactly how it shipped. `MQ-074`: only a fresh instance's
    /// `indexReady` lifts it, which is why the reconnect call may not be conditional.
    func testC1_TheOldInvalidationHandlerDisconnectedTheDomainForGood() throws {
        let harness = try ScenarioHarness()
        try harness.serverCreates("a.txt")
        let domain = try harness.addDomain()
        domain.openFolder()

        // The 0.1.0 teardown, written out: the handler ran on the way out.
        domain.provider?.noteAgentUnreachable()
        domain.killIdleInstance()

        XCTAssertTrue(domain.isDisconnected, "MQ-040: state 4, from inside the extension")
        XCTAssertEqual(
            harness.finderListing(), ["a.txt"], "MQ-041: and the listing survives, so it looks fine")
        XCTAssertEqual(
            domain.disconnectReason, ProviderService.agentMissingMessage,
            "with a sentence about an agent that is running perfectly well")
    }

    // MARK: C2 - a reader error is `.serverUnreachable`

    /// The index made unreadable - a reconcile in progress is the real case - with the
    /// agent unreachable too.
    ///
    /// `.serverUnreachable`, **never** `.noSuchItem`: `MQ-011` says the system reads that
    /// from `item(for:)` as "the item was deleted" and deletes the user's file. The
    /// replica keeps it.
    func testC2_AnUnreadableIndexIsServerUnreachableAndNeverNoSuchItem() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("keep.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        XCTAssertEqual(harness.finderListing(), ["keep.txt"])

        try harness.writer.setReconciling(true)
        harness.agent.isReachable = false
        let answer = domain.item(for: harness.id(file))

        guard case .failure(let failure) = answer else {
            return XCTFail("a reader that cannot answer must not succeed")
        }
        XCTAssertEqual(failure, .serverUnreachable)
        XCTAssertNotEqual(failure, .noSuchItem, "MQ-011: that would take the user's file")
        XCTAssertEqual(harness.finderListing(), ["keep.txt"], "which is still there")
    }

    // MARK: H9 - a CLI command is a touch

    /// A location watched only from a terminal.
    ///
    /// `MQ-001` and `MQ-039` between them are why section 6.5 has to count a CLI command
    /// as a touch: a folder is enumerated **once, ever**, and a `readdir`/`lstat` walk is
    /// answered from the replica and reaches the extension **not at all**. So a person can
    /// browse a mount all day and nothing in the system tells the agent that anyone is
    /// looking - the `viewed` reason has no other source.
    func testH9_LookingAtAMountTellsTheAgentNothing() throws {
        let harness = try ScenarioHarness()
        let folder = try harness.serverCreatesDirectory("Documents")
        try harness.serverCreates("deep.txt", in: folder)
        let domain = try harness.addDomain()
        harness.finder.open()
        harness.finder.open(harness.id(folder))
        // Past the trash question the system asks itself at mount time (`MQ-010`), which
        // is the only other thing that reaches the extension on a quiet domain.
        harness.system.advance(5)
        domain.resetCalls()
        harness.agent.resetCalls()

        for _ in 0..<20 {
            harness.finder.open()
            harness.finder.open(harness.id(folder))
            _ = harness.finder.walk()
            harness.system.advance(30)
        }

        XCTAssertEqual(domain.calls, [], "MQ-001, MQ-039: not one call in ten minutes of looking")
        XCTAssertEqual(harness.agent.calls, [], "so the agent cannot know the location is viewed")
        XCTAssertEqual(harness.finder.walk().count, 2, "while the walk answers in full")
    }

    // MARK: P5 - `add(domain)` 4099 after landing

    /// A replica that reports `NSCocoaErrorDomain` 4099 *after* the call succeeded
    /// (`MQ-052`).
    ///
    /// The domain list is re-read before the error is believed, and the discrepancy is
    /// logged: the domain is there, the mount is there, and treating the error as a
    /// failure would remove a working location.
    func testP5_A4099AfterLandingIsCheckedAgainstTheDomainList() throws {
        let harness = try ScenarioHarness()
        harness.system.launchd.installBundle(quarantined: false)
        harness.system.launchd.launchApp()
        harness.system.nextAddReportsError = FileProviderD.DomainError(
            domain: "NSCocoaErrorDomain", code: 4099,
            message: "connection to service named com.apple.FileProvider was invalidated",
            landedAnyway: true)

        var reported: FileProviderD.DomainError?
        do {
            _ = try harness.addDomain()
        } catch let error as FileProviderD.DomainError {
            reported = error
        }
        let error = try XCTUnwrap(reported)
        XCTAssertEqual(error.code, 4099)
        XCTAssertTrue(
            harness.system.domainList().contains(harness.locationID),
            "MQ-052: the domain is there; the error is about the connection, not the domain")
    }

    // MARK: P8 - a nickname renames in place

    /// Four materialized items and one pending upload, then `set nickname`.
    ///
    /// `MQ-051`: `add(domain)` with an identifier the system already holds and a new
    /// display name **renames the domain in place**. The mount directory moves; the
    /// materialized set and the pending upload are unchanged, nothing is re-fetched, and
    /// the pending write still flushes afterwards.
    func testP8_ANicknameRenamesInPlaceAndKeepsTheCacheAndTheQueue() throws {
        let harness = try ScenarioHarness()
        var files: [String] = []
        for index in 0..<4 { files.append(try harness.serverCreates("m\(index).txt")) }
        let pendingFile = try harness.serverCreates("edit.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        for file in files { harness.finder.read(harness.id(file)) }
        harness.finder.read(harness.id(pendingFile))
        harness.agent.isReachable = false
        harness.finder.save(harness.id(pendingFile))
        let fetchesBefore = domain.fetchesIssued.count
        XCTAssertEqual(domain.replica.downloadedCount, 5)
        XCTAssertEqual(domain.pendingIdentifiers, [harness.id(pendingFile)])

        let renamed = try harness.addDomain(nickname: "nas-renamed")
        XCTAssertTrue(renamed === domain, "the same domain, renamed")
        XCTAssertEqual(renamed.mountDirectoryName, "SSHDrive-nas-renamed")
        XCTAssertTrue(
            domain.calls.contains(.domainRenamedInPlace(from: "nas", to: "nas-renamed")))
        XCTAssertEqual(domain.replica.downloadedCount, 5, "MQ-051: the materialized set is untouched")
        XCTAssertEqual(domain.fetchesIssued.count, fetchesBefore, "and nothing was re-fetched")
        XCTAssertEqual(domain.pendingIdentifiers, [harness.id(pendingFile)])

        // And the write still flushes when the connection comes back.
        harness.agent.isReachable = true
        domain.signalErrorResolved(.serverUnreachable)
        harness.system.advance(0.05)
        XCTAssertFalse(domain.hasPendingWrites)
    }

    // MARK: P1 - the login item after a bundle replacement

    /// A registered job whose bundle is deleted and replaced - which is what an upgrade
    /// does to the app underneath a running login item.
    ///
    /// `MQ-062`: `register()` **does not repair** it. It returns success, `status` keeps
    /// saying `enabled`, and every spawn fails on a 10 s throttle for ever. Only
    /// `unregister()` followed by a launch clears it, which is why the handover waits for
    /// a whole one rather than calling `register()` again.
    func testP1_RegisterAloneDoesNotRepairAReplacedBundle() throws {
        let harness = try ScenarioHarness()
        let launchd = harness.system.launchd
        launchd.installBundle(quarantined: false)
        launchd.launchApp()
        launchd.register()
        XCTAssertTrue(launchd.agentIsRunning)
        XCTAssertEqual(launchd.loginItemStatus, "enabled")

        launchd.replaceBundle()
        XCTAssertTrue(launchd.isSpawningAndDying)
        XCTAssertFalse(launchd.agentIsRunning)

        launchd.register()
        harness.system.advance(60)
        XCTAssertEqual(launchd.loginItemStatus, "enabled", "MQ-062: it keeps returning success")
        XCTAssertTrue(launchd.isSpawningAndDying, "while nothing works")
        XCTAssertGreaterThan(launchd.spawnFailures, 4, "on a 10 s throttle, for ever")

        // The handover: unregister, wait for launchd to drop it, then register.
        launchd.unregister()
        launchd.waitForServiceToBeDropped()
        launchd.register()
        XCTAssertFalse(launchd.isSpawningAndDying)
        XCTAssertTrue(launchd.agentIsRunning)
    }

    // MARK: P2 - `unregister` waits for launchd

    /// A job launchd has not yet dropped, and a back-to-back unregister/register.
    ///
    /// `MQ-063`: `unregister()` returns - and `status` says `notRegistered` - **before**
    /// launchd has dropped the job. A `register()` inside that window leaves the job
    /// carrying the previous bundle's launch constraint, dying `EXC_CRASH (SIGKILL (Code
    /// Signature Invalid))` on a 10 s retry, for ever, with the mach service accepting
    /// connections and answering nothing. Polling `launchctl print` until the service is
    /// gone is the whole of the fix.
    func testP2_ARegisterInsideTheUnregisterWindowLeavesAJobDyingForEver() throws {
        let harness = try ScenarioHarness()
        let launchd = harness.system.launchd
        launchd.installBundle(quarantined: false)
        launchd.launchApp()
        launchd.register()
        launchd.replaceBundle()

        launchd.unregister()
        XCTAssertEqual(launchd.loginItemStatus, "not registered", "and yet:")
        XCTAssertTrue(launchd.serviceIsLoaded, "MQ-063: launchd has not dropped the job")

        launchd.register()
        harness.system.advance(60)
        XCTAssertTrue(
            launchd.isSpawningAndDying,
            "MQ-063: the job carries the previous bundle's launch constraint")
        XCTAssertGreaterThan(launchd.spawnFailures, 4)

        // The role the CLI's unregister step plays: poll launchd, not `SMAppService`.
        launchd.unregister()
        let waited = launchd.waitForServiceToBeDropped()
        XCTAssertGreaterThan(waited, 0, "it really waited")
        XCTAssertFalse(launchd.serviceIsLoaded)
        launchd.register()
        harness.system.advance(60)
        XCTAssertFalse(launchd.isSpawningAndDying)
        XCTAssertEqual(launchd.spawnFailures, 0, "a job that spawns once and stays")
    }

    // MARK: P3 - a quarantined bundle registers no plugin

    /// The quarantine xattr present on the installed app, on the version it was measured
    /// on.
    ///
    /// `MQ-061`: LaunchServices registers **no plugin** of a quarantined bundle that no
    /// person has launched - `pluginkit -m` prints nothing and `fileproviderd` answers
    /// `FP -2001 / Underlying FP -2014` - so `add(domain)` cannot work and `doctor`'s
    /// quarantine check has to come ahead of "extension registered". `xattr -dr` then
    /// `open -g` is the durable order, and `open -g` is not an assessed launch.
    func testP3_AQuarantinedBundleRegistersNoPluginUntilItIsStripped() throws {
        let harness = try ScenarioHarness(macOS: .v26_6)
        let launchd = harness.system.launchd
        launchd.installBundle(quarantined: true)
        launchd.launchApp()

        XCTAssertEqual(launchd.pluginKitListing, [], "MQ-061: pluginkit prints nothing")
        XCTAssertFalse(launchd.providerPluginIsRegistered)
        do {
            _ = try harness.addDomain()
            XCTFail("a domain cannot come up without the appex")
        } catch let error as FileProviderD.DomainError {
            XCTAssertEqual(error.code, -2001, "MQ-061: FP -2001, underlying FP -2014")
        }

        // The postflight's order: assess, strip, then launch.
        launchd.stripQuarantine()
        launchd.launchApp()
        XCTAssertEqual(launchd.pluginKitListing, ["org.shirls.sshdrive.fileprovider"])
        let domain = try harness.addDomain()
        XCTAssertTrue(harness.system.domainList().contains(domain.identifier))
    }

    /// The same install on **26.4**, where a quarantined fresh-user install had passed.
    ///
    /// This is what a per-version quirk column is for: `MQ-061` holds a different value in
    /// each column, the model branches on it, and neither measurement is thrown away.
    /// Which half of the difference matters is not claimed anywhere.
    func testP3_TheSameInstallOn26_4TookThePluginRegistrationAnyway() throws {
        let harness = try ScenarioHarness(macOS: .v26_4)
        let launchd = harness.system.launchd
        launchd.installBundle(quarantined: true)
        launchd.launchApp()

        XCTAssertTrue(
            launchd.providerPluginIsRegistered,
            "MQ-061 on 26.4: the quarantined fresh-user install passed")
        XCTAssertNoThrow(try harness.addDomain())
    }
}
