import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import LidCore

/// macOS power state and control.
///
/// Closing the lid always sleeps the Mac, whatever sleep assertions apps hold (that's all
/// `caffeinate` does). The only switch that overrides it is the system-wide SleepDisabled
/// setting, `pmset -a disablesleep 1`, which needs root: install.sh adds a sudoers rule
/// allowing exactly `pmset -a disablesleep 0|1` without a password.
enum Power {
    static let sudoersFile = "/etc/sudoers.d/agent-lid-closed"
    static let legacySudoersFile = "/etc/sudoers.d/claude-lid-closed"

    /// `AGENT_LID_DRY_RUN=1` logs pmset and brightness calls instead of running them;
    /// `AGENT_LID_FAKE_LID=closed` pretends the lid is closed until a file named `lid-open`
    /// appears in the state directory. For testing.
    static let dryRun = environment("DRY_RUN") == "1"
    private static let fakeLid = dryRun && environment("FAKE_LID") == "closed"

    private static func environment(_ suffix: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return env["AGENT_LID_" + suffix] ?? env["CLAUDE_LID_" + suffix]
    }
    @MainActor private static var dryRunSleepDisabled = false
    @MainActor private static var dryRunBrightness: Float = 0.5
    /// The built-in display's ID, remembered because a closed lid may drop it from the display list.
    @MainActor private static var knownBuiltinDisplay: CGDirectDisplayID?

    struct Battery: Equatable {
        var percent: Int
        var onBattery: Bool
    }

    static var isSetUp: Bool {
        dryRun || FileManager.default.fileExists(atPath: sudoersFile)
            || FileManager.default.fileExists(atPath: legacySudoersFile)
    }

    /// Turns lid-closed (and all other) sleep off or back on. Returns an error message on failure.
    @MainActor
    static func setSleepDisabled(_ disabled: Bool) async -> String? {
        if dryRun {
            dryRunSleepDisabled = disabled
            Log.write("[dry run] pmset -a disablesleep \(disabled ? 1 : 0)")
            return nil
        }
        let args = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        let (status, output) = await Task.detached { run("/usr/bin/sudo", args) }.value
        return status == 0 ? nil : "pmset failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Blocking variant for app termination.
    @MainActor
    static func allowSleepNow() -> Bool {
        if dryRun {
            dryRunSleepDisabled = false
            Log.write("[dry run] pmset -a disablesleep 0")
            return true
        }
        return run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]).status == 0
    }

    /// The SleepDisabled setting as macOS reports it.
    @MainActor
    static var sleepDisabled: Bool {
        dryRun ? dryRunSleepDisabled : rootDomainBool("SleepDisabled") ?? false
    }

    static var lidClosed: Bool {
        if dryRun { return fakeLid && !FileManager.default.fileExists(atPath: Paths.stateDir.appendingPathComponent("lid-open").path) }
        return rootDomainBool("AppleClamshellState") == true
    }

    /// With an external display attached, a closed lid means clamshell mode, not "put it away".
    static var hasExternalDisplay: Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Backlight level of the built-in display, 0...1; nil if it can't be read.
    @MainActor
    static var displayBrightness: Float? {
        if dryRun { return dryRunBrightness }
        guard let services = DisplayServices.shared, let display = builtinDisplay() else { return nil }
        var value: Float = 0
        return services.get(display, &value) == 0 ? value : nil
    }

    /// Sets the built-in display's backlight level (0 = off). Returns false if it didn't take.
    @MainActor
    static func setDisplayBrightness(_ value: Float) -> Bool {
        if dryRun {
            dryRunBrightness = value
            Log.write("[dry run] display brightness \(Int((value * 100).rounded()))%")
            return true
        }
        guard let services = DisplayServices.shared, let display = builtinDisplay() else { return false }
        return services.set(display, value) == 0
    }

    static func sleepNow() {
        if dryRun {
            Log.write("[dry run] sleep now")
            return
        }
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        if port != 0 {
            let result = IOPMSleepSystem(port)
            IOServiceClose(port)
            if result == kIOReturnSuccess { return }
        }
        _ = run("/usr/bin/pmset", ["sleepnow"])
    }

    static var battery: Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return Battery(percent: current * 100 / max, onBattery: onBattery)
        }
        return nil
    }

    @MainActor
    private static func builtinDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 {
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if CGGetOnlineDisplayList(count, &displays, &count) == .success,
               let builtin = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) {
                knownBuiltinDisplay = builtin
            }
        }
        return knownBuiltinDisplay
    }

    /// Brightness has no public API on Apple silicon; this is the private framework that System
    /// Settings and the brightness keys use. If it's ever missing, brightness calls just fail.
    private struct DisplayServices {
        typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

        let get: Get
        let set: Set

        static let shared: DisplayServices? = {
            guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
                  let get = dlsym(handle, "DisplayServicesGetBrightness"),
                  let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
            return DisplayServices(get: unsafeBitCast(get, to: Get.self), set: unsafeBitCast(set, to: Set.self))
        }()
    }

    private static func rootDomainBool(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
