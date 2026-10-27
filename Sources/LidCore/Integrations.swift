import Foundation

/// What is set up for each tool, for the Settings window. Reads files only.
public enum Integrations {
    /// A settings file that does or could hold this app's hooks.
    public struct HookFile: Sendable, Equatable, Identifiable {
        public var tool: AgentProvider
        public var path: String
        public var hasHooks: Bool
        /// The tool's own default location, listed even without hooks.
        public var isDefault: Bool
        public var id: String { path }
    }

    private static let marks = ["agent-lid-hook", "claude-lid-hook"]

    /// Tests point this at a temporary home.
    public static var home: URL {
        if let path = ProcessInfo.processInfo.environment["AGENT_LID_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `home` is a test folder set with AGENT_LID_HOME.
    public static var hasTestHome: Bool {
        ProcessInfo.processInfo.environment["AGENT_LID_HOME"]?.isEmpty == false
    }

    public static func defaultHookFile(_ tool: AgentProvider, home: URL = home) -> String {
        tool == .claude ? home.appendingPathComponent(".claude/settings.json").path
            : home.appendingPathComponent(".codex/hooks.json").path
    }

    /// The default file for each tool, then every other file the manifest records.
    public static func hookFiles(home: URL = home, manifest: URL = Paths.hookManifest) -> [HookFile] {
        let recorded = manifestPaths(manifest)
        var files: [HookFile] = []
        for tool in [AgentProvider.claude, .codex] {
            let defaultPath = defaultHookFile(tool, home: home)
            var paths = [defaultPath]
            for path in recorded[tool] ?? [] where !paths.contains(path) { paths.append(path) }
            for path in paths {
                files.append(HookFile(tool: tool, path: path, hasHooks: hasHooks(atPath: path),
                                      isDefault: path == defaultPath))
            }
        }
        return files
    }

    public static func hasHooks(atPath path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let events = settings["hooks"] as? [String: Any] else { return false }
        return events.values.contains { groups in
            ((groups as? [Any]) ?? []).contains { group in
                (((group as? [String: Any])?["hooks"] as? [Any]) ?? []).contains { handler in
                    let command = (handler as? [String: Any])?["command"] as? String ?? ""
                    return marks.contains { command.contains($0) }
                }
            }
        }
    }

    /// The tool's folder or command exists. Apps started by launchd don't see the
    /// login shell's PATH, so the usual install locations are checked.
    public static func isInstalled(_ tool: AgentProvider, home: URL = home,
                                   systemFolders: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) -> Bool {
        let name = tool == .claude ? "claude" : "codex"
        let folder = home.appendingPathComponent(tool == .claude ? ".claude" : ".codex").path
        let commands = [home.appendingPathComponent(".local/bin/\(name)").path,
                        home.appendingPathComponent(".claude/local/\(name)").path]
            + systemFolders.map { "\($0)/\(name)" }
        var isFolder: ObjCBool = false
        return (FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue)
            || commands.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func manifestPaths(_ manifest: URL) -> [AgentProvider: [String]] {
        guard let data = try? Data(contentsOf: manifest),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var result: [AgentProvider: [String]] = [:]
        for tool in [AgentProvider.claude, .codex] {
            result[tool] = (value[tool.rawValue] as? [Any])?.compactMap { $0 as? String } ?? []
        }
        return result
    }
}
