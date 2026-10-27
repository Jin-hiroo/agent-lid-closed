import Foundation
import LidCore

var checks = 0
@MainActor func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
    checks += 1
}

let now: Double = 2_000_000_000
let decoder = JSONDecoder()
func usage(_ five: Double = 100, _ fiveReset: Double = now + 600,
           _ week: Double = 10, _ weekReset: Double = now + 3600) throws -> QuotaUsage {
    try decoder.decode(QuotaUsage.self, from: Data("""
        {"five_hour":{"used_percentage":\(five),"resets_at":\(fiveReset)},
         "seven_day":{"used_percentage":\(week),"resets_at":\(weekReset)}}
        """.utf8))
}
func record() throws -> SessionRecord {
    // A pre-upgrade record must remain readable without any new fields.
    var value = try decoder.decode(SessionRecord.self, from: Data("""
        {"sessionID":"session","state":"waiting","reason":"usage limit","notified":true,
         "stateSince":\(now),"updatedAt":\(now),"pid":42,"pidStart":123}
        """.utf8))
    value.quotaWaitSince = now
    value.quotaResetAt = now + 600
    return value
}
func plan(_ records: [SessionRecord], _ date: Double = now, alive: Bool = true) -> QuotaWakePlan {
    QuotaWakePlan.evaluate(records, now: date, isAlive: { _, _ in alive })
}

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: temporary) }
let store = SessionStore(dir: temporary)
var r = try record()
check(r.client == .claude, "legacy provider")
check(try usage().blockingReset(after: now) == now + 600, "ignore unexhausted weekly window")
check(try usage(100, now + 600, 100).blockingReset(after: now) == now + 3600, "wait for both exhausted limits")
check(try usage(100, now - 1).blockingReset(after: now) == nil, "ignore expired limits")
check(plan([r]).nextWakeAt == now + 480, "wake two minutes early")
check(plan([r]).holdUntil == nil, "sleep between failure and wake")
check(plan([r], now + 480).holdUntil == now + 900, "hold begins before reset")
check(plan([r], now + 650).holdUntil == now + 900, "hold survives reset")
check(plan([r], now + 900).holdUntil == nil, "hold is bounded when Claude doesn't resume")
check(plan([r], alive: false).nextWakeAt == nil, "dead session cannot wake")
r.pid = 0
check(plan([r]).nextWakeAt == nil, "unknown owner cannot wake")
r = try record()
r.provider = .codex
check(plan([r]).nextWakeAt == now + 480, "Codex shares the quota wake schedule")
r = try record()
r.quotaResetAt = now + 86401
check(plan([r]).nextWakeAt == nil, "don't schedule beyond native auto-continue horizon")
r.sessionID = "t3:weekly-thread"
r.quotaResetAt = now + 3 * 86400
check(plan([r]).nextWakeAt == now + 3 * 86400 - 120, "T3 persists recovery across a multi-day weekly limit")
r.quotaResetAt = now + 7 * 86400 + 1
check(plan([r]).nextWakeAt == nil, "T3 wake horizon is bounded to seven days")
r.quotaResetAt = .infinity
check(plan([r]).nextWakeAt == nil, "reject nonfinite state")
r = try record()
var other = r
other.sessionID = "other"
other.quotaResetAt = now + 1000
check(plan([other, r]).nextWakeAt == now + 480, "earliest session wakes first")
check(plan([other, r], now + 480).nextWakeAt == now + 880, "next alarm remains scheduled during first hold")
other.provider = .codex
check(plan([other, r]).nextResetProvider == .claude, "earliest provider is identified")
check(plan([other, r], now + 890).holdingProviders == [.claude, .codex], "both providers can share a hold")

r = try record()
r.quotaUsage = try usage()
r.quotaObservedAt = now - 30
r.quotaWaitSince = nil
r.quotaResetAt = nil
r.state = .working
r.reason = "working"
try store.save(r)
let failure = HookInput(event: "StopFailure", sessionID: "session", error: "rate_limit")
try store.withLock {
    try HookLogic.apply(HookLogic.action(for: failure), input: failure, owner: nil, store: store, now: now)
}
check(store.load("session")?.quotaResetAt == now + 600, "failure arms from recent cached quota")
let idle = HookInput(event: "Notification", sessionID: "session", notificationType: "idle_prompt")
try HookLogic.apply(HookLogic.action(for: idle), input: idle, owner: nil, store: store, now: now + 10)
check(store.load("session")?.quotaResetAt == now + 600, "idle notification preserves quota wait")

