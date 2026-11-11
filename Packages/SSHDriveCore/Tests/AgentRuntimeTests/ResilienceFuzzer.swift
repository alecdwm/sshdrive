import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Foundation
import ServerModel
import Testing

/// The resilience fuzzer: for each seed, a random but reproducible sequence of faults,
/// server-side changes and user touches, then every fault lifted, the quiet period, and
/// `converged()`.
///
/// The seeds are fixed, so a run is the same run every time up to the agent's own
/// scheduling and the breaker's jitter (which draws from the system generator and cannot
/// be seeded from here). `SSHDRIVE_RESILIENCE_SEEDS=<n>` runs seeds 1 to n instead of the
/// default list, and `SSHDRIVE_RESILIENCE_SEED=<seed>` runs that one seed. A failure
/// prints the seed and the steps it drew, which is all a replay needs.
extension AgentScenarios.ResilienceScenarios {

    // MARK: Seeds

    static let defaultFuzzSeeds: [UInt64] = Array(1 ... 25)

    static var fuzzSeeds: [UInt64] {
        let environment = ProcessInfo.processInfo.environment
        if let one = environment["SSHDRIVE_RESILIENCE_SEED"].flatMap(UInt64.init) { return [one] }
        if let count = environment["SSHDRIVE_RESILIENCE_SEEDS"].flatMap(UInt64.init), count > 0 {
            return Array(1 ... count)
        }
        return defaultFuzzSeeds
    }

    /// SplitMix64: small, fast and the same on every platform, which is the whole point.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: Steps

    /// One step of a fuzzed sequence. Durations are virtual seconds.
    enum FuzzStep: CustomStringConvertible, Sendable {
        /// The Wi-Fi drops, the path following it.
        case pathBlip(seconds: Double)
        /// The link dies with the path still up; `lifted` false leaves it down until the
        /// final lift.
        case linkDown(FakeRemoteHost.LinkState, seconds: Double, lifted: Bool)
        /// Every live master dies now.
        case sever
        /// The Mac sleeps for `seconds`, with or without the will-sleep message, and
        /// wakes - with the resolver failing `dnsFailures` times, and with or without a
        /// wake message.
        case sleep(willSleep: Bool, seconds: Double, dnsFailures: Int, wakeMessage: Bool)
        /// `sshd` restarts: the masters die and connects are refused for `seconds`.
        case sshdRestart(seconds: Double)
        /// The server reboots: `sshd` down, the helper's cache emptied, the root missing
        /// for a while after `sshd` is back.
        case reboot(down: Double, rootMissing: Double)
        /// TCP accepted, no banner, for `seconds`.
        case bannerHang(seconds: Double, lifted: Bool)
        case killHelper
        /// Every helper started from now on takes this long to say `ready`, until the
        /// final lift; the running one is killed so the next start meets it.
        case slowReady(seconds: Double)
        /// Helpers never say `ready` for `seconds`; the running one is killed.
        case helperNeverReady(seconds: Double)
        /// The running helper goes silent for good.
        case freezeHelper
        /// The next server probe stalls; the connection is severed so a reconnect meets it.
        case probeStall
        /// The channel probe's SFTP channel `ordinal` stalls on every connect for
        /// `seconds`; the connection is severed so a reconnect meets it.
        case channelProbeStall(ordinal: Int, seconds: Double)
        /// Other sessions hold one of the server's sessions for `seconds`, across a
        /// reconnect.
        case sessionsHeld(seconds: Double)
        /// The next sweep hangs in `find` for `seconds`, across a reconnect.
        case sweepStall(seconds: Double)
        /// The next connect is refused authentication.
        case authFailure
        /// The host key is wrong for `seconds`, met on a path change and lifted by one.
        case hostKey(seconds: Double)
        /// The root is missing for `seconds`, with or without a reconnect.
        case rootHidden(seconds: Double, sever: Bool)
        /// The disk is full for `seconds` while the helper has to be uploaded again.
        case diskFull(seconds: Double)
        case agentRestart
        /// Asleep ten minutes, and the Mac's wall clock jumps on the way back.
        case clockJump(seconds: Double)
        /// One change on the server: 0 create, 1 edit, 2 delete, 3 rename.
        case serverChange(kind: Int, index: Int)
        /// A File Provider request from the user.
        case touch
        /// Nothing at all for a while.
        case wait(seconds: Double)

