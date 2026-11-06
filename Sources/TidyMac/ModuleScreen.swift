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
    @Published var reviewing = false
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

    /// Protection, Quick Tidy and the Malware Finder tool all check launch items; Insights counts those checks.
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
        ZStack(alignment: .bottom) {
            if controller.phase == .intro && !access.granted {
                FullDiskAccessBanner().frame(maxHeight: .infinity, alignment: .top).padding(.top, 40)
            }
            Group {
                switch controller.phase {
                case .intro: IntroView(controller: controller)
                case .scanning, .running: ProgressScreen(controller: controller)
                case .results: ResultsView(controller: controller)
                case .done: DoneView(controller: controller)
                }
            }
            .id(controller.phase == .running ? .scanning : controller.phase)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 96)
            EdgeButton { bottomButton }
        }
        .animation(Motion.animation(.easeInOut(duration: 0.35)), value: controller.phase)
        .onChange(of: access.granted) { if $0 { controller.retryBlockedItems() } }
        .onAppear { if access.granted { controller.retryBlockedItems() } }
        .sheet(isPresented: $controller.reviewing) { ReviewSheet(controller: controller) }
        .sheet(isPresented: Binding(get: { !controller.appsToQuit.isEmpty }, set: { if !$0 { controller.appsToQuit = [] } })) {
            QuitAppsSheet(apps: controller.appsToQuit, onContinue: controller.continueAfterQuitting,
                          onCancel: { controller.appsToQuit = [] })
        }
    }

    @ViewBuilder var bottomButton: some View {
        switch controller.phase {
        case .intro: ScanButton(title: String(localized: "Scan"), module: module) { controller.scan() }
        case .scanning: ScanButton(title: String(localized: "Stop"), module: module, busy: true) { controller.stop() }
        case .running: ScanButton(title: "", module: module, busy: true, dimmed: true) {}
        case .results:
            ScanButton(title: controller.selected.isEmpty ? String(localized: "Scan") : module.actionTitle, module: module,
                       subtitle: controller.selected.isEmpty ? String(localized: "Nothing selected") :
                           controller.selectedSize > 0 ? formatSize(controller.selectedSize) : String(localized: "\(controller.selected.count) items")) {
                controller.selected.isEmpty ? controller.scan() : controller.run()
            }
        case .done: ScanButton(title: String(localized: "Done"), module: module) { controller.phase = .intro }
        }
    }
}

struct IntroView: View {
    @ObservedObject var controller: ModuleController
    var module: Module { controller.module }
    @State private var showUninstaller = false

    var body: some View {
        HStack(spacing: 70) {
            GlassIcon(module: module).appear(offset: CGSize(width: -30, height: 0), scale: 0.88)
            VStack(alignment: .leading, spacing: 14) {
                Text(module.headline).font(.system(size: 42, weight: .light)).foregroundStyle(.white)
                    .appear(delay: 0.08, offset: CGSize(width: 24, height: 0))
                Text(module.tagline).font(.system(size: 17)).foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .appear(delay: 0.14, offset: CGSize(width: 24, height: 0))
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(module.features.enumerated()), id: \.element.1) { i, f in
                        FeatureRow(symbol: f.0, title: f.1, module: module)
                            .appear(delay: 0.2 + 0.06 * Double(i), offset: CGSize(width: 24, height: 0))
                    }
                }
                .padding(.top, 30)
                if module == .clutter {
                    Button { pickFolder() } label: {
                        Label(controller.clutterRoot.lastPathComponent, systemImage: "folder.fill")
                    }.buttonStyle(PillButtonStyle()).padding(.top, 14)
                }
                if module == .applications {
                    Button("Open Uninstaller") { showUninstaller = true }.buttonStyle(PillButtonStyle()).padding(.top, 14)
                }
            }
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
        VStack(spacing: 28) {
            GlassIcon(module: controller.module, size: 200, pulsing: true)
            Text(controller.phase == .running ? String(localized: "Working on it...") : controller.progressTitle)
                .font(.system(size: 26, weight: .light)).foregroundStyle(.white)
                .id(controller.phase)
                .transition(.opacity)
            Text(controller.current).font(.callout).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                .truncationMode(.middle).frame(maxWidth: 520)
                .animation(nil, value: controller.current)
        }
    }
}

struct ResultsView: View {
    @ObservedObject var controller: ModuleController
    @ObservedObject private var access = FullDiskAccessWatcher.shared
    var module: Module { controller.module }

    var header: String {
        if controller.groups.allSatisfy(\.isEmpty) { return String(localized: "Your Mac is in great shape!") }
        switch module {
        case .smartCare: return String(localized: "Your tasks are ready to run. Look what we found:")
        case .cleanup: return String(localized: "There are \(formatSize(controller.totalSize)) of junk files on your Mac.")
        default: return String(localized: "Here is what we found.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(header).font(.system(size: 26, weight: .light)).foregroundStyle(.white)
                    .appear(offset: CGSize(width: 0, height: -10))
                Spacer()
                Button("Review All") { controller.reviewing = true }.buttonStyle(PillButtonStyle())
                Button("Start Over") { controller.phase = .intro }.buttonStyle(PillButtonStyle())
            }
            if controller.scannedWithoutAccess {
                if access.granted {
                    FullDiskAccessBanner(message: String(localized: "Full Disk Access is on. Scan again to include protected folders."),
                                         symbol: "checkmark.shield.fill", actionTitle: String(localized: "Scan Again")) { controller.scan() }
                } else {
                    FullDiskAccessBanner(message: String(localized: "Protected folders were skipped. Grant Full Disk Access to include them."))
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                    ForEach(Array(controller.groups.enumerated()), id: \.element.id) { i, g in
                        Tile(group: g, controller: controller).appear(delay: 0.05 * Double(min(i, 10)), offset: CGSize(width: 0, height: 22), scale: 0.96)
                    }
                }
                .padding(4)
            }
        }
        .padding(.horizontal, 40).padding(.top, 50)
    }
}

