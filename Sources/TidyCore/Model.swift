import Foundation

/// What happens to an item when the user runs a module. Engines only describe actions;
/// `Executor` is the single place that touches the filesystem or the shell.
public enum ItemAction: Hashable, Sendable {
    /// Move to the user's Trash (recoverable).
    case trash(URL)
    /// Permanently delete. Only used for items that already sit in a Trash bin.
    case delete(URL)
    /// Delete paths that need root (system caches/logs), batched into one admin prompt.
    case adminDelete(URL)
    /// Run a shell command, optionally as administrator (batched into one prompt).
    case shell(String, admin: Bool)
    /// Unload a launchd job, then move its plist to the Trash.
    case removeLaunchItem(URL, admin: Bool)
    /// Remove a login item registered with System Events.
    case removeLoginItem(name: String)
    /// Nothing to execute; the item is informational or opened by the user.
    case open(URL)
}

public struct ResultItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let size: Int64?
    public let url: URL?
    public let action: ItemAction
    public let selectedByDefault: Bool
    public let badge: String?
    /// The result group the item was found in (set by `ResultGroup`); My Activity counts by it.
    public var category: String?

    public init(id: String? = nil, title: String, subtitle: String? = nil, size: Int64? = nil, url: URL? = nil,
                action: ItemAction, selectedByDefault: Bool = true, badge: String? = nil) {
        self.id = id ?? url?.path ?? title
        self.title = title; self.subtitle = subtitle; self.size = size; self.url = url
        self.action = action; self.selectedByDefault = selectedByDefault; self.badge = badge
    }

    public static func file(_ url: URL, size: Int64? = nil, subtitle: String? = nil, selected: Bool = true,
                            badge: String? = nil, action: ItemAction? = nil) -> ResultItem {
        ResultItem(title: url.lastPathComponent, subtitle: subtitle ?? Paths.abbreviate(url.deletingLastPathComponent()),
                   size: size ?? FileSize.allocated(url), url: url, action: action ?? .trash(url),
                   selectedByDefault: selected, badge: badge)
    }
}

public struct ResultGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let symbol: String
    public var items: [ResultItem]
    /// Optional sub-heading shown on the module's result tile, e.g. "3 tasks to run".
    public var verb: String

    public init(id: String, title: String, description: String, symbol: String, items: [ResultItem], verb: String = "to clean") {
        self.id = id; self.title = title; self.description = description; self.symbol = symbol
        self.items = items.map { var i = $0; if i.category == nil { i.category = id }; return i }
        self.verb = verb
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    public var isEmpty: Bool { items.isEmpty }
}

public struct ActionReport: Sendable {
    public var succeeded: [ResultItem] = []
    public var failed: [(ResultItem, String)] = []
    public var freed: Int64 { succeeded.reduce(0) { $0 + ($1.size ?? 0) } }
    public init() {}
}

/// A module's scanner. `progress` receives the location currently being looked at.
public protocol ScanEngine: Sendable {
    func scan(progress: @escaping @Sendable (String) -> Void) async -> [ResultGroup]
}

/// Runs blocking work on a background queue and gives up waiting after `seconds`.
/// File reads can block indefinitely while macOS shows a privacy prompt; a scan must not.
public func withDeadline<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () -> T) async -> T? {
    let once = OnceFlag()
    return await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async { let v = work(); if once.claim() { cont.resume(returning: v) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { if once.claim() { cont.resume(returning: nil) } }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

public enum Permissions {
    /// Full Disk Access cannot be queried directly; reading a TCC-protected file is the standard probe.
    public static var hasFullDiskAccess: Bool {
        FileManager.default.isReadableFile(atPath: Paths.library.appendingPathComponent("Safari/Bookmarks.plist").path)
            || (try? FileManager.default.contentsOfDirectory(atPath: Paths.library.appendingPathComponent("Safari").path)) != nil
    }
    public static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static func home(_ p: String) -> URL { home.appendingPathComponent(p) }
    public static var library: URL { home("Library") }

    public static func abbreviate(_ url: URL) -> String {
        let p = url.path, h = home.path
        return p.hasPrefix(h) ? "~" + p.dropFirst(h.count) : p
    }

    public static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public static func children(_ url: URL, hidden: Bool = false) -> [URL] {
        let opts: FileManager.DirectoryEnumerationOptions = hidden ? [] : [.skipsHiddenFiles]
        return (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: opts)) ?? []
    }
}
