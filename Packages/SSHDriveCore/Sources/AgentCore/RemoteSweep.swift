import Foundation
import Logging
import SSHProcess

/// One tier 1 sweep: the `find` pass of DESIGN.md section 6.4, run on one `sh -s` exec
/// channel under the heartbeat wrapper of section 9.2.
///
/// The channel is the scarcest thing a location has - on a `MaxSessions 2` server there
/// is exactly one, and it is shared with the probe - so a sweep opens one, uses it and
/// closes it rather than holding it between cycles. Nothing is started bare: the wrapper
/// backgrounds `find` with its stdin from `/dev/null` and kills it after 60 s of silence,
/// so a sweep of a very large tree on a connection that dies leaves nothing behind
/// (section 6.4, "Lifetime of anything we start on the server").
public enum RemoteSweep {

    public struct Outcome: Sendable {
        /// The server's own `date +%s`, printed before the first `find` runs. Stored only
        /// after the results have been applied, never before (section 6.4).
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

    public enum Failure: Error, LocalizedError {
        case noExecChannel(String)
        case timedOut(TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .noExecChannel(let why): return "no exec channel for the sweep: \(why)"
            case .timedOut(let seconds): return "the sweep did not finish within \(Int(seconds))s"
            }
        }
    }

    /// The whole sweep is one script. `find` never sees a root on a command line: the
    /// canonical root and every sweep root reach it through `set --` and are read as
    /// `"$@"`, so a directory named `$(rm -rf ~)` is data (section 9.2).
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

    public static func run(
        master: SSHMaster,
        canonicalRoot: String,
        plan: SweepPlan,
        timeout: TimeInterval = 300,
        readinessDeadline: TimeInterval = 30
    ) async throws -> Outcome {
        let sentinel = Sentinel()
        let started = Date()
        let channel: ExecChannel
        do {
            channel = try await master.openExecChannel(
                script: script(canonicalRoot: canonicalRoot, plan: plan, sentinel: sentinel),
                readinessDeadline: readinessDeadline)
        } catch let error as SSHProcessError {
            throw Failure.noExecChannel(error.localizedDescription)
        }
        defer { channel.close() }

        // The wrapper kills its child after 60 s of silence, so a sweep that outlives one
        // heartbeat interval needs the agent to keep writing (section 6.4).
        let beater = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                if Task.isCancelled { return }
                try? await channel.sendHeartbeat()
            }
        }
        defer { beater.cancel() }

        let marker = Data(sentinel.marker)
        var payload = Data()
        var truncated = true
        let deadline = started.addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk: Data
            do {
                chunk = try await channel.stream.read(upTo: 256 * 1024, deadline: deadline)
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
        // The agent stops writing and closes stdin; the wrapper reads EOF, kills whatever
        // is left of `find` and exits. Nothing we started outlives the channel.
        channel.endInput()

        let parsed = SweepParser.parse(payload, usesPrintf: plan.usesPrintf)
        let outcome = Outcome(
            serverTime: truncated ? nil : parsed.serverTime,
            hits: parsed.hits,
            duration: Date().timeIntervalSince(started),
            truncated: truncated,
            bytes: payload.count)
        Log.agent.notice(
            "sweep: \(outcome.hits.count, privacy: .public) hit(s) in \(String(format: "%.2f", outcome.duration), privacy: .public)s over \(plan.batches.count, privacy: .public) batch(es), \(outcome.bytes, privacy: .public) bytes\(outcome.truncated ? " (TRUNCATED)" : "", privacy: .public)"
        )
        if truncated, Date() >= deadline { throw Failure.timedOut(timeout) }
        return outcome
    }

    /// Byte search; the output is parsed as bytes throughout because a filename may
    /// contain a newline and need not be valid UTF-8 (sections 9.2, 5.4).
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
