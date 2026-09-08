import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

// The handful of libc calls this module makes by name. `Foundation` re-exports Darwin on
// macOS and Glibc on Linux, but the call sites spelled `Darwin.read` to say "the syscall,
// not the protocol method of the same name", and that spelling is Apple-only. These
// wrappers keep the disambiguation and cost nothing (docs/testing-architecture.md
// section 8, step 1.2). The Darwin path is the same call it always was.

@inline(__always)
func sshRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
        return Darwin.read(fd, buffer, count)
    #else
        return Glibc.read(fd, buffer, count)
    #endif
}

@inline(__always)
func sshWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
        return Darwin.write(fd, buffer, count)
    #else
        return Glibc.write(fd, buffer, count)
    #endif
}

@inline(__always)
@discardableResult
func sshClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
        return Darwin.close(fd)
    #else
        return Glibc.close(fd)
    #endif
}

@inline(__always)
@discardableResult
func sshConnect(
    _ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t
) -> Int32 {
    #if canImport(Darwin)
        return Darwin.connect(fd, address, length)
    #else
        return Glibc.connect(fd, address, length)
    #endif
}
