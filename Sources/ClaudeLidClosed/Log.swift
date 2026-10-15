import Foundation
import LidCore

/// Appends to ~/Library/Logs/ClaudeLidClosed.log; rotated once it passes 1 MB.
enum Log {
    private static let maxSize = 1_000_000

    static func write(_ message: String) {
        let url = Paths.logFile
        let line = "\(Date.now.ISO8601Format(Date.ISO8601FormatStyle(timeZone: .current))) \(message)\n"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxSize {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
    }
}
