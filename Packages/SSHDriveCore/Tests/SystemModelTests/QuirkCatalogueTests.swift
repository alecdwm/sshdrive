import XCTest
import SystemModel

/// The guard `docs/testing-architecture.md` section 9 calls `scripts/check-quirks.sh`: the
/// model may not read a quirk the catalogue does not carry, and the catalogue may not
/// carry an id the model has never heard of.
///
/// Until the script exists this runs from the suite, exactly as `ServerModelTests`'
/// `ServerProfileScenarios` does for `docs/quirks/servers.md`.
final class QuirkCatalogueTests: XCTestCase {

    /// Every id the model resolves exists in `docs/quirks/macos.md`. A sub-id like
    /// `MQ-005.ceiling` is a second value off one measurement and is checked against its
    /// base row.
    func testEveryModelledQuirkIsInTheMarkdownCatalogue() throws {
        let documented = try Self.documentedIDs()
        let table = QuirkTable(for: .v26_4)
        for id in table.ids {
            let base = id.rawValue.split(separator: ".").first.map(String.init) ?? id.rawValue
            XCTAssertTrue(
                documented.contains(base),
                "\(id) is read by SystemModel and is not a row of docs/quirks/macos.md")
        }
    }

    /// And every row of the catalogue that names a scenario id in one of the suites this
    /// module owns is modelled here, so a documented behaviour cannot quietly stop being
    /// defended.
    func testEveryQuirkTheModelClaimsResolvesOnBothColumns() throws {
        for version in MacOSVersion.allCases {
            let table = QuirkTable(for: version)
            for id in table.ids {
                // `value` traps on an id with no measurement covering the version, which
                // is the "we never checked on 14" rule turned into a failure.
                _ = table.value(id)
                XCTAssertFalse(table.statement(id).isEmpty, "\(id) has no statement")
            }
        }
    }

    static func documentedIDs() throws -> Set<String> {
        let markdown = EvictionAndPinningScenarios.repositoryRoot()
            .appendingPathComponent("docs/quirks/macos.md")
        let text = try String(contentsOf: markdown, encoding: .utf8)
        var ids: Set<String> = []
        for line in text.split(separator: "\n") where line.hasPrefix("| MQ-") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count > 1 else { continue }
            ids.insert(fields[1].trimmingCharacters(in: .whitespaces))
        }
        return ids
    }
}
