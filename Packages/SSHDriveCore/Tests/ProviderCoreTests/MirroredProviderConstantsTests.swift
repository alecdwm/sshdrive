import XCTest
import ProviderCore
import XPCProtocols

/// Everything `ProviderCore` mirrors from Apple, asserted against Apple (step 1.3 of
/// `docs/testing-architecture.md` section 8; step 4 promotes this into
/// `AppleConstantsTests`).
///
/// `ProviderCore` holds the extension's decisions and compiles on Linux, so every
/// identifier literal, capability bit, `fileSystemFlags` bit, `changedFields` bit and
/// error code it names is a copy of a framework constant. A copy that drifted would be
/// silent everywhere: the adapter would keep compiling, the Linux suite would keep
/// passing, and the mount would misbehave. This file is one assert per constant and it is
/// the only thing standing between us and that.
///
/// It runs on macOS only, for the obvious reason.
#if canImport(FileProvider)

    import FileProvider

    final class MirroredProviderConstantsTests: XCTestCase {

        // MARK: Identifiers

        /// The three well-known container identifiers are string literals in the
        /// framework, and both processes have always had to spell them the same way: the
        /// index's root row carries the root literal, and the trash refusal of
        /// section 5.4 is keyed on the trash one. Because they match, the adapter's
        /// identifier mapping is the identity - which is worth knowing, and worth
        /// asserting rather than assuming.
        func testContainerIdentifierLiteralsAreApples() {
            XCTAssertEqual(
                ProviderItemIdentifier.rootContainer.rawValue,
                NSFileProviderItemIdentifier.rootContainer.rawValue)
            XCTAssertEqual(
                ProviderItemIdentifier.workingSet.rawValue,
                NSFileProviderItemIdentifier.workingSet.rawValue)
            XCTAssertEqual(
                ProviderItemIdentifier.trashContainer.rawValue,
                NSFileProviderItemIdentifier.trashContainer.rawValue)
            // The same literal, reached the other way: `XPCProtocols` carries it for the
            // processes that do not link FileProvider at all.
            XCTAssertEqual(
                SSHDriveTrash.containerIdentifier,
                NSFileProviderItemIdentifier.trashContainer.rawValue)
        }

        // MARK: Capabilities and flags

        func testCapabilityBitsAreApples() {
            XCTAssertEqual(
                ProviderCapabilities.allowsReading.rawValue,
                NSFileProviderItemCapabilities.allowsReading.rawValue)
            XCTAssertEqual(
                ProviderCapabilities.allowsWriting.rawValue,
                NSFileProviderItemCapabilities.allowsWriting.rawValue)
            XCTAssertEqual(
                ProviderCapabilities.allowsReparenting.rawValue,
                NSFileProviderItemCapabilities.allowsReparenting.rawValue)
            XCTAssertEqual(
                ProviderCapabilities.allowsRenaming.rawValue,
                NSFileProviderItemCapabilities.allowsRenaming.rawValue)
            XCTAssertEqual(
                ProviderCapabilities.allowsTrashing.rawValue,
                NSFileProviderItemCapabilities.allowsTrashing.rawValue)
            XCTAssertEqual(
                ProviderCapabilities.allowsDeleting.rawValue,
                NSFileProviderItemCapabilities.allowsDeleting.rawValue)
            XCTAssertEqual(
                ProviderCapabilities.allowsEvicting.rawValue,
                NSFileProviderItemCapabilities.allowsEvicting.rawValue)
            XCTAssertEqual(
                ProviderCapabilities.allowsExcludingFromSync.rawValue,
                NSFileProviderItemCapabilities.allowsExcludingFromSync.rawValue)
            XCTAssertEqual(
                ProviderCapabilities.allowsAddingSubItems.rawValue,
                NSFileProviderItemCapabilities.allowsAddingSubItems.rawValue)
            XCTAssertEqual(
                ProviderCapabilities.allowsContentEnumerating.rawValue,
                NSFileProviderItemCapabilities.allowsContentEnumerating.rawValue)
        }

        func testFileSystemFlagBitsAreApples() {
            XCTAssertEqual(
                ProviderFileSystemFlags.userExecutable.rawValue,
                NSFileProviderFileSystemFlags.userExecutable.rawValue)
            XCTAssertEqual(
                ProviderFileSystemFlags.userReadable.rawValue,
                NSFileProviderFileSystemFlags.userReadable.rawValue)
            XCTAssertEqual(
                ProviderFileSystemFlags.userWritable.rawValue,
                NSFileProviderFileSystemFlags.userWritable.rawValue)
            XCTAssertEqual(
                ProviderFileSystemFlags.hidden.rawValue,
                NSFileProviderFileSystemFlags.hidden.rawValue)
            XCTAssertEqual(
                ProviderFileSystemFlags.pathExtensionHidden.rawValue,
                NSFileProviderFileSystemFlags.pathExtensionHidden.rawValue)
        }

        /// `changedFields` is the one mirrored mask whose *values* three measured quirks
        /// name outright: a Finder rename is `0x2` (`MQ-048`), a tag change `0x10`
        /// (`MQ-042`) and a `chmod` `0x100` (`MQ-047`).
        func testItemFieldBitsAreApples() {
            XCTAssertEqual(
                ProviderItemFields.contents.rawValue, NSFileProviderItemFields.contents.rawValue)
            XCTAssertEqual(
                ProviderItemFields.filename.rawValue, NSFileProviderItemFields.filename.rawValue)
            XCTAssertEqual(
                ProviderItemFields.parentItemIdentifier.rawValue,
                NSFileProviderItemFields.parentItemIdentifier.rawValue)
            XCTAssertEqual(
                ProviderItemFields.lastUsedDate.rawValue,
                NSFileProviderItemFields.lastUsedDate.rawValue)
            XCTAssertEqual(
                ProviderItemFields.tagData.rawValue, NSFileProviderItemFields.tagData.rawValue)
            XCTAssertEqual(
                ProviderItemFields.favoriteRank.rawValue,
                NSFileProviderItemFields.favoriteRank.rawValue)
            XCTAssertEqual(
                ProviderItemFields.creationDate.rawValue,
                NSFileProviderItemFields.creationDate.rawValue)
            XCTAssertEqual(
                ProviderItemFields.contentModificationDate.rawValue,
                NSFileProviderItemFields.contentModificationDate.rawValue)
            XCTAssertEqual(
                ProviderItemFields.fileSystemFlags.rawValue,
                NSFileProviderItemFields.fileSystemFlags.rawValue)
            XCTAssertEqual(
                ProviderItemFields.extendedAttributes.rawValue,
                NSFileProviderItemFields.extendedAttributes.rawValue)
            XCTAssertEqual(
                ProviderItemFields.typeAndCreator.rawValue,
                NSFileProviderItemFields.typeAndCreator.rawValue)

            // The three the quirk table states as numbers.
            XCTAssertEqual(ProviderItemFields.filename.rawValue, 0x2, "MQ-048")
            XCTAssertEqual(ProviderItemFields.tagData.rawValue, 0x10, "MQ-042")
            XCTAssertEqual(ProviderItemFields.fileSystemFlags.rawValue, 0x100, "MQ-047")
        }

        // MARK: Error codes

        /// Which error the extension answers is the rule the 0.1.2 failure got wrong, so
        /// the numbers behind each `ProviderFailure` are asserted against the framework's
        /// own codes, one at a time.
        func testFailureCodesAreApples() {
            XCTAssertEqual(
                ProviderFailure.notAuthenticated.appleErrorCode,
                NSFileProviderError.Code.notAuthenticated.rawValue)
            XCTAssertEqual(
                ProviderFailure.filenameCollision.appleErrorCode,
                NSFileProviderError.Code.filenameCollision.rawValue)
            XCTAssertEqual(
                ProviderFailure.syncAnchorExpired.appleErrorCode,
                NSFileProviderError.Code.syncAnchorExpired.rawValue)
            XCTAssertEqual(
                ProviderFailure.insufficientQuota.appleErrorCode,
                NSFileProviderError.Code.insufficientQuota.rawValue)
            XCTAssertEqual(
                ProviderFailure.serverUnreachable.appleErrorCode,
                NSFileProviderError.Code.serverUnreachable.rawValue)
            XCTAssertEqual(
                ProviderFailure.noSuchItem.appleErrorCode,
                NSFileProviderError.Code.noSuchItem.rawValue)
            XCTAssertEqual(
                ProviderFailure.deletionRejected.appleErrorCode,
                NSFileProviderError.Code.deletionRejected.rawValue)
            XCTAssertEqual(
                ProviderFailure.cannotSynchronize.appleErrorCode,
                NSFileProviderError.Code.cannotSynchronize.rawValue)
            XCTAssertEqual(
                ProviderFailure.excludedFromSync.appleErrorCode,
                NSFileProviderError.Code.excludedFromSync.rawValue)

            // `NSFileProviderErrorNonEvictable` has no Swift symbol to compare against;
            // the number is the one `evictItem` returned on the VM for a pending upload
            // and for a kept item alike (`MQ-018`, results 2026-09-04 s4-3, s6-5).
            XCTAssertEqual(ProviderFailure.nonEvictable.appleErrorCode, -2008, "MQ-018")

            // The trash refusal's domain and code (`MQ-010`).
            XCTAssertEqual(
                ProviderFailure.featureUnsupported.appleErrorCode, NSFeatureUnsupportedError)
            XCTAssertEqual(ProviderFailure.featureUnsupported.appleErrorDomain, NSCocoaErrorDomain)
        }

        /// Every other failure is raised in the File Provider domain, and the adapter's
        /// one mapping function has to say so.
        func testFailureDomainsAreApples() {
            for failure: ProviderFailure in [
                .serverUnreachable, .noSuchItem, .cannotSynchronize, .syncAnchorExpired,
                .filenameCollision, .notAuthenticated, .insufficientQuota, .nonEvictable,
                .deletionRejected, .excludedFromSync,
            ] {
                XCTAssertEqual(failure.appleErrorDomain, NSFileProviderErrorDomain)
            }
        }

        /// The content policy is mapped by symbol, not by number, in both directions -
        /// but the two enums have to agree case for case or a pinned item would be served
        /// the wrong policy, and `MQ-024` says the policy is what refuses an eviction.
        func testContentPolicyCasesLineUp() {
            XCTAssertEqual(
                ProviderContentPolicy.inherited.rawValue, SSHDriveContentPolicy.inherited.rawValue)
            XCTAssertEqual(
                ProviderContentPolicy.downloadLazily.rawValue,
                SSHDriveContentPolicy.downloadLazily.rawValue)
            XCTAssertEqual(
                ProviderContentPolicy.downloadEagerlyAndKeepDownloaded.rawValue,
                SSHDriveContentPolicy.downloadEagerlyAndKeepDownloaded.rawValue)
            XCTAssertEqual(
                ProviderContentPolicy.unset.rawValue, SSHDriveContentPolicy.unset.rawValue)
        }
    }

#endif
