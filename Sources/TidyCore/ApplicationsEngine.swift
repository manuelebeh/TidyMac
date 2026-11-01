import CoreServices
import Foundation

/// Applications module: Updater (Sparkle appcasts and the App Store), File Leftovers, Unused DMG files.
/// The Uninstaller itself is interactive and lives in `Uninstaller`.
public struct ApplicationsEngine: ScanEngine {
    public init() {}

    public func scan(progress: @escaping @Sendable (String) -> Void) async -> [ResultGroup] {
        let apps = Uninstaller.installedApps()
        progress("Checking for updates")
        let updates = await Self.updates(for: apps)
        progress("Looking for leftovers")
        let leftovers = Self.leftovers(installed: apps)
        progress("Looking for installers")
        let installers = Self.unusedInstallers()
        return [updates, leftovers, installers].filter { !$0.isEmpty }
    }

    // MARK: Updater

    /// Where an update comes from: the developer's Sparkle feed or the App Store.
    public enum UpdateSource: String, Sendable { case developer = "Developer", appStore = "App Store" }

    public struct Update: Sendable {
        public let app: InstalledApp
        public let current: String
        public let latest: String
        public let download: URL?
        public var source: UpdateSource = .developer
        /// App Store only: the update's size in bytes.
        public var size: Int64?
    }

    /// Sparkle feeds and the App Store, checked side by side.
    static func updates(for apps: [InstalledApp]) async -> ResultGroup {
        async let sparkle = sparkleUpdates(for: apps)
        async let store = appStoreUpdates(for: apps)
        let found = await sparkle + store
        AppFacts.record(apps: apps, updates: found)
        let items = found.sorted { $0.app.name < $1.app.name }.map { u in
            // Sparkle apps install their own updates when opened; App Store updates open the app's store page.
            let target = u.source == .appStore ? u.download ?? u.app.url : u.app.url
            let size = u.size.map { " · " + FileSize.format($0) } ?? ""
            return ResultItem(id: "update:\(u.app.url.path)", title: u.app.name,
                              subtitle: "\(u.current) → \(u.latest) · \(u.source.rawValue)\(size)",
                              url: u.app.url, action: .open(target), selectedByDefault: false, badge: u.latest)
        }
        return ResultGroup(id: "updates", title: "App Updater",
                           description: "Apps with a newer version from their developer or the App Store.",
                           symbol: "arrow.down.app", items: items, verb: "to update")
    }

    /// Apps embedding Sparkle publish an appcast feed URL in Info.plist (`SUFeedURL`).
    static func sparkleUpdates(for apps: [InstalledApp]) async -> [Update] {
        let candidates = apps.compactMap { app -> (InstalledApp, URL, String, String?)? in
            guard let info = Bundle(url: app.url)?.infoDictionary,
                  let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.scheme == "https" else { return nil }
            let v = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "0"
            return (app, feed, v, info["CFBundleVersion"] as? String)
        }
        return await withTaskGroup(of: Update?.self) { tg in
            for (app, feed, current, build) in candidates {
                tg.addTask {
                    guard let (data, _) = try? await URLSession.shared.data(from: feed),
                          let latest = AppcastParser.latest(in: data) else { return nil }
                    // Sparkle itself compares build numbers (sparkle:version vs CFBundleVersion).
                    let newer = if let lb = latest.build, let build { Version(lb) > Version(build) }
                                else { Version(latest.version) > Version(current) }
                    guard newer else { return nil }
                    return Update(app: app, current: current, latest: latest.version, download: latest.url)
                }
            }
            var out: [Update] = []
            for await u in tg { if let u { out.append(u) } }
            return out
        }
    }

