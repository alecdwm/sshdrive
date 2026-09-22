import AgentRuntime
import Foundation
import XCTest

/// Everything the agent's Darwin adapters mirror, asserted against Apple.
///
/// The same guard `ProviderCore` has (`MirroredProviderConstantsTests`), for the same
/// reason and in the same shape: `AgentRuntime` holds the agent's decisions and compiles on
/// Linux, so every framework number and name that crosses a seam is a copy. A copy that
/// drifted would be silent everywhere - the adapter would keep compiling, the Linux suite
/// would keep passing, and the mount would misbehave.
///
/// It runs on macOS only, for the obvious reason.
#if canImport(FileProvider) && canImport(ServiceManagement)

    import FileProvider
    import ServiceManagement

    final class MirroredAgentConstantsTests: XCTestCase {

        // MARK: The replica's `stat` (docs/design/eviction.md)

        /// `SF_DATALESS`. A dataless file has no blocks and carries this flag, which is how
        /// the TTL loop tells "materialized" from "placeholder" without asking the system.
        func testDatalessFlagIsApples() {
            XCTAssertEqual(MirroredAgentConstants.datalessFlag, UInt32(SF_DATALESS))
        }

        // MARK: Eviction refusals (measured 2026-09-04)

        /// All three codes, **including the two that are never seen**, because "we never
        /// see it" is the finding: an item with a pending upload and a kept item both come
        /// back `nonEvictable` rather than `unsyncedEdits`, and a directory eviction that
        /// meets a pending child fails as `NSCocoaErrorDomain` 4101 rather than
        /// `nonEvictableChildren` (`MQ-017`, `MQ-018`, `MQ-019`). Nothing above the seam
        /// branches on any of them; they travel in the reports `status` and the runbooks
        /// read, and the quirk table names them as numbers.
        func testEvictionRefusalCodesAreApples() {
            XCTAssertEqual(
                MirroredAgentConstants.nonEvictableCode,
                NSFileProviderError.Code.nonEvictable.rawValue)
            XCTAssertEqual(
                MirroredAgentConstants.unsyncedEditsCode,
                NSFileProviderError.Code.unsyncedEdits.rawValue)
            XCTAssertEqual(
                MirroredAgentConstants.nonEvictableChildrenCode,
                NSFileProviderError.Code.nonEvictableChildren.rawValue)
            // 4097 / 4099 / 4101 are Cocoa's XPC trio, and both of the two the agent meets
            // are in it: the eviction failure of `MQ-019` is a reply it could not read, and
            // the `add(domain)` report of `MQ-052` is an invalidated connection.
            XCTAssertEqual(
                MirroredAgentConstants.cocoaContentVersionMismatchCode,
                NSXPCConnectionReplyInvalid)
            XCTAssertEqual(
                MirroredAgentConstants.cocoaConnectionInvalidatedCode,
                NSXPCConnectionInvalid)
        }

        // MARK: The domain (docs/design/names-and-attributes.md, docs/design/packaging.md)

        /// `MQ-008`: `supportsSyncingTrash` **defaults to YES**, which is why the adapter
        /// clears it on every domain it adds. If this ever defaulted to NO the clearing
        /// would become dead code, and if the property vanished the `.Trash` hang of
        /// `MQ-009` would come back with nothing to point at.
        func testTrashSyncingDefaultsToYes() {
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: "mirror-test"),
                displayName: "mirror-test")
            XCTAssertTrue(domain.supportsSyncingTrash)
        }

        /// The two words `debug fake add --testing-modes` accepts, and the bits they mean.
        /// A word we do not know is ignored rather than guessed at: the system does not let
        /// a domain give `interactive` back once it has it.
        func testTestingModeBitsAreApples() {
            XCTAssertEqual(MirroredAgentConstants.testingModeAlways, "always")
            XCTAssertEqual(MirroredAgentConstants.testingModeInteractive, "interactive")
            XCTAssertEqual(NSFileProviderDomain.TestingModes.alwaysEnabled.rawValue, 1 << 0)
            XCTAssertEqual(NSFileProviderDomain.TestingModes.interactive.rawValue, 1 << 1)
        }

        // MARK: The login item (docs/design/packaging.md)

        /// `doctor` prints this string and treats only `enabled` as a pass, so a fifth case
        /// Apple adds must read as a warning rather than as a broken registration. The five
        /// names are distinct and none is empty; the four Apple cases keep their raw values.
        func testLoginItemStatusNamesCoverApplesCases() {
            let names = [
                MirroredAgentConstants.loginItemEnabled,
                MirroredAgentConstants.loginItemRequiresApproval,
                MirroredAgentConstants.loginItemNotRegistered,
                MirroredAgentConstants.loginItemNotFound,
                MirroredAgentConstants.loginItemUnknown,
            ]
            XCTAssertEqual(Set(names).count, 5)
            XCTAssertFalse(names.contains(""))
            XCTAssertEqual(SMAppService.Status.notRegistered.rawValue, 0)
            XCTAssertEqual(SMAppService.Status.enabled.rawValue, 1)
            XCTAssertEqual(SMAppService.Status.requiresApproval.rawValue, 2)
            XCTAssertEqual(SMAppService.Status.notFound.rawValue, 3)
        }
    }

#endif
