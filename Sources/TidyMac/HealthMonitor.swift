import AppKit
import ServiceManagement
import TidyCore
import UserNotifications

/// Checks the Mac in the background while TidyMac runs
/// (the menu bar item keeps it alive after the window closes) and posts macOS notifications.
@MainActor
final class HealthMonitor: NSObject, UNUserNotificationCenterDelegate {
    static let shared = HealthMonitor()

    private var timer: Timer?
    private var lastThreatCheck = Date.distantPast
    private var lastTrashCheck = Date.distantPast
    private var trashSize: Int64?
    /// Notifications need a bundle id; `swift run` has none, so alerts are only printed there.
    private var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : .current() }

    static let checkInterval: TimeInterval = 60
    static let threatInterval: TimeInterval = 15 * 60
    static let trashInterval: TimeInterval = 5 * 60

    func start() {
        guard timer == nil else { return }
        if let center {
            center.delegate = self
            let review = UNNotificationAction(identifier: "review", title: "Review", options: [.foreground])
            let ignoreDay = UNNotificationAction(identifier: "ignoreDay", title: "Ignore for a Day")
            let ignore = UNNotificationAction(identifier: "ignore", title: "Ignore")
            center.setNotificationCategories([
                UNNotificationCategory(identifier: "issue", actions: [review, ignoreDay], intentIdentifiers: []),
                UNNotificationCategory(identifier: "threat", actions: [review, ignore], intentIdentifiers: []),
                UNNotificationCategory(identifier: "hung", actions: [UNNotificationAction(identifier: "forceQuit", title: "Force Quit All"),
                                                                     UNNotificationAction(identifier: "ignoreDay", title: "Wait")], intentIdentifiers: []),
                UNNotificationCategory(identifier: "drive", actions: [UNNotificationAction(identifier: "show", title: "Show")], intentIdentifiers: []),
                UNNotificationCategory(identifier: "automation", actions: [UNNotificationAction(identifier: "clean", title: "Clean"),
                                                                           UNNotificationAction(identifier: "later", title: "Later")], intentIdentifiers: []),
            ])
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        // "Notify when a drive is connected to the Mac".
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self.announceMount(url) }
        }
        // First check shortly after launch, so it does not compete with the window appearing.
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in Task { @MainActor in await self.check() } }
        Task { try? await Task.sleep(for: .seconds(5)); await check() }
    }

    func check(now: Date = Date()) async {
        let settings = HealthAlerts.Settings.load()
        let rules = Automations.load()
        let needs = Automations.needs(rules)
        let wantThreats = settings.threats && now.timeIntervalSince(lastThreatCheck) >= Self.threatInterval
        let wantTrash = (settings.trashSize || needs.trash) && now.timeIntervalSince(lastTrashCheck) >= Self.trashInterval
        if wantThreats { lastThreatCheck = now }
        if wantTrash { lastTrashCheck = now }
        let previousTrash = trashSize
        let hung = settings.hungApps ? HungApps.current().compactMap(\.localizedName) : []
        let lastCleanup = History.entries.last { $0.freed > 0 }?.date
        let readings = await Task.detached { () -> HealthAlerts.Readings in
            let memory = SystemMonitor.memory()
            return HealthAlerts.Readings(
                storage: SystemMonitor.storage(), memory: memory,
                trashSize: wantTrash ? SystemMonitor.trash()?.size : previousTrash,
                batteryHealth: SystemMonitor.battery()?.healthPercent,
                threats: wantThreats ? HealthAlerts.currentThreats() : nil,
                topConsumer: memory.pressureLevel >= 2 ? HealthAlerts.topMemoryConsumer() : nil,
                externalDrives: settings.externalDrives || needs.drives ? SystemMonitor.externalDrives() : [],
                bluetooth: settings.bluetooth ? SystemMonitor.bluetoothDevices() : [],
                hungApps: hung,
                chromeMemory: settings.heavyChrome ? HealthAlerts.chromeMemory(SystemMonitor.consumers()) : nil,
                // Listed even with the setting off, so turning it on does not announce every app already there.
                trashedApps: SystemMonitor.trashedApps(), lastCleanup: lastCleanup)
        }.value
        trashSize = readings.trashSize

        var state = HealthAlerts.State.load()
        let due = HealthAlerts.evaluate(readings, settings: settings, state: &state, now: now)
        state.save()
        for alert in due { post(alert) }

        // Settings › Automations.
        var runs = Automations.State.load()
        let storage = readings.storage
        let ready = Automations.due(rules, .init(freeSpace: storage.total > 0 ? storage.available : nil, trashSize: readings.trashSize,
                                                 driveAlmostFull: readings.externalDrives.contains(where: \.almostFull)),
                                    state: &runs, now: now)
        runs.save()
        for rule in ready { Task { await AutomationRunner.shared.run(rule) } }

        if SelfUpdate.beginAutomaticCheck(now: now) { Task { await announceUpdate() } }
    }

    /// Settings › Updates, when the daily check is on. A failed check stays silent until the next one.
    private func announceUpdate() async {
        guard case .available(let release)? = try? await SelfUpdate.check(), SelfUpdate.shouldAnnounce(release) else { return }
        let content = UNMutableNotificationContent()
        content.title = "TidyMac \(release.version) is available"
        content.body = "Click to open the download page."
        content.userInfo = ["open": release.page.absoluteString]
        guard let center else { print("alert: \(content.title) — \(content.body)"); return }
        try? await center.add(UNNotificationRequest(identifier: "update:\(release.version)", content: content, trigger: nil))
    }

    func announceMount(_ url: URL) {
        guard let drive = SystemMonitor.externalDrives().first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
              !drive.isDiskImage else { return }
        for rule in Automations.onDriveConnected(Automations.load()) { Task { await AutomationRunner.shared.run(rule) } }
        guard HealthAlerts.Settings.load().driveConnected else { return }
        let content = UNMutableNotificationContent()
        content.title = "\"\(drive.name)\" connected"
        content.body = "\(FileSize.format(drive.available)) available of \(FileSize.format(drive.total)). Click to show the drive in Finder."
        content.categoryIdentifier = "drive"
        content.userInfo = ["reveal": drive.url.path]
        guard let center else { print("alert: \(content.title) — \(content.body)"); return }
        center.add(UNNotificationRequest(identifier: "mount:\(drive.url.path)", content: content, trigger: nil))
        // Its free space is checked right away rather than at the next minute.
        Task { await check() }
    }

    func post(_ a: HealthAlerts.Alert) {
        guard let center else { print("alert: \(a.title) — \(a.body)"); return }
        let content = UNMutableNotificationContent()
        content.title = a.title
        content.body = a.body
        content.sound = .default
        content.categoryIdentifier = a.kind == .threat ? "threat" : a.kind == .hungApps ? "hung" : "issue"
        content.userInfo = ["key": a.key, "target": a.target]
        center.add(UNNotificationRequest(identifier: a.key, content: content, trigger: nil))
    }

    // Shown even while TidyMac is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let path = info["reveal"] as? String, response.actionIdentifier != UNNotificationDismissActionIdentifier {
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            return
        }
        if let link = info["open"] as? String, let url = URL(string: link) {
            if response.actionIdentifier != UNNotificationDismissActionIdentifier { await MainActor.run { _ = NSWorkspace.shared.open(url) } }
            return
        }
        // An automation that asks before cleaning.
        if let rule = info["rule"] as? String {
            let action = response.actionIdentifier
            await MainActor.run {
                switch action {
                case "clean":
                    guard let r = Automations.load().first(where: { $0.id.uuidString == rule }) else { return }
                    Task { await AutomationRunner.shared.run(r, confirmed: true) }
                case UNNotificationDefaultActionIdentifier: NSWorkspace.shared.open(URL(string: "tidymac://open/cleanup")!)
                default: break
                }
            }
            return
        }
        guard let key = info["key"] as? String else { return }
        let target = info["target"] as? String ?? "smartCare"
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case "forceQuit":
                for app in HungApps.current() { app.forceTerminate() }
            case "ignoreDay", "ignore":
                var state = HealthAlerts.State.load()
                state.ignore(key, for: action == "ignore" ? nil : 86_400)
                state.save()
            case UNNotificationDismissActionIdentifier: break
            default:
                // Opens (or brings back) the main window on the module that can fix the issue; see RootView.onOpenURL.
                NSWorkspace.shared.open(URL(string: "tidymac://open/\(target)")!)
            }
        }
    }

    // MARK: Open at Login

    static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setOpensAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
