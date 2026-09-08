import Foundation
import AgentCore
import Config
import Logging
import SFTP
import SSHProcess

/// How many channels this server lets us hold at once, and what that costs
/// (DESIGN.md sections 6.1 and 6.2).
///
/// The master is `ssh -N` and carries **no session** of its own, so `MaxSessions` counts
/// exactly the mux clients: the metadata SFTP channel, the bulk SFTP channel, and the
/// exec channels the capability probe, the `id` identity lookup, the tier-1 sweep and
/// (milestone 9) the helper run on.
///
/// Section 6.1 sets the budget: "the agent holds at most five per location (two SFTP, the
/// helper stream, a sweep, a probe or delete walk)"; "at 2 the bulk SFTP channel is
/// dropped, transfers share the metadata channel under the scheduler of section 6.2, and
/// the helper gets the one exec channel"; "at 1 there is no exec channel at all, the
/// location is SFTP-only in every respect".
///
/// So the question the probe has to answer is not "what is `MaxSessions`" but "may I hold
/// **three** at once" - metadata, bulk, and one exec - because that is the smallest budget
/// under which the bulk channel is affordable. Two channel opens answer it, which is why
/// this is not the ten opens section 6.1 warns against.
public struct ChannelBudget: Sendable, Equatable {
    /// The largest number of simultaneous channels the probe actually held. 3 means "3 or
    /// more": the probe stops there because nothing needs a fourth at the same time.
    public var concurrentChannels: Int
    /// Whether the location keeps the second, bulk SFTP channel.
    public var hasBulkChannel: Bool
    /// Whether an exec channel can be afforded at all (tier 1, the `id` probe, the helper).
    public var allowsExecChannel: Bool
    /// Whether one can be *held open for the life of the connection*, which is what tier 2
    /// needs and tier 1 does not: a sweep opens a channel, spends half a second on it and
    /// closes it, while the helper's stream lives as long as the location does. At a
    /// `MaxSessions` of 2 the one spare channel is shared by the probe and the sweep - and
    /// section 6.4 still runs a sweep every 30 minutes as insurance even at tier 2 - so a
    /// helper that never gave it back would cost the location the insurance sweep, the
    /// re-probe and `sshdrive test`. It is refused there and `status` says why
    /// (2026-09-05, section 13).
    public var allowsPersistentExecChannel: Bool
    /// The sentence `sshdrive status` shows. Empty when nothing was forced.
    public var note: String

    public static let unrestricted = ChannelBudget(
        concurrentChannels: 3, hasBulkChannel: true, allowsExecChannel: true,
        allowsPersistentExecChannel: true, note: "")

    /// The three cases section 6.1 names.
    public static func forConcurrentChannels(_ channels: Int) -> ChannelBudget {
        switch channels {
        case ...1:
            return ChannelBudget(
                concurrentChannels: 1, hasBulkChannel: false, allowsExecChannel: false,
                allowsPersistentExecChannel: false,
                note: "the server allows one channel at a time (MaxSessions 1): no bulk "
                    + "transfer channel and no shell access, so this location is SFTP-only "
                    + "(watch mode poll, no remote identity, no helper)")
        case 2:
            return ChannelBudget(
                concurrentChannels: 2, hasBulkChannel: false, allowsExecChannel: true,
                allowsPersistentExecChannel: false,
                note: "the server allows two channels at a time (MaxSessions 2): the bulk "
                    + "transfer channel is dropped and transfers share the metadata "
                    + "channel, so a large download slows listings; the second channel is "
                    + "kept for shell access, and is shared - the sweep and the probe take "
                    + "it in turns, and the helper cannot hold one open (watch mode sweep)")
        default:
            return .unrestricted
        }
    }

    public var asJSON: [String: Any] {
        [
            "concurrentChannels": concurrentChannels,
            "bulkChannel": hasBulkChannel,
            "execChannel": allowsExecChannel,
            "persistentExecChannel": allowsPersistentExecChannel,
            "note": note,
        ]
    }
}

/// Opens channels until one is refused, and caches the answer.
public enum ChannelProbe {

    /// A channel that never speaks SFTP inside this many seconds is a refused session,
    /// not a slow server: a refusal is an immediate process exit with
    /// `mux_client_request_session: session request failed` on stderr, so the timeout is
    /// only the backstop.
    public static let handshakeSeconds: Double = 10

