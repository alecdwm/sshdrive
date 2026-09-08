import Foundation
import XCTest

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@testable import SSHProcess
@testable import ServerModel

/// Suite K, the master half: the mux clients' options, the `-N` master's own shape, the
/// orphan sweep and what `agent stop` leaves behind (`docs/testing-architecture.md`
/// sections 4.2 and 5; DESIGN.md section 6.1).
///
/// Like `TransportScenarios`, everything here that can be run for real is run for real:
/// `SSHMaster` spawns `FakeSSH` by the same `posix_spawn` and the same argv it spawns
/// `/usr/bin/ssh` with, and the masters this file stands up are actual processes with
/// actual `AF_UNIX` sockets, so `ControlSocket`'s `lstat`, its `-O check` parse, its kill
/// and its `/proc` argv match all run against the thing they are written for.
final class MasterScenarios: XCTestCase {

    private var stubs: [FakeSSH] = []
    private var masters: [SSHMaster] = []
    private var spawned: [SpawnedProcess] = []
    private var reaped: Set<pid_t> = []
    private var scratch: [String] = []
    private var openFDs: [Int32] = []
    private var previousBinaryPath: String?

    override func tearDown() async throws {
        // Nothing this file starts may outlive it: a leaked `ssh` stub is a bystander the
        // next scenario's `killStrayMasters` would find, and a leaked socket in `$TMPDIR`
        // is exactly the mess `SQ-074` is about.
        for master in masters { await master.shutdown() }
        masters = []
        for process in spawned where !reaped.contains(process.pid) {
            kill(process.pid, SIGKILL)
            _ = Spawn.wait(pid: process.pid)
            reaped.insert(process.pid)
        }
        spawned = []
        reaped = []
        for fd in openFDs { close(fd) }
        openFDs = []
        for path in scratch { try? FileManager.default.removeItem(atPath: path) }
        scratch = []
        if let previousBinaryPath {
            SSHProcess.sshBinaryPath = previousBinaryPath
            self.previousBinaryPath = nil
        }
        for stub in stubs { stub.uninstall() }
        stubs = []
    }

    // MARK: - The harness (the private helpers of `TransportScenarios`, kept private here
    // too so neither file has to make the other's seams public)

    private func fakeSSH(_ profile: ServerProfile, hostKeyKnown: Bool = true) throws -> FakeSSH {
        if let reason = FakeSSHD.unavailabilityReason(for: profile) {
            throw XCTSkip("\(profile.name): \(reason)")
        }
        let stub = try FakeSSH(profile: profile, hostKeyKnown: hostKeyKnown)
        stub.install()
        stubs.append(stub)
        return stub
    }

    /// The host as `ssh` would see it: a profile name that carries an account (`deb/pw`)
    /// is a testbed label, not a hostname.
    private func hostName(_ profile: ServerProfile) -> String {
        profile.name.replacingOccurrences(of: "/", with: "-")
    }

    private func master(
        _ profile: ServerProfile, controlPath: String, user: String = "alec"
    ) -> SSHMaster {
        var environment = ProcessInfo.processInfo.environment
        environment["USER"] = user
        let target = SSHTarget(host: hostName(profile), user: user, port: profile.port)
        let master = SSHMaster(configuration: .init(
            locationID: UUID().uuidString,
            target: target,
            environment: environment,
            authenticationDeadline: 15,
            controlPath: controlPath))
        masters.append(master)
        return master
    }

    private func controlPath(_ stub: FakeSSH) -> String {
        stub.directory.appendingPathComponent("ctl").path
    }

    private func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["USER"] = "alec"
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// A master spawned the way the agent spawns one - the shipping argv, `posix_spawn`,
    /// stdin from `/dev/null`, stderr on a pipe of ours - but without an `SSHMaster`
    /// around it, which is precisely the state an orphan is in.
    @discardableResult
    private func spawnMaster(
        _ stub: FakeSSH, controlPath path: String, host: String = "deb",
        logLevel: String = "ERROR", extraEnvironment: [String: String] = [:],
        rewriting rewrite: ([String]) -> [String] = { $0 }
    ) throws -> SpawnedProcess {
        let invocation = SSHCommandBuilder.master(
            target: SSHTarget(host: host, user: "alec"), controlPath: path, logLevel: logLevel)
        let process = try Spawn.run(
            executable: stub.executablePath,
            argv: [stub.executablePath] + rewrite(invocation.arguments),
            environment: environment(extraEnvironment),
            wantsStderr: true, stdinFromDevNull: true)
        spawned.append(process)
        scratch.append(path)
        return process
    }

    private func waitForSocket(_ path: String, within seconds: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("the control socket never appeared at \(path)")
    }

