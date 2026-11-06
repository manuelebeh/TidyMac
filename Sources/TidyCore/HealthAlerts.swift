import Foundation

/// Background alerts, matching the menu's issues:
/// low disk space, Trash over the user's limit, heavy memory usage, critical battery health and threats.
/// The rules are pure so they can be tested; `TidyMac.HealthMonitor` feeds them readings and posts notifications.
public enum HealthAlerts {

    public struct Alert: Equatable, Sendable {
        public enum Kind: String, Sendable { case lowDisk, trashSize, memory, battery, threat, externalFull, bluetoothLow, smartCare, hungApps, heavyChrome, trashedApp }
        public let kind: Kind
        /// One per condition; threats get one per launch item so a new one is reported even if another is ignored.
        public let key: String
        public let title: String
        public let body: String
        /// `Module` raw value to open when the notification is clicked.
        public let target: String
    }

    /// Settings › Notifications. The free space and Trash limits can be changed there.
    public struct Settings: Sendable, Equatable {
        public var lowDisk = true
        public var freeSpaceLimit: Int64 = 10_000_000_000
        public var trashSize = true
        public var trashLimit: Int64 = 2_000_000_000
        public var memory = true
        public var battery = true
        public var threats = true
        public var externalDrives = true
        public var bluetooth = true
        public var driveConnected = true
        /// "Remind to run regular Smart Care", every `smartCareInterval` days.
        public var smartCareReminder = true
        public var smartCareInterval = 7
        public var hungApps = true
        public var heavyChrome = true
        /// "Offer to uninstall applications correctly" when an app lands in the Trash.
        public var trashedApps = true
        public init() {}

        /// Reminder options: Once in 3 Days, Weekly, Every 2 Weeks, Monthly.
        public static let smartCareIntervals: [(days: Int, title: String)] = [(3, String(localized: "Once in 3 Days")), (7, String(localized: "Weekly")), (14, String(localized: "Every 2 Weeks")), (30, String(localized: "Monthly"))]

        public static let defaultsKey = "TidyMac.alerts"
        public static func load(_ d: UserDefaults = .standard) -> Settings {
            var s = Settings()
            func bool(_ k: String, _ v: inout Bool) { if d.object(forKey: "\(defaultsKey).\(k)") != nil { v = d.bool(forKey: "\(defaultsKey).\(k)") } }
            func size(_ k: String, _ v: inout Int64) { if let n = d.object(forKey: "\(defaultsKey).\(k)") as? Int { v = Int64(n) } }
            bool("lowDisk", &s.lowDisk); size("freeSpaceLimit", &s.freeSpaceLimit)
            bool("trashSize", &s.trashSize); size("trashLimit", &s.trashLimit)
            bool("memory", &s.memory); bool("battery", &s.battery); bool("threats", &s.threats)
            bool("externalDrives", &s.externalDrives); bool("bluetooth", &s.bluetooth); bool("driveConnected", &s.driveConnected)
            bool("smartCareReminder", &s.smartCareReminder); bool("hungApps", &s.hungApps)
            bool("heavyChrome", &s.heavyChrome); bool("trashedApps", &s.trashedApps)
            if let n = d.object(forKey: "\(defaultsKey).smartCareInterval") as? Int, n > 0 { s.smartCareInterval = n }
            return s
        }
    }

    public struct Readings: Sendable {
        public var storage: SystemMonitor.Storage
        public var memory: SystemMonitor.Memory
        /// nil without Full Disk Access.
        public var trashSize: Int64?
        public var batteryHealth: Int?
        /// nil when the (slower) threat check did not run this time; the previous threats stay as they were.
        public var threats: [(key: String, name: String)]?
        /// Biggest memory user, named in the memory alert.
        public var topConsumer: (name: String, bytes: Int64)?
        public var externalDrives: [SystemMonitor.Drive] = []
        public var bluetooth: [SystemMonitor.BluetoothDevice] = []
        /// Names of the apps the window server reports as not responding.
        public var hungApps: [String] = []
        /// Google Chrome and its helpers together; nil when Chrome is not running.
        public var chromeMemory: Int64?
        /// Apps in the Trash; nil without Full Disk Access, which leaves the known list as it was.
        public var trashedApps: [String]?
        /// The last run that freed space, for the Smart Care reminder.
        public var lastCleanup: Date?
        public init(storage: SystemMonitor.Storage, memory: SystemMonitor.Memory, trashSize: Int64? = nil, batteryHealth: Int? = nil,
                    threats: [(key: String, name: String)]? = nil, topConsumer: (name: String, bytes: Int64)? = nil,
                    externalDrives: [SystemMonitor.Drive] = [], bluetooth: [SystemMonitor.BluetoothDevice] = [],
                    hungApps: [String] = [], chromeMemory: Int64? = nil, trashedApps: [String]? = nil, lastCleanup: Date? = nil) {
            self.storage = storage; self.memory = memory; self.trashSize = trashSize; self.batteryHealth = batteryHealth
            self.threats = threats; self.topConsumer = topConsumer; self.externalDrives = externalDrives; self.bluetooth = bluetooth
            self.hungApps = hungApps; self.chromeMemory = chromeMemory; self.trashedApps = trashedApps; self.lastCleanup = lastCleanup
        }
    }

