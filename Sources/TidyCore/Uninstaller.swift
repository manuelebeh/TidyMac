import CoreServices
import Foundation

public struct InstalledApp: Identifiable, Sendable {
    public enum Kind: Sendable { case app, audioPlugin }

    /// Where the app came from (CleanMyMac's Stores filter).
    public enum Store: String, CaseIterable, Sendable { case appStore = "App Store", setapp = "Setapp", steam = "Steam", other = "Other" }

    public var id: URL { url }
    public let url: URL
    public let name: String
    public let bundleID: String?
    public var size: Int64
    public var kind: Kind = .app
    public var store: Store = .other
    /// Spotlight's last-opened date; nil when Spotlight has none.
    public var lastUsed: Date?

    public var vendor: Vendor { Vendor(bundleID: bundleID) }

    /// Not opened for six months (CleanMyMac's Unused filter). Apps without a Spotlight date are not counted.
    public func isUnused(now: Date = Date()) -> Bool {
        lastUsed.map { now.timeIntervalSince($0) > 182 * 86_400 } ?? false
    }
}

/// CleanMyMac's Vendors filter, by bundle ID prefix.
public enum Vendor: String, CaseIterable, Sendable {
    case apple = "Apple", adobe = "Adobe", google = "Google", jetBrains = "JetBrains", microsoft = "Microsoft", other = "Other"

    init(bundleID: String?) {
        let id = bundleID?.lowercased() ?? ""
        let prefixes: [(String, Vendor)] = [("com.apple.", .apple), ("com.adobe.", .adobe), ("com.google.", .google),
                                            ("com.jetbrains.", .jetBrains), ("com.microsoft.", .microsoft)]
        self = prefixes.first { id.hasPrefix($0.0) }?.1 ?? .other
    }
}

public struct Leftover: Identifiable, Hashable, Sendable {
    /// Resource groups from CleanMyMac's Uninstaller (`resource_group_*`).
    public enum Kind: String, CaseIterable, Sendable {
        case supportingFiles = "Supporting Files", preferences = "Preferences", caches = "Caches", container = "Container",
             logs = "Logs", crashes = "Crashes", launchItems = "Login Items", binaries = "Binaries", plugins = "Plugins",
             installers = "Installers"
    }

    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let kind: Kind
    /// Files outside the home folder go through the administrator prompt; receipts are forgotten with pkgutil.
    public let action: ItemAction
}

public enum Uninstaller {
    static let pluginExtensions: Set<String> = ["component", "vst", "vst3", "aaxplugin"]

    /// Apps in /Applications and ~/Applications (one folder down for suites and Setapp), Steam games and audio plug-ins.
    public static func installedApps(home: URL = Paths.home, system: URL = URL(fileURLWithPath: "/"),
                                     fm: FileManager = .default) -> [InstalledApp] {
        let kids = { (d: URL) in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] }
        let dirs = [system.appendingPathComponent("Applications"), home.appendingPathComponent("Applications")]
        // Suites such as Adobe's install their apps one folder down.
        var bundles = dirs.flatMap { d in
            kids(d).flatMap { k in k.pathExtension == "app" ? [k] : kids(k).filter { $0.pathExtension == "app" } }
        }
        bundles += kids(home.appendingPathComponent("Library/Application Support/Steam/steamapps/common"))
            .flatMap { kids($0).filter { $0.pathExtension == "app" } }
        var apps = bundles.map { u -> InstalledApp in
            var a = InstalledApp(url: u, name: u.deletingPathExtension().lastPathComponent, bundleID: Bundle(url: u)?.bundleIdentifier, size: 0)
            a.store = store(of: u, fm: fm)
            a.lastUsed = lastUsed(u)
            return a
        }
        let pluginDirs = [system, home].flatMap { root in
            ["Components", "VST", "VST3"].map { root.appendingPathComponent("Library/Audio/Plug-Ins/\($0)") }
        } + [system.appendingPathComponent("Library/Application Support/Avid/Audio/Plug-Ins")]
        apps += pluginDirs.flatMap(kids).filter { pluginExtensions.contains($0.pathExtension.lowercased()) }.map { u in
            var a = InstalledApp(url: u, name: u.deletingPathExtension().lastPathComponent, bundleID: Bundle(url: u)?.bundleIdentifier, size: 0)
            a.kind = .audioPlugin
            return a
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Any app bundle, wherever it is: Finder's "Uninstall with TidyMac" can point at an app outside the usual folders.
    public static func app(at url: URL, fm: FileManager = .default) -> InstalledApp? {
        guard url.pathExtension == "app", fm.fileExists(atPath: url.path) else { return nil }
        var a = InstalledApp(url: url, name: url.deletingPathExtension().lastPathComponent, bundleID: Bundle(url: url)?.bundleIdentifier, size: 0)
        a.store = store(of: url, fm: fm)
        a.lastUsed = lastUsed(url)
        return a
    }

    /// `tidymac://uninstall?path=/Applications/Foo.app` opens the Uninstaller on that app. Finder's service uses it,
    /// and Shortcuts can call it with "Open URLs" (CleanMyMac ships an "Uninstall Application" intent instead).
    public static func uninstallURL(for app: URL) -> URL {
        var c = URLComponents()
        c.scheme = "tidymac"; c.host = "uninstall"
        c.queryItems = [URLQueryItem(name: "path", value: app.standardizedFileURL.path)]
        return c.url!
    }

    /// The app an uninstall link points at; nil for other links and for paths that are not app bundles.
    public static func appURL(fromUninstallURL url: URL) -> URL? {
        guard url.scheme == "tidymac", url.host == "uninstall",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
              path.hasPrefix("/") else { return nil }
        let app = URL(fileURLWithPath: path).standardizedFileURL
        return app.pathExtension == "app" ? app : nil
    }

    static func store(of url: URL, fm: FileManager) -> InstalledApp.Store {
        if fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path) { return .appStore }
        if url.path.contains("/steamapps/") { return .steam }
        if url.deletingLastPathComponent().lastPathComponent == "Setapp" { return .setapp }
        return .other
    }

    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// The bundle itself goes to the Trash when it sits where the executor may move it and the user can delete it;
    /// root-owned apps and system-wide plug-ins go through the administrator prompt instead.
    public static func removalAction(for app: InstalledApp, home: URL = Paths.home, fm: FileManager = .default) -> ItemAction {
        let p = app.url.standardizedFileURL.path
        let movable = p.hasPrefix(home.standardizedFileURL.path + "/") || (p.hasPrefix("/Applications/") && app.url.pathExtension == "app")
        return movable && fm.isDeletableFile(atPath: p) ? .trash(app.url) : .adminDelete(app.url)
    }

