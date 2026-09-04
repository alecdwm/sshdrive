import ArgumentParser
import Foundation

/// The test hooks the milestone 1 spikes need (DESIGN.md section 12, spikes S3, S4, S6).
///
/// These are deliberately a separate command group rather than flags on the real
/// commands: they exist to drive the fake backend and to make the system's own behaviour
/// visible, and they go on existing after milestone 1 because the fake backend stays as
/// the test double for every later milestone.
struct Debug: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Test hooks for the fake backend and the index.",
        subcommands: [
            Fake.self, Tree.self, Mutate.self, Anchor.self, Sweep.self, Policy.self,
            IndexCommand.self, Keychain.self, Secrets.self, Signal.self,
            DebugEvict.self, DebugTTL.self, Materialized.self, Stat.self, Xattr.self, Fault.self, Transfers.self,
            Stabilize.self, Testing.self, Transport.self,
            Breaker.self, Power.self, Presence.self, Rearm.self, Calls.self, Row.self,
            Watch.self, Roots.self, Held.self, Reconcile.self,
        ])
}

// MARK: fake locations

struct Fake: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create, list and remove fake-backed locations.",
        subcommands: [FakeAdd.self, FakeRemove.self, FakeList.self])
}

struct FakeAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a location backed by the in-memory tree and add its domain.")

    @Argument(help: "Name for the location; becomes its nickname and the domain's display name.")
    var name: String

    @Option(help: "How many sample files to seed under Documents/Reports.")
    var files: Int = 8

    /// `always` is NSFileProviderDomainTestingModeAlwaysEnabled (the domain comes up
    /// without the user approving the provider) and `interactive` is
    /// NSFileProviderDomainTestingModeInteractive (the system stops scheduling on its own
    /// and `sshdrive debug testing` drives it). Both need the appex's
    /// com.apple.developer.fileprovider.testing-mode entitlement, and the system does not
    /// let a domain give `interactive` back once it has been given.
    @Option(
        name: .customLong("testing-modes"),
        help: "Comma-separated: always, interactive. Needs the testing-mode entitlement.")
    var testingModes: String?

    func run() throws {
        var arguments = ["name": name, "files": String(files)]
        if let testingModes { arguments["testingModes"] = testingModes }
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.fake.add", arguments: arguments))
    }
}

struct FakeRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Remove a fake location, its domain and its index.")

    @Argument var name: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.fake.remove", arguments: ["name": name]))
    }
}

struct FakeList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List every location the agent knows.")

    func run() throws {
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.fake.list"))
    }
}

// `sshdrive debug ssh add` was milestone 2's stand-in for `sshdrive add`, and milestone 3
// replaced it: the real command does the `ssh -G` display, the two-pass collect connection
// and the relayed prompts it never had (sections 4.1, 4.2, 8). Nothing depended on it, so
// it is gone rather than kept as a second, worse way to make a location.

// MARK: the fake tree

struct Tree: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the fake tree as the server would see it.")

    @Argument var name: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.tree", arguments: ["name": name]))
    }
}

struct Mutate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Change the fake tree as if the server had, then run the sweep.",
        discussion: """
            Operations:
              create-file        needs --contents, optional --mode
              create-dir         optional --mode
              create-symlink     needs --target
              write              needs --contents; new mtime and inode
              touch              advances mtime only
              rewrite-invisibly  same size and second-mtime, new ns-mtime and inode.
                                 This is the change SFTP cannot see, and the reason for
                                 the generation column (section 5.3).
              chmod              needs --mode
              rename             needs --to
              delete             optional --recursive
            """)

    @Argument var name: String
    @Argument(help: "One of the operations listed above.")
    var op: String
    @Argument(help: "Path relative to the location root.")
    var path: String

    @Option(help: "Destination path, for rename.")
    var to: String?
    @Option(help: "File contents, for create-file, write and rewrite-invisibly.")
    var contents: String?
    @Option(help: "Octal mode, for create-file, create-dir and chmod.")
    var mode: String?
    @Option(help: "Link target, for create-symlink.")
    var target: String?
    @Flag(help: "Delete a directory and everything under it.")
    var recursive = false

    func run() throws {
        var arguments = ["name": name, "op": op, "path": path]
        if let to { arguments["to"] = to }
        if let contents { arguments["contents"] = contents }
        if let mode { arguments["mode"] = mode }
        if let target { arguments["target"] = target }
        if recursive { arguments["recursive"] = "true" }
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.mutate", arguments: arguments))
    }
}