    public struct Opened {
        public let channel: SFTPChannel
        public let transport: RealSFTPTransport
    }

    /// Why a channel did not open. `Result`'s failure type has to be an `Error`, and what
    /// we actually want to carry is `ssh`'s own stderr, which is the only explanation a
    /// refused session ever gives (`mux_client_request_session: session request failed`).
    public struct Refusal: Error {
        public let diagnostics: String
        /// Whether the server refused a session or the connection died under the open.
        /// Only the first may be turned into a cached budget (section 6.1, 2026-09-08).
        public let verdict: ChannelProbeVerdict

        public var connectionDied: Bool { verdict == .connectionDied }
    }

    /// Spawns one SFTP mux client and completes the SFTP handshake on it, which is the
    /// only proof the session was actually granted: `ssh` exits at once when it was not,
    /// and the spawn itself always succeeds.
    public static func openVerifiedChannel(
        master: SSHMaster, root: String, uploadTag: String
    ) async -> Result<Opened, Refusal> {
        let channel: SFTPChannel
        do {
            channel = try await master.openSFTPChannel()
        } catch {
            return .failure(
                Refusal(
                    diagnostics: "\(error)",
                    verdict: ChannelProbeVerdict.classify(
                        diagnostics: "\(error)", masterIsRunning: await master.isRunning)))
        }
        var configuration = SFTPClient.Configuration()
        configuration.metadataDeadline = .seconds(handshakeSeconds)
        do {
            let transport = try await RealSFTPTransport.connect(
                stream: channel.stream, root: root, uploadTag: uploadTag,
                configuration: configuration)
            return .success(Opened(channel: channel, transport: transport))
        } catch {
            let diagnostics = channel.stderrText
            channel.close()
            let text = diagnostics.isEmpty ? "\(error)" : diagnostics
            return .failure(
                Refusal(
                    diagnostics: text,
                    verdict: ChannelProbeVerdict.classify(
                        diagnostics: text, masterIsRunning: await master.isRunning)))
        }
    }

    /// The probe of section 6.1, run once per location and cached.
    ///
    /// Returns the budget and, when the server allowed it, the bulk channel itself - the
    /// probe's second channel *is* the bulk channel, so nothing is opened twice.
    ///
    /// A **nil** budget means the connection died under the probe rather than the server
    /// refusing a session. Nothing is recorded then: the caller fails the connect attempt
    /// and section 6.3's breaker tries again, because a budget measured on a dying
    /// connection is cached for ever and there is nothing that re-probes (2026-09-08).
    public static func probe(
        master: SSHMaster, root: String, uploadTag: String, locationID: String
    ) async -> (budget: ChannelBudget?, bulk: Opened?) {
        // Channel 2: the bulk channel.
        let second = await openVerifiedChannel(master: master, root: root, uploadTag: uploadTag)
        guard case .success(let bulk) = second else {
            if case .failure(let refusal) = second {
                if refusal.connectionDied {
                    Log.ssh.notice(
                        "\(locationID, privacy: .public): the connection died while probing the second channel (\(refusal.diagnostics, privacy: .public)); recording no budget"
                    )
                    return (nil, nil)
                }
                Log.ssh.notice(
                    "\(locationID, privacy: .public): a second channel was refused (\(refusal.diagnostics, privacy: .public))"
                )
            }
            return (.forConcurrentChannels(1), nil)
        }

        // Channel 3: not kept. It stands in for the exec channel the sweep, the `id`
        // probe and the helper each want alongside the two SFTP channels.
        let third = await openVerifiedChannel(master: master, root: root, uploadTag: uploadTag)
        switch third {
        case .success(let probe):
            await probe.transport.shutdown()
            probe.channel.close()
            Log.ssh.notice("\(locationID, privacy: .public): three channels held; full budget")
            return (.unrestricted, bulk)
        case .failure(let refusal):
            if refusal.connectionDied {
                Log.ssh.notice(
                    "\(locationID, privacy: .public): the connection died while probing the third channel (\(refusal.diagnostics, privacy: .public)); recording no budget"
                )
                await bulk.transport.shutdown()
                bulk.channel.close()
                return (nil, nil)
            }
            Log.ssh.notice(
                "\(locationID, privacy: .public): a third channel was refused (\(refusal.diagnostics, privacy: .public)); dropping the bulk channel"
            )
            await bulk.transport.shutdown()
            bulk.channel.close()
            return (.forConcurrentChannels(2), nil)
        }
    }
}

