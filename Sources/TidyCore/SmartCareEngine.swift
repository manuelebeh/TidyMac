import Foundation

/// Smart Care: one scan across modules, one tile per module, one Run for all.
/// Tile set and wording follow SmartCareModule's strings (see REVERSE.md).
public struct SmartCareEngine: ScanEngine {
    public init() {}

    public func scan(progress: @escaping @Sendable (String) -> Void) async -> [ResultGroup] {
        async let cleanup = CleanupEngine().scan(progress: progress)
        async let performance = PerformanceEngine().scan(progress: progress)
        async let protection = ProtectionEngine.suspiciousLaunchItems()
        async let updates = ApplicationsEngine.updates(for: Uninstaller.installedApps())
        async let clutter = Self.clutter(progress: progress)

        // Only groups Smart Care treats as safe to run unattended keep their default selection.
        let safeCleanup: Set<String> = ["user-cache", "user-logs", "xcode", "broken-prefs", "broken-login", "ai-junk", "mail", "trash"]
        let junk = await cleanup.filter { safeCleanup.contains($0.id) }.flatMap(\.items).filter(\.selectedByDefault)
        let tasks = await performance.first { $0.id == "maintenance" }?.items.filter(\.selectedByDefault) ?? []

        return [
            ResultGroup(id: "cleanup", title: "Cleanup", description: "Junk files that are safe to remove.",
                        symbol: "trash.circle", items: junk, verb: "of junk to clean"),
            ResultGroup(id: "protection", title: "Protection", description: "Suspicious background items.",
                        symbol: "hand.raised", items: await protection.items, verb: "threats to review"),
            ResultGroup(id: "performance", title: "Performance", description: "Recommended maintenance tasks.",
                        symbol: "bolt", items: tasks, verb: "tasks to run"),
            ResultGroup(id: "applications", title: "Applications", description: "Vital updates.",
                        symbol: "square.grid.2x2", items: await updates.items, verb: "updates available"),
            ResultGroup(id: "clutter", title: "My Clutter", description: "Duplicate downloads and large files.",
                        symbol: "folder", items: await clutter, verb: "to review"),
        ]
    }

    static func clutter(progress: @escaping @Sendable (String) -> Void) -> [ResultItem] {
        progress("Downloads")
        let files = ClutterEngine.index(Paths.home("Downloads"))
        let dups = ClutterEngine.duplicates(files).items
        let large = ClutterEngine.largeAndOld(files, minSize: 500_000_000).items
        return dups + large
    }
}