// MARK: anchors and the sweep

struct Anchor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sync anchor hooks.", subcommands: [AnchorExpire.self])
}

struct AnchorExpire: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "expire",
        abstract: "Drop every anchor, so the next working-set read gets .syncAnchorExpired.",
        discussion: """
            S3 watches what the system re-enumerates after this. Turn the agent's catch-up
            sweep off first (`sshdrive debug sweep <name> off`) so the system's own
            behaviour is visible rather than ours (section 5.3).
            """)

    @Argument var name: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.anchor.expire", arguments: ["name": name]))
    }
}

struct Sweep: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Turn the agent's catch-up sweep on or off.",
        discussion: """
            The agent treats handing out a fresh working-set anchor exactly as it treats a
            reconnect: it runs one full sweep of the root set at once (section 5.3). S3
            needs that off to see what the system does on its own.
            """)

    @Argument var name: String
    @Argument(help: "on or off.")
    var state: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(
                command: "debug.sweep", arguments: ["name": name, "enabled": state]))
    }
}

// MARK: content policy

struct Policy: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set a folder's content policy at runtime (spike S6).",
        discussion: """
            eager-keep  the item is served with .downloadEagerlyAndKeepDownloaded and
                        loses allowsEvicting, which is what pinning does (section 7.1.1)
            lazy        an explicit .downloadLazily, which S6 checks overrides an eager
                        ancestor
            inherit     clears the marker
            """)

    @Argument var name: String
    @Argument(help: "Path relative to the location root.")
    var path: String
    @Argument(help: "eager-keep, lazy or inherit.")
    var policy: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(
                command: "debug.policy",
                arguments: ["name": name, "path": path, "policy": policy]))
    }
}

// MARK: the index

struct IndexCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index", abstract: "Read the domain's index.", subcommands: [IndexDump.self])
}

struct IndexDump: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump", abstract: "Print rows from the index as JSON.")

    @Argument var name: String

    @Option(help: "items, anchors or roots.")
    var table: String = "items"

    @Option(help: "Row limit, for anchors.")
    var limit: Int = 100

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(
                command: "debug.index.dump",
                arguments: ["name": name, "table": table, "limit": String(limit)]))
    }
}

struct Signal: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Signal the working-set enumerator, so the system re-asks for changes.",
        discussion: """
            With --container the folder's own enumerator is signalled instead. Reporting a
            row through the working set is not enough to make the system ingest an item
            whose parent it has never enumerated (spike S6, s6-3); signalling the folder is
            what asks for that listing.
            """)

    @Argument var name: String

    @Option(help: "Signal this folder's own enumerator instead of the working set. / is the root.")
    var container: String?

    @Flag(
        name: .customLong("error-resolved"),
        help:
            "Send signalErrorResolved(.serverUnreachable) alone - section 5.6's flush cue, without the working-set signal (S5).")
    var errorResolved = false

    func run() throws {
        var arguments = ["name": name]
        if errorResolved { arguments["errorResolved"] = "true" }
        if let container { arguments["container"] = container }
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.signal", arguments: arguments))
    }
}

// MARK: keychain

/// S1(d2): prove the agent, and only the agent, reaches the data-protection keychain
/// under the shared access group. The real store is milestone 2 (DESIGN.md sections 3.1,
/// 4.2); this writes one item, reads it back and deletes it again.
struct Keychain: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write, read back and delete one keychain item from the agent.")

    @Option(help: "Account name for the item.")
    var key: String = "spike:s1d2"

    @Option(help: "Value to write and read back.")
    var value: String?

    func run() throws {
        var arguments = ["key": key]
        if let value { arguments["value"] = value }
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.keychain", arguments: arguments))
    }
}

// MARK: the keychain and the askpass path (milestone 2, spike S2)

