import Foundation
import Secrets
import XPCProtocols

#if canImport(AgentRuntime)
    import AgentRuntime
#endif

/// The terminal the collect connection of DESIGN.md section 4.2 relays its prompts to.
///
/// "The CLI shows the prompt on the terminal, reads the answer (hidden for secrets,
/// visible for the host-key question), and returns it." This is that CLI: every note is
/// recorded in order, and every prompt is answered from a script the scenario wrote, so a
/// test can assert *what the user was shown* as well as what was typed.
///
/// A prompt with no scripted answer is a **hard stop**, not an empty answer: an empty
/// answer is section 4.2's deliberate refusal of one prompt ("press Enter to skip"), and a
/// double that returned it for a prompt nobody scripted would silently turn a missing
/// script into that refusal.
public final class ScriptedTerminal: TerminalRelaying, @unchecked Sendable {

    /// One prompt as the user saw it.
    public struct Shown: Sendable, Equatable {
        /// `passphrase`, `password`, `hostkey`, `confirm` or `notice`, as
        /// `CollectConnection` labels it.
        public var kind: String
        public var prompt: String
        public var detail: String
        /// Read hidden. False for the host-key question, which the user must be able to
        /// read back against the fingerprint on the screen (section 4.3).
        public var secret: Bool
        public var answered: String?
    }

    /// One scripted answer: the first entry whose `kind` matches (when it names one) and
    /// whose `match` is a substring of the prompt text, and which has not been used up.
    public struct Answer: Sendable {
        public var kind: String?
        public var match: String
        public var answer: String
        /// How many times this entry may answer. A second location on the same host must
        /// prompt for *nothing* (section 4.2), and an entry that answered for ever would
        /// hide the day it starts prompting again.
        public var uses: Int

        public init(kind: String? = nil, match: String, answer: String, uses: Int = 1) {
            self.kind = kind
            self.match = match
            self.answer = answer
            self.uses = uses
        }
    }

    private let lock = NSLock()
    private var script: [Answer]
    private var _notes: [String] = []
    private var _shown: [Shown] = []
    private var _unscripted: [String] = []

    public init(_ script: [Answer] = []) {
        self.script = script
    }

    /// Everything `add` printed, in the order it printed it.
    public var notes: [String] { lock.withLock { _notes } }
    /// Every prompt put to the user, in order.
    public var prompts: [Shown] { lock.withLock { _shown } }
    /// Prompts the script had no answer for. A scenario asserts this is empty unless it
    /// is *about* a prompt the user was never meant to see.
    public var unscripted: [String] { lock.withLock { _unscripted } }

    public func note(_ text: String) {
        lock.withLock { _notes.append(text) }
    }

    public func prompt(kind: String, prompt text: String, detail: String, secret: Bool)
        -> String?
    {
        lock.lock()
        var answer: String?
        for index in script.indices where script[index].uses > 0 {
            if let wanted = script[index].kind, wanted != kind { continue }
            guard text.contains(script[index].match) else { continue }
            script[index].uses -= 1
            answer = script[index].answer
            break
        }
        if answer == nil { _unscripted.append(text) }
        _shown.append(
            Shown(kind: kind, prompt: text, detail: detail, secret: secret, answered: answer))
        lock.unlock()
        return answer
    }
}

/// The `sshdrive-askpass` program, as a scenario can run it.
///
/// The shipping one "knows nothing: it opens an XPC connection to the agent and sends the
/// token, the prompt text, `SSH_ASKPASS_PROMPT`, and the argv of its parent `ssh` process
/// (read with `sysctl KERN_PROCARGS2`), then prints the agent's reply" (section 4.2). This
/// is the same program with a file mailbox in place of the XPC connection: a small `sh`
/// script `ssh` really invokes, and a poller in this process that hands each request to
/// the **real** `AskpassBroker` and writes the reply back. Everything section 4.2 makes
/// decisions about - the token, the retired token, the pid ancestry, the classification,
/// the keychain lookup, the relay to the terminal - is the shipping code path.
///
/// Two honest differences from the Mac, both stated rather than hidden:
///
/// - the parent argv is read from `/proc/<ppid>/cmdline` rather than
///   `sysctl KERN_PROCARGS2`, which is the same question asked of the other kernel
///   (`Secrets.SysctlProcessAncestry` already branches this way for the pid check);
/// - `ServerModel.FakeSSH` is a shell **script**, so its `/proc` command line names the
///   interpreter first. The leading words are dropped up to the `ssh` binary path, which
///   a real `ssh` - a binary - would not need.
public final class AskpassBridge: @unchecked Sendable {

