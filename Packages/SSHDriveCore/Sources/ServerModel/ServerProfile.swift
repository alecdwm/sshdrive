import Foundation

/// Which SFTP server the account's subsystem is.
///
/// The three differ in exactly the places `sshdrive status` reads: the advertised
/// extension list (`SQ-024`, `SQ-025`, `SQ-026`) and whether an rc file can get in front
/// of the `VERSION` reply (`SQ-014`, external only).
public enum SFTPImplementation: String, Sendable, Equatable {
    /// `Subsystem sftp /usr/lib/openssh/sftp-server`: a real child of the login shell, so
    /// the account's rc output lands in front of the `VERSION` packet (`SQ-014`).
    case opensshExternal
    /// `Subsystem sftp internal-sftp`: sshd serves it in-process, no shell, no rc noise.
    case opensshInternal
    /// `tailscaled`'s own Go subsystem (`SQ-024`).
    case goPkgSFTP
    /// No SFTP subsystem at all.
    case none
}

/// Which `find` the server has. `ServerModel` is the only place `.bsd` is ever exercised:
/// the testbed has no BSD (`docs/testing-architecture.md` section 4.1).
public enum ServerFindFlavour: String, Sendable, Equatable {
    /// GNU findutils: `-cmin` and `-printf` both work.
    case gnu
    /// BusyBox 1.36.1 as shipped: `find: unrecognized: -cmin` (`SQ-001`), no `-printf`
    /// (`SQ-003`), and `find --version` prints an error and **exits 0** (`SQ-002`).
    case busybox
    /// A pre-1.34 busybox, which the testbed's `alp-nocmin` shim was meant to emulate.
    /// Identical to `.busybox` today, and kept as its own value only so a future
    /// measurement has somewhere to land.
    case busyboxNoCmin
    /// BSD `find`: `-cmin` yes, `-printf` no. Modelled, never measured.
    case bsd

    /// Whether `find -cmin` is accepted at all (`SQ-001`).
    public var takesCmin: Bool {
        switch self {
        case .gnu, .bsd: return true
        case .busybox, .busyboxNoCmin: return false
        }
    }

    /// Whether `find -printf` is accepted (`SQ-003`).
    public var takesPrintf: Bool { self == .gnu }

    /// What `find --version | head -1` prints, and what it exits with.
    ///
    /// `SQ-002`: busybox prints `find: unrecognized: --version` on **stderr** and exits
    /// **0**, so a probe keyed on the exit status calls every busybox server GNU. The
    /// probe of section 8.1 reads the banner and the `-cmin` answer instead.
    public var versionBanner: (line: String, exitStatus: Int32) {
        switch self {
        case .gnu: return ("find (GNU findutils) 4.9.0", 0)
        case .bsd: return ("", 1)
        case .busybox, .busyboxNoCmin: return ("", 0)
        }
    }

    /// The `busybox | head -1` banner the probe script also collects.
    public var busyboxBanner: String? {
        switch self {
        case .busybox: return "BusyBox v1.36.1 (2024-05-30 12:00:00 UTC) multi-call binary."
        case .busyboxNoCmin: return "BusyBox v1.33.2 (2021-01-01 00:00:00 UTC) multi-call binary."
        case .gnu, .bsd: return nil
        }
    }
}

/// The account's login shell, and what its rc file does before our sentinel.
///
/// `SQ-015`: rc files print on non-interactive startup in **every** shape - `.bashrc` for
/// bash, `.zshenv` for zsh (read for every invocation), `config.fish` for `fish -c`,
/// `.cshrc` for tcsh. The exec channel still runs `sh -s` (section 9.2), so the login
/// shell decides only the noise; the *script* shell is `shellExecutable` below.
public enum LoginShell: String, Sendable, Equatable, CaseIterable {
    case bashQuiet
    case bashNoisy
    /// `deb-shells`' `bashbg`: the rc file leaves `( sleep 300 & )` holding stdout, so
    /// EOF never arrives and only the closing sentinel ends the read (`SQ-016`).
    case bashBackgroundHolder
    case zsh
    case fish
    case tcsh
    case dash
    case busyboxAsh
    /// A `ForceCommand internal-sftp` account: no shell at all.
    case none

