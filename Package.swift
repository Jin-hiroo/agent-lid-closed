// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeLidClosed",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared by the app and the hook: session state, hook rules, sleep decision.
        .target(name: "LidCore"),
        // Menu bar app that turns lid-closed sleep off and on.
        .executableTarget(name: "ClaudeLidClosed", dependencies: ["LidCore"]),
        // Called by Claude Code hooks; records what each session is doing.
        .executableTarget(name: "claude-lid-hook", dependencies: ["LidCore"]),
    ]
)