/// The milestone 2 hook set. `debug keychain` above proves `SecItem` is reachable at all;
/// this drives the real `Secrets` store and the whole askpass token protocol from the
/// launchd-started agent, which is the only process that can run either (DESIGN.md
/// sections 3.1, 4.2).
///
/// A stored value never comes back out: `lookup` reports whether the item exists and,
/// with `--value`, whether it matches.
struct Secrets: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secrets",
        abstract: "Store, look up, delete and list keychain items, and run one real ssh through askpass.",
        discussion: """
            sshdrive debug secrets list
            sshdrive debug secrets store --destination pw@192.168.64.1 --port 2201 --value spike-password
            sshdrive debug secrets store --identity ~/.ssh/sshdrive-spike-enc --value spike-passphrase
            sshdrive debug secrets lookup --key password:pw@192.168.64.1:2201
            sshdrive debug secrets delete --identity ~/.ssh/sshdrive-spike-enc
            sshdrive debug secrets classify --prompt "pw@nas's password: "
            sshdrive debug secrets connect --destination pw@192.168.64.1 --port 2201
            """)

    @Argument(help: "store | lookup | delete | list | classify | connect")
    var op: String = "list"

    @Option(help: "Item account, e.g. password:user@host:port or passphrase:/path.")
    var key: String?

    @Option(help: "user@host, with --port, instead of spelling the key out.")
    var destination: String?

    @Option(help: "Port for --destination.")
    var port: Int = 22

    @Option(help: "Identity file, for a passphrase item.")
    var identity: String?

    @Option(help: "Value to store, or to compare against on lookup.")
    var value: String?

    @Option(help: "Prompt text, for `classify`.")
    var prompt: String?

    @Option(help: "SSH_ASKPASS_PROMPT value, for `classify`: confirm, none, or empty.")
    var kind: String?

    @Option(help: "Remote command, for `connect`.")
    var command: String?

    @Option(help: "StrictHostKeyChecking for `connect` (default yes).")
    var hostKeyChecking: String?

    @Option(help: "Token purpose for `connect`: master or collect.")
    var purpose: String?

    @Option(help: "ProxyJump chain for `connect`: one or more user@host:port, comma separated.")
    var jump: String?

    @Flag(help: "Let `connect` consult a key agent (default: IdentityAgent=none).")
    var withKeyAgent = false

    func run() throws {
        var arguments: [String: String] = ["op": op, "port": String(port)]
        if let key { arguments["key"] = key }
        if let destination { arguments["destination"] = destination }
        if let identity { arguments["identity"] = identity }
        if let value { arguments["value"] = value }
        if let prompt { arguments["prompt"] = prompt }
        if let kind { arguments["kind"] = kind }
        if let command { arguments["command"] = command }
        if let hostKeyChecking { arguments["hostKeyChecking"] = hostKeyChecking }
        if let purpose { arguments["purpose"] = purpose }
        if let jump { arguments["jump"] = jump }
        if withKeyAgent { arguments["noAgent"] = "false" }
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.secrets", arguments: arguments))
    }
}

// MARK: eviction, the materialized set and the replica (spikes S4, S6)

/// S4-1, S4-3, S6-5. `NSFileProviderManager.evictItem` from the agent, which is where the
/// TTL loop of section 7 will call it from. The reply carries the error's domain and code
/// rather than a sentence, because which error comes back is the answer: the header
/// promises `NSFileProviderErrorUnsyncedEdits` for an item with pending changes and
/// `NSFileProviderErrorNonEvictable` for one the provider marked non-purgeable.
struct DebugEvict: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "evict",
        abstract: "Ask the system to evict one item (spike S4).")

    @Argument var name: String
    @Argument(help: "Path relative to the location root.")
    var path: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.evict", arguments: ["name": name, "path": path]))
    }
}

/// `sshdrive debug ttl <name> --seconds N`: the cache TTL in seconds, for this agent
/// process only, so a runbook can watch section 7's loop work without waiting fifteen
/// minutes per assertion. The pass itself is the ordinary one.
struct DebugTTL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ttl",
        abstract: "Override the cache TTL in seconds (spike/runbook hook).")

    @Argument var name: String

    @Option(help: "The TTL in seconds.")
    var seconds: Double?

    @Flag(help: "Go back to the location's own cache-ttl.")
    var off = false

    func run() throws {
        var arguments = ["name": name]
        if let seconds { arguments["seconds"] = String(seconds) }
        if off { arguments["off"] = "true" }
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.ttl", arguments: arguments))
    }
}

/// The two sets the system keeps for a domain. `--pending` proves an item really does have
/// unsynced changes before S4 tries to evict it; the materialized set is the enumerator the
/// TTL loop walks (section 7), and is how a headless run sees what an eager policy actually
/// downloaded.
struct Materialized: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the domain's materialized set, or its pending set.")

    @Argument var name: String

    @Flag(help: "Enumerate the pending set instead.")
    var pending = false

    func run() throws {
        var arguments = ["name": name]
        if pending { arguments["pending"] = "true" }
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.materialized", arguments: arguments))
    }
}

