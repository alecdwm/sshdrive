/// Version of the XPC interface. A mismatched agent and extension (mid upgrade) is
/// reported as `.serverUnreachable` until the agent restarts (DESIGN.md section 5.2).
///
/// A plain integer, so it stays here beside the value types; the `@objc` protocol that
/// negotiates it lives in `XPCInterfaces`, which only the app targets link.
public let sshDriveXPCInterfaceVersion = 4
