import Foundation

/// Applications module: Updater (Sparkle appcasts), File Leftovers, Unused DMG files.
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

    public struct Update: Sendable { public let app: InstalledApp; public let current: String; public let latest: String; public let download: URL? }

    /// Apps embedding Sparkle publish an appcast feed URL in Info.plist (`SUFeedURL`).
    static func updates(for apps: [InstalledApp]) async -> ResultGroup {
        let candidates = apps.compactMap { app -> (InstalledApp, URL, String, String?)? in
            guard let info = Bundle(url: app.url)?.infoDictionary,
                  let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.scheme == "https" else { return nil }
            let v = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "0"
            return (app, feed, v, info["CFBundleVersion"] as? String)
        }
        let found = await withTaskGroup(of: Update?.self) { tg in
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
        let items = found.sorted { $0.app.name < $1.app.name }.map {
            // Sparkle apps install their own updates; opening the app triggers its updater.
            ResultItem(id: "update:\($0.app.url.path)", title: $0.app.name, subtitle: "\($0.current) → \($0.latest)",
                       url: $0.app.url, action: .open($0.app.url), selectedByDefault: false, badge: $0.latest)
        }
        return ResultGroup(id: "updates", title: "App Updater",
                           description: "Apps with a newer version available from their developer.",
                           symbol: "arrow.down.app", items: items, verb: "to update")
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
