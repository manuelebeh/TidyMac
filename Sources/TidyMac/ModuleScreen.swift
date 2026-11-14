import SwiftUI
import TidyCore

@MainActor
final class ModuleController: ObservableObject {
    enum Phase { case intro, scanning, results, running, done }

    let module: Module
    /// Set when the controller runs a single Toolkit scan instead of the whole module.
    let tool: Tool?
    @Published var phase: Phase = .intro
    @Published var current = ""
    @Published var groups: [ResultGroup] = []
    @Published var selected: Set<String> = []
    @Published var report: ActionReport?
    /// Running apps that hold files about to be removed; non-empty shows the quit sheet.
    @Published var appsToQuit: [NSRunningApplication] = []
    @Published var clutterRoot = Paths.home
    /// These results were found without Full Disk Access, so protected folders are missing from them.
    @Published var scannedWithoutAccess = false
    private var task: Task<Void, Never>?

    init(module: Module) { self.module = module; tool = nil }
    init(tool: Tool) { module = Module(rawValue: tool.module) ?? .myTools; self.tool = tool }

    var progressTitle: String { tool?.scanTitle ?? module.progressTitle }

    var selectedItems: [ResultItem] { groups.flatMap(\.items).filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + ($1.size ?? 0) } }
    var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }

    func scan() {
        phase = .scanning; current = ""; report = nil
        scannedWithoutAccess = !Permissions.hasFullDiskAccess
        let engine: any ScanEngine = tool.map(ToolEngine.init) ?? module.engine(clutterRoot: clutterRoot)
        task = Task {
            let result = await Task.detached(priority: .userInitiated) {
                await engine.scan { p in Task { @MainActor in self.current = p } }
            }.value
            guard !Task.isCancelled else { return }
            groups = IgnoreList.apply(result)
            selected = Set(groups.flatMap(\.items).filter(\.selectedByDefault).map(\.id))
            recordMalwareScan(groups)
            phase = .results
            Sounds.scanFinished()
        }
    }

    func stop() { task?.cancel(); phase = .intro }

    /// Protection, Full Scan and the Malware Finder tool all check launch items; History counts those checks.
    private func recordMalwareScan(_ result: [ResultGroup]) {
        let checksMalware = module == .protection || module == .smartCare || tool?.id == "malwareFinder"
        guard checksMalware else { return }
        let threats = result.flatMap(\.items).filter { $0.category == "malware" }.count
        History.recordMalwareScan(scanned: LaunchItems.all().filter { !$0.label.hasPrefix("com.apple.") }.count, threats: threats)
    }

    func run() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let apps = RunningApps.related(to: AppTerminator.removedURLs(items))
        if apps.isEmpty { execute(items) } else { appsToQuit = apps }
    }

    /// Called by the quit sheet once the apps have quit, or when the user continues anyway.
    func continueAfterQuitting() {
        appsToQuit = []
        if phase == .results { execute(selectedItems) }
    }

    private func execute(_ items: [ResultItem]) {
        phase = .running
        Task {
            var r = await Task.detached { await Executor.run(items) }.value
            PerformanceEngine.markRun(r.succeeded)
            // With access already there, it cannot be what is missing.
            if Permissions.hasFullDiskAccess { r.needsAccess = [] }
            report = r
            phase = .done
            Sounds.cleanupFinished()
        }
    }

    /// Finishes what macOS blocked, once access is granted: the user already confirmed these items.
    /// Whatever still fails is reported, and is not tried again.
    func retryBlockedItems() {
        guard phase == .done, let first = report, !first.needsAccess.isEmpty else { return }
        let items = first.needsAccess
        phase = .running
        Task {
            let r = await Task.detached { await Executor.run(items) }.value
            PerformanceEngine.markRun(r.succeeded)
            report = first.merging(retry: r)
            phase = .done
            Sounds.cleanupFinished()
        }
    }

    func toggle(_ item: ResultItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    /// Adds the item to the Ignore List and hides it from these results.
    func ignore(_ item: ResultItem) {
        IgnoreList.add([item])
        selected.remove(item.id)
        for i in groups.indices { groups[i].items.removeAll { $0.id == item.id } }
    }

    func toggle(_ group: ResultGroup) {
        let ids = Set(group.items.map(\.id))
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }

    func selectedSize(of g: ResultGroup) -> Int64 { g.items.filter { selected.contains($0.id) }.reduce(0) { $0 + ($1.size ?? 0) } }
    func selectedCount(of g: ResultGroup) -> Int { g.items.filter { selected.contains($0.id) }.count }
}

