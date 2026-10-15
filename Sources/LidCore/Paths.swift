import Foundation

/// Files shared by the hook and the app.
public enum Paths {
    public static let bundleID = "local.ClaudeLidClosed"

    /// `CLAUDE_LID_STATE_DIR` overrides the location, for tests.
    public static var stateDir: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_LID_STATE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/ClaudeLidClosed", isDirectory: true)
    }

    public static var sessionsDir: URL { stateDir.appendingPathComponent("sessions", isDirectory: true) }

    /// Exists while the app has sleep disabled, so a crashed app can undo it on its next launch.
    public static var holdMarker: URL { stateDir.appendingPathComponent("holding") }

    public static var logFile: URL {
        if ProcessInfo.processInfo.environment["CLAUDE_LID_STATE_DIR"] != nil {
            return stateDir.appendingPathComponent("ClaudeLidClosed.log")
        }
        return home.appendingPathComponent("Library/Logs/ClaudeLidClosed.log")
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}
