import SwiftUI
import TidyCore

/// Readings behind the menu bar. It lives as long as the app: a light check every minute keeps the menu bar badge
/// current while the menu is closed, and the cheap readings refresh every 2 s while it is open.
@MainActor
final class MonitorModel: ObservableObject {
    /// Samples kept for the CPU and network charts (2 minutes at one reading every 2 s).
    static let historyLength = 60

    @Published var storage = SystemMonitor.storage()
    @Published var memory = SystemMonitor.memory()
    @Published var cpu = SystemMonitor.cpu()
    @Published var battery = SystemMonitor.battery()
    @Published var network = SystemMonitor.network()
    @Published var networkInfo: SystemMonitor.NetworkInfo?
    @Published var cpuHistory: [Double] = []
    @Published var downloadHistory: [Double] = []
    @Published var uploadHistory: [Double] = []
    @Published var trash: (size: Int64, apps: Int)?
    @Published var health: MacHealth?
    @Published var hungApps: [NSRunningApplication] = []
    @Published var issues: [SystemMonitor.Issue] = []
    @Published var ignored = SystemMonitor.IgnoredIssues.load()
    @Published var freeingMemory = false
    @Published var emptyingTrash = false
    @Published var speedTest: (download: Double, upload: Double)?
    @Published var testingSpeed = false
    @Published var speedTestFailed = false
    @Published var consumers: [SystemMonitor.Consumer] = []
    @Published var drives: [SystemMonitor.Drive] = []
    @Published var bluetooth: [SystemMonitor.BluetoothDevice] = []
    @Published var driveHealth: SystemMonitor.DriveHealth?
    @Published var ejecting: Set<String> = []
    @Published var ejectMessage: String?
    /// Top Consumers are only read while the Memory or CPU details are open.
    var wantsConsumers = false
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var slowRunning = false
    private var ticks = 0

    init(background: Bool = true) {
        if background { startBackground() }
    }

    var visibleIssues: [SystemMonitor.Issue] { ignored.visible(issues) }
    /// The Screen Cleaning reminder is a suggestion, not something that needs attention.
    var needsAttention: Bool { visibleIssues.contains { $0.kind != .screenCleaning } }

