import Foundation
import AgentCore
import Config
import Logging
import SFTP
import SSHProcess
import XPCProtocols

/// DESIGN.md section 6.3 in front of one location's transport: the `NWPathMonitor` gate,
/// the circuit breaker with its bounded waiting, and reconnection with backoff.
///
/// It is an `SFTPTransport` like `SSHBackedTransport` and `FakeTransport`, so nothing in
/// `LocationRuntime` changes: the runtime holds this, and this holds the live
/// `SSHBackedTransport` - or does not, which is the whole point. Every call goes through
/// `ConnectionGate.acquire()`, which is section 6.3's four rules in one place:
///
/// - no path at all, or the breaker open: throw `.noConnection` at once, and the agent
///   maps that to `.serverUnreachable` for the extension (section 5.1);
/// - an attempt in progress: wait for it, bounded by the attempt's own remaining
///   authentication deadline;
/// - nothing connected and nothing owed: connect, and everything that arrives meanwhile
///   waits on that one attempt;
/// - connected: make the call, and a lost connection puts the location back to the first
///   case without a backoff, because the connection worked a moment ago.
///
/// The fault hooks (`sshdrive debug fault --unreachable`, `--transport-hang`) sit here
/// rather than in `LocationRuntime` because the spike needs a connect attempt to fail or
/// hang too, not only the calls that follow one.
public final class ReconnectingTransport: SFTPTransport, @unchecked Sendable {

    public let gate: ConnectionGate
    public let locationID: String

    public init(gate: ConnectionGate, locationID: String) {
        self.gate = gate
        self.locationID = locationID
    }

    /// Acquire, call, and tell the gate what happened. One place, so no transport method
    /// can forget either half.
    ///
    /// - Parameter retryOnLostConnection: whether a dead connection is worth one more go.
    ///   Section 6.1 says a connection that died silently is found by the request that uses
    ///   it, and that request pays for the discovery. For a read that is the wrong price:
    ///   S5 measured that the system **never re-issues a `fetchContents` that failed**
    ///   (2026-09-04), so the one call is the user's entire experience of a master that
    ///   went while nobody was looking - a double-click that says "Operation timed out"
    ///   and a folder that works again only if they try a second time. So a read or a
    ///   metadata call is retried once, through the breaker, which by then is either
    ///   connecting (the call waits for it) or open (it fails fast, as it should).
    ///
    ///   Writes are **not** retried: the upload's `source` closure is a pull from the
    ///   system's file handle and cannot be replayed, and a `rename` or `remove` that may
    ///   already have landed must not be re-sent. A failed write is the case the system
    ///   *does* retry on its own (section 5.6), which is why it needs no help here.
    private func run<T: Sendable>(
        _ what: String, retryOnLostConnection: Bool = false,
        _ body: @Sendable (any LiveConnection) async throws -> T
    ) async throws -> T {
        try await gate.applyFaults(what)
        var attempts = 0
        while true {
            attempts += 1
            let connection = try await gate.acquire()
            do {
                let value = try await body(connection)
                await gate.noteCallSucceeded()
                return value
            } catch let error as SFTPError {
                await gate.noteCallFailed(error)
                if retryOnLostConnection, attempts == 1,
                    error == .connectionLost || error == .eof
                {
                    Log.sftp.notice(
                        "\(self.locationID, privacy: .public): \(what, privacy: .public) hit a dead connection; retrying once through the breaker"
                    )
                    continue
                }
                throw error
            }
        }
    }

    // MARK: SFTPTransport

    public var extensions: SFTPServerExtensions {
        get async {
            await gate.currentConnection()?.extensions ?? SFTPServerExtensions()
        }
    }

    public func realpath(_ path: RelativePath) async throws -> String {
        try await run("realpath", retryOnLostConnection: true) { try await $0.realpath(path) }
    }

    public func lstat(_ path: RelativePath) async throws -> SFTPFileAttributes {
        try await run("lstat", retryOnLostConnection: true) { try await $0.lstat(path) }
    }

    public func readdir(_ path: RelativePath) async throws -> [SFTPDirectoryEntry] {
        try await run("readdir", retryOnLostConnection: true) { try await $0.readdir(path) }
    }