let refreshed = try decoder.decode(QuotaStatusInput.self, from: Data("""
    {"session_id":"session","rate_limits":{"five_hour":{"used_percentage":0,"resets_at":\(now + 18600)}}}
    """.utf8))
try refreshed.save(to: store, now: now + 601)
check(store.load("session")?.updatedAt == now + 10, "status line does not refresh heartbeat")
check(store.load("session")?.pid == 42, "status line does not replace owner")
check(store.load("session")?.quotaResetAt == now + 600, "refresh at reset preserves latched hold")

for notification in ["quota_auto_resume_fired", "quota_auto_resume_stale", "quota_auto_resume_disabled"] {
    try store.save(try record())
    let event = HookInput(event: "Notification", sessionID: "session", notificationType: notification)
    try HookLogic.apply(HookLogic.action(for: event), input: event, owner: nil, store: store, now: now + 1)
    check(store.load("session")?.quotaResetAt == nil, "continuation/cancellation disarms wake")
}
for event in [HookInput(event: "UserPromptSubmit", sessionID: "session"),
              HookInput(event: "PreToolUse", sessionID: "session", toolName: "AskUserQuestion"),
              HookInput(event: "Stop", sessionID: "session"),
              HookInput(event: "StopFailure", sessionID: "session", error: "authentication_failed")] {
    try store.save(try record())
    try HookLogic.apply(HookLogic.action(for: event), input: event, owner: nil, store: store, now: now + 1)
    check(store.load("session")?.quotaResetAt == nil, "new activity or non-quota failure disarms wake")
}
// Reverse callback ordering: quota data can arrive after the failure.
r = try record()
r.quotaUsage = nil
r.quotaObservedAt = nil
r.quotaResetAt = nil
try store.save(r)
let late = try decoder.decode(QuotaStatusInput.self, from: Data("""
    {"session_id":"session","rate_limits":{"five_hour":{"used_percentage":100,"resets_at":\(now + 600)}}}
    """.utf8))
try late.save(to: store, now: now + 2)
check(store.load("session")?.quotaResetAt == now + 600, "quota callback after failure arms wake")
try store.save(try record())
let end = HookInput(event: "SessionEnd", sessionID: "session")
try HookLogic.apply(.endSession, input: end, owner: nil, store: store, now: now + 1)
try late.save(to: store, now: now + 2)
check(store.load("session") == nil, "late status line cannot resurrect an ended session")

// Codex has no StopFailure hook. Read only its typed local event metadata.
let transcript = temporary.appendingPathComponent("codex.jsonl")
var codex = try record()
codex.sessionID = "codex:events"
codex.provider = .codex
codex.state = .working
codex.reason = "working"
codex.updatedAt = now - 10
codex.stateSince = now - 10
codex.quotaWaitSince = nil
codex.quotaResetAt = nil
codex.turnID = "turn-1"
codex.transcriptPath = transcript.path
try store.save(codex)
func codexEvent(_ type: String, at time: Double, fields: [String: Any] = [:]) throws -> Data {
    var payload = fields
    payload["type"] = type
    let date = Date(timeIntervalSince1970: time).ISO8601Format(.iso8601WithTimeZone(includingFractionalSeconds: true))
    var data = try JSONSerialization.data(withJSONObject: ["timestamp": date, "type": "event_msg", "payload": payload])
    data.append(10)
    return data
}
func appendCodex(_ data: Data) throws {
    if !FileManager.default.fileExists(atPath: transcript.path) { try Data().write(to: transcript) }
    let handle = try FileHandle(forWritingTo: transcript)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}