        var description: String {
            func s(_ value: Double) -> String { "\(Int(value))s" }
            switch self {
            case let .pathBlip(seconds): return "pathBlip(\(s(seconds)))"
            case let .linkDown(state, seconds, lifted):
                return "linkDown(\(state.rawValue), \(s(seconds))\(lifted ? "" : ", held"))"
            case .sever: return "sever"
            case let .sleep(willSleep, seconds, dns, wake):
                return "sleep(\(willSleep ? "will-sleep" : "no will-sleep"), \(s(seconds)), dns failures \(dns)\(wake ? "" : ", no wake message"))"
            case let .sshdRestart(seconds): return "sshdRestart(\(s(seconds)))"
            case let .reboot(down, missing): return "reboot(down \(s(down)), root missing \(s(missing)))"
            case let .bannerHang(seconds, lifted): return "bannerHang(\(s(seconds))\(lifted ? "" : ", held"))"
            case .killHelper: return "killHelper"
            case let .slowReady(seconds): return "slowReady(\(s(seconds)))"
            case let .helperNeverReady(seconds): return "helperNeverReady(\(s(seconds)))"
            case .freezeHelper: return "freezeHelper"
            case .probeStall: return "probeStall"
            case let .channelProbeStall(ordinal, seconds): return "channelProbeStall(#\(ordinal), \(s(seconds)))"
            case let .sessionsHeld(seconds): return "sessionsHeld(\(s(seconds)))"
            case let .sweepStall(seconds): return "sweepStall(\(s(seconds)))"
            case .authFailure: return "authFailure"
            case let .hostKey(seconds): return "hostKey(\(s(seconds)))"
            case let .rootHidden(seconds, sever): return "rootHidden(\(s(seconds))\(sever ? ", sever" : ""))"
            case let .diskFull(seconds): return "diskFull(\(s(seconds)))"
            case .agentRestart: return "agentRestart"
            case let .clockJump(seconds): return "clockJump(\(s(seconds)))"
            case let .serverChange(kind, index): return "serverChange(\(["create", "edit", "delete", "rename"][kind]) #\(index))"
            case .touch: return "touch"
            case let .wait(seconds): return "wait(\(s(seconds)))"
            }
        }

        /// Whether the step is a refusal: it stops the backoff, and the slow timer (or a
        /// wake, a path change or an unlock) is what retries it.
        var isRefusal: Bool {
            switch self {
            case .authFailure, .hostKey: return true
            default: return false
            }
        }
    }

    /// The step list for one seed.
    static func fuzzSteps(seed: UInt64) -> [FuzzStep] {
        var random = SplitMix64(seed: seed)
        func seconds(_ range: ClosedRange<Double>) -> Double {
            Double(Int.random(in: Int(range.lowerBound) ... Int(range.upperBound), using: &random))
        }
        let count = Int.random(in: 5 ... 15, using: &random)
        var steps: [FuzzStep] = []
        var refusals = 0
        var changes = 0
        while steps.count < count {
            let step: FuzzStep
            switch Int.random(in: 0 ..< 30, using: &random) {
            case 0, 1: step = .pathBlip(seconds: seconds(1 ... 120))
            case 2:
                step = .linkDown(
                    Bool.random(using: &random) ? .unreachable : .blackhole,
                    seconds: seconds(5 ... 300), lifted: Int.random(in: 0 ..< 10, using: &random) < 7)
            case 3, 4: step = .sever
            case 5, 6:
                step = .sleep(
                    willSleep: Int.random(in: 0 ..< 4, using: &random) > 0,
                    seconds: [60, 600, 3600, 4 * 3600, 12 * 3600][Int.random(in: 0 ..< 5, using: &random)],
                    dnsFailures: Int.random(in: 0 ..< 4, using: &random) == 0 ? Int.random(in: 1 ... 3, using: &random) : 0,
                    wakeMessage: Int.random(in: 0 ..< 6, using: &random) > 0)
            case 7: step = .sshdRestart(seconds: seconds(1 ... 60))
            case 8: step = .reboot(down: seconds(10 ... 180), rootMissing: seconds(0 ... 60))
            case 9:
                step = .bannerHang(
                    seconds: seconds(10 ... 180), lifted: Int.random(in: 0 ..< 10, using: &random) < 7)
            case 10: step = .killHelper
            case 11: step = .slowReady(seconds: seconds(1 ... 110))
            case 12: step = .helperNeverReady(seconds: seconds(10 ... 300))
            case 13: step = .freezeHelper
            case 14: step = .probeStall
            case 15: step = .channelProbeStall(ordinal: Int.random(in: 2 ... 3, using: &random), seconds: seconds(10 ... 120))
            case 16: step = .sessionsHeld(seconds: seconds(10 ... 120))
            case 17: step = .sweepStall(seconds: seconds(10 ... 300))
            case 18: step = .authFailure
            case 19: step = .hostKey(seconds: seconds(10 ... 600))
            case 20: step = .rootHidden(seconds: seconds(5 ... 120), sever: Bool.random(using: &random))
            case 21: step = .diskFull(seconds: seconds(10 ... 180))
            case 22: step = .agentRestart
            case 23: step = .clockJump(seconds: Bool.random(using: &random) ? 3600 : -3600)
            case 24, 25, 26:
                changes += 1
                step = .serverChange(kind: Int.random(in: 0 ..< 4, using: &random), index: changes)
            case 27: step = .touch
            default: step = .wait(seconds: seconds(1 ... 300))
            }
            // One refusal per sequence: the slow timer's interval is only promised for the
            // first retry, and a quiet period long enough for a backed-off one would make
            // every such seed cost half an hour.
            if step.isRefusal {
                guard refusals == 0 else { continue }
                refusals += 1
            }
            steps.append(step)
        }
        return steps
    }