/// S4-2 and S4-5. `lstat` of the user-visible file, made from the launchd-started agent
/// with `AT_SYMLINK_NOFOLLOW`, exactly as the eviction loop will (sections 7, 9.1). The
/// path comes from `getUserVisibleURL`, not from the display name. `--read` opens and reads
/// one byte first, so the atime question can be asked without leaving the agent.
struct Stat: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "lstat an item's user-visible file from the agent (spike S4).")

    @Argument var name: String
    @Argument var path: String

    @Flag(help: "Open and read one byte before the stat.")
    var read = false

    func run() throws {
        var arguments = ["name": name, "path": path]
        if read { arguments["read"] = "true" }
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.stat", arguments: arguments))
    }
}

/// S4-4. What the index actually serves as `extendedAttributes` for a row (section 5.4),
/// next to the metadata version the xattr hash feeds. Compare with `xattr -l` on the mount
/// before and after an eviction.
struct Xattr: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the extended attributes the index serves for an item.")

    @Argument var name: String
    @Argument var path: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.xattr", arguments: ["name": name, "path": path]))
    }
}

/// Fault injection, for the two questions that need the agent to misbehave.
///
/// `--writes on` makes every `createItem` and `modifyItem` fail `.serverUnreachable`, so an
/// edit made in the mount stays in the system's pending set: that is the item S4-3 tries to
/// evict. `--fetch-delay` holds each `fetchContents` open, because a fake-backed fetch is a
/// memory copy and finishes before the next one starts, which would make the concurrency
/// S6-11 counts always 1.
struct Fault: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make the agent fail uploads, or hold fetches open (spikes S4, S6).")

    @Argument var name: String

    @Option(help: "on or off: fail every upload with .serverUnreachable.")
    var writes: String?

    @Option(name: .customLong("fetch-delay"), help: "Milliseconds to hold each fetchContents open.")
    var fetchDelay: Int?

    @Option(
        name: .customLong("version-mismatch"),
        help: "on or off: modifyItem replies with versions that are not the ones written.")
    var versionMismatch: String?

    @Option(
        name: .customLong("collisions"),
        help: "on or off: fail every createItem with .filenameCollision.")
    var collisions: String?

    @Option(
        name: .customLong("upload-delay"),
        help: "Milliseconds to hold every upload open between the bytes landing in the temp file and the lstat of the destination - section 5.5's conflict window. Change the file on the server inside it to get a real conflict copy (milestone 4).")
    var uploadDelay: Int?

    @Option(
        name: .customLong("frozen-metadata"),
        help: "on or off: modifyItem replies with the metadata version the item had before the change, which is S10's control case for the xattr hash.")
    var frozenMetadata: String?

    @Option(
        help:
            "on or off: every transport call and every connect attempt fails as if the server had gone (section 6.3). What a VM guest uses in place of a link-down it cannot cause."
    )
    var unreachable: String?

    @Option(
        name: .customLong("transport-hang"),
        help:
            "Milliseconds every transport call stalls before doing anything - a network that has gone away without saying so.")
    var transportHang: Int?

    @Option(
        name: .customLong("connect-hang"),
        help:
            "Milliseconds every connect attempt stalls, with calls left alone: section 6.3's bounded wait, on its own.")
    var connectHang: Int?

    @Option(
        name: .customLong("connect-failure"),
        help:
            "transient | authenticationDeadline | authenticationFailed | hostKeyFailed | keyAgentNotReady: what --unreachable reports the attempt failed as (section 6.1's classifier).")
    var connectFailure: String?

    @Option(
        name: .customLong("fetch-error"),
        help:
            "noSuchItem | cannotSynchronize | none: what every fetchContents answers instead of reading bytes (S5).")
    var fetchError: String?

    func run() throws {
        var arguments = ["name": name]
        if let fetchError { arguments["fetchError"] = fetchError }
        if let unreachable { arguments["unreachable"] = unreachable }
        if let transportHang { arguments["transportHang"] = String(transportHang) }
        if let connectHang { arguments["connectHang"] = String(connectHang) }
        if let connectFailure { arguments["connectFailure"] = connectFailure }
        if let writes { arguments["writes"] = writes }
        if let fetchDelay { arguments["fetchDelay"] = String(fetchDelay) }
        if let versionMismatch { arguments["versionMismatch"] = versionMismatch }
        if let collisions { arguments["collisions"] = collisions }
        if let uploadDelay { arguments["uploadDelay"] = String(uploadDelay) }
        if let frozenMetadata { arguments["frozenMetadata"] = frozenMetadata }
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.fault", arguments: arguments))
    }
}

