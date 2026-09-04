import Foundation
import FileProvider
import Config
import Index
import SFTP
import SSHProcess
import XPCProtocols
import Logging

/// Owns the File Provider domain lifecycle and the per-location runtimes.
///
/// The agent is, with one exception, the only process that changes domain state through
/// NSFileProviderManager: the extension calls `disconnect(reason:)` and `reconnect()` on
/// its own domain when the agent cannot be reached (DESIGN.md sections 3, 5.2).
actor DomainManager {
    static let shared = DomainManager()

    /// config.json, reached through a serial queue of its own. Nothing that blocks on a
    /// file ever runs on this actor's executor: see `ConfigAccess`.
    private let config: ConfigAccess?
    private var runtimes: [String: LocationRuntime] = [:]
    private var started = false

    init() {
        self.config = try? ConfigAccess()
    }

    /// Loads config.json and brings up a runtime, and a domain, for every mounted
    /// location. Called once, when the launchd-started agent comes up.
    func start() async {
        guard !started else { return }
        started = true
        guard let config else {
            Log.agent.error("no app group container; the agent cannot serve any location")
            return
        }
        // Section 6.1: orphans are not adopted. A master left behind by a crashed agent
        // still owns its socket, and `ControlMaster=yes` against an existing socket
        // disables multiplexing, so later mux clients would attach to the orphan.
        let swept = ControlSocket.sweepOrphans(environment: await AgentSSHEnvironment.shared.environment())
        if !swept.isEmpty {
            Log.ssh.notice("swept \(swept.count, privacy: .public) orphaned control socket(s)")
        }
        do {
            let file = try await config.load()
            for location in file.locations where location.mounted {
                do {
                    _ = try await runtime(for: location)
                    try await addDomain(for: location)
                } catch {
                    Log.agent.error(
                        "cannot start location \(location.id, privacy: .public): \(error, privacy: .public)")
                }
            }
            Log.agent.notice("agent ready with \(file.locations.count) location(s)")
        } catch {
            Log.agent.error("cannot read config.json: \(error, privacy: .public)")
        }
    }

    func configuration() async throws -> ConfigFile {
        guard let config else { throw GroupContainer.ContainerError.unavailable }
        return try await config.load()
    }

    func location(named name: String) async throws -> Location {
        guard let config else { throw GroupContainer.ContainerError.unavailable }
        return try await config.location(named: name)
    }

    @discardableResult
    func mutateConfiguration(_ body: @escaping (inout ConfigFile) throws -> Void) async throws
        -> ConfigFile
    {
        guard let config else { throw GroupContainer.ContainerError.unavailable }
        return try await config.mutate(body)
    }

    /// The runtime for a location, started on first use.
    func runtime(for location: Location) async throws -> LocationRuntime {
        if let existing = runtimes[location.id] { return existing }
        try GroupContainer.createDomainDirectory(locationID: location.id)
        let transport: any SFTPTransport
        switch location.backend {
        case .fake:
            transport = FakeTransport(root: location.remotePath ?? "/srv/fake")
        case .sftp:
            // Section 6.1 and 6.2: the login shell snapshot, the `-N` master with a token
            // of its own, an SFTP channel on its mux socket, and the wire client on that
            // channel. `SSHBackedTransport` adds the deadline and the lost-master rule;
            // everything below this line is the same code the fake backend runs.
            let file = try? await config?.load()
            transport = try await SSHBackedTransport.connect(
                location: location,
                askpassPath: AgentSecrets.askpassPath,
                askpass: AgentSecrets.broker,
                uploadTag: String((file?.macID ?? "00000000").prefix(8)))
        }
        let runtime = try LocationRuntime(
            location: location,
            transport: transport,
            indexURL: try GroupContainer.indexURL(locationID: location.id),
            backupURL: try GroupContainer.indexBackupURL(locationID: location.id))
        try await runtime.start()
        runtimes[location.id] = runtime
        return runtime
    }

    func runtime(domainIdentifier: String) async throws -> LocationRuntime {
        if let existing = runtimes[domainIdentifier] { return existing }
        guard let config else { throw GroupContainer.ContainerError.unavailable }
        let file = try await config.load()
        guard let location = file.locations.first(where: { $0.id == domainIdentifier }) else {
            throw SSHDriveAgentError.unknownDomain.asNSError("No location \(domainIdentifier).")
        }
        return try await runtime(for: location)
    }

    func dropRuntime(locationID: String) async {
        guard let runtime = runtimes.removeValue(forKey: locationID) else { return }
        // `-O exit` on the master and the channel with it, so removing a location does
        // not leave an `ssh` behind (section 6.1).
        await runtime.shutdownTransport()
    }

    // MARK: Domains

    /// One domain per location, identified by the location's UUID (section 4).
    ///
    /// Whether the display name should be "SSH Drive - nas" or just "nas" is what spike
    /// S3 records, so that the sidebar does not read "SSH Drive - SSH Drive - nas"
    /// (section 2). Milestone 1 passes the bare name and S3 compares.
    nonisolated func addDomain(
        for location: Location, testingModes: NSFileProviderDomain.TestingModes = []
    ) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: location.id),
            displayName: location.displayName)
        // Only ever set by `sshdrive debug fake add --testing-modes` (spikes S4 and S6).
        // `alwaysEnabled` skips the user's approval, `interactive` hands the scheduler to
        // `listAvailableTestingOperations`; the appex's
        // com.apple.developer.fileprovider.testing-mode entitlement is what allows either.
        // A real location never asks for them, and the system does not let a domain give
        // `interactive` back once it has it.
        if !testingModes.isEmpty { domain.testingModes = testingModes }
        // No trash (section 5.4). This property defaults to YES, and with it the system
        // draws a `.Trash` in the mount, syncs it to the extension, and loops on
        // materializing a container we do not serve; anything that stats `.Trash`, such
        // as `ls -la`, waits on that loop (docs/spikes/results.md, 2026-09-04).
        domain.supportsSyncingTrash = false
        try await Deadline.run("adding the File Provider domain") {
            try await NSFileProviderManager.add(domain)
        }
        Log.agent.notice(
            "added domain \(location.id, privacy: .public) as \(location.displayName, privacy: .public)")
    }

    nonisolated func removeDomain(for location: Location) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: location.id),
            displayName: location.displayName)
        try await Deadline.run("removing the File Provider domain") {
            try await NSFileProviderManager.remove(domain)
        }
        Log.agent.notice("removed domain \(location.id, privacy: .public)")
    }

    /// Tells the system to re-ask for the working set, which is how every change the
    /// agent found reaches Finder (sections 5.3, 6.4).
    nonisolated func signalWorkingSet(locationID: String) async {
        await signalEnumerator(locationID: locationID, container: .workingSet)
    }

    /// The same call for one container. Reporting a new row through the working set is not
    /// enough to make the system ingest an item whose parent it has never enumerated: S6
    /// found that a pin on such a path sits idle until something looks the chain up
    /// (docs/spikes/results.md, 2026-09-04, s6-3). Signalling each new ancestor's own
    /// enumerator is how the agent asks for that listing.
    nonisolated func signalEnumerator(
        locationID: String, container: NSFileProviderItemIdentifier
    ) async {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: locationID),
            displayName: locationID)
        guard let manager = NSFileProviderManager(for: domain) else {
            Log.agent.error("no manager for domain \(locationID, privacy: .public)")
            return
        }
        do {
            try await Deadline.run("signalling an enumerator") {
                try await manager.signalEnumerator(for: container)
            }
        } catch {
            Log.agent.error("signalEnumerator failed: \(error, privacy: .public)")
        }
    }

    /// Every domain the system currently has for our provider, as "<name> (<id>)".
    ///
    /// The descriptions rather than the domains themselves, because the whole call runs
    /// under a deadline and `NSFileProviderDomain` is not `Sendable`.
    static func existingDomainDescriptions() async throws -> [String] {
        try await Deadline.run("listing the File Provider domains") {
            try await NSFileProviderManager.domains().map {
                "\($0.displayName) (\($0.identifier.rawValue))"
            }
        }
    }
}
