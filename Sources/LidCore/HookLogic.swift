import Foundation

/// The fields of a Claude Code hook payload that matter here. Everything else is ignored.
public struct HookInput: Decodable, Sendable {
    public var event: String
    public var sessionID: String
    /// Set when the hook fires inside a subagent.
    public var agentID: String?
    public var toolName: String?
    public var notificationType: String?
    /// SessionStart: startup, resume, clear or compact.
    public var source: String?
    public var cwd: String?
    public var transcriptPath: String?
    /// Stop: statuses of the session's background tasks. nil if the payload has none.
    public var backgroundTaskStatuses: [String]?

    public init(event: String, sessionID: String, agentID: String? = nil, toolName: String? = nil,
                notificationType: String? = nil, source: String? = nil, cwd: String? = nil,
                transcriptPath: String? = nil, backgroundTaskStatuses: [String]? = nil) {
        self.event = event
        self.sessionID = sessionID
        self.agentID = agentID
        self.toolName = toolName
        self.notificationType = notificationType
        self.source = source
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.backgroundTaskStatuses = backgroundTaskStatuses
    }

    private enum CodingKeys: String, CodingKey {
        case event = "hook_event_name"
        case sessionID = "session_id"
        case agentID = "agent_id"
        case toolName = "tool_name"
        case notificationType = "notification_type"
        case source
        case cwd
        case transcriptPath = "transcript_path"
        case backgroundTasks = "background_tasks"
    }

    private struct BackgroundTask: Decodable {
        var status: String?
    }

    /// Lenient: a field with an unexpected type is treated as missing rather than failing the hook.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(String.self, forKey: .event)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        agentID = try? c.decodeIfPresent(String.self, forKey: .agentID)
        toolName = try? c.decodeIfPresent(String.self, forKey: .toolName)
        notificationType = try? c.decodeIfPresent(String.self, forKey: .notificationType)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
        backgroundTaskStatuses = (try? c.decodeIfPresent([BackgroundTask].self, forKey: .backgroundTasks))?
            .map { $0.status ?? "" }
    }
}

public enum HookAction: Equatable, Sendable {
    /// Move the main agent to `state`. A nil reason keeps the current one.
    case set(AgentState, reason: String?, notified: Bool)
    /// Refresh the session's heartbeat without changing its state.
    case keepState
    case subagentActive(String)
    case subagentDone(String)
    case endSession
    case ignore
}

public enum HookLogic {
    /// Tools that stop and wait for your answer.
    private static let userInputTools = ["AskUserQuestion": "question", "ExitPlanMode": "plan approval"]
    /// Notifications that mean Claude is now waiting for you.
    private static let waitingNotifications = [
        "permission_prompt": "permission",
        "elicitation_dialog": "MCP input",
        "elicitation_url_dialog": "MCP input",
    ]
    private static let finishedTaskStatuses: Set<String> = [
        "completed", "complete", "done", "finished", "succeeded", "success",
        "failed", "error", "killed", "stopped", "cancelled", "canceled", "timeout", "timed_out",
    ]

    public static func action(for input: HookInput) -> HookAction {
        if input.event == "SessionEnd" { return .endSession }
        if let agent = input.agentID, !agent.isEmpty {
            // Inside a subagent: track it separately so it can't overwrite the main agent's state.
            return input.event == "SubagentStop" ? .subagentDone(agent) : .subagentActive(agent)
        }
        switch input.event {
        case "SessionStart":
            // "compact" fires in the middle of a turn, after auto-compaction.
            return input.source == "compact" ? .keepState : .set(.waiting, reason: "new session", notified: true)
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "ElicitationResult":
            return .set(.working, reason: "working", notified: false)
        case "PreToolUse":
            if let reason = userInputTools[input.toolName ?? ""] {
                return .set(.waiting, reason: reason, notified: false)
            }
            return .set(.working, reason: "working", notified: false)
        case "Notification":
            if input.notificationType == "idle_prompt" {
                return .set(.waiting, reason: nil, notified: true)
            }
            if let reason = waitingNotifications[input.notificationType ?? ""] {
                return .set(.waiting, reason: reason, notified: true)
            }
            return .ignore
        case "Elicitation":
            return .set(.waiting, reason: "MCP input", notified: false)
        case "Stop":
            let running = (input.backgroundTaskStatuses ?? []).contains {
                !finishedTaskStatuses.contains($0.lowercased())
            }
            return running
                ? .set(.background, reason: "background tasks", notified: false)
                : .set(.waiting, reason: "finished", notified: false)
        case "StopFailure":
            return .set(.waiting, reason: "API error", notified: false)
        default:
            return .ignore
        }
    }

    /// Applies `action` to the stored session. `owner` is the Claude Code process that ran the hook.
    public static func apply(_ action: HookAction, input: HookInput, owner: ProcessIdentity?,
                             store: SessionStore, now: Double) throws {
        let existing = store.load(input.sessionID)
        func fresh(_ state: AgentState, _ reason: String) -> SessionRecord {
            SessionRecord(sessionID: input.sessionID, state: state, reason: reason, notified: false,
                          stateSince: now, updatedAt: now, pid: 0, pidStart: 0)
        }
        var record: SessionRecord
        switch action {
        case .ignore:
            return
        case .endSession:
            store.remove(input.sessionID)
            return
        case .subagentDone(let agent):
            store.removeAgent(input.sessionID, agent)
            return
        case .subagentActive(let agent):
            store.touchAgent(input.sessionID, agent)
            // The session record carries the PID used to clean up after a crash, so make sure it exists.
            guard existing == nil else { return }
            record = fresh(.working, "working")
        case .keepState:
            record = existing ?? fresh(.working, "working")
        case .set(let state, let reason, let notified):
            if var current = existing, current.state == state {
                current.notified = current.notified || notified
                if let reason { current.reason = reason }
                record = current
            } else {
                record = fresh(state, reason ?? "idle")
                record.notified = notified
                if let existing {
                    record.pid = existing.pid
                    record.pidStart = existing.pidStart
                    record.cwd = existing.cwd
                    record.transcriptPath = existing.transcriptPath
                }
            }
        }
        record.updatedAt = now
        if let owner {
            record.pid = owner.pid
            record.pidStart = owner.startTime
        }
        if let cwd = input.cwd { record.cwd = cwd }
        if let path = input.transcriptPath { record.transcriptPath = path }
        try store.save(record)
    }
}
