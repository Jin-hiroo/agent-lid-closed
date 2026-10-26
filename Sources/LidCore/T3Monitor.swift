import Foundation
import SQLite3

/// Reads T3's durable orchestration metadata. T3 owns continuation, including
/// deduplication, cancellation and the original conversation's permissions.
/// No credentials, prompts, or conversation bodies are read or written here.
public enum T3Monitor {
    public struct Snapshot: Sendable {
        public var records: [SessionRecord] = []
        public var ownedSessionIDs: Set<String> = []
        public var error: String?
        fileprivate var owner: ProcessIdentity?

        public func merging(_ hooks: SessionStore.Contents) -> SessionStore.Contents {
            var result = hooks
            // Native state wins over hooks from the same T3-owned conversation.
            // In particular, a dead provider child must not erase a durable wait.
            let shadowed = Set(hooks.records.filter { record in
                guard ownedSessionIDs.contains(record.sessionID) else { return false }
                return record.pid <= 0 || !ProcessLookup.isAlive(pid: record.pid, startTime: record.pidStart)
                    || owner.map { ProcessLookup.isDescendant(record.pid, of: $0.pid) } == true
            }.map(\.sessionID))
            result.records.removeAll { shadowed.contains($0.sessionID) }
            for id in shadowed { result.agentActivity.removeValue(forKey: SessionStore.fileKey(id)) }
            result.records += records
            return result
        }
    }

    /// A transient read failure must not drop work or a reset hold. A confirmed
    /// host exit bypasses the cache, and errors cannot extend its 60 s lifetime.
    public struct Cache: Sendable {
        private var lastGood: Snapshot?
        private var lastGoodAt: Double = -.infinity

        public init() {}

        public mutating func resolve(_ current: Snapshot, now: Double) -> Snapshot {
            if current.error == nil {
                lastGood = current
                lastGoodAt = now
                return current
            }
            guard let lastGood, current.owner != nil, current.owner == lastGood.owner,
                  now >= lastGoodAt, now - lastGoodAt < 60 else { return current }
            var cached = lastGood
            cached.error = current.error
            return cached
        }
    }

    public static var defaultDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["AGENT_LID_T3_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // Isolated hook/app tests must never observe the user's live T3 server.
        if ProcessInfo.processInfo.environment["AGENT_LID_STATE_DIR"] != nil
            || ProcessInfo.processInfo.environment["CLAUDE_LID_STATE_DIR"] != nil {
            return Paths.stateDir.appendingPathComponent("t3-disabled")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata")
    }

    private struct Runtime: Decodable {
        var pid: Int32
        var startedAt: String
    }

    public static func read(directory: URL = defaultDirectory, now: Double,
                            identity: (Int32) -> ProcessIdentity? = ProcessLookup.identity) -> Snapshot {
        var snapshot = Snapshot()
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("server-runtime.json")),
              let runtime = try? JSONDecoder().decode(Runtime.self, from: data), runtime.pid > 1,
              let started = timestamp(runtime.startedAt),
              let owner = identity(runtime.pid), started >= owner.startTime - 1,
              started - owner.startTime < 120 else { return snapshot }
        snapshot.owner = owner

        var database: OpaquePointer?
        // Never create a missing DB, change its schema, or write T3 state. Opening
        // the live WAL normally (not immutable) makes recent commits visible.
        guard sqlite3_open_v2(directory.appendingPathComponent("statev2.sqlite").path,
                              &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            snapshot.error = "T3 activity unavailable: could not open its database"
            return snapshot
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)
        do {
            // All metadata comes from one commit while T3 continues to write.
            try execute(database, "BEGIN")
            defer { try? execute(database, "ROLLBACK") }
            try rows(database, activitySQL, now: now) { row in
                guard let threadID = string(row, 0), let status = string(row, 1),
                      let provider = provider(string(row, 2)),
                      let since = timestamp(string(row, 3)) else { return }
                let pendingInput = sqlite3_column_int(row, 5) != 0
                var record = SessionRecord(sessionID: "t3:\(threadID)", state: .working,
                    reason: "T3 Code", notified: true, stateSince: since,
                    updatedAt: timestamp(string(row, 17)) ?? since,
                    pid: owner.pid, pidStart: owner.startTime, cwd: string(row, 4), provider: provider)
                let backgroundActivity = timestamp(string(row, 18))
                let nativeID = string(row, 19).map(provider.sessionKey)
                if (sqlite3_column_int(row, 15) > 0 || backgroundActivity != nil)
                    && !["preparing", "starting", "running"].contains(status) {
                    var background = record
                    background.sessionID += ":background"
                    background.state = .background
                    background.reason = "T3 background tasks"
                    background.updatedAt = max(timestamp(string(row, 16)) ?? since, backgroundActivity ?? since)
                    snapshot.records.append(background)
                    if let nativeID { snapshot.ownedSessionIDs.insert(nativeID) }
                }
                if pendingInput {
                    record.state = .waiting
                    record.reason = "T3 input request"
                    record.stateSince = timestamp(string(row, 14)) ?? since
                    record.updatedAt = record.stateSince
                } else if status == "failed" {
                    // Only a recovery durably armed for this exact failed run and
                    // reset can schedule a wake. Explicit opt-outs are respected.
                    guard string(row, 6) == "usage_limit", let reset = timestamp(string(row, 7)),
                          reset > since, sqlite3_column_int(row, 8) != 0,
                          string(row, 9) == string(row, 10),
                          let recoveryReset = timestamp(string(row, 11)), recoveryReset == reset,
                          sqlite3_column_int(row, 12) != 0 else { return }
                    let snoozed = timestamp(string(row, 13)) ?? 0
                    record.state = .waiting
                    record.reason = "usage limit"
                    record.updatedAt = since
                    record.quotaWaitSince = since
                    // T3 retains the recovery when a later user snooze delays it.
                    record.quotaResetAt = max(reset, snoozed)
                } else if ["completed", "cancelled", "interrupted"].contains(status) {
                    record.state = .waiting
                    record.reason = status == "completed" ? "finished" : status
                    record.updatedAt = since
                }
                snapshot.records.append(record)
                if let nativeID { snapshot.ownedSessionIDs.insert(nativeID) }
            }
            return snapshot
        } catch {
            // An unsupported schema or interrupted read cannot leave a partial
            // snapshot suppressing the independently functioning hook adapter.
            var failed = Snapshot()
            failed.error = "T3 activity unavailable: database busy or unsupported schema"
            failed.owner = owner
            return failed
        }
    }

