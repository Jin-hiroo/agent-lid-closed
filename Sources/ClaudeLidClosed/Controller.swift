import AppKit
import LidCore
import Observation

/// Keeps the Mac awake, lid closed included, while any Claude Code session is working, and
/// lets it sleep again (right away, if the lid is closed) once they're all waiting for you.
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
    @ObservationIgnored private var loggedSummary = ""

    init() {
        UserDefaults.standard.register(defaults: ["autoEnabled": true])
        autoEnabled = UserDefaults.standard.bool(forKey: "autoEnabled")
    }

    func start() {
        started = true
        try? FileManager.default.createDirectory(at: Paths.sessionsDir, withIntermediateDirectories: true)
        // A hold left behind by a crash: take it over, and evaluate() releases it if nothing needs it.
        if FileManager.default.fileExists(atPath: Paths.holdMarker.path) {
            holding = Power.sleepDisabled
            if !holding { try? FileManager.default.removeItem(at: Paths.holdMarker) }
        }
        Log.write("Started\(Power.dryRun ? " (dry run)" : "")\(holding ? "; sleep still disabled from last run" : "")")

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

    /// On quit: never leave the Mac unable to sleep.
    func shutdown() {
        guard started else { return }
        ticker?.cancel()
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
        let result = Evaluator.evaluate(store.loadAll(), now: now, settings: settings,
                                        isAlive: ProcessLookup.isAlive,
                                        isInterrupted: interrupts.endsWithInterrupt)
        for id in result.deadSessionIDs {
            store.remove(id)
            Log.write("Session \(id.prefix(8)) is gone (Claude Code exited)")
        }
        for key in result.orphanSessionKeys { store.remove(key) }
        evaluation = result
        lidClosed = Power.lidClosed
        sleepDisabled = Power.sleepDisabled
        blocker = currentBlocker()
        logSessionsIfChanged()

        guard !transitioning, Date() >= retryAt else { return }
        if result.keepAwake && blocker == nil {
            pendingSleepAt = nil
            if !holding { transition(hold: true, why: "Claude is working") }
        } else if holding {
            if let blocker {
                pendingSleepAt = nil
                transition(hold: false, why: Self.describe(blocker))
            } else if now >= result.sleepAllowedAt {
                pendingSleepAt = nil
                transition(hold: false, why: result.sessions.isEmpty ? "no Claude sessions" : "Claude is waiting for you")
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
        if holding, let pendingSleepAt {
            let seconds = max(0, Int(pendingSleepAt.timeIntervalSinceNow.rounded(.up)))
            return "Claude is waiting: Mac can sleep in \(seconds) s"
        }
        if holding || evaluation.keepAwake { return "Keeping your Mac awake: Claude is working" }
        return evaluation.sessions.isEmpty ? "No Claude Code sessions: normal sleep" : "Claude is waiting for you: normal sleep"
    }

    var detail: String {
        var text = "Lid \(lidClosed ? "closed" : "open") · system sleep \(sleepDisabled ? "disabled" : "enabled")"
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
            if Power.lidClosed && !Power.hasExternalDisplay {
                Log.write("Lid is closed: sleeping now")
                Power.sleepNow()
            }
        }
    }

    private func currentBlocker() -> Blocker? {
        if !autoEnabled { return .paused }
        if !Power.isSetUp { return .setupNeeded }
        if let battery = Power.battery, battery.onBattery, battery.percent <= settings.batteryFloor {
            return .batteryLow(battery.percent)
        }
        let thermal = ProcessInfo.processInfo.thermalState
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
        let summary = evaluation.sessions.map { "\($0.project) \($0.label)" }.joined(separator: "; ")
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
