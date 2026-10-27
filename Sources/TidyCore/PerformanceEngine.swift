import Foundation

public struct LaunchItem: Sendable {
    public let plist: URL
    public let label: String
    public let executable: String?
    public let arguments: [String]
    public let isSystemWide: Bool
    public let isDaemon: Bool

    /// The job points to a binary that no longer exists.
    public var isBroken: Bool {
        guard let exe = executable, exe.hasPrefix("/") else { return false }
        return !FileManager.default.fileExists(atPath: exe)
    }
}

public enum LaunchItems {
    public static func all() -> [LaunchItem] {
        let dirs: [(URL, Bool, Bool)] = [
            (Paths.library.appendingPathComponent("LaunchAgents"), false, false),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), true, false),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), true, true),
        ]
        return dirs.flatMap { dir, system, daemon in
            Paths.children(dir).filter { $0.pathExtension == "plist" }.map { url in
                let d = NSDictionary(contentsOf: url)
                let args = d?["ProgramArguments"] as? [String] ?? []
                let exe = d?["Program"] as? String ?? args.first
                return LaunchItem(plist: url, label: d?["Label"] as? String ?? url.deletingPathExtension().lastPathComponent,
                                  executable: exe, arguments: args, isSystemWide: system, isDaemon: daemon)
            }
        }
    }
}

/// Performance module: maintenance tasks, login items, background items.
/// Task list = PerformanceScanning `TaskIdentifier` cases (see REVERSE.md).
public struct PerformanceEngine: ScanEngine {
    public init() {}

    public struct Task: Sendable {
        public let id, title, detail, symbol, command: String
        public let admin: Bool
        /// Long-running or disruptive tasks are offered but never preselected.
        public var heavy = false
    }

    public static let tasks: [Task] = [
        Task(id: "freeUpRAM", title: "Free Up RAM", detail: "Flushes inactive memory so apps get room to work.",
             symbol: "memorychip", command: "purge", admin: true),
        Task(id: "flushDNSCache", title: "Flush DNS Cache", detail: "Clears cached domain lookups that may be stale.",
             symbol: "network", command: "dscacheutil -flushcache; killall -HUP mDNSResponder", admin: true),
        Task(id: "speedUpMail", title: "Speed Up Mail", detail: "Rebuilds Mail's envelope index. Mail must be closed.",
             symbol: "envelope", command: "for f in ~/Library/Mail/V*/MailData/Envelope\\ Index; do /usr/bin/sqlite3 \"$f\" vacuum; done",
             admin: false),
        Task(id: "reindexSpotlight", title: "Reindex Spotlight", detail: "Rebuilds the Spotlight index for the startup disk.",
             symbol: "magnifyingglass", command: "mdutil -E /", admin: true, heavy: true),
        Task(id: "repairDiskPermissions", title: "Repair Disk Permissions",
             detail: "Resets permissions on your home folder files.",
             symbol: "lock.shield", command: "diskutil resetUserPermissions / \(getuid())", admin: true, heavy: true),
        Task(id: "periodicScripts", title: "Run Maintenance Scripts",
             detail: "Runs the daily, weekly and monthly system scripts.",
             symbol: "clock.arrow.circlepath", command: "periodic daily weekly monthly", admin: true),
        Task(id: "thinLocalSnapshots", title: "Thin Time Machine Snapshots",
             detail: "Removes local Time Machine snapshots. Backups on your drive are not affected.",
             symbol: "clock.badge.xmark", command: "tmutil thinlocalsnapshots / 999999999999 4", admin: true, heavy: true),
    ]

    public func scan(progress: @escaping @Sendable (String) -> Void) async -> [ResultGroup] {
        progress("Maintenance tasks")
        let lastRun = UserDefaults.standard.dictionary(forKey: "TidyMac.taskRuns") as? [String: Date] ?? [:]
        let tasks = Self.tasks.map { t -> ResultItem in
            let last = lastRun[t.id]
            // Recommend tasks not run in the last week, like CleanMyMac's "recommended" set.
            let due = last.map { Date().timeIntervalSince($0) > 7 * 86_400 } ?? true
            return ResultItem(id: "task:\(t.id)", title: t.title,
                              subtitle: t.detail + (last.map { " Last run \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()))." } ?? ""),
                              action: .shell(t.command, admin: t.admin), selectedByDefault: due && !t.heavy)
        }

        progress("Login items")
        let loginNames = Shell.osascript("tell application \"System Events\" to get the name of every login item").output
        let logins = loginNames.isEmpty || loginNames.contains("execution error") ? [] :
            loginNames.components(separatedBy: ", ").map {
                ResultItem(id: "login:\($0)", title: $0, subtitle: "Opens when you log in",
                           action: .removeLoginItem(name: $0), selectedByDefault: false)
            }

        progress("Background items")
        let agents = LaunchItems.all().filter { !$0.label.hasPrefix("com.apple.") }.map { li in
            ResultItem(id: "launch:\(li.plist.path)", title: li.label,
                       subtitle: (li.isDaemon ? "System daemon" : li.isSystemWide ? "Agent for all users" : "User agent")
                           + (li.isBroken ? " · broken" : ""),
                       url: li.plist, action: .removeLaunchItem(li.plist, admin: li.isSystemWide),
                       selectedByDefault: li.isBroken, badge: li.isBroken ? "Broken" : nil)
        }

        let snapshots = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).output
            .split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }
            .map { s in ResultItem(id: "snap:\(s)", title: String(s), subtitle: "Local Time Machine snapshot",
                                   action: .shell("tmutil deletelocalsnapshots \(s.split(separator: ".").dropFirst(3).first ?? "")", admin: true),
                                   selectedByDefault: false) }

        return [
            ResultGroup(id: "maintenance", title: "Maintenance Tasks",
                        description: "Essential care for your Mac's software and hardware. Most tasks ask for your administrator password once.",
                        symbol: "wrench.and.screwdriver", items: tasks, verb: "to run"),
            ResultGroup(id: "login-items", title: "Login Items",
                        description: "Apps that open automatically when you log in.", symbol: "person.badge.clock",
                        items: logins, verb: "to review"),
            ResultGroup(id: "background-items", title: "Background Items",
                        description: "Launch agents and daemons that run in the background.", symbol: "gearshape.arrow.triangle.2.circlepath",
                        items: agents, verb: "to review"),
            ResultGroup(id: "snapshots", title: "Time Machine Snapshots",
                        description: "Local snapshots kept on the startup disk.", symbol: "clock.arrow.circlepath",
                        items: snapshots, verb: "to remove"),
        ].filter { !$0.isEmpty }
    }

    public static func markRun(_ items: [ResultItem]) {
        var runs = UserDefaults.standard.dictionary(forKey: "TidyMac.taskRuns") as? [String: Date] ?? [:]
        for i in items where i.id.hasPrefix("task:") { runs[String(i.id.dropFirst(5))] = Date() }
        UserDefaults.standard.set(runs, forKey: "TidyMac.taskRuns")
    }
}
