import Foundation

struct DictationEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let raw: String        // whisper output
    let cleaned: String    // what was inserted
    let seconds: Double    // spoken duration
    let app: String        // frontmost app it was inserted into
}

/// JSON-backed history at ~/.<app>/history.json (newest first, capped).
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [DictationEntry] = []

    private static let url = AppConfig.supportDir.appendingPathComponent("history.json")
    private let cap = 500

    init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.url),
           let list = try? dec.decode([DictationEntry].self, from: data) {
            entries = list
        }
    }

    func add(raw: String, cleaned: String, seconds: Double, app: String) {
        entries.insert(DictationEntry(id: UUID(), date: Date(), raw: raw,
                                      cleaned: cleaned, seconds: seconds, app: app), at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        persist()
    }

    func clear() {
        entries = []
        persist()
        Log.clear()
        Log.write("history: cleared (and the log)")
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(entries) { try? data.write(to: Self.url) }
    }
}
