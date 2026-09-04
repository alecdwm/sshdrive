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
// here. ssh tags a notification with SSH_ASKPASS_PROMPT=none and a permission question
// with "confirm"; a secret carries no tag - and neither does the host-key question, so
// the agent classifies by the text (section 4.2, and the S2 askpass capture).
//
// This program knows nothing and holds nothing. It forwards four things to the agent -
// the token, the prompt, SSH_ASKPASS_PROMPT, and the argv of its parent ssh, which is how
// the agent tells a ProxyJump hop apart from the master whose token it inherited - and
// prints whatever the agent answers. It never reads the keychain, and it never learns
// which location it is serving: an askpass that did either would be a password oracle for
// any local process.
//
// Exit codes, which are what ssh actually reads:
//
//   0 + a line on stdout   the answer
//   0 + an empty line      "skip this identity"; ssh logs "no passphrase given, try next
//                          key" and moves on, and for a notification it is the ack
//   non-zero               no answer: ssh fails the prompt, and with it the connection

let environment = ProcessInfo.processInfo.environment
// The variable name is section 4.2's, and the agent's AskpassEnvironment builds it.
let token = environment["SSHDRIVE_ASKPASS_TOKEN"] ?? ""
let promptKind = environment["SSH_ASKPASS_PROMPT"] ?? ""
let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

Log.askpass.notice(
    "askpass invoked, kind \(promptKind.isEmpty ? "secret" : promptKind, privacy: .public)")

guard !token.isEmpty else {
    // No token means we were not started by an ssh the agent spawned. Answer nothing:
    // "an askpass invocation with no token ... gets no answer" (section 4.2).
    Log.askpass.error("no SSHDRIVE_ASKPASS_TOKEN in the environment; refusing to answer")
    exit(1)
}

// The parent is the ssh that invoked us. Its argv carries the destination and, for a
// ProxyJump hop, that hop's own -p and -W (section 6.1).
let parentArguments = SSHDriveProcessArguments.parentArguments()

let connection = NSXPCConnection(
    machServiceName: SSHDriveIdentifiers.machServiceName, options: [])
connection.remoteObjectInterface = SSHDriveXPCInterface.askpass
connection.resume()

let semaphore = DispatchSemaphore(value: 0)
var answer: String?

let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    Log.askpass.error("cannot reach the agent: \(error, privacy: .public)")
    semaphore.signal()
} as? SSHDriveAskpassProtocol

if let proxy {
    proxy.askpassRequest(
        token: token, promptKind: promptKind, prompt: prompt,
        parentArguments: parentArguments
    ) { value, error in
        if let error {
            Log.askpass.error("the agent refused the prompt: \(error, privacy: .public)")
        } else {
            answer = value
        }
        semaphore.signal()
    }
} else {
    semaphore.signal()
}

// ssh's own authentication deadline is 60 s from spawn (section 4.2); waiting longer here
// would only keep a process alive that the agent has already killed.
if semaphore.wait(timeout: .now() + 55) == .timedOut {
    Log.askpass.error("the agent did not answer within the deadline")
    answer = nil
}
connection.invalidate()

if let answer {
    // An empty answer prints an empty line on purpose: that is the "skip this identity"
    // of section 4.2, and the acknowledgement of a notification.
    print(answer)
    exit(0)
}

exit(1)
