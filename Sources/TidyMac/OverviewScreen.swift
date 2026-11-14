import SwiftUI
import TidyCore

/// Home: how full the disk is, and one row per area of the app with what its last scan found.
/// Starting the Full Scan hands the window over to the regular module screens until it is dismissed.
struct OverviewScreen: View {
    @ObservedObject var app: AppState
    @ObservedObject var controller: ModuleController
    @ObservedObject private var access = FullDiskAccessWatcher.shared
    @State private var storage = SystemMonitor.storage()

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
            .padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !access.granted { FullDiskAccessBanner() }
                    diskCard
                    VStack(spacing: 0) {
                        ForEach(Array(areas.enumerated()), id: \.element) { i, m in
                            AreaRow(module: m, app: app)
                            if i < areas.count - 1 { Divider().padding(.leading, 64) }
                        }
                    }
                    .card()
                }
                .padding(.horizontal, 32).padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { storage = SystemMonitor.storage() }
    }

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(storage.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(formatSize(used)).font(.system(size: 30, weight: .semibold)).monospacedDigit()
                        Text("used of \(formatSize(storage.total))").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Available: \(formatSize(storage.available))").font(.system(size: 13, weight: .medium)).monospacedDigit()
                    Text("\(Int((1 - usedFraction) * 100))%").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            UsageBar(segments: [.init(fraction: usedFraction, color: usedFraction > 0.9 ? DS.caution : DS.accent)], height: 10)
        }
        .padding(18)
        .card()
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
            HStack(spacing: 14) {
                IconChip(symbol: module.features.first?.0 ?? module.symbol, tint: module.tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.name).font(.system(size: 14, weight: .semibold))
                    Text(module.tagline).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if let found { Text(found).font(.system(size: 14, weight: .semibold)).monospacedDigit() }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(hover ? DS.selection.opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