struct Tile: View {
    let group: ResultGroup
    @ObservedObject var controller: ModuleController
    @State private var hover = false

    var value: String {
        if group.isEmpty { return String(localized: "Nothing found") }
        guard group.totalSize > 0 else { return String(localized: "\(controller.selectedCount(of: group)) of \(group.items.count)") }
        let size = controller.selectedSize(of: group)
        return size > 0 ? formatSize(size) : String(localized: "\(formatSize(group.totalSize)) found")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: group.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: controller.module.aurora, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .opacity(group.isEmpty ? 0.35 : 0.9))
                Spacer()
                if !group.isEmpty {
                    Toggle("", isOn: Binding(get: { controller.selectedCount(of: group) > 0 }, set: { _ in controller.toggle(group) }))
                        .toggleStyle(.checkbox).labelsHidden()
                }
            }
            Text(group.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            Text(value).font(.system(size: 22, weight: .light)).foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(Motion.animation(.easeOut(duration: 0.25)), value: value)
            Text(group.isEmpty ? "" : group.verb).font(.caption).foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: 0)
            if !group.isEmpty {
                Button("Review") { controller.reviewing = true }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(16)
        .frame(height: 210, alignment: .topLeading)
        .glassTile(highlighted: hover)
        .scaleEffect(hover ? 1.015 : 1)
        .shadow(color: .black.opacity(hover ? 0.25 : 0), radius: 14, y: 8)
        .onHover { hover = $0 }
        .animation(Motion.animation(.spring(response: 0.3, dampingFraction: 0.8)), value: hover)
    }
}

/// Two-pane review: groups on the left, items of the selected group on the right.
struct ReviewSheet: View {
    @ObservedObject var controller: ModuleController
    @State private var current: String?

    var body: some View {
        let groups = controller.groups.filter { !$0.isEmpty }
        let shown = groups.first { $0.id == (current ?? groups.first?.id) }
        VStack(spacing: 0) {
            HStack {
                Text("Review \(controller.tool?.title ?? controller.module.name)").font(.title2.weight(.semibold))
                Spacer()
                Text("\(controller.selected.count) selected · \(formatSize(controller.selectedSize))").foregroundStyle(.secondary)
                Button("Done") { controller.reviewing = false }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            HSplitView {
                List(groups, selection: Binding(get: { current ?? groups.first?.id }, set: { current = $0 })) { g in
                    HStack {
                        Toggle("", isOn: Binding(get: { controller.selectedCount(of: g) == g.items.count },
                                                 set: { _ in controller.toggle(g) })).labelsHidden()
                        Image(systemName: g.symbol).frame(width: 20)
                        Text(g.title)
                        Spacer()
                        Text(g.totalSize > 0 ? formatSize(g.totalSize) : "\(g.items.count)").foregroundStyle(.secondary)
                    }.tag(g.id)
                }
                .frame(minWidth: 260, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    if let g = shown {
                        Text(g.title).font(.title3.weight(.semibold))
                        Text(g.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        List(g.items) { item in
                            HStack(alignment: .top) {
                                Toggle("", isOn: Binding(get: { controller.selected.contains(item.id) },
                                                         set: { _ in controller.toggle(item) })).labelsHidden()
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(item.title).lineLimit(1)
                                        if let b = item.badge {
                                            Text(b).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                                                .background(Capsule().fill(controller.module.accent.opacity(0.4)))
                                        }
                                    }
                                    if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                Spacer()
                                if let size = item.size, size > 0 { Text(formatSize(size)).monospacedDigit().foregroundStyle(.secondary) }
                            }
                            .contextMenu {
                                if let u = item.url { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                                Button("Add to Ignore List") { controller.ignore(item) }
                            }
                        }
                        Text("Right-click an item to add it to the Ignore List. Manage the list in Settings (⌘,).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 900, height: 580)
    }
}

struct DoneView: View {
    @ObservedObject var controller: ModuleController
    @ObservedObject private var access = FullDiskAccessWatcher.shared
    var body: some View {
        let r = controller.report ?? ActionReport()
        VStack(spacing: 18) {
            GlassIcon(module: controller.module, size: 180)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: r.failed.isEmpty ? "checkmark" : "exclamationmark")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(r.failed.isEmpty ? Color(hex: 0x2FC96D) : .orange))
                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 2))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .appear(delay: 0.35, offset: .zero, scale: 0.2)
                }
                .appear(scale: 0.85)
            Text(r.failed.isEmpty ? String(localized: "Well done!") : String(localized: "Some items were not processed"))
                .font(.system(size: 30, weight: .light)).foregroundStyle(.white)
                .appear(delay: 0.15)
            Text(r.freed > 0 ? String(localized: "\(formatSize(r.freed)) freed · \(r.succeeded.count) items") : String(localized: "\(r.succeeded.count) items done"))
                .font(.title3).foregroundStyle(.white.opacity(0.8))
                .appear(delay: 0.22)
            if !r.needsAccess.isEmpty && !access.granted {
                FullDiskAccessBanner(message: String(localized: "macOS blocked \(r.needsAccess.count) of these items. Stay on this screen and grant Full Disk Access: they will be removed as soon as you do."))
                    .frame(maxWidth: 640)
            }
            if !r.failed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(r.failed.enumerated()), id: \.offset) { _, f in
                            Text("\(f.0.title): \(f.1)").font(.caption).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }.frame(maxWidth: 520, maxHeight: 120)
            }
        }
    }
}
