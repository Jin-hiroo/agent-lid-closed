import Foundation

/// Codex 0.163's local event format. This adapter uses only typed event metadata,
/// discarding conversation content. It never reads credentials or discovers other transcripts.
/// The format is not a stable hook API: unknown records are ignored and cannot arm a wake.
public final class CodexQuotaMonitor {
    private static let maximumRead: UInt64 = 1024 * 1024

    private struct Limits: Decodable {
        struct Window: Decodable {
            var usedPercent: Double
            var resetsAt: Double?
            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetsAt = "resets_at"
            }
            var normalized: QuotaUsage.Window? {
                guard let resetsAt else { return nil }
                return QuotaUsage.Window(usedPercentage: usedPercent, resetsAt: resetsAt)
            }
        }
        var primary: Window?
        var secondary: Window?
        var usage: QuotaUsage {
            QuotaUsage(primary: primary?.normalized, secondary: secondary?.normalized)
        }
    }

    private struct Event: Decodable {
        struct Payload: Decodable {
            var type: String
            var limits: Limits?
            var error: String?
            var turnID: String?
            var willRetry: Bool?
            enum CodingKeys: String, CodingKey {
                case type
                case limits = "rate_limits"
                case error = "codex_error_info"
                case turnID = "turn_id"
                case willRetry = "will_retry"
                case willRetryCamel = "willRetry"
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try c.decode(String.self, forKey: .type)
                limits = try? c.decodeIfPresent(Limits.self, forKey: .limits)
                error = try? c.decodeIfPresent(String.self, forKey: .error)
                turnID = try? c.decodeIfPresent(String.self, forKey: .turnID)
                willRetry = (try? c.decodeIfPresent(Bool.self, forKey: .willRetry))
                    ?? (try? c.decodeIfPresent(Bool.self, forKey: .willRetryCamel))
            }
        }
        var timestamp: String
        var type: String
        var payload: Payload
        var time: Double? {
            let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp))
                ?? (try? Date.ISO8601FormatStyle().parse(timestamp))
            return date?.timeIntervalSince1970
        }
    }

    public init() {}

    public func refresh(store: SessionStore, now: Double, isAlive: (Int32, Double) -> Bool) {
        for record in store.loadAll().records where record.client == .codex && record.pid > 0
            && isAlive(record.pid, record.pidStart) {
            try? store.withLock {
                guard var current = store.load(record.sessionID), current.client == .codex,
                      let path = current.transcriptPath, path.hasPrefix("/"), path.hasSuffix(".jsonl"),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                      let size = (attributes[.size] as? NSNumber)?.uint64Value else { return }
                let previous = current.codexTranscriptFileID == fileID ? current.codexTranscriptOffset : nil
                let offset = previous.flatMap { $0 <= size ? $0 : nil } ?? 0
                guard offset < size else { return }
                // Bound initial scans and bursts. Oversized response-item lines can be skipped;
                // they contain no quota metadata and never cause unbounded memory growth.
                let start = max(offset, size > Self.maximumRead ? size - Self.maximumRead : 0)
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                try handle.seek(toOffset: start)
                let data = try handle.read(upToCount: Int(Self.maximumRead)) ?? Data()
                guard let lastNewline = data.lastIndex(of: 10) else {
                    if data.count == Int(Self.maximumRead) {
                        current.codexTranscriptOffset = start + UInt64(data.count)
                        current.codexTranscriptFileID = fileID
                        try store.save(current)
                    }
                    return
                }
                var lines = data[...lastNewline].split(separator: 10)
                if start > offset && !lines.isEmpty { lines.removeFirst() }
                let decoder = JSONDecoder()
                var streamTurnID = current.turnID
                for line in lines {
                    guard let event = try? decoder.decode(Event.self, from: Data(line)), event.type == "event_msg",
                          let time = event.time, time.isFinite, time <= now + 5 else { continue }
                    let payload = event.payload
                    if payload.type == "task_started" { streamTurnID = payload.turnID }
                    if payload.type == "token_count", let limits = payload.limits {
                        current.quotaUsage = limits.usage
                        current.quotaObservedAt = time
                        if let since = current.quotaWaitSince,
                           let reset = limits.usage.blockingReset(after: since) { current.quotaResetAt = reset }
                        continue
                    }
                    let eventTurnID = payload.turnID ?? streamTurnID
                    if payload.type == "task_started", time >= current.updatedAt - 0.01 {
                        current.turnID = payload.turnID
                        current.state = .working
                        current.reason = "working"
                        current.notified = false
                        current.stateSince = time
                        current.updatedAt = max(time, current.updatedAt)
                    }
                    // A stale failure must not overwrite a newer prompt, approval or interrupt.
                    if let expected = current.turnID, let actual = eventTurnID, expected != actual { continue }
                    let sameFinishedTurn = eventTurnID != nil && eventTurnID == current.turnID
                        && current.state == .waiting && current.reason == "finished"
                    guard time >= current.updatedAt - 0.01 || (payload.type == "error" && sameFinishedTurn) else { continue }
                    switch payload.type {
                    case "error":
                        if payload.willRetry == true { continue }
                        let quota = ["usage_limit_exceeded", "usageLimitExceeded", "rate_limit_exceeded", "rateLimitExceeded"]
                            .contains(payload.error ?? "")
                        current.state = .waiting
                        current.reason = quota ? "usage limit" : "API error"
                        current.notified = true
                        current.stateSince = time
                        current.updatedAt = max(time, current.updatedAt)
                        current.quotaWaitSince = quota ? time : nil
                        current.quotaResetAt = nil
                        if quota, let observed = current.quotaObservedAt, time - observed >= -1, time - observed < 600 {
                            current.quotaResetAt = current.quotaUsage?.blockingReset(after: time)
                        }
                    case "task_started", "turn_aborted":
                        current.quotaWaitSince = nil
                        current.quotaResetAt = nil
                        if payload.type == "turn_aborted" {
                            current.state = .waiting
                            current.reason = "interrupted"
                            current.notified = true
                            current.stateSince = time
                            current.updatedAt = max(time, current.updatedAt)
                        }
                    default: break
                    }
                }
                current.codexTranscriptOffset = start + UInt64(lastNewline + 1)
                current.codexTranscriptFileID = fileID
                try store.save(current)
            }
        }
    }
}
