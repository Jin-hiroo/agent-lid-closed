import AppKit
import LidCore
import Observation

/// Keeps the Mac awake, lid closed included, while any Claude or Codex session is working, and
/// lets it sleep again (right away, if the lid is closed) once they're all waiting for you.
/// While it's awake with the lid closed, the built-in display's backlight is switched off.
@MainActor
@Observable
final class Controller {
    enum Blocker: Equatable {
        case paused
        case setupNeeded
        case batteryLow(Int)
        case tooHot
    }

    private(set) var evaluation = Evaluation()
    /// This app currently has system sleep disabled.
    private(set) var holding = false
    private(set) var blocker: Blocker?
    /// When the Mac may sleep again, while every session is waiting but the grace period runs.
    private(set) var pendingSleepAt: Date?
    private(set) var lidClosed = false
    private(set) var sleepDisabled = false
    private(set) var lastError: String?
    private(set) var autoEnabled: Bool
    private(set) var dimEnabled: Bool
    private(set) var wakeEnabled: Bool
    private(set) var nextQuotaReset: Date?
    private(set) var nextQuotaAccount: String?
    private(set) var quotaHoldUntil: Date?
    private(set) var quotaHoldingAccounts: [String] = []
    private(set) var wakeError: String?
    private(set) var t3Error: String?
    private(set) var switchEnabled: Bool
    /// The latest account switch, or why it couldn't be made.
    private(set) var switchStatus: String?
    private(set) var t3Running = false
    /// T3 Code has two configured, enabled accounts of the same tool.
    private(set) var switchAvailable = false
    /// This app has turned the built-in display's backlight off.
    private(set) var displayDimmed = false

    /// Restoring never goes below this, so a brightness read of 0 can't leave a black screen.
    private static let minimumRestoredBrightness: Float = 0.1

    @ObservationIgnored private let store = SessionStore()
    @ObservationIgnored private var settings = LidSettings()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var transitioning = false
    /// After a failed pmset call, don't retry before this (no sudo storm if the rule is broken).
    @ObservationIgnored private var retryAt = Date.distantPast
    @ObservationIgnored private var evaluateQueued = false
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var releaseTimer: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var signalSources: [DispatchSourceSignal] = []
    @ObservationIgnored private let interrupts = InterruptCache()
    @ObservationIgnored private let codexQuota = CodexQuotaMonitor()
    @ObservationIgnored private var t3Cache = T3Monitor.Cache()
    @ObservationIgnored private var loggedSummary = ""
    /// Brightness to put back when the lid opens.
    @ObservationIgnored private var savedBrightness: Float?
    @ObservationIgnored private var lidWatcher: Task<Void, Never>?
    @ObservationIgnored private var loggedDisplayError = ""
    @ObservationIgnored private var scheduledWakeAt: Double?
    @ObservationIgnored private var lastT3WakeAt: Double?
    @ObservationIgnored private var wakeSynchronized = false
    @ObservationIgnored private var wakeRetryAt = Date.distantPast
    /// Account switches by T3 thread ID, until the conversation leaves the limited run.
    @ObservationIgnored private var switches: [String: SwitchAttempt] = [:]
    @ObservationIgnored private var lastSwitchAt: [String: Double] = [:]

    private struct SwitchAttempt {
        enum Phase: Equatable {
            case delivering
            case accepted(at: Double)
            case retrying(at: Double)
            case abandoned
        }
        static let acceptedHold: Double = 120
        var runID: String
        var to: String
        var phase = Phase.delivering
        var failures = 0

        /// The Mac stays awake until T3 starts the continued run, or delivery gives up.
        func keepsAwake(now: Double) -> Bool {
            switch phase {
            case .delivering: true
            case .retrying(let at): now < at + Controller.retryDelay
            case .accepted(let at): now - at < Self.acceptedHold
            case .abandoned: false
            }
        }
    }

    nonisolated private static let retryDelay: Double = 30
    private static let maximumDeliveryFailures = 3
    /// One conversation moves at most this often, even if its accounts' reset times are wrong.
    private static let switchInterval: Double = 600

