import Foundation

/// What My Activity counts, named after CleanMyMac's `StatisticsDashboard_TimeSaved_Category_*` strings.
public enum ActivityCategory: String, CaseIterable, Codable, Sendable {
    case systemJunk, mailAttachments, trashBin, privacyItems, appPermissions, backgroundItems, loginItems,
         maintenanceTasks, leftovers, installers, applicationsUpdated, applicationsUninstalled,
         duplicates, largeFiles, similarImages, downloads, malwares, spaceLens

    /// Result group IDs from the engines (see `ResultItem.category`).
    public init?(group: String) {
        switch group {
        case "user-cache", "system-cache", "user-logs", "system-logs", "xcode", "ios-backups", "broken-prefs",
             "broken-login", "deleted-users", "ai-junk", "local-models", "snapshots": self = .systemJunk
        case "mail": self = .mailAttachments
        case "trash": self = .trashBin
        case "privacy": self = .privacyItems
        case "permissions": self = .appPermissions
        case "background-items": self = .backgroundItems
        case "login-items": self = .loginItems
        case "maintenance": self = .maintenanceTasks
        case "leftovers": self = .leftovers
        case "installers": self = .installers
        case "updates": self = .applicationsUpdated
        case "uninstalled": self = .applicationsUninstalled
        case "duplicates": self = .duplicates
        case "large-old": self = .largeFiles
        case "similar": self = .similarImages
        case "downloads": self = .downloads
        case "malware": self = .malwares
        case "space-lens": self = .spaceLens
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .systemJunk: "System Junk Cleaned"
        case .mailAttachments: "Mail Attachments Cleaned"
        case .trashBin: "Trash Bin Cleaned"
        case .privacyItems: "Privacy Items Removed"
        case .appPermissions: "App Permissions Revoked"
        case .backgroundItems: "Background Items Removed"
        case .loginItems: "Login Items Removed"
        case .maintenanceTasks: "Maintenance Tasks Run"
        case .leftovers: "Leftovers Removed"
        case .installers: "Installers Removed"
        case .applicationsUpdated: "Applications Updated"
        case .applicationsUninstalled: "Applications Uninstalled"
        case .duplicates: "Duplicates Removed"
        case .largeFiles: "Large Files Removed"
        case .similarImages: "Similar Images Removed"
        case .downloads: "Downloads Removed"
        case .malwares: "Malware Scan Run"
        case .spaceLens: "Space Lens Used"
        }
    }

    /// The three parts of "Local Storage Cleaned".
    public enum Storage: String, CaseIterable, Sendable { case systemJunk = "System Junk", applications = "Applications", personalFiles = "Personal Files" }

    public var storage: Storage {
        switch self {
        case .leftovers, .installers, .applicationsUninstalled, .applicationsUpdated: .applications
        case .duplicates, .largeFiles, .similarImages, .downloads, .spaceLens: .personalFiles
        default: .systemJunk
        }
    }

    /// Minutes a person would spend doing this by hand: finding where it lives, deciding, removing it.
    /// CleanMyMac's own figures are not in its resources; these are TidyMac's estimates.
    var minutes: (perRun: Double, perItem: Double) {
        switch self {
        case .systemJunk: (10, 0.2)
        case .mailAttachments: (5, 0.2)
        case .trashBin: (1, 0)
        case .privacyItems: (5, 0.5)
        case .appPermissions: (3, 1)
        case .backgroundItems: (5, 2)
        case .loginItems: (3, 1)
        case .maintenanceTasks: (0, 5)
        case .leftovers: (5, 1)
        case .installers: (1, 0.5)
        case .applicationsUpdated: (0, 3)
        case .applicationsUninstalled: (0, 5)
        case .duplicates: (10, 0.5)
        case .largeFiles: (5, 1)
        case .similarImages: (10, 0.5)
        case .downloads: (5, 0.3)
        case .malwares: (15, 0)
        case .spaceLens: (5, 0.5)
        }
    }

    public func minutesSaved(items: Int) -> Double { minutes.perRun + minutes.perItem * Double(items) }
}

/// Every run and scan My Activity adds up, persisted in user defaults.
public enum History {
    static let key = "TidyMac.history"

    public struct Stat: Codable, Sendable { public var items: Int; public var bytes: Int64 }

    public struct Entry: Codable, Sendable {
        public let date: Date
        public let items: Int
        public let freed: Int64
        /// Per `ActivityCategory` raw value; missing in entries saved before categories existed.
        public var categories: [String: Stat]?
        /// Malware scans: how many items were checked and how many looked suspicious.
        public var scanned: Int?
        public var threats: Int?

