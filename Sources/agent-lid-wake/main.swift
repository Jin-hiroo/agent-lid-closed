// Installed root-owned outside the user-writable app bundle. This program deliberately
// ignores environment configuration and touches only wake events bearing its fixed owner.
import Darwin
import Foundation
import IOKit.pwr_mgt
import LidCore

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("agent-lid-wake: \(message)\n".utf8))
    exit(code)
}

guard let request = WakeRequest.parse(Array(CommandLine.arguments.dropFirst()), now: Date().timeIntervalSince1970) else {
    fail("usage: agent-lid-wake clear | set <Unix seconds within the next 7 days>", code: 64)
}
guard geteuid() == 0 else { fail("must run as root", code: 77) }

// Serialize scheduling and cancellation even if an old app is still shutting down.
let lock = open("/var/run/local.AgentLidClosed.wake.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
guard lock >= 0, flock(lock, LOCK_EX) == 0 else { fail("cannot lock wake schedule") }
defer { close(lock) }

let owner = "local.AgentLidClosed.quota"
let type = kIOPMAutoWake
let events = (IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]]) ?? []
let dates = events.compactMap { event -> Date? in
    guard event[kIOPMPowerEventAppNameKey] as? String == owner,
          event[kIOPMPowerEventTypeKey] as? String == type else { return nil }
    return event[kIOPMPowerEventTimeKey] as? Date
}
let wanted: Date?
switch request {
case .clear: wanted = nil
case .set(let epoch): wanted = Date(timeIntervalSince1970: Double(epoch))
}

// Schedule the replacement first: a failure must not destroy a still-useful alarm.
if let wanted, !dates.contains(wanted) {
    let status = IOPMSchedulePowerEvent(wanted as CFDate, owner as CFString, type as CFString)
    guard status == kIOReturnSuccess else { fail("could not schedule wake (\(status))") }
}
for date in dates where date != wanted {
    let status = IOPMCancelScheduledPowerEvent(date as CFDate, owner as CFString, type as CFString)
    guard status == kIOReturnSuccess || status == kIOReturnNotFound else {
        fail("could not cancel wake (\(status))")
    }
}