    /// What `sh -s` actually is on that server. Debian's `/bin/sh` is dash (`SQ-017`), so
    /// the sleep-and-mtime watchdog branch of the heartbeat wrapper is the *ordinary*
    /// Linux path; Alpine's is busybox ash, which takes the `read -t` branch.
    public var scriptShell: ScriptShell {
        switch self {
        case .busyboxAsh: return .busyboxAsh
        case .none: return .dash
        default: return .dash
        }
    }

    /// The bytes the account writes before anything of ours, exactly as the testbed's
    /// accounts do (`testbed/README.md`, `SQ-015`).
    public var rcNoise: String {
        switch self {
        case .bashQuiet, .none: return ""
        case .bashNoisy: return "bashrc: hello from .bashrc\n"
        case .bashBackgroundHolder: return "bashrc: hello from .bashrc\n"
        case .zsh: return "zshenv: hello from .zshenv\n"
        case .fish: return "config.fish: hello from config.fish\n"
        case .tcsh: return "cshrc: hello from .cshrc\n"
        case .dash: return "profile: hello from .profile\n"
        case .busyboxAsh: return "profile: hello from /etc/profile\n"
        }
    }

    /// True where the rc file leaves a background child holding stdout, so a reader that
    /// waits for EOF hangs for ever (`SQ-016`).
    public var holdsStdoutOpen: Bool { self == .bashBackgroundHolder }
}

/// Which real shell on this box runs a `ServerModel` script.
///
/// The deliberate design choice of `docs/testing-architecture.md` section 4.2: the remote
/// scripts are run against **real** shells, because three of this project's worst bugs
/// lived exactly there - the `;;` dash rejects (`SQ-018`), the `{ … }` group the heartbeat
/// reader would otherwise eat, and the `printf "\0<sentinel>"` that ate its own sentinel
/// (`SQ-020`). A shell this box does not have is skipped by name, never faked.
public enum ScriptShell: String, Sendable, Equatable, CaseIterable {
    case dash
    case bash
    case busyboxAsh
    case zsh

    /// The candidate executables, in the order to try them.
    public var candidates: [String] {
        switch self {
        case .dash: return ["/usr/bin/dash", "/bin/dash", "/bin/sh"]
        case .bash: return ["/usr/bin/bash", "/bin/bash"]
        case .zsh: return ["/usr/bin/zsh", "/bin/zsh"]
        case .busyboxAsh: return ["/usr/bin/busybox", "/bin/busybox"]
        }
    }

    /// The arguments that make it read a script from stdin.
    public var stdinScriptArguments: [String] {
        self == .busyboxAsh ? ["sh", "-s"] : ["-s"]
    }

    /// The first candidate that exists on this box, or nil.
    public var executablePath: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var isAvailable: Bool { executablePath != nil }

    /// The sentence a skipped scenario prints. Naming the shell and the package is the
    /// difference between a skip a reader can act on and one they cannot.
    public var skipReason: String {
        switch self {
        case .busyboxAsh:
            return "busybox is not installed on this box (apt install busybox-static); the busybox rows are skipped, not faked"
        case .zsh: return "zsh is not installed on this box; the zsh rows are skipped, not faked"
        case .bash: return "bash is not installed on this box; the bash rows are skipped, not faked"
        case .dash: return "no dash and no /bin/sh on this box; the POSIX rows are skipped, not faked"
        }
    }
}

/// A `ForceCommand` on the account.
public enum ForceCommand: String, Sendable, Equatable {
    /// `SQ-013`: the exec channel may answer with SFTP framing **or** with the plain
    /// sentence `This service allows sftp connections only.`; both mean "no shell access
    /// (ForceCommand)", never "shell output unusable".
    case internalSFTP
    /// The same refusal, in the SFTP-framing shape.
    case internalSFTPFraming
}

/// Whether a session gets a process group of its own.
public enum SessionGrouping: Sendable, Equatable {
    /// sshd's behaviour: a session and process group of its own, so `kill … 0` has a
    /// blast radius of exactly that session (`SQ-012`).
    case ownProcessGroup
    /// Tailscale SSH: every session of every client shares the named daemon's process
    /// group, so `kill -TERM 0` from one session kills the others *and the connections
    /// under them* (`SQ-010`). The wrapper names `-$$` for exactly this reason.
    case sharedWith(String)

    public var isShared: Bool { if case .sharedWith = self { return true }; return false }
}

