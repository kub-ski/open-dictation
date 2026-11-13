import Foundation

/// Append-only session log at ~/.<app>/logs/app.log — the debugging surface
/// for headless verification (every stage writes here with timings).
enum Log {
    private static let url: URL = {
        let dir = AppConfig.supportDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()
    private static let q = DispatchQueue(label: "opendictation.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ msg: String) {
        q.async {
            let line = "[\(fmt.string(from: Date()))] \(msg)\n"
            if let data = line.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }

    /// The log quotes dictations, so "Clear history" clears it too.
    static func clear() {
        q.async { try? FileManager.default.removeItem(at: url) }
    }
}
