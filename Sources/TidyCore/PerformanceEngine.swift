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
public struct PerformanceEngine: ScanEngine {
    public init() {}

    public struct Task: Sendable {
        public let id, title, detail, symbol: String
        public let command: Command
        public let admin: Bool
        /// Long-running or disruptive tasks are offered but never preselected.
        public var heavy = false
    }

    public static let tasks: [Task] = [
        Task(id: "freeUpRAM", title: String(localized: "Free Up RAM"), detail: String(localized: "Flushes inactive memory so apps get room to work."),
             symbol: "memorychip", command: Command("/usr/sbin/purge"), admin: true),
        Task(id: "flushDNSCache", title: String(localized: "Flush DNS Cache"), detail: String(localized: "Clears cached domain lookups that may be stale."),
             symbol: "network", command: .script("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"), admin: true),
        Task(id: "speedUpMail", title: String(localized: "Speed Up Mail"), detail: String(localized: "Rebuilds Mail's envelope index. Mail must be closed."),
             symbol: "envelope", command: .script("for f in ~/Library/Mail/V*/MailData/Envelope\\ Index; do /usr/bin/sqlite3 \"$f\" vacuum; done"),
             admin: false),
        Task(id: "reindexSpotlight", title: String(localized: "Reindex Spotlight"), detail: String(localized: "Rebuilds the Spotlight index for the startup disk."),
             symbol: "magnifyingglass", command: Command("/usr/bin/mdutil", "-E", "/"), admin: true, heavy: true),
        Task(id: "repairDiskPermissions", title: String(localized: "Repair Disk Permissions"),
             detail: String(localized: "Resets permissions on your home folder files."),
             symbol: "lock.shield", command: Command("/usr/sbin/diskutil", "resetUserPermissions", "/", String(getuid())), admin: true, heavy: true),
        Task(id: "periodicScripts", title: String(localized: "Run Maintenance Scripts"),
             detail: String(localized: "Runs the daily, weekly and monthly system scripts."),
             symbol: "clock.arrow.circlepath", command: Command("/usr/sbin/periodic", "daily", "weekly", "monthly"), admin: true),
        Task(id: "thinLocalSnapshots", title: String(localized: "Thin Time Machine Snapshots"),
             detail: String(localized: "Removes local Time Machine snapshots. Backups on your drive are not affected."),
             symbol: "clock.badge.xmark", command: Command("/usr/bin/tmutil", "thinlocalsnapshots", "/", "999999999999", "4"), admin: true, heavy: true),
    ]

    /// The tasks this Mac can run. macOS drops old tools over time (macOS 27 has no `periodic`), and a task that can only
    /// fail should not be offered, let alone preselected.
    static func availableTasks(isInstalled: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> [Task] {
        tasks.filter { isInstalled($0.command.executable) }
    }

    /// The date `tmutil deletelocalsnapshots` takes, from a line of `tmutil listlocalsnapshots` such as
    /// "com.apple.TimeMachine.2026-11-06-101500.local". nil for any other line.
    static func snapshotDate(_ line: Substring) -> String? {
        guard line.hasPrefix("com.apple.TimeMachine."), let date = line.split(separator: ".").dropFirst(3).first,
              date.allSatisfy({ $0.isNumber || $0 == "-" }) else { return nil }
        return String(date)
    }

    public func scan(progress: @escaping @Sendable (String) -> Void) async -> [ResultGroup] {
        progress(String(localized: "Maintenance tasks"))
        let lastRun = UserDefaults.standard.dictionary(forKey: "TidyMac.taskRuns") as? [String: Date] ?? [:]
        let tasks = Self.availableTasks().map { t -> ResultItem in
            let last = lastRun[t.id]
            // Recommend tasks not run in the last week.
            let due = last.map { Date().timeIntervalSince($0) > 7 * 86_400 } ?? true
            return ResultItem(id: "task:\(t.id)", title: t.title,
                              subtitle: t.detail + (last.map { String(localized: " Last run \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())).") } ?? ""),
                              action: .run(t.command, admin: t.admin), selectedByDefault: due && !t.heavy)
        }

        progress(String(localized: "Login items"))
        let loginNames = Shell.osascript("tell application \"System Events\" to get the name of every login item").output
        let logins = loginNames.isEmpty || loginNames.contains("execution error") ? [] :
            loginNames.components(separatedBy: ", ").map {
                ResultItem(id: "login:\($0)", title: $0, subtitle: String(localized: "Opens when you log in"),
                           action: .removeLoginItem(name: $0), selectedByDefault: false)
            }

        progress(String(localized: "Background items"))
        let agents = LaunchItems.all().filter { !$0.label.hasPrefix("com.apple.") }.map { li in
            ResultItem(id: "launch:\(li.plist.path)", title: li.label,
                       subtitle: (li.isDaemon ? String(localized: "System daemon") : li.isSystemWide ? String(localized: "Agent for all users") : String(localized: "User agent"))
                           + (li.isBroken ? String(localized: " · broken") : ""),
                       url: li.plist, action: .removeLaunchItem(li.plist, admin: li.isSystemWide),
                       selectedByDefault: li.isBroken, badge: li.isBroken ? String(localized: "Broken") : nil)
        }

        let snapshots = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).output
            .split(separator: "\n")
            .compactMap { s -> ResultItem? in
                guard let date = Self.snapshotDate(s) else { return nil }
                return ResultItem(id: "snap:\(s)", title: String(s), subtitle: String(localized: "Local Time Machine snapshot"),
                                  action: .run(Command("/usr/bin/tmutil", "deletelocalsnapshots", date), admin: true),
                                  selectedByDefault: false)
            }

        return [
            ResultGroup(id: "maintenance", title: String(localized: "Maintenance Tasks"),
                        description: String(localized: "Essential care for your Mac's software and hardware. Most tasks ask for your administrator password once."),
                        symbol: "wrench.and.screwdriver", items: tasks, verb: String(localized: "to run")),
            ResultGroup(id: "login-items", title: String(localized: "Login Items"),
                        description: String(localized: "Apps that open automatically when you log in."), symbol: "person.badge.clock",
                        items: logins, verb: String(localized: "to review")),
            ResultGroup(id: "background-items", title: String(localized: "Background Items"),
                        description: String(localized: "Launch agents and daemons that run in the background."), symbol: "gearshape.arrow.triangle.2.circlepath",
                        items: agents, verb: String(localized: "to review")),
            ResultGroup(id: "snapshots", title: String(localized: "Time Machine Snapshots"),
                        description: String(localized: "Local snapshots kept on the startup disk."), symbol: "clock.arrow.circlepath",
                        items: snapshots, verb: String(localized: "to remove")),
        ].filter { !$0.isEmpty }
    }

    public static func markRun(_ items: [ResultItem]) {
        var runs = UserDefaults.standard.dictionary(forKey: "TidyMac.taskRuns") as? [String: Date] ?? [:]
        for i in items where i.id.hasPrefix("task:") { runs[String(i.id.dropFirst(5))] = Date() }
        UserDefaults.standard.set(runs, forKey: "TidyMac.taskRuns")
    }
}
