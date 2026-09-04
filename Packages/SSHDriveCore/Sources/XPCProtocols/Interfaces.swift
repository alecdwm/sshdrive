import Foundation

/// The configured NSXPCInterfaces. NSXPC refuses any collection or custom class that was
/// not whitelisted for the exact argument it appears in, so both ends build their
/// interfaces here and never inline.
public enum SSHDriveXPCInterface {

    /// NSXPCInterface takes a Set<AnyHashable> of classes; class objects are not Hashable
    /// in Swift, so the set is built as an NSSet and bridged, which is what Apple's own
    /// sample code does.
    private static func classSet(_ classes: [AnyClass]) -> Set<AnyHashable> {
        // swiftlint:disable:next force_cast
        NSSet(array: classes) as! Set<AnyHashable>
    }

    private static var itemClassSet: Set<AnyHashable> {
        classSet([
            SSHDriveItemPage.self, SSHDriveItemSnapshot.self,
            NSArray.self, NSDictionary.self, NSString.self, NSData.self, NSNumber.self,
        ])
    }

    private static var plistClassSet: Set<AnyHashable> {
        classSet([NSArray.self, NSDictionary.self, NSString.self, NSData.self, NSNumber.self])
    }

    /// The agent's interface, as both ends must configure it.
    public static var agent: NSXPCInterface {
        let interface = NSXPCInterface(with: SSHDriveAgentProtocol.self)

        for selector in [
            #selector(SSHDriveAgentProtocol.enumerateItems(domainIdentifier:containerIdentifier:pageToken:reply:)),
            #selector(SSHDriveAgentProtocol.enumerateChanges(domainIdentifier:containerIdentifier:anchor:reply:)),
        ] {
            interface.setClasses(itemClassSet, for: selector, argumentIndex: 0, ofReply: true)
        }

        interface.setClasses(
            itemClassSet,
            for: #selector(SSHDriveAgentProtocol.item(domainIdentifier:itemIdentifier:reply:)),
            argumentIndex: 0, ofReply: true)
        interface.setClasses(
            itemClassSet,
            for: #selector(SSHDriveAgentProtocol.fetchContents(domainIdentifier:itemIdentifier:requestedVersion:isFileViewerRequest:isSystemRequest:into:transferID:reply:)),
            argumentIndex: 0, ofReply: true)
        interface.setClasses(
            itemClassSet,
            for: #selector(SSHDriveAgentProtocol.fetchPartialContents(domainIdentifier:itemIdentifier:offset:length:into:transferID:reply:)),
            argumentIndex: 0, ofReply: true)
        interface.setClasses(
            itemClassSet,
            for: #selector(SSHDriveAgentProtocol.createItem(domainIdentifier:parentIdentifier:filename:isDirectory:symlinkTarget:contents:transferID:reply:)),
            argumentIndex: 0, ofReply: true)

        let modify = #selector(SSHDriveAgentProtocol.modifyItem(domainIdentifier:itemIdentifier:baseVersion:changedFields:newParentIdentifier:newFilename:newFileSystemFlags:newModificationDate:newExtendedAttributes:contents:transferID:reply:))
        interface.setClasses(itemClassSet, for: modify, argumentIndex: 0, ofReply: true)
        // newExtendedAttributes: [String: Data]
        interface.setClasses(plistClassSet, for: modify, argumentIndex: 8, ofReply: false)

        // itemIdentifiers: [String]
        interface.setClasses(
            plistClassSet,
            for: #selector(SSHDriveAgentProtocol.performAction(domainIdentifier:actionIdentifier:itemIdentifiers:reply:)),
            argumentIndex: 2, ofReply: false)

        // arguments: [String: String]
        interface.setClasses(
            plistClassSet,
            for: #selector(SSHDriveAgentProtocol.control(command:arguments:reply:)),
            argumentIndex: 1, ofReply: false)

        return interface
    }

    /// The extension's exported interface, for the agent's callbacks.
    public static var fileProviderExtension: NSXPCInterface {
        NSXPCInterface(with: SSHDriveExtensionProtocol.self)
    }
}
