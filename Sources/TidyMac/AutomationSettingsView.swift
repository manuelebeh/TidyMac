import SwiftUI
import TidyCore
import UserNotifications

/// Settings › Automations: rules that clean on a schedule or when something happens on the Mac.
struct AutomationSettingsView: View {
    @State private var rules = Automations.load()
    @State private var editing: Editing?
    @State private var results: [UUID: String] = [:]
    @State private var authorization: UNAuthorizationStatus?

    struct Editing: Identifiable {
        var rule: Automations.Rule
        let isNew: Bool
        var id: UUID { rule.id }
    }

    var body: some View {
        Form {
            if authorization == .denied {
                Section {
                    Label("Notifications are turned off for TidyMac. Rules that ask before cleaning cannot reach you.", systemImage: "bell.slash")
                }
            }
            Section {
                if rules.isEmpty {
                    Text("No automations yet. Add one to clean junk on a schedule, or when your Mac needs it.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach($rules) { $rule in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                            Text(rule.summary).font(.caption).foregroundStyle(.secondary)
                            if let r = results[rule.id] { Text(r).font(.caption) }
                        }
                        Spacer()
                        Button("Run Now") { runNow(rule) }.disabled(results[rule.id] == "Running…")
                        Button("Edit") { editing = Editing(rule: rule, isNew: false) }
                        Toggle(rule.name, isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .contextMenu {
                        Button("Edit…") { editing = Editing(rule: rule, isNew: false) }
                        Button("Delete", role: .destructive) { delete(rule.id) }
                    }
                }
                Menu("Add Rule") {
                    ForEach(Self.presets, id: \.name) { p in
                        Button(p.name) { editing = Editing(rule: p.rule(), isNew: true) }
                    }
                }
                .fixedSize()
            } header: {
                Text("Rules")
            } footer: {
                Text("Rules run while TidyMac or its menu is running; turn on Open at Login in Notifications to keep them going. A scheduled run missed while the Mac was off happens at the next check. Nothing that needs your administrator password runs automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .onChange(of: rules) { Automations.save($0) }
        .sheet(item: $editing) { e in
            RuleEditor(rule: e.rule, isNew: e.isNew, save: { saved in
                if let i = rules.firstIndex(where: { $0.id == saved.id }) { rules[i] = saved } else { rules.append(saved) }
            }, delete: { delete(e.rule.id) })
        }
        .task {
            guard Bundle.main.bundleIdentifier != nil else { return }
            authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    /// Follows the rule's mode, so a rule that asks first only posts what it found.
    private func runNow(_ rule: Automations.Rule) {
        results[rule.id] = "Running…"
        Task { results[rule.id] = await AutomationRunner.shared.run(rule) }
    }

    private func delete(_ id: UUID) {
        rules.removeAll { $0.id == id }
        results[id] = nil
    }

    /// One starting point per trigger; each opens in the editor.
    static let presets: [(name: String, rule: () -> Automations.Rule)] = [
        ("Weekly Cleanup", { .init(name: "Weekly Cleanup", trigger: .schedule(.init()), categories: ["user-cache", "user-logs", "ai-junk", "broken-prefs"]) }),
        ("When Free Space Is Low", { .init(name: "Low Disk Space", trigger: .freeSpaceBelow(10_000_000_000), categories: ["user-cache", "user-logs", "xcode", "ai-junk"]) }),
        ("When Trash Gets Too Big", { .init(name: "Empty Trash", trigger: .trashOver(5_000_000_000), categories: ["trash"]) }),
        ("When an External Drive Is Almost Full", { .init(name: "Full External Drive", trigger: .driveAlmostFull, categories: ["trash"]) }),
        ("When a Drive Is Connected", { .init(name: "Drive Connected", trigger: .driveConnected, categories: ["trash"]) }),
    ]
}

/// Adds or changes one rule.
struct RuleEditor: View {
    @State var rule: Automations.Rule
    let isNew: Bool
    let save: (Automations.Rule) -> Void
    let delete: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Kind: String, CaseIterable {
        case schedule = "On a Schedule", freeSpace = "Free Space Is Below", trash = "Trash Size Exceeds"
        case driveFull = "An External Drive Is Almost Full", driveConnected = "A Drive Is Connected"
    }

    private let freeSpaceOptions: [Int64] = [5, 10, 20, 50].map { $0 * 1_000_000_000 }
    private let trashOptions: [Int64] = [1, 2, 5, 10, 20].map { $0 * 1_000_000_000 }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $rule.name)
                }
                Section("When") {
                    Picker("Trigger", selection: kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    switch kind.wrappedValue {
                    case .schedule:
                        Picker("Repeat", selection: schedule.frequency) {
                            Text("Daily").tag(Automations.Frequency.daily)
                            Text("Weekly").tag(Automations.Frequency.weekly)
                            Text("Monthly").tag(Automations.Frequency.monthly)
                        }
                        if schedule.wrappedValue.frequency == .weekly {
                            Picker("On", selection: schedule.weekday) {
                                ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                            }
                        }
                        if schedule.wrappedValue.frequency == .monthly {
                            Picker("On day", selection: schedule.day) { ForEach(1...28, id: \.self) { Text("\($0)").tag($0) } }
                        }
                        Picker("At", selection: schedule.hour) { ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0) } }
                    case .freeSpace:
                        Picker("Limit", selection: limit) { ForEach(freeSpaceOptions, id: \.self) { Text(FileSize.format($0)).tag($0) } }
                    case .trash:
                        Picker("Limit", selection: limit) { ForEach(trashOptions, id: \.self) { Text(FileSize.format($0)).tag($0) } }
                        if SystemMonitor.trash() == nil {
                            Text("Allow Full Disk Access so TidyMac can measure the Trash.").font(.caption).foregroundStyle(.secondary)
                        }
                    case .driveFull, .driveConnected:
                        EmptyView()
                    }
                }
                Section {
                    ForEach(CleanupEngine.categories.filter { CleanupEngine.unattended.contains($0.id) }, id: \.id) { c in
                        Toggle(c.title, isOn: Binding(get: { rule.categories.contains(c.id) }, set: { on in
                            if on { rule.categories.append(c.id) } else { rule.categories.removeAll { $0 == c.id } }
                        }))
                    }
                } header: {
                    Text("Clean")
                } footer: {
                    Text(rule.categories.contains("trash") ? "Trash Bins includes the Trash on connected drives. Those files are deleted for good." : "Items are moved to the Trash.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Mode", selection: $rule.mode) {
                        Text("Ask before cleaning").tag(Automations.Mode.ask)
                        Text("Clean automatically").tag(Automations.Mode.auto)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                } footer: {
                    Text(rule.mode == .ask ? "A notification says how much was found; nothing is removed until you click Clean."
                                           : "TidyMac cleans right away, then tells you how much it freed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if !isNew { Button("Delete Rule", role: .destructive) { delete(); dismiss() } }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save(rule); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.categories.isEmpty || rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        // Shorter than the Settings window, which a sheet cannot outgrow; the form scrolls.
        .frame(width: 460, height: 480)
    }

    static func hour(_ h: Int) -> String { String(format: "%02d:00", h) }

    private var kind: Binding<Kind> {
        Binding(get: {
            switch rule.trigger {
            case .schedule: .schedule
            case .freeSpaceBelow: .freeSpace
            case .trashOver: .trash
            case .driveAlmostFull: .driveFull
            case .driveConnected: .driveConnected
            }
        }, set: { k in
            switch k {
            case .schedule: rule.trigger = .schedule(.init())
            case .freeSpace: rule.trigger = .freeSpaceBelow(10_000_000_000)
            case .trash: rule.trigger = .trashOver(5_000_000_000)
            case .driveFull: rule.trigger = .driveAlmostFull
            case .driveConnected: rule.trigger = .driveConnected
            }
        })
    }

    private var schedule: Binding<Automations.Schedule> {
        Binding(get: {
            if case .schedule(let s) = rule.trigger { return s }
            return .init()
        }, set: { rule.trigger = .schedule($0) })
    }

    private var limit: Binding<Int64> {
        Binding(get: {
            switch rule.trigger {
            case .freeSpaceBelow(let l), .trashOver(let l): l
            default: 0
            }
        }, set: { l in
            if case .trashOver = rule.trigger { rule.trigger = .trashOver(l) } else { rule.trigger = .freeSpaceBelow(l) }
        })
    }
}

extension Automations.Rule {
    /// "Weekly on Monday at 10:00 · 3 categories · Asks first".
    var summary: String {
        let when: String
        switch trigger {
        case .schedule(let s):
            let at = RuleEditor.hour(s.hour)
            switch s.frequency {
            case .daily: when = "Daily at \(at)"
            case .weekly: when = "Weekly on \(Calendar.current.weekdaySymbols[s.weekday - 1]) at \(at)"
            case .monthly: when = "Monthly on day \(s.day) at \(at)"
            }
        case .freeSpaceBelow(let l): when = "When free space is below \(FileSize.format(l))"
        case .trashOver(let l): when = "When the Trash exceeds \(FileSize.format(l))"
        case .driveAlmostFull: when = "When an external drive is almost full"
        case .driveConnected: when = "When a drive is connected"
        }
        let titles = CleanupEngine.categories.filter { categories.contains($0.id) }.map(\.title)
        let what = titles.count <= 2 ? titles.joined(separator: ", ") : "\(titles.count) categories"
        return [when, what, mode == .ask ? "Asks first" : "Cleans automatically"].joined(separator: " · ")
    }
}
