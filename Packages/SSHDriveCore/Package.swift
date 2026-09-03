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
        .target(name: "SFTP", dependencies: ["Logging"]),

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

        // Keychain wrapper. Stub until milestone 2.
        .target(name: "Secrets", dependencies: ["Logging", "Config"]),

        // ssh supervision, ControlMaster, exec channels. Stub until milestone 2.
        .target(name: "SSHProcess", dependencies: ["Logging", "Config"]),

        .testTarget(name: "SFTPTests", dependencies: ["SFTP"]),
        .testTarget(name: "XPCProtocolsTests", dependencies: ["XPCProtocols", "Config"]),
        .testTarget(name: "ConfigTests", dependencies: ["Config"]),
        .testTarget(name: "IndexTests", dependencies: ["Index", "Config"]),
    ]
)
