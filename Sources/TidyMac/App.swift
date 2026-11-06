import SwiftUI
import TidyCore
import UserNotifications

@main
struct TidyMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var app: AppState { delegate.app }

    var body: some Scene {
        WindowGroup("TidyMac", id: "main") {
            RootView(app: app)
                .frame(minWidth: 1000, idealWidth: 1200, minHeight: 640, idealHeight: 720)
                // Sets the window's appearance, so sheets get a dark background to match their light text.
                .preferredColorScheme(.dark)
                // A notification opens tidymac://open/<module>; reuse the open window instead of adding one.
                .handlesExternalEvents(preferring: ["open", "uninstall"], allowing: ["*"])
                .onOpenURL { url in
                    if url.host == "open", let m = Module(rawValue: url.lastPathComponent) { app.module = m }
                    if let target = Uninstaller.appURL(fromUninstallURL: url) { app.module = .applications; app.uninstallTarget = target }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: ["open", "uninstall"])

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var app = AppState()
    /// The menu bar item (`TrayController`), which keeps running after the main window closes.
    @MainActor private var tray: TrayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--snapshot-tray <png>` renders the menu bar panel to an image and quits (for visual checks).
        let args = ProcessInfo.processInfo.arguments
        // `--scan <module>` prints what a module's scan finds and quits. It never runs any action.
        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count, let module = Module(rawValue: args[i + 1]) {
            let engine = module.engine(clutterRoot: Paths.home)
            Task.detached {
                let start = Date()
                let groups = IgnoreList.apply(await engine.scan { _ in })
                for g in groups {
                    print("== \(g.title) — \(g.items.count) items, \(FileSize.format(g.totalSize)), \(g.items.filter(\.selectedByDefault).count) preselected")
                    for item in g.items.prefix(8) {
                        print("   [\(item.selectedByDefault ? "x" : " ")] \(item.title)\(item.badge.map { " <\($0)>" } ?? "") — \(item.subtitle ?? "") \(item.size.map(FileSize.format) ?? "")")
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
                                                items: [ResultItem(title: "Caches", size: 2_400_000_000, action: .shell("true", admin: false))]),
                                    ResultGroup(id: "b", title: "Trash Bins", description: "", symbol: "trash.fill", items: [])]
                        c.selected = Set(c.groups.flatMap(\.items).map(\.id)); c.phase = .results
                        c.scannedWithoutAccess = !Permissions.hasFullDiskAccess
                    case "scanning": c.current = "~/Library/Caches"; c.phase = .scanning
                    case "done": c.report = ActionReport(); c.phase = .done
                    case "blocked":
                        let item = ResultItem(title: "Mail Downloads", action: .shell("true", admin: false))
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
                // `--snapshot-tray <png> [card] [--light]` opens that card's details (storage, memory, cpu, drives, devices…).
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
                for a in HealthAlerts.conditions(r, settings: .load(), state: &state) { print("  [\(a.kind.rawValue)] \(a.title) — \(a.body)") }
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
        let policy: NSApplication.ActivationPolicy = mainOpen || GeneralSettings.keepsDockIcon() ? .regular : .accessory
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
    @Published var module: Module = .smartCare
    /// Set by a `tidymac://uninstall` link; shows the Uninstaller on that app.
    @Published var uninstallTarget: URL?
    let screenCleaning = ScreenCleaningSession()
    /// Opens (or brings back) the main window; set once it has appeared.
    var openMain: (() -> Void)?
    let controllers: [Module: ModuleController] = Dictionary(uniqueKeysWithValues: Module.allCases.map { ($0, ModuleController(module: $0)) })
}

struct RootView: View {
    @ObservedObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            ModuleBackground(module: app.module)
            HStack(spacing: 0) {
                Sidebar(selection: $app.module)
                    .frame(width: 252)
                Group {
                    switch app.module {
                    case .spaceLens: SpaceLensScreen(app: app)
                    case .activity: ActivityScreen(app: app)
                    case .myTools: MyToolsScreen(screenCleaning: app.screenCleaning)
                    default: ModuleScreen(controller: app.controllers[app.module]!)
                    }
                }
                .id(app.module)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 16)), removal: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(Motion.animation(.easeInOut(duration: 0.35)), value: app.module)
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
}

/// Rows 50 pt tall every 60 pt, a plain glyph per module and a translucent pill under the selection, which slides
/// to the new row. The selected glyph takes the module's colours.
struct Sidebar: View {
    @Binding var selection: Module
    @Namespace private var pill
    @State private var hovered: Module?
    private let main: [Module] = [.smartCare, .cleanup, .protection, .performance, .applications, .clutter, .spaceLens]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The first row starts 67 pt from the top of the window, title bar included.
            Spacer().frame(height: 29)
            ForEach(main) { row($0) }
            Spacer(minLength: 20)
            row(.myTools)
            row(.activity)
            Spacer().frame(height: 11)
        }
        .padding(.horizontal, 16)
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.08), .white.opacity(0.08), .white.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: 1)
                .padding(.vertical, 60)
        }
        .animation(Motion.animation(.spring(response: 0.38, dampingFraction: 0.82)), value: selection)
        .animation(Motion.animation(.easeOut(duration: 0.15)), value: hovered)
    }

    func row(_ m: Module) -> some View {
        let active = selection == m
        return Button { selection = m } label: {
            HStack(spacing: 19) {
                Image(systemName: m.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(active ? AnyShapeStyle(LinearGradient(colors: [m.aurora[0], m.aurora[2], m.aurora[4]],
                                                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                                            : AnyShapeStyle(.white.opacity(0.85)))
                    .shadow(color: active ? m.aurora[2].opacity(0.6) : .black.opacity(0.25), radius: active ? 5 : 1, y: 1)
                    .frame(width: 24, height: 24)
                Text(m.name).font(.system(size: 14)).foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 19)
            .frame(height: 50)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.09))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)))
                        .matchedGeometryEffect(id: "selection", in: pill)
                } else if hovered == m {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? m : (hovered == m ? nil : hovered) }
    }
}
