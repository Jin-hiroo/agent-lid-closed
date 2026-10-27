import Foundation

/// Subscription windows reported by the two providers. No credentials are read.
public struct QuotaUsage: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public var usedPercentage: Double
        public var resetsAt: Double

        private enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    public var primary: Window?
    public var secondary: Window?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case primary, secondary
    }

    /// Both exhausted windows must reset before work can resume.
    public func blockingReset(after date: Double) -> Double? {
        [fiveHour, sevenDay, primary, secondary].compactMap { $0 }.filter {
            $0.usedPercentage.isFinite && $0.usedPercentage >= 100 && $0.resetsAt.isFinite && $0.resetsAt > date
        }.map(\.resetsAt).max()
    }
}

public struct QuotaStatusInput: Decodable {
    public var sessionID: String
    public var usage: QuotaUsage?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case usage = "rate_limits"
    }

    /// Status updates preserve the activity heartbeat and the owner discovered by the hooks.
    public func save(to store: SessionStore, now: Double) throws {
        try store.withLock {
            guard var record = store.load(sessionID), record.client == .claude else { return }
            let reset = record.quotaWaitSince.flatMap { usage?.blockingReset(after: $0) }
            // Streaming status refreshes can arrive several times per second.
            // Unchanged quota needs only a recent observation, not a file write.
            if record.quotaUsage == usage, reset == nil || reset == record.quotaResetAt,
               let observed = record.quotaObservedAt, now >= observed, now - observed < 30 { return }
            record.quotaUsage = usage
            record.quotaObservedAt = now
            if let since = record.quotaWaitSince, let reset = usage?.blockingReset(after: since) {
                record.quotaResetAt = reset
            }
            try store.save(record)
        }
    }
}

/// A short hold surrounding the reset gives Claude time to continue and report real activity.
/// Absolute wall-clock times deliberately include time the computer spent asleep.
public struct QuotaWakePlan: Sendable, Equatable {
    public static let leadTime: Double = 120
    public static let resumeGrace: Double = 300
    public static let maximumWait: Double = 24 * 60 * 60
    /// T3 persists its recovery across multi-day weekly limits; terminal Claude's
    /// native countdown has a shorter lifetime.
    public static let maximumScheduledWait: Double = 7 * 24 * 60 * 60

    public var nextWakeAt: Double?
    public var nextResetAt: Double?
    public var nextResetProvider: AgentProvider?
    public var nextResetAccountName: String?
    public var holdUntil: Double?
    public var holdingProviders: [AgentProvider] = []
    public var holdingAccountNames: [String] = []

    public static func evaluate(_ records: [SessionRecord], now: Double,
                                isAlive: (Int32, Double) -> Bool) -> QuotaWakePlan {
        var plan = QuotaWakePlan()
        for record in records {
            guard record.state == .waiting, record.reason == "usage limit",
                  record.pid > 0, isAlive(record.pid, record.pidStart),
                  let since = record.quotaWaitSince, let reset = record.quotaResetAt,
                  since.isFinite, reset.isFinite, reset > since,
                  reset - since <= (record.sessionID.hasPrefix("t3:") ? maximumScheduledWait : maximumWait),
                  now < reset + resumeGrace else { continue }
            let account = record.quotaAccountName ?? record.displayName
            let wake = floor(reset - leadTime)
            if wake > now + 5 {
                plan.nextWakeAt = min(plan.nextWakeAt ?? wake, wake)
            } else {
                plan.holdUntil = max(plan.holdUntil ?? 0, reset + resumeGrace)
                if !plan.holdingProviders.contains(record.client) { plan.holdingProviders.append(record.client) }
                if !plan.holdingAccountNames.contains(account) { plan.holdingAccountNames.append(account) }
            }
            if reset < (plan.nextResetAt ?? .infinity) {
                plan.nextResetAt = reset
                plan.nextResetProvider = record.client
                plan.nextResetAccountName = account
            }
        }
        plan.holdingProviders.sort { $0.name < $1.name }
        plan.holdingAccountNames.sort()
        return plan
    }
}

/// The privileged executable accepts only these operations, never arbitrary pmset arguments.
public enum WakeRequest: Equatable {
    case set(Int64)
    case clear

    public static func parse(_ arguments: [String], now: Double) -> WakeRequest? {
        if arguments == ["clear"] { return .clear }
        guard arguments.count == 2, arguments[0] == "set", !arguments[1].isEmpty,
              arguments[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let epoch = Int64(arguments[1]), Double(epoch) > now + 1,
              Double(epoch) <= now + QuotaWakePlan.maximumScheduledWait else { return nil }
        return .set(epoch)
    }
}
