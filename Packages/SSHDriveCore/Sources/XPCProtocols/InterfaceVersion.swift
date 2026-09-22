/// Version of the XPC interface. A mismatched agent and extension (mid upgrade) is
/// reported as `.serverUnreachable` until the agent restarts (docs/design/extension.md).
///
/// A plain integer, so it stays here beside the value types; the `@objc` protocol that
/// negotiates it lives in `XPCInterfaces`, which only the app targets link.
public let sshDriveXPCInterfaceVersion = 4
