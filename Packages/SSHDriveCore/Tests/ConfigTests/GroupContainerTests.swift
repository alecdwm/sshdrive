import XCTest

@testable import Config

/// The seam described in docs/design/testing.md: on macOS the container is the app
/// group's own, off Darwin it is a directory the test names, and the layout in
/// docs/design/components.md is derived from whichever one answered.
final class GroupContainerTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-container-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        GroupContainer.resetLocator()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testAFixedLocatorPutsTheWholeLayoutUnderIt() throws {
        GroupContainer.locator = FixedGroupContainerLocator(directory)

        XCTAssertEqual(try GroupContainer.requireURL().path, directory.path)
        XCTAssertEqual(try GroupContainer.configURL().lastPathComponent, "config.json")
        XCTAssertEqual(
            try GroupContainer.indexURL(locationID: "abc").path,
            directory.appendingPathComponent("domains/abc/index.sqlite").path)
        XCTAssertEqual(
            try GroupContainer.pinsURL(locationID: "abc").path,
            directory.appendingPathComponent("domains/abc/pins.json").path)

        // The per-domain directory is the agent's to create, and it lands inside.
        let created = try GroupContainer.createDomainDirectory(locationID: "abc")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: created.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// No container is the honest answer for a process without the entitlement, and it is
    /// an error rather than a path nobody owns.
    func testNoContainerIsAnError() {
        GroupContainer.locator = FixedGroupContainerLocator(nil)
        XCTAssertNil(GroupContainer.url)
        XCTAssertThrowsError(try GroupContainer.requireURL()) { error in
            XCTAssertTrue(error is GroupContainer.ContainerError)
        }
    }

    /// `SSHDRIVE_GROUP_CONTAINER` is what the Linux suite sets; unset means no container.
    func testTheEnvironmentLocatorReadsTheVariable() {
        XCTAssertEqual(EnvironmentGroupContainerLocator.variableName, "SSHDRIVE_GROUP_CONTAINER")
        setenv(EnvironmentGroupContainerLocator.variableName, directory.path, 1)
        defer { unsetenv(EnvironmentGroupContainerLocator.variableName) }

        let locator = EnvironmentGroupContainerLocator()
        XCTAssertEqual(
            locator.containerURL(forGroupIdentifier: GroupContainer.identifier)?.path,
            directory.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        unsetenv(EnvironmentGroupContainerLocator.variableName)
        XCTAssertNil(locator.containerURL(forGroupIdentifier: GroupContainer.identifier))
    }

    /// macOS keeps asking the app group and nothing else.
    #if canImport(Darwin)
        func testTheDefaultLocatorOnDarwinIsTheAppGroup() {
            XCTAssertTrue(GroupContainer.defaultLocator is SystemGroupContainerLocator)
            XCTAssertEqual(GroupContainer.identifier, "RWGDZAYBM8.org.shirls.sshdrive")
        }
    #else
        func testTheDefaultLocatorOffDarwinIsTheEnvironment() {
            XCTAssertTrue(GroupContainer.defaultLocator is EnvironmentGroupContainerLocator)
        }
    #endif
}
