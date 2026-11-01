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
    @Published var cpuUserHistory: [Double] = []
    @Published var cpuSystemHistory: [Double] = []
    /// Marketing name such as "MacBook Pro", read once (system_profiler is slow).
    @Published var machine = "Mac"
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
        if machine == "Mac" { Task { machine = await Task.detached { SystemMonitor.machineName() }.value } }
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
        Self.append(cpu.user, to: &cpuUserHistory)
        Self.append(cpu.system, to: &cpuSystemHistory)
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
        let known = driveHealth
        let fda = Permissions.hasFullDiskAccess, screenDue = ScreenCleaningSession.reminderDue
        Task {
            let r = await Task.detached {
                let drive = known ?? SystemMonitor.driveHealth()
                return (SystemMonitor.trash(), SystemMonitor.externalDrives(), SystemMonitor.bluetoothDevices(), drive,
                        MacHealth.current(hasFullDiskAccess: fda, screenCleaningDue: screenDue, driveHealth: drive))
            }.value
            trash = r.0; drives = r.1; bluetooth = r.2; driveHealth = r.3; health = r.4
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
        hungApps = HungApps.current(); machine = SystemMonitor.machineName()
        health = MacHealth.current(hasFullDiskAccess: Permissions.hasFullDiskAccess, screenCleaningDue: ScreenCleaningSession.reminderDue,
                                   driveHealth: driveHealth)
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

    /// Quit and Force Quit are offered for apps; plain processes are left alone.
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
        let clean = GeneralSettings.cleansOnEject()
        Task {
            var failed: [String] = []
            var cleaned: Int64 = 0
            for d in list {
                // "Clean up junk automatically on ejection": the drive's own Trash, which would otherwise stay on it.
                if clean, !d.isDiskImage {
                    let junk = await Task.detached { SystemMonitor.driveTrash(d) }.value
                    if !junk.isEmpty { cleaned += await Task.detached { await Executor.run(junk) }.value.freed }
                }
                let ok = await Task.detached { (try? NSWorkspace.shared.unmountAndEjectDevice(at: d.url)) != nil }.value
                if !ok { failed.append(d.name) }
                ejecting.remove(d.id)
            }
            ejectMessage = failed.isEmpty ? "Successfully ejected!" : "\(failed.joined(separator: ", ")) could not be ejected."
            if cleaned > 0 { ejectMessage! += " \(FileSize.format(cleaned)) of junk cleaned." }
            drives = await Task.detached { SystemMonitor.externalDrives() }.value
            updateIssues()
        }
    }

    /// `purge` needs root, so TidyMac asks for the password; there is no privileged helper.
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
/// Private API: when a symbol is missing, nothing is reported.
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

