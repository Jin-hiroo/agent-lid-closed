import Foundation

/// A T3 provider instance: one signed-in account of a tool.
public struct T3Account: Sendable, Equatable {
    public var id: String
    /// T3 driver kind, such as `claudeAgent` or `codex`.
    public var driver: String
    public var name: String
    public var enabled: Bool
    /// Per-project overrides of `enabled`, by T3 project ID.
    public var projectEnabled: [String: Bool]
    /// Configured in T3's settings. T3's built-in instances exist without that,
    /// but may not be signed in, so they are never chosen as a target.
    public var configured: Bool
    /// Models that exist only because this instance's settings add them.
    public var customModels: Set<String>

    public init(id: String, driver: String, name: String, enabled: Bool = true, projectEnabled: [String: Bool] = [:],
                configured: Bool = true, customModels: Set<String> = []) {
        self.id = id
        self.driver = driver
        self.name = name
        self.enabled = enabled
        self.projectEnabled = projectEnabled
        self.configured = configured
        self.customModels = customModels
    }

    public func isEnabled(inProject project: String?) -> Bool {
        project.flatMap { projectEnabled[$0] } ?? enabled
    }
}

/// A T3 conversation whose latest run stopped at one account's usage limit.
public struct T3LimitedThread: Sendable, Equatable {
    public var threadID: String
    public var runID: String
    public var projectID: String?
    public var accountID: String
    public var failedAt: Double
    public var resetAt: Double
    public var snoozedUntil: Double?
    /// T3's recovery choice for this exact run; nil until its worker arms one.
    public var autoResume: Bool?
    /// Delegated children report the failure to their parent, which decides.
    public var isDelegated: Bool
    /// The conversation's selection as T3 stores it: a JSON object.
    public var modelSelection: String
    /// The conversation's native record, reused while a switch is delivered.
    public var record: SessionRecord

    public init(threadID: String, runID: String, projectID: String? = nil, accountID: String, failedAt: Double, resetAt: Double,
                snoozedUntil: Double? = nil, autoResume: Bool? = nil, isDelegated: Bool = false,
                modelSelection: String, record: SessionRecord) {
        self.threadID = threadID
        self.runID = runID
        self.projectID = projectID
        self.accountID = accountID
        self.failedAt = failedAt
        self.resetAt = resetAt
        self.snoozedUntil = snoozedUntil
        self.autoResume = autoResume
        self.isDelegated = isDelegated
        self.modelSelection = modelSelection
        self.record = record
    }
}

/// Moves one blocked conversation to another account of the same tool and
/// continues it there, as T3's Resume button does after a manual account change.
public struct AccountSwitch: Sendable, Equatable {
    public var threadID: String
    public var runID: String
    /// Shown in the menu and log.
    public var project: String
    public var from: T3Account
    public var to: T3Account
    /// T3 `message.dispatch` command. Its ID makes redelivery idempotent.
    public var command: Data
    public var commandID: String { AccountSwitchPlanner.commandID(threadID: threadID, runID: runID) }
}

public enum AccountSwitchPlanner {
    /// A failure this recent is switched before T3's recovery worker arms it.
    public static let freshFailureWindow: Double = 15 * 60
    /// A reset estimate can be slightly early; T3 itself resumes exactly at it.
    public static let resetMargin: Double = 60

    public struct EarlierReset: Sendable, Equatable {
        public var at: Double
        public var accountName: String

        public init(at: Double, accountName: String) {
            self.at = at
            self.accountName = accountName
        }
    }

    public struct Plan: Sendable, Equatable {
        public var switches: [AccountSwitch] = []
        /// Blocked conversations, by thread ID, that another account can take over before their own reset.
        public var earlierResets: [String: EarlierReset] = [:]

        public init() {}
    }

    public static func commandID(threadID: String, runID: String) -> String {
        "agent-lid-account-switch:\(threadID):\(runID)"
    }

    /// `limitedUntil` maps an account to its latest known reset. T3's global opt-out of
    /// automatic continuation also turns switching off.
    public static func plan(threads: [T3LimitedThread], accounts: [T3Account],
                            limitedUntil: [String: Double], now: Double,
                            continuationDisabled: Bool = false) -> Plan {
        var plan = Plan()
        guard !continuationDisabled else { return plan }
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for thread in threads {
            guard !thread.isDelegated, thread.autoResume != false,
                  (thread.snoozedUntil ?? 0) <= now,
                  thread.autoResume == true || (now >= thread.failedAt && now - thread.failedAt < freshFailureWindow),
                  let source = byID[thread.accountID],
                  let model = model(of: thread.modelSelection) else { continue }
            let candidates = accounts.filter { account in
                account.id != source.id && account.driver == source.driver && account.configured
                    && account.isEnabled(inProject: thread.projectID)
                    && (!source.customModels.contains(model) || account.customModels.contains(model))
            }.sorted { $0.id < $1.id }
            func availableAt(_ account: T3Account) -> Double {
                limitedUntil[account.id].map { $0 + resetMargin } ?? 0
            }
            if let target = candidates.first(where: { availableAt($0) <= now }) {
                guard let command = command(thread: thread, from: source, to: target) else { continue }
                let project = thread.record.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? String(thread.threadID.prefix(8))
                plan.switches.append(AccountSwitch(threadID: thread.threadID, runID: thread.runID, project: project,
                                                   from: source, to: target, command: command))
            } else if let next = candidates.min(by: { availableAt($0) < availableAt($1) }),
                      availableAt(next) < max(thread.resetAt, thread.snoozedUntil ?? 0) {
                plan.earlierResets[thread.threadID] = EarlierReset(at: availableAt(next), accountName: next.name)
            }
        }
        return plan
    }

    /// The same `message.dispatch` T3's Resume button sends with another account
    /// selected: it switches the conversation and starts the turn atomically.
    public static func command(thread: T3LimitedThread, from source: T3Account, to target: T3Account) -> Data? {
        guard var selection = (try? JSONSerialization.jsonObject(with: Data(thread.modelSelection.utf8))) as? [String: Any],
              selection["model"] is String else { return nil }
        selection["instanceId"] = target.id
        let id = commandID(threadID: thread.threadID, runID: thread.runID)
        let command: [String: Any] = [
            "type": "message.dispatch",
            "commandId": id,
            "messageId": id,
            "threadId": thread.threadID,
            "createdBy": "user",
            "creationSource": "server",
            "manualContinuationOfRunId": thread.runID,
            "modelSelection": selection,
            "text": "Continue where you left off. \(source.name) reached its usage limit, "
                + "so Agent Lid Closed moved this conversation to \(target.name).",
            "attachments": [Any](),
            "dispatchMode": ["type": "start_immediately"],
        ]
        return try? JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
    }

    private static func model(of selection: String) -> String? {
        ((try? JSONSerialization.jsonObject(with: Data(selection.utf8))) as? [String: Any])?["model"] as? String
    }
}
