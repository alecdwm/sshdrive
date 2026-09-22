import FileProvider
import Foundation
import ProviderCore
import XPCProtocols

/// The whole of the translation between Apple's File Provider vocabulary and
/// `ProviderCore`'s (`docs/design/testing.md`).
///
/// There is no decision in this file. Every rule about *which* error to answer lives in
/// `ProviderCore`; what is here is the one function that turns a `ProviderFailure` into
/// the `NSError` the system expects, and its inverse. The constants both halves rest on
/// are asserted against Apple's own in the macOS-only `MirroredProviderConstantsTests`.
enum AppleMapping {

    /// A `ProviderFailure` as the system wants it. Built from Apple's own symbols, never
    /// from a number, so this cannot be the thing that drifts.
    static func nsError(_ failure: ProviderFailure) -> NSError {
        switch failure {
        case .serverUnreachable: return NSFileProviderError(.serverUnreachable) as NSError
        case .noSuchItem: return NSFileProviderError(.noSuchItem) as NSError
        case .cannotSynchronize: return NSFileProviderError(.cannotSynchronize) as NSError
        case .syncAnchorExpired: return NSFileProviderError(.syncAnchorExpired) as NSError
        case .filenameCollision: return NSFileProviderError(.filenameCollision) as NSError
        case .notAuthenticated: return NSFileProviderError(.notAuthenticated) as NSError
        case .insufficientQuota: return NSFileProviderError(.insufficientQuota) as NSError
        case .deletionRejected: return NSFileProviderError(.deletionRejected) as NSError
        case .excludedFromSync: return NSFileProviderError(.excludedFromSync) as NSError
        case .nonEvictable:
            // `NSFileProviderErrorNonEvictable` has no Swift symbol; the number is the one
            // the VM measured (`MQ-018`).
            return NSError(
                domain: NSFileProviderErrorDomain, code: failure.appleErrorCode, userInfo: nil)
        case .featureUnsupported:
            // The trash refusal, with the sentence Finder shows (`MQ-010`).
            return SSHDriveTrash.unsupportedError
        }
    }

    /// Every error the agent hands back becomes a `ProviderFailure` before it reaches a
    /// decision (`docs/design/extension.md`).
    static func failure(from error: Error) -> ProviderFailure {
        let nsError = error as NSError
        if nsError.domain == NSFileProviderErrorDomain {
            return ProviderFailure(appleErrorCode: nsError.code)
        }
        guard let agentError = nsError.sshDriveAgentError else { return .serverUnreachable }
        return ProviderFailure(agentError: agentError)
    }

    // MARK: Identifiers and anchors

    static func identifier(_ identifier: NSFileProviderItemIdentifier) -> ProviderItemIdentifier {
        ProviderItemIdentifier(identifier.rawValue)
    }

    static func identifier(_ identifier: ProviderItemIdentifier) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(identifier.rawValue)
    }

    static func anchor(_ anchor: NSFileProviderSyncAnchor) -> ProviderSyncAnchor {
        ProviderSyncAnchor(String(decoding: anchor.rawValue, as: UTF8.self))
    }

    static func anchor(_ anchor: ProviderSyncAnchor) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(anchor.rawValue.utf8))
    }

    /// The system's two well-known first-page constants are not tokens of ours; anything
    /// else is a token we handed out.
    static func token(from page: NSFileProviderPage) -> ProviderPageToken? {
        if page.rawValue == NSFileProviderPage.initialPageSortedByName as Data { return nil }
        if page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data { return nil }
        let text = String(decoding: page.rawValue, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    static func page(from token: ProviderPageToken?) -> NSFileProviderPage? {
        token.map { NSFileProviderPage(Data($0.utf8)) }
    }
}