/// How the account authenticates.
public enum AuthShape: Sendable, Equatable {
    case key
    case password(String)
    case keyboardInteractive(String)
    /// Tailscale SSH: the tailnet ACL is the auth (`SQ-061`).
    case none
    /// A server that accepts **both**, which is what makes the two-pass collect
    /// connection's "your key did not authenticate and the server accepts passwords"
    /// branch reachable (`SQ-064`).
    case keyOrPassword(String)

    public var acceptsAKey: Bool {
        switch self {
        case .key, .keyOrPassword, .none: return true
        case .password, .keyboardInteractive: return false
        }
    }

    public var password: String? {
        switch self {
        case let .password(value), let .keyboardInteractive(value), let .keyOrPassword(value):
            return value
        case .key, .none: return nil
        }
    }
}

/// The advertised `SSH_FXP_VERSION` extension lists, in the order each server sends them.
///
/// `status` reads these, so the order and the exact spelling matter: a name that
/// round-trips wrongly costs a feature a level (`SQ-024`, `SQ-025`, `SQ-026`).
public enum SFTPExtensionSets {

    /// Go `pkg/sftp` advertises **exactly** these three and nothing else; that fingerprint
    /// is what identifies it, and no version advertises `fsync` or `limits` (`SQ-024`).
    public static let goPkgSFTP = [
        "hardlink@openssh.com",
        "posix-rename@openssh.com",
        "statvfs@openssh.com",
    ]

    /// OpenSSH 9.2p1's `sftp-server`, measured on `deb` (`SQ-025`). Anything carrying
    /// `fsync`/`lsetstat`/`limits`/`expand-path` is OpenSSH.
    public static let openSSH9_2 = [
        "posix-rename@openssh.com",
        "statvfs@openssh.com",
        "fstatvfs@openssh.com",
        "hardlink@openssh.com",
        "fsync@openssh.com",
        "lsetstat@openssh.com",
        "limits@openssh.com",
        "expand-path@openssh.com",
        "copy-data",
        "home-directory",
        "users-groups-by-id@openssh.com",
    ]

    /// OpenSSH 9.6's, which is the same eleven names: every one of them predates 9.2, so
    /// the fingerprint cannot tell 9.2 and 9.6 apart and the **identification string** is
    /// the only thing that can (`SQ-025`, `SQ-036`). Kept as its own constant so a future
    /// release that does move the set has a place to land without touching 9.2's row.
    public static let openSSH9_6 = openSSH9_2

    /// Alpine's `internal-sftp` offers the same set as the external server, so nothing in
    /// the write protocol degrades there (`SQ-026`).
    public static let alpineInternalSFTP = openSSH9_2
}

/// One server, as a value.
///
/// `docs/testing-architecture.md` section 4.1: "One value describes a server, and the
/// testbed's twelve services are twelve constants." Every field is a row of
/// `docs/quirks/servers.md`, and every rule `FakeSFTPServer`, `FakeExecChannel` and
/// `FakeSSH` apply cites the id it comes from.
public struct ServerProfile: Sendable, Equatable {

    /// The testbed service name, or the shape's name where there is no service.
    public var name: String
    public var sftp: SFTPImplementation
    /// The advertised `SSH_FXP_VERSION` list, in order (`SQ-024`-`SQ-026`).
    public var extensions: [String]
    public var findFlavour: ServerFindFlavour
    public var loginShell: LoginShell
    public var forceCommand: ForceCommand?
    /// sshd's `MaxSessions`. 10 is the OpenSSH default; `deb-maxsess` is 2 (`SQ-021`).
    public var maxSessions: Int
    public var sessionGrouping: SessionGrouping
    /// Set only on `deb` (15 s / 3). It reaps nothing (`SQ-009`).
    public var clientAliveInterval: Int?
    /// False on every server measured: sshd reaping the session does not reach a child
    /// that has left the foreground job (`SQ-008`).
    public var reapsOrphans: Bool
    /// The one thing a container could never give us: Docker has no time namespace, so a
    /// clock-skewed server has never been tested against a real skew (`SQ-054`). The model
    /// is the only coverage there will ever be.
    public var clockOffset: TimeInterval
    /// The umask a `mkdir`'s attributes go through, so an asked-for 0700 can land 0755
    /// and needs a `setstat` afterwards (`SQ-033`).
    public var umask: UInt32
    public var caseInsensitive: Bool
    /// `SQ-034`: a plain `rename` may refuse an existing name or may overwrite it, and
    /// the probe is what decides. True here means "overwrites".
    public var renameOverwrites: Bool
    public var hasSHA256Sum: Bool
    public var hasMkfifo: Bool
    /// `uname -s` and `uname -m`, which is what the helper manifest keys on.
    public var unameSM: String
    /// What `ssh -v` reports as `remote software version` (`SQ-036`).
    public var identificationString: String
    public var auth: AuthShape
    /// The port the testbed publishes it on, where it has one.
    public var port: Int?
    /// The `$HOME` the account spells (section 5.7).
    public var home: String
    /// Every quirk row this profile is a carrier of, so a scenario can say which it
    /// exercises without repeating the list.
    public var quirks: [ServerQuirkID]

