import AppKit
import LidCore
import SwiftUI

@main
struct AgentLidClosedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller, openSettings: appDelegate.showSettings)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()
    private var settingsWindow: NSWindow?

    /// A plain AppKit window: a menu bar app can't reliably bring SwiftUI's Settings scene forward.
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(controller: controller)))
            window.title = "Agent Lid Closed Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would fight over the same system setting.
        let others = [Paths.bundleID, Paths.legacyBundleID].flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }
            .filter { $0.processIdentifier != getpid() }
        guard Power.dryRun || others.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        controller.start()
        // For screenshots and UI checks of a dry-run copy.
        if Power.dryRun, ProcessInfo.processInfo.environment["AGENT_LID_OPEN_SETTINGS"] == "1" { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

struct MenuBarIcon: View {
    let controller: Controller

    var body: some View {
        Image(systemName: controller.symbolName)
    }
}

struct MenuContent: View {
    let controller: Controller
    let openSettings: () -> Void

    var body: some View {
        Text(controller.headline)
        Text(controller.detail)
        Divider()
        if controller.evaluation.sessions.isEmpty {
            Text("No agent sessions")
        } else {
            ForEach(controller.evaluation.sessions) { session in
                Text("\(session.accountName) · \(session.project): \(session.label) · \(Self.age(session.since))")
            }
        }
        Divider()
        Toggle("Automatic Mode", isOn: Binding(get: { controller.autoEnabled },
                                               set: { controller.setAutoEnabled($0) }))
        Toggle("Turn Display Off When Lid Closed", isOn: Binding(get: { controller.dimEnabled },
                                                                 set: { controller.setDimEnabled($0) }))
        Toggle("Wake for Usage Resets", isOn: Binding(get: { controller.wakeEnabled },
                                                    set: { controller.setWakeEnabled($0) }))
        if controller.switchAvailable {
            Toggle("Switch Accounts at Usage Limits", isOn: Binding(get: { controller.switchEnabled },
                                                                  set: { controller.setSwitchEnabled($0) }))
        }
        Divider()
        Button("Settings…", action: openSettings)
            .keyboardShortcut(",")
        Button("Open Log") { NSWorkspace.shared.open(Paths.logFile) }
        Divider()
        Button("Quit (restores normal sleep)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private static func age(_ since: Date) -> String {
        let minutes = Int(-since.timeIntervalSinceNow) / 60
        return minutes < 1 ? "just now" : minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