    /// One invocation, as the broker saw it.
    public struct Record: Sendable {
        public var token: String
        public var promptText: String
        /// `SSH_ASKPASS_PROMPT`, or "" where `ssh` set none - which is the host-key
        /// question's shape (`SQ-047`).
        public var hint: String
        /// The argv of the asking `ssh`, which is how a `ProxyJump` hop is told apart
        /// from the master whose token it inherited (`SQ-063`).
        public var parentArguments: [String]
        public var callerPID: Int32
        public var reply: AskpassReply
        /// Whether the askpass really was a descendant of the `ssh` the token was issued
        /// to, asked **while both were alive**. The broker asks the same question of the
        /// same kernel and refuses when the answer is no; a scenario cannot ask it
        /// afterwards, because by then the askpass has exited.
        public var callerWasADescendant: Bool
        /// The live token as the broker described it at the moment it answered. It is
        /// captured here because `add` forgets the token when the connection ends, and
        /// `K10`'s deadline is only observable while it exists.
        public var session: AskpassSessionInfo?
    }

    public let directory: URL
    /// What goes in `SSH_ASKPASS`.
    public let executablePath: String

    private let sshBinaryPath: String
    private let lock = NSLock()
    private var broker: AskpassBroker?
    private var _records: [Record] = []
    private var stopped = false
    private var thread: Thread?

    /// The mailbox and the program, before there is a broker to answer with: the broker
    /// lives on `AgentSecrets`, which is constructed with this program's path, so the two
    /// cannot both be first.
    public init(sshBinaryPath: String) throws {
        self.sshBinaryPath = sshBinaryPath
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-askpass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executablePath = directory.appendingPathComponent("sshdrive-askpass").path
        try AskpassBridge.script(mailbox: directory.path)
            .write(toFile: executablePath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executablePath)
    }

    /// Starts answering, from this broker. Until this is called an invocation waits, which
    /// is the right shape: `ssh` is blocked on the reply either way.
    public func start(broker: AskpassBroker) {
        lock.lock()
        self.broker = broker
        lock.unlock()
        let thread = Thread { [weak self] in self?.serve() }
        thread.name = "sshdrive-askpass-bridge"
        thread.start()
        self.thread = thread
    }

    deinit { shutdown() }

    /// Stops the poller and removes the mailbox. Called from `deinit` and from a
    /// scenario's teardown, so nothing is left running between tests.
    public func shutdown() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    public var records: [Record] { lock.withLock { _records } }

    /// Every prompt text put to the broker, in order.
    public var prompts: [String] { records.map(\.promptText) }

    // MARK: - The poller

