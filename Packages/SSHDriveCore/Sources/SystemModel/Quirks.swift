import Foundation

/// The quirk table (`docs/testing-architecture.md` section 3.2).
///
/// Every rule `SystemModel` implements is keyed on an id from `docs/quirks/macos.md`, and
/// every value it uses is resolved out of this table for the macOS version the scenario
/// names. Adding macOS 27 is a new column here and no scenario change.
///
/// The two columns that exist today are 26.4 and 26.6, and they are **identical unless a
/// quirk says otherwise** - the catalog records which version each behaviour was measured
/// on, and nothing measured so far differs between the two. `MQ-005` is the one row whose
/// measurement came from 26.6 (the 0.1.2 field failure); nothing about it suggests 26.4
/// behaves differently and 26.4 is where the reproduction ran, so it covers both.
public enum MacOSVersion: String, CaseIterable, Sendable, Hashable {
    case v26_4 = "26.4"
    case v26_6 = "26.6"
}

public struct QuirkID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

public enum QuirkValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case duration(Double)
    case text(String)
}

/// One measurement of one quirk: which versions it covers, what was seen, and where the
/// evidence is. `results.md` stays the source of truth; this is an index into it.
public struct QuirkMeasurement: Sendable {
    public let versions: [MacOSVersion]
    public let value: QuirkValue
    public let source: String

    public init(versions: [MacOSVersion], value: QuirkValue, source: String) {
        self.versions = versions
        self.value = value
        self.source = source
    }
}

public struct Quirk: Sendable {
    public let id: QuirkID
    public let statement: String
    public let measurements: [QuirkMeasurement]

    public init(id: QuirkID, statement: String, measurements: [QuirkMeasurement]) {
        self.id = id
        self.statement = statement
        self.measurements = measurements
    }
}

/// The catalogue as the model reads it, resolved for one version.
///
/// It **refuses to resolve an id with no measurement covering that version**: a scenario
/// depending on an unmeasured quirk on a version we claim to support fails loudly with the
/// id, rather than quietly taking someone's guess. That is the mechanism that turns "we
/// never checked on 14" from a silent assumption into a test failure.
public struct QuirkTable {
    public let version: MacOSVersion
    private let quirks: [QuirkID: Quirk]

    public init(for version: MacOSVersion, catalogue: [Quirk] = QuirkTable.macOSCatalogue) {
        self.version = version
        self.quirks = Dictionary(uniqueKeysWithValues: catalogue.map { ($0.id, $0) })
    }

    public func value(_ id: QuirkID) -> QuirkValue {
        guard let quirk = quirks[id] else {
            fatalError(
                "SystemModel asked for quirk \(id), which is not in docs/quirks/macos.md")
        }
        guard
            let measurement = quirk.measurements.first(where: { $0.versions.contains(version) })
        else {
            fatalError(
                "quirk \(id) has no measurement covering macOS \(version.rawValue): run "
                    + "docs/spikes/macos-version-sweep.md on that version and add the row")
        }
        return measurement.value
    }

    public func bool(_ id: QuirkID) -> Bool {
        guard case .bool(let value) = value(id) else {
            fatalError("quirk \(id) is not a boolean")
        }
        return value
    }

    public func int(_ id: QuirkID) -> Int {
        guard case .int(let value) = value(id) else { fatalError("quirk \(id) is not an int") }
        return value
    }

    public func duration(_ id: QuirkID) -> Double {
        guard case .duration(let value) = value(id) else {
            fatalError("quirk \(id) is not a duration")
        }
        return value
    }

    public var ids: [QuirkID] { quirks.keys.sorted { $0.rawValue < $1.rawValue } }
}

extension QuirkTable {
    /// Both columns, for the rows nothing has been measured to differ on.
    private static let bothVersions: [MacOSVersion] = [.v26_4, .v26_6]

