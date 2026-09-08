#if canImport(FileProvider)
    import FileProvider
#endif
import XCTest
@testable import XPCProtocols

/// SSH Drive has no trash (DESIGN.md section 5.4). The system gives a replicated domain
/// one anyway unless it is told otherwise, and the extension's answers about it are what
/// decide whether a `stat` of `.Trash` returns or loops (docs/spikes/results.md,
/// 2026-09-04).
final class TrashTests: XCTestCase {

    /// The identifier is written out in XPCProtocols so the module does not link
    /// FileProvider. If Apple ever changes the constant, this is what says so. macOS
    /// only: it is an assertion about Apple's constant, which is step 4's
    /// `AppleConstantsTests` (docs/testing-architecture.md section 8).
    #if canImport(FileProvider)
        func testContainerIdentifierMatchesTheFrameworkConstant() {
            XCTAssertEqual(
                SSHDriveTrash.containerIdentifier,
                NSFileProviderItemIdentifier.trashContainer.rawValue)
        }

        func testOnlyTheTrashContainerIsRefusedByIdentifier() {
            XCTAssertTrue(
                SSHDriveTrash.isTrash(
                    identifier: NSFileProviderItemIdentifier.trashContainer.rawValue))
            XCTAssertFalse(
                SSHDriveTrash.isTrash(
                    identifier: NSFileProviderItemIdentifier.rootContainer.rawValue))
            XCTAssertFalse(
                SSHDriveTrash.isTrash(identifier: NSFileProviderItemIdentifier.workingSet.rawValue))
            XCTAssertFalse(SSHDriveTrash.isTrash(identifier: UUID().uuidString))
        }
    #else
        func testOnlyTheTrashContainerIsRefusedByIdentifier() {
            XCTAssertTrue(SSHDriveTrash.isTrash(identifier: SSHDriveTrash.containerIdentifier))
            XCTAssertFalse(
                SSHDriveTrash.isTrash(identifier: "NSFileProviderRootContainerItemIdentifier"))
            XCTAssertFalse(
                SSHDriveTrash.isTrash(identifier: "NSFileProviderWorkingSetContainerItemIdentifier"))
            XCTAssertFalse(SSHDriveTrash.isTrash(identifier: UUID().uuidString))
        }
    #endif

    /// The local replica is case-insensitive and normalisation-insensitive (section 5.4),
    /// so every spelling that would land on the system's own `.Trash` is refused, and
    /// nothing else is.
    func testTrashNameIsRefusedHoweverItIsSpelled() {
        XCTAssertTrue(SSHDriveTrash.isTrash(filename: ".Trash"))
        XCTAssertTrue(SSHDriveTrash.isTrash(filename: ".trash"))
        XCTAssertTrue(SSHDriveTrash.isTrash(filename: ".TRASH"))

        XCTAssertFalse(SSHDriveTrash.isTrash(filename: "Trash"))
        XCTAssertFalse(SSHDriveTrash.isTrash(filename: ".Trashes"))
        XCTAssertFalse(SSHDriveTrash.isTrash(filename: ".Trash.txt"))
        XCTAssertFalse(SSHDriveTrash.isTrash(filename: "README.txt"))
    }

    /// Not `noSuchItem`: the system reads that as "the container was deleted", tries to
    /// delete it from disk, fails, and retries about once a second for ever.
    func testTheRefusalIsFeatureUnsupportedRatherThanNoSuchItem() {
        let error = SSHDriveTrash.unsupportedError
        XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error.code, NSFeatureUnsupportedError)
        #if canImport(FileProvider)
            XCTAssertNotEqual(error.domain, NSFileProviderErrorDomain)
        #endif
    }
}
