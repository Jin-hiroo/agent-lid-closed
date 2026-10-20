// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentLidClosed",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared by the app and the hook: session state, hook rules, sleep decision.
        .target(name: "LidCore"),
        // Menu bar app that turns lid-closed sleep off and on.
        .executableTarget(name: "AgentLidClosed", dependencies: ["LidCore"]),
        // Called by Claude Code and Codex hooks; records each session's activity.
        .executableTarget(name: "agent-lid-hook", dependencies: ["LidCore"]),
    ]
)
