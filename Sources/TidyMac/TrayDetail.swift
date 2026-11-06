import SwiftUI
import TidyCore

/// The details of a menu card, in a panel of their own on the left of the menu. It is a child window of the menu,
/// so it moves and closes with it, and it never becomes key, so clicking it does not dismiss the menu.
@MainActor
final class TrayDetailPanel: ObservableObject {
    private var panel: NSPanel?
    private var host: Host?
    private weak var parent: NSWindow?
    private var resizeObserver: Any?
    static let gap: CGFloat = 12

    /// Takes clicks even while the menu, not this panel, is the key window.
    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func show(_ view: AnyView, beside window: NSWindow) {
        if let host {
            host.rootView = view
        } else {
            let host = Host(rootView: view)
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = host
            // The panel grows with its content from the bottom; keep its top level with the menu's.
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
            self.panel = panel; self.host = host
        }
        guard let panel else { return }
        panel.level = window.level
        panel.appearance = window.effectiveAppearance
        if parent !== window {
            parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        place()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = Motion.reduced ? 0 : 0.18; panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        guard let panel else { return }
        parent?.removeChildWindow(panel)
        parent = nil
        panel.orderOut(nil)
    }

    private func place() {
        guard let panel, let parent, let host else { return }
        let size = host.fittingSize
        if panel.frame.size != size { panel.setContentSize(size) }
        panel.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX - Self.gap - size.width, y: parent.frame.maxY))
    }
}