func scanCodex(_ date: Double = now + 100) {
    CodexQuotaMonitor().refresh(store: store, now: date, isAlive: { _, _ in true })
}
func limits(_ primaryReset: Double = now + 600, weekly: Double = 10) -> [String: Any] {
    ["primary": ["used_percent": 100, "resets_at": primaryReset],
     "secondary": ["used_percent": weekly, "resets_at": now + 1000]]
}
try appendCodex(codexEvent("token_count", at: now - 1, fields: ["rate_limits": limits()]))
try appendCodex(codexEvent("error", at: now, fields: ["turn_id": "turn-1", "codex_error_info": "usage_limit_exceeded"]))
scanCodex()
check(store.load(codex.sessionID)?.quotaResetAt == now + 600, "Codex quota failure arms known reset")
check(store.load(codex.sessionID)?.reason == "usage limit", "Codex failure stops the working hold")
check(store.load(codex.sessionID)?.pid == 42, "event reader preserves owning process")
let codexStop = HookInput(event: "Stop", sessionID: codex.sessionID, turnID: "turn-1")
try HookLogic.apply(HookLogic.action(for: codexStop, provider: .codex), input: codexStop,
                    owner: nil, store: store, now: now + 2, provider: .codex)
check(store.load(codex.sessionID)?.quotaResetAt == now + 600,
      "Stop after quota observation preserves the confirmed failure")
let cursor = store.load(codex.sessionID)?.codexTranscriptOffset
let interrupt = HookInput(event: "Interrupt", sessionID: codex.sessionID, turnID: "turn-1")
try HookLogic.apply(HookLogic.action(for: interrupt, provider: .codex), input: interrupt,
                    owner: nil, store: store, now: now + 5, provider: .codex)
scanCodex()
check(store.load(codex.sessionID)?.quotaResetAt == nil, "restart cannot replay a cancelled Codex failure")
check(store.load(codex.sessionID)?.codexTranscriptOffset == cursor, "hooks retain the read cursor")
try appendCodex(codexEvent("token_count", at: now + 6, fields: ["rate_limits": limits()]))
scanCodex()
check(store.load(codex.sessionID)?.quotaResetAt == nil, "exhausted usage alone cannot re-arm a cancelled wait")

let prompt = HookInput(event: "UserPromptSubmit", sessionID: codex.sessionID, turnID: "turn-2")
try HookLogic.apply(HookLogic.action(for: prompt, provider: .codex), input: prompt,
                    owner: nil, store: store, now: now + 7, provider: .codex)
try appendCodex(codexEvent("error", at: now + 8, fields: ["turn_id": "turn-1", "codex_error_info": "usageLimitExceeded"]))
scanCodex()
check(store.load(codex.sessionID)?.state == .working, "late error from a different turn cannot pause new work")
try HookLogic.apply(HookLogic.action(for: codexStop, provider: .codex), input: codexStop,
                    owner: nil, store: store, now: now + 8, provider: .codex)
check(store.load(codex.sessionID)?.state == .working, "late Stop from the previous turn cannot stop new work")
try appendCodex(codexEvent("error", at: now + 8.5,
                          fields: ["turn_id": "turn-2", "codex_error_info": "rateLimitExceeded", "will_retry": true]))
scanCodex()
check(store.load(codex.sessionID)?.state == .working, "transient errors retain the hold while Codex retries")
try appendCodex(codexEvent("error", at: now + 9, fields: ["turn_id": "turn-2", "codex_error_info": "contextWindowExceeded"]))
scanCodex()
check(store.load(codex.sessionID)?.quotaResetAt == nil, "non-quota errors do not schedule a wake")
try appendCodex(codexEvent("task_started", at: now + 10, fields: ["turn_id": "turn-3"]))
try appendCodex(codexEvent("token_count", at: now + 11, fields: ["rate_limits": limits(weekly: 100)]))
try appendCodex(codexEvent("error", at: now + 12, fields: ["turn_id": "turn-3", "codex_error_info": "rateLimitExceeded"]))
scanCodex()
check(store.load(codex.sessionID)?.quotaResetAt == now + 1000, "both exhausted Codex windows must reset")
try appendCodex(codexEvent("task_complete", at: now + 13, fields: ["turn_id": "turn-3"]))
scanCodex()
check(store.load(codex.sessionID)?.quotaResetAt == now + 1000, "end-of-turn bookkeeping preserves a quota pause")
try appendCodex(codexEvent("turn_aborted", at: now + 14, fields: ["turn_id": "turn-3"]))
scanCodex()
check(store.load(codex.sessionID)?.quotaResetAt == nil, "Codex abort cancels the wake")

let partial = try codexEvent("error", at: now + 15,
                            fields: ["turn_id": "turn-3", "codex_error_info": "usage_limit_exceeded"])