struct ModuleScreen: View {
    @ObservedObject var controller: ModuleController
    @ObservedObject private var access = FullDiskAccessWatcher.shared
    var module: Module { controller.module }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 16)
            Group {
                switch controller.phase {
                case .intro: IntroView(controller: controller)
                case .scanning, .running: ProgressScreen(controller: controller)
                case .results: ResultsView(controller: controller)
                case .done: DoneView(controller: controller)
                }
            }
            .id(controller.phase == .running ? .scanning : controller.phase)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Motion.animation(.easeInOut(duration: 0.2)), value: controller.phase)
        .onChange(of: access.granted) { if $0 { controller.retryBlockedItems() } }
        .onAppear { if access.granted { controller.retryBlockedItems() } }
        .sheet(isPresented: Binding(get: { !controller.appsToQuit.isEmpty }, set: { if !$0 { controller.appsToQuit = [] } })) {
            QuitAppsSheet(apps: controller.appsToQuit, onContinue: controller.continueAfterQuitting,
                          onCancel: { controller.appsToQuit = [] })
        }
    }

    private var subtitle: String? {
        switch controller.phase {
        case .results:
            let items = controller.groups.flatMap(\.items)
            if items.isEmpty { return String(localized: "Your Mac is in great shape!") }
            return controller.totalSize > 0 ? String(localized: "\(items.count) items · \(formatSize(controller.totalSize)) found") : String(localized: "\(items.count) items found")
        case .scanning: return controller.progressTitle
        case .running: return String(localized: "Working on it...")
        default: return nil
        }
    }

    private var header: some View {
        ScreenHeader(title: module.headline, subtitle: subtitle) {
            switch controller.phase {
            case .intro: EmptyView()
            case .scanning: Button("Stop") { controller.stop() }.buttonStyle(SecondaryButtonStyle())
            case .running: EmptyView()
            case .results:
                Button("Scan") { controller.scan() }.buttonStyle(SecondaryButtonStyle())
            case .done: Button("Done") { controller.phase = .intro }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

/// Before a scan: one centred composition, with the scan as its action.
struct IntroView: View {
    @ObservedObject var controller: ModuleController
    @ObservedObject private var access = FullDiskAccessWatcher.shared
    var module: Module { controller.module }
    @State private var showUninstaller = false

    var body: some View {
        VStack(spacing: 0) {
            if !access.granted { FullDiskAccessBanner().padding(.horizontal, 32) }
            Spacer(minLength: 0)
            EmptyState(symbol: module.symbol, tint: module.tint, title: module.headline, message: module.tagline,
                       actionTitle: String(localized: "Scan")) { controller.scan() } extra: {
                VStack(spacing: 16) {
                    FeaturePills(features: module.features, tint: module.tint)
                    if module == .clutter {
                        Button { pickFolder() } label: {
                            Label(controller.clutterRoot.path.replacingOccurrences(of: Paths.home.path, with: "~"), systemImage: "folder.fill")
                                .lineLimit(1).truncationMode(.middle)
                        }.buttonStyle(SecondaryButtonStyle())
                    }
                    if module == .applications {
                        Button("Open Uninstaller") { showUninstaller = true }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            Spacer(minLength: 0)
            Spacer(minLength: 0).frame(height: 40)
        }
        .sheet(isPresented: $showUninstaller) { UninstallerSheet(module: module) }
    }

    func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.directoryURL = controller.clutterRoot
        if p.runModal() == .OK, let u = p.url { controller.clutterRoot = u }
    }
}

struct ProgressScreen: View {
    @ObservedObject var controller: ModuleController
    var body: some View {
        VStack(spacing: 18) {
            IconChip(symbol: controller.module.symbol, tint: controller.module.tint, size: 64)
            ProgressView().progressViewStyle(.linear).frame(width: 320).tint(DS.accent)
            Text(controller.phase == .running ? String(localized: "Working on it...") : controller.progressTitle)
                .font(.system(size: 15, weight: .medium))
            Text(controller.current).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.middle).frame(maxWidth: 520)
                .animation(nil, value: controller.current)
        }
        .padding(.bottom, 60)
    }
}

/// Everything the scan found, in one list: filters with counts on top, one card per group, the action at the bottom.
struct ResultsView: View {
    @ObservedObject var controller: ModuleController
    @ObservedObject private var access = FullDiskAccessWatcher.shared
    @State private var filter: Filter = .all
    @State private var sort: Sort = .size
    var module: Module { controller.module }

    enum Filter { case all, recommended, check }
    enum Sort { case size, name }

    private var allItems: [ResultItem] { controller.groups.flatMap(\.items) }
    private var recommended: [ResultItem] { allItems.filter(\.selectedByDefault) }
    private var check: [ResultItem] { allItems.filter { !$0.selectedByDefault } }

    private func visible(_ group: ResultGroup) -> [ResultItem] {
        var items = group.items.filter {
            switch filter { case .all: true; case .recommended: $0.selectedByDefault; case .check: !$0.selectedByDefault }
        }
        switch sort {
        case .size: items.sort { ($0.size ?? 0) > ($1.size ?? 0) }
        case .name: items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            if allItems.isEmpty {
                emptyState
            } else {
                toolbar.padding(.horizontal, 32).padding(.bottom, 10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if controller.scannedWithoutAccess {
                            if access.granted {
                                FullDiskAccessBanner(message: String(localized: "Full Disk Access is on. Scan again to include protected folders."),
                                                     symbol: "checkmark.shield.fill", actionTitle: String(localized: "Scan Again")) { controller.scan() }
                            } else {
                                FullDiskAccessBanner(message: String(localized: "Protected folders were skipped. Grant Full Disk Access to include them."))
                            }
                        }
                        ForEach(controller.groups) { g in
                            let items = visible(g)
                            if !items.isEmpty { GroupCard(group: g, items: items, controller: controller) }
                        }
                    }
                    .padding(.horizontal, 32).padding(.bottom, 24)
                }
                footer
            }
        }
    }

    private var emptyState: some View {
        EmptyState(symbol: "checkmark.seal.fill", tint: DS.safe, title: String(localized: "Your Mac is in great shape!"),
                   actionTitle: String(localized: "Start Over"), primary: false) { controller.phase = .intro }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 60)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            FilterChip(title: String(localized: "All"), count: allItems.count, selected: filter == .all) { filter = .all }
            FilterChip(title: String(localized: "Recommended"), count: recommended.count, selected: filter == .recommended) { filter = .recommended }
            if !check.isEmpty {
                FilterChip(title: String(localized: "Check First"), count: check.count, selected: filter == .check) { filter = .check }
            }
            Spacer()
            Button(String(localized: "Select Recommended")) { controller.selected = Set(recommended.map(\.id)) }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(DS.accent)
                .padding(.trailing, 10)
            Menu {
                Picker("Sort", selection: $sort) {
                    Text("Largest").tag(Sort.size)
                    Text("Name").tag(Sort.name)
                }.pickerStyle(.inline)
            } label: {
                Label(sort == .size ? String(localized: "Largest") : String(localized: "Name"), systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 12.5))
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if controller.selected.isEmpty {
                Text("Nothing selected").foregroundStyle(.secondary)
            } else {
                Text("\(controller.selected.count) selected").fontWeight(.medium)
                if controller.selectedSize > 0 { Text("·").foregroundStyle(.tertiary); Text(formatSize(controller.selectedSize)).monospacedDigit() }
            }
            Spacer()
            Button("Start Over") { controller.phase = .intro }.buttonStyle(SecondaryButtonStyle())
            Button(module.actionTitle) { controller.run() }
                .buttonStyle(PrimaryButtonStyle()).disabled(controller.selected.isEmpty)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 32).padding(.vertical, 14)
        .background(DS.sidebar.opacity(0.9))
        .overlay(alignment: .top) { Rectangle().fill(DS.border).frame(height: 1) }
    }
}

/// A group of results: header with its select-all box and total, then one row per item.
struct GroupCard: View {
    let group: ResultGroup
    let items: [ResultItem]
    @ObservedObject var controller: ModuleController

    private var state: Bool? {
        let n = items.filter { controller.selected.contains($0.id) }.count
        return n == 0 ? false : n == items.count ? true : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                CheckBox(state: state) {
                    let ids = Set(items.map(\.id))
                    if state == true { controller.selected.subtract(ids) } else { controller.selected.formUnion(ids) }
                }
                IconChip(symbol: group.symbol, tint: controller.module.tint, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title).font(.system(size: 14, weight: .semibold))
                    if !group.description.isEmpty {
                        Text(group.description).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(group.totalSize > 0 ? formatSize(items.reduce(0) { $0 + ($1.size ?? 0) }) : "\(items.count)")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            .padding(14)
            Divider()
            ForEach(items) { item in
                ItemRow(item: item, controller: controller)
                if item.id != items.last?.id { Divider().padding(.leading, 44) }
            }
        }
        .card()
    }
}

struct ItemRow: View {
    let item: ResultItem
    @ObservedObject var controller: ModuleController
    @State private var hover = false

    var body: some View {
        let on = controller.selected.contains(item.id)
        HStack(alignment: .center, spacing: 12) {
            CheckBox(state: on) { controller.toggle(item) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let s = item.subtitle {
                    Text(s).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let b = item.badge {
                Text(b).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(DS.selection)).fixedSize()
            }
            VStack(alignment: .trailing, spacing: 4) {
                if let size = item.size, size > 0 { Text(formatSize(size)).font(.system(size: 13, weight: .medium)).monospacedDigit() }
                StatusBadge(kind: item.selectedByDefault ? .safe : .check)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(hover ? DS.selection.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { controller.toggle(item) }
        .onHover { hover = $0 }
        .contextMenu {
            if let u = item.url { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
            Button("Add to Ignore List") { controller.ignore(item) }
        }
    }
}

struct DoneView: View {
    @ObservedObject var controller: ModuleController
    @ObservedObject private var access = FullDiskAccessWatcher.shared
    var body: some View {
        let r = controller.report ?? ActionReport()
        let ok = r.failed.isEmpty
        ScrollView {
            VStack(spacing: 14) {
                IconChip(symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", tint: ok ? DS.safe : DS.caution, size: 64)
                    .appear(scale: 0.8)
                Text(ok ? String(localized: "Well done!") : String(localized: "Some items were not processed"))
                    .font(.system(size: 20, weight: .semibold))
                Text(r.freed > 0 ? String(localized: "\(formatSize(r.freed)) freed · \(r.succeeded.count) items") : String(localized: "\(r.succeeded.count) items done"))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                if !r.needsAccess.isEmpty && !access.granted {
                    FullDiskAccessBanner(message: String(localized: "macOS blocked \(r.needsAccess.count) of these items. Stay on this screen and grant Full Disk Access: they will be removed as soon as you do."))
                        .frame(maxWidth: 640)
                }
                if !r.failed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(r.failed.enumerated()), id: \.offset) { _, f in
                            Text("\(f.0.title): \(f.1)").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14).frame(maxWidth: 560, alignment: .leading).card()
                }
            }
            .frame(maxWidth: .infinity).padding(.top, 50).padding(.horizontal, 32)
        }
    }
}