    private func serve() {
        while true {
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { return }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))
                ?? []
            for name in names.sorted() where name.hasSuffix(".req") {
                answer(requestNamed: name)
            }
            usleep(2000)
        }
    }

    private func answer(requestNamed name: String) {
        let request = directory.appendingPathComponent(name)
        guard let text = try? String(contentsOf: request, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: request)

        var fields: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            fields[String(line[line.startIndex ..< tab])] =
                String(line[line.index(after: tab)...])
        }
        lock.lock()
        let broker = self.broker
        lock.unlock()
        guard let broker else { return }

        let token = fields["token"] ?? ""
        let hint = fields["hint"] ?? ""
        let prompt = (fields["prompt"] ?? "").replacingOccurrences(of: "\u{2}", with: "\n")
        let callerPID = Int32(fields["pid"] ?? "") ?? 0
        let parent = AskpassBridge.sshArguments(
            in: (fields["argv"] ?? "").components(separatedBy: "\u{1}"),
            sshBinaryPath: sshBinaryPath)

        let session = broker.info(token: token)
        let descendant = session?.sshPID.map {
            SysctlProcessAncestry().isDescendant(callerPID, of: $0)
        } ?? false
        let reply = broker.answer(
            token: token, promptKind: hint, prompt: prompt,
            parentArguments: parent, callerPID: callerPID)

        lock.lock()
        _records.append(
            Record(
                token: token, promptText: prompt, hint: hint, parentArguments: parent,
                callerPID: callerPID, reply: reply, callerWasADescendant: descendant,
                session: session))
        lock.unlock()

        var body: String
        switch reply {
        case .answer(let value): body = "ok\n" + value
        case .empty: body = "ok\n"
        case .refuse: body = "no\n"
        }
        let base = String(name.dropLast(".req".count))
        let temporary = directory.appendingPathComponent(base + ".rep.tmp")
        try? body.write(to: temporary, atomically: false, encoding: .utf8)
        try? FileManager.default.moveItem(
            at: temporary, to: directory.appendingPathComponent(base + ".rep"))
    }

    /// The asking `ssh`'s argv, from a `/proc` command line that may name the script
    /// interpreter first. Everything before the `ssh` binary is dropped; a command line
    /// that does not name it at all is taken as it is.
    static func sshArguments(in cmdline: [String], sshBinaryPath: String) -> [String] {
        let words = cmdline.filter { !$0.isEmpty }
        guard let start = words.firstIndex(of: sshBinaryPath) else { return words }
        return Array(words[start...])
    }

    // MARK: - The program

    /// A POSIX `sh` script, for the same reason `FakeSSH` is one: `ssh` invokes it by
    /// absolute path exactly as it invokes `sshdrive-askpass`, it needs no build step, and
    /// every line is one a reader can check.
    static func script(mailbox: String) -> String {
        let quoted = "'" + mailbox.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
            #!/bin/sh
            # AgentRuntimeTestSupport.AskpassBridge - `sshdrive-askpass` with a file
            # mailbox where the XPC connection is (DESIGN.md section 4.2). It holds
            # nothing: the token, the prompt, the hint and the parent argv go to the
            # agent, and whatever the agent says is what is printed.
            D=\(quoted)
            REQ=$(mktemp "$D/askXXXXXX")

            # `ssh` sets SSH_ASKPASS_PROMPT only for its own permission questions and its
            # notifications; a secret - and the host-key question (SQ-047) - arrives with
            # it unset, which is the empty string here.
            {
              printf 'token\\t%s\\n' "$SSHDRIVE_ASKPASS_TOKEN"
              printf 'hint\\t%s\\n' "$SSH_ASKPASS_PROMPT"
              printf 'pid\\t%s\\n' "$$"
              # The asking `ssh`'s own argv (`SQ-063`). `ServerModel.FakeSSH` hands it
              # over in a file, because macOS has no `/proc` and no shell route to
              # `sysctl KERN_PROCARGS2`; `/proc/<ppid>/cmdline` is the fallback, and the
              # two agree on this box. The *product* asks the kernel either way -
              # `Secrets.ProcessAncestry` is branched - so the source of these bytes is
              # harness plumbing and the classification above them is the shipping code.
              if [ -n "$SSHDRIVE_FAKESSH_ARGV" ] && [ -f "$SSHDRIVE_FAKESSH_ARGV" ]; then
                __argv=$(cat "$SSHDRIVE_FAKESSH_ARGV")
              else
                __argv=$(tr '\\0' '\\001' < /proc/$PPID/cmdline 2>/dev/null)
              fi
              printf 'argv\\t%s\\n' "$__argv"
              # The host-key question is multi-line; it travels on one line and is put
              # back by the reader.
              printf 'prompt\\t%s\\n' "$(printf '%s' "$1" | tr '\\n' '\\002')"
            } > "$REQ.tmp"
            mv "$REQ.tmp" "$REQ.req"
            rm -f "$REQ"

            # Bounded: nothing here may outlive the authentication deadline the agent is
            # already holding over the ssh that is waiting on this reply (section 4.2).
            __i=0
            while [ "$__i" -lt 3000 ]; do
              if [ -f "$REQ.rep" ]; then
                if [ "$(head -n 1 "$REQ.rep")" = ok ]; then
                  tail -n +2 "$REQ.rep"
                  rm -f "$REQ.rep"
                  exit 0
                fi
                # Print nothing and exit non-zero: `ssh` fails the prompt, and with it the
                # connection. Section 4.2's refusals.
                rm -f "$REQ.rep"
                exit 1
              fi
              __i=$((__i + 1))
              sleep 0.02
            done
            exit 1
            """
    }
}
