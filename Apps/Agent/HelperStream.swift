import Foundation
import AgentCore
import Config
import Logging
import SFTP
import SSHProcess

/// The tier 2 event stream: one exec channel running the deployed helper under the
/// heartbeat wrapper, decoding NDJSON and handing events to the detector
/// (DESIGN.md section 6.4 tier 2, step 3).
///
/// One channel, held for the life of the connection, which is what tier 2 is and tier 1 is
/// not: a sweep spends half a second on a channel and gives it back. That is why the
/// budget of section 6.1 has to allow a *persistent* exec channel before this is even
/// tried, and why a `MaxSessions 2` server stays at sweep.
actor HelperStream {

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

    private var channel: ExecChannel?
    private var reader: Task<Void, Never>?
    private var beater: Task<Void, Never>?
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
    /// costs the location (section 6.4).
    private let onDeath: @Sendable (String) async -> Void

    init(
        locationID: String, helperPath: String, canonicalRoot: String, directory: String,
        onEvents: @escaping @Sendable ([HelperEvent]) async -> Void,
        onDeath: @escaping @Sendable (String) async -> Void
    ) {
        self.locationID = locationID
        self.helperPath = helperPath
        self.canonicalRoot = canonicalRoot
        self.directory = directory
        self.onEvents = onEvents
        self.onDeath = onDeath
    }

    // MARK: The script

    /// Section 6.4: "Start `<path>/sshdrive-helper watch --json --root <root>
    /// --roots-from-stdin` from the same `sh -s` wrapper script as every other remote
    /// command (section 9.2), its path and root single-quoted into the script and never on
    /// the command line".
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
    /// on the first tier that starts successfully" means here. Throws when it does not
    /// arrive: a shell that answered and produced no helper is a tier failure, not an
    /// outage.
    func start(master: SSHMaster, roots: Roots, readyDeadline: TimeInterval = 20) async throws {
        stop()
        self.roots = roots
        let relay = "\(directory)/.sshdrive-helper-in-\(UInt32.random(in: 0...UInt32.max))"
        let script = HelperStream.script(
            helperPath: helperPath, canonicalRoot: canonicalRoot, relay: relay, roots: roots)
        let opened = try await master.openExecChannel(script: script, readinessDeadline: readyDeadline)
        channel = opened

        var decoder = HelperEventDecoder()
        var ready: HelperEvent?
        let deadline = Date().addingTimeInterval(readyDeadline)
        while Date() < deadline, ready == nil {
            let chunk = try await opened.stream.read(upTo: 64 * 1024, deadline: deadline)
            if chunk.isEmpty { break }
            for event in decoder.append(chunk) where event.kind == .ready { ready = event }
        }
        guard let ready else {
            opened.close()
            channel = nil
            let stderr = opened.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperDeployer.Failure.unavailable(
                stderr.isEmpty
                    ? "the helper did not start on the server"
                    : "the helper did not start on the server: \(stderr)")
        }
        version = ready.version
        mechanism = ready.mechanism
        state = .running
        startedAt = Date().timeIntervalSince1970
        Log.agent.notice(
            "\(self.locationID, privacy: .public): helper \(ready.version ?? "?", privacy: .public) running at \(self.helperPath, privacy: .public) (\(ready.mechanism ?? "?", privacy: .public)), \(roots.shallow.count + roots.recursive.count, privacy: .public) root(s)"
        )

        beater = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                if Task.isCancelled { return }
                await self?.beat()
            }
        }
        reader = Task { [weak self] in
            await self?.readLoop(channel: opened, decoder: decoder)
        }
    }

    func stop() {
        reader?.cancel()
        beater?.cancel()
        reader = nil
        beater = nil
        // Closing stdin is what the wrapper reads as EOF: it kills the helper and exits,
        // so nothing is left running on the server (section 6.4).
        channel?.endInput()
        channel?.close()
        channel = nil
        if state == .running { state = .idle }
    }

    /// Section 6.4: "When it changes, the helper is sent the new set on its stdin and
    /// applies it live." The line goes down the channel's stdin; the wrapper relays it into
    /// the helper's FIFO.
    func updateRoots(_ new: Roots) async {
        guard new != roots else { return }
        roots = new
        guard let channel, state == .running else { return }
        let line = HelperControl.rootsLine(
            shallow: new.shallow, recursive: new.recursive, excluded: new.excluded)
        do {
            try await channel.stream.write(line)
        } catch {
            await die("could not send the root set to the helper: \(error)")
        }
    }

    private func beat() async {
        guard let channel, state == .running else { return }
        do {
            try await channel.sendHeartbeat()
        } catch {
            await die("the helper's channel closed: \(error)")
        }
    }

    private func readLoop(channel: ExecChannel, decoder: HelperEventDecoder) async {
        var decoder = decoder
        while !Task.isCancelled {
            let chunk: Data
            do {
                // No deadline that could fire on a quiet tree: the helper's own heartbeat
                // every 15 s is what proves it is alive, and the wrapper kills it if we
                // stop writing. A read deadline here would tear down a healthy stream.
                chunk = try await channel.stream.read(
                    upTo: 256 * 1024, deadline: Date().addingTimeInterval(3600))
            } catch {
                await die("the helper's stream ended: \(error)")
                return
            }
            if chunk.isEmpty {
                await die("the helper exited")
                return
            }
            let events = decoder.append(chunk)
            guard !events.isEmpty else { continue }
            lastEventAt = Date().timeIntervalSince1970
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

    private func die(_ reason: String) async {
        guard state == .running else { return }
        state = .failed(reason)
        channel?.close()
        channel = nil
        beater?.cancel()
        Log.agent.error(
            "\(self.locationID, privacy: .public): the helper stream died: \(reason, privacy: .public)")
        await onDeath(reason)
    }

    // MARK: Reporting (section 8.1)

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