/// The menu bar icon, with a dot when an issue needs attention.
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
    @State private var contentHeight: CGFloat = 560
    @State private var window: NSWindow?
    @StateObject private var panel = TrayDetailPanel()
    /// Screen height minus the menu bar, header, footer and padding.
    static var maxScrollHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 150 }
    struct ContentHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    static let width: CGFloat = 420

    /// ImageRenderer (`--snapshot-tray`) cannot draw scroll views or windows.
    var scrolls = true

    @MainActor init(app: AppState, monitor: MonitorModel, detail: Card? = nil, scrolls: Bool = true) {
        self.app = app; self.monitor = monitor; self.scrolls = scrolls
        _detail = State(initialValue: detail)
    }
    @Environment(\.colorScheme) private var scheme

    enum Card: String { case storage, memory, battery, cpu, network, drives, devices }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 21).padding(.top, 18).padding(.bottom, 16)
            // Scrolls only when the cards and recommendations no longer fit on screen.
            Group {
                if scrolls {
                    ScrollView(showsIndicators: false) {
                        content.background(GeometryReader { Color.clear.preference(key: ContentHeight.self, value: $0.size.height) })
                    }
                    .frame(height: min(contentHeight, Self.maxScrollHeight))
                    .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
                } else {
                    content
                }
            }
            footer
        }
        .frame(width: Self.width)
        .background(TrayBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .background(WindowReader { window = $0; fitWindow() })
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop(); detail = nil; panel.hide() }
        .onChange(of: detail) { _ in updatePanel() }
        .onChange(of: contentHeight) { _ in fitWindow() }
    }

    /// Fits the panel to the content as it grows or shrinks, keeping its top under the menu bar.
    func fitWindow() {
        DispatchQueue.main.async {
            guard let window, let size = window.contentView?.fittingSize, size.height > 0,
                  abs(window.frame.height - size.height) > 0.5 else { return }
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: window.frame.width, height: size.height),
                            display: true)
        }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 11) {
            protectionCard
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 11, alignment: .top), GridItem(.flexible(), spacing: 11, alignment: .top)],
                      alignment: .leading, spacing: 11) {
                storageCard
                memoryCard
                if let b = monitor.battery { batteryCard(b) }
                cpuCard
                networkCard
                devicesCard
                if !monitor.drives.isEmpty { drivesCard }
            }
            if !monitor.visibleIssues.isEmpty { recommendations.transition(.opacity.combined(with: .offset(y: 8))) }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    // MARK: Header

    /// Mac Health with the Mac on a glow in the colour of its state; a click opens Smart Care.
    var header: some View {
        let state = monitor.health?.state
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("Mac Health:")
                    Text(state?.rawValue ?? "…").foregroundStyle(state?.color(scheme) ?? .secondary)
                }
                .font(.system(size: 18, weight: .semibold))
                Text(monitor.machine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HealthGlow(color: state?.glow ?? .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(.smartCare) }
        .help((monitor.health?.description ?? "") + "\nClick to open Smart Care.")
    }

    // MARK: Cards

    /// TidyMac has no real-time malware monitor; the card shows the last on-demand scan.
    var protectionCard: some View {
        let last = History.entries.last { $0.scanned != nil }
        let threats = last?.threats ?? 0
        let shield: Color = last == nil ? .secondary : threats > 0 ? TrayStyle.warning : Color(hex: 0x22C503)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: threats > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .symbolRenderingMode(.palette).foregroundStyle(.white, shield)
                    .font(.system(size: 19))
                Text("Protection").font(.system(size: 15, weight: .semibold))
                Spacer()
                if last == nil {
                    Button("Scan") { open(.protection) }.buttonStyle(TrayLinkStyle())
                } else {
                    Label(threats > 0 ? "\(threats) to review" : "No threats", systemImage: threats > 0 ? "exclamationmark.triangle" : "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(threats > 0 ? TrayStyle.warning : .primary)
                }
            }
            Text("On-demand malware check").font(.system(size: 13, weight: .medium)).padding(.top, 16)
            Text(last.map { "Last scan: \(RelativeDateTimeFormatter().localizedString(for: $0.date, relativeTo: Date()))" } ?? "No scan yet")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .trayCard(radius: 12)
        .contentShape(Rectangle())
        .onTapGesture { open(.protection) }
        .help("Open Protection")
    }

    var storageCard: some View {
        let s = monitor.storage
        let low = monitor.issues.contains { $0.kind == .lowDiskSpace } || (s.total > 0 && s.available < s.total / 50)
        return TrayTile(title: s.name, symbol: "internaldrive.fill", subtitle: "Available: \(formatSize(s.available))",
                        subtitleColor: low ? TrayStyle.warning : .secondary, selected: detail == .storage, hint: "Click for Storage details",
                        action: ("Free Up", false, { open(.cleanup) })) { toggle(.storage) }
    }

    var memoryCard: some View {
        let m = monitor.memory
        let tight = Metric.memoryPressure(m).severity > .normal
        return TrayTile(title: "Memory", symbol: "memorychip", subtitle: "Pressure: \(m.pressure)",
                        subtitleColor: tight ? TrayStyle.warning : .secondary, selected: detail == .memory, hint: "Click for Memory details",
                        action: (monitor.freeingMemory ? "Freeing Up..." : "Free Up", monitor.freeingMemory, { monitor.freeUpMemory() })) { toggle(.memory) }
    }

    func batteryCard(_ b: SystemMonitor.Battery) -> some View {
        TrayTile(title: "Battery", symbol: b.isCharging ? "battery.100percent.bolt" : "battery.50percent", trailing: "\(b.percent)%",
                 trailingColor: b.percent <= 20 && !b.isPluggedIn ? TrayStyle.warning : .primary,
                 subtitle: Self.batteryLine(b), selected: detail == .battery, hint: "Click for Battery details") { toggle(.battery) }
    }

    /// "4h 3m remaining", like the menu's other durations.
    static func batteryLine(_ b: SystemMonitor.Battery) -> String {
        guard !b.isCharging, !b.isPluggedIn, let m = b.minutesRemaining else { return b.status }
        return "\(m / 60)h \(m % 60)m remaining"
    }

    var cpuCard: some View {
        TrayTile(title: "CPU", symbol: "cpu", subtitle: "Load: \(Int(monitor.cpu.load * 100))%",
                 subtitleColor: monitor.cpu.load > 0.8 ? TrayStyle.warning : .secondary,
                 selected: detail == .cpu, hint: "Click for CPU details") { toggle(.cpu) }
    }

    var networkCard: some View {
        let n = monitor.network
        let wired = monitor.networkInfo?.kind == .wired
        return TrayTile(title: n.connected ? monitor.networkInfo?.name ?? "Network" : "Network", symbol: wired ? "cable.connector" : "wifi",
                        subtitle: n.connected ? nil : "Internet connection is missing", subtitleColor: TrayStyle.warning,
                        selected: detail == .network, hint: "Click for Network details",
                        action: (monitor.testingSpeed ? "Testing..." : "Test Speed", monitor.testingSpeed, { monitor.runSpeedTest(); detail = .network })) {
            toggle(.network)
        } extra: {
            if n.connected {
                VStack(alignment: .leading, spacing: 8) {
                    Label(Self.speed(n.upload), systemImage: "arrow.up")
                    Label(Self.speed(n.download), systemImage: "arrow.down")
                }
                .font(.system(size: 11).monospacedDigit())
                .labelStyle(TrayStyle.TightLabel())
                .padding(.top, 8)
            }
        }
    }

    var devicesCard: some View {
        let b = monitor.bluetooth
        let value = b.isEmpty ? "No devices connected"
            : b.count == 1 ? "\(b[0].name)\(b[0].lowest.map { " · \($0)%" } ?? "")" : "\(b.count) connected"
        let low = b.contains { ($0.lowest ?? 100) <= HealthAlerts.bluetoothLowLevel }
        return TrayTile(title: "Connected Devices", symbol: nil, subtitle: value, subtitleColor: low ? TrayStyle.warning : .secondary,
                        selected: detail == .devices, hint: "Click for Connected Devices details") { toggle(.devices) }
    }

    var drivesCard: some View {
        let d = monitor.drives
        return TrayTile(title: "External Drives", symbol: "externaldrive.fill",
                        subtitle: d.count == 1 ? "\(d[0].name) · \(formatSize(d[0].available)) free" : "\(d.count) connected",
                        subtitleColor: d.contains(where: \.almostFull) ? TrayStyle.warning : .secondary,
                        selected: detail == .drives, hint: "Click for External Drives details",
                        action: (monitor.ejecting.isEmpty ? "Eject All" : "Ejecting...", !monitor.ejecting.isEmpty, { monitor.eject(d) })) { toggle(.drives) }
    }

    func toggle(_ c: Card) { detail = detail == c ? nil : c }

    /// Details open in their own panel on the left of the menu.
    func updatePanel() {
        monitor.wantsConsumers = detail == .memory || detail == .cpu
        if monitor.wantsConsumers { monitor.loadConsumers() }
        guard scrolls, let window else { return }
        if let detail {
            panel.show(AnyView(TrayDetail(card: detail, app: app, monitor: monitor, open: open).environment(\.colorScheme, scheme)), beside: window)
        } else {
            panel.hide()
        }
    }

    // MARK: Recommendations & footer

    var recommendations: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Today's Recommendation").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary.opacity(0.85))
                .padding(.leading, 11).padding(.top, 8)
            ForEach(monitor.visibleIssues) { issue in
                let look = Self.look(issue.kind)
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: look.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LinearGradient(colors: look.module.aurora, startPoint: .topLeading, endPoint: .bottomTrailing)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.title).font(.system(size: 13, weight: .semibold))
                        Text(issue.detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 14) {
                            Spacer()
                            Menu("Ignore") {
                                ForEach(SystemMonitor.IgnoreOption.allCases, id: \.self) { o in
                                    Button(o.title) { monitor.ignore(issue.kind, o) }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
                            Button(look.action) { fix(issue) }.buttonStyle(TrayButtonStyle())
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(16)
                .trayCard(radius: 12)
            }
        }
    }

    /// Icon, module colour and button for each issue.
    static func look(_ kind: SystemMonitor.Issue.Kind) -> (symbol: String, module: Module, action: String) {
        switch kind {
        case .lowDiskSpace: ("internaldrive.fill", .cleanup, "Free Up")
        case .trashSize: ("trash.fill", .cleanup, "Review Trash")
        case .trashedApps: ("app.badge.checkmark", .applications, "Uninstall...")
        case .heavyMemory: ("memorychip.fill", .performance, "Free Up")
        case .hungApps: ("hourglass", .performance, "Force Quit All")
        case .bluetoothLow: ("battery.25", .myTools, "See All Devices")
        case .externalFull: ("externaldrive.fill", .spaceLens, "Free Up")
        case .screenCleaning: ("sparkles.tv", .protection, "Try Screen Cleaning Mode")
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
        case .screenCleaning: TrayController.shared?.close(); app.screenCleaning.start()
        }
    }

    var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            ZStack {
                Button("Show TidyMac") { open(nil) }.buttonStyle(TrayTextStyle())
                HStack(spacing: 6) {
                    Button { TrayController.shared?.close(); app.screenCleaning.start() } label: { Image(systemName: "sparkles.tv") }
                        .buttonStyle(TraySquareStyle()).help("Screen Cleaning Mode")
                    Spacer()
                    Button { TrayController.openSettings() } label: { Image(systemName: "gearshape.fill") }
                        .buttonStyle(TraySquareStyle()).help("Settings")
                    Menu {
                        Button("About TidyMac") { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps: true) }
                        Button("Provide Feedback...") { NSWorkspace.shared.open(URL(string: "https://github.com/manuelebeh/TidyMac/issues")!) }
                        Divider()
                        Button("Quit") { NSApp.terminate(nil) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.16)))
                        .help("More")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
        }
    }

    func open(_ module: Module?) {
        if let module { app.module = module }
        TrayController.shared?.close()
        if let openMain = app.openMain {
            openMain()
        } else if let url = URL(string: "tidymac://open/\(app.module.rawValue)") {
            NSWorkspace.shared.open(url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1_000 ? "0 KB/sec" : "\(formatSize(Int64(bytesPerSecond)))/sec"
    }
}

/// Colours and small pieces shared by the menu and its detail panel.
enum TrayStyle {
    static let link = Color(hex: 0x4FB0FF)
    static let selected = Color(hex: 0x4D7DFF)
    static let warning = Color(hex: 0xF5B942)

    static func color(_ s: Metric.Severity) -> Color {
        switch s {
        case .normal: .primary
        case .warning: warning
        case .critical: Color(hex: 0xFF6B6B)
        }
    }

    /// Icon and text closer together than the system label.
    struct TightLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) { configuration.icon.fontWeight(.semibold); configuration.title }
        }
    }
}

