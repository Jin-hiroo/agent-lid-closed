import Foundation

/// Keeping the Mac awake by hand, either until turned off or for a set time.
public enum ManualAwake {
    /// UserDefaults key: end time in seconds since 1970, or `indefinite`. Absent or 0 means off.
    public static let defaultsKey = "manualAwakeUntil"
    public static let indefinite: Double = -1
    /// Longest timer accepted.
    public static let maximumDuration: TimeInterval = 7 * 24 * 3600

    /// Parses a typed duration: `90` (minutes), `1:30`, `2h`, `45m`, `1h30m`, `1.5h`, `2 hours 10 min`.
    /// Returns nil for anything else, for zero, or for more than `maximumDuration`.
    public static func parseDuration(_ text: String) -> TimeInterval? {
        let input = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        var seconds: Double

        if let minutes = Double(input) {
            seconds = minutes * 60
        } else if input.contains(":") {
            let parts = input.split(separator: ":", omittingEmptySubsequences: false)
            // Double, so a huge hour count is rejected below instead of overflowing.
            guard parts.count == 2, parts[0].allSatisfy(\.isASCII), let h = Double(parts[0]), h >= 0,
                  h.rounded() == h, let m = Int(parts[1]), parts[1].count == 2, (0..<60).contains(m) else { return nil }
            seconds = h * 3600 + Double(m * 60)
        } else {
            seconds = 0
            var number = ""
            var unit = ""
            var sawUnit = false
            func flush() -> Bool {
                guard !number.isEmpty || !unit.isEmpty else { return true }
                guard let value = Double(number) else { return false }
                switch unit {
                case "h", "hr", "hrs", "hour", "hours": seconds += value * 3600
                case "m", "min", "mins", "minute", "minutes": seconds += value * 60
                case "s", "sec", "secs", "second", "seconds": seconds += value
                default: return false
                }
                sawUnit = true
                number = ""
                unit = ""
                return true
            }
            for character in input {
                if character.isNumber || character == "." {
                    if !unit.isEmpty, !flush() { return nil }
                    number.append(character)
                } else if character.isLetter {
                    guard !number.isEmpty else { return nil }
                    unit.append(character)
                } else if character == " " {
                    continue
                } else {
                    return nil
                }
            }
            guard flush(), sawUnit else { return nil }
        }
        guard seconds.isFinite, seconds >= 1, seconds <= maximumDuration else { return nil }
        return seconds.rounded()
    }

    /// "1 h 30 min", "45 min", "20 s".
    public static func describe(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.up)))
        let days = total / 86400, hours = total % 86400 / 3600, minutes = total % 3600 / 60
        if total < 60 { return "\(total) s" }
        var parts: [String] = []
        if days > 0 { parts.append("\(days) d") }
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 || parts.isEmpty { parts.append("\(minutes) min") }
        return parts.joined(separator: " ")
    }
}
