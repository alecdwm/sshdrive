import Foundation

/// One hit from a tier 1 sweep (DESIGN.md section 6.4).
///
/// Everything but `path` is nil on a `-print0` sweep, which is BSD and busybox: there the
/// agent `stat`s each path over SFTP, one round trip each. On GNU the `-printf` record
/// carries the whole of section 5.3's version inputs and no round trip is needed.
public struct SweepHit: Equatable, Sendable {
    /// Raw server bytes, exactly as `find` printed them. Never a `String`: a name need not
    /// be valid UTF-8 (section 5.4) and may contain a newline (section 9.2).
    public var path: Data
    /// `%y`: "d" or "f". Nil on a `-print0` sweep.
    public var type: String?
    public var size: Int64?
    /// Whole seconds, from the integer part of `%T@`.
    public var mtime: Int64?
    public var mtimeNanoseconds: Int64?
    public var inode: Int64?
    /// `%m` is octal digits, so "644" is 0o644 == 420.
    public var mode: Int64?
    public var uid: Int64?
    public var gid: Int64?

    public init(path: Data, type: String? = nil, size: Int64? = nil, mtime: Int64? = nil,
                mtimeNanoseconds: Int64? = nil, inode: Int64? = nil, mode: Int64? = nil,
                uid: Int64? = nil, gid: Int64? = nil) {
        self.path = path
        self.type = type
        self.size = size
        self.mtime = mtime
        self.mtimeNanoseconds = mtimeNanoseconds
        self.inode = inode
        self.mode = mode
        self.uid = uid
        self.gid = gid
    }

    /// True when the hit is a directory. Nil `type` means the sweep did not say, so the
    /// caller has to `stat`.
    public var isDirectory: Bool? {
        guard let type else { return nil }
        return type == "d"
    }
}

/// Reads what `SweepPlan`'s script printed (DESIGN.md sections 6.4 and 9.2).
///
/// The stream is NUL-delimited and is parsed as bytes from end to end. It is never split
/// on newlines: a filename may contain one, and a parser that split on them would turn one
/// file into two paths that exist on no server.
public enum SweepParser {

    /// `%p\0%y\0%s\0%T@\0%i\0%m\0%U\0%G\0` is eight fields per hit.
    private static let printfFieldCount = 8

    /// Parses one sweep's output.
    ///
    /// The first NUL-delimited record is the server's `date +%s`, which the agent stores
    /// only once the results have been applied to the index (section 6.4). Everything
    /// after it is either bare paths or eight-field records.
    ///
    /// A trailing partial record - the stream was cut, the channel died, the wrapper's
    /// heartbeat ran out mid-walk - is dropped rather than guessed. Half a record would
    /// otherwise become a hit with a truncated path, and a truncated path is a different
    /// file.
    public static func parse(_ output: Data, usesPrintf: Bool) -> (serverTime: Int64?, hits: [SweepHit]) {
        let records = nulDelimitedRecords(output)
        guard let first = records.first else { return (nil, []) }
        let serverTime = Int64(text(first))
        let body = records.dropFirst()

        guard usesPrintf else {
            // A bare -print0 stream. An empty record cannot be a path, so it is dropped;
            // that is the only thing a stray NUL can produce.
            return (serverTime, body.filter { !$0.isEmpty }.map { SweepHit(path: $0) })
        }

        var hits: [SweepHit] = []
        var fields = Array(body)
        // Whole records only: the last few fields of an interrupted hit are not a hit.
        let complete = (fields.count / printfFieldCount) * printfFieldCount
        fields.removeLast(fields.count - complete)
        hits.reserveCapacity(complete / printfFieldCount)
        var index = 0
        while index < complete {
            let (seconds, nanoseconds) = timestamp(fields[index + 3])
            hits.append(
                SweepHit(
                    path: fields[index],
                    type: text(fields[index + 1]),
                    size: Int64(text(fields[index + 2])),
                    mtime: seconds,
                    mtimeNanoseconds: nanoseconds,
                    inode: Int64(text(fields[index + 4])),
                    // `%m` is octal digits and nothing else; radix 8 is not a nicety.
                    mode: Int64(text(fields[index + 5]), radix: 8),
                    uid: Int64(text(fields[index + 6])),
                    gid: Int64(text(fields[index + 7]))))
            index += printfFieldCount
        }
        return (serverTime, hits)
    }

    /// Splits on NUL, keeping only records that were actually terminated. Anything after
    /// the last NUL is the partial record described above.
    private static func nulDelimitedRecords(_ output: Data) -> [Data] {
        var records: [Data] = []
        var start = output.startIndex
        var index = output.startIndex
        while index < output.endIndex {
            if output[index] == 0 {
                records.append(Data(output[start..<index]))
                start = output.index(after: index)
            }
            index = output.index(after: index)
        }
        return records
    }

    /// `%T@` prints seconds and a fraction, e.g. `1756900000.1234567890`. The fraction is
    /// padded or truncated to nine digits, because the index stores nanoseconds and GNU's
    /// digit count is not fixed.
    private static func timestamp(_ field: Data) -> (seconds: Int64?, nanoseconds: Int64?) {
        let value = text(field)
        guard !value.isEmpty else { return (nil, nil) }
        let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let seconds = Int64(parts[0])
        guard seconds != nil else { return (nil, nil) }
        guard parts.count == 2 else { return (seconds, 0) }
        var fraction = String(parts[1].prefix(9))
        while fraction.count < 9 { fraction.append("0") }
        return (seconds, Int64(fraction) ?? 0)
    }

    /// Every field but `%p` is ASCII digits or a single letter, so decoding is safe. The
    /// path is never put through this.
    private static func text(_ field: Data) -> String {
        String(decoding: field, as: UTF8.self)
    }
}
