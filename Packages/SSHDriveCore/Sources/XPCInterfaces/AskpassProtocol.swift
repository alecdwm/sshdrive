#if canImport(Darwin)

import Foundation

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

#endif
