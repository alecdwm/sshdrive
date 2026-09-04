import Foundation

/// The three variables the agent puts in every `ssh` it spawns (DESIGN.md section 4.2):
///
///     SSH_ASKPASS=<bundle>/Contents/MacOS/sshdrive-askpass
///     SSH_ASKPASS_REQUIRE=force
///     SSHDRIVE_ASKPASS_TOKEN=<one-time token minted for this ssh process>
///
/// `SSH_ASKPASS_REQUIRE=force` is what makes `ssh` use the program with no tty and no
/// `DISPLAY`; without it OpenSSH only reaches for an askpass when it has no terminal
/// *and* `DISPLAY` is set. A `ProxyJump` hop inherits all three from the master, which is
/// how it gets a token the agent never issued it directly (section 4.2, section 6.1).
///
/// This lives in `XPCProtocols` because four things need the same names and must not
/// disagree about them: `Secrets`, which mints the tokens and answers the prompts;
/// `SSHProcess`, which spawns the `ssh` that carries them and strips them off every mux
/// client; the agent, which wires the two together; and `sshdrive-askpass` itself, which
/// reads the token out of its own environment. There used to be a copy in `Secrets` and
/// another in `SSHProcess`; they were merged here on 2026-09-04.
public enum AskpassEnvironment {
    public static let tokenVariable = "SSHDRIVE_ASKPASS_TOKEN"
    public static let askpassVariable = "SSH_ASKPASS"
    public static let requireVariable = "SSH_ASKPASS_REQUIRE"
    /// `ssh` sets this on the askpass it invokes; it must never be inherited *into* one.
    public static let promptVariable = "SSH_ASKPASS_PROMPT"
    public static let requireForce = "force"

    /// The askpass program beside the running agent. The path is taken from the running
    /// bundle rather than hard-coded, so a build in `~/build` and one in `/Applications`
    /// each use their own (section 4.2).
    public static func askpassPath(
        forExecutableAt executable: URL? = Bundle.main.executableURL
    ) -> String? {
        guard let executable else { return nil }
        let candidate = executable.deletingLastPathComponent()
            .appendingPathComponent("sshdrive-askpass")
        return FileManager.default.isExecutableFile(atPath: candidate.path)
            ? candidate.path : nil
    }

    /// The variables to add to a spawned `ssh`'s environment.
    public static func variables(askpassPath: String, token: String) -> [String: String] {
        [
            askpassVariable: askpassPath,
            requireVariable: requireForce,
            tokenVariable: token,
        ]
    }

    /// The agent's own environment plus those three, with `SSH_ASKPASS_PROMPT` and any
    /// inherited token removed.
    public static func environment(
        base: [String: String], askpassPath: String, token: String
    ) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: promptVariable)
        for (key, value) in variables(askpassPath: askpassPath, token: token) {
            environment[key] = value
        }
        return environment
    }

    /// Strips the token and the askpass from an environment: what a mux client gets.
    /// A mux client runs `BatchMode=yes` and can never prompt, and the agent mints it no
    /// token, so leaving the variables on it would only invite a refusal that the exit
    /// classifier would have to read as an authentication failure (section 6.1).
    public static func removingAskpass(from environment: [String: String]) -> [String: String] {
        var out = environment
        out[askpassVariable] = nil
        out[requireVariable] = nil
        out[tokenVariable] = nil
        out[promptVariable] = nil
        return out
    }
}

/// The seam between the process side and the secrets side of the askpass protocol.
///
/// `SSHProcess` spawns the `ssh` that will be prompted and therefore has to mint a token
/// for it, attach its pid once it exists and retire it when it exits; `Secrets`
/// (`AskpassBroker`) is what actually holds the tokens and answers the prompts. Neither
/// module depends on the other: they meet on this protocol, which is also the seam the
/// tests drive through `AskpassHarness` (section 4.2).
public protocol AskpassTokenProviding: AnyObject, Sendable {
    /// One token for one `ssh` about to be spawned. `argv` is the command line the agent
    /// built, which is how a `ProxyJump` hop's own argv is later told apart from it.
    func mintToken(locationID: String, argv: [String]) -> String
    /// The same, for a connection that is not a master: the collect connection of
    /// `sshdrive add` and `sshdrive passwd`, whose token is marked `collect` so a prompt
    /// with no stored answer is relayed to the CLI rather than skipped, and which may mask
    /// stored items so a stale password reaches the terminal (section 4.2). Defaulted, so
    /// a test double only ever has to implement the three methods above.
    func mintCollectToken(
        locationID: String, argv: [String], maskedAccounts: Set<String>
    ) -> String
    /// The pid of the `ssh` the token was issued to, once it has one. Until this is set
    /// the descendant check the broker makes cannot run.
    func attachToken(_ token: String, pid: Int32, argv: [String])
    /// Retire the token when the master exits, which ends every hop with it.
    func retireToken(_ token: String)
}

extension AskpassTokenProviding {
    public func mintCollectToken(
        locationID: String, argv: [String], maskedAccounts: Set<String>
    ) -> String {
        mintToken(locationID: locationID, argv: argv)
    }
}