/// Card surface of the menu: faint glass with a hairline edge, a blue edge when selected.
struct TrayCard: ViewModifier {
    var radius: CGFloat = 10
    var selected = false
    var hover = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(dark ? Color.white.opacity(hover ? 0.11 : 0.07) : Color.white.opacity(hover ? 0.75 : 0.58)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(selected ? TrayStyle.selected : dark ? Color.white.opacity(0.09) : Color.black.opacity(0.07),
                                        lineWidth: selected ? 2 : 1))
    }
}

extension View {
    func trayCard(radius: CGFloat = 10, selected: Bool = false, hover: Bool = false) -> some View {
        modifier(TrayCard(radius: radius, selected: selected, hover: hover))
    }
}

/// One monitor tile: glyph, title with an optional value on the right, a status line and a link at the bottom right.
struct TrayTile<Extra: View>: View {
    let title: String
    let symbol: String?
    var trailing: String? = nil
    var trailingColor: Color = .primary
    var subtitle: String? = nil
    var subtitleColor: Color = .secondary
    let selected: Bool
    let hint: String
    var action: (title: String, busy: Bool, run: () -> Void)? = nil
    let onTap: () -> Void
    @ViewBuilder var extra: Extra
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary.opacity(0.9))
                    .frame(width: 22, height: 17)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let trailing {
                        Text(trailing).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(trailingColor)
                    }
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(subtitleColor).lineLimit(1).minimumScaleFactor(0.85)
                }
                extra
                if let action {
                    HStack {
                        Spacer()
                        Button(action.title, action: action.run).buttonStyle(TrayLinkStyle()).disabled(action.busy)
                    }
                    .padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .trayCard(selected: selected, hover: hover)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hover = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.15)), value: hover)
        .animation(Motion.animation(.easeInOut(duration: 0.2)), value: selected)
        .help(hint)
    }
}