struct TrayDetail: View {
    let card: TrayView.Card
    @ObservedObject var app: AppState
    @ObservedObject var monitor: MonitorModel
    let open: (Module?) -> Void
    @State private var confirmEmptyTrash = false
    @State private var showAllDevices = false
    /// Devices listed before "Show more".
    static let visibleDevices = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 17, weight: .bold)).lineLimit(1).padding(.horizontal, 7)
            switch card {
            case .storage: storage
            case .memory: memory
            case .battery: battery
            case .cpu: cpu
            case .network: network
            case .drives: drives
            case .devices: devices
            }
        }
        .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 14)
        .frame(width: TrayView.width, alignment: .leading)
        .background(TrayBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .fixedSize(horizontal: false, vertical: true)
    }

    var title: String {
        switch card {
        case .storage: monitor.storage.name
        case .memory: String(localized: "Memory")
        case .battery: String(localized: "Battery")
        case .cpu: Self.chip
        case .network: String(localized: "Network")
        case .drives: String(localized: "External Drives")
        case .devices: String(localized: "Connected Devices")
        }
    }

    /// "Apple M4 Pro".
    static let chip: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "CPU" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "CPU" }
        return String(cString: buffer)
    }()

    // MARK: Storage

    @ViewBuilder var storage: some View {
        let s = monitor.storage
        let used = s.total - s.available
        let low = monitor.issues.contains { $0.kind == .lowDiskSpace } || (s.total > 0 && s.available < s.total / 50)
        HStack(spacing: 26) {
            Donut(parts: [(Double(used), .white)], total: Double(max(s.total, 1))) {
                BigFigure(size: s.available, color: low ? TrayStyle.warning : .primary, caption: String(localized: "of \(formatSize(s.total)) available"))
            }
            VStack(alignment: .leading, spacing: 12) {
                LegendRow(color: .white, title: String(localized: "Used"), value: formatSize(used))
                LegendRow(color: .primary.opacity(0.25), title: String(localized: "Available"), value: formatSize(s.available))
            }
        }
        .padding(.horizontal, 14)
        HStack(alignment: .top, spacing: 11) {
            if let h = monitor.driveHealth { InfoCard(symbol: "heart.fill", metric: Metric.driveHealth(h)) }
            InfoCard(symbol: nil, metric: Metric(title: String(localized: "Capacity"), value: formatSize(s.total), severity: .normal,
                                                             detail: String(localized: "The total size of your startup disk.")))
        }
        .fixedSize(horizontal: false, vertical: true)
        SectionTitle(String(localized: "Components"))
        HStack(alignment: .top, spacing: 11) {
            trash.frame(maxWidth: .infinity)
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
        }
        if confirmEmptyTrash {
            Text("Items in the Trash are deleted permanently. This cannot be undone.")
                .font(.system(size: 11)).foregroundStyle(TrayStyle.warning).padding(.horizontal, 7)
        }
    }

    /// The Trash, with its own Free Up.
    var trash: some View {
        let limit = HealthAlerts.Settings.load().trashLimit
        return VStack(alignment: .leading, spacing: 10) {
            Label("Trash", systemImage: "trash.fill").font(.system(size: 15, weight: .semibold)).labelStyle(TrayStyle.TightLabel())
            if let t = monitor.trash {
                ThinBar(fraction: Double(t.size) / Double(max(limit, 1)), color: t.size > limit ? TrayStyle.warning : .white)
                Text(String(localized: "Used: \(t.size == 0 ? "Empty" : formatSize(t.size)) of \(formatSize(limit))")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Allow Full Disk Access to analyze Trash contents.").font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Spacer()
                if monitor.trash == nil {
                    Button("Allow Access") { NSWorkspace.shared.open(Permissions.fullDiskAccessSettings) }.buttonStyle(TrayLinkStyle())
                } else if confirmEmptyTrash {
                    Button("Cancel") { confirmEmptyTrash = false }.buttonStyle(TrayTextStyle())
                    Button("Delete for Good") { confirmEmptyTrash = false; monitor.emptyTrash() }.buttonStyle(TrayLinkStyle())
                } else if (monitor.trash?.size ?? 0) > 0 {
                    Button(monitor.emptyingTrash ? String(localized: "Freeing Up...") : String(localized: "Free Up")) { confirmEmptyTrash = true }
                        .buttonStyle(TrayLinkStyle()).disabled(monitor.emptyingTrash)
                }
            }
        }
        .padding(14)
        .trayCard()
    }

    // MARK: Memory

    @ViewBuilder var memory: some View {
        let m = monitor.memory
        let parts: [(String, Int64, Color, String)] = [
            (String(localized: "Active"), m.active, Color(hex: 0x3CA8FF), String(localized: "The amount of RAM that’s being actively used")),
            (String(localized: "Wired"), m.wired, Color(hex: 0x3F7BFF), String(localized: "Memory that’s used by the system, so it must stay in RAM and can’t be borrowed by other apps")),
            (String(localized: "Compressed"), m.compressed, Color(hex: 0x6C57FE), String(localized: "The amount of memory that was compressed to make more RAM available for active apps")),
        ]
        HStack(spacing: 26) {
            Donut(parts: parts.map { (Double($0.1), $0.2) }, total: Double(max(m.total, 1))) {
                BigFigure(size: m.available, color: .primary, caption: String(localized: "of \(formatSize(m.total)) available"))
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(parts, id: \.0) { p in LegendRow(color: p.2, title: p.0, value: formatSize(p.1)).help(p.3) }
            }
        }
        .padding(.horizontal, 14)
        HStack(alignment: .top, spacing: 11) {
            InfoCard(symbol: nil, metric: Metric.memoryPressure(m))
            InfoCard(symbol: nil, metric: Metric.swap(m))
        }
        .fixedSize(horizontal: false, vertical: true)
        ConsumerList(monitor: monitor, unit: String(localized: "Usage"), key: \.memory, heavy: { $0.memory > 2_000_000_000 }) { formatSize($0.memory) }
    }

    // MARK: Battery

    @ViewBuilder var battery: some View {
        if let b = monitor.battery {
            let status = b.chartStatus
            let color = b.percent <= 20 && !b.isPluggedIn ? TrayStyle.warning : Color(hex: 0x54F3D1)
            HStack(spacing: 30) {
                TickRing(fraction: Double(b.percent) / 100, color: color) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(b.percent)").font(.system(size: 46, weight: .bold)).monospacedDigit()
                        Text("%").font(.system(size: 22, weight: .semibold))
                    }
                    .contentTransition(.numericText())
                }
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.title).font(.system(size: 16, weight: .semibold))
                        if let d = status.detail { Text(d).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    if let c = b.cycleCount {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(c) / 1000").font(.system(size: 16, weight: .semibold)).monospacedDigit()
                            Text("charge cycles").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .help("Your battery is designed to retain up to 80% of its original charge capacity at its maximum cycle count.")
                    }
                }
            }
            .padding(.horizontal, 14)
            HStack(alignment: .top, spacing: 11) {
                InfoCard(symbol: "heart.fill", metric: Metric.batteryHealth(b.healthPercent))
                if let t = b.temperature { InfoCard(symbol: "thermometer.medium", metric: Metric.batteryTemperature(t)) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: CPU

    @ViewBuilder var cpu: some View {
        let p = monitor.cpu
        HStack(alignment: .top, spacing: 18) {
            CPUChart(user: monitor.cpuUserHistory, system: monitor.cpuSystemHistory, capacity: MonitorModel.historyLength)
                .frame(height: 142)
            VStack(alignment: .leading, spacing: 16) {
                LegendBar(color: .primary.opacity(0.22), value: p.idle, title: String(localized: "Available"))
                LegendBar(color: CPUChart.user, value: p.user, title: String(localized: "User"))
                LegendBar(color: CPUChart.system, value: p.system, title: String(localized: "System"))
            }
            .frame(width: 104, alignment: .leading)
        }
        .padding(.horizontal, 7)
        HStack(alignment: .top, spacing: 11) {
            InfoCard(symbol: "clock.fill", metric: Metric.uptime(p.uptime))
            InfoCard(symbol: "gauge.with.dots.needle.67percent", metric: Metric(
                title: String(localized: "Load"), value: "\(Int(p.load * 100))%", severity: p.load > 0.8 ? .warning : .normal,
                detail: p.load > 0.8 ? String(localized: "Your Mac is working hard right now. The apps below use the most.") : String(localized: "Your processor has room for more work.")))
        }
        .fixedSize(horizontal: false, vertical: true)
        ConsumerList(monitor: monitor, unit: String(localized: "Usage, %"), key: \.cpu, heavy: { $0.cpu > 20 }) { String(format: "%.1f", $0.cpu) }
    }

    // MARK: Network

    @ViewBuilder var network: some View {
        let n = monitor.network
        if !n.connected {
            Text("No network connection. Check router and network cables and try reconnecting to Wi-Fi.")
                .font(.system(size: 13)).foregroundStyle(TrayStyle.warning).padding(.horizontal, 7)
        } else {
            let info = monitor.networkInfo
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: info?.kind == .wired ? "cable.connector" : "wifi").font(.system(size: 20, weight: .medium))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info?.name ?? String(localized: "Network")).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(info.map { $0.kind == .wifi ? String(localized: "Wi-Fi connection") : $0.kind == .wired ? String(localized: "Wired connection") : $0.kind.title } ?? String(localized: "Connected"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let i = info?.interface { Text(i).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .padding(14)
                .background(.primary.opacity(0.05))
                if let security = info.flatMap(Metric.networkSecurity) {
                    Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                    Text(security.detail).font(.system(size: 13)).foregroundStyle(TrayStyle.color(security.severity).opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true).padding(14)
                }
            }
            .trayCard()
            HStack(spacing: 11) {
                TrafficCard(title: String(localized: "Download"), total: n.received, speed: n.download, history: monitor.downloadHistory, color: Color(hex: 0x5B8CFF))
                    .help("Amount of data transferred to your Mac since its network interface came up")
                TrafficCard(title: String(localized: "Upload"), total: n.sent, speed: n.upload, history: monitor.uploadHistory, color: Color(hex: 0xFF6B81))
                    .help("Amount of data transferred from your Mac since its network interface came up")
            }
        }
        SectionTitle(String(localized: "Test Your Connection"))
        HStack(spacing: 26) {
            SpeedTestButton(testing: monitor.testingSpeed, done: monitor.speedTest != nil) { monitor.runSpeedTest() }
            VStack(alignment: .leading, spacing: 5) {
                if let s = monitor.speedTest {
                    HStack(spacing: 18) {
                        LegendRow(color: Color(hex: 0x5B8CFF), title: String(localized: "Download"), value: TrayView.speed(s.download))
                        LegendRow(color: Color(hex: 0xFF6B81), title: String(localized: "Upload"), value: TrayView.speed(s.upload))
                    }
                    let good = SystemMonitor.goodFor(download: s.download, upload: s.upload)
                    if good.isEmpty {
                        Text("Internet connection speed is very low. Try reconnecting to Wi-Fi or contact your service provider.")
                            .font(.system(size: 12)).foregroundStyle(TrayStyle.warning).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Good for:").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
                        FlowRow(items: good)
                    }
                } else if monitor.speedTestFailed {
                    Text("Network error").font(.system(size: 15, weight: .semibold))
                    Text("Check your internet connection and try again.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text("How it works").font(.system(size: 15, weight: .semibold))
                    Text(monitor.testingSpeed ? String(localized: "Running, about 20 seconds… TidyMac measures your download and upload speed with macOS’s networkQuality.")
                                              : String(localized: "TidyMac measures your download and upload speed with macOS’s networkQuality."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 7).padding(.bottom, 6)
    }

    // MARK: Drives & devices

    @ViewBuilder var drives: some View {
        if monitor.drives.isEmpty { Note(String(localized: "When connected, external storage devices will appear here.")) }
        ForEach(monitor.drives) { d in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: d.isDiskImage ? "opticaldiscdrive" : "externaldrive.fill").font(.system(size: 15))
                    Text(d.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(d.isDiskImage ? String(localized: "Disk Image") : d.format ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Eject") { monitor.eject([d]) }.buttonStyle(TrayLinkStyle()).disabled(monitor.ejecting.contains(d.id))
                }
                ThinBar(fraction: d.total > 0 ? Double(d.total - d.available) / Double(d.total) : 0, color: d.almostFull ? TrayStyle.warning : .white)
                Text(d.almostFull ? String(localized: "Almost Full · \(formatSize(d.available)) available") : String(localized: "\(formatSize(d.available)) available of \(formatSize(d.total))"))
                    .font(.system(size: 11)).foregroundStyle(d.almostFull ? TrayStyle.warning : .secondary)
            }
            .padding(14)
            .trayCard()
        }
        if let m = monitor.ejectMessage { Note(m, warning: !m.hasPrefix("Success")) }
    }

    @ViewBuilder var devices: some View {
        let all = monitor.bluetooth
        if all.isEmpty { Note(String(localized: "Connect wireless devices to your Mac, and they will appear here.")) }
        if !all.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array((showAllDevices ? all : Array(all.prefix(Self.visibleDevices))).enumerated()), id: \.element.id) { i, d in
                    if i > 0 { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
                    HStack(spacing: 12) {
                        Image(systemName: Self.deviceSymbol(d.kind)).font(.system(size: 15)).frame(width: 22)
                        Text(d.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer()
                        if d.batteries.isEmpty {
                            Text("No battery data").font(.system(size: 12)).foregroundStyle(.secondary)
                                .help("Battery charge information is not available for this device")
                        } else {
                            // AirPods report Left, Right and Case separately.
                            HStack(spacing: 10) {
                                ForEach(d.batteries, id: \.label) { b in
                                    HStack(spacing: 3) {
                                        if !b.label.isEmpty { Text(b.title.prefix(1)).foregroundStyle(.secondary).help(b.title) }
                                        Text("\(b.percent)%").monospacedDigit()
                                            .foregroundStyle(b.label != "Case" && b.percent <= HealthAlerts.bluetoothLowLevel ? TrayStyle.warning : .primary)
                                    }
                                }
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                }
            }
            .trayCard()
        }
        if all.count > Self.visibleDevices {
            Button(showAllDevices ? String(localized: "Show less") : String(localized: "Show \(all.count - Self.visibleDevices) more")) { showAllDevices.toggle() }
                .buttonStyle(TrayLinkStyle()).padding(.horizontal, 7)
        }
    }

    static func deviceSymbol(_ kind: String?) -> String {
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
}

// MARK: Pieces

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 7).padding(.top, 6) }
}

struct Note: View {
    let text: String
    var warning = false
    init(_ text: String, warning: Bool = false) { self.text = text; self.warning = warning }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(warning ? TrayStyle.warning : .secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 7)
    }
}

/// A large size in the middle of a ring: "51,4 GB" over "of 494 GB available".
struct BigFigure: View {
    let size: Int64
    let color: Color
    let caption: String
    var body: some View {
        let text = formatSize(size)
        let split = text.lastIndex(of: " ").map { (String(text[..<$0]), String(text[text.index(after: $0)...])) } ?? (text, "")
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(split.0).font(.system(size: 30, weight: .bold)).monospacedDigit()
                Text(split.1).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(color)
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 120)
        }
    }
}

struct LegendRow: View {
    let color: Color
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
        }
    }
}

