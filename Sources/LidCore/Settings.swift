import Foundation

/// Tunables. Override with `defaults write local.AgentLidClosed <key> <value>`.
public struct LidSettings: Sendable {
    /// A "working" session with no hook event for this long is treated as stuck.
    public var workingStale: TimeInterval = 30 * 60
    /// How long background tasks alone keep the Mac awake after Claude's last event.
    public var backgroundStale: TimeInterval = 60 * 60
    /// After Claude stops, how long to wait for Claude Code's own "waiting for your input"
    /// notification (sent ~60 s later) before sleeping, so it still reaches your phone.
    public var notifyTimeout: TimeInterval = 90
    /// How long to wait after that notification (or a permission prompt) before sleeping.
    public var sleepGrace: TimeInterval = 10
    /// On battery at or below this percentage, the Mac is allowed to sleep again.
    public var batteryFloor: Int = 15

    public init() {}

    public static func load(from defaults: UserDefaults) -> LidSettings {
        var settings = LidSettings()
        // double(forKey:) also parses strings, as set by `defaults write -string` or `-key value` arguments.
        // Values are clamped, so a stray `defaults write` can't crash the app.
        func value(_ key: String) -> Double? {
            guard defaults.object(forKey: key) != nil else { return nil }
            let value = defaults.double(forKey: key)
            return value.isFinite ? min(max(0, value), 1_000_000) : nil
        }
        if let v = value("workingStaleMinutes") { settings.workingStale = v * 60 }
        if let v = value("backgroundStaleMinutes") { settings.backgroundStale = v * 60 }
        if let v = value("notifyTimeoutSeconds") { settings.notifyTimeout = v }
        if let v = value("sleepGraceSeconds") { settings.sleepGrace = v }
        if let v = value("batteryFloorPercent") { settings.batteryFloor = Int(min(v, 100)) }
        return settings
    }
}