    private static func provider(_ driver: String?) -> AgentProvider? {
        switch driver {
        case "codex": .codex
        case "claudeAgent": .claude
        default: nil
        }
    }

    private static func timestamp(_ value: String?) -> Double? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value))?.timeIntervalSince1970
    }

    private enum ReadError: Error { case sqlite }

    private static func string(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ReadError.sqlite }
    }

    private static func rows(_ db: OpaquePointer, _ sql: String, now: Double? = nil,
                             body: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReadError.sqlite
        }
        defer { sqlite3_finalize(statement) }
        if let now { sqlite3_bind_double(statement, 1, now) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: body(statement)
            case SQLITE_DONE: return
            default: throw ReadError.sqlite
            }
        }
    }

    /// T3's background roster is supplemented by active tool/subagent items.
    /// Read only lifecycle metadata and the persistent-monitor flag.
    private static let backgroundActivitySQL = """
        (SELECT MAX(work.updated_at) FROM orchestration_v2_projection_turn_items work
         LEFT JOIN orchestration_v2_projection_runs work_run ON work_run.run_id = work.run_id
         WHERE work.thread_id = t.thread_id
           AND work.type IN ('command_execution', 'dynamic_tool', 'subagent')
           AND work.status IN ('pending', 'running', 'waiting')
           AND NOT (work.type = 'dynamic_tool' AND json_extract(work.payload_json, '$.input.persistent') IS 1)
           AND work_run.status IS NOT 'rolled_back')
        """

    // Match T3's latestExecutedRun ordering and root failure selection. A queued
    // or never-started cancelled run cannot hide the actual last execution.
    private static let activitySQL = """
        SELECT t.thread_id, r.status, pt.driver,
          COALESCE(r.completed_at, json_extract(r.payload_json, '$.startedAt'), r.requested_at),
          COALESCE(json_extract(t.payload_json, '$.worktreePath'), p.workspace_root),
          (EXISTS (SELECT 1 FROM orchestration_v2_projection_runtime_requests request
                   WHERE request.thread_id = t.thread_id AND request.status = 'pending')
           OR EXISTS (SELECT 1 FROM orchestration_v2_projection_turn_items secret
                      WHERE secret.thread_id = t.thread_id AND secret.run_id = r.run_id
                        AND secret.type = 'secret_request' AND secret.status = 'waiting'
                        AND r.status IN ('preparing', 'starting', 'running', 'waiting'))),
          json_extract(item.payload_json, '$.failure.class'),
          json_extract(item.payload_json, '$.failure.resetAt'),
          json_extract(t.payload_json, '$.limitRecovery.autoResume') = 1,
          json_extract(t.payload_json, '$.limitRecovery.runId'), r.run_id,
          json_extract(t.payload_json, '$.limitRecovery.resetAt'),
          t.provider_instance_id IS r.provider_instance_id,
          json_extract(t.payload_json, '$.snoozedUntil'),
          COALESCE((SELECT MAX(request.created_at) FROM orchestration_v2_projection_runtime_requests request
                    WHERE request.thread_id = t.thread_id AND request.status = 'pending'),
                   (SELECT MAX(secret.updated_at) FROM orchestration_v2_projection_turn_items secret
                    WHERE secret.thread_id = t.thread_id AND secret.run_id = r.run_id
                      AND secret.type = 'secret_request' AND secret.status = 'waiting')),
          json_array_length(pt.payload_json, '$.pendingBackgroundTasks'),
          json_extract(pt.payload_json, '$.updatedAt'),
          MAX(COALESCE((SELECT MAX(progress.updated_at) FROM orchestration_v2_projection_turn_items progress
                        WHERE progress.thread_id = t.thread_id AND progress.run_id = r.run_id), r.requested_at),
              COALESCE(json_extract(r.payload_json, '$.startedAt'), r.requested_at)),
          \(backgroundActivitySQL),
          json_extract(pt.payload_json, '$.nativeThreadRef.nativeId')
        FROM orchestration_v2_projection_threads t
        JOIN orchestration_v2_projection_runs r ON r.run_id = (
          SELECT latest.run_id FROM orchestration_v2_projection_runs latest
          WHERE latest.thread_id = t.thread_id AND latest.status <> 'queued'
            AND NOT (latest.status = 'cancelled' AND json_extract(latest.payload_json, '$.startedAt') IS NULL)
          ORDER BY latest.completed_at IS NULL DESC, latest.completed_at DESC,
                   latest.ordinal DESC, latest.run_id DESC LIMIT 1
        )
        JOIN orchestration_v2_projection_provider_threads pt ON pt.provider_thread_id = r.provider_thread_id
        LEFT JOIN projection_projects p ON p.project_id = t.project_id
        LEFT JOIN orchestration_v2_projection_turn_items item ON item.turn_item_id = (
          SELECT error.turn_item_id FROM orchestration_v2_projection_turn_items error
          WHERE error.thread_id = t.thread_id AND error.run_id = r.run_id
            AND error.type = 'error' AND error.status = 'failed'
            AND error.node_id IS json_extract(r.payload_json, '$.rootNodeId')
          ORDER BY error.updated_at DESC, error.ordinal DESC, error.turn_item_id DESC LIMIT 1
        )
        WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
          AND json_extract(t.payload_json, '$.settledOverride') IS NOT 'settled'
          -- A finished or limited delegated task whose parent the user has settled is not
          -- theirs to wait for: its wake and hold would only keep the Mac awake for nothing.
          AND NOT (r.status NOT IN ('preparing', 'starting', 'running')
                   AND json_extract(t.payload_json, '$.lineage.relationshipToParent') = 'subagent'
                   AND EXISTS (SELECT 1 FROM orchestration_v2_projection_threads parent
                               WHERE parent.thread_id = json_extract(t.payload_json, '$.lineage.parentThreadId')
                                 AND (json_extract(parent.payload_json, '$.settledOverride') = 'settled'
                                      OR parent.archived_at IS NOT NULL OR parent.deleted_at IS NOT NULL)))
          AND (r.status IN ('preparing', 'starting', 'running', 'waiting', 'failed')
               OR (r.status IN ('completed', 'cancelled', 'interrupted')
                   AND ((julianday(r.completed_at) - 2440587.5) * 86400 > ?1 - 120
                        OR json_array_length(pt.payload_json, '$.pendingBackgroundTasks') > 0
                        OR \(backgroundActivitySQL) IS NOT NULL)))
          AND pt.driver IN ('codex', 'claudeAgent')
        """
}
