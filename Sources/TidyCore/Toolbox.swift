import Foundation

/// My Tools: single-purpose scans that run one part of a module on its own.
/// Titles, descriptions and search keywords are CleanMyMac's `custom_flow_*` strings (see REVERSE.md).
public struct Tool: Identifiable, Sendable {
    public enum Kind: Sendable { case scan(@Sendable () async -> [ResultGroup]), uninstaller, screenCleaning }

    public let id: String
    public let title: String
    public let description: String
    public let symbol: String
    /// Raw value of the sidebar module the tool comes from; its colours are reused.
    public let module: String
    public let scanTitle: String
    public let keywords: [String]
    public let kind: Kind

    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || title.lowercased().contains(q) || keywords.contains { $0.contains(q) }
    }
}

/// Runs one tool's builder as a regular scan, so the module screens can display it.
public struct ToolEngine: ScanEngine {
    let tool: Tool
    public init(_ tool: Tool) { self.tool = tool }
    public func scan(progress: @escaping @Sendable (String) -> Void) async -> [ResultGroup] {
        guard case .scan(let build) = tool.kind else { return [] }
        progress(tool.title)
        return await build().filter { !$0.isEmpty }
    }
}

public enum Toolbox {
    static func keywords(_ s: String) -> [String] { s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }

    /// A group builder that may block on a privacy prompt gets the same deadline as in Cleanup.
    static func groups(_ builders: [@Sendable () -> ResultGroup]) -> @Sendable () async -> [ResultGroup] {
        {
            var out: [ResultGroup] = []
            for b in builders { if let g = await withDeadline(45, b) { out.append(g) } }
            return out
        }
    }

    static func performance(_ ids: Set<String>) -> @Sendable () async -> [ResultGroup] {
        { await PerformanceEngine().scan { _ in }.filter { ids.contains($0.id) } }
    }

    static func clutter(_ pick: @escaping @Sendable ([ClutterEngine.FileInfo]) -> ResultGroup) -> @Sendable () async -> [ResultGroup] {
        { [pick(ClutterEngine.index(Paths.home))] }
    }