    init() {
        Paths.migratePreferences(to: .standard)
        UserDefaults.standard.register(defaults: ["autoEnabled": true, "dimDisplay": true, "wakeForQuotaReset": true,
                                                  "switchAccountAtLimit": true])
        autoEnabled = UserDefaults.standard.bool(forKey: "autoEnabled")
        dimEnabled = UserDefaults.standard.bool(forKey: "dimDisplay")
        wakeEnabled = UserDefaults.standard.bool(forKey: "wakeForQuotaReset")
        switchEnabled = UserDefaults.standard.bool(forKey: "switchAccountAtLimit")
    }

    func start() {
        started = true
        try? FileManager.default.createDirectory(at: Paths.sessionsDir, withIntermediateDirectories: true)
        // A hold left behind by a crash: take it over, and evaluate() releases it if nothing needs it.
        if FileManager.default.fileExists(atPath: Paths.holdMarker.path) {
            holding = Power.sleepDisabled
            if !holding { try? FileManager.default.removeItem(at: Paths.holdMarker) }
        }
        // A dimmed display left behind by a crash: take it over, and evaluate() restores it once the lid is open.
        if let data = try? Data(contentsOf: Paths.dimMarker),
           let saved = Float(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
            savedBrightness = saved
            displayDimmed = true
        }
        Log.write("Started\(Power.dryRun ? " (dry run)" : "")\(holding ? "; sleep still disabled from last run" : "")\(displayDimmed ? "; display still dimmed from last run" : "")")

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.evaluate()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
        // launchctl, logout and Ctrl-C all go through applicationWillTerminate, which re-enables sleep.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
        evaluate()
    }

    /// On quit: never leave the Mac unable to sleep or the display dark.
    func shutdown() {
        guard started else { return }
        ticker?.cancel()
        if Power.wakeIsSetUp, let error = Power.setScheduledWake(nil) { Log.write(error) }
        if displayDimmed { restoreDisplay() }
        guard holding else { return }
        if Power.allowSleepNow() {
            holding = false
            try? FileManager.default.removeItem(at: Paths.holdMarker)
            Log.write("Quit: sleep allowed again")
        } else {
            Log.write("Quit: could not re-enable sleep. Run `sudo pmset -a disablesleep 0`")
        }
    }

    func setAutoEnabled(_ enabled: Bool) {
        autoEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoEnabled")
        Log.write("Automatic mode \(enabled ? "on" : "off")")
        evaluate()
    }

