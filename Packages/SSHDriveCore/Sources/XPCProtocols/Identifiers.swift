import Foundation

/// Every fixed identifier in the project, from DESIGN.md section 3.1. Nothing derives one
/// of these at runtime; they are the strings that entitlements, the launchd plist and the
/// signing settings also carry, and they must be edited together.
public enum SSHDriveIdentifiers {
    /// Apple Developer Team ID.
    public static let teamID = "RWGDZAYBM8"

    /// App bundle ("SSH Drive.app"), whose main executable is the background agent.
    public static let appBundleID = "org.shirls.sshdrive"

    /// The File Provider extension.
    public static let extensionBundleID = "org.shirls.sshdrive.fileprovider"

    /// Explicit signing identifier of the CLI. A bare tool would otherwise be signed as
    /// its product name, which the agent's peer requirement refuses.
    public static let cliSigningID = "org.shirls.sshdrive.cli"

    /// Explicit signing identifier of the askpass program.
    public static let askpassSigningID = "org.shirls.sshdrive.askpass"

    /// launchd label of the login agent, registered through SMAppService.agent.
    public static let agentLabel = "org.shirls.sshdrive.agent"

    /// App group and keychain access group. macOS app groups are Team-ID prefixed, and
    /// the keychain access group is the same string.
    public static let appGroup = "\(teamID).org.shirls.sshdrive"
    public static let keychainAccessGroup = appGroup

    /// The mach service the agent listens on. App-group prefixed so the sandboxed
    /// extension is allowed to look it up.
    public static let machServiceName = "\(teamID).org.shirls.sshdrive.agent"

    /// Every signing identifier admitted by the agent's listener.
    public static let peerSigningIdentifiers = [
        appBundleID, extensionBundleID, cliSigningID, askpassSigningID,
    ]
}