    public static let tools: [Tool] = [
        Tool(id: "screenCleaning", title: "Screen Cleaning Mode",
             description: "Ready to give your screen a proper clean? Keyboard locks — no accidental taps.",
             symbol: "sparkles.tv", module: "smartCare", scanTitle: "",
             keywords: keywords("screen, clean, wipe, keyboard lock, display"), kind: .screenCleaning),
        Tool(id: "aiClutter", title: "AI Clutter",
             description: "Free up space by removing AI tool caches, logs, and local models you no longer need.",
             symbol: "sparkles", module: "cleanup", scanTitle: "Looking for AI Clutter",
             keywords: keywords("ai clutter,ai junk,ai artifacts,ai cache,ai caches,ai logs,ai tools,local models,llm,ollama,lm studio,claude,codex,gemini,cursor"),
             kind: .scan(groups([CleanupEngine.aiClutter, CleanupEngine.localModels]))),
        Tool(id: "leftovers", title: "App Leftovers",
             description: "Locate and remove app leftovers even if the main app is already gone.",
             symbol: "shippingbox.fill", module: "applications", scanTitle: "Looking for app leftovers...",
             keywords: keywords("leftovers,app leftovers,orphan files,residual files,remaining files,uninstaller leftovers,ghost files,app remnants,leftover apps,remove leftovers"),
             kind: .scan({ [ApplicationsEngine.leftovers(installed: Uninstaller.installedApps())] })),
        Tool(id: "updateApps", title: "App Updater",
             description: "Keep an eye on the latest and most reliable versions of your applications.",
             symbol: "arrow.up.circle.fill", module: "applications", scanTitle: "Looking for app updates...",
             keywords: keywords("update apps,app updater,app updates,outdated apps,outdated,new versions,upgrade apps,check for updates,software updates,app upgrades"),
             kind: .scan({ [await ApplicationsEngine.updates(for: Uninstaller.installedApps())] })),
        Tool(id: "applicationPermissions", title: "Application Permissions",
             description: "Manage how apps access system features, devices, and functionality.",
             symbol: "lock.shield.fill", module: "protection", scanTitle: "Scanning app permissions...",
             keywords: keywords("permissions,app permissions,application permissions,full disk access,camera access,microphone access,mic access,screen recording,accessibility,app privacy,review permissions,security permissions,tcc"),
             kind: .scan(groups([ProtectionEngine.permissions]))),
        Tool(id: "backgroundItems", title: "Background Items",
             description: "Manage background apps and processes running on your Mac.",
             symbol: "gearshape.2.fill", module: "performance", scanTitle: "Looking for background items...",
             keywords: keywords("background items,background apps,background processes,launch agents,daemons,helpers,background tasks,running in background,background services"),
             kind: .scan(performance(["background-items"]))),
        Tool(id: "duplicateFinder", title: "Duplicate Finder",
             description: "Remove duplicate files stored in different locations on your Mac.",
             symbol: "doc.on.doc.fill", module: "clutter", scanTitle: "Looking for duplicate files...",
             keywords: keywords("duplicates,duplicate files,find duplicates,check for duplicates,duplicate finder,same files,copies,identical files,redundant files,repeated files"),
             kind: .scan(clutter { ClutterEngine.duplicates($0) })),
        Tool(id: "downloads", title: "Downloads",
             description: "Review and clean one-time use files from Downloads to keep folders tidy.",
             symbol: "arrow.down.circle.fill", module: "clutter", scanTitle: "Scanning downloads...",
             keywords: keywords("downloads,downloads folder,downloaded files,browser downloads,chrome downloads,safari downloads,old downloads,installer files,dmg files"),
             kind: .scan({ [ClutterEngine.downloads(), ApplicationsEngine.unusedInstallers()] })),
        Tool(id: "laof", title: "Large and Old Files",
             description: "Find and remove large, unused files that take up space on your Mac.",
             symbol: "doc.fill", module: "clutter", scanTitle: "Looking for large and old files...",
             keywords: keywords("large files,old files,big files,huge files,free up space,free disk space,storage,space hogs,unused files,forgotten files,old documents,large and old"),
             kind: .scan(clutter { ClutterEngine.largeAndOld($0) })),
        Tool(id: "loginItems", title: "Login Items",
             description: "Manage apps that open automatically when you start your Mac.",
             symbol: "person.badge.clock.fill", module: "performance", scanTitle: "Looking for login items...",
             keywords: keywords("login items,startup items,startup,startup apps,boot items,launch at login,autostart,slow startup,startup programs,login apps"),
             kind: .scan(performance(["login-items"]))),
        Tool(id: "mailAttachments", title: "Mail Attachments",
             description: "Remove locally stored email attachments to free space while keeping modified files.",
             symbol: "paperclip", module: "cleanup", scanTitle: "Looking for mail attachments...",
             keywords: keywords("mail attachments,email attachments,mail,apple mail,attachments,mail downloads,email files,mail cleanup"),
             kind: .scan(groups([CleanupEngine.mailAttachments]))),
        Tool(id: "maintenanceTasks", title: "Maintenance Tasks",
             description: "Run a set of recommended maintenance tasks to bring your Mac to its max.",
             symbol: "wrench.and.screwdriver.fill", module: "performance", scanTitle: "Analyzing your Mac...",
             keywords: keywords("maintenance,maintenance tasks,tune up,optimize,speed up mac,slow mac,reindex spotlight,flush dns,dns cache,free up ram,ram cleaner,repair permissions,speed up mail,periodic scripts,weekly maintenance"),
             kind: .scan(performance(["maintenance"]))),
        Tool(id: "malwareFinder", title: "Malware Finder",
             description: "Identify and remove malicious items to keep your Mac secure.",
             symbol: "ladybug.fill", module: "protection", scanTitle: "Looking for threats...",
             keywords: keywords("malware,virus,viruses,malware scan,virus scan,antivirus,security,scan for malware,trojan,spyware,adware,threats,infection,protection"),
             kind: .scan(groups([ProtectionEngine.suspiciousLaunchItems]))),
        Tool(id: "privacyItems", title: "Privacy Items",
             description: "Remove browsing history and activity traces to protect your privacy.",
             symbol: "hand.raised.fill", module: "protection", scanTitle: "Scanning privacy items...",
             keywords: keywords("privacy,cookies,cache,browsing history,history,autofill,saved logins,downloads history,search history,sessions,recent items,browser data,clear browser,trackers"),
             kind: .scan(groups([ProtectionEngine.privacyItems]))),
        Tool(id: "similarImages", title: "Similar Images",
             description: "Review similar photos and keep only the best ones.",
             symbol: "photo.on.rectangle", module: "clutter", scanTitle: "Looking for similar images...",
             keywords: keywords("similar images,similar photos,find similars,similars,near duplicates,blurry photos,noisy photos,image flaws,photo cleanup,bad photos"),
             kind: .scan(clutter { ClutterEngine.similarImages($0) })),
        Tool(id: "systemJunk", title: "System Junk",
             description: "Remove redundant files that clog up device storage and impede optimal performance.",
             symbol: "archivebox.fill", module: "cleanup", scanTitle: "Looking for system junk...",
             keywords: keywords("system junk,junk,junk files,cache,caches,system cache,user cache,logs,system logs,user logs,temp files,temporary files,clean mac,free up space"),
             kind: .scan(groups([CleanupEngine.userCache, CleanupEngine.systemCache, CleanupEngine.userLogs, CleanupEngine.systemLogs,
                                 CleanupEngine.xcodeJunk, CleanupEngine.iosBackups, CleanupEngine.brokenPreferences,
                                 CleanupEngine.brokenLoginItems, CleanupEngine.deletedUsers]))),
        Tool(id: "timeMachineSnapshot", title: "Time Machine Snapshot",
             description: "Remove local Time Machine snapshots without affecting your backups.",
             symbol: "clock.arrow.circlepath", module: "performance", scanTitle: "Looking for local snapshots...",
             keywords: keywords("time machine,snapshots,local snapshots,tm snapshots,time machine space,local backups,thin snapshots,remove snapshots"),
             kind: .scan(performance(["snapshots"]))),
        Tool(id: "trashBin", title: "Trash Bins",
             description: "Empty all of the available Trash Bins on your Mac.",
             symbol: "trash.fill", module: "cleanup", scanTitle: "Looking for junk...",
             keywords: keywords("trash,trash bin,trash bins,empty trash,empty bin,clear trash,mail trash,delete trash,garbage,recycle bin"),
             kind: .scan(groups([CleanupEngine.trashBins]))),
        Tool(id: "uninstaller", title: "Uninstaller",
             description: "Correctly remove entire applications with all of the related files.",
             symbol: "xmark.app.fill", module: "applications", scanTitle: "",
             keywords: keywords("uninstall,uninstall apps,uninstaller,remove apps,delete apps,remove programs,manage apps,installed apps,unused apps"),
             kind: .uninstaller),
    ]
}