extension TrayTile where Extra == EmptyView {
    init(title: String, symbol: String?, trailing: String? = nil, trailingColor: Color = .primary, subtitle: String? = nil,
         subtitleColor: Color = .secondary, selected: Bool, hint: String, action: (title: String, busy: Bool, run: () -> Void)? = nil,
         onTap: @escaping () -> Void) {
        self.init(title: title, symbol: symbol, trailing: trailing, trailingColor: trailingColor, subtitle: subtitle, subtitleColor: subtitleColor,
                  selected: selected, hint: hint, action: action, onTap: onTap) { EmptyView() }
    }
}

/// Blue text links: "Free Up", "Test Speed", "Quit".
struct TrayLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Link(label: configuration.label, pressed: configuration.isPressed) }

    private struct Link<Label: View>: View {
        let label: Label
        let pressed: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TrayStyle.link.opacity(!enabled ? 0.5 : pressed ? 0.6 : hover ? 0.8 : 1))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// The bordered button of a recommendation.
struct TrayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Body(label: configuration.label, pressed: configuration.isPressed) }

    private struct Body<Label: View>: View {
        let label: Label
        let pressed: Bool
        @State private var hover = false
        var body: some View {
            label
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(pressed ? 0.22 : hover ? 0.16 : 0.1)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.18)))
                .onHover { hover = $0 }
                .animation(Motion.animation(.easeOut(duration: 0.12)), value: hover)
        }
    }
}