    func startBackground() {
        slowTimer?.invalidate()
        slowTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in self.refreshSlow() } }
        Task { try? await Task.sleep(for: .seconds(3)); refreshSlow() }
    }

    func start() {
        refreshFast()
        refreshSlow()
        fastTimer?.invalidate()
        fastTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.refreshFast() } }
    }

    func stop() { fastTimer?.invalidate(); fastTimer = nil }

    /// Cheap readings, every 2 s while the menu is open. Drives, Bluetooth and the connection info follow every 10 s,
    /// off the main thread: `system_profiler` and CoreWLAN take tens to hundreds of milliseconds.
    func refreshFast() {
        storage = SystemMonitor.storage()
        memory = SystemMonitor.memory()
        cpu = SystemMonitor.cpu()
        battery = SystemMonitor.battery()
        network = SystemMonitor.network()
        Self.append(cpu.load, to: &cpuHistory)
        Self.append(network.download, to: &downloadHistory)
        Self.append(network.upload, to: &uploadHistory)
        let wantsConsumers = wantsConsumers, every10s = ticks % 5 == 0
        ticks += 1
        updateIssues()
        guard wantsConsumers || every10s else { return }
        Task {
            let r = await Task.detached {
                (wantsConsumers ? SystemMonitor.consumers() : nil, every10s ? SystemMonitor.externalDrives() : nil,
                 every10s ? SystemMonitor.bluetoothDevices() : nil, every10s ? SystemMonitor.networkInfo() : nil)
            }.value
            if let c = r.0 { consumers = c }
            if let d = r.1 { drives = d }
            if let b = r.2 { bluetooth = b }
            if every10s { networkInfo = r.3 }
            updateIssues()
        }
    }

    /// The expensive readings, once a minute even while the menu is closed: Trash size (walks the whole Trash),
    /// drives, Bluetooth, drive health, frozen apps and Mac Health.
    func refreshSlow() {
        guard !slowRunning else { return }
        slowRunning = true
        hungApps = HungApps.current()
        let wantsDriveHealth = driveHealth == nil
        let fda = Permissions.hasFullDiskAccess, screenDue = ScreenCleaningSession.reminderDue
        Task {
            let r = await Task.detached {
                (SystemMonitor.trash(), SystemMonitor.externalDrives(), SystemMonitor.bluetoothDevices(),
                 wantsDriveHealth ? SystemMonitor.driveHealth() : nil, MacHealth.current(hasFullDiskAccess: fda, screenCleaningDue: screenDue))
            }.value
            trash = r.0; drives = r.1; bluetooth = r.2; health = r.4
            if let h = r.3 { driveHealth = h }
            if fastTimer == nil { storage = SystemMonitor.storage(); memory = SystemMonitor.memory() }
            slowRunning = false
            updateIssues()
        }
    }

    func updateIssues() {
        issues = SystemMonitor.issues(storage: storage, memory: memory, trashSize: trash?.size, trashedApps: trash?.apps ?? 0,
                                      screenCleaningDue: ScreenCleaningSession.reminderDue,
                                      trashLimit: HealthAlerts.Settings.load().trashLimit,
                                      hungApps: hungApps.compactMap(\.localizedName), bluetooth: bluetooth, drives: drives)
    }

    static func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }

    /// Everything at once, synchronously; for `--snapshot-tray`, which renders a single frame.
    func loadAllNow() {
        for _ in 0..<12 { refreshFast(); usleep(150_000) }
        consumers = SystemMonitor.consumers(); bluetooth = SystemMonitor.bluetoothDevices(); driveHealth = SystemMonitor.driveHealth()
        drives = SystemMonitor.externalDrives(); networkInfo = SystemMonitor.networkInfo(); trash = SystemMonitor.trash()
        hungApps = HungApps.current()
        health = MacHealth.current(hasFullDiskAccess: Permissions.hasFullDiskAccess, screenCleaningDue: ScreenCleaningSession.reminderDue)
        updateIssues()
    }

    func ignore(_ kind: SystemMonitor.Issue.Kind, _ option: SystemMonitor.IgnoreOption) {
        ignored.ignore(kind, option)
        ignored.save()
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

    /// "Force Quit All" on the Non-responsive applications issue.
    func forceQuitHungApps() {
        for app in hungApps { app.forceTerminate() }
        Task { try? await Task.sleep(for: .seconds(1.5)); refreshSlow() }
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
            drives = await Task.detached { SystemMonitor.externalDrives() }.value
            updateIssues()
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
            refreshFast()
        }
    }

    /// The Trash component's Free Up. Same rule as Cleanup's Trash Bins: what is already in the Trash is deleted for good.
    func emptyTrash() {
        emptyingTrash = true
        Task {
            _ = await Task.detached {
                let items = Paths.children(Paths.home(".Trash"), hidden: true).map { url -> ResultItem in
                    var i = ResultItem.file(url, subtitle: "Trash", action: .delete(url)); i.category = "trash"; return i
                }
                return await Executor.run(items)
            }.value
            emptyingTrash = false
            refreshSlow()
        }
    }

    func runSpeedTest() {
        testingSpeed = true; speedTest = nil; speedTestFailed = false
        Task {
            speedTest = await Task.detached { SystemMonitor.speedTest() }.value
            speedTestFailed = speedTest == nil
            testingSpeed = false
        }
    }
}

/// Apps the window server marks as not responding (the spinning cursor), through SkyLight's `CGSEventIsAppUnresponsive`.
/// CleanMyMac Menu imports the related `CGSRegisterNotifyProc`. Private API: when a symbol is missing, nothing is reported.
enum HungApps {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias IsUnresponsive = @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>) -> Bool
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let api: (MainConnection, IsUnresponsive, ProcessForPID)? = {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let main = dlsym(sky, "CGSMainConnectionID"), let check = dlsym(sky, "CGSEventIsAppUnresponsive"),
              let psn = dlsym(dlopen(nil, RTLD_LAZY), "GetProcessForPID") else { return nil }
        return (unsafeBitCast(main, to: MainConnection.self), unsafeBitCast(check, to: IsUnresponsive.self),
                unsafeBitCast(psn, to: ProcessForPID.self))
    }()

    @MainActor static func current() -> [NSRunningApplication] {
        guard let (main, check, processForPID) = api else { return [] }
        let connection = main()
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, !app.isTerminated else { return false }
            var psn = ProcessSerialNumber()
            return processForPID(app.processIdentifier, &psn) == noErr && check(connection, &psn)
        }
    }
}