    /// The rows step 1.3 needs: enumeration, the working set, anchors and the throttle.
    /// Statements are abbreviations of `docs/quirks/macos.md`, which is the catalogue;
    /// `results.md` is the source of truth behind both.
    public static let macOSCatalogue: [Quirk] = [
        Quirk(
            id: .enumerateOnceEver,
            statement:
                "A folder is enumerated once, ever: revisiting it and a remote change landing "
                + "while it is open produce no container-enumerator call at all.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 evening, s3-3; DESIGN.md section 6.5; gotcha 29")
            ]),
        Quirk(
            id: .workingSetIsChangeStreamOnly,
            statement:
                "The working set is only a change stream: enumerateItems on it returns nothing "
                + "and the system ingests nothing from it.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04, s6-3; DESIGN.md section 5.3")
            ]),
        Quirk(
            id: .freshInstancePerSignal,
            statement:
                "The system launches a fresh extension instance for every working-set signal, "
                + "and for every retry of a queued write.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 (M5) s5-1; results 2026-09-04 (M6)")
            ]),
        Quirk(
            id: .emptyChangeSetMeansUpToDate,
            statement:
                "An empty change set at the anchor the system already holds tells it that it is "
                + "up to date; the change is dropped until something else signals.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 (M6) \"Four assumptions that failed\"; gotcha 78")
            ]),
        Quirk(
            id: .changeEnumerationThrottleThreshold,
            statement:
                "fileproviderd throttles a change enumeration that keeps failing; 27 consecutive "
                + "errors took one domain's fetch-event stream to a 47-minute retry.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .int(27),
                    source: "results 2026-09-08 addendum (measured on 26.6, the 0.1.2 field failure)")
            ]),
        Quirk(
            id: .changeEnumerationThrottleCeiling,
            statement:
                "The retry the fetch-event stream reached after those 27 errors was 47 minutes.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .duration(47 * 60),
                    source: "results 2026-09-08 addendum, `fileproviderctl dump`: next:'28min45s' count:27")
            ]),
        Quirk(
            id: .changeEnumerationThrottleAtSevenErrors,
            statement:
                "The same backoff stood at 1 min 34 s after 7 consecutive errors, which is the "
                + "second point the model's schedule is fitted through.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .duration(94),
                    source: "results 2026-09-08 addendum, the VM reproduction: next:'1min34s' count:7")
            ]),
        Quirk(
            id: .signalErrorResolvedIsTheOnlyFlush,
            statement:
                "signalErrorResolved(.serverUnreachable) is the only thing that clears the "
                + "backoff and flushes a queued write; signalEnumerator alone does nothing.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 (M5) s5-2; gotcha 58")
            ]),
        Quirk(
            id: .syncAnchorExpiredIsReAsked,
            statement:
                "syncAnchorExpired makes the system re-ask from a fresh anchor rather than "
                + "giving up.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "DESIGN.md section 5.3; results 2026-09-04 (M6)")
            ]),
        Quirk(
            id: .noTimeoutOnEnumerateItems,
            statement:
                "The system does not time out an enumerateItems held the full 60 s, takes the "
                + "answer, and leaves the extension process running. Measured at 60.19 s.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .duration(60.19),
                    source: "results 2026-09-04 (M5) s5-6; gotcha 60")
            ]),
        Quirk(
            id: .believesReturnedVersions,
            statement:
                "The system believes whatever version a reply carries: it records it, never "
                + "re-fetches and never re-offers.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 evening, s3-7; gotcha 30")
            ]),
        Quirk(
            id: .killsIdleInstances,
            statement:
                "The system kills an idle extension instance, and the extension's XPC connection "
                + "to the agent invalidates as part of that teardown.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 S1 signed pass, \"Two bugs found while running this pass\"")
            ]),
    ]
}

extension QuirkID {
    public static let enumerateOnceEver: QuirkID = "MQ-001"
    public static let workingSetIsChangeStreamOnly: QuirkID = "MQ-002"
    public static let freshInstancePerSignal: QuirkID = "MQ-003"
    public static let emptyChangeSetMeansUpToDate: QuirkID = "MQ-004"
    public static let changeEnumerationThrottleThreshold: QuirkID = "MQ-005"
    /// Two more values off the same measurement, kept as ids of their own so the model
    /// never carries a number that is not in the catalogue.
    public static let changeEnumerationThrottleCeiling: QuirkID = "MQ-005.ceiling"
    public static let changeEnumerationThrottleAtSevenErrors: QuirkID = "MQ-005.at7"
    public static let syncAnchorExpiredIsReAsked: QuirkID = "MQ-006"
    public static let noTimeoutOnEnumerateItems: QuirkID = "MQ-007"
    public static let believesReturnedVersions: QuirkID = "MQ-013"
    public static let signalErrorResolvedIsTheOnlyFlush: QuirkID = "MQ-037"
    public static let killsIdleInstances: QuirkID = "MQ-073"
}