/// A coloured bar beside a percentage and its name, as in the CPU legend.
struct LegendBar: View {
    let color: Color
    let value: Double
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            Capsule().fill(color).frame(width: 4, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text((value * 100).formatted(.number.precision(.fractionLength(1))) + " %").font(.system(size: 17, weight: .semibold)).monospacedDigit()
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A metric with its value in a header strip and the explanation under it.
struct InfoCard: View {
    let symbol: String?
    let metric: Metric
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol).font(.system(size: 15)) }
                Text(metric.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(metric.value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(TrayStyle.color(metric.severity))
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(.primary.opacity(0.05))
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            Text(metric.detail).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .trayCard()
    }
}

/// A ring over a faint disc: each part is an arc, in order from the top, clockwise.
struct Donut<Center: View>: View {
    let parts: [(value: Double, color: Color)]
    let total: Double
    var size: CGFloat = 196
    var line: CGFloat = 26
    @ViewBuilder let center: Center

    var body: some View {
        let ends = parts.reduce(into: [Double]()) { $0.append(($0.last ?? 0) + $1.value / total) }
        ZStack {
            Circle().fill(.primary.opacity(0.07))
            ForEach(parts.indices, id: \.self) { i in
                let start = i == 0 ? 0 : ends[i - 1]
                Circle().trim(from: min(start + (i == 0 ? 0 : 0.004), 1), to: min(ends[i], 1))
                    .stroke(parts[i].color, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: parts[i].color.opacity(0.45), radius: 8)
                    .padding(line / 2)
            }
            center
        }
        .frame(width: size, height: size)
        .animation(Motion.animation(.easeInOut(duration: 0.6)), value: ends)
    }
}

/// The battery ring: tapered ticks around a faint disc, lit up to the charge.
struct TickRing<Center: View>: View {
    let fraction: Double
    let color: Color
    var size: CGFloat = 196
    var line: CGFloat = 30
    var ticks = 44
    @ViewBuilder let center: Center