    /// Polls for the child to exit and reaps it. Nil while it is still running.
    private func exitOf(_ process: SpawnedProcess, within seconds: TimeInterval) async
        -> ProcessExit?
    {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let exit = Spawn.poll(pid: process.pid) {
                reaped.insert(process.pid)
                return exit
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    /// Whether a child is still running, **without** reaping it: the zombie state is what
    /// `SQ-075` is about and `waitpid` would destroy the evidence.
    ///
    /// The state is read through `ControlSocket.isZombie`, which is the product's own
    /// reader and answers on both platforms - `/proc/<pid>/stat` here, `p_stat` from
    /// `KERN_PROC_PID` on Darwin. The `/proc` spelling below cannot: it returns nil on a
    /// Mac, and `?? true` then read every one of `K6`'s killed masters as still running.
    private func isRunning(_ process: SpawnedProcess) -> Bool {
        guard !reaped.contains(process.pid) else { return false }
        return kill(process.pid, 0) == 0 && !ControlSocket.isZombie(process.pid)
    }

    /// Waits for a signalled child to actually die, **without** reaping it.
    /// `ControlSocket.terminate` returns once it has delivered a signal, and the KILL
    /// half a second behind the TERM takes effect a moment after that.
    private func waitUntilStopped(_ process: SpawnedProcess, within seconds: TimeInterval = 15)
        async -> Bool
    {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isRunning(process) { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }

    /// `/proc/<pid>/stat`'s third field **read directly**, which is the corroboration for
    /// `ControlSocket.isZombie`'s Linux branch rather than a second implementation of it.
    /// Linux only; the assertions that use it say so.
    private func processState(of pid: pid_t) -> String? {
        #if canImport(Darwin)
            return nil
        #else
            guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                let close = text.lastIndex(of: ")")
            else { return nil }
            return text[text.index(after: close)...]
                .split(whereSeparator: { $0 == " " }).first.map(String.init)
        #endif
    }

    /// `/proc/<pid>/stat`'s fourth field, the parent. Nil off Linux.
    private func parentPID(of pid: pid_t) -> pid_t? {
        #if canImport(Darwin)
            return nil
        #else
            guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                let close = text.lastIndex(of: ")")
            else { return nil }
            let fields = text[text.index(after: close)...].split(whereSeparator: { $0 == " " })
            guard fields.count > 1 else { return nil }
            return pid_t(fields[1])
        #endif
    }

    private func rewriting(_ keyword: String, to value: String) -> ([String]) -> [String] {
        { arguments in
            var out = arguments
            for index in out.indices
            where index > 0 && out[index - 1] == "-o" && out[index].hasPrefix("\(keyword)=") {
                out[index] = "\(keyword)=\(value)"
            }
            return out
        }
    }

    // MARK: - K3: the mux client's three options

    /// **K3** (`SQ-042`, `SQ-079`): every mux client carries `-F /dev/null`,
    /// `BatchMode=yes` and `ProxyCommand=/usr/bin/false`, and with them a client whose
    /// socket is missing **fails** instead of connecting. The failure is classified
    /// `masterLost` - a mux client that exits before its channel opened is never an
    /// authentication failure - so it costs a reconnect through the breaker and never
    /// stops the location.
    func testK3_theMuxOptionsMakeAMissingSocketFailAndTheFailureIsMasterLost() async throws {
        let stub = try fakeSSH(.debian)
        let path = controlPath(stub)

        // Every mux client the agent runs: the two SFTP channels, the exec channels and
        // the `-O` commands (section 6.1's `MUX=` line).
        for invocation in [
            SSHCommandBuilder.sftpChannel(controlPath: path, host: "deb"),
            SSHCommandBuilder.execChannel(controlPath: path, host: "deb"),
            SSHCommandBuilder.control("check", controlPath: path, host: "deb"),
            SSHCommandBuilder.control("exit", controlPath: path, host: "deb"),
        ] {
            let configFlag = try XCTUnwrap(invocation.arguments.firstIndex(of: "-F"))
            XCTAssertEqual(invocation.arguments[configFlag + 1], "/dev/null",
                           "SQ-042: no config at all, so no Match exec and no SendEnv")
            XCTAssertEqual(invocation.option("BatchMode"), "yes",
                           "SQ-042: a mux client can never prompt")
            XCTAssertEqual(invocation.option("ProxyCommand"), "/usr/bin/false",
                           "SQ-042: the fallback connection dies before a byte is exchanged")
        }

        let master = self.master(.debian, controlPath: path)
        try await master.connect()
        await master.shutdown()

        var diagnostics = ""
        do {
            _ = try await master.openExecChannel(
                script: RemoteScript(body: "true"), readinessDeadline: 5)
            XCTFail("SQ-042: a mux client with no socket must fail rather than connect")
        } catch let error as SSHProcessError {
            diagnostics = "\(error)"
            XCTAssertEqual(error.classification, .masterLost,
                           "SQ-042: a client that never opened its channel is master lost")
            XCTAssertEqual(error.classification?.stopsReconnection, false,
                           "section 6.1: it costs a reconnect, never the location")
        }
        XCTAssertTrue(diagnostics.contains("Control socket connect"), "SQ-079: ssh's own wording")
        XCTAssertEqual(stub.unsupervisedFallbacks, [],
                       "SQ-042: no second connection was opened, which is the whole point")
    }

    /// **K3**, the bite (`SQ-042`, `SQ-035`): the same open **without** the three options,
    /// run for real against the stub. `ssh` does not fail a session open on a missing
    /// socket - it notes it at debug level and makes a direct connection of its own,
    /// reading the config files and authenticating from scratch. Here it succeeds, which
    /// under the agent means a second, unsupervised connection to the server with the
    /// config's own timeouts and nobody watching it.
    func testK3_withoutThemAMuxClientOpensASecondUnsupervisedConnection() async throws {
        let stub = try fakeSSH(.debian)
        let missing = controlPath(stub) + "-never-existed"
        let environment = ["USER": "alec", "PATH": "/usr/bin:/bin"]

        // The shape that has only `-S`: what a mux client looks like without section
        // 6.1's rule.
        let unguarded = try Spawn.capture(
            executable: stub.executablePath,
            argv: [stub.executablePath, "-S", missing, "deb", "sh", "-s"],
            environment: environment, timeout: 20)
        XCTAssertEqual(unguarded.exit.status, 0,
                       "SQ-042: it did not fail - it connected, which is the bug")
        XCTAssertEqual(stub.unsupervisedFallbacks.count, 1,
                       "and the connection it made was a second one, unsupervised")

        // The shape we ship, against the same missing socket.
        let guarded = try Spawn.capture(
            executable: stub.executablePath,
            argv: [stub.executablePath]
                + SSHCommandBuilder.execChannel(controlPath: missing, host: "deb").arguments,
            environment: environment, timeout: 20)
        XCTAssertEqual(guarded.exit.status, 255)
        let stderr = String(decoding: guarded.stderr, as: UTF8.self)
        XCTAssertTrue(stderr.contains("Control socket connect(\(missing))"))
        XCTAssertTrue(stderr.contains("\r\n"), "SQ-035: ssh's stderr lines end CRLF")
        XCTAssertEqual(stub.unsupervisedFallbacks.count, 1,
                       "SQ-042: still one - the guarded client opened nothing")
    }

    /// **K3** (`SQ-042`, `SQ-052`): and the reason the classification matters. A mux
    /// client gets no askpass token (section 4.2), so the fallback connection cannot
    /// authenticate and dies with the one sentence that stops a location for ever. It
    /// must not: `channelOpened` false is what the classifier reads, not the text.
    func testK3_aFallbackConnectionsPermissionDeniedIsStillMasterLost() async throws {
        let stub = try fakeSSH(.debianPassword)
        let missing = controlPath(stub) + "-never-existed"
        let fallback = try Spawn.capture(
            executable: stub.executablePath,
            argv: [stub.executablePath, "-S", missing, hostName(.debianPassword), "sh", "-s"],
            environment: ["USER": "alec", "PATH": "/usr/bin:/bin"], timeout: 20)
        XCTAssertEqual(fallback.exit.status, 255)
        let stderr = String(decoding: fallback.stderr, as: UTF8.self)
        XCTAssertTrue(stderr.contains(OpenSSHPrompts.permissionDenied),
                      "SQ-052: the bare sentence, from a connection nobody could answer for")

        XCTAssertEqual(
            SSHExitClassifier.classify(
                role: .muxClient, exitStatus: 255, stderr: stderr, channelOpened: false),
            .masterLost,
            "SQ-042: before its channel opened, a mux client's death is always the master's")
        // The bite: read the same stderr as though the channel had opened and it is an
        // authentication failure, which stops the location until the user runs `test`.
        XCTAssertEqual(
            SSHExitClassifier.classify(
                role: .muxClient, exitStatus: 255, stderr: stderr, channelOpened: true),
            .authenticationFailed)
        XCTAssertTrue(SSHExitClassification.authenticationFailed.stopsReconnection)
        XCTAssertFalse(SSHExitClassification.masterLost.stopsReconnection)
    }

    // MARK: - K4: the master's shape

    /// **K4** (`SQ-041`, `SQ-036`): the master is `-N` with `ControlMaster=yes`,
    /// `ControlPersist=no` and a `ControlPath` of `$TMPDIR/sshdrive-<id8>` - the first
    /// eight hex digits of the location id, and never `%C`, which hashes user, host and
    /// port and would give two locations on one host the same socket.
    ///
    /// With `ControlPersist=no` the master stays in the foreground as our own child, and
    /// that is what makes the pid, the stderr and the exit signal ours: this spawns one
    /// and reads all three off the real process.
    func testK4_theMasterIsNWithControlPersistNoAndItsPidStderrAndExitAreOurs() async throws {
        let stub = try fakeSSH(.debian)
        let locationID = UUID().uuidString
        let path = ControlSocket.path(forLocationID: locationID)

        let expected = "sshdrive-"
            + String(locationID.lowercased().filter(\.isHexDigit).prefix(8))
        XCTAssertEqual((path as NSString).lastPathComponent, expected,
                       "$TMPDIR/sshdrive-<id8>, section 6.1")
        XCTAssertTrue(path.hasPrefix(ControlSocket.temporaryDirectory()))

        let invocation = SSHCommandBuilder.master(
            target: SSHTarget(host: "deb", user: "alec"), controlPath: path, logLevel: "DEBUG1")
        XCTAssertTrue(invocation.hasFlag("-N"), "no session, only the mux socket")
        XCTAssertEqual(invocation.option("ControlMaster"), "yes")
        XCTAssertEqual(invocation.option("ControlPersist"), "no", "SQ-041")
        XCTAssertEqual(invocation.option("ControlPath"), path)
        XCTAssertFalse(invocation.arguments.contains { $0.contains("%C") },
                       "section 6.1: never %C - it hashes user, host and port")
        XCTAssertEqual(invocation.option("ForkAfterAuthentication"), "no",
                       "the other keyword that would detach the master")

        let process = try spawnMaster(stub, controlPath: path, logLevel: "DEBUG1")
        let collector = StderrCollector(fd: process.stderrFD)
        try await waitForSocket(path)
        XCTAssertTrue(ControlSocket.isSocket(path), "SQ-074: and it really is an AF_UNIX socket")

        // The pid is ours: still running, still a child of this process, still an `ssh`.
        XCTAssertNil(Spawn.poll(pid: process.pid),
                     "SQ-041: with ControlPersist=no the master stays in the foreground")
        XCTAssertTrue(
            ControlSocket.isLiveSSH(process.pid),
            "SQ-082: and the kernel's short name for it is the one the sweep matches on - "
                + "expected \(ControlSocket.masterProcessName), got "
                + "\(ControlSocket.processName(of: process.pid) ?? "nothing")")
        if let parent = parentPID(of: process.pid) {
            XCTAssertEqual(parent, getpid(), "SQ-041: it is our own child, not a reparented fork")
        }

        // The stderr is ours: it arrived up a pipe we hold.
        var stderr = collector.text
        let deadline = Date().addingTimeInterval(5)
        while !stderr.contains("remote software version"), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            stderr = collector.text
        }
        XCTAssertTrue(stderr.contains("remote software version"),
                      "SQ-036: at DEBUG1 ssh names the server, and we are the ones reading it")

        // And so is the exit signal.
        XCTAssertEqual(kill(process.pid, SIGKILL), 0)
        let killed = await exitOf(process, within: 10)
        let exit = try XCTUnwrap(killed)
        XCTAssertEqual(exit.signal, SIGKILL, "SQ-041: the master's death is ours to see")
    }

    /// **K4**, the bite (`SQ-041`): `ControlPersist` set makes `ssh` fork the master into
    /// the background after authentication and the process the agent spawned exits - even
    /// under `-N`. Run for real: the child exits 0 with nothing to say, while the socket
    /// it created, and the connection under it, are still there with nobody supervising
    /// them. That is the pid, the stderr and the exit signal all lost at once, which is
    /// why an argv assertion alone would not have been the proof.
    func testK4_withControlPersistTheMasterForksAwayAndThePidStopsBeingTheConnection()
        async throws
    {
        let stub = try fakeSSH(.debian)
        let path = controlPath(stub) + "-persisted"
        let process = try spawnMaster(
            stub, controlPath: path, rewriting: rewriting("ControlPersist", to: "10m"))
        try await waitForSocket(path)

        let detached = await exitOf(process, within: 15)
        let exit = try XCTUnwrap(
            detached, "SQ-041: with ControlPersist set the spawned process does not stay")
        XCTAssertEqual(exit.status, 0)
        XCTAssertNil(exit.signal,
                     "the exit the agent watches says nothing at all about the connection")
        XCTAssertTrue(
            ControlSocket.isSocket(path),
            "SQ-041: the socket - and the connection under it - outlived the pid we spawned")

        // Nothing else can end it, which is the point: unlink the socket by hand so the
        // orphan this scenario just made does not outlive the test.
        ControlSocket.unlink(path)
    }

    // MARK: - K5: the orphan sweep takes only sockets

    /// The sweep as it was before 2026-09-04: every `$TMPDIR` entry whose name starts
    /// with our prefix, unlinked. `sshdrive doctor` reported **six orphaned sockets** on
    /// a clean install with this, and `agent restart` would have deleted them (`SQ-074`).
    /// Kept here, and run, so the row is defended by the damage it prevents.
    private static func nameOnlySweep(in directory: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var swept: [String] = []
        for name in entries where name.hasPrefix(ControlSocket.namePrefix) {
            let path = (directory as NSString).appendingPathComponent(name)
            try? FileManager.default.removeItem(atPath: path)
            swept.append(path)
        }
        return swept.sorted()
    }

    /// A directory holding the package's own temporary databases - two of them, with the
    /// `-wal` and `-shm` sidecars that made the six - and, where `withSocket`, a real
    /// `AF_UNIX` socket and a symlink pointing at it.
    private func makeSharedTemporaryDirectory(withSocket: Bool) throws
        -> (root: String, databases: [String], socket: String?, decoy: String?)
    {
        // Eight hex digits: a real `AF_UNIX` socket is bound **inside** this directory and
        // `sockaddr_un.sun_path` holds 104 bytes, of which macOS's `$TMPDIR` is about fifty
        // (`SQ-085`). A UUID component here put the bind over the limit and the whole row
        // skipped on Darwin, which is the one place the 104-byte limit actually bites.
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sshdrive-k5-\(HostTools.shortID())")
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        scratch.append(root)

        var databases: [String] = []
        for _ in 0 ..< 2 {
            let base = "sshdrive-nested-\(UUID().uuidString).sqlite"
            for suffix in ["", "-wal", "-shm"] {
                let path = (root as NSString).appendingPathComponent(base + suffix)
                XCTAssertTrue(
                    FileManager.default.createFile(
                        atPath: path, contents: Data("not a socket".utf8)))
                databases.append(path)
            }
        }
        XCTAssertEqual(databases.count, 6, "the exact six `doctor` called orphaned sockets")
        guard withSocket else { return (root, databases, nil, nil) }

        let socketPath = (root as NSString).appendingPathComponent("sshdrive-1a2b3c4d")
        try bindUnixSocket(at: socketPath)
        let decoy = (root as NSString).appendingPathComponent("sshdrive-decoy")
        XCTAssertEqual(symlink(socketPath, decoy), 0)
        return (root, databases, socketPath, decoy)
    }

    /// A real `AF_UNIX` socket, because `S_IFSOCK` is the assertion and a stand-in file
    /// would make the test agree with the bug.
    private func bindUnixSocket(at path: String) throws {
        #if canImport(Darwin)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
            // Glibc types SOCK_STREAM as `__socket_type`, not `Int32`.
            let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        try XCTSkipIf(fd < 0, "this box cannot make an AF_UNIX socket (errno \(errno))")
        openFDs.append(fd)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        try XCTSkipIf(
            bytes.count >= MemoryLayout.size(ofValue: address.sun_path),
            "the socket path is over the 104-byte limit on this box")
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.baseAddress?.copyMemory(from: bytes, byteCount: bytes.count)
        }
        #if canImport(Darwin)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        // Spelled through the module, not bare: `bind` is one of the libc names Swift
        // resolves differently on the two platforms (`Darwin` re-exported by Foundation
        // on macOS, `Glibc` here), and the bare spelling does not compile on Darwin.
        // Same rule as `SSHProcess/Platform.swift`'s wrappers.
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                #if canImport(Darwin)
                    return Darwin.bind(
                        fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                    return Glibc.bind(
                        fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        XCTAssertEqual(bound, 0, "bind(\(path)) failed with errno \(errno)")
    }

    /// **K5** (`SQ-074`): `$TMPDIR` is shared and `sshdrive-` is not ours exclusively.
    /// The package's own tests write `sshdrive-nested-<uuid>.sqlite` there, and its `-wal`
    /// and `-shm` sidecars were counted as **six orphaned control sockets** by `sshdrive
    /// doctor`, which reported a healthy install as failing and would have deleted them
    /// (2026-09-04). Every candidate is `lstat`ed for `S_IFSOCK`, so only the socket is a
    /// candidate; the databases survive, the symlink planted at our prefix decides
    /// nothing, and `doctor` calls a clean install clean.
    func testK5_theSweepTakesOnlySocketsAndTheTestDatabasesSurvive() throws {
        let real = try makeSharedTemporaryDirectory(withSocket: true)
        let socketPath = try XCTUnwrap(real.socket)
        let decoy = try XCTUnwrap(real.decoy)

        XCTAssertEqual(ControlSocket.existingSockets(in: real.root), [socketPath],
                       "SQ-074: one candidate out of eight entries with our prefix")
        XCTAssertTrue(ControlSocket.isSocket(socketPath))
        XCTAssertFalse(
            ControlSocket.isSocket(decoy),
            "section 9.1: `lstat`, never `stat` - a symlink at that name is not our socket")
        for database in real.databases { XCTAssertFalse(ControlSocket.isSocket(database)) }

        // The bite, against a directory of its own so the damage is real and contained.
        let bitten = try makeSharedTemporaryDirectory(withSocket: true)
        let takenByName = MasterScenarios.nameOnlySweep(in: bitten.root)
        XCTAssertEqual(takenByName.count, 8,
                       "SQ-074: the name-only sweep takes everything with the prefix")
        for database in bitten.databases {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: database),
                "SQ-074: and this is the regression - it deleted the package's databases")
        }

        // The shipping sweep, on the real directory. `-O exit` and `-O check` are run
        // through `SSHProcess.sshBinaryPath`; pointing it at `/bin/true` keeps this row
        // a pure unit and gives the sweep the answer a socket with no owner gives.
        previousBinaryPath = SSHProcess.sshBinaryPath
        SSHProcess.sshBinaryPath = "/bin/true"
        XCTAssertNil(ControlSocket.masterPID(socket: socketPath, environment: [:]),
                     "nothing answered `-O check`, so there is no owner to kill")
        let swept = ControlSocket.sweepOrphans(environment: [:], in: real.root)
        XCTAssertEqual(swept, [socketPath], "SQ-074: only the socket was ever a candidate")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        for database in real.databases {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: database),
                "SQ-074: the databases are not ours to delete")
        }
        // Read with `destinationOfSymbolicLink` rather than `fileExists`, which follows
        // the link and would now answer for the socket the sweep took.
        XCTAssertEqual(
            try? FileManager.default.destinationOfSymbolicLink(atPath: decoy), socketPath,
            "SQ-074: nor is a symlink somebody else left at our prefix")
    }

    /// **K5** (`SQ-074`): and what `sshdrive doctor` says. A socket a mounted location is
    /// using is not an orphan; a socket no location claims is; and an install with
    /// nothing but the test databases in `$TMPDIR` is **clean**, which is the answer the
    /// name-only version got wrong.
    func testK5_doctorReportsACleanInstallAsClean() throws {
        let holding = try makeSharedTemporaryDirectory(withSocket: true)
        let socketPath = try XCTUnwrap(holding.socket)

        XCTAssertEqual(
            ControlSocket.orphanedSockets(inUse: [socketPath], in: holding.root), [],
            "a mounted location's own socket is not an orphan")
        XCTAssertEqual(
            ControlSocket.orphanedSockets(inUse: [], in: holding.root), [socketPath],
            "and one no location claims is")

        let clean = try makeSharedTemporaryDirectory(withSocket: false)
        XCTAssertEqual(
            ControlSocket.orphanedSockets(inUse: [], in: clean.root), [],
            "SQ-074: six `sshdrive-nested-*.sqlite*` files and a clean bill of health")
        XCTAssertEqual(
            MasterScenarios.nameOnlySweep(in: clean.root).count, 6,
            "SQ-074: the name-only sweep is where the six came from")
    }

    // MARK: - K6: `agent stop` takes the masters

    /// **K6** (`SQ-043`, `SQ-044`, `SQ-075`): two locations, four masters, and
    /// every one of section 6.1's three routes needed to take them all.
    ///
    /// Location A was restarted, so it holds two masters (`SQ-043`): the first owns the
    /// socket but has stopped serving it, and the second found that socket in place,
    /// printed `ControlSocket … already exists, disabling multiplexing` and is running
    /// with **no socket at all**. Location B's agent was killed mid-shutdown: one master
    /// is still serving its socket, and one has had its socket unlinked already
    /// (`SQ-044`), which puts it out of reach of `-O exit` for ever.
    ///
    /// The three routes, and which master each one is the only way to reach:
    ///   1. `-O exit`, through the socket - the healthy master, and what `agent stop`
    ///      does per location before the agent exits;
    ///   2. the pid `-O check` prints, then TERM - the master that still owns a socket it
    ///      no longer serves, which answers the check and ignores the exit;
    ///   3. the argv match on `ControlPath=$TMPDIR/sshdrive-` - the two with no socket,
    ///      which no socket-based sweep can see at all.
    ///
    /// `SQ-075` is the last assertion: a master killed but not yet reaped is a zombie, so
    /// "did I kill it?" is read from the process **state** and not from the pid still
    /// being there, which `pgrep` and `kill(pid, 0)` both are fooled by.
    func testK6_agentStopTakesEveryMasterByAllThreeRoutes() async throws {
        let stub = try fakeSSH(.debian)

        // **A `$TMPDIR` of this scenario's own**, and it has to be. `sweepOrphans` and
        // `killStrayMasters` act on every `sshdrive-*` socket, and on every process whose
        // argv carries `ControlPath=<that directory>/sshdrive-`, in the directory they are
        // given - which is exactly the blast radius `agent stop` needs and exactly the one
        // a test must not have. `swift test` runs the swift-testing suites **concurrently**
        // with XCTest in one process, and suite Q's `add` flow holds live `FakeSSH` masters
        // on control paths under the real `$TMPDIR` with the same prefix: sweeping the
        // shared directory killed them mid-`add`, and Q2/Q3/Q5/Q8/Q9 failed
        // `badMessage`/`serverUnreachable`, a different subset every run (2026-09-08).
        //
        // Everything the three routes assert is unchanged; only what they can reach is.
        // The name is short because a `sockaddr_un` path holds 104 bytes (`SQ-085`).
        let temporaryDirectory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sd-k6-\(HostTools.shortID())")
        try FileManager.default.createDirectory(
            atPath: temporaryDirectory, withIntermediateDirectories: true)
        scratch.append(temporaryDirectory)
        func ownSocketPath() -> String {
            (temporaryDirectory as NSString)
                .appendingPathComponent("\(ControlSocket.namePrefix)\(HostTools.shortID())")
        }

        // Location A, restarted. The first master owns the socket and has stopped
        // serving it; section 6.1: "or one that has stopped serving it".
        let alphaSocket = ownSocketPath()
        let alpha1 = try spawnMaster(
            stub, controlPath: alphaSocket,
            extraEnvironment: ["SSHDRIVE_FAKESSH_MASTER": "wedged"])
        try await waitForSocket(alphaSocket)

        // The second finds it in place and runs without one (SQ-043).
        let alpha2 = try spawnMaster(stub, controlPath: alphaSocket)
        let alpha2Stderr = StderrCollector(fd: alpha2.stderrFD)
        var sentence = ""
        let deadline = Date().addingTimeInterval(15)
        while !sentence.contains("disabling multiplexing"), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            sentence = alpha2Stderr.text
        }
        XCTAssertTrue(
            sentence.contains("already exists, disabling multiplexing"),
            "SQ-043: the second master says so and carries on with no socket")
        XCTAssertTrue(isRunning(alpha2), "SQ-043: and it does carry on - it did not fail")

        // Location B: one healthy master, and one whose socket has already gone.
        let betaSocket = ownSocketPath()
        let beta1 = try spawnMaster(stub, controlPath: betaSocket)
        try await waitForSocket(betaSocket)
        let beta2Socket = ownSocketPath()
        let beta2 = try spawnMaster(stub, controlPath: beta2Socket)
        try await waitForSocket(beta2Socket)
        ControlSocket.unlink(beta2Socket)   // SQ-044: as `SSHMaster.shutdown()` would
        XCTAssertFalse(FileManager.default.fileExists(atPath: beta2Socket))
        XCTAssertTrue(isRunning(beta2), "SQ-044: unlinking the socket does not end the master")

        let environment = self.environment()

        // Route 1: `-O exit`, which is what `agent stop` runs per location.
        let exitRequest = SSHCommandBuilder.control(
            "exit", controlPath: betaSocket, host: "deb")
        let answered = try Spawn.capture(
            executable: exitRequest.executable, argv: exitRequest.argv,
            environment: environment, timeout: 10)
        XCTAssertTrue(String(decoding: answered.stderr, as: UTF8.self).contains("Exit request sent."))
        let beta1Ended = await exitOf(beta1, within: 10)
        let beta1Exit = try XCTUnwrap(
            beta1Ended, "route 1: `-O exit` takes a master that serves its socket")
        XCTAssertEqual(beta1Exit.status, 0)
        XCTAssertNil(beta1Exit.signal, "it left on request, not on a signal")

        // SQ-044: and the same request cannot reach beta2 at all.
        let unreachable = SSHCommandBuilder.control("exit", controlPath: beta2Socket, host: "deb")
        let refused = try Spawn.capture(
            executable: unreachable.executable, argv: unreachable.argv,
            environment: environment, timeout: 10)
        XCTAssertEqual(refused.exit.status, 255)
        XCTAssertTrue(
            String(decoding: refused.stderr, as: UTF8.self).contains("Control socket connect"),
            "SQ-044: with the socket gone there is nothing left to ask")
        XCTAssertTrue(isRunning(beta2))

        // Route 2: the pid `-O check` prints. It is the only route from a socket to a
        // process, and for alpha1 it is the only route there is.
        XCTAssertEqual(
            ControlSocket.masterPID(socket: alphaSocket, environment: environment), alpha1.pid,
            "section 6.1: `Master running (pid=NNNN)` is how a socket names its owner")
        let swept = ControlSocket.sweepOrphans(environment: environment, in: temporaryDirectory)
        XCTAssertTrue(swept.contains(alphaSocket), "the sweep found the socket alpha1 owns")
        XCTAssertFalse(swept.contains(beta2Socket), "which is exactly what it cannot find")
        let alpha1Stopped = await waitUntilStopped(alpha1)
        XCTAssertTrue(
            alpha1Stopped,
            "route 2: the exit request could not take alpha1, so the pid had to")

        // Route 3: the argv match, for the two masters with no socket at all.
        let live = ControlSocket.liveMasterPIDs(in: temporaryDirectory)
        let needle = "ControlPath=\((temporaryDirectory as NSString).appendingPathComponent("sshdrive-"))"
        func identify(_ label: String, _ pid: pid_t) -> String {
            let argv = ControlSocket.commandLine(of: pid)
            return "\(label)=\(pid) name=\(ControlSocket.processName(of: pid) ?? "nothing") "
                + "zombie=\(ControlSocket.isZombie(pid)) "
                + "argv=\(argv == nil ? "unreadable" : (argv!.contains(needle) ? "matches" : "no needle: \(argv!)"))"
        }
        let identity = "matching on \(ControlSocket.masterProcessName), \(live.count) live; "
            + identify("alpha2", alpha2.pid) + "; " + identify("beta2", beta2.pid)
        XCTAssertTrue(live.contains(alpha2.pid),
                      "SQ-043: found by ControlPath= on its command line (\(identity))")
        XCTAssertTrue(live.contains(beta2.pid), "SQ-044: and so is this one (\(identity))")
        XCTAssertFalse(
            live.contains(alpha1.pid),
            "SQ-075: alpha1 was killed a moment ago and is an unreaped zombie, not a master")
        let strays = ControlSocket.killStrayMasters(in: temporaryDirectory)
        XCTAssertTrue(strays.contains(alpha2.pid))
        XCTAssertTrue(strays.contains(beta2.pid))
        let alpha2Stopped = await waitUntilStopped(alpha2)
        let beta2Stopped = await waitUntilStopped(beta2)
        XCTAssertTrue(alpha2Stopped, "route 3: found by its argv and killed by its pid")
        XCTAssertTrue(beta2Stopped)

        // Every master is gone - and this is where `pgrep` would still say four.
        for process in [alpha1, alpha2, beta2] {
            XCTAssertEqual(kill(process.pid, 0), 0,
                           "SQ-075: the pid is still there, because nothing has reaped it")
            XCTAssertTrue(ControlSocket.isZombie(process.pid),
                          "SQ-075: and the process **state** is what says it is gone")
            #if !canImport(Darwin)
                // The same answer read straight out of `/proc`, so the product's reader is
                // corroborated rather than merely agreed with. There is no `/proc` on a Mac
                // and `p_stat` is the whole of the evidence there.
                XCTAssertEqual(processState(of: process.pid), "Z",
                               "SQ-075: `ps -o stat` is the one to read")
            #endif
            XCTAssertFalse(ControlSocket.isLiveSSH(process.pid),
                           "SQ-075: and a zombie is not a live master")
        }
        let secondPass = ControlSocket.killStrayMasters(in: temporaryDirectory)
        for process in [alpha1, alpha2, beta2] {
            XCTAssertFalse(
                secondPass.contains(process.pid),
                "SQ-075: a second pass reports no kill it already made, so the answer is stable")
        }

        // And each of the three left on a **signal** - the TERM the stub catches, or the
        // KILL half a second behind it - which is what says `-O exit` was not what took
        // them: an exit request never signals anything.
        for process in [alpha1, alpha2, beta2] {
            let ended = await exitOf(process, within: 10)
            let exit = try XCTUnwrap(ended, "every master must be gone")
            XCTAssertTrue(
                exit.signal != nil || stub.terminatedPIDs.contains(process.pid),
                "\(process.pid) left on its own, which none of these three could do")
        }
    }
}
