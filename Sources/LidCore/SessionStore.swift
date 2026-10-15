import Foundation

/// What the main Claude agent of a session is doing, as last reported by a hook.
public enum AgentState: String, Codable, Sendable {
    /// Generating a reply or running tools.
    case working
    /// Waiting for you: the turn finished, or Claude asked a question or for permission.
    case waiting
    /// The turn ended, but background tasks (shells, subagents…) are still running.
    case background
}

/// One Claude Code session, stored as `sessions/<session id>.json`.
public struct SessionRecord: Codable, Sendable, Equatable {
    public var sessionID: String
    public var state: AgentState
    /// Why Claude is in `state`, shown in the menu ("finished", "question", …).
    public var reason: String
    /// Claude Code has already raised its own "needs your input" notification for this wait.
    public var notified: Bool
    public var stateSince: Double
    public var updatedAt: Double
    /// The Claude Code process, so the app can drop sessions whose process is gone. 0 if unknown.
    public var pid: Int32
    public var pidStart: Double
    public var cwd: String?
    public var transcriptPath: String?
}

/// Session files in one directory. Running subagents are empty marker files named
/// `<session id>.agent.<agent id>`, whose modification time is their last activity.
public struct SessionStore: Sendable {
    public let dir: URL

    public init(dir: URL = Paths.sessionsDir) {
        self.dir = dir
    }

    public struct Contents: Sendable {
        public var records: [SessionRecord] = []
        /// Last-activity times of running subagents, keyed by `SessionStore.fileKey(sessionID)`.
        public var agentActivity: [String: [Double]] = [:]
    }

    private static let agentSeparator = ".agent."
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// `id` reduced to characters that are safe in a file name.
    public static func fileKey(_ id: String) -> String {
        String(id.map { allowed.contains($0) ? $0 : "_" }.prefix(128))
    }

    private func recordURL(_ sessionID: String) -> URL {
        dir.appendingPathComponent(Self.fileKey(sessionID) + ".json")
    }

    private func agentURL(_ sessionID: String, _ agentID: String) -> URL {
        dir.appendingPathComponent(Self.fileKey(sessionID) + Self.agentSeparator + Self.fileKey(agentID))
    }

    public func load(_ sessionID: String) -> SessionRecord? {
        guard let data = try? Data(contentsOf: recordURL(sessionID)) else { return nil }
        return try? JSONDecoder().decode(SessionRecord.self, from: data)
    }

    /// Writes atomically (temp file + rename), so readers never see a partial record.
    public func save(_ record: SessionRecord) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        let temp = dir.appendingPathComponent(".\(Self.fileKey(record.sessionID)).\(getpid()).tmp")
        try data.write(to: temp)
        guard rename(temp.path, recordURL(record.sessionID).path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Removes the session record and its subagent markers.
    public func remove(_ sessionID: String) {
        let key = Self.fileKey(sessionID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name == key + ".json" || name.hasPrefix(key + Self.agentSeparator) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    public func touchAgent(_ sessionID: String, _ agentID: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: agentURL(sessionID, agentID).path, contents: nil)
    }

    public func removeAgent(_ sessionID: String, _ agentID: String) {
        try? FileManager.default.removeItem(at: agentURL(sessionID, agentID))
    }

    public func loadAll() -> Contents {
        var contents = Contents()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let decoder = JSONDecoder()
        for name in names where !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            if name.hasSuffix(".json") {
                if let data = try? Data(contentsOf: url), let record = try? decoder.decode(SessionRecord.self, from: data) {
                    contents.records.append(record)
                }
            } else if let separator = name.range(of: Self.agentSeparator) {
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                contents.agentActivity[String(name[..<separator.lowerBound]), default: []]
                    .append(modified?.timeIntervalSince1970 ?? 0)
            }
        }
        return contents
    }

    /// Serializes read-modify-write between hooks that run at the same time (parallel tool calls).
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return try body() }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        flock(fd, LOCK_EX)
        return try body()
    }
}
