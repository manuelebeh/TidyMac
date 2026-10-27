import AppKit
import ServiceManagement
import TidyCore
import UserNotifications

/// TidyMac's take on CleanMyMac's HealthMonitor login item: checks the Mac in the background while TidyMac runs
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
                UNNotificationCategory(identifier: "drive", actions: [UNNotificationAction(identifier: "show", title: "Show")], intentIdentifiers: []),
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
        let wantThreats = settings.threats && now.timeIntervalSince(lastThreatCheck) >= Self.threatInterval
        let wantTrash = settings.trashSize && now.timeIntervalSince(lastTrashCheck) >= Self.trashInterval
        if wantThreats { lastThreatCheck = now }
        if wantTrash { lastTrashCheck = now }
        let previousTrash = trashSize
        let readings = await Task.detached { () -> HealthAlerts.Readings in
            let memory = SystemMonitor.memory()
            return HealthAlerts.Readings(
                storage: SystemMonitor.storage(), memory: memory,
                trashSize: wantTrash ? SystemMonitor.trash()?.size : previousTrash,
                batteryHealth: SystemMonitor.battery()?.healthPercent,
                threats: wantThreats ? HealthAlerts.currentThreats() : nil,
                topConsumer: memory.pressureLevel >= 2 ? HealthAlerts.topMemoryConsumer() : nil,
                externalDrives: settings.externalDrives ? SystemMonitor.externalDrives() : [],
                bluetooth: settings.bluetooth ? SystemMonitor.bluetoothDevices() : [])
        }.value
        trashSize = readings.trashSize

        var state = HealthAlerts.State.load()
        let due = HealthAlerts.evaluate(readings, settings: settings, state: &state, now: now)
        state.save()
        for alert in due { post(alert) }
    }

    func announceMount(_ url: URL) {
        guard HealthAlerts.Settings.load().driveConnected,
              let drive = SystemMonitor.externalDrives().first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
              !drive.isDiskImage else { return }
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
        content.categoryIdentifier = a.kind == .threat ? "threat" : "issue"
        content.userInfo = ["key": a.key, "target": a.target]
        center.add(UNNotificationRequest(identifier: a.key, content: content, trigger: nil))
    }

    // Shown even while TidyMac is in front, like CleanMyMac's.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let path = info["reveal"] as? String, response.actionIdentifier != UNNotificationDismissActionIdentifier {
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            return
        }
        guard let key = info["key"] as? String else { return }
        let target = info["target"] as? String ?? "smartCare"
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
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

    // MARK: Open at Login (CleanMyMac Menu's setting of the same name)

    static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setOpensAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
