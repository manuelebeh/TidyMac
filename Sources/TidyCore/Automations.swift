import Foundation

/// Settings › Automations: rules that clean on a schedule, or when a condition appears, without opening TidyMac.
/// A rule is a trigger, the Cleanup categories to clean, and whether to ask first.
/// The rules are pure so they can be tested; `TidyMac.AutomationRunner` runs the ones `due` returns.
public enum Automations {
    /// "Ask before cleaning" posts what was found with a Clean button; "Clean automatically" cleans and reports.
    public enum Mode: String, Codable, CaseIterable, Sendable { case ask, auto }

    public enum Frequency: String, Codable, CaseIterable, Sendable { case daily, weekly, monthly }

    public struct Schedule: Codable, Equatable, Sendable {
        public var frequency: Frequency = .weekly
        public var hour = 10
        /// 1 is Sunday, as in `Calendar`.
        public var weekday = 2
        /// Up to 28, so every month has it.
        public var day = 1
        public init(frequency: Frequency = .weekly, hour: Int = 10, weekday: Int = 2, day: Int = 1) {
            self.frequency = frequency; self.hour = hour; self.weekday = weekday; self.day = day
        }

        var components: DateComponents {
            switch frequency {
            case .daily: DateComponents(hour: hour, minute: 0)
            case .weekly: DateComponents(hour: hour, minute: 0, weekday: weekday)
            case .monthly: DateComponents(day: day, hour: hour, minute: 0)
            }
        }

        /// The latest time this schedule came round, at or before `now`.
        public func previous(_ now: Date, calendar: Calendar = .current) -> Date? {
            if calendar.date(now, matchesComponents: components), calendar.component(.second, from: now) == 0 { return now }
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime, direction: .backward)
        }
    }

    public enum Trigger: Codable, Equatable, Sendable {
        case schedule(Schedule)
        case freeSpaceBelow(Int64)
        case trashOver(Int64)
        case driveAlmostFull
        case driveConnected
    }

    public struct Rule: Codable, Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var name: String
        public var enabled = true
        public var trigger: Trigger
        /// `CleanupEngine.unattended` category IDs.
        public var categories: [String]
        public var mode: Mode = .ask
        /// A schedule only counts slots after this, so a new rule does not run at once for last week's slot.
        public var created = Date()

        public init(name: String, trigger: Trigger, categories: [String], mode: Mode = .ask, created: Date = Date()) {
            self.name = name; self.trigger = trigger; self.categories = categories; self.mode = mode; self.created = created
        }
    }

    /// What the background check knows; nil when it could not tell (Trash size without Full Disk Access).
    public struct Readings: Sendable {
        public var freeSpace: Int64?
        public var trashSize: Int64?
        public var driveAlmostFull = false
        public init(freeSpace: Int64? = nil, trashSize: Int64? = nil, driveAlmostFull: Bool = false) {
            self.freeSpace = freeSpace; self.trashSize = trashSize; self.driveAlmostFull = driveAlmostFull
        }
    }

    /// When each rule last ran, kept apart from the rules so editing them in Settings does not race the background check.
    public struct State: Codable, Equatable, Sendable {
        public var lastRun: [UUID: Date] = [:]
        /// Condition rules whose condition held at the last check; they run again only once it has cleared.
        public var held: Set<UUID> = []
        public init() {}

        public static let defaultsKey = "TidyMac.automationState"
        public static func load(_ d: UserDefaults = .standard) -> State {
            d.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        }
        public func save(_ d: UserDefaults = .standard) {
            if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
        }
    }

    public static let defaultsKey = "TidyMac.automations"
    public static func load(_ d: UserDefaults = .standard) -> [Rule] {
        d.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([Rule].self, from: $0) } ?? []
    }
    public static func save(_ rules: [Rule], _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(rules) { d.set(data, forKey: defaultsKey) }
    }

    /// Rules to run now. A schedule runs once per slot, and a slot missed while the Mac was off or TidyMac closed
    /// runs at the next check. A condition runs when it appears, and again only after it has cleared. Updates `state`.
    public static func due(_ rules: [Rule], _ r: Readings, state: inout State, now: Date = Date(), calendar: Calendar = .current) -> [Rule] {
        var out: [Rule] = []
        for rule in rules where rule.enabled {
            if case .schedule(let s) = rule.trigger {
                guard let slot = s.previous(now, calendar: calendar), slot > max(rule.created, state.lastRun[rule.id] ?? .distantPast) else { continue }
                out.append(rule)
            } else if let holds = holds(rule.trigger, r) {
                if !holds { state.held.remove(rule.id) } else if state.held.insert(rule.id).inserted { out.append(rule) }
            }
        }
        for rule in out { state.lastRun[rule.id] = now }
        // Deleted rules are forgotten; a turned-off rule re-arms, so turning it back on runs it if its condition holds.
        let ids = Set(rules.map(\.id)), on = Set(rules.filter(\.enabled).map(\.id))
        state.lastRun = state.lastRun.filter { ids.contains($0.key) }
        state.held = state.held.intersection(on)
        return out
    }

    /// nil for event triggers, and when the reading is unknown, which leaves the rule as it was.
    static func holds(_ t: Trigger, _ r: Readings) -> Bool? {
        switch t {
        case .schedule, .driveConnected: nil
        case .freeSpaceBelow(let limit): r.freeSpace.map { $0 < limit }
        case .trashOver(let limit): r.trashSize.map { $0 > limit }
        case .driveAlmostFull: r.driveAlmostFull
        }
    }

    /// Rules to run when a drive is connected.
    public static func onDriveConnected(_ rules: [Rule]) -> [Rule] {
        rules.filter { $0.enabled && $0.trigger == .driveConnected }
    }

    /// Whether the background check has to read the Trash size or the external drives for these rules.
    public static func needs(_ rules: [Rule]) -> (trash: Bool, drives: Bool) {
        let on = rules.filter(\.enabled).map(\.trigger)
        return (on.contains { if case .trashOver = $0 { true } else { false } }, on.contains(.driveAlmostFull))
    }

    /// What a rule would clean right now: its categories' preselected items, minus the Ignore List
    /// and anything that would ask for the administrator password, which nobody is there to type.
    public static func items(for rule: Rule) async -> [ResultItem] {
        let builders = CleanupEngine.categories.filter { rule.categories.contains($0.id) && CleanupEngine.unattended.contains($0.id) }.map(\.build)
        var groups: [ResultGroup] = []
        // A category stuck behind a privacy prompt is skipped, as in a scan.
        for b in builders { if let g = await withDeadline(45, b), !g.isEmpty { groups.append(g) } }
        return IgnoreList.apply(groups).flatMap(\.items).filter { $0.selectedByDefault && runsUnattended($0.action) }
    }

    static func runsUnattended(_ a: ItemAction, fm: FileManager = .default) -> Bool {
        switch a {
        case .trash, .removeLoginItem: true
        // `Executor` falls back to an administrator prompt for Trash items it cannot delete.
        case .delete(let url): fm.isDeletableFile(atPath: url.path)
        case .shell(_, let admin), .removeLaunchItem(_, let admin): !admin
        case .adminDelete, .open: false
        }
    }
}