/// The menu bar icon, with a dot like CleanMyMac's `MonitorAttentionBadgeIcon` when an issue needs attention.
/// It stays a template image so macOS tints it for light and dark menu bars.
enum MenuBarIcon {
    static func image(attention: Bool) -> NSImage {
        let base = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "TidyMac")!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))!
        guard attention else { base.isTemplate = true; return base }
        let d: CGFloat = 6
        let image = NSImage(size: NSSize(width: base.size.width + 2, height: base.size.height), flipped: false) { rect in
            base.draw(in: NSRect(origin: .zero, size: base.size))
            let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            // A transparent ring keeps the dot readable over the symbol.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "TidyMac, needs attention"
        return image
    }
}

struct TrayView: View {
    @ObservedObject var app: AppState
    @ObservedObject var monitor: MonitorModel
    @State private var detail: Card?
    @State private var contentHeight: CGFloat = 640
    @State private var confirmEmptyTrash = false
    @State private var showAllDevices = false
    /// Screen height minus the menu bar, header, footer and padding.
    static var maxScrollHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 150 }
    struct ContentHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    /// Devices listed before "Show more" (CleanMyMac's `maxVisibleRowsCount`; its value is not in the binary's strings).
    static let visibleDevices = 4

    /// ImageRenderer (`--snapshot-tray`) cannot draw scroll views.
    var scrolls = true

    @MainActor init(app: AppState, monitor: MonitorModel, detail: Card? = nil, scrolls: Bool = true) {
        self.app = app; self.monitor = monitor; self.scrolls = scrolls
        _detail = State(initialValue: detail)
    }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme

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
        .background(TrayBackground())
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
            if !monitor.visibleIssues.isEmpty { recommendations }
        }
    }

    // MARK: Header

    /// CleanMyMac shows the Mac model with a glow in the colour of its Mac Health state.
    var header: some View {
        let state = monitor.health?.state
        let color = state?.color(scheme) ?? .secondary
        return HStack(spacing: 12) {
            ZStack {
                Circle().stroke(LinearGradient(colors: [color, color.opacity(0.15)], startPoint: .top, endPoint: .bottom), lineWidth: 3)
                    .shadow(color: color.opacity(0.8), radius: 6)
                Image(systemName: "laptopcomputer").font(.system(size: 17)).foregroundStyle(.primary)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(Host.current().localizedName ?? "This Mac").font(.headline).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 4) {
                    Text("Mac Health:").foregroundStyle(.secondary)
                    Text(state?.rawValue ?? "…").fontWeight(.semibold).foregroundStyle(color)
                }
                .font(.caption)
                Text(lastCare).font(.caption2).foregroundStyle(.secondary)
            }
            .help(monitor.health?.description ?? "")
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
        let low = monitor.issues.contains { $0.kind == .lowDiskSpace }
        let severity: Metric.Severity = s.total > 0 && s.available < s.total / 50 ? .critical : low ? .warning : .normal
        return MonitorCard(title: s.name, symbol: "internaldrive.fill", tint: Module.cleanup.accent, fraction: used,
                           value: "Available: \(formatSize(s.available))", severity: max(severity, monitor.driveHealth.map { Metric.driveHealth($0).severity } ?? .normal),
                           hint: "Click for Storage details", selected: detail == .storage,
                           action: ("Free Up", false, { open(.cleanup) })) { toggle(.storage) }
    }

    var memoryCard: some View {
        let m = monitor.memory
        return MonitorCard(title: "Memory", symbol: "memorychip.fill", tint: Module.applications.accent,
                           fraction: Double(m.used) / Double(max(m.total, 1)),
                           value: "Pressure: \(m.pressure)", severity: Metric.memoryPressure(m).severity,
                           hint: "Click for Memory details", selected: detail == .memory,
                           action: (monitor.freeingMemory ? "Freeing Up..." : "Free Up", monitor.freeingMemory, { monitor.freeUpMemory() })) { toggle(.memory) }
    }

    func batteryCard(_ b: SystemMonitor.Battery) -> some View {
        MonitorCard(title: "Battery", symbol: b.isCharging ? "battery.100.bolt" : "battery.75", tint: Module.clutter.accent,
                    fraction: Double(b.percent) / 100, value: "\(b.percent)% · \(b.status)",
                    severity: Metric.batteryHealth(b.healthPercent).severity, hint: "Click for Battery details",
                    selected: detail == .battery, action: nil) { toggle(.battery) }
    }

    var cpuCard: some View {
        MonitorCard(title: "CPU", symbol: "cpu.fill", tint: Module.performance.accent, fraction: monitor.cpu.load,
                    value: "Load: \(Int(monitor.cpu.load * 100))%", severity: Metric.uptime(monitor.cpu.uptime).severity,
                    hint: "Click for CPU details", selected: detail == .cpu, action: nil) { toggle(.cpu) }
    }

    var networkCard: some View {
        let n = monitor.network
        let severity: Metric.Severity = !n.connected ? .warning : monitor.networkInfo.flatMap(Metric.networkSecurity)?.severity ?? .normal
        return MonitorCard(title: "Network", symbol: monitor.networkInfo?.kind == .wired ? "cable.connector" : "wifi",
                           tint: Module.protection.accent, fraction: nil,
                           value: n.connected ? "↓ \(speed(n.download))  ↑ \(speed(n.upload))" : "Internet connection is missing",
                           severity: severity, hint: "Click for Network details", selected: detail == .network,
                           action: (monitor.testingSpeed ? "Testing..." : "Test Speed", monitor.testingSpeed, { monitor.runSpeedTest(); detail = .network })) { toggle(.network) }
    }

    /// CleanMyMac shows its real-time malware monitor here; TidyMac has on-demand checks only.
    var protectionCard: some View {
        MonitorCard(title: "Protection", symbol: "hand.raised.fill", tint: Module.protection.accent, fraction: nil,
                    value: "On-demand malware check", hint: "Open Protection", selected: false,
                    action: ("Scan", false, { open(.protection) })) { open(.protection) }
    }

    var drivesCard: some View {
        let d = monitor.drives
        return MonitorCard(title: "External Drives", symbol: "externaldrive.fill", tint: Module.spaceLens.accent, fraction: nil,
                           value: d.isEmpty ? "No devices connected" : d.count == 1 ? "\(d[0].name) · \(formatSize(d[0].available)) free" : "\(d.count) connected",
                           severity: d.contains(where: \.almostFull) ? .warning : .normal, hint: "Click for External Drives details",
                           selected: detail == .drives,
                           action: d.isEmpty ? nil : (monitor.ejecting.isEmpty ? "Eject All" : "Ejecting...", !monitor.ejecting.isEmpty, { monitor.eject(d) })) { toggle(.drives) }
    }

    var devicesCard: some View {
        let b = monitor.bluetooth
        let value = b.isEmpty ? "No devices connected"
            : b.count == 1 ? "\(b[0].name)\(b[0].lowest.map { " · \($0)%" } ?? "")" : "\(b.count) connected"
        let low = b.contains { ($0.lowest ?? 100) <= HealthAlerts.bluetoothLowLevel }
        return MonitorCard(title: "Connected Devices", symbol: "dot.radiowaves.left.and.right", tint: Module.myTools.accent, fraction: nil,
                           value: value, severity: low ? .warning : .normal, hint: "Click for Connected Devices details",
                           selected: detail == .devices, action: nil) { toggle(.devices) }
    }

    func toggle(_ c: Card) {
        detail = detail == c ? nil : c
        monitor.wantsConsumers = detail == .memory || detail == .cpu
        if monitor.wantsConsumers { monitor.loadConsumers() }
    }

    // MARK: Details

    @ViewBuilder func detailView(_ c: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch c {
            case .storage: storageDetail
            case .memory: memoryDetail
            case .battery: batteryDetail
            case .cpu: cpuDetail
            case .network: networkDetail
            case .drives:
                if monitor.drives.isEmpty { note("When connected, external storage devices will appear here.") }
                ForEach(monitor.drives) { driveRow($0) }
                if let m = monitor.ejectMessage { note(m, warning: !m.hasPrefix("Success")) }
            case .devices: devicesDetail
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.08)))
    }

    @ViewBuilder var storageDetail: some View {
        let s = monitor.storage
        row("Capacity", formatSize(s.total)); row("Used", formatSize(s.total - s.available)); row("Available", formatSize(s.available))
        if let h = monitor.driveHealth { MetricRow(metric: Metric.driveHealth(h)) }
        sectionTitle("Components")
        // CleanMyMac's Trash component, with its own Free Up.
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "trash.fill").foregroundStyle(.primary).frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Module.cleanup.accent.opacity(0.4)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Trash").font(.callout.weight(.semibold)).foregroundStyle(.primary)
                if let t = monitor.trash {
                    Text(t.size == 0 ? "Empty" : formatSize(t.size)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Allow Full Disk Access to analyze Trash contents.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if monitor.trash == nil {
                Button("Allow Access") { NSWorkspace.shared.open(Permissions.fullDiskAccessSettings) }.buttonStyle(PillButtonStyle())
            } else if confirmEmptyTrash {
                Button("Cancel") { confirmEmptyTrash = false }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Button("Delete for Good") { confirmEmptyTrash = false; monitor.emptyTrash() }.buttonStyle(PillButtonStyle())
            } else if (monitor.trash?.size ?? 0) > 0 {
                Button(monitor.emptyingTrash ? "Freeing Up..." : "Free Up") { confirmEmptyTrash = true }
                    .buttonStyle(PillButtonStyle()).disabled(monitor.emptyingTrash)
            }
        }
        if confirmEmptyTrash { note("Items in the Trash are deleted permanently. This cannot be undone.", warning: true) }
    }

    @ViewBuilder var memoryDetail: some View {
        let m = monitor.memory
        let parts: [(String, Int64, Color, String)] = [
            ("Active", m.active, Module.applications.accent, "The amount of RAM that’s being actively used"),
            ("Wired", m.wired, Module.smartCare.accent, "Memory that’s used by the system, so it must stay in RAM and can’t be borrowed by other apps"),
            ("Compressed", m.compressed, Module.performance.accent, "The amount of memory that was compressed to make more RAM available for active apps"),
            ("Available", m.available, .primary.opacity(0.2), "The amount of RAM that can be used freely"),
        ]
        SegmentBar(parts: parts.map { (Double($0.1), $0.2) })
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
            ForEach(parts, id: \.0) { p in
                HStack(spacing: 6) {
                    Circle().fill(p.2).frame(width: 7, height: 7)
                    Text(p.0).foregroundStyle(.secondary)
                    Spacer()
                    Text(formatSize(p.1)).monospacedDigit().foregroundStyle(.primary)
                }
                .font(.caption).help(p.3)
            }
        }
        MetricRow(metric: Metric.memoryPressure(m))
        MetricRow(metric: Metric.swap(m))
        topConsumers(by: \.memory) { formatSize($0.memory) }
    }

    @ViewBuilder var batteryDetail: some View {
        if let b = monitor.battery {
            let status = b.chartStatus
            HStack(alignment: .firstTextBaseline) {
                Text(status.title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                Text("\(b.percent)%").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
            }
            if let d = status.detail { note(d) }
            Bar(fraction: Double(b.percent) / 100, color: b.percent <= 20 ? .orange : Module.clutter.accent)
            if let c = b.cycleCount {
                row("Cycles", "\(c) charge cycles")
                    .help("Your battery is designed to retain up to 80% of its original charge capacity at its maximum cycle count.")
            }
            MetricRow(metric: Metric.batteryHealth(b.healthPercent))
            if let t = b.temperature { MetricRow(metric: Metric.batteryTemperature(t)) }
        }
    }

    @ViewBuilder var cpuDetail: some View {
        let p = monitor.cpu
        Sparkline(series: [(monitor.cpuHistory, Module.performance.accent)], capacity: MonitorModel.historyLength, maxValue: 1)
        row("User", "\(Int(p.user * 100))%"); row("System", "\(Int(p.system * 100))%"); row("Available", "\(Int(p.idle * 100))%")
        MetricRow(metric: Metric.uptime(p.uptime))
        topConsumers(by: \.cpu) { String(format: "%.1f%%", $0.cpu) }
    }

    @ViewBuilder var networkDetail: some View {
        let n = monitor.network
        if !n.connected {
            note("No network connection. Check router and network cables and try reconnecting to Wi-Fi.", warning: true)
        } else {
            Sparkline(series: [(monitor.downloadHistory, Module.protection.accent), (monitor.uploadHistory, Module.applications.accent)],
                      capacity: MonitorModel.historyLength)
            HStack(spacing: 12) {
                Label("Download \(speed(n.download))", systemImage: "arrow.down").foregroundStyle(Module.protection.accent)
                Label("Upload \(speed(n.upload))", systemImage: "arrow.up").foregroundStyle(Module.applications.accent)
            }
            .font(.caption.monospacedDigit())
            if let info = monitor.networkInfo {
                row("Connection type", info.kind == .wifi ? "Wi-Fi connection" : info.kind == .wired ? "Wired connection" : info.kind.rawValue)
                if let name = info.name { row("Name", name) }
                row("Interface", info.interface)
                if let security = Metric.networkSecurity(info) { MetricRow(metric: security) }
            }
            row("Downloaded", formatSize(n.received)).help("Amount of data transferred to your Mac since its network interface came up")
            row("Uploaded", formatSize(n.sent)).help("Amount of data transferred from your Mac since its network interface came up")
        }
        sectionTitle("Test Your Connection")
        if let s = monitor.speedTest {
            row("Download", speed(s.download)); row("Upload", speed(s.upload))
            let good = SystemMonitor.goodFor(download: s.download, upload: s.upload)
            if good.isEmpty {
                note("Internet connection speed is very low. Try reconnecting to Wi-Fi or contact your service provider.", warning: true)
            } else {
                Text("Good for:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FlowRow(items: good)
            }
        } else if monitor.testingSpeed {
            note("Running, about 20 seconds… TidyMac uses macOS’s networkQuality to measure your connection.")
        } else if monitor.speedTestFailed {
            note("Network error. Check your internet connection and try again.", warning: true)
        } else {
            note("Measures your download and upload speed with macOS’s networkQuality.")
        }
        if !monitor.testingSpeed {
            Button(monitor.speedTest == nil ? "Test Speed" : "Test Again") { monitor.runSpeedTest() }.buttonStyle(PillButtonStyle())
        }
    }

    @ViewBuilder var devicesDetail: some View {
        let all = monitor.bluetooth
        if all.isEmpty { note("Connect wireless devices to your Mac, and they will appear here.") }
        ForEach(showAllDevices ? all : Array(all.prefix(Self.visibleDevices))) { d in
            HStack {
                Image(systemName: deviceSymbol(d.kind)).foregroundStyle(.primary.opacity(0.8)).frame(width: 18)
                Text(d.name).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                if d.batteries.isEmpty {
                    Text("No battery data").foregroundStyle(.secondary).help("Battery charge information is not available for this device")
                } else {
                    // AirPods report Left, Right and Case separately.
                    HStack(spacing: 8) {
                        ForEach(d.batteries, id: \.label) { b in
                            HStack(spacing: 3) {
                                if !b.label.isEmpty { Text(b.label.prefix(1)).foregroundStyle(.secondary).help(b.label) }
                                Text("\(b.percent)%").monospacedDigit()
                                    .foregroundStyle(b.label != "Case" && b.percent <= HealthAlerts.bluetoothLowLevel ? .orange : .primary)
                            }
                        }
                    }
                }
            }
            .font(.callout)
        }
        if all.count > Self.visibleDevices {
            Button(showAllDevices ? "Show less" : "Show \(all.count - Self.visibleDevices) more") { showAllDevices.toggle() }
                .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    func note(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.caption).foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)).fixedSize(horizontal: false, vertical: true)
    }

    func sectionTitle(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(.primary.opacity(0.15)).padding(.top, 2)
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder func topConsumers(by key: KeyPath<SystemMonitor.Consumer, some Comparable>, _ value: @escaping (SystemMonitor.Consumer) -> String) -> some View {
        sectionTitle("Top Consumers")
        ForEach(monitor.consumers.sorted { $0[keyPath: key] > $1[keyPath: key] }.prefix(5)) { c in
            HStack(spacing: 8) {
                Text(c.name).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                Text(value(c)).monospacedDigit().foregroundStyle(.primary.opacity(0.8))
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
                Image(systemName: d.isDiskImage ? "opticaldiscdrive" : "externaldrive").foregroundStyle(.primary.opacity(0.8))
                Text(d.name).foregroundStyle(.primary).lineLimit(1)
                Text(d.isDiskImage ? "Disk Image" : d.format ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { monitor.eject([d]) } label: { Image(systemName: "eject.fill") }
                    .buttonStyle(.plain).foregroundStyle(.primary).disabled(monitor.ejecting.contains(d.id)).help("Eject")
            }
            Bar(fraction: d.total > 0 ? Double(d.total - d.available) / Double(d.total) : 0, color: d.almostFull ? .orange : Module.spaceLens.accent)
            Text(d.almostFull ? "Almost Full · \(formatSize(d.available)) available" : "\(formatSize(d.available)) available of \(formatSize(d.total))")
                .font(.caption).foregroundStyle(d.almostFull ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
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
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit().foregroundStyle(.primary).lineLimit(1) }.font(.callout)
    }

    // MARK: Recommendations & footer

    var recommendations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today's Recommendation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(monitor.visibleIssues) { issue in
                let look = Self.look(issue.kind)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: look.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                        .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(look.module.accent.opacity(0.45)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                        Text(issue.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button(look.action) { fix(issue) }.buttonStyle(PillButtonStyle())
                            Menu("Ignore") {
                                ForEach(SystemMonitor.IgnoreOption.allCases, id: \.self) { o in
                                    Button(o.title) { monitor.ignore(issue.kind, o) }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize().font(.caption)
                        }
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.08)))
            }
        }
    }

    /// Icon, module colour and button for each issue, after CleanMyMac's `Recommendation*` icons and issue buttons.
    static func look(_ kind: SystemMonitor.Issue.Kind) -> (symbol: String, module: Module, action: String) {
        switch kind {
        case .lowDiskSpace: ("internaldrive.fill", .cleanup, "Free Up")
        case .trashSize: ("trash.fill", .cleanup, "Review Trash")
        case .trashedApps: ("app.badge.checkmark", .applications, "Uninstall...")
        case .heavyMemory: ("memorychip.fill", .performance, "Free Up")
        case .hungApps: ("hourglass", .performance, "Force Quit All")
        case .bluetoothLow: ("battery.25", .myTools, "See All Devices")
        case .externalFull: ("externaldrive.fill", .spaceLens, "Free Up")
        case .screenCleaning: ("sparkles.tv", .smartCare, "Try")
        }
    }

    func fix(_ issue: SystemMonitor.Issue) {
        switch issue.kind {
        case .lowDiskSpace: open(.cleanup)
        case .trashSize: detail = .storage
        case .trashedApps: open(.applications)
        case .heavyMemory: monitor.freeUpMemory()
        case .hungApps: monitor.forceQuitHungApps()
        case .bluetoothLow: detail = .devices
        case .externalFull: open(.spaceLens)
        case .screenCleaning: app.screenCleaning.start()
        }
    }

    var footer: some View {
        HStack(spacing: 12) {
            Button("Open TidyMac") { open(nil) }.buttonStyle(PillButtonStyle())
            Spacer()
            Button { app.screenCleaning.start() } label: { Image(systemName: "sparkles.tv") }
                .buttonStyle(.plain).foregroundStyle(.primary).help("Screen Cleaning Mode")
            if #available(macOS 14, *) {
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(.primary).help("Settings")
            } else {
                Button { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.primary).help("Settings")
            }
            Menu {
                Button("About TidyMac") { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps: true) }
                Button("Provide Feedback...") { NSWorkspace.shared.open(URL(string: "https://github.com/manuelebeh/TidyMac/issues")!) }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.primary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .font(.system(size: 14))
    }

    func open(_ module: Module?) {
        if let module { app.module = module }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1_000 ? "0 KB/s" : "\(formatSize(Int64(bytesPerSecond)))/s"
    }
}

