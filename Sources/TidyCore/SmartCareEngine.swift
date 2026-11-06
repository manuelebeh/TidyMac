import Foundation

/// Quick Tidy: one scan across modules, one tile per module, one Run for all.
public struct SmartCareEngine: ScanEngine {
    let settings: ScanSettings
    public init(settings: ScanSettings = .load()) { self.settings = settings }

    public func scan(progress: @escaping @Sendable (String) -> Void) async -> [ResultGroup] {
        // Modules turned off in Settings › Scanning are not scanned and get no tile.
        let s = settings
        async let cleanup = s.scansSmartCare("cleanup") ? CleanupEngine(settings: s).scan(progress: progress) : []
        async let performance = s.scansSmartCare("performance") ? PerformanceEngine().scan(progress: progress) : []
        async let protection = s.scansSmartCare("protection") ? ProtectionEngine.suspiciousLaunchItems().items : []
        async let updates = s.scansSmartCare("applications") ? ApplicationsEngine.updates(for: Uninstaller.installedApps()).items : []
        async let clutter = s.scansSmartCare("clutter") ? Self.clutter(progress: progress) : []

        // Only groups safe to run unattended keep their default selection.
        let junk = await cleanup.filter { CleanupEngine.unattended.contains($0.id) }.flatMap(\.items).filter(\.selectedByDefault)
        let tasks = await performance.first { $0.id == "maintenance" }?.items.filter(\.selectedByDefault) ?? []

        return [
            ResultGroup(id: "cleanup", title: String(localized: "Cleanup"), description: String(localized: "Junk files that are safe to remove."),
                        symbol: "trash.circle", items: junk, verb: String(localized: "of junk to clean")),
            ResultGroup(id: "protection", title: String(localized: "Protection"), description: String(localized: "Suspicious background items."),
                        symbol: "hand.raised", items: await protection, verb: String(localized: "threats to review")),
            ResultGroup(id: "performance", title: String(localized: "Performance"), description: String(localized: "Recommended maintenance tasks."),
                        symbol: "bolt", items: tasks, verb: String(localized: "tasks to run")),
            ResultGroup(id: "applications", title: String(localized: "Applications"), description: String(localized: "Vital updates."),
                        symbol: "square.grid.2x2", items: await updates, verb: String(localized: "updates available")),
            ResultGroup(id: "clutter", title: String(localized: "Declutter"), description: String(localized: "Duplicate downloads and large files."),
                        symbol: "folder", items: await clutter, verb: String(localized: "to review")),
        ].filter { s.scansSmartCare($0.id) }
    }

    static func clutter(progress: @escaping @Sendable (String) -> Void) -> [ResultItem] {
        progress(String(localized: "Downloads"))
        let files = ClutterEngine.index(Paths.home("Downloads"))
        let dups = ClutterEngine.duplicates(files).items
        let large = ClutterEngine.largeAndOld(files, minSize: 500_000_000).items
        return dups + large
    }
}