        public var minutesSaved: Double {
            (categories ?? [:]).reduce(0) { sum, kv in
                sum + (ActivityCategory(rawValue: kv.key)?.minutesSaved(items: kv.value.items) ?? 0)
            }
        }
    }

    public static func record(_ r: ActionReport) {
        guard !r.succeeded.isEmpty else { return }
        var cats: [String: Stat] = [:]
        for item in r.succeeded {
            // A moved Downloads duplicate counts as a duplicate; anything unknown is still counted in the totals.
            guard let c = item.category.flatMap(ActivityCategory.init(group:)) else { continue }
            cats[c.rawValue, default: Stat(items: 0, bytes: 0)].items += 1
            cats[c.rawValue]!.bytes += item.size ?? 0
        }
        append(Entry(date: Date(), items: r.succeeded.count, freed: r.freed, categories: cats))
    }

    public static func recordMalwareScan(scanned: Int, threats: Int) {
        append(Entry(date: Date(), items: 0, freed: 0, categories: [ActivityCategory.malwares.rawValue: Stat(items: 0, bytes: 0)],
                     scanned: scanned, threats: threats))
    }

    static func append(_ e: Entry) {
        var all = entries
        all.append(e)
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: key) }
    }

    public static var entries: [Entry] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }
}

/// The figures on the My Activity dashboard, computed from `History` entries.
public struct ActivitySummary: Sendable {
    public let since: Date?
    public let freed: Int64
    public let freedThisMonth: Int64
    public let freedBy: [(ActivityCategory.Storage, Int64)]
    public let minutesSaved: Double
    public let minutesThisMonth: Double
    public let savedBy: [(ActivityCategory, Double)]
    public let recentSaves: [(Date, Double)]
    public let malwareScans: Int
    public let itemsScanned: Int
    public let threatsFound: Int
    public let lastMalwareScan: Date?

    public init(_ entries: [Entry] = History.entries, now: Date = Date()) {
        let monthStart = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        since = entries.first?.date
        freed = entries.reduce(0) { $0 + $1.freed }
        freedThisMonth = entries.filter { $0.date >= monthStart }.reduce(0) { $0 + $1.freed }
        var storage: [ActivityCategory.Storage: Int64] = [:], minutes: [ActivityCategory: Double] = [:]
        for e in entries {
            for (k, v) in e.categories ?? [:] {
                guard let c = ActivityCategory(rawValue: k) else { continue }
                storage[c.storage, default: 0] += v.bytes
                minutes[c, default: 0] += c.minutesSaved(items: v.items)
            }
        }
        freedBy = ActivityCategory.Storage.allCases.map { ($0, storage[$0] ?? 0) }
        minutesSaved = entries.reduce(0) { $0 + $1.minutesSaved }
        minutesThisMonth = entries.filter { $0.date >= monthStart }.reduce(0) { $0 + $1.minutesSaved }
        savedBy = minutes.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        recentSaves = entries.filter { $0.minutesSaved > 0 }.suffix(5).reversed().map { ($0.date, $0.minutesSaved) }
        let scans = entries.filter { $0.scanned != nil }
        malwareScans = scans.count
        itemsScanned = scans.reduce(0) { $0 + ($1.scanned ?? 0) }
        threatsFound = scans.reduce(0) { $0 + ($1.threats ?? 0) }
        lastMalwareScan = scans.last?.date
    }
    public typealias Entry = History.Entry

    /// `StatisticsDashboard_TimeSaved_Hint_*`, chosen by this month's total.
    public var timeSavedHint: String {
        switch minutesThisMonth {
        case 0: "Time savings dipped. Easy to improve!"
        case ..<60: "Going steady — let's save more time!"
        case ..<420: "Good progress on time saved!"
        default: "That’s a solid time-saving win!"
        }
    }

    public static func format(minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}

/// "Mac Health" with the recommendations that make it up (`MacStatePopover_*` / `MacState_*` strings).
public struct MacHealth: Sendable {
    public enum State: String, Sendable { case excellent = "Excellent", good = "Good", normal = "Fair", requiresAttention = "Requires Attention", critical = "Critical" }

    public struct Recommendation: Identifiable, Sendable {
        public enum Target: Sendable { case smartCare, cleanup, protection, performance, applications, clutter, fullDiskAccess, screenCleaning }
        public let id: String
        public let title: String
        public let detail: String
        public let target: Target
        /// Severe items (critical battery, almost no disk space) pull the state down on their own.
        public let severe: Bool
    }

