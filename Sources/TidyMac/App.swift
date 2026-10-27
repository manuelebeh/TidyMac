import SwiftUI
import TidyCore
import UserNotifications

@main
struct TidyMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("TidyMac", id: "main") {
            RootView(app: app)
                .frame(minWidth: 1000, idealWidth: 1200, minHeight: 640, idealHeight: 720)
                .environment(\.colorScheme, .dark)
                // A notification opens tidymac://open/<module>; reuse the open window instead of adding one.
                .handlesExternalEvents(preferring: ["open"], allowing: ["*"])
                .onOpenURL { url in
                    if url.host == "open", let m = Module(rawValue: url.lastPathComponent) { app.module = m }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: ["open"])

        Settings {
            SettingsView()
        }

        // Equivalent of CleanMyMac's separate "CleanMyMac Menu" login item.
        MenuBarExtra {
            TrayView(app: app)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--snapshot-tray <png>` renders the menu bar panel to an image and quits (for visual checks).
        let args = ProcessInfo.processInfo.arguments
        // `--scan <module>` prints what a module's scan finds and quits. It never runs any action.
        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count, let module = Module(rawValue: args[i + 1]) {
            let engine = module.engine(clutterRoot: Paths.home)
            Task.detached {
                let start = Date()
                let groups = await engine.scan { _ in }
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
        if let i = args.firstIndex(of: "--snapshot-tray") ?? args.firstIndex(of: "--snapshot-screen-clean"), i + 1 < args.count {
            MainActor.assumeIsolated {
                // `--snapshot-tray <png> [card]` opens that card's details (storage, memory, cpu, drives, devices…).
                let monitor = MonitorModel()
                if args[i] == "--snapshot-tray" { monitor.loadAllNow() }
                let card = i + 2 < args.count ? TrayView.Card(rawValue: args[i + 2]) : nil
                let content: AnyView = args[i] == "--snapshot-tray" ? AnyView(TrayView(app: AppState(), monitor: monitor, detail: card, scrolls: false))
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
        MainActor.assumeIsolated { HealthMonitor.shared.start() }
    }
    // The menu bar item keeps running after the main window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Owns one controller per module so scan results survive switching modules.
@MainActor
final class AppState: ObservableObject {
    @Published var module: Module = .smartCare
    let screenCleaning = ScreenCleaningSession()
    let controllers: [Module: ModuleController] = Dictionary(uniqueKeysWithValues: Module.allCases.map { ($0, ModuleController(module: $0)) })
}

struct RootView: View {
    @ObservedObject var app: AppState

    var body: some View {
        ZStack {
            ModuleBackground(module: app.module)
            HStack(spacing: 0) {
                Sidebar(selection: $app.module)
                    .frame(width: 230)
                Group {
                    switch app.module {
                    case .spaceLens: SpaceLensScreen()
                    case .activity: ActivityScreen(app: app)
                    case .myTools: MyToolsScreen(screenCleaning: app.screenCleaning)
                    default: ModuleScreen(controller: app.controllers[app.module]!)
                    }
                }
                .id(app.module)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: app.module)
        .sheet(isPresented: Binding(get: { app.screenCleaning.showSuccess }, set: { app.screenCleaning.showSuccess = $0 })) {
            ScreenCleaningSuccess(session: app.screenCleaning)
        }
    }
}

struct Sidebar: View {
    @Binding var selection: Module
    private let main: [Module] = [.smartCare, .cleanup, .protection, .performance, .applications, .clutter, .spaceLens]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer().frame(height: 46)
            ForEach(main) { row($0) }
            Spacer()
            row(.myTools)
            row(.activity)
            Spacer().frame(height: 16)
        }
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.06))
    }

    func row(_ m: Module) -> some View {
        Button { selection = m } label: {
            HStack(spacing: 12) {
                Image(systemName: m.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(
                        LinearGradient(colors: [m.accent, m.light], startPoint: .top, endPoint: .bottom)))
                Text(m.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(selection == m ? 0.14 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(selection == m ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