    /// What has been said already, persisted so a relaunch does not repeat every alert.
    public struct State: Codable, Equatable, Sendable {
        public var notified: [String: Date] = [:]
        public var snoozed: [String: Date] = [:]
        public var memoryHighSince: Date?
        public var threatKeys: [String] = []
        /// Apps seen in the Trash at the last look; only newcomers are announced. Optional so older saved states still decode.
        public var trashedApps: [String]?
        public init() {}

        public static let defaultsKey = "TidyMac.alertState"
        public static func load(_ d: UserDefaults = .standard) -> State {
            d.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        }
        public func save(_ d: UserDefaults = .standard) {
            if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
        }
        /// The "Ignore" menu: for a day, 3 days, a week, forever.
        public mutating func ignore(_ key: String, for interval: TimeInterval?, now: Date = Date()) {
            snoozed[key] = interval.map { now.addingTimeInterval($0) } ?? .distantFuture
        }
    }

    /// Memory pressure has to stay at "warning" this long before it is worth a notification; "critical" alerts at once.
    public static let memoryGrace: TimeInterval = 5 * 60
    /// Bluetooth battery level that counts as low.
    public static let bluetoothLowLevel = 20

    /// Chrome counts as heavy above a quarter of the RAM, and never below 2 GB (TidyMac's threshold).
    public static func chromeLimit(totalMemory: Int64) -> Int64 { max(2_000_000_000, totalMemory / 4) }

    /// Sums Google Chrome's processes (including Dev, Beta and Canary); nil when none is running.
    public static func chromeMemory(_ consumers: [SystemMonitor.Consumer]) -> Int64? {
        let chrome = consumers.filter { $0.name.hasPrefix("Google Chrome") }
        return chrome.isEmpty ? nil : chrome.reduce(0) { $0 + $1.memory }
    }

    /// How long a condition that is still true stays quiet after being reported. A condition that clears and comes back
    /// is reported again straight away. Threats are only reported once each.
    static func repeatAfter(_ kind: Alert.Kind, settings: Settings) -> TimeInterval? {
        switch kind {
        case .lowDisk: 86_400
        case .trashSize: 3 * 86_400
        case .memory: 3_600
        case .battery: 30 * 86_400
        case .threat: nil
        case .externalFull: 86_400
        case .bluetoothLow: 6 * 3_600
        case .smartCare: Double(settings.smartCareInterval) * 86_400
        case .hungApps, .heavyChrome: 6 * 3_600
        case .trashedApp: nil
        }
    }

