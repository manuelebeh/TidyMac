import Foundation

/// Cleanup module: System Junk, AI Clutter, Mail Attachments, Trash Bins.
public struct CleanupEngine: ScanEngine {
    let settings: ScanSettings
    public init(settings: ScanSettings = .load()) { self.settings = settings }

    /// One per result group; Settings › Scanning lists them by title.
    public struct Category: Sendable {
        public let id: String
        public let title: String
        let build: @Sendable () -> ResultGroup
    }

    public static let categories: [Category] = [
        Category(id: "user-cache", title: "User Cache Files", build: userCache),
        Category(id: "system-cache", title: "System Cache Files", build: systemCache),
        Category(id: "user-logs", title: "User Log Files", build: userLogs),
        Category(id: "system-logs", title: "System Log Files", build: systemLogs),
        Category(id: "xcode", title: "Xcode Junk", build: xcodeJunk),
        Category(id: "dev-tools", title: "Developer Tool Caches", build: { devToolCaches() }),
        Category(id: "sim-runtimes", title: "Simulator Runtimes", build: simulatorRuntimes),
        Category(id: "docker", title: "Docker", build: docker),
        Category(id: "ios-backups", title: "iOS Device Backups", build: iosBackups),
        Category(id: "broken-prefs", title: "Broken Preferences", build: brokenPreferences),
        Category(id: "broken-login", title: "Broken Login Items", build: brokenLoginItems),
        Category(id: "deleted-users", title: "Deleted Users", build: deletedUsers),
        Category(id: "ai-junk", title: "AI Junk Files", build: aiClutter),
        Category(id: "local-models", title: "Local Models", build: localModels),
        Category(id: "mail", title: "Mail Attachments", build: mailAttachments),
        Category(id: "trash", title: "Trash Bins", build: trashBins),
    ]

    /// Categories safe to clean with nobody watching: Smart Care keeps their selection and Settings › Automations offers them.
    public static let unattended: Set<String> = ["user-cache", "user-logs", "xcode", "broken-prefs", "broken-login", "ai-junk", "mail", "trash"]