    public func read(_ path: RelativePath, offset: UInt64, length: Int?) async throws -> Data {
        try await run("read", retryOnLostConnection: true) { try await $0.read(path, offset: offset, length: length) }
    }

    public func readStreaming(
        _ path: RelativePath, offset: UInt64, length: UInt64?, window: Int,
        receiver: @escaping @Sendable (UInt64, Data) async -> Void
    ) async throws -> UInt64 {
        try await run("read", retryOnLostConnection: true) {
            try await $0.readStreaming(
                path, offset: offset, length: length, window: window, receiver: receiver)
        }
    }

    public func write(_ path: RelativePath, contents: Data, mode: UInt32) async throws {
        try await run("write") { try await $0.write(path, contents: contents, mode: mode) }
    }

    public func writeStreaming(
        _ path: RelativePath, mode: UInt32, window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try await run("write") {
            try await $0.writeStreaming(
                path, mode: mode, window: window, source: source, progress: progress)
        }
    }

    public func writeExclusive(
        _ path: RelativePath, mode: UInt32, window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try await run("write") {
            try await $0.writeExclusive(
                path, mode: mode, window: window, source: source, progress: progress)
        }
    }

    public func mkdir(_ path: RelativePath, mode: UInt32) async throws {
        try await run("mkdir") { try await $0.mkdir(path, mode: mode) }
    }

    public func remove(_ path: RelativePath) async throws {
        try await run("remove") { try await $0.remove(path) }
    }

    public func rmdir(_ path: RelativePath) async throws {
        try await run("rmdir") { try await $0.rmdir(path) }
    }

    public func rename(_ source: RelativePath, to destination: RelativePath) async throws {
        try await run("rename") { try await $0.rename(source, to: destination) }
    }

    public func posixRename(_ source: RelativePath, to destination: RelativePath) async throws {
        try await run("posix-rename") { try await $0.posixRename(source, to: destination) }
    }

    public func setstat(_ path: RelativePath, mode: UInt32?, mtime: Int64?) async throws {
        try await run("setstat") { try await $0.setstat(path, mode: mode, mtime: mtime) }
    }

    public func symlink(target: String, at path: RelativePath) async throws {
        try await run("symlink") { try await $0.symlink(target: target, at: path) }
    }

    public func readlink(_ path: RelativePath) async throws -> String {
        try await run("readlink", retryOnLostConnection: true) { try await $0.readlink(path) }
    }

    public func statvfs(_ path: RelativePath) async throws -> SFTPFilesystemStats {
        try await run("statvfs", retryOnLostConnection: true) { try await $0.statvfs(path) }
    }
}

