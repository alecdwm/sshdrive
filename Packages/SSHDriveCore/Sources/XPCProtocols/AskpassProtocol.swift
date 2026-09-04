import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// The askpass program's own interface to the agent (DESIGN.md section 4.2).
///
/// It is deliberately **not** part of `SSHDriveAgentProtocol`. The listener exports this
/// interface, and only this one, to a peer whose executable is our `sshdrive-askpass`,
/// and exports the agent interface to everyone else. `ssh` invokes the askpass with the
/// prompt on its command line, and any local process can invoke it too; the token is what
/// authorises the request, and a one-method interface means the path that hands out
/// secrets cannot also remove locations or evict caches (section 5.2).
@objc public protocol SSHDriveAskpassProtocol {

    /// One askpass invocation.
    ///
    /// - Parameters:
    ///   - token: `SSHDRIVE_ASKPASS_TOKEN` from the environment `ssh` passed down.
    ///   - promptKind: `SSH_ASKPASS_PROMPT` - "confirm", "none", or "" when unset, which
    ///     is what `ssh` leaves it at for a secret **and for the host-key question**.
    ///   - prompt: `ssh`'s prompt text, `argv[1]` of the askpass, verbatim.
    ///   - parentArguments: the argv of the askpass's parent `ssh`, read with
    ///     `sysctl KERN_PROCARGS2`. This is how the agent tells a `ProxyJump` hop apart
    ///     from the master whose environment, and token, it inherited.
    ///   - reply: the answer to print, or an error. An answer of `""` means "print an
    ///     empty line and exit 0", which is `ssh`'s "skip this identity"; an error means
    ///     print nothing and exit non-zero, which fails the prompt.
    @objc(askpassRequestWithToken:promptKind:prompt:parentArguments:reply:)
    func askpassRequest(
        token: String,
        promptKind: String,
        prompt: String,
        parentArguments: [String],
        reply: @escaping (String?, Error?) -> Void
    )
}

extension SSHDriveXPCInterface {
    /// The interface exported to `sshdrive-askpass`, and the one it configures its side
    /// with. `[String]` has to be whitelisted for the argument it appears in, like every
    /// collection NSXPC carries.
    public static var askpass: NSXPCInterface {
        let interface = NSXPCInterface(with: SSHDriveAskpassProtocol.self)
        // swiftlint:disable:next force_cast
        let classes = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        interface.setClasses(
            classes,
            for: #selector(SSHDriveAskpassProtocol.askpassRequest(
                token:promptKind:prompt:parentArguments:reply:)),
            argumentIndex: 3, ofReply: false)
        return interface
    }
}

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
