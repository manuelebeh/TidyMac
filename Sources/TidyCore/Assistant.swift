import Foundation

/// What the Assistant knows about installed apps: pending updates and apps not opened for six months.
/// Both are slow to read (network, Spotlight), so every update check records them and Insights reads the copy.
public struct AppFacts: Codable, Sendable, Equatable {
    static let key = "TidyMac.appFacts"

    /// Names of the apps with an update.
    public var updates: [String]
    /// Paths of the unused apps, so an app uninstalled since the check no longer counts.
    public var unused: [String]
    public var date: Date

    public init(updates: [String], unused: [String], date: Date = Date()) {
        self.updates = updates; self.unused = unused; self.date = date
    }

    public var unusedCount: Int { unused.filter { FileManager.default.fileExists(atPath: $0) }.count }

    public static func load(defaults: UserDefaults = .standard) -> AppFacts? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppFacts.self, from: $0) }
    }

    public func save(defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
    }

    /// `others` names updates that are not tied to an installed app bundle, such as Homebrew casks.
    static func record(apps: [InstalledApp], updates: [ApplicationsEngine.Update], others: [String] = []) {
        AppFacts(updates: updates.map(\.app.name) + others,
                 unused: apps.filter { $0.kind == .app && $0.isUnused() }.map(\.url.path)).save()
    }

    /// Runs the update check when the last one is over a day old. It sends App Store IDs to Apple's lookup API.
    public static func refreshIfStale(now: Date = Date()) async {
        if let last = load()?.date, now.timeIntervalSince(last) < 86_400 { return }
        _ = await ApplicationsEngine.updates(for: Uninstaller.installedApps())
    }
}

/// Recommendations put aside with "Skip for now" or "Hide All". They come back the next day.
public struct SkippedRecommendations: Codable, Equatable, Sendable {
    static let key = "TidyMac.skippedRecommendations"
    public var until: [String: Date] = [:]
    public init() {}

    public static func load(defaults: UserDefaults = .standard) -> SkippedRecommendations {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SkippedRecommendations.self, from: $0) } ?? SkippedRecommendations()
    }

    public func save(defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
    }

    public mutating func skip(_ ids: [String], now: Date = Date()) {
        until = until.filter { $0.value > now }
        for id in ids { until[id] = SystemMonitor.IgnoreOption.untilTomorrow.until(from: now) }
    }

    public func visible(_ recs: [MacHealth.Recommendation], now: Date = Date()) -> [MacHealth.Recommendation] {
        recs.filter { (until[$0.id] ?? .distantPast) <= now }
    }
}