    public init(
        name: String,
        sftp: SFTPImplementation,
        extensions: [String],
        findFlavour: ServerFindFlavour,
        loginShell: LoginShell,
        forceCommand: ForceCommand? = nil,
        maxSessions: Int = 10,
        sessionGrouping: SessionGrouping = .ownProcessGroup,
        clientAliveInterval: Int? = nil,
        reapsOrphans: Bool = false,
        clockOffset: TimeInterval = 0,
        umask: UInt32 = 0o022,
        caseInsensitive: Bool = false,
        renameOverwrites: Bool = false,
        hasSHA256Sum: Bool = true,
        hasMkfifo: Bool = true,
        unameSM: String = "Linux aarch64",
        identificationString: String,
        auth: AuthShape = .key,
        port: Int? = nil,
        home: String = "/home/alec",
        quirks: [ServerQuirkID] = []
    ) {
        self.name = name
        self.sftp = sftp
        self.extensions = extensions
        self.findFlavour = findFlavour
        self.loginShell = loginShell
        self.forceCommand = forceCommand
        self.maxSessions = maxSessions
        self.sessionGrouping = sessionGrouping
        self.clientAliveInterval = clientAliveInterval
        self.reapsOrphans = reapsOrphans
        self.clockOffset = clockOffset
        self.umask = umask
        self.caseInsensitive = caseInsensitive
        self.renameOverwrites = renameOverwrites
        self.hasSHA256Sum = hasSHA256Sum
        self.hasMkfifo = hasMkfifo
        self.unameSM = unameSM
        self.identificationString = identificationString
        self.auth = auth
        self.port = port
        self.home = home
        self.quirks = quirks
    }

    /// The extension list as the `SFTP` module's option set, which is what `status` and
    /// `capabilities.json` carry.
    public var extensionFlags: SFTPServerExtensionsMirror {
        SFTPServerExtensionsMirror(names: extensions)
    }

    /// True where an rc file can put bytes in front of the SFTP `VERSION` reply, which
    /// makes `sftp(1)` fail with "Received message too long" and forces our client onto an
    /// exec channel (`SQ-014`).
    public var sftpStreamCarriesRCNoise: Bool {
        sftp == .opensshExternal && !loginShell.rcNoise.isEmpty
    }

    /// Whether the account has a usable shell at all (`SQ-013`).
    public var hasShellAccess: Bool { forceCommand == nil && loginShell != .none }
}

/// The `extensions` list as flags, without importing `SFTP` into every reader.
public struct SFTPServerExtensionsMirror: Sendable, Equatable {
    public let names: [String]
    public init(names: [String]) { self.names = names }
    public var hasPosixRename: Bool { names.contains("posix-rename@openssh.com") }
    public var hasStatvfs: Bool { names.contains("statvfs@openssh.com") }
    public var hasFsync: Bool { names.contains("fsync@openssh.com") }
    public var hasLimits: Bool { names.contains("limits@openssh.com") }
    public var hasLsetstat: Bool { names.contains("lsetstat@openssh.com") }
}

// MARK: - The testbed's twelve services, and the two real servers

public extension ServerProfile {

    /// `deb`, 2201. The main target: OpenSSH 9.2p1, GNU `find`, and the one service with
    /// `ClientAliveInterval` set (15 s / 3) - which reaps nothing (`SQ-009`).
    static let debian = ServerProfile(
        name: "deb",
        sftp: .opensshInternal,
        extensions: SFTPExtensionSets.openSSH9_2,
        findFlavour: .gnu,
        loginShell: .bashQuiet,
        clientAliveInterval: 15,
        unameSM: "Linux aarch64",
        identificationString: "OpenSSH_9.2p1 Debian-2+deb12u10",
        auth: .key,
        port: 2201,
        quirks: [
            ServerQuirks.opensshAdvertisesTheFullSet, ServerQuirks.opensshGivesASessionItsOwnGroup,
            ServerQuirks.clientAliveDoesNotReap, ServerQuirks.backgroundChildSurvivesAKill,
            ServerQuirks.debianShIsDash, ServerQuirks.mminMissesCtimeOnly,
            ServerQuirks.etxtbsyOverARunningBinary, ServerQuirks.mkdirGoesThroughTheUmask,
        ])