/// `domains/<id>/capabilities.json`, section 8.1's cache.
///
/// Read-modify-write of a JSON object, touching only the keys it is given, so that the
/// capability report of section 8.1 and this file can each own their own keys without
/// either overwriting the other.
public enum CapabilityCache {

    public static func read(locationID: String) -> [String: Any] {
        guard let url = try? GroupContainer.capabilitiesURL(locationID: locationID),
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    public static func merge(locationID: String, _ values: [String: Any]) {
        var object = read(locationID: locationID)
        for (key, value) in values { object[key] = value }
        do {
            try GroupContainer.createDomainDirectory(locationID: locationID)
            let url = try GroupContainer.capabilitiesURL(locationID: locationID)
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            Log.agent.error("cannot write capabilities.json: \(error, privacy: .public)")
        }
    }

    /// The cached channel budget, or nil when it has never been probed.
    ///
    /// Section 6.1 caches this "once per server banner" and re-probes only when the banner
    /// changes. The agent never sees a banner: its `ssh` runs at `LogLevel=ERROR`, which
    /// prints no remote version, and a mux client learns nothing at all because it speaks
    /// to the master's socket rather than to the server. So the cache is keyed by the
    /// location and invalidated only on request (2026-09-04, section 13).
    public static func channelBudget(locationID: String) -> ChannelBudget? {
        guard let stored = read(locationID: locationID)["channels"] as? [String: Any],
            let channels = stored["concurrentChannels"] as? Int
        else { return nil }
        // Measured while the connection was going away, or measured before one did: either
        // way it is not evidence any more, and the next connect re-probes. The values stay
        // in the file so an offline `status` still has something to print (2026-09-08).
        if stored["suspect"] as? Bool == true { return nil }
        return ChannelBudget(
            concurrentChannels: channels,
            hasBulkChannel: (stored["bulkChannel"] as? Bool) ?? (channels >= 3),
            allowsExecChannel: (stored["execChannel"] as? Bool) ?? (channels >= 2),
            allowsPersistentExecChannel:
                (stored["persistentExecChannel"] as? Bool) ?? (channels >= 3),
            note: (stored["note"] as? String) ?? "")
    }

    public static func store(_ budget: ChannelBudget, locationID: String) {
        var values = budget.asJSON
        values["probedAt"] = Date().timeIntervalSince1970
        values["suspect"] = false
        merge(locationID: locationID, ["channels": values])
    }

    /// Marks the cached budget as no longer evidence, so the next connect probes again.
    ///
    /// Called on every abrupt loss of a connection that was up - a master that died, two
    /// consecutive deadline misses, a path that went away, the will-sleep drop. Section 6.1
    /// says the cache's "only invalidation" is an explicit re-probe; that was written when
    /// the only way to get a wrong answer was a server that changed its mind, and it left
    /// a location that probed in a bad moment stuck at that answer for the life of the
    /// install (2026-09-08). Two extra channel opens on the next connect is the whole cost.
    public static func markChannelBudgetSuspect(locationID: String) {
        guard var channels = read(locationID: locationID)["channels"] as? [String: Any] else {
            return
        }
        guard channels["suspect"] as? Bool != true else { return }
        channels["suspect"] = true
        merge(locationID: locationID, ["channels": channels])
    }

    /// Section 8.1's own half of the file: "the result is cached in
    /// `domains/<id>/capabilities.json` with a timestamp and the server banner". The agent
    /// never sees a banner (2026-09-04, section 6.1), so what is stored beside the
    /// timestamp is `uname -sm`, which is the closest thing the probe can actually read.
    public static func storeProbe(
        _ probe: ServerProbe.Result, extensions: SFTPServerExtensions,
        advertised: [String] = [], locationID: String
    ) {
        merge(
            locationID: locationID,
            [
                "probe": [
                    "probedAt": Date().timeIntervalSince1970,
                    "uname": probe.uname,
                    "home": probe.home,
                    "shellAccess": probe.hasShellAccess,
                    "shellFailure": probe.failure,
                    "shellPrefix": probe.shellPrefix,
                    "identityKnown": probe.identity.isKnown,
                    "identity": probe.description,
                    "uid": Int(probe.identity.uid ?? 0),
                    "gid": Int(probe.identity.gid ?? 0),
                    "groups": probe.identity.supplementaryGroups.sorted().map(Int.init),
                    "findFlavour": probe.findFlavour,
                    "findTakesCmin": probe.findTakesCmin,
                    "findTakesPrintf": probe.findTakesPrintf,
                    "checksumTool": probe.checksumTool,
                    "cacheDirectory": probe.cacheDirectory,
                    "cacheNote": probe.cacheNote,
                    "sftpExtensions": SFTPExtensionNames.list(extensions),
                    // Everything the server offered, so a missing `fsync@openssh.com` can
                    // be told from a client that failed to read one (2026-09-05).
                    "sftpExtensionsAdvertised": advertised,
                ] as [String: Any]
            ])
    }

    /// The cached probe, for a `status` that has no live connection (section 8.1: "When
    /// offline, the cached probe is shown with (cached; offline) and no guesses are made").
    public static func probe(locationID: String)
        -> (probe: ServerProbe.Result, extensions: SFTPServerExtensions, probedAt: Date)?
    {
        guard let stored = read(locationID: locationID)["probe"] as? [String: Any] else {
            return nil
        }
        var result = ServerProbe.Result()
        result.uname = stored["uname"] as? String ?? ""
        result.home = stored["home"] as? String ?? ""
        result.failure = stored["shellFailure"] as? String ?? ""
        result.shellPrefix = stored["shellPrefix"] as? String ?? ""
        result.description = stored["identity"] as? String ?? ""
        if stored["identityKnown"] as? Bool == true {
            let groups = Set((stored["groups"] as? [Int] ?? []).map { UInt32($0) })
            result.identity = ServerIdentity(
                uid: UInt32(stored["uid"] as? Int ?? 0),
                gid: UInt32(stored["gid"] as? Int ?? 0),
                supplementaryGroups: groups)
        }
        result.findFlavour = stored["findFlavour"] as? String ?? ""
        result.findTakesCmin = stored["findTakesCmin"] as? Bool ?? false
        result.findTakesPrintf = stored["findTakesPrintf"] as? Bool ?? false
        result.checksumTool = stored["checksumTool"] as? String ?? ""
        result.cacheDirectory = stored["cacheDirectory"] as? String ?? ""
        result.cacheNote = stored["cacheNote"] as? String ?? ""
        let extensions = SFTPExtensionNames.parse(stored["sftpExtensions"] as? [String] ?? [])
        let at = Date(timeIntervalSince1970: stored["probedAt"] as? Double ?? 0)
        return (result, extensions, at)
    }

    /// The server's identification string, captured once by the collect connection of
    /// section 4.2 (`add`, `passwd`, `set host|user|port|identity`), which is the only
    /// `ssh` the agent runs that ever sees one (section 6.1, section 8.1; 2026-09-08).
    public static func storeServerVersion(_ version: String?, locationID: String) {
        guard let version, !version.isEmpty else { return }
        merge(locationID: locationID, ["serverVersion": version])
    }

    public static func serverVersion(locationID: String) -> String? {
        read(locationID: locationID)["serverVersion"] as? String
    }

    /// Section 8.1's "name the server software": the captured banner plus the SFTP
    /// extension fingerprint, which every connection has for free.
    public static func software(locationID: String) -> ServerSoftware {
        ServerSoftware(
            banner: serverVersion(locationID: locationID),
            advertisedExtensions: advertisedExtensions(locationID: locationID))
    }

    /// Every extension name the last connection's SSH_FXP_VERSION carried.
    public static func advertisedExtensions(locationID: String) -> [String] {
        guard let stored = read(locationID: locationID)["probe"] as? [String: Any] else {
            return []
        }
        return stored["sftpExtensionsAdvertised"] as? [String] ?? []
    }

    public static func forgetChannelBudget(locationID: String) {
        var object = read(locationID: locationID)
        object.removeValue(forKey: "channels")
        guard let url = try? GroupContainer.capabilitiesURL(locationID: locationID),
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