    /// Conditions that hold right now, whether or not they were reported before.
    public static func conditions(_ r: Readings, settings s: Settings, state: inout State, now: Date = Date()) -> [Alert] {
        var out: [Alert] = []
        if s.lowDisk, r.storage.total > 0, r.storage.available < s.freeSpaceLimit {
            out.append(Alert(kind: .lowDisk, key: "lowDisk", title: String(localized: "You are running out of disk space!"),
                             body: String(localized: "Only \(FileSize.format(r.storage.available)) left on \(r.storage.name). Launch TidyMac to remove unneeded items and reclaim space."),
                             target: "cleanup"))
        }
        if s.trashSize, let t = r.trashSize, t > s.trashLimit {
            out.append(Alert(kind: .trashSize, key: "trashSize", title: String(localized: "It’s time to empty your Trash!"),
                             body: String(localized: "The size of files in your Trash (\(FileSize.format(t))) has exceeded the \(FileSize.format(s.trashLimit)) limit you have set."),
                             target: "cleanup"))
        }

        let p = r.memory.pressureLevel
        if p >= 2 { state.memoryHighSince = state.memoryHighSince ?? now } else { state.memoryHighSince = nil }
        if s.memory, p >= 4 || (p >= 2 && now.timeIntervalSince(state.memoryHighSince ?? now) >= memoryGrace) {
            let hint = r.topConsumer.map { String(localized: " \($0.name) is using \(FileSize.format($0.bytes)).") } ?? ""
            out.append(Alert(kind: .memory, key: "memory", title: String(localized: "Heavy memory usage"),
                             body: String(localized: "You're running out of memory and your Mac may become noticeably slower.\(hint) Consider quitting some applications."),
                             target: "performance"))
        }
        if s.battery, let h = r.batteryHealth, h < 70 {
            out.append(Alert(kind: .battery, key: "battery", title: String(localized: "Critical battery health"),
                             body: String(localized: "Your Mac’s battery capacity has degraded severely (\(h)% of its original capacity). Consider a battery change."),
                             target: "activity"))
        }

        if s.externalDrives {
            for d in r.externalDrives where d.almostFull {
                out.append(Alert(kind: .externalFull, key: "externalFull:\(d.name)", title: String(localized: "Connected disk is almost full"),
                                 body: String(localized: "\(d.name) has \(FileSize.format(d.available)) available. Open Space Lens to see what takes up space on it."),
                                 target: "spaceLens"))
            }
        }
        let low = r.bluetooth.filter { ($0.lowest ?? 100) <= bluetoothLowLevel }
        if s.bluetooth, !low.isEmpty {
            let names = low.map { "\($0.name) (\($0.lowest ?? 0)%)" }.joined(separator: ", ")
            out.append(Alert(kind: .bluetoothLow, key: "bluetoothLow", title: String(localized: "Time to juice up!"),
                             body: String(localized: "Some of your devices are low on battery: \(names). Connect them to a charger before they shut down."),
                             target: "smartCare"))
        }

        if s.smartCareReminder, let last = r.lastCleanup, now.timeIntervalSince(last) >= Double(s.smartCareInterval) * 86_400 {
            let days = Int(now.timeIntervalSince(last) / 86_400)
            out.append(Alert(kind: .smartCare, key: "smartCare", title: String(localized: "It’s time to care for your Mac!"),
                             body: String(localized: "Your last cleanup was \(days) days ago. Run Smart Care to keep your Mac clean, safe and fast."),
                             target: "smartCare"))
        }
        if s.hungApps, !r.hungApps.isEmpty {
            let one = r.hungApps.count == 1, names = r.hungApps.joined(separator: ", ")
            out.append(Alert(kind: .hungApps, key: "hungApps", title: String(localized: "Non-responsive applications"),
                             body: one
                                 ? String(localized: "\(names) is not responding. Force quit it from TidyMac's menu, or wait until it responds.")
                                 : String(localized: "\(names) are not responding. Force quit them from TidyMac's menu, or wait until they respond."),
                             target: "performance"))
        }
        if s.heavyChrome, let m = r.chromeMemory, m > chromeLimit(totalMemory: r.memory.total) {
            out.append(Alert(kind: .heavyChrome, key: "heavyChrome", title: String(localized: "Chrome memory usage is high"),
                             body: String(localized: "Google Chrome is using \(FileSize.format(m)). High RAM usage may slow down your Mac. Managing your tabs can help free up memory."),
                             target: "performance"))
        }
        if let trashed = r.trashedApps {
            // The first look only learns what is already there.
            if s.trashedApps, let known = state.trashedApps {
                for name in trashed where !known.contains(name) {
                    out.append(Alert(kind: .trashedApp, key: "trashedApp:\(name)", title: String(localized: "Uninstall applications correctly"),
                                     body: String(localized: "\(name) is in the Trash, but the files it created may still be on your Mac. Scan Applications to remove its leftovers."),
                                     target: "applications"))
                }
            }
            state.trashedApps = trashed
        }

        if let threats = r.threats { state.threatKeys = threats.map(\.key) }
        if s.threats {
            for t in r.threats ?? [] {
                out.append(Alert(kind: .threat, key: t.key, title: String(localized: "TidyMac has detected a threat!"),
                                 body: String(localized: "⚠️ A suspicious '\(t.name)' has been found on your Mac. Review it in Protection."),
                                 target: "protection"))
            }
        }
        return out
    }

    /// The alerts to post now: conditions that are new, or due again, and not ignored. Updates `state`.
    public static func evaluate(_ r: Readings, settings: Settings, state: inout State, now: Date = Date()) -> [Alert] {
        let current = conditions(r, settings: settings, state: &state, now: now)
        // A cleared condition is forgotten so it is reported again if it comes back. Threats only clear when a threat check ran.
        let live = Set(current.map(\.key)).union(r.threats == nil ? state.threatKeys : [])
        // Memory pressure comes and goes, so it keeps its hour of quiet even when it clears in between.
        state.notified = state.notified.filter { live.contains($0.key) || ($0.key == "memory" && now.timeIntervalSince($0.value) < 3_600) }

        var due: [Alert] = []
        for a in current {
            if let until = state.snoozed[a.key], until > now { continue }
            if let last = state.notified[a.key] {
                guard let wait = repeatAfter(a.kind, settings: settings), now.timeIntervalSince(last) >= wait else { continue }
            }
            state.notified[a.key] = now
            due.append(a)
        }
        state.snoozed = state.snoozed.filter { $0.value > now }
        return due
    }
}

extension HealthAlerts {
    /// Third-party launch items Protection would flag. Spawns `codesign` per item, so it runs on a slower timer.
    public static func currentThreats() -> [(key: String, name: String)] {
        // Launch items on the Ignore List are not reported again.
        IgnoreList.apply([ProtectionEngine.suspiciousLaunchItems()])[0].items.map { ($0.id, $0.title) }
    }

    /// The app (or process) holding the most memory, by resident size.
    public static func topMemoryConsumer() -> (name: String, bytes: Int64)? {
        SystemMonitor.consumers().max { $0.memory < $1.memory }.map { ($0.name, $0.memory) }
    }
}