    public func scan(progress: @escaping @Sendable (String) -> Void) async -> [ResultGroup] {
        let builders = Self.categories.filter { settings.scansCleanup($0.id) }.map(\.build)
        return await withTaskGroup(of: (Int, ResultGroup?).self) { tg in
            for (i, b) in builders.enumerated() {
                // A group stuck behind a privacy prompt is dropped instead of freezing the scan.
                tg.addTask { let g = await withDeadline(45, b); if let g { progress(g.title) }; return (i, g) }
            }
            var out: [(Int, ResultGroup)] = []
            for await (i, g) in tg { if let g { out.append((i, g)) } }
            return out.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.isEmpty }
        }
    }

    // MARK: System Junk

    /// Caches whose removal breaks sync or account state rather than just costing a rebuild.
    static let protectedCaches: Set<String> = [
        "com.apple.bird", "CloudKit", "com.apple.cloudkit", "com.apple.cloudd", "com.apple.FileProvider",
        "com.apple.containermanagerd", "FamilyCircle", "com.apple.HomeKit",
        "com.apple.Safari.SafeBrowsing", "com.apple.akd", "com.apple.ap.adprivacyd", "GeoServices",
    ]

    @Sendable static func userCache() -> ResultGroup {
        let ownID = Bundle.main.bundleIdentifier ?? BundleMigration.bundleID
        let items = Paths.children(Paths.library.appendingPathComponent("Caches"))
            .filter { !protectedCaches.contains($0.lastPathComponent) && $0.lastPathComponent != ownID }
            .map { ResultItem.file($0) }
        return group("user-cache", "User Cache Files",
                     "Temporary data apps keep to load faster. It is rebuilt automatically.", "archivebox", items)
    }

    @Sendable static func systemCache() -> ResultGroup {
        let items = Paths.children(URL(fileURLWithPath: "/Library/Caches"))
            .filter { !$0.lastPathComponent.hasPrefix("com.apple.") && !RemovalGuard.isProtectedByMacOS($0) }
            .map { ResultItem.file($0, selected: false, action: .adminDelete($0)) }
        return group("system-cache", "System Cache Files",
                     "Caches of system-wide services and installers. Removal needs your administrator password.",
                     "gearshape.2", items)
    }

    @Sendable static func userLogs() -> ResultGroup {
        let items = Paths.children(Paths.library.appendingPathComponent("Logs")).map { ResultItem.file($0) }
        return group("user-logs", "User Log Files", "Activity and crash logs written by your apps.", "doc.text", items)
    }

    @Sendable static func systemLogs() -> ResultGroup {
        var items = Paths.children(URL(fileURLWithPath: "/Library/Logs"))
            .filter { !RemovalGuard.isProtectedByMacOS($0) }
            .map { ResultItem.file($0, selected: false, action: .adminDelete($0)) }
        // Only rotated archives in /var/log; live logs stay.
        items += Paths.children(URL(fileURLWithPath: "/private/var/log"))
            .filter { ["gz", "bz2"].contains($0.pathExtension) && !RemovalGuard.isProtectedByMacOS($0) }
            .map { ResultItem.file($0, selected: false, action: .adminDelete($0)) }
        return group("system-logs", "System Log Files",
                     "Logs of system services. Useful for debugging only. Needs your administrator password.",
                     "doc.text.magnifyingglass", items)
    }

    @Sendable static func xcodeJunk() -> ResultGroup {
        let dev = Paths.library.appendingPathComponent("Developer")
        let xcode = dev.appendingPathComponent("Xcode")
        var items: [ResultItem] = []
        for d in ["DerivedData", "iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport",
                  "macOS DeviceSupport", "iOS Device Logs"] {
            items += Paths.children(xcode.appendingPathComponent(d)).map { ResultItem.file($0, subtitle: "Xcode › \(d)") }
        }
        items += Paths.children(xcode.appendingPathComponent("Archives"))
            .map { ResultItem.file($0, subtitle: "Xcode › Archives", selected: false) }
        items += Paths.children(dev.appendingPathComponent("CoreSimulator/Caches"))
            .map { ResultItem.file($0, subtitle: "CoreSimulator › Caches") }
        if Paths.exists(URL(fileURLWithPath: "/usr/bin/xcrun")) {
            items.append(ResultItem(id: "simctl-unavailable", title: "Unavailable Simulators",
                                    subtitle: "Simulators for runtimes that are no longer installed",
                                    action: .shell("xcrun simctl delete unavailable", admin: false)))
        }
        return group("xcode", "Xcode Junk",
                     "Derived data, device support files and simulator caches. Xcode recreates what it needs.",
                     "hammer", items.filter { ($0.size ?? 1) > 0 })
    }

    /// Download and build caches kept outside ~/Library/Caches, which User Cache Files already covers. Only what a tool
    /// fetches again by itself is preselected. Not preselected: pnpm's store, which projects share files with, so removing
    /// it may free little; Maven and NuGet folders, which can hold local packages; and browser and model downloads, which
    /// have to be requested again.
    static let devCaches: [(path: String, tool: String, selected: Bool)] = [
        (".npm/_cacache", "npm", true), (".npm/_logs", "npm", true),
        (".cache/yarn", "Yarn", true), (".yarn/berry/cache", "Yarn", true),
        ("Library/pnpm/store", "pnpm", false), (".pnpm-store", "pnpm", false), (".cache/pnpm", "pnpm", false),
        (".bun/install/cache", "Bun", true), (".cache/node-gyp", "node-gyp", true), (".cache/deno", "Deno", true),
        (".cache/pip", "pip", true), (".cache/pypoetry", "Poetry", true), (".cache/uv", "uv", true),
        (".cargo/registry/cache", "Cargo", true), (".cargo/registry/index", "Cargo", true),
        (".cargo/git/db", "Cargo", true), (".cargo/git/checkouts", "Cargo", true),
        ("go/pkg/mod/cache", "Go", true), (".cache/mise", "mise", true),
        (".gradle/caches", "Gradle", true), (".gradle/wrapper/dists", "Gradle", true),
        // Only downloads: the rest of ~/.pub-cache holds globally activated tools.
        (".pub-cache/hosted", "Dart pub", true), (".pub-cache/git", "Dart pub", true),
        ("Library/Application Support/Code/Cache", "VS Code", true), ("Library/Application Support/Code/CachedData", "VS Code", true),
        ("Library/Application Support/Code/CachedExtensionVSIXs", "VS Code", true), ("Library/Application Support/Code/logs", "VS Code", true),
        (".local/share/NuGet/http-cache", "NuGet", true), (".nuget/packages", "NuGet", false), (".m2/repository", "Maven", false),
        (".cache/puppeteer", "Puppeteer", false), (".cache/ms-playwright", "Playwright", false),
        (".cache/huggingface/hub", "Hugging Face", false), (".cache/huggingface/datasets", "Hugging Face", false),
    ]

    static func devToolCaches(home: URL = Paths.home) -> ResultGroup {
        let found = devCaches.map { (url: home.appendingPathComponent($0.path), tool: $0.tool, selected: $0.selected) }
            .filter { Paths.exists($0.url) }
        let sizes = FileSize.allocated(all: found.map(\.url))
        let items = found.indices.map { i in
            ResultItem.file(found[i].url, size: sizes[i], selected: found[i].selected)
                .with(title: "\(found[i].tool): \(found[i].url.lastPathComponent)")
        }
        return group("dev-tools", "Developer Tool Caches",
                     "Packages and build files kept by npm, pnpm, Cargo, Gradle and similar tools. They are downloaded again when a project needs them.",
                     "terminal", items)
    }

    @Sendable static func simulatorRuntimes() -> ResultGroup {
        // Without developer tools, `xcrun` opens the installer dialog; `xcode-select -p` only reports.
        var items: [ResultItem] = []
        if Shell.run("/usr/bin/xcode-select", ["-p"]).status == 0 {
            let r = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"])
            if r.status == 0 { items = simulatorRuntimeItems(json: r.jsonObject) }
        }
        return group("sim-runtimes", "Simulator Runtimes",
                     "iOS, watchOS, tvOS and visionOS simulator images installed for Xcode. A removed runtime has to be downloaded again from Xcode before its simulators can run.",
                     "iphone.gen3", items)
    }

    /// Entries of `xcrun simctl runtime list -j` that simctl says can be deleted. Never preselected.
    static func simulatorRuntimeItems(json: Data, now: Date = Date()) -> [ResultItem] {
        guard let all = (try? JSONSerialization.jsonObject(with: json)) as? [String: [String: Any]] else { return [] }
        let platforms = ["iphone": "iOS", "watch": "watchOS", "appletv": "tvOS", "xr": "visionOS"]
        return all.compactMap { id, r -> ResultItem? in
            guard UUID(uuidString: id) != nil, r["deletable"] as? Bool == true else { return nil }
            let platform = r["platformIdentifier"] as? String ?? ""
            let name = platforms.first { platform.contains($0.key + "simulator") }?.value ?? "Simulator"
            let used = (r["lastUsedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let usage = used.map { "used \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now))" } ?? "never used"
            return ResultItem(id: "sim-runtime:\(id)", title: "\(name) \(r["version"] as? String ?? "")",
                              subtitle: "Build \(r["build"] as? String ?? "?") · \(usage)",
                              size: (r["sizeBytes"] as? NSNumber)?.int64Value,
                              action: .shell("xcrun simctl runtime delete \(id)", admin: false),
                              selectedByDefault: false, badge: used == nil ? "Never Used" : nil)
        }
    }

    /// Running containers, tagged images and volumes are left alone, and a stopped Docker offers nothing. The size stays
    /// out of the totals: `docker system df` also counts unused tagged images, which `prune -f` keeps.
    @Sendable static func docker() -> ResultGroup {
        let r = Shell.run("/usr/bin/env", ["docker", "system", "df", "--format", "{{json .}}"])
        let reclaimable = r.status == 0 ? dockerReclaimable(r.output) : 0
        let items = reclaimable == 0 ? [] : [
            ResultItem(id: "docker-prune", title: "Unused Docker Data",
                       subtitle: "Stopped containers, dangling images, unused networks and build cache. Up to \(FileSize.format(reclaimable)).",
                       action: .shell("docker system prune -f", admin: false), selectedByDefault: false),
        ]
        return group("docker", "Docker", "What `docker system prune` removes. Running containers, tagged images and volumes stay.", "shippingbox.circle", items)
    }

    /// Adds up the "Reclaimable" column of `docker system df --format '{{json .}}'`, without volumes, which a prune keeps.
    static func dockerReclaimable(_ output: String) -> Int64 {
        output.split(separator: "\n").reduce(0) { total, line in
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  row["Type"] as? String != "Local Volumes", let text = row["Reclaimable"] as? String else { return total }
            return total + decimalBytes(text)
        }
    }

    /// "1.2GB (50%)" → 1_200_000_000. Docker prints decimal units.
    static func decimalBytes(_ text: String) -> Int64 {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        let number = token.prefix { $0.isNumber || $0 == "." }
        let units: [String: Double] = ["B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15]
        guard let value = Double(number), let unit = units[String(token.dropFirst(number.count))] else { return 0 }
        return Int64(value * unit)
    }

    @Sendable static func iosBackups() -> ResultGroup {
        let backups = Paths.children(Paths.library.appendingPathComponent("Application Support/MobileSync/Backup"))
        // Newest backup per device is flagged "Latest" and never preselected.
        var byDevice: [String: (URL, Date)] = [:]
        var info: [URL: (String, Date)] = [:]
        for b in backups {
            let plist = NSDictionary(contentsOf: b.appendingPathComponent("Info.plist"))
            let name = plist?["Device Name"] as? String ?? b.lastPathComponent
            let date = plist?["Last Backup Date"] as? Date ?? .distantPast
            info[b] = (name, date)
            if (byDevice[name]?.1 ?? .distantPast) <= date { byDevice[name] = (b, date) }
        }
        let latest = Set(byDevice.values.map(\.0))
        let items = backups.map { b -> ResultItem in
            let (name, date) = info[b] ?? (b.lastPathComponent, .distantPast)
            return ResultItem(title: name, subtitle: date == .distantPast ? nil : DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short),
                              size: FileSize.allocated(b), url: b, action: .trash(b),
                              selectedByDefault: false, badge: latest.contains(b) ? "Latest" : nil)
        }
        return group("ios-backups", "iOS Device Backups", "Local backups of your iPhone and iPad.", "iphone", items)
    }

    @Sendable static func brokenPreferences() -> ResultGroup {
        let items = Paths.children(Paths.library.appendingPathComponent("Preferences")).filter { url in
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard url.pathExtension == "plist", v?.isRegularFile == true, (v?.fileSize ?? 0) < 20_000_000,
                  let data = try? Data(contentsOf: url) else { return false }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil
        }.map { ResultItem.file($0) }
        return group("broken-prefs", "Broken Preferences",
                     "Preference files that can no longer be read and may make apps misbehave.", "wrench.adjustable", items)
    }

    @Sendable static func brokenLoginItems() -> ResultGroup {
        let items = LaunchItems.all().filter { $0.isBroken && !$0.isSystemWide }
            .map { ResultItem.file($0.plist, subtitle: "Missing: \($0.executable ?? "?")", action: .removeLaunchItem($0.plist, admin: false)) }
        return group("broken-login", "Broken Login Items",
                     "Launch agents pointing to apps that are no longer installed.", "bolt.slash", items)
    }

    @Sendable static func deletedUsers() -> ResultGroup {
        let items = Paths.children(URL(fileURLWithPath: "/Users/Deleted Users"))
            .filter { !RemovalGuard.isProtectedByMacOS($0) }
            .map { ResultItem.file($0, selected: false, action: .adminDelete($0)) }
        return group("deleted-users", "Deleted Users", "Data left over from user accounts that were removed.", "person.crop.circle.badge.xmark", items)
    }

    // MARK: AI Clutter

    /// Only caches, logs and temp folders — never config, history or project memory.
    static let aiPaths: [(String, String)] = [
        ("Library/Caches/com.anthropic.claudefordesktop", "Claude"),
        ("Library/Caches/com.anthropic.claudefordesktop.ShipIt", "Claude"),
        ("Library/Logs/Claude", "Claude"),
        ("Library/Application Support/Claude/Cache", "Claude"),
        ("Library/Application Support/Claude/Code Cache", "Claude"),
        ("Library/Application Support/Claude/GPUCache", "Claude"),
        ("Library/Caches/com.openai.chat", "ChatGPT"),
        ("Library/Caches/com.openai.codex", "Codex"),
        (".codex/log", "Codex"),
        (".gemini/tmp", "Gemini"),
        ("Library/Application Support/Cursor/Cache", "Cursor"),
        ("Library/Application Support/Cursor/CachedData", "Cursor"),
        ("Library/Application Support/Cursor/logs", "Cursor"),
        ("Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt", "Cursor"),
        (".cache/huggingface/xet", "Hugging Face"),
    ]

    @Sendable static func aiClutter() -> ResultGroup {
        let items = aiPaths.map { (Paths.home($0.0), $0.1) }.filter { Paths.exists($0.0) }
            .map { ResultItem.file($0.0, subtitle: "\($0.1) · \(Paths.abbreviate($0.0.deletingLastPathComponent()))") }
            .filter { ($0.size ?? 0) > 0 }
        return group("ai-junk", "AI Junk Files",
                     "Caches, logs and temporary files created by AI tools such as Claude, Codex, Gemini and Cursor.",
                     "sparkles", items)
    }

    @Sendable static func localModels() -> ResultGroup {
        var items: [ResultItem] = []
        // Ollama: manifests/<registry>/<namespace>/<model>/<tag> list the blobs a model uses.
        let ollama = Paths.home(".ollama/models")
        let blobs = ollama.appendingPathComponent("blobs")
        if let e = FileManager.default.enumerator(at: ollama.appendingPathComponent("manifests"), includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let m as URL in e where (try? m.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                guard let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: m)) as? [String: Any] else { continue }
                let layers = (json["layers"] as? [[String: Any]] ?? []) + [json["config"] as? [String: Any] ?? [:]]
                let size = layers.compactMap { $0["digest"] as? String }
                    .map { FileSize.allocated(blobs.appendingPathComponent($0.replacingOccurrences(of: ":", with: "-"))) }
                    .reduce(0, +)
                let name = "\(m.deletingLastPathComponent().lastPathComponent):\(m.lastPathComponent)"
                items.append(ResultItem(id: "ollama:\(name)", title: name, subtitle: "Ollama", size: size, url: m,
                                        action: .shell("ollama rm \(Executor.quote(name))", admin: false), selectedByDefault: false))
            }
        }
        // LM Studio: <root>/<publisher>/<model>
        for root in [Paths.home(".lmstudio/models"), Paths.home(".cache/lm-studio/models")] {
            for pub in Paths.children(root) {
                for model in Paths.children(pub) {
                    items.append(.file(model, subtitle: "LM Studio · \(pub.lastPathComponent)", selected: false))
                }
            }
        }
        return group("local-models", "Local Models",
                     "Models downloaded with Ollama and LM Studio. Removing one means downloading it again before use.",
                     "cpu", items)
    }

    // MARK: Mail & Trash

    @Sendable static func mailAttachments() -> ResultGroup {
        let dl = Paths.library.appendingPathComponent("Containers/com.apple.mail/Data/Library/Mail Downloads")
        let items = Paths.children(dl).map { ResultItem.file($0) }
        return group("mail", "Mail Attachments",
                     "Copies of attachments you opened in Mail. The originals stay on the mail server.", "paperclip", items)
    }

    @Sendable static func trashBins() -> ResultGroup {
        var items = Paths.children(Paths.home(".Trash"), hidden: true)
            .filter { $0.lastPathComponent != ".DS_Store" }
            .map { ResultItem.file($0, subtitle: "Trash", action: .delete($0)) }
        for vol in Paths.children(URL(fileURLWithPath: "/Volumes")) {
            let t = vol.appendingPathComponent(".Trashes/\(getuid())")
            items += Paths.children(t, hidden: true).filter { $0.lastPathComponent != ".DS_Store" }
                .map { ResultItem.file($0, subtitle: "Trash on \(vol.lastPathComponent)", action: .delete($0)) }
        }
        return group("trash", "Trash Bins", "Items you already deleted. They are removed for good.", "trash", items)
    }

    static func group(_ id: String, _ title: String, _ desc: String, _ symbol: String, _ items: [ResultItem]) -> ResultGroup {
        ResultGroup(id: id, title: title, description: desc, symbol: symbol,
                    items: items.filter { ($0.size ?? 1) > 0 }.sorted { ($0.size ?? 0) > ($1.size ?? 0) })
    }
}
