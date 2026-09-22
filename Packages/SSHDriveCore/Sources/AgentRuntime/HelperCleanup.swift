import Foundation
import Config

/// When `sshdrive remove` may take the helper off the server (docs/design/cli.md).
///
/// On its last connection a location removes the helper binary and its directory from the
/// server when no other location of this Mac on the same `user@hostname:port` uses them;
/// another Mac's helper running from there keeps its inode and re-uploads on its next
/// connection.
///
/// So the question is not "is this the last location" but "is this the last location *on
/// this account and host*": two locations on one NAS share one `~/.cache/sshdrive`, and
/// removing one of them must not stop the other watching. The comparison is the same
/// user/host/port triple keychain items are keyed on, which is what makes "the same
/// account on the same server" mean one thing everywhere in the app.
enum HelperCleanup {

    static func sharesHelperDirectory(_ other: Location, with location: Location) -> Bool {
        key(other) == key(location)
    }

    static func key(_ location: Location) -> String {
        let user = location.user ?? ""
        let port = location.port.map(String.init) ?? ""
        return "\(user)@\(location.host):\(port)"
    }
}
