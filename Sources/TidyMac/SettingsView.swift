import SwiftUI
import TidyCore
import UserNotifications

/// TidyMac › Settings (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettingsView().tabItem { Label("Notifications", systemImage: "bell") }
            ScanSettingsView().tabItem { Label("Scanning", systemImage: "magnifyingglass") }
            AutomationSettingsView().tabItem { Label("Automations", systemImage: "clock.arrow.circlepath") }
            IgnoreListSettingsView().tabItem { Label("Ignore List", systemImage: "eye.slash") }
            UpdateSettingsView().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
    }
}

/// Settings › Updates. Asks GitHub only when requested, or once a day if that is turned on, and never installs anything.
struct UpdateSettingsView: View {
    private enum Status: Equatable { case idle, checking, failed, finished(SelfUpdate.Outcome) }

    @AppStorage(GeneralSettings.checkUpdatesKey) private var checksDaily = false
    @State private var status = Status.idle

    private var versionLabel: String {
        guard let version = SelfUpdate.currentVersion else { return String(localized: "Development build") }
        return SelfUpdate.currentBuild.map { "\(version) (\($0))" } ?? version
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: versionLabel)
                HStack {
                    statusView
                    Spacer()
                    Button("Check Now") { Task { await check() } }.disabled(status == .checking)
                }
                Toggle("Check for new versions once a day", isOn: $checksDaily)
            } footer: {
                Text("A check asks GitHub for the latest release of TidyMac and sends nothing about your Mac. New versions are installed by you, never automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Link("Project page", destination: SelfUpdate.projectPage)
                Link("Report a problem", destination: SelfUpdate.issuesPage)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .idle: Text("Not checked yet").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        case .failed: Label("Could not reach GitHub. Try again later.", systemImage: "exclamationmark.triangle")
        case .finished(.upToDate): Label("TidyMac is up to date.", systemImage: "checkmark.circle")
        case .finished(.available(let release)): Link("Download TidyMac \(release.version)", destination: release.page)
        }
    }

    private func check() async {
        status = .checking
        if let outcome = try? await SelfUpdate.check() { status = .finished(outcome) } else { status = .failed }
    }
}

/// Settings › Notifications, plus the menu's "Open at Login".
struct NotificationSettingsView: View {
    private static let k = HealthAlerts.Settings.defaultsKey
    private static let d = HealthAlerts.Settings()
    @AppStorage("\(k).lowDisk") private var lowDisk = d.lowDisk
    @AppStorage("\(k).freeSpaceLimit") private var freeSpaceLimit = Int(d.freeSpaceLimit)
    @AppStorage("\(k).trashSize") private var trashSize = d.trashSize
    @AppStorage("\(k).trashLimit") private var trashLimit = Int(d.trashLimit)
    @AppStorage("\(k).memory") private var memory = d.memory
    @AppStorage("\(k).battery") private var battery = d.battery
    @AppStorage("\(k).threats") private var threats = d.threats
    @AppStorage("\(k).externalDrives") private var externalDrives = d.externalDrives
    @AppStorage("\(k).driveConnected") private var driveConnected = d.driveConnected
    @AppStorage("\(k).bluetooth") private var bluetooth = d.bluetooth
    @AppStorage("\(k).smartCareReminder") private var smartCareReminder = d.smartCareReminder
    @AppStorage("\(k).smartCareInterval") private var smartCareInterval = d.smartCareInterval
    @AppStorage("\(k).hungApps") private var hungApps = d.hungApps
    @AppStorage("\(k).heavyChrome") private var heavyChrome = d.heavyChrome
    @AppStorage("\(k).trashedApps") private var trashedApps = d.trashedApps
    @AppStorage(GeneralSettings.cleanOnEjectKey) private var cleanOnEject = false

    @State private var openAtLogin = HealthMonitor.opensAtLogin
    @State private var loginError: String?
    @State private var authorization: UNAuthorizationStatus?

    private let freeSpaceOptions = [5, 10, 20, 50].map { $0 * 1_000_000_000 }
    private let trashOptions = [500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000]

