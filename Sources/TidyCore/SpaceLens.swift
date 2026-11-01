import Foundation

public struct SpaceNode: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let isDirectory: Bool
    public let isHidden: Bool
    public var name: String { url.lastPathComponent }
}

public enum SpaceLens {
    /// Sizes of the direct children of `url`, hidden ones included, largest first.
    public static func children(of url: URL, fm: FileManager = .default) async -> [SpaceNode] {
        var last: [SpaceNode] = []
        for await partial in childrenProgressively(of: url, fm: fm) { last = partial }
        return last
    }

    /// Same as `children(of:)`, but yields the sorted list each time another child has been sized,
    /// so big folders such as Home fill in as they are measured instead of all at once.
    public static func childrenProgressively(of url: URL, fm: FileManager = .default) -> AsyncStream<[SpaceNode]> {
        AsyncStream { cont in
            let task = Task {
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]
                let kids = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? []
                await withTaskGroup(of: SpaceNode?.self) { group in
                    for k in kids {
                        group.addTask {
                            let v = try? k.resourceValues(forKeys: keys)
                            let isDir = (v?.isDirectory ?? false) && !(v?.isSymbolicLink ?? false) && !(v?.isPackage ?? false)
                            // A privacy prompt can block a read indefinitely; such folders are left out.
                            guard let size = await withDeadline(120, { FileSize.allocated(k) }) else { return nil }
                            return SpaceNode(url: k, size: size, isDirectory: isDir,
                                             isHidden: v?.isHidden ?? k.lastPathComponent.hasPrefix("."))
                        }
                    }
                    var out: [SpaceNode] = []
                    for await n in group {
                        guard let n, n.size > 0 else { continue }
                        out.append(n)
                        out.sort { $0.size > $1.size }
                        cont.yield(out)
                    }
                    if out.isEmpty { cont.yield([]) }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public struct Bubble: Sendable { public let x, y, r: Double }

    /// Packs circles with area proportional to `sizes` (largest first) around the origin:
    /// each circle takes the free spot on an outward spiral closest to the centre.
    public static func pack(_ sizes: [Int64], radius: Double) -> [Bubble] {
        guard let maxSize = sizes.first, maxSize > 0 else { return [] }
        let total = Double(sizes.reduce(0, +))
        // Scale so packed circles cover roughly 55% of the target disc.
        let k = sqrt(0.55 * radius * radius / total)
        var placed: [Bubble] = []
        for s in sizes {
            let r = max(k * sqrt(Double(s)), 6)
            if placed.isEmpty { placed.append(Bubble(x: 0, y: 0, r: r)); continue }
            var angle = 0.0, dist = 0.0
            while true {
                let x = dist * cos(angle), y = dist * sin(angle)
                if !placed.contains(where: { hypot($0.x - x, $0.y - y) < $0.r + r + 2 }) {
                    placed.append(Bubble(x: x, y: y, r: r)); break
                }
                angle += 0.35; dist += 0.6
            }
        }
        // Fit the result into `radius`.
        let extent = placed.map { hypot($0.x, $0.y) + $0.r }.max() ?? radius
        let f = min(1, radius / extent)
        return placed.map { Bubble(x: $0.x * f, y: $0.y * f, r: $0.r * f) }
    }
}

extension SpaceLens {
    /// How much an item is protected from removal (`space_lens_list_info_essential_item` / `space_lens_tooltip_system_folder`).
    public enum Protection: Sendable { case none, systemFolder, essential }

    /// Essential items cannot be selected: the system's own folders, the home folder's standard folders and the parts of
    /// ~/Library that hold keychains, settings and app data. Other folders directly in ~/Library are system folders:
    /// they can be removed, with a warning.
    public static func protection(of url: URL, home: URL = Paths.home) -> Protection {
        let path = url.standardizedFileURL.path, h = home.standardizedFileURL.path
        let system = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/etc", "/var", "/cores", "/opt", "/Applications", "/Users", "/Volumes"]
        if path == "/" || system.contains(path) || path.hasPrefix("/System/") || path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/") {
            return .essential
        }
        guard path.hasPrefix(h + "/") else { return .none }
        let rel = String(path.dropFirst(h.count + 1))
        let homeFolders: Set = ["Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications", ".Trash"]
        let libraryEssentials: Set = ["Keychains", "Preferences", "Containers", "Group Containers", "Mobile Documents", "Accounts",
                                      "Application Support", "CloudStorage", "Mail", "Messages", "Photos", "Calendars", "Sharing"]
        if homeFolders.contains(rel) { return .essential }
        if rel.hasPrefix("Library/") {
            let rest = rel.dropFirst("Library/".count)
            if !rest.contains("/") { return libraryEssentials.contains(String(rest)) ? .essential : .systemFolder }
        }
        return .none
    }

    /// Space macOS can free on its own when storage runs low (caches, local snapshots, iCloud content it can download again).
    public static func purgeableSpace(volume: URL = URL(fileURLWithPath: "/")) -> Int64? {
        guard let v = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let free = v.volumeAvailableCapacity, let important = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return max(0, important - Int64(free))
    }

    /// Items kept in iCloud Drive: trashing them also removes them from the cloud and other devices.
    public static func isInCloud(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            || url.path.contains("/Library/Mobile Documents/")
    }
}

/// Space Lens's "Removal Log": what was removed or failed, newest first.
public enum RemovalLog {
    static let key = "TidyMac.removalLog"
    static let limit = 500

    public struct Entry: Codable, Sendable, Identifiable {
        public var id: String { "\(date.timeIntervalSince1970):\(path)" }
        public let date: Date
        public let path: String
        public let size: Int64
        /// nil when the item was removed.
        public let error: String?
    }

    public static func entries(defaults: UserDefaults = .standard) -> [Entry] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    public static func record(_ report: ActionReport, date: Date = Date(), defaults: UserDefaults = .standard) {
        let new = report.succeeded.map { Entry(date: date, path: $0.url?.path ?? $0.title, size: $0.size ?? 0, error: nil) }
            + report.failed.map { Entry(date: date, path: $0.0.url?.path ?? $0.0.title, size: $0.0.size ?? 0, error: $0.1) }
        let all = Array((new + entries(defaults: defaults)).prefix(limit))
        if let d = try? JSONEncoder().encode(all) { defaults.set(d, forKey: key) }
    }

    public static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
