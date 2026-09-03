import Foundation

/// Flattens an error so its message survives the trip across NSXPC.
///
/// NSXPC rebuilds an `NSError` on the far side from its domain, its code and its
/// `userInfo` dictionary. A Swift error that conforms to `LocalizedError` carries no
/// description *in* `userInfo`: Foundation computes one in-process, through a user-info
/// value provider registered for that error's concrete type, and the receiving process
/// has no such provider. So `ConfigStoreError.unknownLocation("nas")` reached the CLI as
/// `Config.ConfigStoreError error 1` instead of `No location matches "nas".`
/// (`docs/spikes/results.md`, 2026-09-04).
///
/// Every error the agent hands back to a peer goes through here first: the localized
/// strings are written into `userInfo` as plain strings, and the domain and the code are
/// preserved so the extension's mapping to `NSFileProviderError` (`SSHDriveAgentError`,
/// DESIGN.md section 5.1) still works. Values that are neither strings nor a nested error
/// are dropped rather than risking an encoding failure that would lose the whole reply.
public func sshDriveXPCError(_ error: Error) -> NSError {
    let nsError = error as NSError
    var info: [String: Any] = [:]

    for (key, value) in nsError.userInfo {
        if let string = value as? String { info[key] = string }
    }

    if info[NSLocalizedDescriptionKey] == nil {
        // `localizedDescription` already resolves through LocalizedError when the error is
        // a Swift value type; this is the call that pins the result into userInfo.
        let described = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if !described.isEmpty { info[NSLocalizedDescriptionKey] = described }
    }
    if info[NSLocalizedFailureReasonErrorKey] == nil,
        let reason = (error as? LocalizedError)?.failureReason
    {
        info[NSLocalizedFailureReasonErrorKey] = reason
    }
    if info[NSLocalizedRecoverySuggestionErrorKey] == nil,
        let suggestion = (error as? LocalizedError)?.recoverySuggestion
    {
        info[NSLocalizedRecoverySuggestionErrorKey] = suggestion
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        info[NSUnderlyingErrorKey] = sshDriveXPCError(underlying)
    }

    return NSError(domain: nsError.domain, code: nsError.code, userInfo: info)
}