/// Square footer buttons.
struct TraySquareStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Square(label: configuration.label, pressed: configuration.isPressed) }

    private struct Square<Label: View>: View {
        let label: Label
        let pressed: Bool
        @State private var hover = false
        var body: some View {
            label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(pressed ? 0.32 : hover ? 0.24 : 0.16)))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(Motion.animation(.easeOut(duration: 0.12)), value: hover)
        }
    }
}

/// "Show TidyMac": plain text that brightens under the pointer.
struct TrayTextStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Body(label: configuration.label, pressed: configuration.isPressed) }

    private struct Body<Label: View>: View {
        let label: Label
        let pressed: Bool
        @State private var hover = false
        var body: some View {
            label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(pressed ? 0.6 : hover ? 1 : 0.88))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// The Smart Care live background in Dark Mode, a pale version of it in Light Mode.
struct TrayBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LiveBackground(palette: scheme == .dark ? Module.smartCare.live : Module.smartCare.live.light(base: 0xF6EEFC))
            .ignoresSafeArea()
    }
}

/// The Mac in the menu header, a cyan laptop standing on a glow in the colour of its Mac Health state. The glow breathes slowly.
struct HealthGlow: View {
    let color: Color

    var body: some View {
        Cycle(period: 4.8) { wave, _ in
            ZStack {
                Ellipse().fill(RadialGradient(colors: [color.opacity(0.9), color.opacity(0)], center: .center, startRadius: 0, endRadius: 34))
                    .frame(width: 70, height: 24)
                    .offset(y: 17)
                    .blur(radius: 5)
                    .opacity(0.5 + 0.4 * wave)
                    .scaleEffect(0.94 + 0.12 * wave)
                Image(systemName: "laptopcomputer").font(.system(size: 40, weight: .regular))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0xB4F0FF), Color(hex: 0x3DA8F2)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color(hex: 0x55CEFE).opacity(0.45), radius: 6, y: 2)
            }
        }
        .frame(width: 66, height: 48)
        .animation(Motion.animation(.easeInOut(duration: 0.6)), value: color)
    }
}

/// Hands back the window a view is in (the menu bar panel), once it is in one.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { Probe(found: found) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { self.found(window) }
        }
    }
}
