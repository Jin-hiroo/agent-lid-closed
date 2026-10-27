import AppKit
import LidCore
import SwiftUI

/// What is set up on this Mac, refreshed when Settings opens or changes something.
@MainActor
@Observable
final class SetupStatus {
    private(set) var hookFiles: [Integrations.HookFile] = []
    private(set) var claudeInstalled = false
    private(set) var codexInstalled = false
    private(set) var t3Installed = false
    private(set) var t3Accounts: [T3Account] = []
    private(set) var t3ContinuationDisabled = false
    private(set) var powerSetUp = false
    private(set) var wakeSetUp = false
    private(set) var loginItemInstalled = false
    private(set) var startsAtLogin = true
    /// Result of the last action, or why it failed.
    private(set) var message: String?
    /// A hook change is running; the buttons that change hooks wait for it.
    private(set) var busy = false

    func refresh() {
        hookFiles = Integrations.hookFiles()
        claudeInstalled = Integrations.isInstalled(.claude)
        codexInstalled = Integrations.isInstalled(.codex)
        let t3 = T3Monitor.configuration()
        t3Installed = t3 != nil
        t3Accounts = t3?.accounts ?? []
        t3ContinuationDisabled = t3?.continuationDisabled ?? false
        powerSetUp = Power.isSetUp
        wakeSetUp = Power.wakeIsSetUp
        loginItemInstalled = LoginItem.isInstalled
        startsAtLogin = LoginItem.isEnabled
    }

    func files(for tool: AgentProvider) -> [Integrations.HookFile] {
        hookFiles.filter { $0.tool == tool }
    }

    /// Accounts by tool, for tools with more than one configured, enabled account.
    var switchableAccounts: [(tool: String, names: [String])] {
        let usable = t3Accounts.filter { $0.configured && $0.enabled }
        let byDriver = Dictionary(grouping: usable, by: \.driver).filter { $0.value.count > 1 }
        var groups: [(tool: String, names: [String])] = []
        for (driver, accounts) in byDriver {
            groups.append((tool: driver == "codex" ? "Codex" : "Claude", names: accounts.map(\.name)))
        }
        return groups.sorted { $0.tool < $1.tool }
    }

    func addHooks(_ tool: AgentProvider, to path: String) {
        changeHooks {
            await HookSetup.install(tool, into: path)
                ?? "Added hooks to \(Setup.displayPath(path)). " + (tool == .claude
                    ? "Restart open Claude Code sessions to use them."
                    : "In Codex, open /hooks and trust them.")
        }
    }

    func removeHooks(from path: String) {
        changeHooks { await HookSetup.remove(from: path) ?? "Removed hooks from \(Setup.displayPath(path))." }
    }

    private func changeHooks(_ change: @escaping @MainActor () async -> String) {
        guard !busy else { return }
        busy = true
        Task {
            message = await change()
            busy = false
            refresh()
        }
    }

    /// Another Claude account run with CLAUDE_CONFIG_DIR=<folder>.
    func addClaudeFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Claude Code Config Folder"
        panel.message = "Choose the folder you set as CLAUDE_CONFIG_DIR for another Claude account."
        panel.prompt = "Add Hooks"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = Integrations.home
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        addHooks(.claude, to: folder.appendingPathComponent("settings.json").path)
    }

    func setStartsAtLogin(_ enabled: Bool) {
        message = LoginItem.setEnabled(enabled)
        refresh()
    }
}

struct SettingsView: View {
    let controller: Controller
    @State private var status = SetupStatus()
    /// A dry run can open another tab, for screenshots.
    @State private var tab = Power.dryRun ? Int(ProcessInfo.processInfo.environment["AGENT_LID_SETTINGS_TAB"] ?? "") ?? 0 : 0

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(controller: controller, status: status)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            TimingSettings()
                .tabItem { Label("Timing", systemImage: "timer") }.tag(1)
            UsageLimitSettings(controller: controller, status: status)
                .tabItem { Label("Usage Limits", systemImage: "gauge.with.dots.needle.67percent") }.tag(2)
            IntegrationSettings(status: status)
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }.tag(3)
        }
        .frame(width: 560, height: 500)
        .onAppear { status.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            status.refresh()
        }
    }
}

private struct GeneralSettings: View {
    let controller: Controller
    let status: SetupStatus
    @AppStorage("batteryFloorPercent") private var batteryFloor = LidSettings().batteryFloor

