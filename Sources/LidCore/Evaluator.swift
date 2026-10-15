import Foundation

public struct SessionSnapshot: Identifiable, Sendable, Equatable {
    public enum Activity: Sendable, Equatable {
        case working
        case subagents(Int)
        case background
        case waiting(reason: String)
        case interrupted
        case stale
    }

    public let id: String
    public let project: String
    public let activity: Activity
    /// When the session entered its current activity.
    public let since: Date
    public let keepsAwake: Bool
    /// When this session no longer needs the Mac awake (seconds since 1970). Ignored if `keepsAwake`.
    public let sleepAllowedAt: Double

    public var label: String {
        switch activity {
        case .working: "working"
        case .subagents(let count): count == 1 ? "1 subagent running" : "\(count) subagents running"
        case .background: "background tasks running"
        case .waiting(let reason): "waiting for you (\(reason))"
        case .interrupted: "interrupted"
        case .stale: "no activity, ignored"
        }
    }
}

public struct Evaluation: Sendable, Equatable {
    public var sessions: [SessionSnapshot] = []
    /// Sessions whose Claude Code process has exited.
    public var deadSessionIDs: [String] = []
    /// Subagent markers left without a session record.
    public var orphanSessionKeys: [String] = []
    public var keepAwake = false
    /// When the Mac may sleep, if nothing keeps it awake (seconds since 1970).
    public var sleepAllowedAt: Double = 0

    public init() {}
}

/// Decides, from the stored session states, whether Claude needs the Mac awake.
public enum Evaluator {
    /// A "working" session this quiet gets its transcript checked for an Esc interrupt.
    static let interruptCheckDelay: TimeInterval = 20
    /// Subagent markers without a session record are deleted after this long.
    static let orphanGrace: TimeInterval = 60

    public static func evaluate(_ contents: SessionStore.Contents, now: Double, settings: LidSettings,
                                isAlive: (Int32, Double) -> Bool,
                                isInterrupted: (String) -> Bool) -> Evaluation {
        var result = Evaluation()
        var knownKeys = Set<String>()
        for record in contents.records {
            let key = SessionStore.fileKey(record.sessionID)
            knownKeys.insert(key)
            if record.pid > 0 && !isAlive(record.pid, record.pidStart) {
                result.deadSessionIDs.append(record.sessionID)
                continue
            }
            let interrupted = record.state == .working
                && now - record.updatedAt >= interruptCheckDelay
                && record.transcriptPath.map(isInterrupted) == true
            result.sessions.append(snapshot(of: record, agentActivity: contents.agentActivity[key] ?? [],
                                            interrupted: interrupted, now: now, settings: settings))
        }
        for (key, times) in contents.agentActivity where !knownKeys.contains(key) {
            if now - (times.max() ?? 0) > orphanGrace { result.orphanSessionKeys.append(key) }
        }
        result.sessions.sort { ($0.keepsAwake ? 0 : 1, -$0.since.timeIntervalSince1970) < ($1.keepsAwake ? 0 : 1, -$1.since.timeIntervalSince1970) }
        result.keepAwake = result.sessions.contains { $0.keepsAwake }
        result.sleepAllowedAt = result.sessions.filter { !$0.keepsAwake }.map(\.sleepAllowedAt).max() ?? now
        return result
    }

    static func snapshot(of record: SessionRecord, agentActivity: [Double], interrupted: Bool,
                         now: Double, settings: LidSettings) -> SessionSnapshot {
        var activity: SessionSnapshot.Activity
        var keepsAwake = false
        var sleepAllowedAt = now
        var since = record.stateSince

        switch record.state {
        case .working where interrupted:
            activity = .interrupted
            sleepAllowedAt = record.updatedAt + settings.sleepGrace
        case .working where now - record.updatedAt > settings.workingStale:
            activity = .stale
            since = record.updatedAt
        case .working:
            activity = .working
            keepsAwake = true
        case .background where now - record.updatedAt > settings.backgroundStale:
            activity = .stale
            since = record.updatedAt
        case .background:
            activity = .background
            keepsAwake = true
        case .waiting:
            activity = .waiting(reason: record.reason)
            sleepAllowedAt = record.notified
                ? record.updatedAt + settings.sleepGrace
                : record.stateSince + max(settings.notifyTimeout, settings.sleepGrace)
        }

        let runningAgents = agentActivity.filter { now - $0 < settings.workingStale }.count
        if !keepsAwake && runningAgents > 0 {
            activity = .subagents(runningAgents)
            keepsAwake = true
        }

        let project = record.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(record.sessionID.prefix(8))
        return SessionSnapshot(id: record.sessionID, project: project, activity: activity,
                               since: Date(timeIntervalSince1970: since), keepsAwake: keepsAwake,
                               sleepAllowedAt: sleepAllowedAt)
    }
}
