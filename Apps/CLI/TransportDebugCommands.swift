import ArgumentParser
import Foundation

/// `sshdrive debug transport …`: the milestone 3 hooks for the transfer scheduler
/// (DESIGN.md section 6.2), the channel budget (section 6.1) and the hidden-name rules
/// (section 5.4).
///
/// Deliberately separate from the real commands. `sshdrive status` reports the same three
/// things for a user; these drive them without Finder in the way, which is how the queue,
/// the two channels and a mid-transfer cancel are exercised on a headless Mac.
struct Transport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transport",
        abstract: "Channel budget, transfer scheduler and hidden names.",
        subcommands: [
            TransportReport.self, TransportReprobe.self, TransportHidden.self,
            TransportFetch.self, TransportUpload.self, TransportEscape.self,
        ])
}

struct TransportReport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "The channel budget, the remote identity and the scheduler's counters.")

    @Argument var name: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.transport", arguments: ["name": name]))
    }
}

struct TransportReprobe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reprobe",
        abstract: "Forget the cached MaxSessions answer, reconnect and probe again.")

    @Argument var name: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(
                command: "debug.transport.reprobe", arguments: ["name": name]))
    }
}

struct TransportHidden: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hidden",
        abstract: "Names recorded but never shown, with the reason (section 5.4).")

    @Argument var name: String

    func run() throws {
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.transport.hidden", arguments: ["name": name]))
    }
}

struct TransportFetch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Fetch one path through the scheduler, to a temp file that is discarded.",
        discussion: """
            Run several at once from a shell loop to see the four-at-a-time rule and the
            queue in the log. `--background` puts the fetch in section 6.2's background
            class, which starts only while no foreground transfer is waiting.
            """)

    @Argument var name: String
    @Argument(help: "Path inside the location, e.g. data/big/1g.bin.")
    var path: String

    @Flag(help: "Schedule it as a background transfer.")
    var background = false

    @Option(name: .customLong("partial"), help: "A range request, as offset:length.")
    var partial: String?

    @Option(
        name: .customLong("cancel-after"),
        help: "Cancel the transfer this many milliseconds in.")
    var cancelAfter: Int?

    func run() throws {
        var arguments = ["name": name, "path": path]
        if background { arguments["background"] = "1" }
        if let partial { arguments["partial"] = partial }
        if let cancelAfter { arguments["cancelAfterMilliseconds"] = String(cancelAfter) }
        AgentClient.prettyPrint(
            try AgentClient.send(
                command: "debug.transport.fetch", arguments: arguments))
    }
}

struct TransportUpload: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload N MiB of zeroes through the scheduler and the bulk channel.")

    @Argument var name: String
    @Argument(help: "Destination path inside the location.")
    var path: String

    @Option(name: .customLong("size-mib"), help: "How many MiB to send.")
    var sizeMiB: Int = 64

    @Option(
        name: .customLong("cancel-after"),
        help: "Cancel the upload this many milliseconds in.")
    var cancelAfter: Int?

    func run() throws {
        var arguments = ["name": name, "path": path, "megabytes": String(sizeMiB)]
        if let cancelAfter { arguments["cancelAfterMilliseconds"] = String(cancelAfter) }
        AgentClient.prettyPrint(
            try AgentClient.send(
                command: "debug.transport.upload", arguments: arguments))
    }
}

struct TransportEscape: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "escape",
        abstract: "Hand createItem a filename, and a symlink target, of your choosing.",
        discussion: """
            The section 9.1 chokepoint test: the filename goes straight to the same
            `RelativePath` constructor a `createItem` from the extension uses, with no
            shell and no string path anywhere in between.
            """)

    @Argument var name: String

    @Option(help: "The filename createItem is given. Defaults to \"..\".")
    var filename: String = ".."

    @Option(help: "Path of the parent directory inside the location; default the root.")
    var parent: String?

    @Option(name: .customLong("symlink-target"), help: "Create a symlink with this target.")
    var symlinkTarget: String?

    @Flag(help: "Create a directory rather than a file.")
    var directory = false

    func run() throws {
        var arguments = ["name": name, "filename": filename]
        if let parent { arguments["parent"] = parent }
        if let symlinkTarget { arguments["symlinkTarget"] = symlinkTarget }
        if directory { arguments["directory"] = "1" }
        AgentClient.prettyPrint(
            try AgentClient.send(command: "debug.transport.escape", arguments: arguments))
    }
}
