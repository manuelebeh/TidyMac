import Foundation

/// Apps to quit before their files are removed (CleanMyMac's ApplicationsTerminator: "Please quit the following
/// applications to clean all of their related items"). Matching is pure; the UI supplies the running apps.
public enum AppTerminator {
    public struct App: Hashable, Sendable {
        public let pid: Int32
        public let name: String
        public let bundleID: String?
        public let bundleURL: URL?

        public init(pid: Int32, name: String, bundleID: String?, bundleURL: URL?) {
            self.pid = pid; self.name = name; self.bundleID = bundleID; self.bundleURL = bundleURL
        }
    }

    /// The files an item's action removes. Opening, shell commands and launch items do not touch app data.
    public static func removedURLs(_ items: [ResultItem]) -> [URL] {
        items.compactMap {
            switch $0.action {
            case .trash(let u), .delete(let u), .adminDelete(let u): u
            default: nil
            }
        }
    }

    /// An app is related to a file when the file is its bundle or inside it, when a path component is named after
    /// its bundle ID (`Caches/<id>`, `Preferences/<id>.plist`, `Group Containers/<team>.<id>`, `<id>.savedState`),
    /// or when a component under a Library folder carries the app's name (`Application Support/<name>`).
    public static func related(to urls: [URL], among running: [App]) -> [App] {
        let paths = urls.map { $0.standardizedFileURL.path }
        return running.filter { app in
            let bundle = app.bundleURL?.standardizedFileURL.path
            let id = app.bundleID?.lowercased()
            let name = app.name.lowercased()
            return paths.contains { p in
                if let bundle, p == bundle || p.hasPrefix(bundle + "/") { return true }
                let parts = p.lowercased().split(separator: "/").map(String.init)
                if let id, parts.contains(where: { $0 == id || $0.hasPrefix(id + ".") || $0.hasSuffix("." + id) }) { return true }
                if let lib = parts.firstIndex(of: "library") { return parts[(lib + 1)...].contains(name) }
                return false
            }
        }
    }
}
