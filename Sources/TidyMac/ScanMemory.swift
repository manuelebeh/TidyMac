import Foundation
import TidyCore

/// What each module's last full scan found, and what is still there after the run, so its intro can say so.
enum ScanMemory {
    struct Entry: Codable {
        let date: Date
        let size: Int64
        let items: Int
    }

    static let key = "TidyMac.lastScans"

    static func save(_ module: Module, date: Date, size: Int64, items: Int) {
        var all = load()
        all[module.rawValue] = Entry(date: date, size: size, items: items)
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func last(_ module: Module) -> Entry? { load()[module.rawValue] }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    /// "Last Scan: 2 days ago · 3,2 GB found", or what is left of it once cleaned.
    static func summary(_ e: Entry, now: Date = Date()) -> String {
        let when = Calendar.current.isDate(e.date, inSameDayAs: now) ? String(localized: "Last Scan: Today")
            : String(localized: "Last Scan: \(RelativeDateTimeFormatter().localizedString(for: e.date, relativeTo: now))")
        let found = e.size > 0 ? String(localized: "\(formatSize(e.size)) found")
            : e.items > 0 ? String(localized: "\(e.items) items found")
            : String(localized: "Nothing left to do")
        return when + " · " + found
    }
}