    var body: some View {
        ZStack {
            Circle().fill(.primary.opacity(0.07))
            Canvas { ctx, s in drawTicks(ctx, s) }
            .shadow(color: color.opacity(0.45), radius: 8)
            center
        }
        .frame(width: size, height: size)
    }

    // Outside `body` and with its types spelled out: older compilers give up on this much arithmetic inside a view builder.
    private func drawTicks(_ ctx: GraphicsContext, _ s: CGSize) {
        let r: CGFloat = s.width / 2
        let inner: CGFloat = r - line
        let lit = Int((min(max(fraction, 0), 1) * Double(ticks)).rounded())
        let half: Double = Double.pi / Double(ticks) * 0.5
        for i in 0..<lit {
            let a: Double = Double(i) / Double(ticks) * 2 * Double.pi - Double.pi / 2 + half * 1.2
            var p = Path()
            p.move(to: point(a - half * 0.7, inner, s)); p.addLine(to: point(a - half, r, s))
            p.addLine(to: point(a + half, r, s)); p.addLine(to: point(a + half * 0.7, inner, s)); p.closeSubpath()
            ctx.fill(p, with: .color(color))
        }
    }

    func point(_ angle: Double, _ radius: CGFloat, _ s: CGSize) -> CGPoint {
        CGPoint(x: s.width / 2 + radius * CGFloat(cos(angle)), y: s.height / 2 + radius * CGFloat(sin(angle)))
    }
}

/// User and system load over the last two minutes, on a faint grid.
struct CPUChart: View {
    static let user = Color(hex: 0x8C9BFF)
    static let system = Color(hex: 0xFF7E96)
    let user: [Double]
    let system: [Double]
    let capacity: Int

