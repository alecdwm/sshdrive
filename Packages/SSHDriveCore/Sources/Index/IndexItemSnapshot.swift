import Foundation
import XPCProtocols

extension IndexItem {
    /// A row is a finished item (DESIGN.md section 5.2): turning one into the value that
    /// crosses XPC, or that the extension's reader hands straight to the system, is a
    /// field-by-field copy and nothing more. Both the agent and the extension use this,
    /// so the two paths cannot drift.
    public var snapshot: SSHDriveItemSnapshot {
        // The marker decides the policy, not just the effect: a kept item is eager, an
        // explicitly excluded one (`pin_state = -1`) is lazy, which is what overrides an
        // eager ancestor (section 7.1.1), and everything else says nothing.
        let policy: SSHDriveContentPolicy =
            kept
            ? .downloadEagerlyAndKeepDownloaded
            : (pinState == -1 ? .downloadLazily : .unset)
        let attributes: [String: Data] =
            xattrs.flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
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
            extendedAttributes: attributes)
    }
}
