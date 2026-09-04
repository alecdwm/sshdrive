import Foundation

/// One line of the NDJSON stream the remote helper writes (DESIGN.md section 6.4 tier 2).
///
/// `{"op":"create|modify|delete|rename|overflow","path":…,"from":…,"size":…,
/// "mtime_ns":…,"inode":…}` plus a heartbeat every 15 s, and two lines section 6.4 does
/// not name but the stream needs: `ready`, which is what "settling on the first tier that
/// starts successfully" is decided on, and `error`, so a helper that cannot watch says
/// why (2026-09-05, section 13).
///
/// A path arrives as `path` when its bytes are UTF-8 and as `path_b64` when they are not,
/// because a JSON string is UTF-8 by definition and a server filename need not be
/// (section 5.4). Either way what comes out here is the same bytes the index stores.
public struct HelperEvent: Equatable, Sendable {

    public enum Kind: String, Sendable {
        case ready
        case create
        case modify
        case delete
        case rename
        case overflow
        case heartbeat
        case error
        case sweepStart = "sweep_start"
        case sweepEnd = "sweep_end"
    }

    public var kind: Kind
    /// The path the event is about, relative to the location root, in server bytes.
    public var path: Data?
    /// A rename's old path.
    public var from: Data?
    /// "f" or "d".
    public var type: String?
    public var size: Int64?
    public var mtimeNanoseconds: Int64?
    public var inode: Int64?
    public var mode: Int64?
    public var uid: Int64?
    public var gid: Int64?
    /// `ready`'s fields, and `error`/`overflow`'s message.
    public var version: String?
    public var mechanism: String?
    public var message: String?
    public var serverTime: Int64?

    public init(kind: Kind) { self.kind = kind }

    /// Whole seconds, which is what the content version is built from (section 5.3, gotcha
    /// 10: whole-second mtime "at every tier, so a tier change is invisible").
    public var mtimeSeconds: Int64? {
        guard let ns = mtimeNanoseconds else { return nil }
        return ns / 1_000_000_000
    }

    /// True when the event carries everything a row needs, so the agent does not `lstat`.
    public var isSelfSufficient: Bool {
        size != nil && mtimeNanoseconds != nil && mode != nil && type != nil
    }
}

/// Reads the stream a line at a time.
///
/// Framing, not parsing, is the thing that has to be right: the channel hands over
/// arbitrary chunks, one line may arrive in six reads and six lines in one. And the
/// decoder is where backpressure lives - section 6.4 puts "server-side batching and
/// filtering" on the helper, but a helper that has just seen a `rm -rf` can still outrun
/// the agent, so a bounded buffer turns a flood into one `overflow`, which the agent
/// answers with a sweep. Dropping to a sweep is always safe; growing without limit is not.
public struct HelperEventDecoder: Sendable {

    /// A single line longer than this is not a line we wrote.
    public static let lineLimit = 1 << 20
    /// How many events one `append` may return before the rest becomes an overflow.
    public static let batchLimit = 5_000

    private var buffer = Data()
    /// Set when a line was discarded; the next batch carries the overflow that says so.
    private var overflowed: String?

    public init() {}

    public mutating func append(_ chunk: Data) -> [HelperEvent] {
        buffer.append(chunk)
        var events: [HelperEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard events.count < HelperEventDecoder.batchLimit else {
                overflowed = "the helper produced more than \(HelperEventDecoder.batchLimit) events at once"
                continue
            }
            if let event = HelperEventDecoder.decode(line) { events.append(event) }
        }
        if buffer.count > HelperEventDecoder.lineLimit {
            overflowed = "a helper line exceeded \(HelperEventDecoder.lineLimit) bytes"
            buffer.removeAll(keepingCapacity: false)
        }
        if let reason = overflowed {
            overflowed = nil
            var event = HelperEvent(kind: .overflow)
            event.message = reason
            events.append(event)
        }
        return events
    }

    /// Anything left when the stream ends. A trailing partial line is dropped: half a
    /// record is a different path.
    public mutating func finish() -> [HelperEvent] {
        buffer.removeAll()
        return []
    }

    public static func decode(_ line: Data) -> HelperEvent? {
        guard !line.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        guard let op = object["op"] as? String, let kind = HelperEvent.Kind(rawValue: op) else {
            return nil
        }
        var event = HelperEvent(kind: kind)
        event.path = HelperEventDecoder.bytes(object, "path")
        event.from = HelperEventDecoder.bytes(object, "from")
        event.type = object["type"] as? String
        event.size = HelperEventDecoder.integer(object["size"])
        event.mtimeNanoseconds = HelperEventDecoder.integer(object["mtime_ns"])
        event.inode = HelperEventDecoder.integer(object["inode"])
        event.mode = HelperEventDecoder.integer(object["mode"])
        event.uid = HelperEventDecoder.integer(object["uid"])
        event.gid = HelperEventDecoder.integer(object["gid"])
        event.version = object["version"] as? String
        event.mechanism = object["mechanism"] as? String
        event.message = (object["message"] as? String) ?? (object["reason"] as? String)
        event.serverTime = HelperEventDecoder.integer(object["server_time"])
        return event
    }

    /// `<key>` as UTF-8 bytes, or `<key>_b64` decoded. Both spellings produce the same
    /// server bytes; only the encoding differs.
    private static func bytes(_ object: [String: Any], _ key: String) -> Data? {
        if let text = object[key] as? String { return Data(text.utf8) }
        if let encoded = object[key + "_b64"] as? String {
            return Data(base64Encoded: encoded)
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}

/// The other direction: the root set, as one control line.
///
/// Section 6.4: "When it changes, the helper (tier 2) is sent the new set on its stdin and
/// applies it live." A root whose bytes are not UTF-8 travels as `{"b64":"…"}`, which is
/// the one thing tier 1 could not do - `set --` is a String pipeline end to end (section
/// 9.2), so such a root has to be dropped from a sweep and listed at tier 0 instead. The
/// helper has no such limit, and this is where that shows.
public enum HelperControl {

    public static func rootsLine(shallow: [Data], recursive: [Data], excluded: [Data]) -> Data {
        var object: [String: Any] = ["op": "roots"]
        object["shallow"] = shallow.map(encode)
        object["recursive"] = recursive.map(encode)
        object["excluded"] = excluded.map(encode)
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return Data("{\"op\":\"roots\",\"shallow\":[],\"recursive\":[],\"excluded\":[]}\n".utf8)
        }
        data.append(0x0A)
        return data
    }

    private static func encode(_ path: Data) -> Any {
        if let text = String(data: path, encoding: .utf8) { return text }
        return ["b64": path.base64EncodedString()]
    }
}
