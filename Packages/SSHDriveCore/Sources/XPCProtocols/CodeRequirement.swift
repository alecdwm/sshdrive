import Foundation

/// The code requirement the agent's listener applies to every peer (DESIGN.md section 5.2):
/// signed through Apple's chain for team RWGDZAYBM8 and carrying one of the four signing
/// identifiers in section 3.1, listed explicitly because the requirement language matches
/// identifiers exactly and has no prefix form.
///
/// Release builds are Developer ID signed; debug builds carry an Apple Development
/// certificate. The two differ only in the leaf certificate's marker OID, so the
/// requirement is chosen by build configuration and a release agent never admits a debug
/// client.
public enum SSHDriveCodeRequirement {
    /// Developer ID Application leaf marker.
    private static let developerIDLeafOID = "field.1.2.840.113635.100.6.1.13"
    /// Developer ID intermediate marker.
    private static let developerIDIntermediateOID = "field.1.2.840.113635.100.6.2.6"
    /// Apple Development (formerly Mac Developer) leaf marker.
    private static let appleDevelopmentLeafOID = "field.1.2.840.113635.100.6.1.12"
    /// Apple Worldwide Developer Relations intermediate marker.
    private static let wwdrIntermediateOID = "field.1.2.840.113635.100.6.2.1"

    private static var identifierClause: String {
        SSHDriveIdentifiers.peerSigningIdentifiers
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
    }

    private static let teamClause =
        "certificate leaf[subject.OU] = \"\(SSHDriveIdentifiers.teamID)\""

    /// The Developer ID form, used by release builds.
    public static let developerID: String = """
        anchor apple generic \
        and certificate 1[\(developerIDIntermediateOID)] exists \
        and certificate leaf[\(developerIDLeafOID)] exists \
        and \(teamClause) \
        and (\(identifierClause))
        """

    /// The Apple Development form, used by debug builds.
    public static let appleDevelopment: String = """
        anchor apple generic \
        and certificate 1[\(wwdrIntermediateOID)] exists \
        and certificate leaf[\(appleDevelopmentLeafOID)] exists \
        and \(teamClause) \
        and (\(identifierClause))
        """

    /// A debug build lets a spike replace the requirement, either with `SSHDRIVE_PEER_REQUIREMENT` in
    /// the environment or with the one-line file `~/.sshdrive-spike-peer-requirement`.
    /// That exists for one reason: a Mac with no signing identity can only produce an
    /// ad-hoc signature, which has no Apple anchor and no team OU and therefore satisfies
    /// neither form above, so the whole of S1 (a) and (c) would be untestable there.
    /// Restrict the replacement as far as the build allows: `identifier
    /// "org.shirls.sshdrive.cli"` and friends still discriminate under an ad-hoc
    /// signature. Expect the loud log line. The file is read rather than only the
    /// environment because launchd hands an `SMAppService` job a scrubbed environment and
    /// `launchctl setenv` does not reach it. Release builds ignore both, so a shipped
    /// agent cannot be talked into a weaker requirement.
    public static let spikeOverrideFile = ".sshdrive-spike-peer-requirement"

    private static var spikeOverride: String? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["SSHDRIVE_PEER_REQUIREMENT"],
            !value.isEmpty
        {
            return value
        }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(spikeOverrideFile)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
        #else
        return nil
        #endif
    }

    /// The requirement this build applies.
    public static var current: String {
        #if DEBUG
        return spikeOverride ?? appleDevelopment
        #else
        return developerID
        #endif
    }

    /// True when `current` came from a spike override, so the agent can say so.
    public static var isOverridden: Bool { spikeOverride != nil }
}
