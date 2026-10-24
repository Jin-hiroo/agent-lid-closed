import Foundation
import LidCore

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
var now = Double(CommandLine.arguments[2])!
var snapshot = T3Monitor.read(directory: directory, now: now)
if CommandLine.arguments.count >= 5 {
    var cache = T3Monitor.Cache()
    _ = cache.resolve(snapshot, now: now)
    now = Double(CommandLine.arguments[4])!
    snapshot = cache.resolve(T3Monitor.read(directory: URL(fileURLWithPath: CommandLine.arguments[3]), now: now), now: now)
}
var hooks = SessionStore(dir: directory.appendingPathComponent("empty-hooks")).loadAll()
// A conflicting old hook must lose to T3's native state for this conversation.
var oldHook: [String: Any] = ["sessionID": "codex:native-codex", "state": "working",
    "reason": "old hook", "notified": true, "stateSince": now, "updatedAt": now,
    "pid": 0, "pidStart": 0, "provider": "codex"]
if let pid = ProcessInfo.processInfo.environment["AGENT_LID_TEST_HOOK_PID"].flatMap(Int32.init),
   let owner = ProcessLookup.identity(of: pid) {
    oldHook["pid"] = owner.pid
    oldHook["pidStart"] = owner.startTime
}
hooks.records = [try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: oldHook))]
let merged = snapshot.merging(hooks)
let evaluation = Evaluator.evaluate(snapshot.merging(SessionStore(dir: directory.appendingPathComponent("empty-hooks")).loadAll()),
    now: now, settings: LidSettings(),
    isAlive: ProcessLookup.isAlive, isInterrupted: { _ in false })
let plan = QuotaWakePlan.evaluate(snapshot.records, now: now, isAlive: ProcessLookup.isAlive)
let output: [String: Any] = [
    "error": snapshot.error as Any? ?? NSNull(),
    "records": snapshot.records.map { ["id": $0.sessionID, "state": $0.state.rawValue,
        "provider": $0.client.rawValue, "reason": $0.reason, "since": $0.stateSince,
        "updatedAt": $0.updatedAt] as [String: Any] },
    "owned": snapshot.ownedSessionIDs.sorted(),
    "mergedIDs": merged.records.map(\.sessionID),
    "keepAwake": evaluation.keepAwake,
    "wakeAt": plan.nextWakeAt as Any? ?? NSNull(),
    "resetAt": plan.nextResetAt as Any? ?? NSNull(),
    "holdUntil": plan.holdUntil as Any? ?? NSNull()
]
print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