    /// Sizing whole bundles is slow, so it is done separately from listing.
    public static func size(of app: InstalledApp) -> Int64 { FileSize.allocated(app.url) }

    /// Everything an app leaves behind, matched by bundle ID (and its helpers' `<id>.*` IDs) or, in support, cache
    /// and log folders, by the app's exact name. `system` is the root of /Library and /var/db; tests point it elsewhere.
    public static func leftovers(for app: InstalledApp, home: URL = Paths.home, system: URL = URL(fileURLWithPath: "/"),
                                 fm: FileManager = .default) -> [Leftover] {
        guard let bid = app.bundleID?.lowercased(), !bid.hasPrefix("com.apple.") else { return [] }
        let names = nameVariants(app)
        let byID = { (n: String) in n == bid || n.hasPrefix(bid + ".") }
        let byIDOrName = { (n: String) in byID(n) || names.contains(n) }
        let homePath = home.standardizedFileURL.path
        var out: [Leftover] = []

        func scan(_ dir: URL, _ kind: Leftover.Kind, _ match: (String) -> Bool) {
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where match(u.lastPathComponent.lowercased()) {
                guard !u.path.hasPrefix(app.url.path + "/") else { continue }
                let inHome = u.standardizedFileURL.path.hasPrefix(homePath + "/")
                out.append(Leftover(url: u, size: FileSize.allocated(u), kind: kind, action: inHome ? .trash(u) : .adminDelete(u)))
            }
        }
        // Some vendors nest per-version folders under their name: Application Support/Google/AndroidStudio2025.1,
        // Caches/JetBrains/IntelliJIdea2025.2. Inside the folder named after the ID's vendor part, a child whose name
        // starts with the app's name (spaces removed) belongs to the app.
        let vendor = bid.split(separator: ".").dropFirst().first.map(String.init)
        func vendorScan(_ dir: URL, _ kind: Leftover.Kind) {
            guard let vendor, vendor.count >= 3 else { return }
            for v in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where v.lastPathComponent.lowercased() == vendor {
                scan(v, kind) { n in
                    let compact = n.replacingOccurrences(of: " ", with: "")
                    return names.contains { !$0.contains(" ") && compact.hasPrefix($0) }
                }
            }
        }
        func bundles(_ dir: URL) {
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                guard let id = Bundle(url: u)?.bundleIdentifier?.lowercased(), byID(id) else { continue }
                let inHome = u.standardizedFileURL.path.hasPrefix(homePath + "/")
                out.append(Leftover(url: u, size: FileSize.allocated(u), kind: .plugins, action: inHome ? .trash(u) : .adminDelete(u)))
            }
        }
        func launchItems(_ dir: URL, admin: Bool) {
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "plist" {
                let d = NSDictionary(contentsOf: u)
                let exe = d?["Program"] as? String ?? (d?["ProgramArguments"] as? [String])?.first ?? ""
                // A job is the app's when it is named after the app's ID or starts a binary inside its bundle.
                guard byID(u.deletingPathExtension().lastPathComponent.lowercased()) || exe.hasPrefix(app.url.path + "/") else { continue }
                out.append(Leftover(url: u, size: FileSize.allocated(u), kind: .launchItems, action: .removeLaunchItem(u, admin: admin)))
            }
        }

