import Darwin

/// A process, identified by PID plus start time so a reused PID isn't mistaken for it.
public struct ProcessIdentity: Sendable, Equatable {
    public let pid: Int32
    public let startTime: Double
}

public enum ProcessLookup {
    private static let wrappers: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env"]

    public static func identity(of pid: Int32) -> ProcessIdentity? {
        guard let info = kinfo(pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessIdentity(pid: pid, startTime: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    public static func isAlive(pid: Int32, startTime: Double) -> Bool {
        guard let current = identity(of: pid) else { return false }
        return abs(current.startTime - startTime) < 1
    }

    /// The agent process that ran this hook: the nearest ancestor that isn't a shell.
    public static func hookOwner() -> ProcessIdentity? {
        var pid = getppid()
        for _ in 0..<8 {
            guard pid > 1, let info = kinfo(pid) else { return nil }
            if !wrappers.contains(commandName(info)) { return identity(of: pid) }
            pid = info.kp_eproc.e_ppid
        }
        return nil
    }

    private static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func commandName(_ info: kinfo_proc) -> String {
        withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