/// The breaker, the live connection, and the one attempt everything waits on.
///
/// One per location, owned by `DomainManager` and reachable from `ControlCommands` so
/// `status`, `test` and the debug hooks can read and reset it.
public actor ConnectionGate {

    /// What the gate learned about a connection when it came up, which
    /// `LocationRuntime.applyConnection` turns into the identity, the channel budget and
    /// the root row.
    public struct Connected: Sendable {
        public var budget: ChannelBudget
        public var probe: ServerProbe.Result
        public var sharesMetadataChannel: Bool
    }

    private let environment: AgentEnvironment
    private let location: Location
    private let askpassPath: String?
    private let askpass: (any AskpassTokenProviding)?
    private let uploadTag: String

    private var breaker: CircuitBreaker
    private var rearm = DeadlineRearmState()
    private var connection: (any LiveConnection)?
    private var attempt: Task<any LiveConnection, Error>?
    /// The reconnect loop of section 6.1: "connection errors are `.serverUnreachable` and
    /// the agent reconnects with jittered backoff (section 6.3)". One sleeping task per
    /// open breaker, cancelled by a success, a drop or a shutdown.
    ///
    /// It is not an optimisation. S5 measured what the *system* does while we are down: it
    /// retries a queued `modifyItem` with a doubling backoff that is past five minutes
    /// after ten minutes offline, and it never re-issues a failed `fetchContents` at all
    /// (2026-09-04). So an agent that only reconnected when something asked would leave a
    /// mount dead until the user touched it, and a queued write waiting on a retry interval
    /// that only grows. The loop is what makes section 5.6's "network returns -> connection
    /// attempt -> `signalErrorResolved`" happen for a server that came back on its own.
    private var retry: Task<Void, Never>?
    /// Section 6.1: a second consecutive per-request deadline miss drops the master too.
    private var consecutiveDeadlineMisses = 0
    /// Set by `shutdown()` and never cleared: the gate is torn down once, at `agent stop`,
    /// a TERM or a `remove`, and nothing may bring a master back after it.
    private var shutdownRequested = false
    private var lastFailureText: String?
    private var lastClassification: SSHExitClassification?
    /// Counters for the spike and for `debug breaker`.
    public private(set) var attempts = 0
    public private(set) var failFastCalls = 0
    public private(set) var waitedCalls = 0
    public private(set) var reconnects = 0
    /// How many reconnect sequences a successful attempt has started and not finished.
    ///
    /// `connected` is the master and nothing else: the identity, the channel budget, the
    /// rename-semantics probe, the helper's stream and section 5.6's two signals all land
    /// afterwards, on a task of their own so nothing queues behind them (see
    /// `recordSuccess`). Until that task is done the location is still being brought up,
    /// and it is doing remote work of its own - which is what anything that needs the
    /// agent to be *idle* has to be able to see.
    public private(set) var recoveriesInFlight = 0
    /// The bound the last waiting call was held under (`F5`).
    ///
    /// Section 6.3 rule 2: a call that arrives during an attempt waits for **that
    /// attempt's own remaining deadline** - 60 s measured from the spawn of `ssh`, which
    /// already contains the 15 s `ConnectTimeout` - and never for a fresh 60 s of its
    /// own. The difference is invisible from the outside on a connect that succeeds, and
    /// is the whole of the rule on one that does not, so the number is recorded rather
    /// than inferred.
    public private(set) var lastWaitBoundSeconds: Double?

    /// `sshdrive debug fault <name> --unreachable on`: every transport call and every
    /// connect attempt fails as if the server had gone, without a container being stopped
    /// or a link being taken down - neither of which a VM guest can do to its host.
    private var faultUnreachable = false
    /// `--connect-failure <classification>`: what `--unreachable` reports the attempt
    /// failed as. `transient` by default; `authenticationDeadline` is the one section 4.2's
    /// re-arm needs, and there is no other way to produce it on a VM with no key agent, no
    /// FIDO key and no screen (2026-09-04).
    private var faultConnectFailure: SSHExitClassification = .transient
    /// `--transport-hang MS`: every transport **call** stalls this long first, which is
    /// what a network that has gone away but not been told about looks like.
    private var faultHangMilliseconds = 0
    /// `--connect-hang MS`: every connect **attempt** stalls this long, and nothing else
    /// does. That is section 6.3's rule 3 on its own - a server that accepts the TCP
    /// connection and then takes its time - so the bounded wait can be measured without the
    /// call's own hang confusing the number (2026-09-04).
    private var faultConnectHangMilliseconds = 0

    /// Called on the transition to connected. `DomainManager` puts section 5.6's recovery
    /// here: `signalErrorResolved(.serverUnreachable)` on the domain, then
    /// `signalEnumerator` for the working set, and the runtime's own re-derivation.
    public var onConnected: (@Sendable (String, Connected) async -> Void)?
    /// Called when a connection that was up is dropped, so `status` and the log can say
    /// so straight away rather than at the next call.
    public var onDisconnected: (@Sendable (String, String) async -> Void)?
    /// How the gate reads presence for section 4.2's request trigger. Injected so a unit
    /// test never touches CoreGraphics.
    var presence: @Sendable () -> PresenceReading

    public init(
        location: Location, askpassPath: String?, askpass: (any AskpassTokenProviding)?,
        uploadTag: String, environment: AgentEnvironment = .unconfigured,
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = CircuitBreaker.defaultJitter
    ) {
        self.environment = environment
        let source = environment.presence
        self.presence = { source.read() }
        self.location = location
        self.askpassPath = askpassPath
        self.askpass = askpass
        self.uploadTag = uploadTag
        self.breaker = CircuitBreaker(jitter: jitter)
    }

    private var now: TimeInterval { environment.clock.uptime() }

    public func setOnConnected(_ hook: @escaping @Sendable (String, Connected) async -> Void) {
        onConnected = hook
    }

    public func setOnDisconnected(_ hook: @escaping @Sendable (String, String) async -> Void) {
        onDisconnected = hook
    }

    /// Injected by a unit test, so the re-arm can be driven without CoreGraphics.
    public func setPresenceSource(_ source: @escaping @Sendable () -> PresenceReading) {
        presence = source
    }

    // MARK: Admission

    public func currentConnection() -> (any LiveConnection)? { connection }

    /// Section 6.3, all four rules. Throws `SFTPError.noConnection`, which the agent maps
    /// to `.serverUnreachable` (section 5.1).
    public func acquire() async throws -> any LiveConnection {
        // At most two passes: one wait, then one decision on the result of the attempt
        // that was waited for. A third would be a loop on a location that keeps failing.
        for _ in 0..<2 {
            switch breaker.admit(now: now) {
            case .proceed:
                if let connection { return connection }
                // The breaker says up and there is nothing: a drop the breaker has not
                // been told about. Tell it, and take the next decision.
                breaker.connectionLost()
                continue

            case .connect:
                let task = startAttempt()
                do {
                    return try await task.value
                } catch {
                    throw failure(from: error)
                }

            case let .wait(seconds):
                guard let attempt else {
                    // The attempt finished between the decision and here. Go round.
                    continue
                }
                waitedCalls += 1
                lastWaitBoundSeconds = seconds
                do {
                    // Bounded by what is left of the attempt's own 60 s (section 4.2),
                    // never by a timeout of our own added on top of it.
                    return try await Deadline.run("waiting for the connection", seconds: seconds) {
                        try await attempt.value
                    }
                } catch is Deadline.Expired {
                    Log.ssh.notice(
                        "\(self.location.id, privacy: .public): a call gave up waiting for the connection attempt after \(Int(seconds), privacy: .public) s"
                    )
                    throw SFTPError.noConnection
                } catch {
                    throw failure(from: error)
                }

            case let .failFast(reason):
                failFastCalls += 1
                Log.sftp.debug(
                    "\(self.location.id, privacy: .public): failing fast - \(reason.sentence, privacy: .public)"
                )
                throw SFTPError.noConnection
            }
        }
        throw SFTPError.noConnection
    }

    private func failure(from error: Error) -> Error {
        if let sftp = error as? SFTPError { return sftp }
        return SFTPError.noConnection
    }

    // MARK: The attempt

    private func startAttempt() -> Task<any LiveConnection, Error> {
        if let attempt { return attempt }
        if shutdownRequested {
            return Task { throw SFTPError.noConnection }
        }
        attempts += 1
        let location = self.location
        let askpassPath = self.askpassPath
        let askpass = self.askpass
        let uploadTag = self.uploadTag
        let unreachable = faultUnreachable
        let failure = faultConnectFailure
        let hang = faultConnectHangMilliseconds
        let launcher = environment.launcher
        let clock = environment.clock
        let task = Task<any LiveConnection, Error> { [weak self] in
            do {
                if hang > 0 {
                    // A server that accepts the TCP connection and then says nothing: the
                    // attempt stalls, and section 6.3's rule 3 is what everything waiting
                    // on it is measured against.
                    await clock.sleep(seconds: Double(hang) / 1000)
                }
                if unreachable {
                    // The `--unreachable` fault stands in for a link that is down. It
                    // fails the attempt rather than hanging it, so the breaker opens on
                    // the ordinary path.
                    throw SSHProcessError.connectionFailed(
                        classification: failure, stderr: "debug fault --unreachable")
                }
                let connected = try await launcher.connect(
                    location: location, askpassPath: askpassPath, askpass: askpass,
                    uploadTag: uploadTag, reprobeChannels: false)
                await self?.recordSuccess(connected)
                return connected
            } catch {
                await self?.recordFailure(error)
                throw error
            }
        }
        attempt = task
        return task
    }

    private func recordSuccess(_ transport: any LiveConnection) async {
        attempt = nil
        // The attempt outran the shutdown (see `shutdown()`): this master is nobody's, and
        // the gate is not going to be asked again.
        guard !shutdownRequested else {
            await transport.shutdown()
            return
        }
        retry?.cancel()
        retry = nil
        let wasDown = !breaker.isUp
        connection = transport
        breaker.attemptSucceeded()
        rearm.clear()
        consecutiveDeadlineMisses = 0
        lastFailureText = nil
        lastClassification = nil
        if wasDown { reconnects += 1 }
        Log.ssh.notice("\(self.location.id, privacy: .public): connected")
        let report = Connected(
            budget: transport.budget, probe: transport.probe,
            sharesMetadataChannel: transport.transfersShareMetadataChannel)
        let hook = onConnected
        let id = location.id
        // Off the actor: the recovery does File Provider calls and a re-derivation, and
        // nothing else may queue behind them. Counted while it runs, because from the
        // outside "connected" would otherwise look like "finished".
        recoveriesInFlight += 1
        Task { [weak self] in
            await hook?(id, report)
            await self?.noteRecoveryFinished()
        }
    }

    private func noteRecoveryFinished() {
        recoveriesInFlight = max(0, recoveriesInFlight - 1)
    }

    private func recordFailure(_ error: Error) async {
        attempt = nil
        connection = nil
        let classification = (error as? SSHProcessError)?.classification ?? .transient
        lastClassification = classification
        lastFailureText = error.localizedDescription
        breaker.attemptFailed(classification, now: now)
        rearm.noteStop(classification)
        scheduleRetry()
        if classification.stopsReconnection {
            Log.ssh.error(
                "\(self.location.id, privacy: .public): reconnection stopped (\(classification.rawValue, privacy: .public))"
            )
        } else {
            Log.ssh.notice(
                "\(self.location.id, privacy: .public): connection attempt failed (\(classification.rawValue, privacy: .public)); \(self.breaker.description(now: self.now), privacy: .public)"
            )
        }
    }

    /// Sleeps out the breaker's backoff and then attempts once. A stopped location gets no
    /// loop: an auth or host-key failure waits for the user, and a deadline stop waits for
    /// section 4.2's re-arm.
    private func scheduleRetry() {
        retry?.cancel()
        retry = nil
        guard case let .backingOff(until) = breaker.state else { return }
        let seconds = max(0, until - now)
        let clock = environment.clock
        retry = Task { [weak self] in
            await clock.sleep(seconds: seconds)
            guard !Task.isCancelled else { return }
            await self?.connectInBackground(trigger: "the reconnect backoff")
        }
    }

    // MARK: Call outcomes

    public func noteCallSucceeded() {
        consecutiveDeadlineMisses = 0
    }

    /// Section 6.1's three ways a dead connection is found, as they reach this layer.
    public func noteCallFailed(_ error: SFTPError) async {
        switch error {
        case .connectionLost, .noConnection, .eof:
            await drop(reason: "the connection was lost")
        case .deadlineExceeded:
            consecutiveDeadlineMisses += 1
            if consecutiveDeadlineMisses >= 2 {
                await drop(reason: "two consecutive requests missed their deadline")
            }
        default:
            break
        }
    }

    /// Puts the location back to "nothing connected". The master is shut down with
    /// `-O exit` so nothing is left holding a socket (section 6.1).
    /// - Parameter reconnect: whether to start an attempt straight away. True everywhere
    ///   except the will-sleep drop, where reconnecting would defeat the point, and the
    ///   shutdown path. Section 6.1 reconnects on a connection error rather than waiting
    ///   for something to ask, and S5 is why that matters: the system re-issues nothing on
    ///   its own after a failed `fetchContents`, and backs a queued `modifyItem` off past
    ///   five minutes, so a mount whose server blinked would stay dead until the user
    ///   clicked it (2026-09-04).
    public func drop(reason: String, reconnect: Bool = true) async {
        retry?.cancel()
        retry = nil
        guard let live = connection else {
            breaker.connectionLost()
            if reconnect { await connectInBackground(trigger: reason) }
            return
        }
        connection = nil
        consecutiveDeadlineMisses = 0
        breaker.connectionLost()
        // Section 6.1's channel budget is measured on one connection and cached for ever,
        // and a measurement taken while a connection was dying is the wrong answer kept
        // for good: a location that probed in that moment reported "MaxSessions 1,
        // SFTP-only" against a healthy server, with no helper, across every later restart
        // (2026-09-08). An abrupt loss of a connection that was up is exactly the moment
        // that produces one, so the cached answer stops being evidence here and the next
        // connect probes again.
        CapabilityCache.markChannelBudgetSuspect(locationID: location.id)
        Log.ssh.notice(
            "\(self.location.id, privacy: .public): dropping the master - \(reason, privacy: .public)")
        await live.shutdown()
        let hook = onDisconnected
        let id = location.id
        Task { await hook?(id, reason) }
        if reconnect { await connectInBackground(trigger: reason) }
    }

    // MARK: Section 6.1's sleep and wake, and section 6.3's resets

    /// `kIOMessageSystemWillSleep`: the agent does not wait to find out whether the
    /// connection survived, it runs `-O exit` on every master before the Mac abandons it.
    public func willSleep() async {
        await drop(reason: "the Mac is going to sleep", reconnect: false)
    }

    /// `kIOMessageSystemHasPoweredOn`, and the same path a returning network path takes
    /// (section 5.6). Resets the breaker and connects, so the flush happens without
    /// waiting for a request.
    public func didWake(trigger: String) async {
        breaker.reset()
        Log.ssh.notice("\(self.location.id, privacy: .public): \(trigger, privacy: .public); reconnecting")
        await connectInBackground(trigger: trigger)
    }

    /// Section 4.2: an `agentDependent` location makes no attempt at all while the screen
    /// is locked, wake included - its first attempt after a sleep is the one the unlock
    /// re-arms.
    public func connectInBackground(trigger: String) async {
        if location.agentDependent, presence().screenLocked {
            Log.ssh.notice(
                "\(self.location.id, privacy: .public): not attempting after \(trigger, privacy: .public); the screen is locked and the location depends on a key agent"
            )
            return
        }
        guard case .connect = breaker.admit(now: now) else { return }
        _ = startAttempt()
    }

    public func setNetworkPath(_ available: Bool) async {
        let had = breaker.hasNetworkPath
        breaker.setNetworkPath(available)
        guard available, !had else {
            if !available { await drop(reason: "the network path went away", reconnect: false) }
            return
        }
        await connectInBackground(trigger: "the network path came back")
    }

    /// `com.apple.screenIsUnlocked`. Section 4.2's first trigger.
    public func screenUnlocked() async {
        guard rearm.screenUnlocked() else { return }
        guard breaker.rearmOneAttempt() else { return }
        Log.ssh.notice(
            "\(self.location.id, privacy: .public): one attempt re-armed by the screen unlock (section 4.2)")
        await connectInBackground(trigger: "screen unlock")
    }

    /// Section 4.2's second trigger: a File Provider request for this domain arriving
    /// while the presence test passes. Every XPC call from the extension goes through
    /// here, so the test is behind the once-a-minute rule and costs nothing.
    public func fileProviderRequestArrived() async {
        let source = presence
        guard rearm.requestArrived(now: now, presence: { source() }) else { return }
        guard breaker.rearmOneAttempt() else { return }
        Log.ssh.notice(
            "\(self.location.id, privacy: .public): one attempt re-armed by a request with the user present (section 4.2)"
        )
        await connectInBackground(trigger: "a present-user request")
    }

    /// `sshdrive test`, `passwd`, or a settings change: the only things that clear a
    /// refusal (section 6.1). Also what the CLI's explicit reconnect uses.
    public func clearStopAndConnect() async {
        breaker.clearStop()
        rearm.clear()
        await connectInBackground(trigger: "an explicit reconnect")
    }

    /// The last thing that happens to a gate: every schedule cancelled, the attempt in
    /// flight abandoned, and the master shut down.
    ///
    /// **The connection is taken out of the actor before it is awaited**, exactly as
    /// `drop` does it. `LiveConnection.shutdown()` is a nonisolated `async` call, so the
    /// gate is released for the length of it, and the shutdown really does arrive twice:
    /// `DomainManager.shutdownAll` runs `gate.shutdown()` and `runtime.shutdownTransport()`
    /// in one task group and the runtime's is `gate.shutdown()` again. With `connection`
    /// still set across the await, the second caller would find it and run `-O exit` on the
    /// same master a second time - on a real master, a stray `ssh -O exit` against a socket
    /// that has already gone (`P4`).
    ///
    /// `shutdownRequested` is the other half: `startAttempt`'s task is not synchronously
    /// cancellable - `launcher.connect` spawns an `ssh` and only notices a cancel where it
    /// happens to await - so an attempt that lands after this point would otherwise install
    /// a live master into a gate nobody will ever shut down again. It is shut down here
    /// instead, and no new attempt is ever started.
    public func shutdown() async {
        shutdownRequested = true
        retry?.cancel()
        retry = nil
        attempt?.cancel()
        attempt = nil
        let live = connection
        connection = nil
        if let live { await live.shutdown() }
    }

    // MARK: Faults

    private func applyHang() async throws {
        if faultHangMilliseconds > 0 {
            await environment.clock.sleep(seconds: Double(faultHangMilliseconds) / 1000)
        }
    }

    /// Called before every transport call. Only the hang lives here: `--unreachable` is
    /// applied to the **connect attempt** and not to the call, so a faulted location takes
    /// exactly the path a genuinely dead server takes - the first call connects, the
    /// attempt fails, the breaker opens, and every call after that fails fast without
    /// touching the network. Failing the call directly instead was the first shape of this
    /// hook and it measured nothing: the breaker was never entered, `failFastCalls` stayed
    /// at zero, and the fault was testing itself (2026-09-04).
    public func applyFaults(_ what: String) async throws {
        try await applyHang()
    }

    public func setFault(
        unreachable: Bool?, hangMilliseconds: Int?, connectHangMilliseconds: Int? = nil,
        connectFailure: String? = nil
    ) async {
        if let connectFailure, let parsed = SSHExitClassification(rawValue: connectFailure) {
            faultConnectFailure = parsed
        }
        if let connectHangMilliseconds {
            faultConnectHangMilliseconds = max(0, connectHangMilliseconds)
        }
        if let unreachable {
            faultUnreachable = unreachable
            if unreachable {
                await drop(reason: "debug fault --unreachable on")
            } else {
                // Turning the fault off is the outage ending, so it takes exactly the path
                // section 5.6's "network returns" row takes: reset, connect, and on success
                // signal. Resetting alone would leave the flush waiting for whenever the
                // system next asked, which is the thing S5 is trying to measure.
                breaker.reset()
                await connectInBackground(trigger: "debug fault --unreachable off")
            }
        }
        if let hangMilliseconds { faultHangMilliseconds = max(0, hangMilliseconds) }
    }

    /// S5 has to tell `signalErrorResolved` and `signalEnumerator` apart, and the recovery
    /// sends both. With this on, a reconnect sends neither and the spike sends one by hand
    /// with `sshdrive debug signal`.
    public private(set) var suppressRecoverySignals = false

    public func setSuppressRecoverySignals(_ value: Bool) { suppressRecoverySignals = value }

    // MARK: Reporting

    public func report(includeCounters: Bool = true) -> [String: Any] {
        var report: [String: Any] = [
            "state": breaker.description(now: now),
            "connected": connection != nil,
            "hasNetworkPath": breaker.hasNetworkPath,
            "consecutiveFailures": breaker.consecutiveFailures,
            "nextBackoffSeconds": breaker.nextBackoff().rounded(toPlaces: 2),
            "backoffCapSeconds": breaker.backoffCapSeconds,
            "stopped": breaker.isStopped,
            "recovering": recoveriesInFlight > 0,
            "retryScheduled": retry != nil,
            "rearmArmed": rearm.isArmed,
            "rearmUnlockUsed": rearm.unlockTriggerUsed,
            "rearmRequestUsed": rearm.requestTriggerUsed,
            "presenceEvaluations": rearm.presenceEvaluations,
        ]
        if let lastFailureText { report["lastFailure"] = lastFailureText }
        if let lastClassification { report["lastClassification"] = lastClassification.rawValue }
        if includeCounters {
            report["attempts"] = attempts
            report["reconnects"] = reconnects
            report["failFastCalls"] = failFastCalls
            report["waitedCalls"] = waitedCalls
            if let lastWaitBoundSeconds { report["lastWaitBoundSeconds"] = lastWaitBoundSeconds }
            report["faultUnreachable"] = faultUnreachable
            report["faultHangMilliseconds"] = faultHangMilliseconds
        }
        return report
    }

    /// The sentence `sshdrive status` and `list` show for an offline location.
    public func stateSentence() -> String {
        if connection != nil { return "connected" }
        return breaker.description(now: now)
    }

    public var isConnected: Bool { connection != nil }
}
