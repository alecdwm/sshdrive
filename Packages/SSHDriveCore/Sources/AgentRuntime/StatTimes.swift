import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// The two `struct stat` fields the agent reads by name, spelled once.
///
/// Darwin calls them `st_mtimespec`/`st_atimespec` and Linux calls them
/// `st_mtim`/`st_atim`. The Darwin branch is byte-for-byte the call it always was; the
/// Linux one exists so `IndexReconcile`'s replica walk compiles here, where it is driven
/// by a fake replica rather than by `~/Library/CloudStorage`.
enum StatTimes {
    @inline(__always)
    static func modificationSeconds(of buffer: stat) -> Int {
        #if canImport(Darwin)
            return buffer.st_mtimespec.tv_sec
        #else
            return buffer.st_mtim.tv_sec
        #endif
    }

    @inline(__always)
    static func accessSeconds(of buffer: stat) -> Int {
        #if canImport(Darwin)
            return buffer.st_atimespec.tv_sec
        #else
            return buffer.st_atim.tv_sec
        #endif
    }
}
