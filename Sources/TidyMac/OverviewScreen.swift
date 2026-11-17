import SwiftUI
import TidyCore

/// Home: how full the disk is, and one row per area of the app with what its last scan found.
/// Starting the Full Scan hands the window over to the regular module screens until it is dismissed.
struct OverviewScreen: View {
    @ObservedObject var app: AppState
    @ObservedObject var controller: ModuleController
    @State private var storage = SystemMonitor.storage()
    @State private var parts: [StorageBreakdown.Part] = []
    @State private var hoveredSlice: String?

    private let areas: [Module] = [.cleanup, .clutter, .applications, .protection, .performance, .spaceLens]

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
                    diskCard
                    VStack(spacing: 0) {
                        ForEach(Array(areas.enumerated()), id: \.element) { i, m in
                            AreaRow(module: m, app: app)
                            if i < areas.count - 1 { Divider().padding(.leading, 64) }
                        }
                    }
                    .card()
                }
                .pagePadding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { storage = SystemMonitor.storage() }
        .task { for await measured in StorageBreakdown.measure() { parts = measured } }
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
            let slices = layout(geo.size.width)
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
                    VStack(spacing: 1) {
                        Text(item.segment.title).font(.system(size: 12, weight: .semibold))
                        Text(FileSize.format(item.segment.bytes)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .fixedSize()
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.window))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(DS.border))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    // A zero-size anchor on the slice's centre, 8pt above the bar: the bubble is centred on it, bottom edge on it.
                    .frame(width: 0, height: 0, alignment: .bottom)
                    .offset(x: item.x + item.w / 2, y: -8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
        .frame(height: 14)
        .animation(Motion.animation(.easeOut(duration: 0.12)), value: hovered)
    }
}

/// An area of the app: icon, name, one line about it, and either the size a scan found or a chevron.
struct AreaRow: View {
    let module: Module
    @ObservedObject var app: AppState
    @ObservedObject private var controller: ModuleController
    @State private var hover = false

    init(module: Module, app: AppState) {
        self.module = module
        self.app = app
        _controller = ObservedObject(wrappedValue: app.controllers[module]!)
    }

    private var found: String? {
        guard controller.phase == .results, controller.totalSize > 0 else { return nil }
        return formatSize(controller.totalSize)
    }

    var body: some View {
        Button { app.module = module } label: {
            HStack(spacing: DS.Space.item) {
                IconChip(symbol: module.symbol, tint: module.tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.name).font(.system(size: 14, weight: .semibold))
                    Text(module.tagline).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if let found { Text(found).font(.system(size: 14, weight: .semibold)).monospacedDigit() }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.Space.rowH).padding(.vertical, DS.Space.item)
            .background(hover ? DS.selection.opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(module.tagline)
        .onHover { hover = $0 }
    }
}
