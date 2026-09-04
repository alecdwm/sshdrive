import Foundation
import IOKit
import IOKit.pwr_mgt
import Network
import Logging

/// Sleep, wake, and the network path (DESIGN.md sections 6.1 and 6.3).
///
/// **Sleep and wake come from IOKit**, `IORegisterForSystemPower` with
/// `kIOMessageSystemWillSleep` and `kIOMessageSystemHasPoweredOn`, and not from
/// `NSWorkspace`: the agent runs no `NSApplication` (section 6.1). At the will-sleep
/// message the agent does not wait to find out whether the connection survived - it runs
/// `-O exit` on every master, because a connection that slept through a network change is
/// dead more often than not and dropping it before the sleep leaves no request in flight
/// on a connection the Mac is about to abandon. It reconnects at
/// `kIOMessageSystemHasPoweredOn`.
///
/// The will-sleep message must be **acknowledged**, and the sleep does not proceed until
/// it is or until the system's own timeout (about 30 s) expires. `-O exit` on a handful of
/// masters is a few hundred milliseconds, so the acknowledgement is sent after the drop
/// rather than before it, with a hard 5 s cap so a wedged `ssh` can never delay a lid
/// close.
final class PowerEvents {
    static let shared = PowerEvents()

    /// The three `IOMessage.h` constants this needs. They are C macros
    /// (`iokit_common_msg(0x280)`), not enum cases, so Swift does not import them and they
    /// are spelled out here with the arithmetic that produces them:
    /// `sys_iokit | sub_iokit_common | code`, which is `0xE0000000 | code`.
    private static let systemWillSleep: UInt32 = 0xE000_0280      // iokit_common_msg(0x280)
    private static let canSystemSleep: UInt32 = 0xE000_0270       // iokit_common_msg(0x270)
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300   // iokit_common_msg(0x300)

    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootPort: io_connect_t = 0
    private(set) var willSleepCount = 0
    private(set) var didWakeCount = 0

    /// How long the will-sleep handler may spend dropping masters before it acknowledges
    /// anyway. The system's own limit is around 30 s; nothing here should need one.
    static let willSleepGraceSeconds: Double = 5

    func start() {
        var notificationPort: IONotificationPortRef?
        var notifierObject: io_object_t = 0
        let reference = Unmanaged.passUnretained(self).toOpaque()

        let connect = IORegisterForSystemPower(
            reference, &notificationPort,
            { context, _, messageType, messageArgument in
                guard let context else { return }
                let events = Unmanaged<PowerEvents>.fromOpaque(context).takeUnretainedValue()
                events.handle(messageType: messageType, argument: messageArgument)
            }, &notifierObject)

        guard connect != 0, let notificationPort else {
            Log.agent.error("IORegisterForSystemPower failed; sleep and wake will not be seen")
            return
        }
        rootPort = connect
        port = notificationPort
        notifier = notifierObject
        CFRunLoopAddSource(
            CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue(),
            .defaultMode)
        Log.agent.notice("registered for system power notifications")
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.systemWillSleep:
            willSleepCount += 1
            Log.agent.notice("system will sleep: dropping every master (section 6.1)")
            let rootPort = self.rootPort
            let token = intptr_t(bitPattern: argument)
            let acknowledged = Acknowledgement()
            Task {
                await DomainManager.shared.willSleep()
                if acknowledged.claim() { IOAllowPowerChange(rootPort, token) }
            }
            // The cap. Whatever happens to the drop, the Mac sleeps.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.willSleepGraceSeconds) {
                if acknowledged.claim() {
                    Log.agent.error("will-sleep drop did not finish in time; acknowledging anyway")
                    IOAllowPowerChange(rootPort, token)
                }
            }

        case Self.canSystemSleep:
            // Idle sleep. Nothing to object to; refusing would keep a laptop awake.
            IOAllowPowerChange(rootPort, intptr_t(bitPattern: argument))

        case Self.systemHasPoweredOn:
            didWakeCount += 1
            Log.agent.notice("system has powered on: reconnecting every location (section 6.1)")
            Task { await DomainManager.shared.didWake(trigger: "wake from sleep") }

        default:
            break
        }
    }

    /// `IOAllowPowerChange` must be called exactly once per will-sleep message.
    private final class Acknowledgement: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    var report: [String: Any] {
        ["willSleep": willSleepCount, "didWake": didWakeCount, "registered": port != nil]
    }
}

/// Section 6.3's first rule: `NWPathMonitor` says there is no path at all, and every call
/// is `.serverUnreachable` immediately without a socket being opened.
///
/// It covers Wi-Fi off and a cable pulled, and deliberately not a powered-down NAS or a
/// tailnet that is down while the Mac is online - that is what the breaker is for. A path
/// that comes back is section 5.6's "network returns" row: reset the breaker, connect, and
/// on success signal the flush.
final class NetworkPathGate {
    static let shared = NetworkPathGate()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.shirls.sshdrive.path")
    private(set) var lastStatus: NWPath.Status = .satisfied
    private(set) var changes = 0

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let changed = path.status != self.lastStatus
            self.lastStatus = path.status
            guard changed else { return }
            self.changes += 1
            Log.agent.notice(
                "network path is now \(String(describing: path.status), privacy: .public)")
            Task { await DomainManager.shared.networkPathChanged(available: satisfied) }
        }
        monitor.start(queue: queue)
    }

    var report: [String: Any] {
        ["status": String(describing: lastStatus), "changes": changes]
    }
}
