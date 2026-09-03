import Foundation
import XPCProtocols
import Logging

// sshdrive-askpass: the program ssh calls for every prompt (DESIGN.md section 4.2).
//
// The agent runs ssh with no tty and with
//
//     SSH_ASKPASS=<bundle>/Contents/MacOS/sshdrive-askpass
//     SSH_ASKPASS_REQUIRE=force
//     SSHDRIVE_ASKPASS_TOKEN=<one-time token minted by the agent for this ssh process>
//
// so every prompt, including host-key confirmations and user-presence notices, arrives
// here. ssh tags each with SSH_ASKPASS_PROMPT: "confirm" for yes/no questions, "none" for
// notifications, unset for secrets. This program reads nothing itself: it forwards the
// prompt and the token to the agent and prints whatever the agent answers.
//
// TODO milestone 2 (Transport): the agent side of this is a stub, so every call is
// refused. The token protocol shape, the three prompt kinds and the exit codes are here
// now because the target, its embedded Info.plist and its signing identifier have to
// exist from milestone 1 for spike S1(d).

let environment = ProcessInfo.processInfo.environment
let token = environment["SSHDRIVE_ASKPASS_TOKEN"] ?? ""
let promptKind = environment["SSH_ASKPASS_PROMPT"] ?? ""
let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

Log.askpass.notice(
    "askpass invoked, kind \(promptKind.isEmpty ? "secret" : promptKind, privacy: .public)")

guard !token.isEmpty else {
    // No token means we were not started by the agent. Answer nothing at all: ssh treats
    // an empty answer as a skip, which is the safe outcome (section 4.2).
    Log.askpass.error("no SSHDRIVE_ASKPASS_TOKEN in the environment; refusing to answer")
    exit(1)
}

let connection = NSXPCConnection(
    machServiceName: SSHDriveIdentifiers.machServiceName, options: [])
connection.remoteObjectInterface = SSHDriveXPCInterface.agent
connection.resume()

let semaphore = DispatchSemaphore(value: 0)
var answer: String?
var failed = false

let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    Log.askpass.error("cannot reach the agent: \(error, privacy: .public)")
    failed = true
    semaphore.signal()
} as? SSHDriveAgentProtocol

if let proxy {
    proxy.askpassAnswer(token: token, promptKind: promptKind, prompt: prompt) { value, error in
        if let error {
            Log.askpass.error("the agent refused the prompt: \(error, privacy: .public)")
            failed = true
        }
        answer = value
        semaphore.signal()
    }
} else {
    failed = true
    semaphore.signal()
}

// ssh's own authentication deadline is 60 s from spawn (section 4.2); waiting longer here
// would only keep a process alive that ssh has already given up on.
if semaphore.wait(timeout: .now() + 55) == .timedOut { failed = true }
connection.invalidate()

if let answer {
    // A "confirm" prompt wants "yes" or "no"; a "none" notification wants nothing; a
    // secret wants the secret. In every case the agent decided, and this prints it.
    print(answer)
    exit(0)
}

exit(failed ? 1 : 0)
