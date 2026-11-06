import AppKit
import TidyCore
import UserNotifications

/// Runs Settings › Automations rules for `HealthMonitor` and Run Now.
/// "Ask before cleaning" posts what was found with a Clean button; "Clean automatically" cleans, then says how much it freed.
@MainActor
final class AutomationRunner {
    static let shared = AutomationRunner()

    private var running: Set<UUID> = []
    /// Notifications need a bundle id; `swift run` has none, so they are only printed there.
    private var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : .current() }

    /// `confirmed` is the notification's Clean button. Returns what happened, for Settings.
    @discardableResult
    func run(_ rule: Automations.Rule, confirmed: Bool = false) async -> String {
        guard running.insert(rule.id).inserted else { return String(localized: "Already running.") }
        defer { running.remove(rule.id) }
        let items = await Task.detached { await Automations.items(for: rule) }.value
        guard !items.isEmpty else { return String(localized: "Nothing to clean.") }

        let size = items.reduce(0) { $0 + ($1.size ?? 0) }
        let found = size > 0 ? FileSize.format(size) : String(localized: "\(items.count) items")
        if rule.mode == .ask && !confirmed {
            if let center, await center.notificationSettings().authorizationStatus == .denied {
                return String(localized: "Found \(found), but notifications are off, so TidyMac cannot ask you. Nothing was cleaned.")
            }
            post(id: "automation:\(rule.id)", title: rule.name, body: String(localized: "\(found) of junk is ready to clean."),
                 category: "automation", info: ["rule": rule.id.uuidString])
            return String(localized: "Found \(found). Waiting for you to clean it from the notification.")
        }

        let report = await Task.detached { await Executor.run(items) }.value
        var body = String(localized: "\(FileSize.format(report.freed)) of junk cleaned.")
        if !report.failed.isEmpty { body += String(localized: " \(report.failed.count) items could not be removed.") }
        // Clicking the result opens My Activity, which counts the run.
        post(id: "automation:\(rule.id)", title: rule.name, body: body, category: nil, info: ["key": "automation", "target": "activity"])
        return body
    }

    private func post(id: String, title: String, body: String, category: String?, info: [String: String]) {
        guard let center else { print("automation: \(title) — \(body)"); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        content.userInfo = info
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
