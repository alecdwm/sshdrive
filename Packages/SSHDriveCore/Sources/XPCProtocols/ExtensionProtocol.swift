import Foundation

/// The extension's exported object: the callbacks the agent makes on an established
/// connection (DESIGN.md section 5.2).
@objc public protocol SSHDriveExtensionProtocol {

    /// Byte counts for a running transfer, forwarded to the Progress the extension
    /// returned to the system.
    func transferProgress(transferID: String, bytesCompleted: Int64, bytesTotal: Int64)

    /// The agent is about to truncate and rebuild the index (section 5.3). The reader
    /// holds the -shm file mapped, so it must close before the truncate; until
    /// `reopenIndexReader` the extension answers `.serverUnreachable`.
    func closeIndexReader(reply: @escaping () -> Void)

    /// The rebuild is finished; the reader may open again.
    func reopenIndexReader()
}
