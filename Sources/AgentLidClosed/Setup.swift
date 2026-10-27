import AppKit
import LidCore

/// Start at login, through the LaunchAgent that install.sh adds. Turning it off
/// disables the job for future logins; the running app keeps running.
@MainActor
enum LoginItem {
    private static var label: String { Paths.bundleID }
    private static var domain: String { "gui/\(getuid())" }
    private static var dryRunEnabled = true

    static var isInstalled: Bool {
        Power.dryRun || FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist").path)
    }

    static var isEnabled: Bool {
        if Power.dryRun { return dryRunEnabled }
        let result = Power.run("/bin/launchctl", ["print-disabled", domain])
        guard result.status == 0 else { return true }
        // `"label" => disabled` on current macOS, `=> true` on older versions.
        return !result.output.split(separator: "\n").contains { line in
            line.contains("\"\(label)\"") && (line.contains("disabled") || line.contains("true"))
        }
    }

    /// Returns an error message, or nil.
    static func setEnabled(_ enabled: Bool) -> String? {
        let action = enabled ? "enable" : "disable"
        if Power.dryRun {
            dryRunEnabled = enabled
            Log.write("[dry run] launchctl \(action) \(label)")
            return nil
        }
        let result = Power.run("/bin/launchctl", [action, "\(domain)/\(label)"])
        guard result.status == 0 else { return "Couldn't change Start at Login: \(result.output)" }
        Log.write("Start at login \(enabled ? "on" : "off")")
        return nil
    }
}

/// Adds or removes hooks with the same script install.sh uses, bundled in the app.
@MainActor
enum HookSetup {
    private static let python = "/usr/bin/python3"

    static var hookCommand: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agent-lid-hook")
    }

    /// Returns an error message, or nil.
    static func install(_ tool: AgentProvider, into path: String) async -> String? {
        await run(["install", path, hookCommand.path, tool.rawValue], verb: "add hooks to", path: path)
    }

    static func remove(from path: String) async -> String? {
        await run(["uninstall", path], verb: "remove hooks from", path: path)
    }

    /// A dry run changes only files in a test home, with a test manifest.
    private static func dryRunMayChange(_ path: String) -> Bool {
        let home = Integrations.home.standardizedFileURL.resolvingSymlinksInPath().path
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return Integrations.hasTestHome && Paths.hasTestState && file.hasPrefix(home + "/")
    }

    private static func run(_ arguments: [String], verb: String, path: String) async -> String? {
        guard let script = Bundle.main.url(forResource: "hooks", withExtension: "py") else {
            return "This copy of the app is missing hooks.py; reinstall it with scripts/install.sh"
        }
        guard FileManager.default.isExecutableFile(atPath: python) else {
            return "Python isn't available; install the Command Line Tools with xcode-select --install"
        }
        if Power.dryRun && !dryRunMayChange(path) {
            Log.write("[dry run] hooks.py \(arguments[0]) \(path)")
            return "Dry run: \(Setup.displayPath(path)) wasn't changed. A dry run changes only files under AGENT_LID_HOME, and needs AGENT_LID_STATE_DIR too."
        }
        let executable = python
        let command = ["-I", script.path] + arguments + ["--manifest", Paths.hookManifest.path]
        // Off the main thread, so a slow disk can't hold up the menu or sleep decisions.
        let result = await Task.detached { Power.run(executable, command) }.value
        guard result.status == 0 else {
            // The script's last line explains invalid settings without showing their contents.
            let reason = result.output.split(separator: "\n").last.map(String.init) ?? "exit \(result.status)"
            Log.write("Couldn't \(verb) \(path): \(reason)")
            return "Couldn't \(verb) \(Setup.displayPath(path)): \(reason)"
        }
        Log.write("\(arguments[0] == "install" ? "Added hooks to" : "Removed hooks from") \(path)")
        return nil
    }
}

enum Setup {
    /// `~/.claude/settings.json` instead of the full home path.
    static func displayPath(_ path: String) -> String {
        let home = Integrations.home.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