        let lib = home.appendingPathComponent("Library")
        scan(lib.appendingPathComponent("Application Support"), .supportingFiles, byIDOrName)
        scan(lib.appendingPathComponent("Application Scripts"), .supportingFiles, byID)
        scan(lib.appendingPathComponent("Saved Application State"), .supportingFiles) { $0 == bid + ".savedstate" }
        scan(lib.appendingPathComponent("HTTPStorages"), .supportingFiles) { byID($0) || $0 == bid + ".binarycookies" }
        scan(lib.appendingPathComponent("Cookies"), .supportingFiles) { $0 == bid + ".binarycookies" }
        scan(lib.appendingPathComponent("Preferences"), .preferences) { byID($0.replacingOccurrences(of: ".plist", with: "")) }
        scan(lib.appendingPathComponent("Preferences/ByHost"), .preferences) { $0.hasPrefix(bid + ".") }
        scan(lib.appendingPathComponent("Caches"), .caches, byIDOrName)
        scan(lib.appendingPathComponent("WebKit"), .caches, byID)
        scan(lib.appendingPathComponent("Containers"), .container, byID)
        // Group containers are named "<team ID>.<group ID>"; the group ID usually starts with the app's ID.
        scan(lib.appendingPathComponent("Group Containers"), .container) { n in
            n.split(separator: ".", maxSplits: 1).count == 2 && byID(String(n.split(separator: ".", maxSplits: 1)[1]))
        }
        scan(lib.appendingPathComponent("Logs"), .logs, byIDOrName)
        vendorScan(lib.appendingPathComponent("Application Support"), .supportingFiles)
        vendorScan(lib.appendingPathComponent("Caches"), .caches)
        vendorScan(lib.appendingPathComponent("Logs"), .logs)
        let crashPrefixes = names.flatMap { [$0 + "-", $0 + "_"] }
        scan(lib.appendingPathComponent("Logs/DiagnosticReports"), .crashes) { n in crashPrefixes.contains { n.hasPrefix($0) } }
        scan(lib.appendingPathComponent("Application Support/CrashReporter"), .crashes) { n in crashPrefixes.contains { n.hasPrefix($0) } }
        launchItems(lib.appendingPathComponent("LaunchAgents"), admin: false)
        for d in ["Internet Plug-Ins", "PreferencePanes", "QuickLook", "Services", "Screen Savers", "Spotlight"] {
            bundles(lib.appendingPathComponent(d))
        }

        let sys = system.appendingPathComponent("Library")
        scan(sys.appendingPathComponent("Application Support"), .supportingFiles, byIDOrName)
        scan(sys.appendingPathComponent("Preferences"), .preferences) { byID($0.replacingOccurrences(of: ".plist", with: "")) }
        scan(sys.appendingPathComponent("Logs"), .logs, byIDOrName)
        scan(sys.appendingPathComponent("PrivilegedHelperTools"), .binaries, byID)
        launchItems(sys.appendingPathComponent("LaunchAgents"), admin: true)
        launchItems(sys.appendingPathComponent("LaunchDaemons"), admin: true)
        for d in ["Internet Plug-Ins", "PreferencePanes", "QuickLook", "Screen Savers", "Spotlight"] {
            bundles(sys.appendingPathComponent(d))
        }
        // Package receipts are only forgotten; the files they list are shared too often to remove blindly.
        for u in (try? fm.contentsOfDirectory(at: system.appendingPathComponent("var/db/receipts"), includingPropertiesForKeys: nil)) ?? []
        where u.pathExtension == "plist" && byID(u.deletingPathExtension().lastPathComponent.lowercased()) {
            let pkg = u.deletingPathExtension().lastPathComponent
            out.append(Leftover(url: u, size: 0, kind: .installers, action: .shell("/usr/sbin/pkgutil --forget \(Executor.quote(pkg))", admin: true)))
        }

        var seen = Set<URL>()
        return out.filter { seen.insert($0.url.standardizedFileURL).inserted }
    }

    /// The app's display name, bundle name and executable, with and without spaces. Short and generic names are left
    /// out: a folder called "Go" or "Launcher" says nothing about who made it.
    static func nameVariants(_ app: InstalledApp) -> Set<String> {
        let info = Bundle(url: app.url)?.infoDictionary
        let raw = [app.name, info?["CFBundleName"] as? String, info?["CFBundleExecutable"] as? String].compactMap { $0?.lowercased() }
        return Set((raw + raw.map { $0.replacingOccurrences(of: " ", with: "") }).filter { $0.count >= 4 && !genericNames.contains($0) })
    }

    static let genericNames: Set<String> = ["applet", "launcher", "helper", "electron", "java", "python", "node", "main",
                                            "update", "updater", "stub", "runner", "application", "default", "studio"]
}