    /// `deb`'s `pw` account: a plain password, stored as `password:pw@<host>:2201`.
    static let debianPassword = ServerProfile(
        name: "deb/pw",
        sftp: .opensshInternal,
        extensions: SFTPExtensionSets.openSSH9_2,
        findFlavour: .gnu,
        loginShell: .bashQuiet,
        identificationString: "OpenSSH_9.2p1 Debian-2+deb12u10",
        auth: .password("spike-password"),
        port: 2201,
        home: "/home/pw",
        quirks: [ServerQuirks.promptStringsAreExact])

    /// `deb`'s `keypass` account: key **or** password, which is the branch the two-pass
    /// collect connection exists for (`SQ-064`).
    static let debianKeyOrPassword = ServerProfile(
        name: "deb/keypass",
        sftp: .opensshInternal,
        extensions: SFTPExtensionSets.openSSH9_2,
        findFlavour: .gnu,
        loginShell: .bashQuiet,
        identificationString: "OpenSSH_9.2p1 Debian-2+deb12u10",
        auth: .keyOrPassword("spike-password"),
        port: 2201,
        home: "/home/keypass",
        quirks: [ServerQuirks.keyAndPasswordTogether, ServerQuirks.promptStringsAreExact])

    /// `deb-shells`, 2202: every login-shell shape plus `ForceCommand internal-sftp`.
    /// The constant carries `bashnoisy`; the others are the `shell(_:)` variants below.
    static let debianShells = ServerProfile(
        name: "deb-shells",
        sftp: .opensshInternal,
        extensions: SFTPExtensionSets.openSSH9_2,
        findFlavour: .gnu,
        loginShell: .bashNoisy,
        identificationString: "OpenSSH_9.2p1 Debian-2+deb12u10",
        auth: .key,
        port: 2202,
        quirks: [ServerQuirks.rcFilesPrintNonInteractively])

    /// `deb-shells`' `bashbg`: the account that never closes stdout (`SQ-016`).
    static let debianBackgroundHolder = ServerProfile.debianShells
        .with(name: "deb-shells/bashbg", loginShell: .bashBackgroundHolder,
              quirks: [ServerQuirks.rcFilesPrintNonInteractively,
                       ServerQuirks.backgroundChildHoldsStdout])

    /// `deb-shells`' `forcesftp`: `ForceCommand internal-sftp` answering an exec channel
    /// with the plain sentence rather than SFTP framing (`SQ-013`).
    static let debianForceCommand = ServerProfile.debianShells
        .with(name: "deb-shells/forcesftp", loginShell: LoginShell.none,
              forceCommand: ForceCommand.internalSFTP,
              quirks: [ServerQuirks.forceCommandAnswersPlainText])

    /// `deb-extsftp`, 2203: an **external** `sftp-server` behind a noisy rc file, so the
    /// rc output lands in front of the `VERSION` reply (`SQ-014`).
    static let debianExternalSFTP = ServerProfile(
        name: "deb-extsftp/extnoisy",
        sftp: .opensshExternal,
        extensions: SFTPExtensionSets.openSSH9_2,
        findFlavour: .gnu,
        loginShell: .bashNoisy,
        identificationString: "OpenSSH_9.2p1 Debian-2+deb12u10",
        auth: .key,
        port: 2203,
        quirks: [ServerQuirks.noisyRCBreaksTheExternalSFTPServer,
                 ServerQuirks.rcFilesPrintNonInteractively])

    /// `deb-extsftp`'s `extquiet`: the same external server with a clean stream.
    static let debianExternalSFTPQuiet = ServerProfile.debianExternalSFTP
        .with(name: "deb-extsftp/extquiet", loginShell: .bashQuiet, quirks: [])

