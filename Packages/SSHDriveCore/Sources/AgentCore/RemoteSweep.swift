import Foundation
import Logging
import SSHProcess

/// One tier 1 sweep: the `find` pass of docs/design/change-detection.md, run on one
/// `sh -s` exec channel under the heartbeat wrapper (docs/design/security.md).
///
/// The channel is the scarcest thing a location has - on a `MaxSessions 2` server there
/// is exactly one, and it is shared with the probe - so a sweep opens one, uses it and
/// closes it rather than holding it between cycles. Nothing is started bare: the wrapper
/// backgrounds `find` with its stdin from `/dev/null` and kills it after 60 s of silence,
/// so a sweep of a very large tree on a connection that dies leaves nothing behind
/// (docs/design/change-detection.md, on the lifetime of anything we start on the
/// server).
public enum RemoteSweep {

    public struct Outcome: Sendable {
        /// The server's own `date +%s`, printed before the first `find` runs. Stored only
        /// after the results have been applied, never before
        /// (docs/design/change-detection.md).
        public var serverTime: Int64?
        public var hits: [SweepHit]
        public var duration: TimeInterval
        /// True when the closing sentinel never arrived: the output is a prefix of the
        /// sweep, and the server timestamp must NOT be stored.
        public var truncated: Bool
        public var bytes: Int

        public init(serverTime: Int64?, hits: [SweepHit], duration: TimeInterval,
                    truncated: Bool, bytes: Int) {
            self.serverTime = serverTime
            self.hits = hits
            self.duration = duration
            self.truncated = truncated
            self.bytes = bytes
        }
    }

    /// Why a sweep produced no outcome. `find` itself never fails the sweep: the script
    /// runs it as `find … || true`, so a `find` that is missing or rejects an option
    /// produces an empty, complete sweep, and whether the server has a usable `find` is
    /// the probe's answer, not the sweep's.
    public enum Failure: Error, LocalizedError {
        /// The channel could not be opened: the connection went, the server refused a
        /// session, the shell's output was unusable this time.
        case noExecChannel(String)
        /// The account has no shell at all (`ForceCommand internal-sftp`). The one failure
        /// that is a fact about the server rather than about this attempt.
        case noShellAccess(String)
        /// The closing sentinel did not arrive in time: a `find` stuck on an NFS mount, a
        /// connection that stalled, or a Mac that slept through the deadline.
        case timedOut(TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .noExecChannel(let why): return "no exec channel for the sweep: \(why)"
            case .noShellAccess(let why): return "the account has no shell access: \(why)"
            case .timedOut(let seconds): return "the sweep did not finish within \(Int(seconds))s"
            }
        }

