import SwiftUI
import TidyCore
import UserNotifications

/// The Settings page inside the main window: a row of sections, and the form of the one picked.
struct SettingsPage: View {
    @ObservedObject var app: AppState
    private enum Tab: String, CaseIterable, Identifiable {
        case general, notifications, scanning, applications, automations, ignoreList, updates
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .notifications: String(localized: "Notifications")
            case .scanning: String(localized: "Scanning")
            case .applications: String(localized: "Applications")
            case .automations: String(localized: "Automations")
            case .ignoreList: String(localized: "Ignore List")
            case .updates: String(localized: "Updates")
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .notifications: "bell"
            case .scanning: "magnifyingglass"
            case .applications: "app.badge.checkmark"
            case .automations: "clock.arrow.circlepath"
            case .ignoreList: "eye.slash"
            case .updates: "arrow.down.circle"
            }
        }
    }

    @State private var tab = Tab.general

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: String(localized: "Settings")) { EmptyView() }
                .padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Tab.allCases) { t in
                        Button { tab = t } label: {
                            Label(t.title, systemImage: t.symbol).font(.system(size: 12.5, weight: tab == t ? .semibold : .medium))
                                .labelStyle(.titleAndIcon)
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(Capsule().fill(tab == t ? DS.cardHover : Color.clear))
                                .overlay(Capsule().strokeBorder(tab == t ? DS.border : Color.clear, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
            }
            .padding(.bottom, 8)
            Group {
                switch tab {
                case .general: GeneralSettingsView(app: app)
                case .notifications: NotificationSettingsView()
                case .scanning: ScanSettingsView()
                case .applications: ApplicationSettingsView()
                case .automations: AutomationSettingsView()
                case .ignoreList: IgnoreListSettingsView()
                case .updates: UpdateSettingsView()
                }
            }
            .frame(maxWidth: 760, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Settings › Updates. Asks GitHub only when requested, or once a day if that is turned on, and never installs anything.
struct UpdateSettingsView: View {
    private enum Status: Equatable { case idle, checking, failed, finished(SelfUpdate.Outcome) }

    @AppStorage(GeneralSettings.checkUpdatesKey) private var checksDaily = false
    @AppStorage(GeneralSettings.installUpdatesKey) private var installsAutomatically = false
    @State private var status = Status.idle
    @State private var installing = false
    @State private var installError: String?

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
                if let installError { Text(installError).font(.caption).foregroundStyle(.red) }
                Toggle("Check for new versions once a day", isOn: $checksDaily)
                Toggle("Install new versions automatically", isOn: $installsAutomatically).disabled(!checksDaily)
            } footer: {
                Text("A check asks GitHub for the latest release of TidyMac and sends nothing about your Mac. An automatic install downloads the signed release, checks it was made by the same developer, and swaps it in the next time you quit TidyMac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Link("Project page", destination: SelfUpdate.projectPage)
                Link("Report a problem", destination: SelfUpdate.issuesPage)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .idle: Text("Not checked yet").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        case .failed: Label("Could not reach GitHub. Try again later.", systemImage: "exclamationmark.triangle")
        case .finished(.upToDate): Label("TidyMac is up to date.", systemImage: "checkmark.circle")
        case .finished(.available(let release)):
            HStack {
                Link("Download TidyMac \(release.version)", destination: release.page)
                if release.archive != nil {
                    Spacer()
                    Button("Install and Restart") { Task { await install(release) } }.disabled(installing)
                }
            }
        }
    }

    private func install(_ release: SelfUpdate.Release) async {
        installing = true; installError = nil
        defer { installing = false }
        do {
            try await UpdateInstaller.stage(release)
            UpdateInstaller.apply(relaunch: true)
            NSApp.terminate(nil)
        } catch UpdateInstaller.Failure.folderNotWritable {
            installError = String(localized: "TidyMac cannot replace itself in this folder. Download the update instead.")
        } catch {
            installError = String(localized: "The update could not be installed. Download it from the project page instead.")
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
                limitRow(String(localized: "Warn when free space is less than"), isOn: $lowDisk, limit: $freeSpaceLimit, options: freeSpaceOptions)
                limitRow(String(localized: "Notify if Trash size exceeds"), isOn: $trashSize, limit: $trashLimit, options: trashOptions)
                if trashSize, SystemMonitor.trash() == nil {
                    Text("Allow Full Disk Access to analyze Trash contents.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Suggest to clean up overfilled external drives", isOn: $externalDrives)
                Toggle("Notify when a drive is connected to the Mac", isOn: $driveConnected)
            }
            Section("General") {
                HStack {
                    Toggle("Remind to run regular Full Scan", isOn: $smartCareReminder)
                    Spacer()
                    Picker("Remind to run regular Full Scan", selection: $smartCareInterval) {
                        ForEach(HealthAlerts.Settings.smartCareIntervals, id: \.days) { Text($0.title).tag($0.days) }
                    }
                    .labelsHidden().fixedSize().disabled(!smartCareReminder)
                }
                Toggle("Notify when too low on free RAM", isOn: $memory)
                Toggle("Warn about critical battery health", isOn: $battery)
                Toggle("Warn when connected device batteries are running low", isOn: $bluetooth)
            }
            Section("Applications") {
                described(String(localized: "Notify about hung applications"), isOn: $hungApps,
                          String(localized: "If any of your apps stop responding, force quit them right from the notification."))
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
                described(String(localized: "Clean up junk automatically on ejection"), isOn: $cleanOnEject,
                          String(localized: "Ejecting a drive from the menu first empties that drive's Trash. Those files are deleted for good."))
            } header: {
                Text("Menu")
            } footer: {
                Text("Open at Login keeps the menu and its alerts running after a restart.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        if case .section = confirmReset { return String(localized: "Are you sure you want to reset the selected category of the Ignore List?") }
        return String(localized: "Are you sure you want to reset your Ignore List to its initial state?")
    }

    private func reload() { entries = IgnoreList.entries(); picked = [] }
    private func remove(_ ids: Set<String>) { IgnoreList.remove(ids); reload() }
}

/// Settings › Scanning: modules for Full Scan, categories for Cleanup.
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
                Text("Modules to scan using Full Scan:")
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
                Text("Full Scan's cleanup uses these categories too. Toolkit always runs the tool you pick.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
    @ObservedObject var app: AppState
    @AppStorage(GeneralSettings.soundsKey) private var sounds = true
    @AppStorage(GeneralSettings.reduceMotionKey) private var reduceMotion = GeneralSettings.ReduceMotion.system.rawValue
    @AppStorage(GeneralSettings.keepInDockKey) private var keepInDock = true
    @AppStorage(GeneralSettings.showInMenuBarKey) private var showInMenuBar = true
    @AppStorage(GeneralSettings.assistantKey) private var assistant = true
    @AppStorage(GeneralSettings.appearanceKey) private var appearance = GeneralSettings.Appearance.system.rawValue
    @State private var fullDiskAccess = Permissions.hasFullDiskAccess

    var body: some View {
        Form {
            Section("Appearance") {
                HStack(spacing: 14) {
                    ForEach(GeneralSettings.Appearance.allCases, id: \.self) { mode in
                        AppearanceTile(mode: mode, selected: appearance == mode.rawValue) {
                            appearance = mode.rawValue
                            AppDelegate.applyAppearance()
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Section("General") {
                Toggle("Play sounds for main TidyMac actions", isOn: $sounds)
                Picker("Reduce Motion:", selection: $reduceMotion) {
                    ForEach(GeneralSettings.ReduceMotion.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Show TidyMac in the menu bar", isOn: $showInMenuBar)
                    .onChange(of: showInMenuBar) { _ in TrayController.updateVisibility(); AppDelegate.updateDockIcon() }
                Toggle("Keep icon in Dock when TidyMac is not open", isOn: $keepInDock)
                    .onChange(of: keepInDock) { _ in AppDelegate.updateDockIcon() }
                Toggle("Show Assistant recommendations", isOn: $assistant)
            }
            Section("Full Disk Access") {
                HStack {
                    Label(fullDiskAccess ? String(localized: "Full Disk Access enabled for TidyMac") : String(localized: "Full Disk Access disabled for TidyMac"),
                          systemImage: fullDiskAccess ? "checkmark.shield" : "exclamationmark.shield")
                    Spacer()
                    if !fullDiskAccess { Button("Enable") { NSWorkspace.shared.open(Permissions.fullDiskAccessSettings) } }
                }
            }
            if Bundle.main.bundleIdentifier != nil {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Uninstall TidyMac")
                            Text("Removes the app and the files it keeps, such as its settings and caches.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Uninstall...") { app.uninstallTarget = Bundle.main.bundleURL }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Picks up access granted in System Settings while this window was open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess = Permissions.hasFullDiskAccess
        }
    }
}

/// A small preview of the window in one appearance, with its name under it.
struct AppearanceTile: View {
    let mode: GeneralSettings.Appearance
    let selected: Bool
    let action: () -> Void

    private func preview(dark: Bool) -> some View {
        let bg = dark ? Color(white: 0.14) : Color(white: 0.96)
        let side = dark ? Color(white: 0.2) : Color(white: 0.88)
        let bar = dark ? Color.white.opacity(0.22) : Color.black.opacity(0.16)
        return ZStack(alignment: .topLeading) {
            bg
            HStack(spacing: 0) {
                side.frame(width: 22)
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(DS.accent).frame(width: 30, height: 5)
                    Capsule().fill(bar).frame(width: 50, height: 4)
                    Capsule().fill(bar).frame(width: 38, height: 4)
                }
                .padding(8)
            }
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if mode == .system {
                        preview(dark: false).overlay(preview(dark: true).mask(HalfMask()))
                    } else {
                        preview(dark: mode == .dark)
                    }
                }
                .frame(width: 92, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? DS.accent : Color.secondary.opacity(0.35), lineWidth: selected ? 2 : 1))
                Text(mode.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The right half, for the System tile.
    private struct HalfMask: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.closeSubpath()
            return p
        }
    }
}

/// Settings › Applications: how the Uninstaller finds apps and what happens when one is deleted by hand.
struct ApplicationSettingsView: View {
    private static let trashedKey = "\(HealthAlerts.Settings.defaultsKey).trashedApps"
    @AppStorage(trashedKey) private var reviewLeftovers = HealthAlerts.Settings().trashedApps
    @State private var folders = Uninstaller.extraFolders().map(\.path)
    @State private var refused = false

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uninstall from Finder's right-click menu")
                        Text("Right-click an app, then choose Services > Uninstall with TidyMac. If it is missing, turn it on in System Settings > Keyboard > Keyboard Shortcuts > Services.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                }
            }
            Section {
                folderRow(String(localized: "Applications"), path: "/Applications", removable: false)
                folderRow("~/Applications", path: Paths.home("Applications").path, removable: false)
                ForEach(folders, id: \.self) { folderRow(Paths.abbreviate(URL(fileURLWithPath: $0)), path: $0, removable: true) }
                HStack {
                    Button("Add Folder...") { addFolder() }
                    if refused { Text("TidyMac only looks in your home folder and on drives.").font(.caption).foregroundStyle(.red) }
                }
            } header: {
                Text("Where TidyMac looks for apps")
            } footer: {
                Text("Drives you plug in are included automatically.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Review leftovers when an app is deleted", isOn: $reviewLeftovers)
                    Text("If you put an application into Trash, you will be offered to remove the files it left behind.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if reviewLeftovers, SystemMonitor.trashedApps() == nil {
                    Text("Allow Full Disk Access so TidyMac can see apps in the Trash.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func folderRow(_ title: String, path: String, removable: Bool) -> some View {
        HStack {
            Label(title, systemImage: "folder")
            Spacer()
            if removable {
                Button { folders.removeAll { $0 == path }; save() } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).help("Stop looking here")
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        refused = false
        for url in panel.urls {
            if Uninstaller.canSearch(url) { if !folders.contains(url.standardizedFileURL.path) { folders.append(url.standardizedFileURL.path) } }
            else { refused = true }
        }
        save()
    }

    private func save() { UserDefaults.standard.set(folders, forKey: Uninstaller.extraFoldersKey) }
}