    var body: some View {
        let top = max((user.max() ?? 0) * 1.2, 0.2)
        ZStack {
            Canvas { ctx, s in
                let step: CGFloat = 14
                var grid = Path()
                for x in stride(from: 0, through: s.width, by: step) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: s.height)) }
                for y in stride(from: s.height, through: 0, by: -step) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: s.width, y: y)) }
                ctx.stroke(grid, with: .color(.primary.opacity(0.06)), lineWidth: 1)
            }
            Sparkline(values: user, color: Self.user, capacity: capacity, maxValue: top)
            Sparkline(values: system, color: Self.system, capacity: capacity, maxValue: top)
        }
    }
}

/// Download or upload: the total since the interface came up, the current speed and a live chart along the bottom.
struct TrafficCard: View {
    let title: String
    let total: Int64
    let speed: Double
    let history: [Double]
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 14).padding(.top, 13)
            HStack {
                Text(formatSize(total))
                Spacer()
                Text(TrayView.speed(speed))
            }
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 14)
            Sparkline(values: history, color: color, capacity: MonitorModel.historyLength, maxValue: max(history.max() ?? 0, 1) * 1.15)
                .frame(height: 38)
        }
        .trayCard()
    }
}

/// The round "Test speed" button: a dark disc in a halo ring, with a turning arc while the test runs.
struct SpeedTestButton: View {
    let testing: Bool
    let done: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Cycle(period: 1.2, paused: !testing) { _, phase in
                ZStack {
                    Circle().fill(Color(hex: 0x0C063F).opacity(0.55)).frame(width: 156, height: 156)
                    Circle().fill(Color(hex: 0x20194E).opacity(hover ? 1 : 0.85)).frame(width: 128, height: 128)
                        .overlay(Circle().strokeBorder(.white.opacity(hover ? 0.16 : 0.08)))
                    if testing {
                        Circle().trim(from: 0, to: 0.25)
                            .stroke(TrayStyle.link, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 142, height: 142)
                            .rotationEffect(.degrees(phase * 360))
                    }
                    Text(testing ? String(localized: "Testing...") : done ? String(localized: "Test again") : String(localized: "Test speed")).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(testing)
        .onHover { hover = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.15)), value: hover)
    }
}