        /// True for a failure that says something about the server and will be just as
        /// true on the next attempt over this connection. Everything else is about this
        /// attempt.
        public var isServerVerdict: Bool {
            if case .noShellAccess = self { return true }
            return false
        }
    }

    /// The whole sweep is one script. `find` never sees a root on a command line: the
    /// canonical root and every sweep root reach it through `set --` and are read as
    /// `"$@"`, so a directory named `$(rm -rf ~)` is data (docs/design/security.md).
    ///
    /// The script `cd`s to the canonical root first and passes `find` relative roots, so
    /// nothing here has to reproduce the join the transport does, and the output comes
    /// back in exactly the form the index stores.
    public static func script(canonicalRoot: String, plan: SweepPlan, sentinel: Sentinel)
        -> RemoteScript
    {
        let inner = plan.script()
        let body = """
            __sd_root="$1"; shift
            cd -- "$__sd_root" || exit 1
            \(inner.body)
            printf '%s' '\(sentinel.hex)'; printf '\\000'
            """
        return RemoteScript(
            sentinel: sentinel,
            arguments: [canonicalRoot] + inner.arguments,
            body: body,
            heartbeat: .standard)
    }

    /// `clock` paces the heartbeat and bounds the read; the system clock unless a
    /// scenario drives one.
    public static func run(
        master: any RemoteMaster,
        canonicalRoot: String,
        plan: SweepPlan,
        timeout: TimeInterval = 300,
        readinessDeadline: TimeInterval = 30,
        clock: any TimeSource = SystemTimeSource()
    ) async throws -> Outcome {
        let sentinel = Sentinel()
        let started = clock.now()
        let channel: any RemoteExecChannel
        do {
            channel = try await master.openExecChannel(
                script: script(canonicalRoot: canonicalRoot, plan: plan, sentinel: sentinel),
                readinessDeadline: readinessDeadline)
        } catch let error as SSHProcessError {
            if case .noShellAccess = error { throw Failure.noShellAccess(error.localizedDescription) }
            throw Failure.noExecChannel(error.localizedDescription)
        }
        defer { channel.close() }

        // The wrapper kills its child after 60 s of silence, so a sweep that outlives one
        // heartbeat interval needs the agent to keep writing
        // (docs/design/change-detection.md).
        let beater = Task {
            while !Task.isCancelled {
                await clock.sleep(seconds: 15)
                if Task.isCancelled { return }
                try? await channel.sendHeartbeat()
            }
        }
        defer { beater.cancel() }

        let deadline = started + timeout
        let outcome = await collect(
            stream: channel.stream, sentinel: sentinel, usesPrintf: plan.usesPrintf,
            batches: plan.batches.count, started: Date(timeIntervalSince1970: started),
            deadline: Date(timeIntervalSince1970: deadline), clock: clock)
        // The agent stops writing and closes stdin; the wrapper reads EOF, kills whatever
        // is left of `find` and exits. Nothing we started outlives the channel.
        channel.endInput()

        if outcome.truncated, clock.now() >= deadline { throw Failure.timedOut(timeout) }
        return outcome
    }

    /// Reads one sweep off a channel and turns it into an `Outcome`.
    ///
    /// Split out of `run` so that a scenario can drive it against a **real** exec channel
    /// whose remote end really died mid-sweep (`H5`), rather than reproducing the read
    /// loop - or, worse, hand-building an `Outcome` and asserting against the thing it
    /// just wrote. Everything the rule depends on is here: the scan for the closing
    /// sentinel, and `truncated`.
    ///
    /// **The closing sentinel is the only end-of-sweep there is.** EOF is not one: an
    /// account whose rc file leaves a background child holding stdout never sends it
    /// (`SQ-016`), and a channel that died mid-walk sends it *early*. So the marker is the
    /// signal, and its absence means the output is a prefix of a sweep - at which point
    /// the server's stamp must not be stored, however plainly it arrived in the first
    /// record. Storing it would move the window forward over changes this sweep never got
    /// as far as reporting, and nothing would look at them again until the 30-minute
    /// insurance pass (docs/design/change-detection.md).
    ///
    /// `started` and `deadline` are on `clock`'s wall clock, and so is the duration.
    public static func collect(
        stream: ByteStream,
        sentinel: Sentinel,
        usesPrintf: Bool,
        batches: Int = 1,
        started: Date? = nil,
        deadline: Date,
        clock: any TimeSource = SystemTimeSource()
    ) async -> Outcome {
        let started = started ?? Date(timeIntervalSince1970: clock.now())
        let marker = Data(sentinel.marker)
        var payload = Data()
        var truncated = true
        while clock.now() < deadline.timeIntervalSince1970 {
            let chunk: Data
            do {
                chunk = try await stream.read(upTo: 256 * 1024, deadline: deadline)
            } catch {
                break
            }
            if chunk.isEmpty { break }
            let scanFrom = max(0, payload.count - (marker.count - 1))
            payload.append(chunk)
            if let index = find(marker, in: payload, from: scanFrom) {
                payload = payload.prefix(index)
                truncated = false
                break
            }
        }

        let parsed = SweepParser.parse(payload, usesPrintf: usesPrintf)
        let outcome = Outcome(
            serverTime: truncated ? nil : parsed.serverTime,
            hits: parsed.hits,
            duration: clock.now() - started.timeIntervalSince1970,
            truncated: truncated,
            bytes: payload.count)
        Log.agent.notice(
            "sweep: \(outcome.hits.count, privacy: .public) hit(s) in \(String(format: "%.2f", outcome.duration), privacy: .public)s over \(batches, privacy: .public) batch(es), \(outcome.bytes, privacy: .public) bytes\(outcome.truncated ? " (TRUNCATED)" : "", privacy: .public)"
        )
        return outcome
    }

    /// Byte search; the output is parsed as bytes throughout because a filename may contain a
    /// newline and need not be valid UTF-8 (docs/design/security.md,
    /// docs/design/names-and-attributes.md).
    public static func find(_ needle: Data, in haystack: Data, from: Int = 0) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let bytes = [UInt8](haystack)
        let pattern = [UInt8](needle)
        var index = max(0, from)
        let last = bytes.count - pattern.count
        while index <= last {
            if bytes[index] == pattern[0] {
                var offset = 1
                while offset < pattern.count, bytes[index + offset] == pattern[offset] { offset += 1 }
                if offset == pattern.count { return index }
            }
            index += 1
        }
        return nil
    }
}
