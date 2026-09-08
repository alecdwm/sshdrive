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
        .library(name: "XPCInterfaces", targets: ["XPCInterfaces"]),
        .library(name: "Config", targets: ["Config"]),
        .library(name: "Index", targets: ["Index"]),
        .library(name: "SFTP", targets: ["SFTP"]),
        .library(name: "Secrets", targets: ["Secrets"]),
        .library(name: "SSHProcess", targets: ["SSHProcess"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "ProviderCore", targets: ["ProviderCore"]),
        .library(name: "SystemModel", targets: ["SystemModel"]),
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

        // libsqlite3, for the platforms with no `SQLite3` module of their own. Darwin
        // has one in the SDK and keeps using it, so the macOS build is untouched.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),

        // The per-domain SQLite index: writer (agent) and read-only WAL reader (extension).
        .target(
            name: "Index",
            dependencies: [
                "Logging", "Config", "XPCProtocols",
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // The values every process shares: identifiers, item snapshots, the agent
        // error codes, the askpass environment and the trash constants. No Objective-C
        // and no Apple framework, so it compiles everywhere.
        .target(name: "XPCProtocols", dependencies: ["Logging"]),

        // The @objc NSXPC protocols and the configured NSXPCInterfaces. macOS only -
        // the file bodies are `#if canImport(Darwin)` - and linked only by the four app
        // targets (docs/testing-architecture.md section 2.1). The peer code requirement
        // stays in XPCProtocols: it is a string, and the SecStaticCode check that applies
        // it lives in Apps/Agent.
        .target(name: "XPCInterfaces", dependencies: ["XPCProtocols", "Logging"]),

        // The keychain wrapper and the askpass token protocol (section 4.2).
        .target(name: "Secrets", dependencies: ["Logging", "Config", "XPCProtocols"]),

        // ssh supervision: the -N ControlMaster, mux clients, the agent-built ProxyJump
        // chain, the login shell snapshot, sh -s scripts and exit classification
        // (DESIGN.md sections 6.1 and 9.2).
        .target(name: "SSHProcess", dependencies: ["Logging", "Config", "XPCProtocols"]),

        // The agent's own derivations, kept in the package so they are unit-testable
        // without an app bundle: section 5.4's mode-to-capabilities mapping and name
        // rules, and section 6.2's transfer scheduler.
        .target(name: "AgentCore", dependencies: ["Logging", "Config", "Index", "ProviderCore", "SFTP", "Secrets", "SSHProcess", "XPCProtocols"]),

        // Everything Apps/FileProvider decides (docs/testing-architecture.md section 2.2):
        // the enumerators, the working-set change path, the reader store and its
        // readiness rule, item construction, the trash contract, the error selection and
        // the two Finder actions - behind ProviderFailure, EnumerationObserving,
        // ChangeObserving, AgentChannel, ReaderStoring and ProviderClock, with neutral
        // mirrors of Apple's identifiers, capabilities, flags, fields, content policy and
        // error codes. Apps/FileProvider is the adapter above it and holds no decision.
        .target(name: "ProviderCore", dependencies: ["Logging", "Config", "Index", "XPCProtocols"]),

        // The simulated macOS: a fileproviderd that drives ProviderCore the way the real
        // one drives the extension, with the measured quirks of docs/quirks/macos.md as a
        // per-version table and a virtual clock (docs/testing-architecture.md section 3).
        .target(name: "SystemModel", dependencies: ["Logging", "Config", "Index", "ProviderCore", "XPCProtocols"]),

        .testTarget(name: "LoggingTests", dependencies: ["Logging"]),
        .testTarget(name: "ProviderCoreTests", dependencies: ["ProviderCore", "Config", "Index", "XPCProtocols"]),
        .testTarget(name: "SystemModelTests", dependencies: ["SystemModel", "ProviderCore", "Config", "Index", "Logging", "XPCProtocols"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore", "Config", "Index", "SFTP", "Secrets", "SSHProcess", "XPCProtocols"]),
        .testTarget(name: "SFTPTests", dependencies: ["SFTP", "SSHProcess"]),
        .testTarget(name: "XPCProtocolsTests", dependencies: ["XPCProtocols", "Config"]),
        .testTarget(name: "ConfigTests", dependencies: ["Config"]),
        .testTarget(name: "IndexTests", dependencies: ["Index", "Config", "XPCProtocols"]),
        .testTarget(name: "SecretsTests", dependencies: ["Secrets", "XPCProtocols"]),
        .testTarget(name: "SSHProcessTests", dependencies: ["SSHProcess", "AgentCore", "SFTP", "Config", "XPCProtocols"]),

    ]
)
