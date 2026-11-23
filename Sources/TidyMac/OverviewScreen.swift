import Combine
import SwiftUI
import TidyCore

/// Home: how the Mac is doing and what to do about it, how full the disk is, and live readings (memory, processor, battery, uptime).
/// Starting the Full Scan hands the window over to the regular module screens until it is dismissed.
struct OverviewScreen: View {
    @ObservedObject var app: AppState
    @ObservedObject var controller: ModuleController
    @State private var storage = SystemMonitor.storage()
    @State private var parts: [StorageBreakdown.Part] = []
    @State private var hoveredSlice: String?

    @State private var memory = SystemMonitor.memory()
    @State private var cpu = SystemMonitor.cpu()
    @State private var battery = SystemMonitor.battery()
    @State private var freeingMemory = false
    @State private var trash = SystemMonitor.trash()
    @State private var purgeable = SpaceLens.purgeableSpace()
    @State private var consumers: [SystemMonitor.Consumer] = []
    @State private var health: MacHealth?
    @State private var machine = "Mac"
    @AppStorage(GeneralSettings.assistantKey) private var showsRecommendations = true
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        if controller.phase == .intro {
            overview
        } else {
            ModuleScreen(controller: controller)
        }
    }

    private var used: Int64 { max(storage.total - storage.available, 0) }
    private var usedFraction: Double { storage.total > 0 ? Double(used) / Double(storage.total) : 0 }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: String(localized: "Overview"), subtitle: Module.smartCare.tagline) {
                Button("Scan Everything") { controller.scan() }.buttonStyle(PrimaryButtonStyle())
            }
            .headerPadding()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.section) {
                    healthSection
                    diskCard
                    systemSection
                    actionsSection
                    consumersCard
                }
                .pagePadding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { storage = SystemMonitor.storage() }
        .onReceive(refresh) { _ in
            memory = SystemMonitor.memory(); cpu = SystemMonitor.cpu(); battery = SystemMonitor.battery()
            trash = SystemMonitor.trash()
            Task { consumers = await Task.detached { SystemMonitor.consumers() }.value }
        }
        .task {
            await loadHealth()
            machine = await Task.detached { SystemMonitor.machineName() }.value
            // The update check behind "Install application updates" runs at most once a day.
            await AppFacts.refreshIfStale()
            await loadHealth()
        }
        .task { consumers = await Task.detached { SystemMonitor.consumers() }.value }
        .task { for await measured in StorageBreakdown.measure() { parts = measured } }
    }

    private func loadHealth() async {
        let due = ScreenCleaningSession.reminderDue, fda = Permissions.hasFullDiskAccess
        health = await Task.detached {
            MacHealth.current(hasFullDiskAccess: fda, screenCleaningDue: due, driveHealth: SystemMonitor.driveHealth())
        }.value
    }

    // MARK: Health

    /// Mac Health next to what to do about it; side by side when there is room.
    @ViewBuilder private var healthSection: some View {
        if showsRecommendations {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.section) {
                    MacHealthCard(health: health, machine: machine).frame(maxWidth: 340)
                    RecommendationsCard(app: app, health: $health)
                }
                .fixedSize(horizontal: false, vertical: true).frame(minWidth: 700)
                VStack(spacing: DS.Space.section) {
                    MacHealthCard(health: health, machine: machine)
                    RecommendationsCard(app: app, health: $health)
                }
            }
        } else {
            MacHealthCard(health: health, machine: machine)
        }
    }

    // MARK: System

    private var systemSection: some View {
        let uptime = SystemMonitor.uptime()
        var tiles: [StatusTile] = [
            StatusTile(id: "memory", symbol: "memorychip", tint: Module.spaceLens.tint, title: String(localized: "Memory"),
                       value: formatSize(memory.used), detail: String(localized: "\(formatSize(memory.used)) of \(formatSize(memory.total)) used"),
                       fraction: memory.total > 0 ? Double(memory.used) / Double(memory.total) : 0,
                       warning: memory.pressureLevel >= 2),
            StatusTile(id: "cpu", symbol: "cpu", tint: Module.performance.tint, title: String(localized: "Processor"),
                       value: "\(Int(cpu.load * 100))%", detail: String(localized: "Load"), fraction: cpu.load, warning: cpu.load > 0.8),
        ]
        if let battery {
            tiles.append(StatusTile(id: "battery", symbol: battery.isCharging ? "battery.100.bolt" : "battery.75", tint: Module.cleanup.tint,
                                    title: String(localized: "Battery"), value: "\(battery.percent)%", detail: battery.status,
                                    fraction: Double(battery.percent) / 100, warning: !battery.isPluggedIn && battery.percent <= 20))
        }
        tiles.append(StatusTile(id: "uptime", symbol: "clock.fill", tint: Module.smartCare.tint, title: String(localized: "Uptime"),
                                value: Metric.formatUptime(uptime), detail: Metric.uptime(uptime).severity == .normal
                                    ? String(localized: "Your Mac was restarted less than a week ago.") : String(localized: "It’s been over a week now. Restart your Mac once in a while."),
                                fraction: nil, warning: Metric.uptime(uptime).severity != .normal))
        return VStack(alignment: .leading, spacing: 10) {
            Text("System").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.section) { ForEach(tiles) { StatusTileView(tile: $0) } }
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.section, alignment: .top), GridItem(.flexible(), alignment: .top)],
                          spacing: DS.Space.section) { ForEach(tiles) { StatusTileView(tile: $0) } }
            }
        }
    }

    // MARK: Quick actions

    private var actionsSection: some View {
        let actions: [QuickAction] = [
            QuickAction(id: "ram", symbol: "memorychip", tint: Module.spaceLens.tint, title: String(localized: "Free Up RAM"),
                        detail: String(localized: "Flushes inactive memory so apps get room to work."),
                        button: String(localized: "Free Up"), busy: freeingMemory) { freeUpMemory() },
            QuickAction(id: "trash", symbol: "trash.fill", tint: Module.cleanup.tint, title: String(localized: "Trash"),
                        detail: trash.map { formatSize($0.size) } ?? String(localized: "Size needs Full Disk Access"),
                        button: String(localized: "Review"), busy: false) { app.openTool("trashBin") },
            // Local Time Machine snapshots are what macOS mostly counts as purgeable.
            QuickAction(id: "purgeable", symbol: "externaldrive.fill", tint: Module.performance.tint, title: String(localized: "Purgeable Space"),
                        detail: purgeable.map { formatSize($0) } ?? "–", button: String(localized: "Review"), busy: false) { app.openTool("timeMachineSnapshot") },
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Quick Actions").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            // Columns by available width, not by how long the texts are: longer translations wrap instead of stacking the row.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.section, alignment: .top), count: 3), spacing: DS.Space.section) {
                ForEach(actions) { QuickActionView(action: $0).frame(minHeight: 76) }
            }
        }
    }

    /// `purge` needs root, so macOS asks for the password.
    private func freeUpMemory() {
        freeingMemory = true
        Task {
            var item = ResultItem(title: String(localized: "Free Up RAM"), action: .run(Command("/usr/sbin/purge"), admin: true))
            item.category = "maintenance"
            _ = await Task.detached { [item] in await Executor.run([item]) }.value
            freeingMemory = false
            memory = SystemMonitor.memory()
        }
    }

    /// What uses the most memory right now, in two columns.
    private var consumersCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.item) {
            Text("Top Consumers").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.section * 2), GridItem(.flexible())], alignment: .leading,
                      spacing: DS.Space.item) {
                ForEach(consumers.sorted { $0.memory > $1.memory }.prefix(8)) { c in
                    HStack(spacing: 12) {
                        if let pid = c.pid, let image = NSRunningApplication(processIdentifier: pid)?.icon {
                            Image(nsImage: image).resizable().interpolation(.high).frame(width: 32, height: 32)
                        } else {
                            IconChip(symbol: "gearshape.fill", tint: DS.glyph, size: 32)
                        }
                        Text(c.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(FileSize.format(c.memory)).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .padding(DS.Space.card)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }

    // MARK: Storage

    /// One legend entry: a group of the disk and the colour of its slice.
    private struct Slice: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let color: Color
    }

    private func color(_ kind: StorageBreakdown.Kind) -> Color {
        switch kind {
        case .applications: Color(hex: 0xEB4D4B)
        case .documents: Color(hex: 0xF0963E)
        case .photos: Color(hex: 0x5CC46A)
        case .media: Color(hex: 0x9B6BDB)
        }
    }

    private func title(_ kind: StorageBreakdown.Kind) -> String {
        switch kind {
        case .applications: String(localized: "Applications")
        case .documents: String(localized: "Documents")
        case .photos: String(localized: "Photos")
        case .media: String(localized: "Media")
        }
    }

    /// The measured groups, largest first, then whatever is left of the used space as System Data (grey, as in System Settings).
    private var slices: [Slice] {
        let known = parts.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
            .map { Slice(id: $0.kind.rawValue, title: title($0.kind), bytes: $0.bytes, color: color($0.kind)) }
        let rest = max(used - known.reduce(0) { $0 + $1.bytes }, 0)
        return known + [Slice(id: "system", title: String(localized: "System Data"), bytes: rest, color: Color.gray)]
    }

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.item) {
            HStack(alignment: .firstTextBaseline) {
                Text(storage.name).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(String(localized: "\(formatSize(used)) of \(formatSize(storage.total)) used"))
                    .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            }
            StorageBar(segments: slices.map { .init(id: $0.id, title: $0.title, bytes: $0.bytes, color: $0.color) },
                       total: storage.total, hovered: $hoveredSlice)
            HStack(spacing: 14) {
                ForEach(slices) { slice in
                    HStack(spacing: 6) {
                        Circle().fill(slice.color).frame(width: 8, height: 8)
                        Text(slice.title).font(.system(size: 12)).foregroundStyle(hoveredSlice == slice.id ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                    .onHover { hoveredSlice = $0 ? slice.id : nil }
                }
                Spacer(minLength: 0)
                Text(String(localized: "Available: \(formatSize(storage.available))"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(usedFraction > 0.9 ? DS.caution : .secondary).monospacedDigit()
            }
            .lineLimit(1)
        }
        .padding(DS.Space.card)
        .card()
        .animation(Motion.animation(.easeOut(duration: 0.3)), value: parts.count)
    }
}

/// The storage bar of System Settings: one rounded bar, a slice per group with a hairline gap, free space as the track.
/// Hovering a slice (or its legend entry) lifts it and shows its name and size in a bubble above it.
struct StorageBar: View {
    struct Segment: Identifiable { let id: String; let title: String; let bytes: Int64; let color: Color }
    let segments: [Segment]
    let total: Int64
    @Binding var hovered: String?

    private func layout(_ width: CGFloat) -> [(segment: Segment, x: CGFloat, w: CGFloat)] {
        let visible = segments.filter { $0.bytes > 0 }
        let usable = width - CGFloat(max(visible.count - 1, 0))
        var x: CGFloat = 0
        return visible.map { s in
            let w = max(2, usable * CGFloat(Double(s.bytes) / Double(max(total, 1))))
            defer { x += w + 1 }
            return (s, x, w)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let slices = layout(width)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(DS.track)
                ForEach(slices, id: \.segment.id) { item in
                    Rectangle().fill(item.segment.color)
                        .opacity(hovered == nil || hovered == item.segment.id ? 1 : 0.45)
                        .frame(width: item.w).offset(x: item.x)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = slices.first { p.x >= $0.x && p.x <= $0.x + $0.w + 1 }?.segment.id
                case .ended: hovered = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let h = hovered, let item = slices.first(where: { $0.segment.id == h }) {
                    // One line, so the bubble always fits between the top of the card and the bar (the page scroll clips what overflows).
                    HStack(spacing: 6) {
                        Text(item.segment.title).font(.system(size: 12, weight: .semibold))
                        Text(FileSize.format(item.segment.bytes)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .fixedSize()
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.window))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(DS.border))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    // A zero-size anchor on the slice's centre, 8pt above the bar: the bubble is centred on it, bottom edge on it.
                    .frame(width: 0, height: 0, alignment: .bottom)
                    .offset(x: min(max(item.x + item.w / 2, 90), max(width - 90, 90)) , y: -6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
        .frame(height: 14)
        .animation(Motion.animation(.easeOut(duration: 0.12)), value: hovered)
    }
}

struct StatusTile: Identifiable {
    let id: String, symbol: String, title: String, value: String, detail: String
    let tint: Color, fraction: Double?, warning: Bool
    init(id: String, symbol: String, tint: Color, title: String, value: String, detail: String, fraction: Double?, warning: Bool) {
        self.id = id; self.symbol = symbol; self.tint = tint; self.title = title; self.value = value
        self.detail = detail; self.fraction = fraction; self.warning = warning
    }
}

/// A live reading of the Mac: badge, name, the value, a short line and (when it has a scale) a thin gauge.
struct StatusTileView: View {
    let tile: StatusTile

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            HStack(spacing: 10) {
                IconChip(symbol: tile.symbol, tint: tile.tint, size: 28)
                Text(tile.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(tile.value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                .foregroundStyle(tile.warning ? DS.caution : .primary).lineLimit(1)
            if let f = tile.fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.track)
                        Capsule().fill(tile.warning ? DS.caution : tile.tint).frame(width: max(4, geo.size.width * min(max(f, 0), 1)))
                    }
                }
                .frame(height: 5)
            }
            Text(tile.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        }
        .padding(DS.Space.card)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .help(tile.detail)
    }
}

struct QuickAction: Identifiable {
    let id: String, symbol: String, title: String, detail: String, button: String
    let tint: Color, busy: Bool, run: () -> Void
    init(id: String, symbol: String, tint: Color, title: String, detail: String, button: String, busy: Bool, run: @escaping () -> Void) {
        self.id = id; self.symbol = symbol; self.tint = tint; self.title = title; self.detail = detail
        self.button = button; self.busy = busy; self.run = run
    }
}

/// One thing to do right now: badge, name, what it concerns, and the button.
struct QuickActionView: View {
    let action: QuickAction

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.item) {
            IconChip(symbol: action.symbol, tint: action.tint, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(action.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if action.busy { ProgressView().controlSize(.small) }
            else { Button(action.button, action: action.run).buttonStyle(SecondaryButtonStyle()).fixedSize() }
        }
        .padding(DS.Space.card)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .card()
    }
}
