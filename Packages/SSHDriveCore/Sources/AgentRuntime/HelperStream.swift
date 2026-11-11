import Foundation
import AgentCore
import Config
import Logging
import SFTP
import SSHProcess

/// The tier 2 event stream: one exec channel running the deployed helper under the
/// heartbeat wrapper, decoding NDJSON and handing events to the detector
/// (docs/design/change-detection.md, tier 2).
///
/// One channel, held for the life of the connection, which is what tier 2 is and tier 1 is
/// not: a sweep spends half a second on a channel and gives it back. That is why the
/// channel budget has to allow a *persistent* exec channel before this is even tried,
/// and why a `MaxSessions 2` server stays at sweep.
actor HelperStream {

    /// How long the helper may take to say `ready`. Its first act is a walk of the root
    /// set to establish the watches, and on a large pinned tree that walk is tens of
    /// seconds; a deadline shorter than the walk fails a healthy helper on every attempt.
    static let readySeconds: TimeInterval = 120
    /// How long the exec channel itself may take to open, which is the sentinel arriving
    /// and nothing more.
    static let openSeconds: TimeInterval = 20
    /// The agent's ping, which the heartbeat wrapper needs at least once a minute.
    static let heartbeatSeconds: Double = 15
    /// How long a running stream may go without a single byte before it is declared
    /// dead. The helper writes a heartbeat of its own every 15 s whether or not anything
    /// changed, so a minute of nothing is four missed heartbeats: a helper that has hung,
    /// or a channel that has stalled under a connection whose other channels still work.
    static let silenceSeconds: Double = 60

    enum State: Equatable {
        case idle
        case running
        /// Died and will be restarted by the ladder, with the sentence `status` prints.
        case failed(String)
    }

    struct Roots: Equatable, Sendable {
        var shallow: [Data]
        var recursive: [Data]
        var excluded: [Data]

        init(shallow: [Data] = [], recursive: [Data] = [], excluded: [Data] = []) {
            self.shallow = shallow
            self.recursive = recursive
            self.excluded = excluded
        }
    }

    let locationID: String
    private let helperPath: String
    private let canonicalRoot: String
    private let directory: String
    /// The ready deadline, the heartbeat, the read deadline, the death grace and the two
    /// timestamps `status` prints are all on this clock.
    private let clock: any AgentClock

    private var channel: (any RemoteExecChannel)?
    private var reader: Task<Void, Never>?
    private var beater: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// Bumped by every `stop()`, so a `start` that was waiting for `ready` when it was
    /// stopped knows not to go on and run.
    private var generation = 0
    /// When the last byte arrived, on the clock's monotonic time: the silence watchdog's
    /// reference.
    private var lastReceivedAt: Double = 0
    /// When a new root set was last sent. The helper applies a root set by walking every
    /// root again, and a helper built without heartbeats inside its walk says nothing
    /// until the walk is done, so for `readySeconds` after the send - the allowance its
    /// first walk gets - silence is not death. The allowance is not ended by the next
    /// byte: a heartbeat already in the pipe when the line was sent arrives after it, and
    /// would end the allowance before the walk had begun.
    private var rootsSentAt: Double?
    private(set) var state: State = .idle
    private(set) var roots = Roots()
    private(set) var lastEventAt: Double?
    private(set) var startedAt: Double?
    private(set) var eventCount = 0
    private(set) var overflowCount = 0
    private(set) var mechanism: String?
    private(set) var version: String?

    /// Called with every batch the decoder produced, on the detector's actor.
    private let onEvents: @Sendable ([HelperEvent]) async -> Void
    /// Called once when the stream dies, with the reason. The ladder decides what that
    /// costs the location.
    private let onDeath: @Sendable (String) async -> Void

    init(
        locationID: String, helperPath: String, canonicalRoot: String, directory: String,
        clock: any AgentClock = SystemAgentClock(),
        onEvents: @escaping @Sendable ([HelperEvent]) async -> Void,
        onDeath: @escaping @Sendable (String) async -> Void
    ) {
        self.clock = clock
        self.locationID = locationID
        self.helperPath = helperPath
        self.canonicalRoot = canonicalRoot
        self.directory = directory
        self.onEvents = onEvents
        self.onDeath = onDeath
    }

    // MARK: The script

    /// Start `<path>/sshdrive-helper watch --json --root <root> --roots-from-stdin` from
    /// the same `sh -s` wrapper script as every other remote command, its path and root
    /// single-quoted into the script and never on the command line.
    ///
    /// The initial root set goes on the helper's own argv as well as down the relay. That
    /// is not redundancy for its own sake: a server whose helper directory cannot hold a
    /// FIFO runs the helper with no stdin at all, and without the argv copy it would watch
    /// nothing at all there.
    static func script(
        helperPath: String, canonicalRoot: String, relay: String, roots: Roots,
        sentinel: Sentinel = Sentinel()
    ) -> RemoteScript {
        var arguments = [helperPath, canonicalRoot]
        for root in roots.shallow {
            if let text = String(data: root, encoding: .utf8) { arguments += ["--shallow", text] }
        }
        for root in roots.recursive {
            if let text = String(data: root, encoding: .utf8) { arguments += ["--recursive", text] }
        }
        for root in roots.excluded {
            if let text = String(data: root, encoding: .utf8) { arguments += ["--exclude", text] }
        }
        let body = """
            __sd_helper="$1"; __sd_root="$2"; shift 2
            if [ "$\(RemoteScript.relayFlagVariable)" = 1 ]; then
              exec "$__sd_helper" watch --json --root "$__sd_root" --roots-from-stdin "$@"
            else
              exec "$__sd_helper" watch --json --root "$__sd_root" "$@"
            fi
            """
        return RemoteScript(
            sentinel: sentinel, arguments: arguments, body: body,
            heartbeat: .standard, stdinRelay: relay)
    }

    // MARK: Lifecycle

    /// Opens the channel and waits for the helper's `ready` line, which is what "settling
    /// on the first tier that starts successfully" means here.
    ///
    /// The agent pings from the moment the channel is open, not from `ready`: the
    /// wrapper kills a child that has heard nothing for 60 s, and the helper's first walk
    /// can be longer than that.
    ///
    /// Throws when `ready` does not arrive - EOF, a read error, the deadline, or `stop()`
    /// while waiting - and always as the transient `.unavailable(_, permanent: false)`,
    /// with the channel closed. The commonest way to get here is a channel that went with
    /// the connection, then a walk slower than the deadline; a server that genuinely
    /// cannot execute the binary was already refused by the `--version` run in the
    /// deployment. Only the channel's open can throw anything else, and that error is
    /// passed through for the caller to classify.
    func start(
        master: any RemoteMaster, roots: Roots, readyDeadline: TimeInterval = readySeconds
    ) async throws {
        stop()
        let generation = self.generation
        self.roots = roots
        let relay = "\(directory)/.sshdrive-helper-in-\(UInt32.random(in: 0...UInt32.max))"
        let script = HelperStream.script(
            helperPath: helperPath, canonicalRoot: canonicalRoot, relay: relay, roots: roots)
        let opened = try await master.openExecChannel(
            script: script, readinessDeadline: Self.openSeconds)
        guard generation == self.generation else {
            opened.close()
            throw HelperDeployer.Failure.unavailable(
                "the helper stream was stopped while it was starting", permanent: false)
        }
        channel = opened
        startBeating()

        var decoder = HelperEventDecoder()
        var ready: HelperEvent?
        var why = "the helper did not say ready within \(Int(readyDeadline)) s"
        let deadline = clock.now() + readyDeadline
        while ready == nil, generation == self.generation {
            guard clock.now() < deadline else { break }
            let chunk: Data
            do {
                chunk = try await opened.stream.read(
                    upTo: 64 * 1024, deadline: Date(timeIntervalSince1970: deadline))
            } catch ByteStreamError.readTimedOut {
                break
            } catch {
                why = "the helper's channel failed before it said ready: \(error.localizedDescription)"
                break
            }
            if chunk.isEmpty {
                why = "the helper did not start on the server"
                break
            }
            for event in decoder.append(chunk) where event.kind == .ready { ready = event }
        }
        guard let ready, generation == self.generation else {
            if generation == self.generation {
                beater?.cancel()
                beater = nil
                channel = nil
                opened.close()
            } else {
                // `stop()` has closed the channel and cancelled the pinger already, and
                // whatever it has since started is not this attempt's to touch.
                why = "the helper stream was stopped while it was starting"
            }
            let stderr = opened.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperDeployer.Failure.unavailable(
                stderr.isEmpty ? why : "\(why): \(stderr)", permanent: false)
        }
        version = ready.version
        mechanism = ready.mechanism
        state = .running
        startedAt = clock.now()
        lastReceivedAt = clock.uptime()
        Log.agent.notice(
            "\(self.locationID, privacy: .public): helper \(ready.version ?? "?", privacy: .public) running at \(self.helperPath, privacy: .public) (\(ready.mechanism ?? "?", privacy: .public)), \(roots.shallow.count + roots.recursive.count, privacy: .public) root(s)"
        )

        let clock = self.clock
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                guard let due = await self?.silenceDeadline() else { return }
                let now = clock.uptime()
                if now >= due {
                    await self?.die(
                        "the helper went silent for \(Int(HelperStream.silenceSeconds)) s",
                        channelMayStillRun: true)
                    return
                }
                await clock.sleep(seconds: due - now)
            }
        }
        reader = Task { [weak self] in
            await self?.readLoop(channel: opened, decoder: decoder)
        }
    }

    func stop() {
        generation += 1
        reader?.cancel()
        beater?.cancel()
        watchdog?.cancel()
        reader = nil
        beater = nil
        watchdog = nil
        // Closing stdin is what the wrapper reads as EOF: it kills the helper and exits,
        // so nothing is left running on the server.
        channel?.endInput()
        channel?.close()
        channel = nil
        if state == .running { state = .idle }
    }

    private func startBeating() {
        let clock = self.clock
        beater = Task { [weak self] in
            while !Task.isCancelled {
                await clock.sleep(seconds: HelperStream.heartbeatSeconds)
                if Task.isCancelled { return }
                await self?.beat()
            }
        }
    }

    /// When the running stream is due to be declared silent, or nil once it is not
    /// running.
    private func silenceDeadline() -> Double? {
        guard state == .running else { return nil }
        let silence = lastReceivedAt + Self.silenceSeconds
        guard let rootsSentAt else { return silence }
        return max(silence, rootsSentAt + Self.readySeconds)
    }

    /// When the root set changes the helper is sent the new set on its stdin and applies
    /// it live. The line goes down the channel's stdin; the wrapper relays it into the
    /// helper's FIFO.
    func updateRoots(_ new: Roots) async {
        guard new != roots else { return }
        roots = new
        guard let channel, state == .running else { return }
        let line = HelperControl.rootsLine(
            shallow: new.shallow, recursive: new.recursive, excluded: new.excluded)
        do {
            try await channel.stream.write(line)
            rootsSentAt = clock.uptime()
        } catch {
            await die("could not send the root set to the helper: \(error)")
        }
    }

    /// One ping. Before `ready` a failed write is left to the `ready` wait, which sees
    /// the same channel end; after it, it is the stream's death.
    private func beat() async {
        guard let channel else { return }
        do {
            try await channel.sendHeartbeat()
        } catch {
            await die("the helper's channel closed: \(error)")
        }
    }

    private func readLoop(channel: any RemoteExecChannel, decoder: HelperEventDecoder) async {
        var decoder = decoder
        while !Task.isCancelled {
            let chunk: Data
            do {
                // No deadline that could fire on a quiet tree: the helper's own heartbeat
                // every 15 s is what proves it is alive, and the wrapper kills it if we
                // stop writing. A read deadline here would tear down a healthy stream.
                chunk = try await channel.stream.read(
                    upTo: 256 * 1024, deadline: clock.deadline(after: 3600))
            } catch {
                await die("the helper's stream ended: \(error)")
                return
            }
            if chunk.isEmpty {
                await die("the helper exited")
                return
            }
            lastReceivedAt = clock.uptime()
            let events = decoder.append(chunk)
            guard !events.isEmpty else { continue }
            lastEventAt = clock.now()
            eventCount += events.filter { $0.kind != .heartbeat }.count
            overflowCount += events.filter { $0.kind == .overflow }.count
            for event in events where event.kind == .error {
                Log.agent.error(
                    "\(self.locationID, privacy: .public): helper: \(event.message ?? "?", privacy: .public)"
                )
            }
            await onEvents(events)
        }
    }

    /// - Parameter channelMayStillRun: the stream was declared dead while its channel may
    ///   still be open - a helper that went silent. The channel is closed before anything
    ///   here waits, so the helper behind it is gone before a replacement can start: one
    ///   helper per connection.
    private func die(_ reason: String, channelMayStillRun: Bool = false) async {
        guard state == .running else { return }
        // Marked failed before anything here waits, so the reader, the pinger and the
        // watchdog can each reach this and only the first one reports a death.
        state = .failed(reason)
        let dying = channel
        channel = nil
        // What the channel had to say on its way out. Without it a helper that dies on a
        // real server leaves one sentence in the log, "the helper exited", with no exit
        // status, no signal and no stderr to say why. The tasks are cancelled after it,
        // because this may be running on one of them and a cancelled task's sleep returns
        // at once.
        var full = reason
        if let dying {
            let detail: String
            if channelMayStillRun {
                detail = Self.deathDetailNow(dying)
                dying.endInput()
                dying.close()
            } else {
                detail = await Self.deathDetail(dying, clock: clock)
                dying.close()
            }
            if !detail.isEmpty { full = "\(reason) (\(detail))" }
        }
        beater?.cancel()
        watchdog?.cancel()
        beater = nil
        watchdog = nil
        state = .failed(full)
        Log.agent.error(
            "\(self.locationID, privacy: .public): the helper stream died: \(full, privacy: .public)")
        await onDeath(full)
    }

    /// The exec channel's exit status and the tail of its stderr, once it has been reaped.
    private static func deathDetail(
        _ channel: any RemoteExecChannel, clock: any AgentClock
    ) async -> String {
        if channel.exitStatus() == nil {
            // The mux client is usually a hair behind the EOF that brought us here.
            await clock.sleep(seconds: 0.3)
        }
        return deathDetailNow(channel)
    }

    /// The same, as the channel stands at this moment.
    private static func deathDetailNow(_ channel: any RemoteExecChannel) -> String {
        let exit = channel.exitStatus()
        var parts: [String] = []
        if let exit {
            if let signal = exit.signal {
                parts.append("the channel was killed by signal \(signal)")
            } else {
                parts.append("the channel exited \(exit.status)")
            }
        } else {
            parts.append("the channel is still running")
        }
        let stderr = channel.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { parts.append("stderr: \(String(stderr.suffix(500)))") }
        return parts.joined(separator: "; ")
    }

    // MARK: Reporting

    func report() -> [String: Any] {
        var out: [String: Any] = [
            "path": helperPath,
            "directory": directory,
            "events": eventCount,
            "overflows": overflowCount,
        ]
        if let version { out["version"] = version }
        if let mechanism { out["mechanism"] = mechanism }
        if let startedAt { out["startedAt"] = startedAt }
        if let lastEventAt { out["lastEventAt"] = lastEventAt }
        switch state {
        case .idle: out["state"] = "idle"
        case .running: out["state"] = "running"
        case .failed(let reason):
            out["state"] = "failed"
            out["reason"] = reason
        }
        return out
    }
}