/// The Smart Care gradient in Dark Mode, a pale version of it in Light Mode.
struct TrayBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if scheme == .dark {
            ModuleBackground(module: .smartCare)
        } else {
            ZStack {
                LinearGradient(colors: [Color(hex: 0xFBF5FD), Color(hex: 0xEEE2FA)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Module.smartCare.accent.opacity(0.18), .clear], center: .init(x: 0.85, y: 0.1), startRadius: 10, endRadius: 360)
            }
            .ignoresSafeArea()
        }
    }
}

/// One monitor tile: icon with a severity dot, small ring gauge, value line and an optional action pill.
struct MonitorCard: View {
    let title: String, symbol: String, tint: Color
    let fraction: Double?
    let value: String
    var severity: Metric.Severity = .normal
    let hint: String
    let selected: Bool
    let action: (title: String, busy: Bool, run: () -> Void)?
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.5)))
                    .overlay(alignment: .topTrailing) {
                        // CleanMyMac's SimpleMonitorBadgeView.
                        if severity > .normal {
                            Circle().fill(severity.color).frame(width: 9, height: 9).offset(x: 3, y: -3)
                        }
                    }
                Spacer()
                if let fraction {
                    ZStack {
                        Circle().stroke(.primary.opacity(0.15), lineWidth: 4)
                        Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                            .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                    }.frame(width: 24, height: 24)
                }
            }
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
            Text(value).font(.caption).foregroundStyle(.primary.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.8)
            if let action {
                Button(action.title, action: action.run).buttonStyle(PillButtonStyle()).disabled(action.busy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.primary.opacity(selected ? 0.16 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(selected ? 0.3 : 0.1)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .help(hint)
    }
}

/// A detail row with a value coloured by severity and a line explaining it (CleanMyMac's metric rows).
struct MetricRow: View {
    let metric: Metric
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(metric.title).foregroundStyle(.secondary)
                Spacer()
                Text(metric.value).monospacedDigit().fontWeight(.medium).foregroundStyle(metric.severity.color)
            }
            .font(.callout)
            Text(metric.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Metric.Severity {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// A live line chart; new samples come in from the right until the history is full.
struct Sparkline: View {
    let series: [(values: [Double], color: Color)]
    let capacity: Int
    var maxValue: Double?

    var body: some View {
        GeometryReader { g in
            let top = maxValue ?? max(series.flatMap(\.values).max() ?? 0, 1)
            ZStack {
                ForEach(series.indices, id: \.self) { i in
                    let pts = points(series[i].values, size: g.size, top: top)
                    if let first = pts.first, let last = pts.last {
                        Path { p in
                            p.move(to: CGPoint(x: first.x, y: g.size.height)); pts.forEach { p.addLine(to: $0) }
                            p.addLine(to: CGPoint(x: last.x, y: g.size.height)); p.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [series[i].color.opacity(0.35), series[i].color.opacity(0)], startPoint: .top, endPoint: .bottom))
                        Path { p in p.addLines(pts) }
                            .stroke(series[i].color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .frame(height: 54)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.05)))
    }

    func points(_ values: [Double], size: CGSize, top: Double) -> [CGPoint] {
        let step = size.width / CGFloat(max(capacity - 1, 1))
        let start = CGFloat(capacity - values.count) * step
        return values.enumerated().map { i, v in
            CGPoint(x: start + CGFloat(i) * step, y: size.height * (1 - CGFloat(min(max(v / top, 0), 1))))
        }
    }
}

/// A horizontal bar split into coloured parts, like the memory chart's groups.
struct SegmentBar: View {
    let parts: [(value: Double, color: Color)]
    var body: some View {
        GeometryReader { g in
            let total = max(parts.reduce(0) { $0 + $1.value }, 1)
            HStack(spacing: 2) {
                ForEach(parts.indices, id: \.self) { i in
                    Rectangle().fill(parts[i].color).frame(width: max(0, (g.size.width - CGFloat(parts.count - 1) * 2) * parts[i].value / total))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}

/// Small tags that wrap onto new lines ("Good for:" activities).
struct FlowRow: View {
    let items: [String]
    var body: some View {
        // Two fixed columns are enough for the six speed test activities.
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.primary)
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}