    /// `deb-kbdint`, 2204: keyboard-interactive only, whose prompt is
    /// `(<user>@<host>) Password: ` (`SQ-062`).
    static let debianKbdInt = ServerProfile(
        name: "deb-kbdint",
        sftp: .opensshInternal,
        extensions: SFTPExtensionSets.openSSH9_2,
        findFlavour: .gnu,
        loginShell: .bashQuiet,
        identificationString: "OpenSSH_9.2p1 Debian-2+deb12u10",
        auth: .keyboardInteractive("spike-password"),
        port: 2204,
        home: "/home/kbd",
        quirks: [ServerQuirks.keyboardInteractivePromptShape, ServerQuirks.promptStringsAreExact])

    /// `deb-maxsess`, 2205: `MaxSessions 2`, which leaves exactly one spare channel
    /// beside the metadata SFTP channel (`SQ-021`).
    static let debianMaxSessions = ServerProfile(
        name: "deb-maxsess",
        sftp: .opensshInternal,
        extensions: SFTPExtensionSets.openSSH9_2,
        findFlavour: .gnu,
        loginShell: .bashQuiet,
        maxSessions: 2,
        identificationString: "OpenSSH_9.2p1 Debian-2+deb12u10",
        auth: .keyOrPassword("spike-password"),
        port: 2205,
        quirks: [ServerQuirks.maxSessionsTwoLeavesOneSpare,
                 ServerQuirks.aChannelIsProvedByItsHandshake])

    /// `alp`, 2206: busybox `find` and `internal-sftp` on musl, which is every NAS's
    /// shape (`SQ-001`, `SQ-026`).
    static let alpine = ServerProfile(
        name: "alp",
        sftp: .opensshInternal,
        extensions: SFTPExtensionSets.alpineInternalSFTP,
        findFlavour: .busybox,
        loginShell: .busyboxAsh,
        renameOverwrites: false,
        unameSM: "Linux aarch64",
        identificationString: "OpenSSH_9.7",
        auth: .key,
        port: 2206,
        quirks: [
            ServerQuirks.noBusyboxCmin, ServerQuirks.busyboxFindVersionExitsZero,
            ServerQuirks.noBusyboxPrintf, ServerQuirks.mminMissesCtimeOnly,
            ServerQuirks.internalSFTPMatchesTheExternal, ServerQuirks.renameSemanticsVary,
        ])

    /// `alp-ext`, 2207: the external `sftp-server` on Alpine, with a quiet rc.
    static let alpineExternalSFTP = ServerProfile.alpine
        .with(name: "alp-ext", sftp: .opensshExternal, port: 2207,
              quirks: [ServerQuirks.internalSFTPMatchesTheExternal])

    /// `alp-nocmin`, 2208: meant to emulate pre-1.34 busybox. It adds nothing today,
    /// because stock busybox 1.36.1 already rejects `-cmin` and `-printf` (`SQ-001`).
    static let alpineNoCmin = ServerProfile.alpine
        .with(name: "alp-nocmin", findFlavour: .busyboxNoCmin, port: 2208,
              quirks: [ServerQuirks.noBusyboxCmin, ServerQuirks.noBusyboxPrintf])

    /// `bastion-a`, 2210: hop 1 of the `ProxyJump` chain, password `spike-password-a`.
    static let bastionA = ServerProfile(
        name: "bastion-a",
        sftp: .opensshInternal,
        extensions: SFTPExtensionSets.openSSH9_2,
        findFlavour: .gnu,
        loginShell: .bashQuiet,
        identificationString: "OpenSSH_9.2p1 Debian-2+deb12u10",
        auth: .password("spike-password-a"),
        port: 2210,
        home: "/home/hop",
        quirks: [ServerQuirks.hopsAreToldApartByArgv, ServerQuirks.hopNeedsControlPathNone])

    /// `bastion-b`: hop 2, with a **different** password, so per-host keychain keying is
    /// visibly doing its job (`SQ-063`).
    static let bastionB = ServerProfile.bastionA
        .with(name: "bastion-b", auth: .password("spike-password-b"), port: .some(nil))

    /// `inner`: the destination behind both hops.
    static let inner = ServerProfile.debian
        .with(name: "inner", clientAliveInterval: .some(nil),
              auth: .keyOrPassword("spike-password"), port: .some(nil))

