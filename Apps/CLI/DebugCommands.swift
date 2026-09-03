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
            IndexCommand.self, Keychain.self, Signal.self,
            Evict.self, Materialized.self, Stat.self, Xattr.self, Fault.self, Transfers.self,
            Stabilize.self, Testing.self,
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

    func run() throws {
        var arguments = ["name": name]
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

// MARK: eviction, the materialized set and the replica (spikes S4, S6)

/// S4-1, S4-3, S6-5. `NSFileProviderManager.evictItem` from the agent, which is where the
/// TTL loop of section 7 will call it from. The reply carries the error's domain and code
/// rather than a sentence, because which error comes back is the answer: the header
/// promises `NSFileProviderErrorUnsyncedEdits` for an item with pending changes and
/// `NSFileProviderErrorNonEvictable` for one the provider marked non-purgeable.
struct Evict: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Ask the system to evict one item (spike S4).")

    @Argument var name: String
    @Argument(help: "Path relative to the location root.")
    var path: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.evict", arguments: ["name": name, "path": path]))
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

    func run() throws {
        var arguments = ["name": name]
        if let writes { arguments["writes"] = writes }
        if let fetchDelay { arguments["fetchDelay"] = String(fetchDelay) }
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