    var body: some View {
        Form {
            Section {
                Toggle("Keep the Mac awake while agents work", isOn: Binding(
                    get: { controller.autoEnabled }, set: { controller.setAutoEnabled($0) }))
                Toggle("Turn the display off when the lid is closed", isOn: Binding(
                    get: { controller.dimEnabled }, set: { controller.setDimEnabled($0) }))
                Toggle("Start at login", isOn: Binding(
                    get: { status.startsAtLogin }, set: { status.setStartsAtLogin($0) }))
                    .disabled(!status.loginItemInstalled)
            } footer: {
                Text("While an agent works, the Mac stays awake even with the lid closed. When every agent is waiting for you, it sleeps normally. Quitting the app restores normal sleep.")
                    .settingsFootnote()
            }
            Section {
                Stepper(value: $batteryFloor, in: 0...50, step: 5) {
                    Text(batteryFloor == 0 ? "Keep working on battery until it runs out"
                         : "Allow sleep on battery at \(batteryFloor)% or less")
                }
            } header: {
                Text("Battery")
            } footer: {
                Text("Serious heat also allows sleep, whatever this setting is.").settingsFootnote()
            }
            if !status.powerSetUp {
                Section {
                    Label("Sleep control isn't set up. Run scripts/install.sh from the source folder; it asks for your administrator password once.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if let message = status.message { Section { Text(message).settingsFootnote() } }
        }
        .formStyle(.grouped)
    }
}

private struct TimingSettings: View {
    private static let defaults = LidSettings()
    @AppStorage("sleepGraceSeconds") private var sleepGrace = defaults.sleepGrace
    @AppStorage("notifyTimeoutSeconds") private var notifyTimeout = defaults.notifyTimeout
    @AppStorage("workingStaleMinutes") private var workingStale = defaults.workingStale / 60
    @AppStorage("backgroundStaleMinutes") private var backgroundStale = defaults.backgroundStale / 60

    var body: some View {
        Form {
            Section {
                // String(format:) rather than Int(_:), which traps on a huge stored value.
                Stepper(value: $sleepGrace, in: 0...300, step: 5) {
                    LabeledContent("Sleep after agents start waiting", value: String(format: "%.0f s", sleepGrace))
                }
                Stepper(value: $notifyTimeout, in: 0...300, step: 10) {
                    LabeledContent("Wait for Claude's notification",
                                   value: notifyTimeout == 0 ? "Off" : String(format: "up to %.0f s", notifyTimeout))
                }
            } header: {
                Text("When work finishes")
            } footer: {
                Text("Claude Code sends its \"waiting for your input\" notification about a minute after it stops. Waiting for it lets the notification reach your phone before the Mac sleeps. Codex doesn't need this wait.")
                    .settingsFootnote()
            }
            Section {
                Stepper(value: $workingStale, in: 5...240, step: 5) {
                    LabeledContent("Stop waiting for silent work after", value: String(format: "%.0f min", workingStale))
                }
                Stepper(value: $backgroundStale, in: 5...480, step: 5) {
                    LabeledContent("Stop waiting for background tasks after", value: String(format: "%.0f min", backgroundStale))
                }
            } header: {
                Text("Stuck sessions")
            } footer: {
                Text("A session that reports no activity for this long no longer keeps the Mac awake, in case it crashed without saying so.")
                    .settingsFootnote()
            }
            Section {
                Button("Restore Defaults") {
                    for key in ["sleepGraceSeconds", "notifyTimeoutSeconds", "workingStaleMinutes", "backgroundStaleMinutes"] {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                    sleepGrace = Self.defaults.sleepGrace
                    notifyTimeout = Self.defaults.notifyTimeout
                    workingStale = Self.defaults.workingStale / 60
                    backgroundStale = Self.defaults.backgroundStale / 60
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct UsageLimitSettings: View {
    let controller: Controller
    let status: SetupStatus

    var body: some View {
        Form {
            Section {
                Toggle("Wake the Mac before usage resets", isOn: Binding(
                    get: { controller.wakeEnabled }, set: { controller.setWakeEnabled($0) }))
                if !status.wakeSetUp {
                    Label("Wake alarms aren't set up. Run scripts/install.sh.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("When Claude Code or Codex stops at a subscription limit, the Mac sleeps and wakes two minutes before the limit resets, so the session can continue.")
                    .settingsFootnote()
            }
            Section {
                // Shows off while it can't apply; the saved choice returns once it can.
                Toggle("Switch to another account at a usage limit", isOn: Binding(
                    get: { canSwitch && controller.switchEnabled }, set: { controller.setSwitchEnabled($0) }))
                    .disabled(!canSwitch)
                ForEach(status.switchableAccounts, id: \.tool) { group in
                    LabeledContent(group.tool, value: group.names.joined(separator: ", "))
                }
                if let note = availabilityNote {
                    Text(note).settingsFootnote()
                }
                if let result = controller.switchStatus { Text(result).settingsFootnote() }
            } header: {
                Text("T3 Code")
            } footer: {
                Text("A conversation that hits one account's limit continues right away on another account of the same tool, instead of waiting for the reset.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
    }

    private var canSwitch: Bool { !status.switchableAccounts.isEmpty && !status.t3ContinuationDisabled }

    private var availabilityNote: String? {
        if !status.t3Installed {
            return "Needs T3 Code with two accounts of one tool, such as two Claude subscriptions."
        }
        if status.switchableAccounts.isEmpty {
            return "Add a second Claude or Codex account in T3 Code's provider settings to use this."
        }
        if status.t3ContinuationDisabled {
            return "Turn on automatic continuation after usage limits in T3 Code's settings to use this."
        }
        return nil
    }
}

private struct IntegrationSettings: View {
    let status: SetupStatus

    var body: some View {
        Form {
            Section {
                ForEach(status.files(for: .claude)) { HookRow(file: $0, status: status) }
                Button("Add Config Folder for Another Account…") { status.addClaudeFolder() }
                    .disabled(status.busy)
            } header: {
                Text("Claude Code")
            } footer: {
                Text(status.claudeInstalled || status.files(for: .claude).contains(where: \.hasHooks)
                     ? "Hooks report each session's activity, and the status line records when usage limits reset. Restart open sessions after a change."
                     : "Claude Code wasn't found on this Mac.")
                    .settingsFootnote()
            }
            Section {
                ForEach(status.files(for: .codex)) { HookRow(file: $0, status: status) }
            } header: {
                Text("Codex")
            } footer: {
                Text(status.codexInstalled || status.files(for: .codex).contains(where: \.hasHooks)
                     ? "After adding hooks, open /hooks in Codex and trust them; Codex skips untrusted hooks."
                     : "Codex wasn't found on this Mac.")
                    .settingsFootnote()
            }
            Section {
                LabeledContent("Conversations") {
                    StatusText(ok: status.t3Installed, text: status.t3Installed ? "Tracked directly, no hooks needed" : "T3 Code not installed")
                }
                if status.t3Installed {
                    LabeledContent("Continue after usage limits") {
                        StatusText(ok: !status.t3ContinuationDisabled,
                                   text: status.t3ContinuationDisabled ? "Off in T3 Code's settings" : "On")
                    }
                }
            } header: {
                Text("T3 Code")
            }
            Section {
                LabeledContent("Sleep control") {
                    StatusText(ok: status.powerSetUp, text: status.powerSetUp ? "Set up" : "Run scripts/install.sh")
                }
                LabeledContent("Wake alarms") {
                    StatusText(ok: status.wakeSetUp, text: status.wakeSetUp ? "Set up" : "Run scripts/install.sh")
                }
            } header: {
                Text("Power")
            } footer: {
                Text("install.sh adds a rule that lets this app turn lid-closed sleep on and off, and a helper that can only set this app's wake alarms. It asks for your administrator password once.")
                    .settingsFootnote()
            }
            Section {
                if let message = status.message { Text(message).settingsFootnote() }
                HStack {
                    Button("Open Log") { NSWorkspace.shared.open(Paths.logFile) }
                    Button("Refresh") { status.refresh() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HookRow: View {
    let file: Integrations.HookFile
    let status: SetupStatus

    var body: some View {
        LabeledContent {
            HStack {
                StatusText(ok: file.hasHooks, text: file.hasHooks ? "Hooks added" : "No hooks")
                if file.hasHooks {
                    Button("Remove") { status.removeHooks(from: file.path) }
                } else {
                    Button("Add") { status.addHooks(file.tool, to: file.path) }
                }
            }
            .disabled(status.busy)
        } label: {
            Text(Setup.displayPath(file.path)).truncationMode(.middle).lineLimit(1)
        }
    }
}

private struct StatusText: View {
    let ok: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(ok ? .green : .secondary)
    }
}

private extension Text {
    func settingsFootnote() -> some View {
        font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