    /// `ts-ssh`: a **Tailscale SSH** node. `tailscaled` serves SSH itself, so `none` auth
    /// (`SQ-061`), a Go `pkg/sftp` subsystem advertising exactly three extensions
    /// (`SQ-024`), and every session in `tailscaled`'s own process group (`SQ-010`) -
    /// which is what made `kill -TERM 0` kill sibling sessions and the connections under
    /// them. This is the shape of the owner's own Tailscale SSH server.
    static let tailscaleSSH = ServerProfile(
        name: "ts-ssh",
        sftp: .goPkgSFTP,
        extensions: SFTPExtensionSets.goPkgSFTP,
        findFlavour: .gnu,
        loginShell: .bashQuiet,
        sessionGrouping: .sharedWith("tailscaled"),
        unameSM: "Linux x86_64",
        identificationString: "Tailscale",
        auth: AuthShape.none,
        quirks: [
            ServerQuirks.tailscaleSharesTheProcessGroup, ServerQuirks.goPkgSFTPAdvertisesThree,
            ServerQuirks.tailscaleAuthenticatesWithNone, ServerQuirks.signalKillIs255WithNoStderr,
            ServerQuirks.helperDiesWithTheRelay,
        ])

    /// **The owner's own Debian server**, the one their first cask install added: OpenSSH
    /// 9.2p1 Debian-2+deb12u10, GNU `find`, x86_64 (results 2026-09-05, 2026-09-08).
    static let ownerDebian = ServerProfile(
        name: "owner-debian",
        sftp: .opensshInternal,
        extensions: SFTPExtensionSets.openSSH9_2,
        findFlavour: .gnu,
        loginShell: .bashQuiet,
        unameSM: "Linux x86_64",
        identificationString: "OpenSSH_9.2p1 Debian-2+deb12u10",
        auth: .key,
        quirks: [ServerQuirks.opensshAdvertisesTheFullSet])

    /// **The owner's own Tailscale SSH server** (x86_64 Debian), the one whose tier 2
    /// stream died 255 fifteen seconds after `ready` (results 2026-09-08). The testbed's
    /// `ts-ssh` exists to reproduce it; this constant is the server itself.
    static let ownerTailscale = ServerProfile.tailscaleSSH
        .with(name: "owner-tailscale")

    /// A server whose sshd is a newer OpenSSH: the extension **set** is identical to
    /// 9.2's, so only the identification string moves (`SQ-025`, `SQ-036`).
    static let openSSH9_6 = ServerProfile.ownerDebian
        .with(name: "openssh-9.6", identificationString: "OpenSSH_9.6p1 Ubuntu-3ubuntu13.5")

    /// Not in the testbed at all: the model is the only coverage BSD will ever get
    /// (`docs/testing-architecture.md` section 4.1). No `-printf`, no FreeBSD `rust-std`
    /// for the helper (`SQ-065`).
    static let freeBSD = ServerProfile(
        name: "freebsd",
        sftp: .opensshExternal,
        extensions: SFTPExtensionSets.openSSH9_2,
        findFlavour: .bsd,
        loginShell: .bashQuiet,
        hasSHA256Sum: false,
        unameSM: "FreeBSD amd64",
        identificationString: "OpenSSH_9.5 FreeBSD-20231004",
        auth: .key,
        home: "/usr/home/alec",
        quirks: [ServerQuirks.noBusyboxPrintf])

    /// A Synology DSM box: busybox without `-cmin`, no `sha256sum`, no working `mkfifo`
    /// on some volumes (`SQ-001`, `SQ-067`, `SQ-068`).
    static let synologyDSM = ServerProfile(
        name: "synology-dsm",
        sftp: .opensshInternal,
        extensions: SFTPExtensionSets.openSSH9_2,
        findFlavour: .busyboxNoCmin,
        loginShell: .busyboxAsh,
        clockOffset: -300,
        hasSHA256Sum: false,
        hasMkfifo: false,
        unameSM: "Linux x86_64",
        identificationString: "OpenSSH_8.2p1",
        auth: .password("spike-password"),
        home: "/volume1/homes/alec",
        quirks: [ServerQuirks.noBusyboxCmin, ServerQuirks.containersShareTheHostClock])

    /// The testbed's twelve services, in port order.
    static let testbed: [ServerProfile] = [
        .debian, .debianShells, .debianExternalSFTP, .debianKbdInt, .debianMaxSessions,
        .alpine, .alpineExternalSFTP, .alpineNoCmin, .bastionA, .bastionB, .inner,
        .tailscaleSSH,
    ]

