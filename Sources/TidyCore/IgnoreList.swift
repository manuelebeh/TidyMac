import Foundation

/// Items the user excluded from scan results (Settings › Ignore List). Matching is by `ResultItem.id`,
/// so an item ignored in Smart Care is also hidden in Cleanup or My Tools. Changes apply on the next scan.
public enum IgnoreList {
    static let key = "TidyMac.ignoreList"

    public struct Entry: Codable, Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let subtitle: String?
        /// The result group the item came from; it decides the section.
        public let category: String?
        public let date: Date

        public var section: Section { Section(group: category) }
    }

    /// Sections group TidyMac's result group IDs into the categories shown in Settings.
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case systemJunk, aiClutter, mail, largeOld, duplicates, similar, downloads, uninstaller, updater, malware, other

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .systemJunk: "System Junk"
            case .aiClutter: "AI Clutter"
            case .mail: "Mail Attachments"
            case .largeOld: "Large & Old Files"
            case .duplicates: "Duplicates"
            case .similar: "Similar Images"
            case .downloads: "Downloads"
            case .uninstaller: "App Leftovers"
            case .updater: "Updater"
            case .malware: "Malware Removal"
            case .other: "Other"
            }
        }

        init(group: String?) {
            switch group {
            case "user-cache", "system-cache", "user-logs", "system-logs", "xcode", "ios-backups",
                 "broken-prefs", "broken-login", "deleted-users": self = .systemJunk
            case "ai-junk", "local-models": self = .aiClutter
            case "mail": self = .mail
            case "large-old": self = .largeOld
            case "duplicates": self = .duplicates
            case "similar": self = .similar
            case "downloads", "installers": self = .downloads
            case "leftovers": self = .uninstaller
            case "updates": self = .updater
            case "malware": self = .malware
            default: self = .other
            }
        }
    }

    public static func entries(defaults: UserDefaults = .standard) -> [Entry] {
        guard let d = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }

    public static func contains(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        entries(defaults: defaults).contains { $0.id == id }
    }

    public static func add(_ items: [ResultItem], defaults: UserDefaults = .standard) {
        var all = entries(defaults: defaults)
        let known = Set(all.map(\.id))
        all += items.filter { !known.contains($0.id) }
            .map { Entry(id: $0.id, title: $0.title, subtitle: $0.subtitle, category: $0.category, date: Date()) }
        save(all, defaults)
    }

    public static func remove(_ ids: Set<String>, defaults: UserDefaults = .standard) {
        save(entries(defaults: defaults).filter { !ids.contains($0.id) }, defaults)
    }

    /// Empties one section, or the whole list when `section` is nil.
    public static func reset(_ section: Section? = nil, defaults: UserDefaults = .standard) {
        save(section.map { s in entries(defaults: defaults).filter { $0.section != s } } ?? [], defaults)
    }

    /// Drops ignored items from scan results. Groups are kept even when emptied, so Smart Care keeps its tiles.
    public static func apply(_ groups: [ResultGroup], defaults: UserDefaults = .standard) -> [ResultGroup] {
        let ignored = Set(entries(defaults: defaults).map(\.id))
        guard !ignored.isEmpty else { return groups }
        return groups.map { var g = $0; g.items.removeAll { ignored.contains($0.id) }; return g }
    }

    static func save(_ all: [Entry], _ defaults: UserDefaults) {
        if let d = try? JSONEncoder().encode(all) { defaults.set(d, forKey: key) }
    }
}