    public let state: State
    public let recommendations: [Recommendation]

    public var description: String {
        switch state {
        case .excellent: "Your Mac is doing great. Run regular maintenance to keep it this way."
        case .good: "Your Mac is in good shape. Run some maintenance to make it perform even better."
        case .normal: "Your Mac is OK, but some maintenance activities are recommended to avoid performance degradation."
        case .requiresAttention: "Your Mac is not doing well. Run some maintenance to bring it back into shape."
        case .critical: "We strongly recommend to take action and bring your Mac back to normal."
        }
    }

    /// CleanMyMac does not ship its scoring; TidyMac grades by the number of open recommendations.
    public init(recommendations: [Recommendation]) {
        self.recommendations = recommendations
        let severe = recommendations.filter(\.severe).count
        switch (recommendations.count, severe) {
        case (_, 2...): state = .critical
        case (_, 1): state = .requiresAttention
        case (0, _): state = .excellent
        case (1...2, _): state = .good
        case (3...5, _): state = .normal
        default: state = .requiresAttention
        }
    }

    public static func current(entries: [History.Entry] = History.entries, now: Date = Date(),
                               hasFullDiskAccess: Bool, screenCleaningDue: Bool) -> MacHealth {
        var out: [Recommendation] = []
        let week: TimeInterval = 7 * 86_400
        let storage = SystemMonitor.storage()
        if storage.total > 0, storage.available < max(storage.total / 10, 15_000_000_000) {
            out.append(Recommendation(id: "space", title: "You are low on space.",
                                      detail: "Only \(FileSize.format(storage.available)) left. Remove unneeded items to reclaim space.",
                                      target: .clutter, severe: storage.available < storage.total / 50))
        }
        if let b = SystemMonitor.battery(), let h = b.healthPercent, h < 70 {
            out.append(Recommendation(id: "battery", title: "Critical battery health.",
                                      detail: "Your battery is in bad condition and should be replaced soon.", target: .smartCare, severe: true))
        }
        if !hasFullDiskAccess {
            out.append(Recommendation(id: "fda", title: "Allow Full Disk Access",
                                      detail: "TidyMac needs it to scan protected folders without repeated prompts.", target: .fullDiskAccess, severe: false))
        }
        let cleanups = entries.filter { $0.freed > 0 }
        if cleanups.isEmpty {
            out.append(Recommendation(id: "smartcare-first", title: "Run Smart Care for the first time ever.",
                                      detail: "Quick maintenance that takes care of the essentials.", target: .smartCare, severe: false))
        } else if let last = cleanups.last?.date, now.timeIntervalSince(last) > week {
            out.append(Recommendation(id: "smartcare", title: "It's time to care for your Mac! Run Smart Care.",
                                      detail: "Your last cleanup was \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: now)).",
                                      target: .smartCare, severe: false))
        }
        let lastScan = entries.last { $0.scanned != nil }?.date
        if lastScan.map({ now.timeIntervalSince($0) > week }) ?? true {
            out.append(Recommendation(id: "malware", title: "Run a deep Malware Scan to make sure you are fully safe and protected.",
                                      detail: lastScan == nil ? "No scans yet." : "Last scan was over a week ago.", target: .protection, severe: false))
        }
        if let t = SystemMonitor.trash(), t.size > 1_000_000_000 {
            out.append(Recommendation(id: "trash", title: "Empty the contents of your Trash Bins.",
                                      detail: "Your Trash holds \(FileSize.format(t.size)).", target: .cleanup, severe: false))
        }
        let lastTasks = entries.last { ($0.categories?[ActivityCategory.maintenanceTasks.rawValue]?.items ?? 0) > 0 }?.date
        if lastTasks.map({ now.timeIntervalSince($0) > week }) ?? true {
            out.append(Recommendation(id: "performance", title: "Run performance tasks to optimize your Mac.",
                                      detail: "Maintenance tasks have not run this week.", target: .performance, severe: false))
        }
        if SystemMonitor.memory().pressureLevel >= 4 {
            out.append(Recommendation(id: "memory", title: "Heavy memory usage",
                                      detail: "Quitting unused apps can help.", target: .performance, severe: false))
        }
        if screenCleaningDue {
            out.append(Recommendation(id: "screen", title: "Your screen deserves some care",
                                      detail: "Keep your Mac clean inside and out with Screen Cleaning Mode.", target: .screenCleaning, severe: false))
        }
        return MacHealth(recommendations: out)
    }
}
