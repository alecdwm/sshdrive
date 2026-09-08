import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Reading another process's argv. The askpass uses it on its own parent, which is the
/// `ssh` that invoked it; `sysctl(KERN_PROCARGS2)` is readable for processes of the same
/// user, which the askpass and its parent always are.
public enum SSHDriveProcessArguments {

    /// The argv of `pid`, or an empty array when it cannot be read.
    public static func arguments(ofPID pid: Int32) -> [String] {
        #if canImport(Darwin)
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
            else { return [] }

            var buffer = [UInt8](repeating: 0, count: size)
            let read = buffer.withUnsafeMutableBytes { raw -> Bool in
                sysctl(&mib, 3, raw.baseAddress, &size, nil, 0) == 0
            }
            guard read, size > MemoryLayout<Int32>.size else { return [] }

            var argc: Int32 = 0
            withUnsafeMutableBytes(of: &argc) { destination in
                destination.copyBytes(from: buffer[0..<MemoryLayout<Int32>.size])
            }
            guard argc > 0 else { return [] }

            var index = MemoryLayout<Int32>.size
            // The executable path comes first, then padding NULs, then argc strings.
            while index < size, buffer[index] != 0 { index += 1 }
            while index < size, buffer[index] == 0 { index += 1 }

            var arguments: [String] = []
            var current: [UInt8] = []
            while index < size, arguments.count < Int(argc) {
                let byte = buffer[index]
                if byte == 0 {
                    arguments.append(String(decoding: current, as: UTF8.self))
                    current.removeAll(keepingCapacity: true)
                } else {
                    current.append(byte)
                }
                index += 1
            }
            return arguments
        #else
            return []
        #endif
    }

    /// The argv of this process's parent.
    public static func parentArguments() -> [String] {
        #if canImport(Darwin)
            return arguments(ofPID: getppid())
        #else
            return []
        #endif
    }
}
