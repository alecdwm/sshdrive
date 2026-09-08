import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Testing
import XPCProtocols

/// Suite P on the agent's side: the login item after a bundle replacement, the window
/// `unregister()` returns inside, and the nickname that renames a domain in place
/// (`docs/testing-architecture.md` section 5).
///
/// These are the `VM`-anchored ones. What runs here is the **state machine** our code
/// reasons about; that LaunchServices and `SMAppService` really behave this way is
/// `MQ-062`/`MQ-063`, measured on the VM (2026-09-05) and recorded in `docs/quirks/`.
extension AgentScenarios {

    @Suite struct LifecycleScenarios {

        /// **P1** - the login item after a replacement.
        ///
        /// Registration is idempotent but not self-repairing: once the bundle has been deleted
        /// and put back (a Homebrew upgrade, or any `rm -rf` plus copy), launchd's
        /// background-task record still names the old bundle and every spawn fails with "Could
        /// not find and/or execute program specified by service", while `register()` keeps
        /// returning success because the item is still, as far as it is concerned, enabled.
        /// Only `unregister()` clears the record.
        @Test func p1RegisterAloneDoesNotRepairAReplacedBundle() async {
            let loginItem = FakeLoginItem()
            let launchd = FakeLaunchd()
            let clock = VirtualAgentClock(autoAdvance: true)

            AgentLifecycle.register(loginItem: loginItem)
            #expect(loginItem.status() == "enabled")

            loginItem.markBundleReplaced()
            AgentLifecycle.register(loginItem: loginItem)
            #expect(loginItem.status() == "enabled", "P1: it still *says* enabled")
            #expect(loginItem.isBroken, "P1: register() alone does not repair it")

            let outcome = await AgentLifecycle.unregisterAndWait(
                loginItem: loginItem, launchd: launchd, uid: 501, clock: clock)
            #expect(outcome.unregistered)
            #expect(!loginItem.isBroken, "P1: only the unregister path clears the record")
            AgentLifecycle.register(loginItem: loginItem)
            #expect(loginItem.status() == "enabled")
            #expect(loginItem.calls == [.register, .register, .unregister, .register])
        }

        /// **P2** - `unregister` waits for launchd.
        ///
        /// `unregister()` returns, and `SMAppService.status` reports `notRegistered`, before
        /// launchd has dropped the job. A `register()` that lands inside that window leaves the
        /// job holding a launch constraint captured from the previous bundle's signature: every
        /// spawn dies with `Launch Constraint Violation`, launchd retries on a 10 s throttle for
        /// ever, and the mach service never comes back. `SMAppService.status` cannot see this,
        /// so the job itself is asked - `launchctl print` answers non-zero once it is gone.
        @Test func p2TheUnregisterRolePollsUntilTheJobIsGone() async {
            let loginItem = FakeLoginItem()
            let launchd = FakeLaunchd(probesBeforeGone: 7)
            let clock = VirtualAgentClock(autoAdvance: true)

            let outcome = await AgentLifecycle.unregisterAndWait(
                loginItem: loginItem, launchd: launchd, uid: 501, clock: clock)
            #expect(outcome.unregistered)
            #expect(outcome.gone, "P2: it waited for launchd, not for SMAppService")
            #expect(launchd.probes == 8, "seven answers of yes, then the one that says no")
            #expect(
                loginItem.status() == "not registered",
                "the status said this from the first probe, which is exactly why it is not the test")

            // And it gives up rather than blocking the cask's postflight for ever.
            let stuck = FakeLaunchd(probesBeforeGone: 10_000)
            let slow = await AgentLifecycle.unregisterAndWait(
                loginItem: FakeLoginItem(), launchd: stuck, uid: 501, clock: clock, attempts: 150)
            #expect(slow.unregistered)
            #expect(!slow.gone, "P2: 30 s and then it says so")
            #expect(stuck.probes == 150)
        }

        /// **P1**, the other half - the upgrade handover never takes a half-copied bundle.
        ///
        /// Section 10.1: the agent waits until the bundle at its path is readable, its
        /// `Info.plist` parses, and its main executable is a **different inode** from the one it
        /// is running. The inode test is what makes a `brew reinstall` of the same version
        /// terminate: `ditto` of an identical tree still produces a new file.
        @Test func p1TheHandoverWaitsForAWholeBundle() async {
            let bundle = FakeBundle()
            let executable = bundle.executableURL
            let bundlePath = AgentLifecycle.bundleURL(forExecutable: executable)
            bundle.setInode(1000, atPath: executable.path)

            // Same inode: nothing has been replaced.
            #expect(
                !AgentLifecycle.replacementIsReady(
                    executable: executable, bundle: bundlePath, originalInode: 1000,
                    inspector: bundle))

            // A new inode, but the Info.plist is not there yet - the copy is half done.
            bundle.setInode(1001, atPath: executable.path)
            #expect(
                !AgentLifecycle.replacementIsReady(
                    executable: executable, bundle: bundlePath, originalInode: 1000,
                    inspector: bundle))

            // Someone else's bundle at our path is not ours to hand over to.
            bundle.setBundleIdentifier("com.example.other", atPath: bundlePath.path)
            #expect(
                !AgentLifecycle.replacementIsReady(
                    executable: executable, bundle: bundlePath, originalInode: 1000,
                    inspector: bundle))

            bundle.setBundleIdentifier(SSHDriveIdentifiers.appBundleID, atPath: bundlePath.path)
            #expect(
                AgentLifecycle.replacementIsReady(
                    executable: executable, bundle: bundlePath, originalInode: 1000,
                    inspector: bundle))
        }

        /// **P8** - a nickname renames the domain in place.
        ///
        /// S9 (2026-09-05): `add(domain)` with the identifier the system already holds and a new
        /// `displayName` renames the domain in place (`MQ-051`). Nothing is removed first -
        /// deliberately, since removing the domain is exactly what would throw the cache and the
        /// pending uploads away - so the materialized set and the pending upload are untouched
        /// and nothing is re-fetched.
        @Test func p8ANicknameRenamesTheDomainInPlace() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas")
            _ = try await harness.manager.runtime(for: location)
            try await harness.manager.addDomain(for: location)

            harness.replica.setMaterialized(["item-1", "item-2", "item-3", "item-4"],
                                            locationID: location.id)
            harness.replica.setPending(["item-5"], locationID: location.id)
            harness.replica.resetCalls()

            let report = try await harness.control(
                "set", ["name": "nas", "key": "nickname", "value": "photos"])
            #expect(report["changed"] as? Bool == true)
            #expect(report["name"] as? String == "photos")

            let domains = harness.replica.domainList
            #expect(domains.count == 1, "P8: one domain, renamed - not removed and re-added")
            #expect(domains.first?.identifier == location.id, "P8: the same identifier")
            #expect(domains.first?.displayName == "photos")
            #expect(
                !harness.replica.calls.contains { if case .removeDomain = $0 { return true } else { return false } },
                "P8: nothing is removed first, which is what keeps the cache")

            let materialized = await harness.replica.materializedIdentifiers(locationID: location.id)
            #expect(materialized?.count == 4, "P8: the materialized set is unchanged")
            let pending = await harness.replica.pendingIdentifiers(locationID: location.id)
            #expect(pending == ["item-5"], "P8: the pending upload is still pending")
            await harness.manager.dropRuntime(locationID: location.id)
        }
    }
}
