import SwiftUI
import TidyCore
import UserNotifications

@main
struct TidyMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var app: AppState { delegate.app }

    init() { BundleMigration.run() }

    var body: some Scene {
        // A single-instance `Window`, not a `WindowGroup`: openWindow(id:) from the menu bar panel or ⌘, would
        // otherwise add another main window every time instead of bringing the existing one forward.
        Window("TidyMac", id: "main") {
            RootView(app: app)
                .frame(minWidth: 980, idealWidth: 1180, minHeight: 640, idealHeight: 740)
                // A notification opens tidymac://open/<module>; reuse the open window instead of adding one.
                .handlesExternalEvents(preferring: ["open", "uninstall"], allowing: ["*"])
                .onOpenURL { url in
                    if url.host == "open", let m = Module(rawValue: url.lastPathComponent) { app.module = m }
                    if url.host == "open", url.lastPathComponent == "settings" { app.openSettings() }
                    if let target = Uninstaller.appURL(fromUninstallURL: url) { app.module = .applications; app.uninstallTarget = target }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: ["open", "uninstall"])

        .commands {
            // ⌘, shows the Settings page of the main window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") { app.openSettings() }.keyboardShortcut(",")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var app = AppState()
    /// The menu bar item (`TrayController`), which keeps running after the main window closes.
    @MainActor private var tray: TrayController?

    /// Light or dark for every window and the menu bar panel; System follows macOS.
    @MainActor static func applyAppearance() {
        switch GeneralSettings.appearance() {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// An update that was downloaded in the background is swapped in once TidyMac has quit.
    func applicationWillTerminate(_ notification: Notification) {
        if GeneralSettings.installsUpdates() { UpdateInstaller.apply(relaunch: false) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Self.applyAppearance() }
        // `--snapshot-tray <png>` renders the menu bar panel to an image and quits (for visual checks).
        let args = ProcessInfo.processInfo.arguments
        // `--scan <module>` prints what a module's scan finds and quits. It never runs any action.
        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count, let module = Module(rawValue: args[i + 1]) {
            let engine = module.engine(clutterRoot: Paths.home)
            Task.detached {
                let start = Date()
                let groups = IgnoreList.apply(await engine.scan { _ in })
                for g in groups {
                    print("== \(g.title) - \(g.items.count) items, \(FileSize.format(g.totalSize)), \(g.items.filter(\.selectedByDefault).count) preselected")
                    for item in g.items.prefix(8) {
                        print("   [\(item.selectedByDefault ? "x" : " ")] \(item.title)\(item.badge.map { " <\($0)>" } ?? "") - \(item.subtitle ?? "") \(item.size.map(FileSize.format) ?? "")")
                    }
                }
                print(String(format: "scan took %.1fs", Date().timeIntervalSince(start)))
                exit(0)
            }
            return
        }
        // `--snapshot-main <png> [module] [phase]` renders the main window (intro, or results with sample tiles, or done).
        if let i = args.firstIndex(of: "--snapshot-main"), i + 1 < args.count {
            MainActor.assumeIsolated {
                let state = AppState()
                if i + 2 < args.count, let m = Module(rawValue: args[i + 2]) { state.module = m }
                if i + 3 < args.count, let c = state.controllers[state.module] {
                    switch args[i + 3] {
                    case "results":
                        c.groups = [ResultGroup(id: "a", title: "System Junk", description: "", symbol: "archivebox.fill",
                                                items: [ResultItem(title: "Caches", size: 2_400_000_000, action: .run(Command("/usr/bin/true"), admin: false))]),
                                    ResultGroup(id: "b", title: "Trash Bins", description: "", symbol: "trash.fill", items: [])]
                        c.selected = Set(c.groups.flatMap(\.items).map(\.id)); c.phase = .results
                        c.scannedWithoutAccess = !Permissions.hasFullDiskAccess
                    case "scanning": c.current = "~/Library/Caches"; c.phase = .scanning
                    case "done": c.report = ActionReport(); c.phase = .done
                    case "blocked":
                        let item = ResultItem(title: "Mail Downloads", action: .run(Command("/usr/bin/true"), admin: false))
                        var report = ActionReport()
                        report.failed = [(item, "You don't have permission to access this item.")]
                        report.needsAccess = [item]
                        c.report = report; c.phase = .done
                    default: break
                    }
                }
                let renderer = ImageRenderer(content: RootView(app: state).frame(width: 1200, height: 720).environment(\.colorScheme, .dark))
                renderer.scale = 1
                if let tiff = renderer.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot-tray") ?? args.firstIndex(of: "--snapshot-screen-clean"), i + 1 < args.count {
            MainActor.assumeIsolated {
                // `--snapshot-tray <png> [card] [--light]` opens that card's details (storage, memory, cpu, drives, devices...).
                let monitor = MonitorModel(background: false)
                if args[i] == "--snapshot-tray" { monitor.loadAllNow() }
                let card = i + 2 < args.count ? TrayView.Card(rawValue: args[i + 2]) : nil
                let state = AppState()
                // The detail panel sits on the left of the menu, as it does on screen.
                let content: AnyView = args[i] == "--snapshot-tray" ? AnyView(HStack(alignment: .top, spacing: TrayDetailPanel.gap) {
                    if let card { TrayDetail(card: card, app: state, monitor: monitor, open: { _ in }) }
                    TrayView(app: state, monitor: monitor, detail: card, scrolls: false)
                }
                .background(card == nil ? Color.clear : Color.black)
                .environment(\.colorScheme, args.contains("--light") ? .light : .dark))
                    : AnyView(ScreenCleaningOverlay(session: ScreenCleaningSession(), main: true).frame(width: 1280, height: 800))
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                if let tiff = renderer.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                }
            }
            exit(0)
        }
        // `--screen-clean <seconds>` runs a short Screen Cleaning session and quits (for checks).
        if let i = args.firstIndex(of: "--screen-clean"), i + 1 < args.count, let seconds = Int(args[i + 1]) {
            MainActor.assumeIsolated {
                NSApp.setActivationPolicy(.regular)
                let session = ScreenCleaningSession()
                session.start(duration: seconds)
                Timer.scheduledTimer(withTimeInterval: Double(seconds) + 0.5, repeats: false) { _ in
                    print("screen cleaning ended, success shown: \(MainActor.assumeIsolated { session.showSuccess })")
                    exit(0)
                }
            }
            return
        }
        // `--check-update` prints what Settings › Updates would say. Installs nothing.
        if args.contains("--check-update") {
            Task.detached {
                do { print("version \(SelfUpdate.currentVersion ?? "unknown"): \(try await SelfUpdate.check())"); exit(0) }
                catch { print("check failed: \(error)"); exit(1) }
            }
            return
        }
        // `--health-check` prints what the background monitor sees now and which alerts are active. Posts nothing.
        if args.contains("--health-check") {
            Task.detached {
                let memory = SystemMonitor.memory()
                let r = HealthAlerts.Readings(storage: SystemMonitor.storage(), memory: memory, trashSize: SystemMonitor.trash()?.size,
                                              batteryHealth: SystemMonitor.battery()?.healthPercent, threats: HealthAlerts.currentThreats(),
                                              topConsumer: HealthAlerts.topMemoryConsumer())
                print("free: \(FileSize.format(r.storage.available)), memory pressure: \(memory.pressureLevel), trash: \(r.trashSize.map(FileSize.format) ?? "no access"), battery health: \(r.batteryHealth.map { "\($0)%" } ?? "n/a"), threats: \(r.threats?.count ?? 0), top: \(r.topConsumer.map { "\($0.name) \(FileSize.format($0.bytes))" } ?? "-")")
                print("drive health: \(SystemMonitor.driveHealth().text)")
                print("top consumers: " + SystemMonitor.consumers().sorted { $0.memory > $1.memory }.prefix(3)
                    .map { "\($0.name) \(FileSize.format($0.memory)) \(String(format: "%.0f", $0.cpu))% CPU\($0.pid == nil ? "" : " [quittable]")" }.joined(separator: ", "))
                for d in SystemMonitor.externalDrives() { print("external: \(d.name) \(d.isDiskImage ? "(disk image)" : d.format ?? "") \(FileSize.format(d.available)) free of \(FileSize.format(d.total))") }
                for b in SystemMonitor.bluetoothDevices() { print("bluetooth: \(b.name) \(b.batteries.map { "\($0.label)\($0.percent)%" })") }
                var state = HealthAlerts.State()
                for a in HealthAlerts.conditions(r, settings: .load(), state: &state) { print("  [\(a.kind.rawValue)] \(a.title) - \(a.body)") }
                if Bundle.main.bundleIdentifier != nil {
                    let s = await UNUserNotificationCenter.current().notificationSettings()
                    let names: [UNAuthorizationStatus: String] = [.notDetermined: "not asked yet", .denied: "denied", .authorized: "allowed", .provisional: "provisional"]
                    print("notifications: \(names[s.authorizationStatus] ?? "\(s.authorizationStatus.rawValue)")")
                }
                exit(0)
            }
            return
        }
        // Running from `swift run` has no bundle; make it a regular foreground app anyway.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            HealthMonitor.shared.start()
            tray = TrayController(app: app, monitor: MonitorModel())
        }
        // `--open-tray` opens the menu bar panel at launch (for checks; other apps may cover the menu bar).
        if args.contains("--open-tray") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.tray?.open() } }
        }
        // Finder › right-click an app › Services (or Quick Actions) › Uninstall with TidyMac.
        NSApp.servicesProvider = FinderService.shared
        NSUpdateDynamicServices()
        DispatchQueue.main.async { MainActor.assumeIsolated { MoveOffer.offerIfNeeded() } }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { Self.updateDockIcon(closing: note.object as? NSWindow) }
        }
    }

    /// "Keep icon in Dock when TidyMac is not open". Without it, closing the main window leaves only the menu bar item.
    @MainActor static func updateDockIcon(closing: NSWindow? = nil) {
        let mainOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
        // Without the menu bar item and the Dock icon there would be no way back in.
        let reachable = GeneralSettings.keepsDockIcon() || !GeneralSettings.showsMenuBarItem()
        let policy: NSApplication.ActivationPolicy = mainOpen || reachable ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// The main window is opening: the Dock icon comes back, and an app without one has to be activated to show it in front.
    @MainActor static func mainWindowOpened() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    // The menu bar item keeps running after the main window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Owns one controller per module so scan results survive switching modules.
@MainActor
final class AppState: ObservableObject {
    @Published var module: Module = .smartCare { didSet { showSettings = false } }
    /// The Settings page is showing instead of the selected module.
    @Published var showSettings = false
    /// Set by a `tidymac://uninstall` link; shows the Uninstaller on that app.
    @Published var uninstallTarget: URL?
    /// Which half of the Applications page shows: the app list, or the scan for updates and leftovers.
    @Published var applicationsTab: ApplicationsTab = .apps
    let screenCleaning = ScreenCleaningSession()
    /// Opens (or brings back) the main window; set once it has appeared.
    var openMain: (() -> Void)?

    func openSettings() {
        showSettings = true
        openMain?()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Runs one tool inside the module it belongs to, so a shortcut (Toolkit, Overview) lands on that tool's results
    /// with the sidebar showing where it lives. A module busy scanning or cleaning is shown as it is.
    func openTool(_ id: String) {
        guard let t = Toolbox.tools.first(where: { $0.id == id }) else { return }
        switch t.kind {
        case .screenCleaning: ToolHistory.markScanned(t.id); screenCleaning.start()
        case .uninstaller: ToolHistory.markScanned(t.id); openApplications(.apps)
        case .scan:
            guard let m = Module(rawValue: t.module), let c = controllers[m] else { return }
            if m == .applications { applicationsTab = .updates }
            module = m
            if c.phase != .scanning && c.phase != .running { c.scan(only: t) }
        }
    }
    /// Shows the Applications page on one tab. The updates tab starts its scan if it has nothing to show yet.
    func openApplications(_ tab: ApplicationsTab) {
        applicationsTab = tab
        module = .applications
        if tab == .updates, let c = controllers[.applications], c.phase == .intro { c.scanAll() }
    }

    let controllers: [Module: ModuleController] = Dictionary(uniqueKeysWithValues: Module.allCases.map { ($0, ModuleController(module: $0)) })
}

struct RootView: View {
    @ObservedObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(app: app)
                .frame(width: 240)
            Rectangle().fill(DS.border).frame(width: 1)
            ZStack {
                DS.window
                content
                    .id(app.showSettings ? "settings" : app.module.rawValue)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.window)
        .ignoresSafeArea()
        .animation(Motion.animation(.easeInOut(duration: 0.2)), value: app.module)
        .animation(Motion.animation(.easeInOut(duration: 0.2)), value: app.showSettings)
        .onAppear {
            AppDelegate.mainWindowOpened()
            // The menu bar panel lives outside SwiftUI's scenes and reopens the main window through this.
            app.openMain = { [openWindow] in openWindow(id: "main") }
        }
        .background {
            // Its own view, so it does not compete with the Screen Cleaning sheet attached below.
            Color.clear.sheet(isPresented: Binding(get: { app.uninstallTarget != nil }, set: { if !$0 { app.uninstallTarget = nil } })) {
                UninstallerSheet(module: .applications, select: app.uninstallTarget)
            }
        }
        .sheet(isPresented: Binding(get: { app.screenCleaning.showSuccess }, set: { app.screenCleaning.showSuccess = $0 })) {
            ScreenCleaningSuccess(session: app.screenCleaning)
        }
    }

    @ViewBuilder private var content: some View {
        if app.showSettings { SettingsPage(app: app) } else { module }
    }

    @ViewBuilder private var module: some View {
        switch app.module {
        case .spaceLens: SpaceLensScreen(app: app)
        case .activity: ActivityScreen(app: app)
        case .myTools: MyToolsScreen(app: app)
        case .smartCare: OverviewScreen(app: app, controller: app.controllers[.smartCare]!)
        case .applications: ApplicationsScreen(app: app, controller: app.controllers[.applications]!)
        default: ModuleScreen(controller: app.controllers[app.module]!)
        }
    }
}

/// Grouped navigation: a brand header, sections with their rows (each showing what a scan found), and at the bottom
/// the Full Disk Access state and Settings.
struct Sidebar: View {
    @ObservedObject var app: AppState
    @ObservedObject private var access = FullDiskAccessWatcher.shared

    /// What to act on. Toolkit and History are reference pages, so they sit at the bottom next to Settings.
    private let sections: [(title: String?, modules: [Module])] = [
        (nil, [.smartCare]),
        (String(localized: "Clean"), [.cleanup, .clutter, .spaceLens, .applications]),
        (String(localized: "Protect & Optimize"), [.protection, .performance]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 34, height: 34)
                Text("TidyMac").font(.system(size: 17, weight: .semibold))
            }
            .padding(.leading, 14).padding(.top, 34).padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.section) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 2) {
                            if let title = section.title {
                                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.leading, 10).padding(.bottom, 3)
                            }
                            ForEach(section.modules) { SidebarRow(module: $0, app: app) }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            VStack(spacing: 2) {
                // Only while something is missing: once access is on there is nothing to do here.
                if !access.granted { accessCard.padding(.bottom, 6) }
                SidebarRow(module: .myTools, app: app)
                SidebarRow(module: .activity, app: app)
                Button { app.showSettings = true } label: {
                    SidebarLabel(symbol: "gearshape.fill", tint: DS.glyph, title: String(localized: "Settings"), badge: nil, selected: app.showSettings)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.sidebar)
    }

    private var accessCard: some View {
        Button { NSWorkspace.shared.open(Permissions.fullDiskAccessSettings) } label: {
            HStack(spacing: 10) {
                IconChip(symbol: "lock.fill", tint: DS.caution, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "Limited scan")).font(.system(size: 12.5, weight: .semibold))
                    Text(String(localized: "Let TidyMac look deeper"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .buttonStyle(.plain)
        .help(String(localized: "Let TidyMac look deeper"))
    }
}

/// One navigation row. It watches its module's controller so the badge shows what the last scan found.
struct SidebarRow: View {
    let module: Module
    @ObservedObject var app: AppState
    @ObservedObject private var controller: ModuleController

    init(module: Module, app: AppState) {
        self.module = module
        self.app = app
        _controller = ObservedObject(wrappedValue: app.controllers[module]!)
    }

    private var badge: String? {
        guard controller.phase == .results, controller.totalSize > 0 else { return nil }
        return formatSize(controller.totalSize)
    }

    var body: some View {
        Button { app.module = module } label: {
            SidebarLabel(symbol: module.symbol, tint: module.tint, title: module == .smartCare ? String(localized: "Overview") : module.name,
                         badge: badge, selected: app.module == module && !app.showSettings)
        }
        .buttonStyle(.plain)
        .help(module.tagline)
    }
}

struct SidebarLabel: View {
    let symbol: String, tint: Color, title: String
    let badge: String?
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            IconChip(symbol: symbol, tint: tint, size: 22)
            Text(title).font(.system(size: 13.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 4)
            if let badge { Text(badge).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal, 8).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? DS.selection : hover ? DS.selection.opacity(0.5) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.12)), value: selected)
    }
}
