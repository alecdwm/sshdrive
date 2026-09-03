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

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(
                command: "debug.fake.add", arguments: ["name": name, "files": String(files)]))
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
        abstract: "Signal the working-set enumerator, so the system re-asks for changes.")

    @Argument var name: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.signal", arguments: ["name": name]))
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
