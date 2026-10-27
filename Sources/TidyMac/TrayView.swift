import SwiftUI
import TidyCore

@MainActor
final class MonitorModel: ObservableObject {
    @Published var storage = SystemMonitor.storage()
    @Published var memory = SystemMonitor.memory()
    @Published var cpu = SystemMonitor.cpu()
    @Published var battery = SystemMonitor.battery()
    @Published var network = SystemMonitor.network()
    @Published var issues: [SystemMonitor.Issue] = []
    @Published var freeingMemory = false
    @Published var speedTest: (download: Double, upload: Double)?
    @Published var testingSpeed = false
    @Published var consumers: [SystemMonitor.Consumer] = []
    @Published var drives: [SystemMonitor.Drive] = []
    @Published var bluetooth: [SystemMonitor.BluetoothDevice] = []
    @Published var driveHealth: SystemMonitor.DriveHealth?
    @Published var ejecting: Set<String> = []
    @Published var ejectMessage: String?
    /// Top Consumers are only read while the Memory or CPU details are open.
    var wantsConsumers = false
    private var timer: Timer?
    private var ticks = 0

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.refresh() } }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        storage = SystemMonitor.storage()
        memory = SystemMonitor.memory()
        cpu = SystemMonitor.cpu()
        battery = SystemMonitor.battery()
        network = SystemMonitor.network()
        let trash = SystemMonitor.trash()
        drives = SystemMonitor.externalDrives()
        refreshSlowReadings()
        issues = SystemMonitor.issues(storage: storage, memory: memory, trashSize: trash?.size, trashedApps: trash?.apps ?? 0,
                                      screenCleaningDue: ScreenCleaningSession.reminderDue,
                                      trashLimit: HealthAlerts.Settings.load().trashLimit)
    }

    /// `ps`, System Information and `diskutil` take tens to hundreds of milliseconds, so they run off the main thread.
    private func refreshSlowReadings() {
        let wantsConsumers = wantsConsumers
        let wantsBluetooth = ticks % 5 == 0, wantsHealth = driveHealth == nil
        ticks += 1
        guard wantsConsumers || wantsBluetooth || wantsHealth else { return }
        Task {
            let r = await Task.detached {
                (wantsConsumers ? SystemMonitor.consumers() : nil, wantsBluetooth ? SystemMonitor.bluetoothDevices() : nil,
                 wantsHealth ? SystemMonitor.driveHealth() : nil)
            }.value
            if let c = r.0 { consumers = c }
            if let b = r.1 { bluetooth = b }
            if let h = r.2 { driveHealth = h }
        }
    }

    /// Everything at once, synchronously; for `--snapshot-tray`, which renders a single frame.
    func loadAllNow() {
        refresh()
        consumers = SystemMonitor.consumers(); bluetooth = SystemMonitor.bluetoothDevices(); driveHealth = SystemMonitor.driveHealth()
    }

    func loadConsumers() {
        wantsConsumers = true
        Task { consumers = await Task.detached { SystemMonitor.consumers() }.value }
    }

    /// CleanMyMac Menu offers Quit and Force Quit for apps; plain processes are left alone.
    func quit(_ c: SystemMonitor.Consumer, force: Bool) {
        guard let pid = c.pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
        _ = force ? app.forceTerminate() : app.terminate()
        Task { try? await Task.sleep(for: .seconds(1.5)); loadConsumers() }
    }

    func eject(_ list: [SystemMonitor.Drive]) {
        ejectMessage = nil
        ejecting.formUnion(list.map(\.id))
        Task {
            var failed: [String] = []
            for d in list {
                let ok = await Task.detached { (try? NSWorkspace.shared.unmountAndEjectDevice(at: d.url)) != nil }.value
                if !ok { failed.append(d.name) }
                ejecting.remove(d.id)
            }
            ejectMessage = failed.isEmpty ? "Successfully ejected!" : "\(failed.joined(separator: ", ")) could not be ejected."
            refresh()
        }
    }

    /// `purge` needs root; CleanMyMac uses its privileged helper, TidyMac asks for the password.
    func freeUpMemory() {
        freeingMemory = true
        Task {
            var item = ResultItem(title: "Free Up RAM", action: .shell("purge", admin: true))
            item.category = "maintenance"
            _ = await Task.detached { [item] in await Executor.run([item]) }.value
            freeingMemory = false
            refresh()
        }
    }

    func runSpeedTest() {
        testingSpeed = true; speedTest = nil
        Task {
            speedTest = await Task.detached { SystemMonitor.speedTest() }.value
            testingSpeed = false
        }
    }
}

