import Foundation

public enum AgentProvider: String, Codable, Sendable {
    case claude
    case codex

    public var name: String { self == .claude ? "Claude" : "Codex" }

    /// Keep Claude's existing keys; Codex IDs live in their own namespace.
    public func sessionKey(_ id: String) -> String {
        self == .claude ? id : "codex:\(id)"
    }

    public static func shortSessionID(_ key: String) -> String {
        let id = key.hasPrefix("codex:") ? String(key.dropFirst(6)) : key
        return String(id.prefix(8))
    }
}
