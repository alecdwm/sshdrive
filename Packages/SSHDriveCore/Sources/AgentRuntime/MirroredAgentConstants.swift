import Foundation

/// The Apple constants the agent's Darwin adapters mirror, in one place, so the macOS-only
/// `MirroredAgentConstantsTests` can assert each one against Apple's own.
///
/// This is the same guard `ProviderCore`'s mirrored capabilities and error codes have
/// (`MirroredProviderConstantsTests`, step 1.3), for the same reason: a number that drifts
/// silently is the only kind of breakage a Linux suite cannot see. It caught five wrong
/// error codes the first time it ran on the extension's side.
///
/// Nothing above the seam **branches** on the eviction codes - S4 measured that the code
/// says nothing about why (`MQ-017`, `MQ-018`, `MQ-019`) - but they travel in the reports
/// `status` and the runbooks read, and the quirk table names them as numbers, so they are
/// asserted here rather than left as prose.
public enum MirroredAgentConstants {

    // MARK: The replica's `stat` (section 7)

    /// `SF_DATALESS`. A dataless file has no blocks and carries this flag, which is how the
    /// TTL loop can tell "materialized" from "placeholder" without asking the system.
    public static let datalessFlag: UInt32 = 0x4000_0000

    // MARK: Eviction refusals (S4, 2026-09-04)

    /// `NSFileProviderError.nonEvictable`. **Both** an item with a pending upload and a
    /// kept item come back as this, never the documented `unsyncedEdits`, so nothing may be
    /// inferred from it beyond "not now" (`MQ-018`).
    public static let nonEvictableCode = -2008
    /// `NSFileProviderError.unsyncedEdits`, which is what the documentation says a pending
    /// item should give and what it never gave (`MQ-018`).
    public static let unsyncedEditsCode = -2007
    /// `NSFileProviderError.nonEvictableChildren`, likewise never seen: evicting the parent
    /// of a pending item fails as `NSCocoaErrorDomain` 4101 instead (`MQ-019`).
    public static let nonEvictableChildrenCode = -2006
    /// `NSXPCConnectionReplyInvalid` - "Couldn't communicate with a helper application" -
    /// which is the opaque failure a directory eviction that meets a pending child actually
    /// gives, with `libfssync.VFSFileTree.ItemNotFoundReason` 5 `contentVersionMismatch`
    /// underneath. Not `nonEvictableChildren`, and not a file error at all (`MQ-019`).
    public static let cocoaContentVersionMismatchCode = 4101
    /// `NSXPCConnectionInvalid`: what `add(domain)` reports *after* the call has landed
    /// while fileproviderd is re-reading its domain list, which is why the domain list is
    /// the authority and not the error (`MQ-052`).
    public static let cocoaConnectionInvalidatedCode = 4099

    // MARK: The login item (section 10)

    /// The four `SMAppService.Status` cases, as `LoginItemControlling.status()` names them.
    /// `doctor` prints the string and `AgentLifecycle` logs it; only `"enabled"` is a pass.
    public static let loginItemEnabled = "enabled"
    public static let loginItemRequiresApproval = "requires approval"
    public static let loginItemNotRegistered = "not registered"
    public static let loginItemNotFound = "not found"
    /// A case Apple adds that we have not seen. `doctor` shows it as a warning rather than
    /// a failure, because an unknown status is not evidence of a broken registration.
    public static let loginItemUnknown = "unknown"

    // MARK: The domain's testing modes (spikes S4 and S6)

    /// `NSFileProviderDomain.TestingModes.alwaysEnabled`, as `debug fake add
    /// --testing-modes` spells it.
    public static let testingModeAlways = "always"
    /// `NSFileProviderDomain.TestingModes.interactive`.
    public static let testingModeInteractive = "interactive"
}