struct TrayView: View {
    @ObservedObject var app: AppState
    @StateObject private var monitor: MonitorModel
    @State private var detail: Card?
    @State private var contentHeight: CGFloat = 640
    /// Screen height minus the menu bar, header, footer and padding.
    static var maxScrollHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 150 }
    struct ContentHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    /// ImageRenderer (`--snapshot-tray`) cannot draw scroll views.
    var scrolls = true

    @MainActor init(app: AppState, monitor: MonitorModel? = nil, detail: Card? = nil, scrolls: Bool = true) {
        self.app = app; self.scrolls = scrolls
        _monitor = StateObject(wrappedValue: monitor ?? MonitorModel())
        _detail = State(initialValue: detail)
    }
    @Environment(\.openWindow) private var openWindow

    enum Card: String { case storage, memory, battery, cpu, network, drives, devices }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            // Scrolls only when cards, details and recommendations no longer fit on screen.
            if scrolls {
                ScrollView(showsIndicators: false) {
                    content.background(GeometryReader { Color.clear.preference(key: ContentHeight.self, value: $0.size.height) })
                }
                .frame(height: min(contentHeight, Self.maxScrollHeight))
                .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
            } else {
                content
            }
            footer
        }
        .padding(16)
        .frame(width: 380)
        .background(ModuleBackground(module: .smartCare))
        .environment(\.colorScheme, .dark)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .animation(.easeInOut(duration: 0.2), value: detail)
    }

    var content: some View {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        storageCard
                        memoryCard
                        if let b = monitor.battery { batteryCard(b) }
                        cpuCard
                        networkCard
                        protectionCard
                        drivesCard
                        devicesCard
                    }
                    if let detail { detailView(detail).transition(.opacity.combined(with: .move(edge: .top))) }
                    if !monitor.issues.isEmpty { recommendations }
                }
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer").font(.title2).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(Host.current().localizedName ?? "This Mac").font(.headline).foregroundStyle(.white)
                Text(lastCare).font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Button { open(.smartCare) } label: { Text("Smart Care") }.buttonStyle(PillButtonStyle())
        }
    }

    var lastCare: String {
        guard let last = History.entries.last?.date else { return "No cleanup yet" }
        return "Last cleanup \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))"
    }

    // MARK: Cards

    var storageCard: some View {
        let s = monitor.storage
        let used = s.total > 0 ? Double(s.total - s.available) / Double(s.total) : 0
        return MonitorCard(title: s.name, symbol: "internaldrive.fill", tint: Module.cleanup.accent, fraction: used,
                           value: "Available: \(formatSize(s.available))", selected: detail == .storage,
                           action: ("Free Up", false, { open(.cleanup) })) { toggle(.storage) }
    }

    var memoryCard: some View {
        let m = monitor.memory
        return MonitorCard(title: "Memory", symbol: "memorychip.fill", tint: Module.applications.accent,
                           fraction: Double(m.used) / Double(max(m.total, 1)),
                           value: "Pressure: \(m.pressure)", selected: detail == .memory,
                           action: (monitor.freeingMemory ? "Freeing Up..." : "Free Up", monitor.freeingMemory, { monitor.freeUpMemory() })) { toggle(.memory) }
    }

    func batteryCard(_ b: SystemMonitor.Battery) -> some View {
        MonitorCard(title: "Battery", symbol: b.isCharging ? "battery.100.bolt" : "battery.75", tint: Module.clutter.accent,
                    fraction: Double(b.percent) / 100, value: "\(b.percent)% · \(b.status)", selected: detail == .battery,
                    action: nil) { toggle(.battery) }
    }

    var cpuCard: some View {
        MonitorCard(title: "CPU", symbol: "cpu.fill", tint: Module.performance.accent, fraction: monitor.cpu.load,
                    value: "Load: \(Int(monitor.cpu.load * 100))%", selected: detail == .cpu, action: nil) { toggle(.cpu) }
    }

    var networkCard: some View {
        let n = monitor.network
        return MonitorCard(title: "Network", symbol: "wifi", tint: Module.protection.accent, fraction: nil,
                           value: n.connected ? "↓ \(speed(n.download))  ↑ \(speed(n.upload))" : "Internet connection is missing",
                           selected: detail == .network,
                           action: (monitor.testingSpeed ? "Testing..." : "Test Speed", monitor.testingSpeed, { monitor.runSpeedTest() })) { toggle(.network) }
    }

    /// CleanMyMac shows its real-time malware monitor here; TidyMac has on-demand checks only.
    var protectionCard: some View {
        MonitorCard(title: "Protection", symbol: "hand.raised.fill", tint: Module.protection.accent, fraction: nil,
                    value: "On-demand malware check", selected: false,
                    action: ("Scan", false, { open(.protection) })) { open(.protection) }
    }

    var drivesCard: some View {
        let d = monitor.drives
        return MonitorCard(title: "External Drives", symbol: "externaldrive.fill", tint: Module.spaceLens.accent, fraction: nil,
                           value: d.isEmpty ? "No devices connected" : d.count == 1 ? "\(d[0].name) · \(formatSize(d[0].available)) free" : "\(d.count) connected",
                           selected: detail == .drives,
                           action: d.isEmpty ? nil : (monitor.ejecting.isEmpty ? "Eject All" : "Ejecting...", !monitor.ejecting.isEmpty, { monitor.eject(d) })) { toggle(.drives) }
    }

    var devicesCard: some View {
        let b = monitor.bluetooth
        let value = b.isEmpty ? "No devices connected"
            : b.count == 1 ? "\(b[0].name)\(b[0].lowest.map { " · \($0)%" } ?? "")" : "\(b.count) connected"
        return MonitorCard(title: "Connected Devices", symbol: "dot.radiowaves.left.and.right", tint: Module.myTools.accent, fraction: nil,
                           value: value, selected: detail == .devices, action: nil) { toggle(.devices) }
    }

    func toggle(_ c: Card) {
        detail = detail == c ? nil : c
        monitor.wantsConsumers = detail == .memory || detail == .cpu
        if monitor.wantsConsumers { monitor.loadConsumers() }
    }

    // MARK: Details

    @ViewBuilder func detailView(_ c: Card) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch c {
            case .storage:
                let s = monitor.storage
                row("Capacity", formatSize(s.total)); row("Used", formatSize(s.total - s.available)); row("Available", formatSize(s.available))
                if let h = monitor.driveHealth {
                    row("Health", h == .good ? "Good" : h == .failing ? "Failing" : "Unknown")
                    note(h.text, warning: h == .failing)
                }
            case .memory:
                let m = monitor.memory
                row("Active", formatSize(m.active)); row("Wired", formatSize(m.wired)); row("Compressed", formatSize(m.compressed))
                row("Available", "\(formatSize(m.available)) of \(formatSize(m.total))"); row("Swap File", formatSize(m.swapUsed))
                topConsumers(by: \.memory) { formatSize($0.memory) }
            case .battery:
                if let b = monitor.battery {
                    row("Status", b.status)
                    if let c = b.cycleCount { row("Cycles", "\(c)") }
                    if let h = b.healthPercent { row("Health", "\(h)%") }
                    if let t = b.temperature { row("Temperature", String(format: "%.1f °C", t)) }
                }
            case .cpu:
                let p = monitor.cpu
                row("User", "\(Int(p.user * 100))%"); row("System", "\(Int(p.system * 100))%"); row("Available", "\(Int(p.idle * 100))%")
                row("Uptime", uptime(p.uptime))
                topConsumers(by: \.cpu) { String(format: "%.1f%%", $0.cpu) }
            case .network:
                row("Interface", monitor.network.interface ?? "None")
                if let s = monitor.speedTest { row("Download", speed(s.download)); row("Upload", speed(s.upload)) }
                else if monitor.testingSpeed { row("Speed test", "Running, about 20 seconds…") }
            case .drives:
                if monitor.drives.isEmpty { note("When connected, external storage devices will appear here.") }
                ForEach(monitor.drives) { driveRow($0) }
                if let m = monitor.ejectMessage { note(m, warning: !m.hasPrefix("Success")) }
            case .devices:
                if monitor.bluetooth.isEmpty { note("No devices connected") }
                ForEach(monitor.bluetooth) { d in
                    HStack {
                        Image(systemName: deviceSymbol(d.kind)).foregroundStyle(.white.opacity(0.8)).frame(width: 18)
                        Text(d.name).foregroundStyle(.white).lineLimit(1)
                        Spacer()
                        if d.batteries.isEmpty {
                            Text("No battery data").foregroundStyle(.white.opacity(0.5)).help("Battery charge information is not available for this device")
                        } else {
                            Text(d.batteries.map { $0.label.isEmpty ? "\($0.percent)%" : "\($0.label) \($0.percent)%" }.joined(separator: " · "))
                                .monospacedDigit().foregroundStyle((d.lowest ?? 100) <= HealthAlerts.bluetoothLowLevel ? .orange : .white)
                        }
                    }.font(.callout)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.22)))
    }

    func note(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.caption).foregroundStyle(warning ? .orange : .white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder func topConsumers(by key: KeyPath<SystemMonitor.Consumer, some Comparable>, _ value: @escaping (SystemMonitor.Consumer) -> String) -> some View {
        Divider().overlay(.white.opacity(0.15)).padding(.vertical, 2)
        Text("Top Consumers").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
        ForEach(monitor.consumers.sorted { $0[keyPath: key] > $1[keyPath: key] }.prefix(5)) { c in
            HStack(spacing: 8) {
                Text(c.name).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Text(value(c)).monospacedDigit().foregroundStyle(.white.opacity(0.8))
                if c.pid != nil {
                    Menu("Quit") { Button("Force Quit") { monitor.quit(c, force: true) } } primaryAction: { monitor.quit(c, force: false) }
                        .menuStyle(.borderlessButton).fixedSize().font(.caption)
                }
            }.font(.callout)
        }
    }

    func driveRow(_ d: SystemMonitor.Drive) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: d.isDiskImage ? "opticaldiscdrive" : "externaldrive").foregroundStyle(.white.opacity(0.8))
                Text(d.name).foregroundStyle(.white).lineLimit(1)
                Text(d.isDiskImage ? "Disk Image" : d.format ?? "").font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Spacer()
                Button { monitor.eject([d]) } label: { Image(systemName: "eject.fill") }
                    .buttonStyle(.plain).foregroundStyle(.white).disabled(monitor.ejecting.contains(d.id)).help("Eject")
            }
            GeometryReader { g in
                let used = d.total > 0 ? Double(d.total - d.available) / Double(d.total) : 0
                Capsule().fill(.white.opacity(0.15))
                    .overlay(alignment: .leading) { Capsule().fill(d.almostFull ? .orange : Module.spaceLens.accent).frame(width: g.size.width * used) }
            }
            .frame(height: 5)
            Text(d.almostFull ? "Almost Full · \(formatSize(d.available)) available" : "\(formatSize(d.available)) available of \(formatSize(d.total))")
                .font(.caption).foregroundStyle(d.almostFull ? .orange : .white.opacity(0.6))
        }.font(.callout)
    }

    func deviceSymbol(_ kind: String?) -> String {
        switch kind?.lowercased() ?? "" {
        case let k where k.contains("mouse"): "computermouse"
        case let k where k.contains("keyboard"): "keyboard"
        case let k where k.contains("trackpad"): "rectangle.and.hand.point.up.left"
        case let k where k.contains("head") || k.contains("ear"): "headphones"
        case let k where k.contains("speaker"): "hifispeaker"
        case let k where k.contains("game"): "gamecontroller"
        default: "dot.radiowaves.left.and.right"
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.white.opacity(0.65)); Spacer(); Text(v).monospacedDigit().foregroundStyle(.white) }.font(.callout)
    }

    // MARK: Recommendations & footer

    var recommendations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today's Recommendation").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            ForEach(monitor.issues) { issue in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title).font(.callout.weight(.semibold)).foregroundStyle(.white)
                        Text(issue.detail).font(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(issue.kind == .heavyMemory ? "Free Up" : issue.kind == .screenCleaning ? "Try" : "Fix") { fix(issue) }.buttonStyle(PillButtonStyle())
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
            }
        }
    }

    func fix(_ issue: SystemMonitor.Issue) {
        switch issue.kind {
        case .lowDiskSpace, .trashSize: open(.cleanup)
        case .trashedApps: open(.applications)
        case .heavyMemory: monitor.freeUpMemory()
        case .screenCleaning: app.screenCleaning.start()
        }
    }

    var footer: some View {
        HStack {
            Button("Open TidyMac") { open(nil) }.buttonStyle(PillButtonStyle())
            Spacer()
            Menu {
                Button("About TidyMac") { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps: true) }
                if #available(macOS 14, *) {
                    SettingsLink { Text("Settings…") }
                } else {
                    Button("Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.white) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    func open(_ module: Module?) {
        if let module { app.module = module }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1_000 ? "0 KB/s" : "\(formatSize(Int64(bytesPerSecond)))/s"
    }

    func uptime(_ t: TimeInterval) -> String {
        let d = Int(t) / 86_400, h = Int(t) % 86_400 / 3600, m = Int(t) % 3600 / 60
        return d > 0 ? "\(d)d \(h)h" : "\(h)h \(m)m"
    }
}

/// One monitor tile: icon, small ring gauge, value line and an optional action pill.
struct MonitorCard: View {
    let title: String, symbol: String, tint: Color
    let fraction: Double?
    let value: String
    let selected: Bool
    let action: (title: String, busy: Bool, run: () -> Void)?
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.5)))
                Spacer()
                if let fraction {
                    ZStack {
                        Circle().stroke(.white.opacity(0.15), lineWidth: 4)
                        Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                            .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                    }.frame(width: 24, height: 24)
                }
            }
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Text(value).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.8)
            if let action {
                Button(action.title, action: action.run).buttonStyle(PillButtonStyle()).disabled(action.busy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(selected ? 0.16 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(selected ? 0.3 : 0.1)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
