import Foundation

/// Which agent a command is being run against.
///
/// The XPC command layer (`ControlCommands`, `LocationCommands`, `TransportDebug`) is
/// reached from an object made per connection and has nothing of its own to hold, so it
/// reads the agent out of here. In a running agent that is always `DomainManager.shared`,
/// which `AgentRuntimeBootstrap.install` set; a scenario binds its own for the duration of
/// one call, which is what lets two agents exist in one test process.
///
/// A task local rather than a parameter because the value has to reach forty-odd private
/// helpers and every `Task` they start, and because the default has to be read *late*: the
/// bootstrap replaces `DomainManager.shared` after this type is first touched.
public enum AgentCommandContext {
    @TaskLocal public static var override: DomainManager?

    public static var manager: DomainManager { override ?? DomainManager.shared }

    /// Runs `body` against one agent. Everything the commands reach - including the tasks
    /// they spawn - sees it.
    public static func with<T>(
        _ manager: DomainManager, _ body: () async throws -> T
    ) async rethrows -> T {
        try await $override.withValue(manager) { try await body() }
    }
}