/// S6-11. How many `fetchContents` calls the system keeps open at once, which bounds the
/// transfer scheduler's backlog (section 6.2). The timeline is per fetch, so the overlap is
/// visible rather than inferred from a peak.
struct Transfers: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Concurrent fetchContents: in flight, peak and a timeline.")

    @Argument var name: String

    @Flag(help: "Clear the peak and the timeline after printing.")
    var reset = false

    func run() throws {
        var arguments = ["name": name]
        if reset { arguments["reset"] = "true" }
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.transfers", arguments: arguments))
    }
}

/// `waitForStabilization`, then the sub-hierarchy barrier on the root. On an idle headless
/// Mac fileproviderd throttles its schedulers, so without this a spike measures the
/// throttle rather than the behaviour (results.md 2026-09-04, s3-1).
struct Stabilize: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Wait until the system has caught up with both sides.")

    @Argument var name: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.stabilize", arguments: ["name": name]))
    }
}

/// Manual scheduling, which the appex's `com.apple.developer.fileprovider.testing-mode`
/// entitlement unlocks. It only works on a domain added with
/// `debug fake add --testing-modes interactive`; on any other domain the error is itself
/// worth recording, so it is printed rather than thrown.
struct Testing: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, and optionally run, the system's pending testing operations.")

    @Argument var name: String

    @Argument(help: "list or run.")
    var action: String = "list"

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(
                command: "debug.testing",
                arguments: ["name": name, "run": action == "run" ? "true" : "false"]))
    }
}


// MARK: milestone 5 - the breaker, sleep and wake, and the deadline re-arm

/// Section 6.3's circuit breaker, as the agent holds it right now.
///
/// The report is the state machine's own fields: the state sentence, the consecutive
/// failure count, what the next backoff would be, whether the location is stopped, and
/// section 4.2's two re-arm flags. The counters (`attempts`, `reconnects`, `failFastCalls`,
/// `waitedCalls`) are what an S5 run reads to tell the three admission paths apart.
struct Breaker: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or drive one location's circuit breaker (section 6.3).")

    @Argument var name: String

    @Flag(help: "Run `-O exit` on the master: the connection dies with no process killed.")
    var drop = false

    @Flag(help: "Reset the breaker, as a path change or a wake does, and reconnect.")
    var reset = false

    @Flag(help: "Clear a stop the way `sshdrive test` does, and attempt once.")
    var connect = false

    @Option(
        name: .customLong("quiet-recovery"),
        help:
            "on or off: a reconnect sends neither signalErrorResolved nor signalEnumerator, so S5 can send one by hand.")
    var quietRecovery: String?

    func run() throws {
        var arguments = ["name": name]
        if let quietRecovery { arguments["quietRecovery"] = quietRecovery }
        if drop { arguments["drop"] = "true" }
        if reset { arguments["reset"] = "true" }
        if connect { arguments["connect"] = "true" }
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.breaker", arguments: arguments))
    }
}

/// Section 6.1's will-sleep and did-wake handlers, and section 6.3's path gate, driven by
/// hand. `pmset sleepnow` is the real path; a VM that does not honour it uses this, and the
/// spike records which was used.
struct Power: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drive the sleep, wake and network-path handlers (sections 6.1, 6.3).")

    @Argument(
        help: "will-sleep | did-wake | path-down | path-up. Omit to just report the counters.")
    var event: String?

    func run() throws {
        var arguments: [String: String] = [:]
        if let event { arguments["event"] = event }
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.power", arguments: arguments))
    }
}

/// Section 4.2's presence test, read exactly as the re-arm reads it: seconds since the last
/// input event from `CGEventSource`, and the screen-lock flag from
/// `CGSessionCopyCurrentDictionary`.
struct Presence: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What the agent thinks about whether a human is here (section 4.2).")

    func run() throws {
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.presence", arguments: [:]))
    }
}

/// Section 4.2's two re-arm triggers after an authentication-deadline stop. A headless VM
/// has no screen to unlock, so the distributed notification's own handler is called here.
struct Rearm: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fire the screen-unlock or present-user re-arm trigger (section 4.2).")

    @Argument var name: String

    @Flag(help: "Fire the present-user request trigger instead of the screen unlock.")
    var request = false

    func run() throws {
        var arguments = ["name": name]
        if request { arguments["request"] = "true" }
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.rearm", arguments: arguments))
    }
}


