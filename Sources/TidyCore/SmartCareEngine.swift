import Foundation

/// Smart Care: one scan across modules, one tile per module, one Run for all.
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

        // Only groups Smart Care treats as safe to run unattended keep their default selection.
        let safeCleanup: Set<String> = ["user-cache", "user-logs", "xcode", "broken-prefs", "broken-login", "ai-junk", "mail", "trash"]
        let junk = await cleanup.filter { safeCleanup.contains($0.id) }.flatMap(\.items).filter(\.selectedByDefault)
        let tasks = await performance.first { $0.id == "maintenance" }?.items.filter(\.selectedByDefault) ?? []

        return [
            ResultGroup(id: "cleanup", title: "Cleanup", description: "Junk files that are safe to remove.",
                        symbol: "trash.circle", items: junk, verb: "of junk to clean"),
            ResultGroup(id: "protection", title: "Protection", description: "Suspicious background items.",
                        symbol: "hand.raised", items: await protection, verb: "threats to review"),
            ResultGroup(id: "performance", title: "Performance", description: "Recommended maintenance tasks.",
                        symbol: "bolt", items: tasks, verb: "tasks to run"),
            ResultGroup(id: "applications", title: "Applications", description: "Vital updates.",
                        symbol: "square.grid.2x2", items: await updates, verb: "updates available"),
            ResultGroup(id: "clutter", title: "My Clutter", description: "Duplicate downloads and large files.",
                        symbol: "folder", items: await clutter, verb: "to review"),
        ].filter { s.scansSmartCare($0.id) }
    }

    static func clutter(progress: @escaping @Sendable (String) -> Void) -> [ResultItem] {
        progress("Downloads")
        let files = ClutterEngine.index(Paths.home("Downloads"))
        let dups = ClutterEngine.duplicates(files).items
        let large = ClutterEngine.largeAndOld(files, minSize: 500_000_000).items
        return dups + large
    }
}