/// Top Consumers: app icon, name, usage and Quit (right-click for Force Quit).
struct ConsumerList<Key: Comparable>: View {
    @ObservedObject var monitor: MonitorModel
    let unit: String
    let key: KeyPath<SystemMonitor.Consumer, Key>
    let heavy: (SystemMonitor.Consumer) -> Bool
    let value: (SystemMonitor.Consumer) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Top Consumers").font(.system(size: 15, weight: .semibold)).padding(.bottom, 14)
            HStack {
                Text("Process name")
                Spacer()
                Text(unit).frame(width: 90, alignment: .trailing)
                Color.clear.frame(width: 48, height: 1)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 6)
            ForEach(monitor.consumers.sorted { $0[keyPath: key] > $1[keyPath: key] }.prefix(5)) { c in
                HStack(spacing: 12) {
                    icon(c).frame(width: 22, height: 22)
                    Text(c.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(value(c)).font(.system(size: 13)).monospacedDigit()
                        .foregroundStyle(heavy(c) ? TrayStyle.warning : .primary.opacity(0.85))
                        .frame(width: 90, alignment: .trailing)
                    ZStack(alignment: .trailing) {
                        Color.clear.frame(height: 1)
                        if c.pid != nil {
                            Button("Quit") { monitor.quit(c, force: false) }.buttonStyle(TrayLinkStyle())
                                .contextMenu { Button("Force Quit") { monitor.quit(c, force: true) } }
                                .help("Right-click to Force Quit")
                        }
                    }
                    .frame(width: 48, alignment: .trailing)
                }
                .frame(height: 34)
            }
        }
        .padding(.horizontal, 7).padding(.top, 6)
        .animation(Motion.animation(.easeInOut(duration: 0.25)), value: monitor.consumers.map(\.id))
    }

    @ViewBuilder func icon(_ c: SystemMonitor.Consumer) -> some View {
        // App icons wash out the whole `--snapshot-tray` render (an ImageRenderer quirk); on screen they draw normally.
        if let pid = c.pid, let image = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: "gearshape.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.primary.opacity(0.12)))
        }
    }
}

struct ThinBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(color).frame(width: max(4, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

/// A live line chart; new samples come in from the right until the history is full. A dot marks the latest sample.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    let capacity: Int
    let maxValue: Double

    var body: some View {
        GeometryReader { g in
            let pts = points(g.size)
            if let first = pts.first, let last = pts.last {
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: first.x, y: g.size.height)); pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: last.x, y: g.size.height)); p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.4), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(pts) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .shadow(color: color.opacity(0.6), radius: 3)
                    Rectangle().fill(color).frame(width: 6, height: 6).rotationEffect(.degrees(45))
                        .position(x: min(last.x, g.size.width - 4), y: last.y)
                }
            }
        }
    }

    func points(_ size: CGSize) -> [CGPoint] {
        let step = size.width / CGFloat(max(capacity - 1, 1))
        let start = CGFloat(capacity - values.count) * step
        return values.enumerated().map { i, v in
            CGPoint(x: start + CGFloat(i) * step, y: 3 + (size.height - 6) * (1 - CGFloat(min(max(v / maxValue, 0), 1))))
        }
    }
}

/// Small tags that wrap onto new lines ("Good for:" activities).
struct FlowRow: View {
    let items: [String]
    var body: some View {
        // Two fixed columns are enough for the six speed test activities.
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.primary)
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}