/// Spike S5's journal of the File Provider calls that reached the agent: when each
/// arrived, what it answered, how long it took, and the gap since the previous call of the
/// same method for the same item. Every "how long does the system wait before calling
/// again" question in the S5 row of section 11 is read off this.
struct Calls: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The File Provider calls the agent has seen, with the gaps between them.")

    @Argument var name: String?

    @Option(help: "How many entries to print (default 200).")
    var limit: Int?

    @Flag(help: "Clear the journal after printing.")
    var reset = false

    func run() throws {
        var arguments: [String: String] = [:]
        if let name { arguments["name"] = name }
        if let limit { arguments["limit"] = String(limit) }
        if reset { arguments["reset"] = "true" }
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.calls", arguments: arguments))
    }
}

/// S5's working-set questions, driven against the index directly. `--forget` deletes the
/// row and its subtree with a deletion anchor, which is what the extension reports through
/// the working set when a listing says an item has gone; `--content-version` gives the row
/// a version the system cannot match, which is what the reconcile walk produces for an item
/// with a pending local edit. Neither touches the server.
struct Row: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report an item deleted, or with an unmatched version, through the working set.")

    @Argument var name: String
    @Argument var path: String

    @Flag(help: "Delete the row and its subtree, with a deletion anchor.")
    var forget = false

    @Option(name: .customLong("content-version"), help: "Give the row this content version.")
    var contentVersion: String?

    func run() throws {
        var arguments = ["name": name, "path": path]
        if forget { arguments["forget"] = "true" }
        if let contentVersion { arguments["contentVersion"] = contentVersion }
        AgentClient.prettyPrint(try AgentClient.send(command: "debug.row", arguments: arguments))
    }
}


// MARK: change detection (section 6.4)

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drive section 6.4's change detection by hand.",
        discussion: """
            `--now` runs one cycle at the current tier; `--full` runs one full sweep, which
            is what a reconnect and a fresh working-set anchor both trigger. `--pause on`
            stops the loop so a spike owns the timing. `--clock-skew` shifts the sweep's own
            server-clock reference, which is the only way to exercise the window from a
            container: containers share the host's clock and Docker has no time namespace,
            so what is under test is the window the agent computes rather than the value
            the server reports, and `status` says the reference is shifted.
            """)

    @Argument var name: String

    @Flag(help: "Run one cycle now.")
    var now = false

    @Flag(help: "Run one full sweep now.")
    var full = false

    @Option(help: "on|off: pause the cadence loop.")
    var pause: String?

    @Option(name: .customLong("clock-skew"), help: "Seconds to shift the stored server timestamp by.")
    var clockSkew: Int?

    @Flag(name: .customLong("forget-stamp"), help: "Drop the stored server timestamp, so the next sweep is unbounded.")
    var forgetStamp = false

    func run() throws {
        var arguments = ["name": name]
        if now { arguments["now"] = "true" }
        if full { arguments["full"] = "true" }
        if let pause { arguments["pause"] = pause }
        if let clockSkew { arguments["clockSkew"] = String(clockSkew) }
        if forgetStamp { arguments["forgetStamp"] = "true" }
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.watch", arguments: arguments, timeout: 1200))
    }
}

struct Roots: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The section 6.5 root set, and the rotation the next tier 0 cycle takes.")

    @Argument var name: String

    @Flag(help: "Rebuild the materialized reason from the system first.")
    var refresh = false

    @Option(help: "Mark the first N directory rows as materialized roots, to measure the rotation at scale.")
    var seed: Int?

    func run() throws {
        var arguments = ["name": name]
        if refresh { arguments["refresh"] = "true" }
        if let seed { arguments["seed"] = String(seed) }
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.roots", arguments: arguments, timeout: 300))
    }
}

struct Held: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What the mass-deletion guard is holding.")

    @Argument var name: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.held", arguments: ["name": name]))
    }
}


struct Reconcile: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rebuild the index from the system's replica (section 5.3).")

    @Argument var name: String

    @Flag(help: "Set meta.reconciling first, so the walk runs on a healthy index.")
    var force = false

    func run() throws {
        var arguments = ["name": name]
        if force { arguments["force"] = "true" }
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.reconcile", arguments: arguments, timeout: 600))
    }
}