try appendCodex(partial.prefix(partial.count / 2))
scanCodex()
check(store.load(codex.sessionID)?.quotaResetAt == nil, "incomplete JSON cannot arm a wake")
try appendCodex(partial.suffix(partial.count - partial.count / 2))
scanCodex()
check(store.load(codex.sessionID)?.quotaResetAt == now + 1000, "partial event is read once completed")
try appendCodex(codexEvent("task_started", at: now + 16, fields: ["turn_id": "turn-4"]))
scanCodex()
check(store.load(codex.sessionID)?.state == .working && store.load(codex.sessionID)?.quotaResetAt == nil,
      "Codex continuation returns to the normal working hold")
// Truncation must not replay an old failure onto the new turn.
try codexEvent("error", at: now, fields: ["turn_id": "turn-1", "codex_error_info": "usage_limit_exceeded"]).write(to: transcript)
scanCodex()
check(store.load(codex.sessionID)?.state == .working, "truncated logs cannot overwrite a newer turn")

// A large response-item line is outside the adapter and does not prevent reading later metadata.
try appendCodex(Data(repeating: 120, count: 1024 * 1024 + 10))
try appendCodex(Data([10]))
try appendCodex(codexEvent("token_count", at: now + 17, fields: ["rate_limits": limits()]))
try appendCodex(codexEvent("error", at: now + 18, fields: ["turn_id": "turn-4", "codex_error_info": "usage_limit_exceeded"]))
scanCodex()
check(store.load(codex.sessionID)?.quotaResetAt == now + 600, "bounded scan skips oversized conversation records")

check(WakeRequest.parse(["clear"], now: now) == .clear, "helper clear")
check(WakeRequest.parse(["set", "2000000600"], now: now) == .set(2_000_000_600), "helper bounded wake")
check(WakeRequest.parse(["set", "2000259200"], now: now) == .set(2_000_259_200), "helper supports T3 multi-day recovery")
for args in [["clear", "extra"], ["set", "2000000600", "extra"], ["set", "+2000000600"],
             ["set", "nan"], ["set", "2000000000"], ["set", "2000604801"], ["set", ""],
             ["set", "99999999999999999999999999999999"], ["shutdown"], ["set", "2000000600;id"]] {
    check(WakeRequest.parse(args, now: now) == nil, "helper rejects malformed, past and out-of-range arguments")
}

// Account switching: another account of the same tool continues a limited conversation.
let main = T3Account(id: "claudeAgent", driver: "claudeAgent", name: "Claude")
let second = T3Account(id: "claudeAgent_second", driver: "claudeAgent", name: "Claude - Second")
let chatGPT = T3Account(id: "codex-personal", driver: "codex", name: "Codex")
let selection = #"{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"effort","value":"xhigh"}]}"#
var threadRecord = try record()
threadRecord.sessionID = "t3:thread"
threadRecord.cwd = "/tmp/project"
@MainActor func limited(failedAt: Double = now - 30, reset: Double = now + 3600, autoResume: Bool? = nil,
             snoozedUntil: Double? = nil, delegated: Bool = false, account: String = "claudeAgent",
             selection: String = selection) -> T3LimitedThread {
    T3LimitedThread(threadID: "thread", runID: "run-1", accountID: account, failedAt: failedAt, resetAt: reset,
                    snoozedUntil: snoozedUntil, autoResume: autoResume, isDelegated: delegated,
                    modelSelection: selection, record: threadRecord)
}
@MainActor func switchPlan(_ threads: [T3LimitedThread], _ accounts: [T3Account] = [main, second, chatGPT],
                limited: [String: Double] = ["claudeAgent": now + 3600], at date: Double = now) -> AccountSwitchPlanner.Plan {
    AccountSwitchPlanner.plan(threads: threads, accounts: accounts, limitedUntil: limited, now: date)
}
var moved = switchPlan([limited()])
check(moved.switches.map(\.to.id) == ["claudeAgent_second"], "switch to the other account of the same tool")
check(moved.switches.first?.project == "project", "switch names the project")
let command = try JSONSerialization.jsonObject(with: moved.switches[0].command) as! [String: Any]
let movedSelection = command["modelSelection"] as! [String: Any]
check(command["type"] as? String == "message.dispatch" && command["manualContinuationOfRunId"] as? String == "run-1",
      "continue the limited run as T3's Resume does")
check(command["commandId"] as? String == "agent-lid-account-switch:thread:run-1"
      && command["messageId"] as? String == command["commandId"] as? String, "stable IDs make redelivery idempotent")