    func setDimEnabled(_ enabled: Bool) {
        dimEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "dimDisplay")
        Log.write("Dim display with lid closed \(enabled ? "on" : "off")")
        updateDisplayDimming()
    }

    func setWakeEnabled(_ enabled: Bool) {
        wakeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "wakeForQuotaReset")
        Log.write("Wake for usage resets \(enabled ? "on" : "off")")
        evaluate()
    }

    func setSwitchEnabled(_ enabled: Bool) {
        switchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "switchAccountAtLimit")
        Log.write("Switch accounts at usage limits \(enabled ? "on" : "off")")
        if !enabled { switchStatus = nil }
        evaluate()
    }

    func evaluate() {
        if watcher == nil {
            try? FileManager.default.createDirectory(at: Paths.sessionsDir, withIntermediateDirectories: true)
            watcher = DirectoryWatcher(url: Paths.sessionsDir) { [weak self] directoryGone in
                if directoryGone { self?.watcher = nil }
                self?.queueEvaluate()
            }
        }
        let now = Date().timeIntervalSince1970
        settings = LidSettings.load(from: .standard)
        codexQuota.refresh(store: store, now: now, isAlive: ProcessLookup.isAlive)
        var t3 = t3Cache.resolve(T3Monitor.read(now: now), now: now)
        t3Error = t3.error
        t3Running = t3.isRunning
        if t3.error == nil { switchAvailable = Self.canSwitch(t3.accounts) }
        updateAccountSwitches(&t3, now: now)
        let contents = t3.merging(store.loadAll())
        let result = Evaluator.evaluate(contents, now: now, settings: settings,
                                        isAlive: ProcessLookup.isAlive,
                                        isInterrupted: interrupts.endsWithInterrupt)
        for id in result.deadSessionIDs {
            store.remove(id)
            Log.write("Session \(AgentProvider.shortSessionID(id)) is gone (agent process exited)")
        }
        for key in result.orphanSessionKeys { store.remove(key) }
        evaluation = result
        lidClosed = Power.lidClosed
        sleepDisabled = Power.sleepDisabled
        blocker = currentBlocker()
        let plan = wakeEnabled && blocker == nil
            ? QuotaWakePlan.evaluate(contents.records, now: now, isAlive: ProcessLookup.isAlive)
            : QuotaWakePlan.evaluate([], now: now, isAlive: ProcessLookup.isAlive)
        if t3.error == nil {
            lastT3WakeAt = QuotaWakePlan.evaluate(t3.records, now: now, isAlive: ProcessLookup.isAlive).nextWakeAt
        }
        nextQuotaReset = plan.nextResetAt.map(Date.init(timeIntervalSince1970:))
        nextQuotaAccount = plan.nextResetAccountName
        quotaHoldUntil = plan.holdUntil.map(Date.init(timeIntervalSince1970:))
        quotaHoldingAccounts = plan.holdingAccountNames
        // Failed telemetry cannot cancel a known future alarm. Explicit pause,
        // disable and safety blockers still cancel it immediately.
        let desiredWake: Double?
        if t3.error != nil, wakeEnabled, blocker == nil,
           let lastT3WakeAt, lastT3WakeAt > now + 5 {
            desiredWake = min(plan.nextWakeAt ?? lastT3WakeAt, lastT3WakeAt)
        } else {
            desiredWake = plan.nextWakeAt
        }
        synchronizeWake(desiredWake)
        logSessionsIfChanged()
        updateDisplayDimming()

        guard !transitioning, Date() >= retryAt else { return }
        if (result.keepAwake || quotaHoldUntil != nil) && blocker == nil {
            pendingSleepAt = nil
            if !holding { transition(hold: true, why: quotaHoldUntil != nil ? "usage resets shortly" : "an agent is working") }
        } else if holding {
            if let blocker {
                pendingSleepAt = nil
                transition(hold: false, why: Self.describe(blocker))
            } else if now >= result.sleepAllowedAt {
                pendingSleepAt = nil
                transition(hold: false, why: result.sessions.isEmpty ? "no agent sessions" : "all agents are waiting for you")
            } else {
                let at = Date(timeIntervalSince1970: result.sleepAllowedAt)
                if at != pendingSleepAt { evaluate(at: at) }
                pendingSleepAt = at
            }
        } else {
            pendingSleepAt = nil
        }
    }

    // MARK: Menu text

    var headline: String {
        if let blocker { return Self.describe(blocker) }
        if quotaHoldUntil != nil {
            let providers = quotaHoldingAccounts.joined(separator: " and ")
            return "Keeping your Mac awake for \(providers)'s usage reset"
        }
        if holding, let pendingSleepAt {
            let seconds = max(0, Int(pendingSleepAt.timeIntervalSinceNow.rounded(.up)))
            return "Agents are waiting: Mac can sleep in \(seconds) s"
        }
        if holding || evaluation.keepAwake { return "Keeping your Mac awake: an agent is working" }
        if nextQuotaReset != nil { return "Waiting for an agent's usage reset: normal sleep" }
        return evaluation.sessions.isEmpty ? "No agent sessions: normal sleep" : "All agents are waiting for you: normal sleep"
    }

    var detail: String {
        var text = "Lid \(lidClosed ? "closed" : "open") · system sleep \(sleepDisabled ? "disabled" : "enabled")"
        if displayDimmed { text += " · display off" }
        if let nextQuotaReset {
            text += "\n\(nextQuotaAccount ?? "Agent") usage resets \(nextQuotaReset.formatted(date: .abbreviated, time: .shortened))"
        }
        if wakeEnabled && !Power.wakeIsSetUp { text += "\nWake setup needed: run scripts/install.sh" }
        if let wakeError { text += "\n\(wakeError)" }
        if let t3Error { text += "\n\(t3Error)" }
        if let switchStatus { text += "\n\(switchStatus)" }
        if let lastError { text += "\n\(lastError)" }
        return text
    }

    var symbolName: String {
        switch blocker {
        case .paused: return "pause.circle"
        case .setupNeeded, .batteryLow, .tooHot: return "exclamationmark.triangle"
        case nil: break
        }
        if holding { return pendingSleepAt == nil ? "cup.and.saucer.fill" : "hourglass" }
        return "moon.zzz"
    }

    // MARK: Private

    /// Moves T3 conversations blocked by one account's usage limit to another account of
    /// the same tool and continues them there. Without an available account, the wake is
    /// brought forward to the earliest reset of another account.
    private func updateAccountSwitches(_ t3: inout T3Monitor.Snapshot, now: Double) {
        if t3.error == nil {
            // A new run, archive or settlement ends the attempt for that limited run.
            let limitedRuns = Dictionary(t3.limitedThreads.map { ($0.threadID, $0.runID) },
                                         uniquingKeysWith: { first, _ in first })
            switches = switches.filter { limitedRuns[$0.key] == $0.value.runID }
            lastSwitchAt = lastSwitchAt.filter { now - $0.value < Self.switchInterval }
        }
        var earlierResets: [String: AccountSwitchPlanner.EarlierReset] = [:]
        if t3.error == nil {
            let plan = switchPlan(t3, now: now)
            earlierResets = plan.earlierResets
            // A retry is dropped once its switch is no longer wanted, for example
            // after turning switching off or when the target becomes limited.
            let planned = Dictionary(plan.switches.map { ($0.threadID, $0) }, uniquingKeysWith: { first, _ in first })
            switches = switches.filter { id, attempt in
                guard case .retrying = attempt.phase else { return true }
                return planned[id].map { $0.runID == attempt.runID && $0.to.id == attempt.to } ?? false
            }
            let due = plan.switches.filter { candidate in
                guard let attempt = switches[candidate.threadID] else {
                    return lastSwitchAt[candidate.threadID] == nil
                }
                if case .retrying(let at) = attempt.phase { return now >= at }
                return false
            }
            if !due.isEmpty { deliver(due, now: now) }
        }
        let delivering = Set(switches.filter { $0.value.keepsAwake(now: now) }.keys)
        t3.applyAccountSwitching(delivering: delivering, earlierResets: earlierResets, now: now)
    }

    static func canSwitch(_ accounts: [T3Account]) -> Bool {
        Dictionary(grouping: accounts.filter { $0.configured && $0.enabled }, by: \.driver).values.contains { $0.count > 1 }
    }

    private func switchPlan(_ t3: T3Monitor.Snapshot, now: Double) -> AccountSwitchPlanner.Plan {
        guard switchEnabled else { return AccountSwitchPlanner.Plan() }
        return AccountSwitchPlanner.plan(threads: t3.limitedThreads, accounts: t3.accounts,
                                         limitedUntil: t3.limitedUntil, now: now,
                                         continuationDisabled: t3.continuationDisabled)
    }

    private func deliver(_ due: [AccountSwitch], now: Double) {
        for item in due {
            var attempt = switches[item.threadID] ?? SwitchAttempt(runID: item.runID, to: item.to.id)
            attempt.phase = .delivering
            switches[item.threadID] = attempt
            // Counted from the first try, so a slow reply can't let the conversation move again.
            if lastSwitchAt[item.threadID] == nil { lastSwitchAt[item.threadID] = now }
            Log.write("\(item.from.name) reached its usage limit: moving \(item.project) to \(item.to.name)")
        }
        let commands = due.map { (id: $0.commandID, json: $0.command) }
        Task {
            let outcomes = await T3Commands.dispatch(commands, directory: T3Monitor.defaultDirectory) {
                await self.stillWanted(due)
            }
            finishDelivery(due, outcomes)
        }
    }

    /// Re-reads T3 just before sending. A snooze, settlement, opt-out, new run, model
    /// change or toggle change made while the credential was issued withdraws the switch.
    private func stillWanted(_ due: [AccountSwitch]) -> Set<String> {
        let now = Date().timeIntervalSince1970
        let t3 = T3Monitor.read(now: now)
        guard t3.error == nil else { return [] }
        let current = switchPlan(t3, now: now).switches
        return Set(due.filter { current.contains($0) }.map(\.commandID))
    }

    private func finishDelivery(_ delivered: [AccountSwitch], _ outcomes: [String: T3Commands.Outcome]) {
        let now = Date().timeIntervalSince1970
        for item in delivered {
            // A newer limited run of the same conversation has its own attempt.
            if let current = switches[item.threadID], current.runID != item.runID { continue }
            var attempt = switches[item.threadID] ?? SwitchAttempt(runID: item.runID, to: item.to.id)
            switch outcomes[item.commandID] ?? .failed("No reply from T3 Code") {
            case .accepted:
                attempt.phase = .accepted(at: now)
                switchStatus = "Moved \(item.project) to \(item.to.name)"
                Log.write("Continued \(item.project) on \(item.to.name)")
            case .withdrawn:
                switches[item.threadID] = nil
                lastSwitchAt[item.threadID] = nil
                Log.write("Didn't move \(item.project): it changed before the switch was sent")
                continue
            case .rejected(let reason):
                attempt.phase = .abandoned
                switchStatus = "Couldn't move \(item.project) to \(item.to.name): \(reason)"
                Log.write("T3 refused to move \(item.project) to \(item.to.name): \(reason)")
            case .failed(let reason):
                attempt.failures += 1
                if attempt.failures >= Self.maximumDeliveryFailures {
                    attempt.phase = .abandoned
                    switchStatus = "Couldn't move \(item.project) to \(item.to.name): \(reason)"
                    Log.write("Gave up moving \(item.project) to \(item.to.name): \(reason)")
                } else {
                    attempt.phase = .retrying(at: now + Self.retryDelay)
                    Log.write("Couldn't move \(item.project) to \(item.to.name) yet: \(reason)")
                }
            }
            switches[item.threadID] = attempt
        }
        evaluate()
    }

    private func synchronizeWake(_ desired: Double?) {
        guard Power.wakeIsSetUp, Date() >= wakeRetryAt,
              !wakeSynchronized || desired != scheduledWakeAt else { return }
        if let error = Power.setScheduledWake(desired) {
            if error != wakeError { Log.write(error) }
            wakeError = error
            wakeRetryAt = Date().addingTimeInterval(30)
            return
        }
        wakeError = nil
        wakeRetryAt = .distantPast
        scheduledWakeAt = desired
        wakeSynchronized = true
        if let desired {
            Log.write("Wake scheduled for usage reset: \(Date(timeIntervalSince1970: desired))")
        } else {
            Log.write("Usage wake cleared")
        }
    }

    /// Re-evaluates right when the grace period ends, rather than on the next 5 s tick.
    private func evaluate(at date: Date) {
        releaseTimer?.cancel()
        releaseTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow) + 0.05))
            if !Task.isCancelled { self?.evaluate() }
        }
    }

    private func queueEvaluate() {
        guard !evaluateQueued else { return }
        evaluateQueued = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            evaluateQueued = false
            evaluate()
        }
    }

    private func transition(hold: Bool, why: String) {
        transitioning = true
        Task {
            defer {
                transitioning = false
                evaluate()
            }
            if let error = await Power.setSleepDisabled(hold) {
                if error != lastError { Log.write(error) }
                lastError = error
                retryAt = Date().addingTimeInterval(30)
                return
            }
            lastError = nil
            retryAt = .distantPast
            holding = hold
            sleepDisabled = Power.sleepDisabled
            if hold {
                FileManager.default.createFile(atPath: Paths.holdMarker.path, contents: nil)
                Log.write("Keeping Mac awake: \(why)")
                return
            }
            try? FileManager.default.removeItem(at: Paths.holdMarker)
            Log.write("Sleep allowed: \(why)")
            // Hooks or a quota warm-up can arrive while pmset runs. Refresh before an
            // explicit sleep so we don't put a newly active session back to sleep.
            evaluate()
            let maySleep = blocker != nil || (!evaluation.keepAwake && quotaHoldUntil == nil
                && Date().timeIntervalSince1970 >= evaluation.sleepAllowedAt)
            if maySleep && Power.lidClosed && !Power.hasExternalDisplay {
                Log.write("Lid is closed: sleeping now")
                Power.sleepNow()
            }
        }
    }

    /// Backlight off while the lid is closed and this app is keeping the Mac awake, back on when the
    /// lid opens. Once dimmed it stays dimmed until then, even if sleep comes back and the Mac
    /// goes to sleep, so waking it with the lid open is what undoes it. With an external display
    /// the lid means clamshell mode, where macOS already turns the built-in panel off.
    private func updateDisplayDimming() {
        let wanted = dimEnabled && Power.lidClosed && (holding || displayDimmed) && !Power.hasExternalDisplay
        if wanted && !displayDimmed {
            dimDisplay()
        } else if !wanted && displayDimmed {
            restoreDisplay()
        }
        if displayDimmed && lidWatcher == nil { watchLid() }
    }

    /// While dimmed, notices the lid opening within half a second rather than on the next 5 s tick.
    private func watchLid() {
        lidWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.updateDisplayDimming()
            }
        }
    }

    private func dimDisplay() {
        guard let current = Power.displayBrightness else { return logDisplayError("Could not read the display brightness") }
        // Marker first: if the app dies between here and the restore, the next launch puts it back.
        try? Data("\(current)".utf8).write(to: Paths.dimMarker)
        guard Power.setDisplayBrightness(0) else {
            try? FileManager.default.removeItem(at: Paths.dimMarker)
            return logDisplayError("Could not turn the display off")
        }
        loggedDisplayError = ""
        savedBrightness = current
        displayDimmed = true
        Log.write("Lid closed: display off (was \(Int((current * 100).rounded()))%)")
    }

    private func restoreDisplay() {
        let level = max(savedBrightness ?? 0.5, Self.minimumRestoredBrightness)
        guard Power.setDisplayBrightness(level) else { return logDisplayError("Could not turn the display back on") }
        loggedDisplayError = ""
        lidWatcher?.cancel()
        lidWatcher = nil
        savedBrightness = nil
        displayDimmed = false
        try? FileManager.default.removeItem(at: Paths.dimMarker)
        Log.write("Display back on at \(Int((level * 100).rounded()))%")
    }

    /// Logs a failure once, not on every retry.
    private func logDisplayError(_ message: String) {
        guard message != loggedDisplayError else { return }
        loggedDisplayError = message
        Log.write(message)
    }

    private func currentBlocker() -> Blocker? {
        if !autoEnabled { return .paused }
        if !Power.isSetUp { return .setupNeeded }
        if let battery = Power.battery, battery.onBattery, battery.percent <= settings.batteryFloor {
            return .batteryLow(battery.percent)
        }
        let thermal = Power.thermalState
        if thermal == .serious || thermal == .critical { return .tooHot }
        return nil
    }

    private static func describe(_ blocker: Blocker) -> String {
        switch blocker {
        case .paused: "Automatic mode is off"
        case .setupNeeded: "Setup needed: run scripts/install.sh"
        case .batteryLow(let percent): "Battery at \(percent)%: sleep allowed"
        case .tooHot: "Mac is too hot: sleep allowed"
        }
    }

    private func logSessionsIfChanged() {
        let summary = evaluation.sessions.map { "\($0.accountName) · \($0.project) \($0.label)" }.joined(separator: "; ")
        guard summary != loggedSummary else { return }
        loggedSummary = summary
        Log.write("Sessions: \(summary.isEmpty ? "none" : summary)")
    }
}

/// Re-reads a transcript only when it has changed.
@MainActor
final class InterruptCache {
    private var cache: [String: (modified: Date, size: Int, interrupted: Bool)] = [:]

    func endsWithInterrupt(_ path: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let size = attributes?[.size] as? Int ?? 0
        if let hit = cache[path], hit.modified == modified, hit.size == size { return hit.interrupted }
        let interrupted = Transcript.endsWithInterrupt(path: path)
        cache[path] = (modified, size, interrupted)
        return interrupted
    }
}

/// Calls back on the main queue when files are added, replaced or removed in a directory.
@MainActor
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @MainActor (_ directoryGone: Bool) -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak source] in
            let gone = source.map { !$0.data.isDisjoint(with: [.delete, .rename]) } ?? false
            if gone { source?.cancel() }
            MainActor.assumeIsolated { onChange(gone) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    isolated deinit {
        source.cancel()
    }
}
