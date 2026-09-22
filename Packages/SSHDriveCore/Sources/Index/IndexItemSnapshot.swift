import Foundation
import XPCProtocols

extension IndexItem {
    /// A row is a finished item (docs/design/extension.md): turning one into the value that
    /// crosses XPC, or that the extension's reader hands straight to the system, is a
    /// field-by-field copy and nothing more. Both the agent and the extension use this, so
    /// the two paths cannot drift.
    public var snapshot: SSHDriveItemSnapshot {
        // The marker decides the policy, not just the effect: a kept item is eager, an
        // explicitly excluded one (`pin_state = -1`) is lazy, which is what overrides an
        // eager ancestor (docs/design/pinning.md), and everything else says nothing.
        let policy: SSHDriveContentPolicy =
            kept
            ? .downloadEagerlyAndKeepDownloaded
            : (pinState == -1 ? .downloadLazily : .unset)
        // The row's one local blob carries both the extended attributes and the Finder
        // tags, and the metadata version hashes exactly that blob, which is what makes a
        // change the agent itself makes - a restore from the index backup - reach the
        // system (gotcha 50).
        let local = LocalAttributes.decode(xattrs)
        return SSHDriveItemSnapshot(
            identifier: identifier,
            parentIdentifier: parent ?? IndexWriter.rootIdentifier,
            filename: filename,
            pathBytes: path,
            isDirectory: type == "directory",
            isSymlink: type == "symlink",
            linkTarget: linkTarget.map { String(decoding: $0, as: UTF8.self) },
            size: size,
            mtime: mtime,
            mode: Int32(truncatingIfNeeded: mode ?? 0),
            uid: Int32(truncatingIfNeeded: uid ?? 0),
            gid: Int32(truncatingIfNeeded: gid ?? 0),
            contentVersion: contentVersion,
            metadataVersion: metadataVersion,
            capabilities: UInt64(bitPattern: capabilities),
            fileSystemFlags: UInt64(bitPattern: fileSystemFlags),
            kept: kept,
            contentPolicyRawValue: policy.rawValue,
            extendedAttributes: local.xattrs,
            tagData: local.tagData)
    }
}