check(movedSelection["instanceId"] as? String == "claudeAgent_second" && movedSelection["model"] as? String == "claude-opus-5-5"
      && (movedSelection["options"] as? [[String: String]])?.first?["value"] == "xhigh", "keep model and options")
check((command["dispatchMode"] as? [String: String])?["type"] == "start_immediately"
      && command["createdBy"] as? String == "user" && (command["text"] as? String)?.contains("Claude - Second") == true,
      "start immediately and tell the agent why")
check(switchPlan([limited()], [main, chatGPT]).switches.isEmpty, "never switch to another tool")
check(switchPlan([limited()], [main, T3Account(id: "claudeAgent_second", driver: "claudeAgent", name: "Off", enabled: false)])
      .switches.isEmpty, "skip disabled accounts")
check(switchPlan([limited(delegated: true)]).switches.isEmpty, "delegated children are left to their parent")
check(switchPlan([limited(autoResume: false)]).switches.isEmpty, "respect a declined recovery")
check(switchPlan([limited(snoozedUntil: now + 60)]).switches.isEmpty, "respect a snooze")
check(switchPlan([limited(failedAt: now - 3600)]).switches.isEmpty, "old unarmed failures stay with T3")
check(switchPlan([limited(failedAt: now - 3600, autoResume: true)]).switches.count == 1, "armed recovery switches at any age")
check(switchPlan([limited(selection: "{}")]).switches.isEmpty, "unreadable selection is not sent")
check(switchPlan([limited()], [main, T3Account(id: "claudeAgent_second", driver: "claudeAgent", name: "Built-in",
                                               configured: false)]).switches.isEmpty,
      "an unconfigured built-in instance may not be signed in")
let projectOff = T3Account(id: "claudeAgent_second", driver: "claudeAgent", name: "Claude - Second",
                           projectEnabled: ["project-a": false])
var inProject = limited()
inProject.projectID = "project-a"
check(switchPlan([inProject], [main, projectOff]).switches.isEmpty, "a project can disable the target")
inProject.projectID = "project-b"
check(switchPlan([inProject], [main, projectOff]).switches.count == 1, "other projects keep the machine-wide setting")
check(AccountSwitchPlanner.plan(threads: [limited()], accounts: [main, second], limitedUntil: [:], now: now,
                                continuationDisabled: true) == .init(), "T3's global opt-out also stops switching")
let custom = T3Account(id: "claudeAgent", driver: "claudeAgent", name: "Claude", customModels: ["claude-opus-5-5"])
check(switchPlan([limited()], [custom, second]).switches.isEmpty, "a custom model must exist on the target")
// Both accounts limited: wake for whichever resets first, after a margin.
moved = switchPlan([limited(reset: now + 7200)], limited: ["claudeAgent": now + 7200, "claudeAgent_second": now + 1800])
check(moved.switches.isEmpty, "no switch while every account is limited")
check(moved.earlierResets["thread"] == .init(at: now + 1860, accountName: "Claude - Second"), "wake for the earlier reset")
check(switchPlan([limited(reset: now + 1800)], limited: ["claudeAgent_second": now + 7200]).earlierResets.isEmpty,
      "the thread's own reset comes first")
check(switchPlan([limited()], limited: ["claudeAgent_second": now - 30]).switches.isEmpty, "wait out the reset margin")
check(switchPlan([limited()], limited: ["claudeAgent_second": now - 61]).switches.count == 1, "switch back after the reset")

// The native record keeps the Mac awake while a switch is delivered.
var waiting = threadRecord
waiting.state = .waiting
var snapshot = T3Monitor.Snapshot()
snapshot.records = [waiting]
snapshot.limitedThreads = [limited()]
snapshot.applyAccountSwitching(delivering: ["thread"], earlierResets: [:], now: now)
check(snapshot.records.map(\.state) == [.working] && snapshot.records.first?.reason == "switching account",
      "delivery keeps the conversation working")