    var body: some View {
        Form {
            if authorization == .denied {
                Section {
                    HStack {
                        Label("Notifications are turned off for TidyMac.", systemImage: "bell.slash")
                        Spacer()
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
            }
            Section("Disk Space") {
                limitRow("Warn when free space is less than", isOn: $lowDisk, limit: $freeSpaceLimit, options: freeSpaceOptions)
                limitRow("Notify if Trash size exceeds", isOn: $trashSize, limit: $trashLimit, options: trashOptions)
                if trashSize, SystemMonitor.trash() == nil {
                    Text("Allow Full Disk Access to analyze Trash contents.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Suggest to clean up overfilled external drives", isOn: $externalDrives)
                Toggle("Notify when a drive is connected to the Mac", isOn: $driveConnected)
            }
            Section("General") {
                HStack {
                    Toggle("Remind to run regular Smart Care", isOn: $smartCareReminder)
                    Spacer()
                    Picker("Remind to run regular Smart Care", selection: $smartCareInterval) {
                        ForEach(HealthAlerts.Settings.smartCareIntervals, id: \.days) { Text($0.title).tag($0.days) }
                    }
                    .labelsHidden().fixedSize().disabled(!smartCareReminder)
                }
                Toggle("Notify when too low on free RAM", isOn: $memory)
                Toggle("Warn about critical battery health", isOn: $battery)
                Toggle("Warn when connected device batteries are running low", isOn: $bluetooth)
            }
            Section("Applications") {
                described("Offer to uninstall applications correctly", isOn: $trashedApps,
                          "If you put an application into Trash, you will be offered to remove the files it left behind.")
                if trashedApps, SystemMonitor.trashedApps() == nil {
                    Text("Allow Full Disk Access so TidyMac can see apps in the Trash.").font(.caption).foregroundStyle(.secondary)
                }
                described("Notify about hung applications", isOn: $hungApps,
                          "If any of your apps stop responding, force quit them right from the notification.")
                Toggle("Notify when Chrome uses too much memory", isOn: $heavyChrome)
            }
            Section {
                Toggle("Notify about detected threats", isOn: $threats)
            } header: {
                Text("Protection")
            } footer: {
                Text("Checks launch agents and daemons every 15 minutes while TidyMac or its menu is running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: { on in
                    do { try HealthMonitor.setOpensAtLogin(on); loginError = nil } catch { loginError = error.localizedDescription }
                    openAtLogin = HealthMonitor.opensAtLogin
                }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                described("Clean up junk automatically on ejection", isOn: $cleanOnEject,
                          "Ejecting a drive from the menu first empties that drive's Trash. Those files are deleted for good.")
            } header: {
                Text("Menu")
            } footer: {
                Text("Open at Login keeps the menu and its alerts running after a restart.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Scrolls rather than growing past a laptop screen.
        .frame(width: 480, height: 640)
        .task {
            guard Bundle.main.bundleIdentifier != nil else { return }
            authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    private func described(_ title: String, isOn: Binding<Bool>, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func limitRow(_ title: String, isOn: Binding<Bool>, limit: Binding<Int>, options: [Int]) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
            Spacer()
            Picker(title, selection: limit) {
                ForEach(options, id: \.self) { Text(FileSize.format(Int64($0))).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!isOn.wrappedValue)
        }
    }
}

/// Settings › Ignore List: sections on the left, ignored items on the right.
struct IgnoreListSettingsView: View {
    @State private var entries: [IgnoreList.Entry] = []
    @State private var section: IgnoreList.Section?
    @State private var picked: Set<String> = []
    @State private var confirmReset: Reset?

    private enum Reset { case section(IgnoreList.Section), all }

    private var sections: [IgnoreList.Section] {
        let used = Set(entries.map(\.section))
        return IgnoreList.Section.allCases.filter(used.contains)
    }
    private var current: IgnoreList.Section? { section.flatMap { sections.contains($0) ? $0 : nil } ?? sections.first }
    private var shown: [IgnoreList.Entry] { entries.filter { $0.section == current }.sorted { $0.date > $1.date } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("View and manage the items that were earlier excluded from scan results:")
            if entries.isEmpty {
                Text("Add items to this list directly from TidyMac's detailed scan results: right-click an item and choose Add to Ignore List.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            } else {
                HSplitView {
                    List(sections, selection: Binding(get: { current }, set: { section = $0; picked = [] })) { s in
                        HStack {
                            Text(s.title)
                            Spacer()
                            Text("\(entries.filter { $0.section == s }.count)").foregroundStyle(.secondary)
                        }.tag(s)
                    }
                    .frame(minWidth: 180, maxWidth: 220)
                    List(shown, selection: $picked) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).lineLimit(1)
                            if let s = e.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .tag(e.id)
                        .contextMenu { Button("Remove from Ignore List") { remove(picked.contains(e.id) ? picked : [e.id]) } }
                    }
                    .onDeleteCommand { remove(picked) }
                    .frame(minWidth: 300)
                }
            }
            HStack {
                Text("All changes take effect after a new scan.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remove") { remove(picked) }.disabled(picked.isEmpty)
                Button("Reset Selected Ignore List") { current.map { confirmReset = .section($0) } }.disabled(current == nil)
                Button("Reset All Ignore Lists") { confirmReset = .all }.disabled(entries.isEmpty)
            }
        }
        .padding()
        .frame(width: 680, height: 420)
        .onAppear(perform: reload)
        .alert(resetTitle, isPresented: Binding(get: { confirmReset != nil }, set: { if !$0 { confirmReset = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Ignore List", role: .destructive) {
                switch confirmReset {
                case .section(let s): IgnoreList.reset(s)
                case .all: IgnoreList.reset()
                case nil: break
                }
                reload()
            }
        } message: {
            Text("TidyMac will no longer ignore the items you previously added.")
        }
    }

    private var resetTitle: String {
        if case .section = confirmReset { return "Are you sure you want to reset the selected category of the Ignore List?" }
        return "Are you sure you want to reset your Ignore List to its initial state?"
    }

    private func reload() { entries = IgnoreList.entries(); picked = [] }
    private func remove(_ ids: Set<String>) { IgnoreList.remove(ids); reload() }
}

/// Settings › Scanning: modules for Smart Care, categories for Cleanup.
struct ScanSettingsView: View {
    @State private var settings = ScanSettings.load()

    var body: some View {
        Form {
            Section {
                ForEach(ScanSettings.smartCareModules, id: \.id) { m in
                    toggle(m.title, isOn: !settings.disabledSmartCare.contains(m.id),
                           isLast: settings.disabledSmartCare.count == ScanSettings.smartCareModules.count - 1) {
                        settings.disabledSmartCare.formSymmetricDifference([m.id])
                    }
                }
            } header: {
                Text("Modules to scan using Smart Care:")
            }
            Section {
                ForEach(CleanupEngine.categories, id: \.id) { c in
                    toggle(c.title, isOn: !settings.disabledCleanup.contains(c.id),
                           isLast: settings.disabledCleanup.count == CleanupEngine.categories.count - 1) {
                        settings.disabledCleanup.formSymmetricDifference([c.id])
                    }
                }
            } header: {
                Text("Categories to scan using Cleanup:")
            } footer: {
                Text("Smart Care's cleanup uses these categories too. My Tools always runs the tool you pick.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .onChange(of: settings) { $0.save() }
    }

    /// The last module or category that is still on cannot be turned off: a scan of nothing would look like a clean Mac.
    private func toggle(_ title: String, isOn: Bool, isLast: Bool, flip: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { _ in flip() }))
            .disabled(isOn && isLast)
    }
}

/// Settings › General.
struct GeneralSettingsView: View {
    @AppStorage(GeneralSettings.soundsKey) private var sounds = true
    @AppStorage(GeneralSettings.reduceMotionKey) private var reduceMotion = GeneralSettings.ReduceMotion.system.rawValue
    @AppStorage(GeneralSettings.keepInDockKey) private var keepInDock = true
    @AppStorage(GeneralSettings.assistantKey) private var assistant = true
    @State private var fullDiskAccess = Permissions.hasFullDiskAccess

    var body: some View {
        Form {
            Section("General") {
                Toggle("Play sounds for main TidyMac actions", isOn: $sounds)
                Picker("Reduce Motion:", selection: $reduceMotion) {
                    ForEach(GeneralSettings.ReduceMotion.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                Toggle("Keep icon in Dock when TidyMac is not open", isOn: $keepInDock)
                    .onChange(of: keepInDock) { _ in AppDelegate.updateDockIcon() }
                Toggle("Show Assistant recommendations", isOn: $assistant)
            }
            Section("Full Disk Access") {
                HStack {
                    Label(fullDiskAccess ? "Full Disk Access enabled for TidyMac" : "Full Disk Access disabled for TidyMac",
                          systemImage: fullDiskAccess ? "checkmark.shield" : "exclamationmark.shield")
                    Spacer()
                    if !fullDiskAccess { Button("Enable") { NSWorkspace.shared.open(Permissions.fullDiskAccessSettings) } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        // Picks up access granted in System Settings while this window was open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess = Permissions.hasFullDiskAccess
        }
    }
}