    /// App Store apps are looked up by their store ID (Spotlight's `kMDItemAppStoreAdamID`), or by bundle ID when
    /// Spotlight has none, in Apple's public lookup API for the user's region.
    static func appStoreUpdates(for apps: [InstalledApp]) async -> [Update] {
        let mas = apps.filter { $0.store == .appStore && $0.kind == .app }
        guard !mas.isEmpty else { return [] }
        let ids = mas.map { ($0, AppStoreLookup.adamID($0.url)) }
        var queries = stride(from: 0, to: ids.count, by: 100).compactMap { i -> [URLQueryItem]? in
            let chunk = ids[i..<min(i + 100, ids.count)].compactMap(\.1)
            return chunk.isEmpty ? nil : [URLQueryItem(name: "id", value: chunk.map(String.init).joined(separator: ","))]
        }
        let byBundle = ids.filter { $0.1 == nil }.compactMap(\.0.bundleID)
        if !byBundle.isEmpty {
            queries.append([URLQueryItem(name: "bundleId", value: byBundle.joined(separator: ",")),
                            URLQueryItem(name: "entity", value: "desktopSoftware")])
        }
        var entries: [AppStoreLookup.Entry] = []
        for q in queries {
            var c = URLComponents(string: "https://itunes.apple.com/lookup")!
            c.queryItems = q + [URLQueryItem(name: "country", value: AppStoreLookup.country)]
            if let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url) { entries += AppStoreLookup.parse(data) }
        }
        return ids.compactMap { app, adam in
            guard let e = entries.first(where: { adam != nil ? $0.id == adam : $0.bundleID == app.bundleID }),
                  let current = Bundle(url: app.url)?.infoDictionary?["CFBundleShortVersionString"] as? String,
                  Version(e.version) > Version(current) else { return nil }
            return Update(app: app, current: current, latest: e.version, download: e.storePage, source: .appStore, size: e.size)
        }
    }

    // MARK: Leftovers

    static func leftovers(installed: [InstalledApp]) -> ResultGroup {
        var ids = Set(installed.compactMap { $0.bundleID?.lowercased() })
        if let own = Bundle.main.bundleIdentifier?.lowercased() { ids.insert(own) }
        // Vendors share data between their apps and helpers (com.adobe.*, com.microsoft.*),
        // so anything from a vendor with an installed app is kept.
        let vendors = Set(ids.map { $0.split(separator: ".").prefix(2).joined(separator: ".") })
        let lib = Paths.library
        var items: [ResultItem] = []
        for (dir, ext) in [("Application Support", ""), ("Containers", ""), ("Caches", ""), ("Preferences", "plist"),
                           ("Saved Application State", "savedState"), ("HTTPStorages", ""), ("WebKit", "")] {
            for u in Paths.children(lib.appendingPathComponent(dir)) {
                var name = u.lastPathComponent
                if !ext.isEmpty { guard u.pathExtension == ext else { continue }; name = u.deletingPathExtension().lastPathComponent }
                guard Self.looksLikeBundleID(name) else { continue }
                let id = name.lowercased()
                // Helpers and extensions use the parent app's ID as prefix.
                if ids.contains(where: { id == $0 || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }) { continue }
                if vendors.contains(id.split(separator: ".").prefix(2).joined(separator: ".")) { continue }
                items.append(.file(u, subtitle: "\(dir) · no matching app", selected: false))
            }
        }
        return ResultGroup(id: "leftovers", title: "File Leftovers",
                           description: "Support files of apps that are no longer installed.",
                           symbol: "shippingbox", items: items.filter { ($0.size ?? 0) > 0 }.sorted { ($0.size ?? 0) > ($1.size ?? 0) },
                           verb: "to remove")
    }

    /// Frameworks and developer tools that store data under their own ID without being an app.
    static let nonAppPrefixes = ["org.swift.", "com.bugsnag.", "com.crashlytics", "io.sentry", "org.sparkle-project.",
                                 "com.google.keystone", "com.google.gtm", "com.microsoft.appcenter", "com.segment."]

    static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count >= 3, !s.hasPrefix("com.apple."), !s.hasPrefix("group."),
              !nonAppPrefixes.contains(where: { s.lowercased().hasPrefix($0) }) else { return false }
        return ["com", "org", "net", "io", "dev", "app", "co", "de", "fr", "ru", "us", "me"].contains(parts[0].lowercased())
    }

    static func unusedInstallers() -> ResultGroup {
        let items = Paths.children(Paths.home("Downloads"))
            .filter { ["dmg", "pkg", "mpkg"].contains($0.pathExtension.lowercased()) }
            .map { ResultItem.file($0) }
        return ResultGroup(id: "installers", title: "Unused DMG Files",
                           description: "Installers left in Downloads after the app was installed.",
                           symbol: "opticaldiscdrive", items: items, verb: "to remove")
    }
}

public enum AppcastParser {
    /// `version` is the display version; `build` is `sparkle:version` when the feed has both.
    public struct Entry { public let version: String; public let build: String?; public let url: URL? }

    /// Returns the highest version announced in a Sparkle appcast.
    public static func latest(in data: Data) -> Entry? {
        let delegate = Delegate()
        let p = XMLParser(data: data)
        p.delegate = delegate
        p.parse()
        return delegate.entries.max { Version($0.build ?? $0.version) < Version($1.build ?? $1.version) }
    }

    final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        var inItem = false, text = "", short: String?, build: String?, url: URL?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "item" { inItem = true; short = nil; build = nil; url = nil }
            if inItem, name == "enclosure" {
                short = attributes["sparkle:shortVersionString"] ?? short
                build = attributes["sparkle:version"] ?? build
                url = attributes["url"].flatMap(URL.init(string:))
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if inItem, name == "sparkle:shortVersionString", !t.isEmpty { short = t }
            if inItem, name == "sparkle:version", !t.isEmpty { build = t }
            if name == "item" {
                inItem = false
                if let v = short ?? build { entries.append(Entry(version: v, build: short == nil ? nil : build, url: url)) }
            }
        }
    }
}

/// Dotted version comparison ("1.10.2" > "1.9").
public struct Version: Comparable {
    let parts: [Int]
    public init(_ s: String) {
        parts = s.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map {
            $0.split(separator: ".").map { Int($0) ?? 0 }
        } ?? [0]
    }
    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}

/// Apple's public iTunes lookup API, as used for App Store update checks.
public enum AppStoreLookup {
    public struct Entry: Sendable, Equatable {
        public let id: Int
        public let bundleID: String?
        public let version: String
        public let size: Int64?
        /// The app's page, opened with the App Store app (`macappstore://`).
        public let storePage: URL?
    }

    /// The store region; App Store versions and availability differ between countries.
    static var country: String { (Locale.current.region?.identifier ?? "US").lowercased() }

    static func adamID(_ url: URL) -> Int? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        // The attribute has no exported constant; `mdls` lists it under this name.
        return (MDItemCopyAttribute(item, "kMDItemAppStoreAdamID" as CFString) as? NSNumber)?.intValue
    }

    public static func parse(_ data: Data) -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let id = r["trackId"] as? Int, let version = r["version"] as? String else { return nil }
            // fileSizeBytes is a string in the API's responses.
            let size = (r["fileSizeBytes"] as? String).flatMap { Int64($0) } ?? (r["fileSizeBytes"] as? NSNumber)?.int64Value
            let page = URL(string: "macappstore://apps.apple.com/app/id\(id)")
            return Entry(id: id, bundleID: r["bundleId"] as? String, version: version, size: size, storePage: page)
        }
    }
}
