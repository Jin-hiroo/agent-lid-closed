import Foundation

/// Reads Claude Code's session transcript (JSONL) to spot an interrupted turn.
/// No hook fires when you press Esc, so this is the only way to see that Claude stopped.
public enum Transcript {
    private static let marker = "[Request interrupted by user"
    private static let tailBytes: UInt64 = 256 * 1024

    /// True if the newest message in the transcript is Claude Code's interrupt marker.
    public static func endsWithInterrupt(path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        let start = size > tailBytes ? size - tailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return false }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() } // cut off mid-line
        for (index, line) in lines.reversed().enumerated() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                // An unreadable newest line means it's still being written; don't guess.
                if index == 0 { return false }
                continue
            }
            if entry["isSidechain"] as? Bool == true || entry["isMeta"] as? Bool == true { continue }
            switch entry["type"] as? String {
            case "assistant":
                return false
            case "user":
                let content = (entry["message"] as? [String: Any])?["content"]
                if let text = content as? String { return text.hasPrefix(marker) }
                let items = content as? [[String: Any]] ?? []
                return items.contains { ($0["text"] as? String)?.hasPrefix(marker) == true }
            default:
                continue
            }
        }
        return false
    }
}
