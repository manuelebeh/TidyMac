import Foundation

/// Cleanup module: System Junk, AI Clutter, Mail Attachments, Trash Bins.
/// Group list mirrors CleanMyMac's SystemJunkScanning `ScanTasksFactory` (see REVERSE.md).
public struct CleanupEngine: ScanEngine {
    public init() {}

    public func scan(progress: @escaping @Sendable (String) -> Void) async -> [ResultGroup] {
        let builders: [@Sendable () -> ResultGroup] = [
            Self.userCache, Self.systemCache, Self.userLogs, Self.systemLogs, Self.xcodeJunk,
            Self.iosBackups, Self.brokenPreferences, Self.brokenLoginItems, Self.deletedUsers,
            Self.aiClutter, Self.localModels, Self.mailAttachments, Self.trashBins,
        ]
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
        "com.apple.bird", "CloudKit", "com.apple.containermanagerd", "FamilyCircle", "com.apple.HomeKit",
        "com.apple.Safari.SafeBrowsing", "com.apple.akd", "com.apple.ap.adprivacyd", "GeoServices",
    ]

    static func userCache() -> ResultGroup {
        let ownID = Bundle.main.bundleIdentifier ?? "dev.local.TidyMac"
        let items = Paths.children(Paths.library.appendingPathComponent("Caches"))
            .filter { !protectedCaches.contains($0.lastPathComponent) && $0.lastPathComponent != ownID }
            .map { ResultItem.file($0) }
        return group("user-cache", "User Cache Files",
                     "Temporary data apps keep to load faster. It is rebuilt automatically.", "archivebox", items)
    }

    static func systemCache() -> ResultGroup {
        let items = Paths.children(URL(fileURLWithPath: "/Library/Caches"))
            .filter { !$0.lastPathComponent.hasPrefix("com.apple.") }
            .map { ResultItem.file($0, selected: false, action: .adminDelete($0)) }
        return group("system-cache", "System Cache Files",
                     "Caches of system-wide services and installers. Removal needs your administrator password.",
                     "gearshape.2", items)
    }

    static func userLogs() -> ResultGroup {
        let items = Paths.children(Paths.library.appendingPathComponent("Logs")).map { ResultItem.file($0) }
        return group("user-logs", "User Log Files", "Activity and crash logs written by your apps.", "doc.text", items)
    }

    static func systemLogs() -> ResultGroup {
        var items = Paths.children(URL(fileURLWithPath: "/Library/Logs"))
            .map { ResultItem.file($0, selected: false, action: .adminDelete($0)) }
        // Only rotated archives in /var/log; live logs stay.
        items += Paths.children(URL(fileURLWithPath: "/private/var/log"))
            .filter { ["gz", "bz2"].contains($0.pathExtension) }
            .map { ResultItem.file($0, selected: false, action: .adminDelete($0)) }
        return group("system-logs", "System Log Files",
                     "Logs of system services. Useful for debugging only. Needs your administrator password.",
                     "doc.text.magnifyingglass", items)
    }

    static func xcodeJunk() -> ResultGroup {
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

    static func iosBackups() -> ResultGroup {
        let backups = Paths.children(Paths.library.appendingPathComponent("Application Support/MobileSync/Backup"))
        // Newest backup per device is flagged "Latest" and never preselected, as in CleanMyMac.
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

    static func brokenPreferences() -> ResultGroup {
        let items = Paths.children(Paths.library.appendingPathComponent("Preferences")).filter { url in
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard url.pathExtension == "plist", v?.isRegularFile == true, (v?.fileSize ?? 0) < 20_000_000,
                  let data = try? Data(contentsOf: url) else { return false }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil
        }.map { ResultItem.file($0) }
        return group("broken-prefs", "Broken Preferences",
                     "Preference files that can no longer be read and may make apps misbehave.", "wrench.adjustable", items)
    }

    static func brokenLoginItems() -> ResultGroup {
        let items = LaunchItems.all().filter { $0.isBroken && !$0.isSystemWide }
            .map { ResultItem.file($0.plist, subtitle: "Missing: \($0.executable ?? "?")", action: .removeLaunchItem($0.plist, admin: false)) }
        return group("broken-login", "Broken Login Items",
                     "Launch agents pointing to apps that are no longer installed.", "bolt.slash", items)
    }

    static func deletedUsers() -> ResultGroup {
        let items = Paths.children(URL(fileURLWithPath: "/Users/Deleted Users"))
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

    static func aiClutter() -> ResultGroup {
        let items = aiPaths.map { (Paths.home($0.0), $0.1) }.filter { Paths.exists($0.0) }
            .map { ResultItem.file($0.0, subtitle: "\($0.1) · \(Paths.abbreviate($0.0.deletingLastPathComponent()))") }
            .filter { ($0.size ?? 0) > 0 }
        return group("ai-junk", "AI Junk Files",
                     "Caches, logs and temporary files created by AI tools such as Claude, Codex, Gemini and Cursor.",
                     "sparkles", items)
    }

    static func localModels() -> ResultGroup {
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

    static func mailAttachments() -> ResultGroup {
        let dl = Paths.library.appendingPathComponent("Containers/com.apple.mail/Data/Library/Mail Downloads")
        let items = Paths.children(dl).map { ResultItem.file($0) }
        return group("mail", "Mail Attachments",
                     "Copies of attachments you opened in Mail. The originals stay on the mail server.", "paperclip", items)
    }

    static func trashBins() -> ResultGroup {
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
