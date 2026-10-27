import Foundation

public struct InstalledApp: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let bundleID: String?
    public var size: Int64
}

public struct Leftover: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
}

public enum Uninstaller {
    public static func installedApps(fm: FileManager = .default) -> [InstalledApp] {
        let dirs = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        // Suites such as Adobe's install their apps one folder down.
        let candidates = dirs.flatMap { d -> [URL] in
            let kids = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            return kids.flatMap { k -> [URL] in
                if k.pathExtension == "app" { return [k] }
                return ((try? fm.contentsOfDirectory(at: k, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
            }
        }
        let apps = candidates.map {
            InstalledApp(url: $0, name: $0.deletingPathExtension().lastPathComponent, bundleID: Bundle(url: $0)?.bundleIdentifier, size: 0)
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Sizing whole bundles is slow, so it is done separately from listing.
    public static func size(of app: InstalledApp) -> Int64 { FileSize.allocated(app.url) }

    /// Per-user locations where an app commonly stores data, matched by bundle identifier.
    public static func leftovers(for app: InstalledApp, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 fm: FileManager = .default) -> [Leftover] {
        guard let bid = app.bundleID, !bid.hasPrefix("com.apple.") else { return [] }
        let lib = home.appendingPathComponent("Library")
        var candidates: [URL] = [
            "Application Support/\(bid)", "Application Support/\(app.name)",
            "Caches/\(bid)", "Containers/\(bid)", "Preferences/\(bid).plist",
            "Saved Application State/\(bid).savedState", "HTTPStorages/\(bid)",
            "WebKit/\(bid)", "Logs/\(app.name)", "LaunchAgents/\(bid).plist",
        ].map { lib.appendingPathComponent($0) }
        if let groups = try? fm.contentsOfDirectory(at: lib.appendingPathComponent("Group Containers"), includingPropertiesForKeys: nil) {
            candidates += groups.filter { $0.lastPathComponent.hasSuffix(bid) }
        }
        return candidates.filter { fm.fileExists(atPath: $0.path) }
            .map { Leftover(url: $0, size: FileSize.allocated($0)) }
    }
}
