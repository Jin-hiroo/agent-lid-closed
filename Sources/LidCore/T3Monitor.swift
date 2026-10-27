import Foundation
import SQLite3

/// Reads T3's durable orchestration metadata. T3 owns continuation, including
/// deduplication, cancellation and the original conversation's permissions.
/// No credentials, prompts, or conversation bodies are read or written here.
public enum T3Monitor {
    public struct Snapshot: Sendable {
        public var records: [SessionRecord] = []
        public var ownedSessionIDs: Set<String> = []
        /// Conversations blocked by an account's usage limit, for account switching.
        public var limitedThreads: [T3LimitedThread] = []
        public var accounts: [T3Account] = []
        /// Each account's latest reset that no later successful run has disproved.
        /// Includes resets that passed less than `AccountSwitchPlanner.resetMargin` ago.
        public var limitedUntil: [String: Double] = [:]
        /// The user turned off T3's automatic continuation after usage limits, or the
        /// accounts' limits couldn't be read. Either way, no account is switched.
        public var continuationDisabled = false
        public var error: String?
        fileprivate var owner: ProcessIdentity?

        public init() {}

        /// T3 Code's server was found running.
        public var isRunning: Bool { owner != nil }

        /// Conversations whose account switch is being delivered keep the Mac awake.
        /// Another account's earlier reset brings their wake forward.
        public mutating func applyAccountSwitching(delivering: Set<String>,
                                                   earlierResets: [String: AccountSwitchPlanner.EarlierReset],
                                                   now: Double) {
            for thread in limitedThreads {
                let id = "t3:\(thread.threadID)"
                if delivering.contains(thread.threadID) {
                    var record = thread.record
                    record.state = .working
                    record.reason = "switching account"
                    record.stateSince = thread.failedAt
                    record.updatedAt = now
                    records.removeAll { $0.sessionID == id }
                    records.append(record)
                } else if let earlier = earlierResets[thread.threadID],
                          let index = records.firstIndex(where: { $0.sessionID == id && $0.reason == "usage limit" }),
                          let reset = records[index].quotaResetAt, earlier.at < reset {
                    records[index].quotaResetAt = earlier.at
                    records[index].quotaAccountName = earlier.accountName
                }
            }
        }

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
            guard let lastGood, current.owner != nil, current.owner == lastGood.owner else { return current }
            if now < lastGoodAt || now - lastGoodAt >= 60 {
                // Activity expires, but known T3-owned IDs remain authoritative
                // for this live host. Otherwise stale hooks could re-arm waits.
                var failed = current
                failed.ownedSessionIDs.formUnion(lastGood.ownedSessionIDs)
                return failed
            }
            var cached = lastGood
            cached.ownedSessionIDs.formUnion(current.ownedSessionIDs)
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
        let settings = settings(directory: directory)
        let accountNames = accountNames(settings.providerInstances)
        snapshot.accounts = accounts(settings)
        snapshot.continuationDisabled = settings.autoResumeLimitedThreads == false

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
        var ownershipLoaded = false
        do {
            // All metadata comes from one commit while T3 continues to write.
            try execute(database, "BEGIN")
            defer { try? execute(database, "ROLLBACK") }
            // Ownership is independent of activity. Settling, archiving, opting
            // out, or finishing must not let a T3 provider fall back to its hooks.
            // merging() still preserves live hooks from independent terminals.
            try rows(database, ownershipSQL) { row in
                guard let nativeID = string(row, 0), !nativeID.isEmpty,
                      let provider = provider(string(row, 1)) else { return }
                snapshot.ownedSessionIDs.insert(provider.sessionKey(nativeID))
            }
            ownershipLoaded = true
            try rows(database, activitySQL, now: now) { row in
                guard let threadID = string(row, 0), let status = string(row, 1),
                      let provider = provider(string(row, 2)),
                      let since = timestamp(string(row, 3)) else { return }
                let pendingInput = sqlite3_column_int(row, 5) != 0
                var record = SessionRecord(sessionID: "t3:\(threadID)", state: .working,
                    reason: "T3 Code", notified: true, stateSince: since,
                    updatedAt: timestamp(string(row, 17)) ?? since,
                    pid: owner.pid, pidStart: owner.startTime, cwd: string(row, 4), provider: provider)
                record.providerInstanceID = string(row, 20)
                record.accountName = record.providerInstanceID.flatMap { accountNames[$0] }
                let backgroundActivity = timestamp(string(row, 18))
                if (sqlite3_column_int(row, 15) > 0 || backgroundActivity != nil)
                    && !["preparing", "starting", "running"].contains(status) {
                    var background = record
                    background.sessionID += ":background"
                    background.state = .background
                    background.reason = "T3 background tasks"
                    background.updatedAt = max(timestamp(string(row, 16)) ?? since, backgroundActivity ?? since)
                    snapshot.records.append(background)
                }
                if pendingInput {
                    record.state = .waiting
                    record.reason = "T3 input request"
                    record.stateSince = timestamp(string(row, 14)) ?? since
                    record.updatedAt = record.stateSince
                } else if status == "failed" {
                    // The same conditions T3 applies before continuing a limited run:
                    // the conversation still uses the failed account and no later
                    // error from that account superseded the limit.
                    if string(row, 6) == "usage_limit", let reset = timestamp(string(row, 7)), reset > since,
                       sqlite3_column_int(row, 12) != 0,
                       string(row, 21).map({ $0 == string(row, 22) }) ?? true,
                       let runID = string(row, 10), let instance = string(row, 20),
                       let selection = string(row, 23) {
                        let armed = string(row, 9) == runID && sqlite3_column_type(row, 25) != SQLITE_NULL
                        snapshot.limitedThreads.append(T3LimitedThread(
                            threadID: threadID, runID: runID, projectID: string(row, 26), accountID: instance,
                            failedAt: since, resetAt: reset,
                            snoozedUntil: timestamp(string(row, 13)),
                            autoResume: armed ? sqlite3_column_int(row, 25) != 0 : nil,
                            isDelegated: string(row, 24) == "subagent",
                            modelSelection: selection, record: record))
                    }
                    // Only a recovery durably armed for this exact failed run and
                    // reset can schedule a wake. Explicit opt-outs are respected.
                    guard string(row, 6) == "usage_limit", let reset = timestamp(string(row, 7)),
                          reset > since, sqlite3_column_int(row, 8) != 0,
                          string(row, 9) == string(row, 10),
                          let recoveryReset = timestamp(string(row, 11)), recoveryReset == reset,
                          sqlite3_column_int(row, 12) != 0 else { return }
                    // T3 rejects a quota recovery superseded by a different error
                    // from the session bound to this particular account.
                    if let sessionError = string(row, 21), sessionError != string(row, 22) { return }
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
            }
            // An account stays limited until its reset, unless a run started after
            // the failure has since completed on it. Unknown limits stop switching
            // rather than the activity this monitor reports.
            do {
                var provenAt: [String: Double] = [:]
                try rows(database, provenAccountsSQL) { row in
                    guard let instance = string(row, 0), sqlite3_column_type(row, 1) != SQLITE_NULL else { return }
                    provenAt[instance] = sqlite3_column_double(row, 1)
                }
                try rows(database, limitedAccountsSQL, now: now) { row in
                    guard let instance = string(row, 0), let reset = timestamp(string(row, 1)),
                          reset + AccountSwitchPlanner.resetMargin > now,
                          let failedAt = timestamp(string(row, 2)), failedAt > provenAt[instance] ?? -.infinity else { return }
                    snapshot.limitedUntil[instance] = max(snapshot.limitedUntil[instance] ?? reset, reset)
                }
            } catch {
                snapshot.limitedUntil = [:]
                snapshot.continuationDisabled = true
            }
            return snapshot
        } catch {
            // Discard partial activity. Independently loaded ownership remains
            // valid, preventing settled T3 work from reappearing through hooks.
            var failed = Snapshot()
            failed.error = "T3 activity unavailable: database busy or unsupported schema"
            failed.owner = owner
            if ownershipLoaded { failed.ownedSessionIDs = snapshot.ownedSessionIDs }
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

    private struct Settings: Decodable {
        /// Every field is optional so that one unusual instance can't hide the others.
        struct Instance: Decodable {
            var driver: String?
            var displayName: String?
            var enabled: Bool?
            var customModels: Set<String> = []

            private enum CodingKeys: String, CodingKey { case driver, displayName, enabled, config }
            private enum ConfigKeys: String, CodingKey { case customModels, enabled }
            /// A legacy bare slug or a full entry.
            private struct Model: Decodable {
                var slug: String?
                private enum Keys: String, CodingKey { case slug }
                init(from decoder: Decoder) throws {
                    slug = (try? decoder.singleValueContainer().decode(String.self))
                        ?? (try? decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .slug))
                }
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                driver = try? container.decode(String.self, forKey: .driver)
                displayName = try? container.decode(String.self, forKey: .displayName)
                let config = try? container.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config)
                let models = (try? config?.decode([Model].self, forKey: .customModels)) ?? []
                customModels = Set(models.compactMap(\.slug))
                // As T3 resolves it: a false on the envelope or the legacy config flag wins.
                let envelope = try? container.decode(Bool.self, forKey: .enabled)
                let legacy = try? config?.decode(Bool.self, forKey: .enabled)
                enabled = envelope == false || legacy == false ? false : envelope ?? legacy
            }
        }
        /// Unreadable entries decode as empty instead of failing the whole map.
        private struct ProjectOverride: Decodable {
            struct Instance: Decodable {
                var enabled: Bool?
                private enum Keys: String, CodingKey { case enabled }
                init(from decoder: Decoder) throws {
                    enabled = try? decoder.container(keyedBy: Keys.self).decode(Bool.self, forKey: .enabled)
                }
            }
            var providerInstances: [String: Instance] = [:]
            private enum Keys: String, CodingKey { case providerInstances }
            init(from decoder: Decoder) throws {
                providerInstances = (try? decoder.container(keyedBy: Keys.self)
                    .decode([String: Instance].self, forKey: .providerInstances)) ?? [:]
            }
        }
        private enum CodingKeys: String, CodingKey {
            case providerInstances, projectSettingsOverrides, autoResumeLimitedThreads
        }

        var providerInstances: [String: Instance] = [:]
        /// Project ID, then instance ID.
        var projectEnabled: [String: [String: Bool]] = [:]
        var autoResumeLimitedThreads: Bool?

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            providerInstances = (try? container.decode([String: Instance].self, forKey: .providerInstances)) ?? [:]
            let overrides = (try? container.decode([String: ProjectOverride].self, forKey: .projectSettingsOverrides)) ?? [:]
            projectEnabled = overrides.mapValues { $0.providerInstances.compactMapValues(\.enabled) }
            autoResumeLimitedThreads = try? container.decode(Bool.self, forKey: .autoResumeLimitedThreads)
        }
    }

