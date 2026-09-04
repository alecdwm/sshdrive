// swift-tools-version:5.9
import PackageDescription

// SSHDriveCore: the modules shared by the agent, the extension, the CLI and askpass
// (DESIGN.md section 3). Kept as a local package so the Xcode targets and `swift test`
// build the same sources.
let package = Package(
    name: "SSHDriveCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Logging", targets: ["Logging"]),
        .library(name: "XPCProtocols", targets: ["XPCProtocols"]),
        .library(name: "Config", targets: ["Config"]),
        .library(name: "Index", targets: ["Index"]),
        .library(name: "SFTP", targets: ["SFTP"]),
        .library(name: "Secrets", targets: ["Secrets"]),
        .library(name: "SSHProcess", targets: ["SSHProcess"]),
    ],
    targets: [
        // os.Logger subsystems, shared by all processes.
        .target(name: "Logging"),

        // Paths, the SFTPTransport protocol, and the milestone 1 fake backend.
        // The wire client sits on `SSHProcess`'s `ByteStream`: an SFTP channel is a mux
        // client's stdio, exactly like an exec channel, so there is one definition of
        // that pipe and not two (sections 6.1, 6.2).
        .target(name: "SFTP", dependencies: ["Logging", "SSHProcess"]),

        // The location model and the JSON store in the app-group container.
        .target(name: "Config", dependencies: ["Logging"]),

        // The per-domain SQLite index: writer (agent) and read-only WAL reader (extension).
        .target(
            name: "Index",
            dependencies: ["Logging", "Config", "XPCProtocols"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // The agent's NSXPC interfaces plus the peer code requirement.
        .target(name: "XPCProtocols", dependencies: ["Logging"]),

        // The keychain wrapper and the askpass token protocol (section 4.2).
        .target(name: "Secrets", dependencies: ["Logging", "Config", "XPCProtocols"]),

        // ssh supervision: the -N ControlMaster, mux clients, the agent-built ProxyJump
        // chain, the login shell snapshot, sh -s scripts and exit classification
        // (DESIGN.md sections 6.1 and 9.2).
        .target(name: "SSHProcess", dependencies: ["Logging", "Config", "XPCProtocols"]),

        .testTarget(name: "SFTPTests", dependencies: ["SFTP", "SSHProcess"]),
        .testTarget(name: "XPCProtocolsTests", dependencies: ["XPCProtocols", "Config"]),
        .testTarget(name: "ConfigTests", dependencies: ["Config"]),
        .testTarget(name: "IndexTests", dependencies: ["Index", "Config", "XPCProtocols"]),
        .testTarget(name: "SecretsTests", dependencies: ["Secrets", "XPCProtocols"]),
        .testTarget(name: "SSHProcessTests", dependencies: ["SSHProcess", "Config", "XPCProtocols"]),

    ]
)