    // MARK: Running a step

    /// The server time of everything the sequence did that is owed a connect attempt: a
    /// returning path, a wake, a sever, a restart. The fault phase's effort is judged
    /// against these.
    final class Triggers: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []
        func note(_ harness: ResilienceHarness) { lock.withLock { times.append(harness.host.serverNow) } }
        var all: [Double] { lock.withLock { times } }
    }

    static func perform(_ step: FuzzStep, _ harness: ResilienceHarness, triggers: Triggers) async throws {
        let host = harness.host
        switch step {
        case let .pathBlip(seconds):
            host.setLink(.unreachable)
            try await harness.setNetworkPath(false)
            try await harness.run(for: seconds)
            host.setLink(.up)
            try await harness.setNetworkPath(true)
            triggers.note(harness)
        case let .linkDown(state, seconds, lifted):
            host.setLink(state)
            try await harness.run(for: seconds)
            if lifted { host.setLink(.up) }
        case .sever:
            host.severConnections()
            triggers.note(harness)
        case let .sleep(willSleep, seconds, dnsFailures, wakeMessage):
            try await harness.sleepMac(willSleep: willSleep)
            harness.passTimeAsleep(seconds)
            if dnsFailures > 0 { host.failNameResolution(times: dnsFailures) }
            if wakeMessage { try await harness.wakeMac() }
            triggers.note(harness)
        case let .sshdRestart(seconds):
            host.severConnections()
            host.sshd = .refusing
            triggers.note(harness)
            try await harness.run(for: seconds)
            host.sshd = .running
        case let .reboot(down, rootMissing):
            host.severConnections()
            host.sshd = .refusing
            host.wipeHelperCache()
            triggers.note(harness)
            try await harness.run(for: down)
            if rootMissing > 0 { host.hideRoot() }
            host.sshd = .running
            try await harness.run(for: rootMissing)
            host.restoreRoot()
        case let .bannerHang(seconds, lifted):
            host.sshd = .bannerHang
            host.severConnections()
            triggers.note(harness)
            try await harness.run(for: seconds)
            if lifted { host.sshd = .running }
        case .killHelper:
            host.killHelpers()
        case let .slowReady(seconds):
            host.helperReadyDelay = seconds
            host.killHelpers()
        case let .helperNeverReady(seconds):
            host.helperNeverReady = true
            host.killHelpers()
            try await harness.run(for: seconds)
            host.helperNeverReady = false
        case .freezeHelper:
            host.freezeHelpers()
        case .probeStall:
            host.stallScript(.probe, count: 1)
            host.severConnections()
            triggers.note(harness)
        case let .channelProbeStall(ordinal, seconds):
            host.stalledSFTPChannelOrdinals = [ordinal]
            host.severConnections()
            triggers.note(harness)
            try await harness.run(for: seconds)
            host.stalledSFTPChannelOrdinals = []
        case let .sessionsHeld(seconds):
            host.extraSessionsHeld = 1
            host.severConnections()
            triggers.note(harness)
            try await harness.run(for: seconds)
            host.extraSessionsHeld = 0
        case let .sweepStall(seconds):
            host.stallScript(.sweep, count: 1)
            host.severConnections()
            triggers.note(harness)
            try await harness.run(for: seconds)
            host.clearScriptStalls()
            host.resumeStalledScripts()
        case .authFailure:
            host.failAuthentication(times: 1)
            host.severConnections()
            triggers.note(harness)
        case let .hostKey(seconds):
            try await harness.setNetworkPath(false)
            host.failHostKey(true)
            try await harness.setNetworkPath(true)
            triggers.note(harness)
            try await harness.run(for: seconds)
            host.failHostKey(false)
            try await harness.setNetworkPath(false)
            try await harness.setNetworkPath(true)
            triggers.note(harness)
        case let .rootHidden(seconds, sever):
            host.hideRoot()
            if sever {
                host.severConnections()
                triggers.note(harness)
            }
            try await harness.run(for: seconds)
            host.restoreRoot()
        case let .diskFull(seconds):
            host.wipeHelperCache()
            host.setDiskFull(true)
            host.severConnections()
            triggers.note(harness)
            try await harness.run(for: seconds)
            host.setDiskFull(false)
        case .agentRestart:
            try await harness.restartAgent()
            triggers.note(harness)
        case let .clockJump(seconds):
            try await harness.sleepMac(willSleep: true)
            harness.passTimeAsleep(600)
            harness.jumpMacWallClock(by: seconds)
            try await harness.wakeMac()
            triggers.note(harness)
        case let .serverChange(kind, index):
            switch kind {
            case 0: host.writeFile("fuzz-\(index).txt", text: "created by step \(index)\n")
            case 1: host.writeFile("notes.txt", text: "edited by step \(index)\n")
            case 2:
                let victims = ["old.txt", "README.txt"].filter(host.exists)
                if let victim = victims.first { host.delete(victim) } else {
                    host.writeFile("fuzz-\(index).txt", text: "nothing left to delete\n")
                }
            default:
                if host.exists("notes.txt") {
                    host.rename("notes.txt", to: "notes-\(index).txt")
                } else {
                    host.writeFile("notes.txt", text: "recreated by step \(index)\n")
                }
            }
        case .touch:
            harness.manager.noteFileProviderRequest(
                domainIdentifier: harness.location.id, method: "fetchContents")
        case let .wait(seconds):
            try await harness.run(for: seconds)
        }
        // Every step is followed by a little time, so consecutive faults are not all
        // applied in the same instant.
        try await harness.run(for: 2)
    }

    /// Every fault off, the Mac awake and on a network.
    static func liftEverything(_ harness: ResilienceHarness) async throws {
        let host = harness.host
        host.setLink(.up)
        host.sshd = .running
        host.failHostKey(false)
        host.failAuthentication(times: 0)
        host.failNameResolution(times: 0)
        host.clearConnectOutcomes()
        host.clearExecRefusal()
        host.clearScriptStalls()
        host.resumeStalledScripts()
        host.stalledSFTPChannelOrdinals = []
        host.helperReadyDelay = 0.5
        host.helperNeverReady = false
        host.restoreRoot()
        host.setDiskFull(false)
        host.extraSessionsHeld = 0
        try await harness.setNetworkPath(true)
    }

    // MARK: The fuzzer

    @Test(arguments: fuzzSeeds)
    func fuzzedSequenceConverges(seed: UInt64) async throws {
        let steps = Self.fuzzSteps(seed: seed)
        let replay = "seed \(seed) (SSHDRIVE_RESILIENCE_SEED=\(seed)): \(steps.map(\.description).joined(separator: ", "))"
        await Self.scenario(replay: replay) { harness in
            try await harness.run(for: 10)
            let triggers = Triggers()
            let faultStart = harness.host.serverNow
            for step in steps {
                try await Self.perform(step, harness, triggers: triggers)
            }
            try await Self.liftEverything(harness)
            triggers.note(harness)
            let lifted = harness.host.serverNow

            // While the faults were on: no hot loop. A minute may hold the ordinary eight
            // attempts plus two for everything in it that is owed one.
            let attempts = harness.host.attempts.filter { $0.serverAt >= faultStart && $0.serverAt < lifted }
            let owed = triggers.all
            var worst: (count: Int, allowed: Int, at: Double) = (0, 0, 0)
            for attempt in attempts {
                let window = attempts.filter { $0.serverAt >= attempt.serverAt && $0.serverAt < attempt.serverAt + 60 }.count
                let allowed = 8 + 2 * owed.filter { $0 >= attempt.serverAt - 60 && $0 < attempt.serverAt + 60 }.count
                if window - allowed > worst.count - worst.allowed { worst = (window, allowed, attempt.serverAt) }
            }
            #expect(
                worst.count <= worst.allowed,
                "\(worst.count) connect attempts in the minute from \(Int(worst.at - faultStart)) s, \(worst.allowed) allowed\n\(replay)")

            var quiet = Self.quiet
            if steps.contains(where: \.isRefusal) { quiet = Self.authQuiet }
            // Sessions held across a reconnect leave a connection that measured a smaller
            // budget, and on a connection that stays up that answer is asked again only on
            // the 30-minute pass.
            if steps.contains(where: { if case .sessionsHeld = $0 { return true }; return false }) {
                quiet = max(quiet, Self.verdictQuiet)
            }
            if steps.contains(where: {
                if case .slowReady = $0 { return true }
                if case .helperNeverReady = $0 { return true }
                return false
            }) {
                quiet = max(quiet, Self.quiet + 60)
            }
            try await harness.run(for: quiet)
            await Self.expectConverged(
                harness, effort: ResilienceHarness.Effort(since: lifted), replay: replay)
        }
    }
}