snapshot.records = [waiting]
snapshot.applyAccountSwitching(delivering: [], earlierResets: ["thread": .init(at: now + 300, accountName: "Claude - Second")], now: now)
let earlier = plan(snapshot.records)
check(earlier.nextWakeAt == now + 180 && earlier.nextResetAccountName == "Claude - Second", "wake names the account that resets")
snapshot.limitedThreads = []
snapshot.records = [waiting]
snapshot.applyAccountSwitching(delivering: ["thread"], earlierResets: [:], now: now)
check(snapshot.records.map(\.state) == [.waiting], "a conversation that moved on is left alone")
// Settings > Integrations: what is installed and where the hooks are.
let setupHome = temporary.appendingPathComponent("home")
let setupManifest = temporary.appendingPathComponent("hook-targets.json")
try FileManager.default.createDirectory(at: setupHome, withIntermediateDirectories: true)
// Tools installed on the test machine itself must not count.
check(!Integrations.isInstalled(.claude, home: setupHome, systemFolders: [])
      && !Integrations.isInstalled(.codex, home: setupHome, systemFolders: []), "no tools in an empty home")
try FileManager.default.createDirectory(at: setupHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
check(Integrations.isInstalled(.claude, home: setupHome, systemFolders: []),
      "a Claude config folder means Claude Code is installed")
let bin = temporary.appendingPathComponent("bin")
try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: bin.appendingPathComponent("codex").path, contents: Data(), attributes: [.posixPermissions: 0o755])
check(Integrations.isInstalled(.codex, home: setupHome, systemFolders: [bin.path]), "a codex command counts as installed")
// A stray `defaults write` is clamped instead of crashing the app.
let strayDefaults = UserDefaults(suiteName: "AgentLidClosed.checks.\(getpid())")!
strayDefaults.set(1e20, forKey: "batteryFloorPercent")
strayDefaults.set(Double.infinity, forKey: "sleepGraceSeconds")
strayDefaults.set("-5", forKey: "notifyTimeoutSeconds")
strayDefaults.set("20", forKey: "workingStaleMinutes")
let stray = LidSettings.load(from: strayDefaults)
check(stray.batteryFloor == 100 && stray.sleepGrace == LidSettings().sleepGrace && stray.notifyTimeout == 0
      && stray.workingStale == 20 * 60, "out-of-range settings are clamped; strings still parse")
strayDefaults.removePersistentDomain(forName: "AgentLidClosed.checks.\(getpid())")
var files = Integrations.hookFiles(home: setupHome, manifest: setupManifest)
check(files.map(\.tool) == [.claude, .codex] && files.allSatisfy { $0.isDefault && !$0.hasHooks },
      "default files are listed without hooks")
let hooked = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/Apps/agent-lid-hook"}]}]},"theme":"dark"}"#
try Data(hooked.utf8).write(to: setupHome.appendingPathComponent(".claude/settings.json"))
let work = temporary.appendingPathComponent("work-claude/settings.json").path
try Data(#"{"claude":["\#(work)"],"codex":7}"#.utf8).write(to: setupManifest)
files = Integrations.hookFiles(home: setupHome, manifest: setupManifest)
check(files.map(\.path) == [Integrations.defaultHookFile(.claude, home: setupHome), work,
                            Integrations.defaultHookFile(.codex, home: setupHome)],
      "recorded files of other accounts follow the default")
check(files[0].hasHooks && !files[1].hasHooks && !files[1].isDefault, "hooks are detected per file")
try Data(#"{"hooks":{"Stop":"odd"}}"#.utf8).write(to: setupHome.appendingPathComponent(".claude/settings.json"))
check(!Integrations.hasHooks(atPath: setupHome.appendingPathComponent(".claude/settings.json").path),
      "odd settings read as no hooks")
let t3Directory = temporary.appendingPathComponent("t3")
check(T3Monitor.configuration(directory: t3Directory) == nil, "T3 Code isn't installed without its settings")
try FileManager.default.createDirectory(at: t3Directory, withIntermediateDirectories: true)
try Data(#"{"autoResumeLimitedThreads":false,"providerInstances":{"claudeAgent_second":{"driver":"claudeAgent","displayName":"Work"}}}"#.utf8)
    .write(to: t3Directory.appendingPathComponent("settings.json"))
let t3Setup = T3Monitor.configuration(directory: t3Directory)
check(t3Setup?.continuationDisabled == true
      && t3Setup?.accounts.map(\.id) == ["claudeAgent", "claudeAgent_second", "codex"]
      && t3Setup?.accounts.map(\.name) == ["Claude", "Claude (Work)", "Codex"],
      "T3 accounts and its continuation choice are read without its server")
print("PASS \(checks) quota planning, lifecycle, account switching and setup checks")
