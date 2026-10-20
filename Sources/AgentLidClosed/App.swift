import AppKit
import LidCore
import SwiftUI

@main
struct AgentLidClosedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would fight over the same system setting.
        let others = [Paths.bundleID, Paths.legacyBundleID].flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }
            .filter { $0.processIdentifier != getpid() }
        guard others.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        controller.start()
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

    var body: some View {
        Text(controller.headline)
        Text(controller.detail)
        Divider()
        if controller.evaluation.sessions.isEmpty {
            Text("No agent sessions")
        } else {
            ForEach(controller.evaluation.sessions) { session in
                Text("\(session.provider.name) · \(session.project): \(session.label) · \(Self.age(session.since))")
            }
        }
        Divider()
        Toggle("Automatic Mode", isOn: Binding(get: { controller.autoEnabled },
                                               set: { controller.setAutoEnabled($0) }))
        Toggle("Turn Display Off When Lid Closed", isOn: Binding(get: { controller.dimEnabled },
                                                                 set: { controller.setDimEnabled($0) }))
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
