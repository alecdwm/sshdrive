import Testing

/// Every agent-side scenario, in one serialized tree.
///
/// `Config.GroupContainer`'s locator is process-wide - it is the app group container, and
/// a process has one - so two harnesses cannot be up at the same time. `.serialized` on
/// the outer suite is recursive, so it covers the nested suites as well, and it is the
/// only thing here: the scenarios themselves take no real time, and the whole tree runs in
/// well under a second.
@Suite(.serialized)
struct AgentScenarios {}