    /// One field changed, everything else kept. A profile is a value; this is how the
    /// account variants of one service are spelled without repeating twenty fields.
    func with(
        name: String? = nil,
        sftp: SFTPImplementation? = nil,
        extensions: [String]? = nil,
        findFlavour: ServerFindFlavour? = nil,
        loginShell: LoginShell? = nil,
        forceCommand: ForceCommand? = nil,
        maxSessions: Int? = nil,
        sessionGrouping: SessionGrouping? = nil,
        clientAliveInterval: Int?? = nil,
        clockOffset: TimeInterval? = nil,
        umask: UInt32? = nil,
        renameOverwrites: Bool? = nil,
        hasMkfifo: Bool? = nil,
        identificationString: String? = nil,
        auth: AuthShape? = nil,
        port: Int?? = nil,
        home: String? = nil,
        quirks: [ServerQuirkID]? = nil
    ) -> ServerProfile {
        var copy = self
        if let name { copy.name = name }
        if let sftp { copy.sftp = sftp }
        if let extensions { copy.extensions = extensions }
        if let findFlavour { copy.findFlavour = findFlavour }
        if let loginShell { copy.loginShell = loginShell }
        if let forceCommand { copy.forceCommand = forceCommand }
        if let maxSessions { copy.maxSessions = maxSessions }
        if let sessionGrouping { copy.sessionGrouping = sessionGrouping }
        if let clientAliveInterval { copy.clientAliveInterval = clientAliveInterval }
        if let clockOffset { copy.clockOffset = clockOffset }
        if let umask { copy.umask = umask }
        if let renameOverwrites { copy.renameOverwrites = renameOverwrites }
        if let hasMkfifo { copy.hasMkfifo = hasMkfifo }
        if let identificationString { copy.identificationString = identificationString }
        if let auth { copy.auth = auth }
        if let port { copy.port = port }
        if let home { copy.home = home }
        if let quirks { copy.quirks = quirks }
        return copy
    }
}

// MARK: - The prompt strings, exactly as OpenSSH 10.2 prints them

/// `SQ-060`: the prompt strings are exact, **trailing spaces included**. These are the
/// captured OpenSSH 10.2p1 strings; `Secrets.AskpassPrompt` classifies them and the
/// keychain keys off the account they name, so a character wrong here is a scenario that
/// proves nothing.
public enum OpenSSHPrompts {

    /// `sshconnect2.c`: `"%s@%s's password: "`.
    public static func password(user: String, host: String) -> String {
        "\(user)@\(host)'s password: "
    }

    /// `"Enter passphrase for key '%.100s': "`. The path is `%.100s`-**truncated**
    /// (`SQ-048`), so the prompt text alone can never be the keychain key.
    public static func passphrase(keyPath: String) -> String {
        "Enter passphrase for key '\(String(keyPath.prefix(100)))': "
    }

    /// Keyboard-interactive: `"(%s@%s) Password: "` (`SQ-062`).
    public static func keyboardInteractive(user: String, host: String) -> String {
        "(\(user)@\(host)) Password: "
    }

    /// The multi-line host-key question, which reaches askpass with
    /// `SSH_ASKPASS_PROMPT` **unset**, exactly like a password (`SQ-047`).
    public static func hostKey(host: String, keyType: String = "ED25519",
                               fingerprint: String = "SHA256:0000000000000000000000000000000000000000000") -> String {
        """
        The authenticity of host '\(host)' can't be established.
        \(keyType) key fingerprint is \(fingerprint).
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])? 
        """
    }

    /// What `ssh` prints when every method failed, at `LogLevel=ERROR`. The same sentence
    /// for a missing, a dead and a *locked* key agent (`SQ-052`).
    public static let permissionDenied = "Permission denied (publickey,password)."

    /// `SQ-013`: what a `ForceCommand internal-sftp` account answers an exec channel with.
    public static let forceCommandSentence = "This service allows sftp connections only.\n"

    /// What a mux client prints when the **server** refused another session (`SQ-021`),
    /// which is the one wording `ChannelProbeVerdict` may cache.
    public static let sessionRefused = "mux_client_request_session: session request failed"

    /// What a mux client prints when the **master** has gone (`SQ-079`), which must never
    /// be cached as a `MaxSessions` budget.
    public static func deadMaster(controlPath: String) -> String {
        "Control socket connect(\(controlPath)): No such file or directory"
    }

    /// `SQ-043`: a second master finds the first's socket and runs with none at all.
    public static let controlSocketExists =
        "ControlSocket already exists, disabling multiplexing"
}