    /// T3's accounts and its usage-limit continuation choice, read from its settings
    /// even when T3 isn't running. Nil when T3 Code isn't installed.
    public static func configuration(directory: URL = defaultDirectory)
        -> (accounts: [T3Account], continuationDisabled: Bool)? {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.json").path) else {
            return nil
        }
        let settings = settings(directory: directory)
        return (accounts(settings), settings.autoResumeLimitedThreads == false)
    }

    private static func settings(directory: URL) -> Settings {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return settings
    }

    private static func accountNames(_ instances: [String: Settings.Instance]) -> [String: String] {
        instances.reduce(into: [:]) { names, entry in
            guard let provider = provider(entry.value.driver),
                  let name = entry.value.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            names[entry.key] = name.localizedCaseInsensitiveContains(provider.name)
                ? name : "\(provider.name) (\(name))"
        }
    }

    /// T3's built-in instance for each tool is named after its driver and exists
    /// even when settings don't mention it.
    private static func accounts(_ settings: Settings) -> [T3Account] {
        let instances = settings.providerInstances
        let names = accountNames(instances)
        func projectEnabled(_ id: String) -> [String: Bool] {
            settings.projectEnabled.compactMapValues { $0[id] }
        }
        var accounts = instances.compactMap { id, instance -> T3Account? in
            guard let driver = instance.driver, let provider = provider(driver) else { return nil }
            return T3Account(id: id, driver: driver, name: names[id] ?? provider.name,
                             enabled: instance.enabled ?? true, projectEnabled: projectEnabled(id),
                             customModels: instance.customModels)
        }
        for (driver, provider) in [("claudeAgent", AgentProvider.claude), ("codex", .codex)]
        where instances[driver] == nil {
            accounts.append(T3Account(id: driver, driver: driver, name: provider.name,
                                      projectEnabled: projectEnabled(driver), configured: false))
        }
        return accounts.sorted { $0.id < $1.id }
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

    private static let ownershipSQL = """
        SELECT json_extract(payload_json, '$.nativeThreadRef.nativeId'), driver
        FROM orchestration_v2_projection_provider_threads
        WHERE driver IN ('codex', 'claudeAgent')
        """

    /// Usage-limit failures of any conversation, by account, whose reset is ahead or just passed.
    private static let limitedAccountsSQL = """
        SELECT r.provider_instance_id, json_extract(item.payload_json, '$.failure.resetAt'),
          COALESCE(r.completed_at, item.updated_at)
        FROM orchestration_v2_projection_runs r
        JOIN orchestration_v2_projection_turn_items item ON item.turn_item_id = (
          SELECT error.turn_item_id FROM orchestration_v2_projection_turn_items error
          WHERE error.thread_id = r.thread_id AND error.run_id = r.run_id
            AND error.type = 'error' AND error.status = 'failed'
            AND error.node_id IS json_extract(r.payload_json, '$.rootNodeId')
          ORDER BY error.updated_at DESC, error.ordinal DESC, error.turn_item_id DESC LIMIT 1
        )
        WHERE r.status = 'failed' AND r.provider_instance_id IS NOT NULL
          AND json_extract(item.payload_json, '$.failure.class') = 'usage_limit'
          AND (julianday(json_extract(item.payload_json, '$.failure.resetAt')) - 2440587.5) * 86400 > ?1 - 600
        """

    /// The latest start of a run that went on to complete, by account.
    private static let provenAccountsSQL = """
        SELECT provider_instance_id,
          (MAX(julianday(COALESCE(json_extract(payload_json, '$.startedAt'), requested_at))) - 2440587.5) * 86400
        FROM orchestration_v2_projection_runs
        WHERE status = 'completed' AND provider_instance_id IS NOT NULL
        GROUP BY provider_instance_id
        """

    // Match T3's latestExecutedRun ordering and root failure selection. A queued
    // or never-started cancelled run cannot hide the actual last execution.
    private static let activitySQL = """
        WITH RECURSIVE edges(child, parent) AS MATERIALIZED (
          -- Text affinity lets SQLite index the materialized parent links.
          SELECT thread_id, CAST(json_extract(payload_json, '$.lineage.parentThreadId') AS TEXT)
          FROM orchestration_v2_projection_threads
          WHERE json_extract(payload_json, '$.lineage.relationshipToParent') = 'subagent'
            AND json_extract(payload_json, '$.settledOverride') IS NOT 'active'
        ), retired(thread_id) AS (
          SELECT thread_id FROM orchestration_v2_projection_threads
          WHERE thread_id IS NOT NULL AND (deleted_at IS NOT NULL OR archived_at IS NOT NULL
            OR json_extract(payload_json, '$.settledOverride') = 'settled')
          UNION
          SELECT edges.child FROM edges JOIN retired ON retired.thread_id = edges.parent
        )
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
          json_extract(pt.payload_json, '$.nativeThreadRef.nativeId'),
          r.provider_instance_id,
          (SELECT json_extract(session.payload_json, '$.lastError')
           FROM orchestration_v2_projection_provider_session_bindings binding
           JOIN orchestration_v2_projection_provider_sessions session
             ON session.provider_session_id = binding.provider_session_id
           WHERE binding.thread_id = t.thread_id AND session.provider_instance_id = t.provider_instance_id
           ORDER BY session.updated_at DESC, session.provider_session_id DESC LIMIT 1),
          json_extract(item.payload_json, '$.failure.message'),
          json_extract(t.payload_json, '$.modelSelection'),
          json_extract(t.payload_json, '$.lineage.relationshipToParent'),
          json_extract(t.payload_json, '$.limitRecovery.autoResume'),
          t.project_id
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
          -- Honor ancestor retirement in this app's wake tracking. T3's native
          -- recovery worker checks each thread's own settlement separately.
          -- A genuinely running or explicitly reopened child still needs power.
          AND (r.status IN ('preparing', 'starting', 'running')
               OR NOT EXISTS (SELECT 1 FROM retired WHERE retired.thread_id = t.thread_id))
          AND (r.status IN ('preparing', 'starting', 'running', 'waiting', 'failed')
               OR (r.status IN ('completed', 'cancelled', 'interrupted')
                   AND ((julianday(r.completed_at) - 2440587.5) * 86400 > ?1 - 120
                        OR json_array_length(pt.payload_json, '$.pendingBackgroundTasks') > 0
                        OR \(backgroundActivitySQL) IS NOT NULL)))
          AND pt.driver IN ('codex', 'claudeAgent')
        """
}
