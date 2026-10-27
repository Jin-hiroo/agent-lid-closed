import Foundation

/// Files shared by the hook and the app.
public enum Paths {
    public static let bundleID = "local.AgentLidClosed"
    public static let legacyBundleID = "local.ClaudeLidClosed"

    /// Override the location for tests. Accept the old environment variable as well.
    public static var stateDir: URL {
        if let dir = stateOverride {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/AgentLidClosed", isDirectory: true)
    }

    public static var sessionsDir: URL { stateDir.appendingPathComponent("sessions", isDirectory: true) }

    /// Every settings file that has the hooks, written by `scripts/hooks.py`.
    public static var hookManifest: URL { stateDir.appendingPathComponent("hook-targets.json") }

    /// Exists while the app has sleep disabled, so a crashed app can undo it on its next launch.
    public static var holdMarker: URL { stateDir.appendingPathComponent("holding") }

    /// Exists while the app has the display dimmed; holds the brightness to put back.
    public static var dimMarker: URL { stateDir.appendingPathComponent("dimmed-brightness") }

    public static var logFile: URL {
        if stateOverride != nil {
            return stateDir.appendingPathComponent("AgentLidClosed.log")
        }
        return home.appendingPathComponent("Library/Logs/AgentLidClosed.log")
    }

    /// The state folder is a test folder, set with AGENT_LID_STATE_DIR.
    public static var hasTestState: Bool { stateOverride != nil }

    private static var stateOverride: String? {
        let env = ProcessInfo.processInfo.environment
        return [env["AGENT_LID_STATE_DIR"], env["CLAUDE_LID_STATE_DIR"]].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Copy only app preferences, without overwriting any settings under the new name.
    public static func migratePreferences(to defaults: UserDefaults) {
        guard stateOverride == nil,
              !defaults.bool(forKey: "legacyPreferencesMigrated"),
              let legacy = UserDefaults.standard.persistentDomain(forName: legacyBundleID) else { return }
        for key in ["autoEnabled", "dimDisplay", "workingStaleMinutes", "backgroundStaleMinutes",
                    "notifyTimeoutSeconds", "sleepGraceSeconds", "batteryFloorPercent"] {
            if defaults.object(forKey: key) == nil, let value = legacy[key] {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "legacyPreferencesMigrated")
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}
