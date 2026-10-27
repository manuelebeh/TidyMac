import SwiftUI
import TidyCore

@MainActor
final class ModuleController: ObservableObject {
    enum Phase { case intro, scanning, results, running, done }

    let module: Module
    /// Set when the controller runs a single My Tools scan instead of the whole module.
    let tool: Tool?
    @Published var phase: Phase = .intro
    @Published var current = ""
    @Published var groups: [ResultGroup] = []
    @Published var selected: Set<String> = []
    @Published var report: ActionReport?
    @Published var reviewing = false
    @Published var clutterRoot = Paths.home
    private var task: Task<Void, Never>?

    init(module: Module) { self.module = module; tool = nil }
    init(tool: Tool) { module = Module(rawValue: tool.module) ?? .myTools; self.tool = tool }

    var progressTitle: String { tool?.scanTitle ?? module.progressTitle }

    var selectedItems: [ResultItem] { groups.flatMap(\.items).filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + ($1.size ?? 0) } }
    var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }

    func scan() {
        phase = .scanning; current = ""; report = nil
        let engine: any ScanEngine = tool.map(ToolEngine.init) ?? module.engine(clutterRoot: clutterRoot)
        task = Task {
            let result = await Task.detached(priority: .userInitiated) {
                await engine.scan { p in Task { @MainActor in self.current = p } }
            }.value
            guard !Task.isCancelled else { return }
            groups = result
            selected = Set(result.flatMap(\.items).filter(\.selectedByDefault).map(\.id))
            recordMalwareScan(result)
            phase = .results
        }
    }

    func stop() { task?.cancel(); phase = .intro }

    /// Protection, Smart Care and the Malware Finder tool all check launch items; My Activity counts those checks.
    private func recordMalwareScan(_ result: [ResultGroup]) {
        let checksMalware = module == .protection || module == .smartCare || tool?.id == "malwareFinder"
        guard checksMalware else { return }
        let threats = result.flatMap(\.items).filter { $0.category == "malware" }.count
        History.recordMalwareScan(scanned: LaunchItems.all().filter { !$0.label.hasPrefix("com.apple.") }.count, threats: threats)
    }

    func run() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        phase = .running
        Task {
            let r = await Task.detached { await Executor.run(items) }.value
            PerformanceEngine.markRun(r.succeeded)
            report = r
            phase = .done
        }
    }

    func toggle(_ item: ResultItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
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
    var module: Module { controller.module }

    var body: some View {
        ZStack(alignment: .bottom) {
            if controller.phase == .intro && !Permissions.hasFullDiskAccess {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 110)
            bottomButton.padding(.bottom, 22)
        }
        .sheet(isPresented: $controller.reviewing) { ReviewSheet(controller: controller) }
    }

    @ViewBuilder var bottomButton: some View {
        switch controller.phase {
        case .intro: ScanButton(title: "Scan", module: module) { controller.scan() }
        case .scanning: ScanButton(title: "Stop", module: module) { controller.stop() }
        case .running: ScanButton(title: "...", module: module) {}
        case .results:
            ScanButton(title: controller.selected.isEmpty ? "Scan" : module.actionTitle, module: module,
                       subtitle: controller.selected.isEmpty ? "Nothing selected" :
                           controller.selectedSize > 0 ? formatSize(controller.selectedSize) : "\(controller.selected.count) items") {
                controller.selected.isEmpty ? controller.scan() : controller.run()
            }
        case .done: ScanButton(title: "Done", module: module) { controller.phase = .intro }
        }
    }
}

/// Without Full Disk Access, macOS blocks or prompts for most of what a cleaner needs to read.
struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.yellow)
            Text("Grant Full Disk Access so TidyMac can scan protected folders without repeated prompts.")
                .font(.callout).foregroundStyle(.white)
            Button("Open Settings") { NSWorkspace.shared.open(Permissions.fullDiskAccessSettings) }
                .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(.black.opacity(0.25)))
    }
}

struct IntroView: View {
    @ObservedObject var controller: ModuleController
    var module: Module { controller.module }
    @State private var showUninstaller = false

    var body: some View {
        HStack(spacing: 70) {
            GlassIcon(module: module)
            VStack(alignment: .leading, spacing: 14) {
                Text(module.headline).font(.system(size: 38, weight: .light)).foregroundStyle(.white)
                Text(module.tagline).font(.system(size: 15)).foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: 360, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(module.features, id: \.1) { FeatureRow(symbol: $0.0, title: $0.1, module: module) }
                }
                .padding(.top, 12)
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
            Text(controller.phase == .running ? "Working on it..." : controller.progressTitle)
                .font(.system(size: 26, weight: .light)).foregroundStyle(.white)
            Text(controller.current).font(.callout).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            ProgressView().progressViewStyle(.linear).tint(.white).frame(width: 260)
        }
    }
}

struct ResultsView: View {
    @ObservedObject var controller: ModuleController
    var module: Module { controller.module }

    var header: String {
        if controller.groups.allSatisfy(\.isEmpty) { return "Your Mac is in great shape!" }
        switch module {
        case .smartCare: return "Your tasks are ready to run. Look what we found:"
        case .cleanup: return "There are \(formatSize(controller.totalSize)) of junk files on your Mac."
        default: return "Here is what we found."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(header).font(.system(size: 26, weight: .light)).foregroundStyle(.white)
                Spacer()
                Button("Review All") { controller.reviewing = true }.buttonStyle(PillButtonStyle())
                Button("Start Over") { controller.phase = .intro }.buttonStyle(PillButtonStyle())
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                    ForEach(controller.groups) { g in Tile(group: g, controller: controller) }
                }
            }
        }
        .padding(.horizontal, 40).padding(.top, 50)
    }
}

struct Tile: View {
    let group: ResultGroup
    @ObservedObject var controller: ModuleController

    var value: String {
        if group.isEmpty { return "Nothing found" }
        guard group.totalSize > 0 else { return "\(controller.selectedCount(of: group)) of \(group.items.count)" }
        let size = controller.selectedSize(of: group)
        return size > 0 ? formatSize(size) : "\(formatSize(group.totalSize)) found"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: group.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10).fill(controller.module.accent.opacity(0.5)))
                Spacer()
                if !group.isEmpty {
                    Toggle("", isOn: Binding(get: { controller.selectedCount(of: group) > 0 }, set: { _ in controller.toggle(group) }))
                        .toggleStyle(.checkbox).labelsHidden()
                }
            }
            Text(group.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            Text(value).font(.system(size: 22, weight: .light)).foregroundStyle(.white)
            Text(group.isEmpty ? "" : group.verb).font(.caption).foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: 0)
            if !group.isEmpty {
                Button("Review") { controller.reviewing = true }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(16)
        .frame(height: 210, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
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
                            }
                        }
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
    var body: some View {
        let r = controller.report ?? ActionReport()
        VStack(spacing: 18) {
            GlassIcon(module: controller.module, size: 180)
            Text(r.failed.isEmpty ? "Well done!" : "Some items were not processed")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.white)
            Text(r.freed > 0 ? "\(formatSize(r.freed)) freed · \(r.succeeded.count) items" : "\(r.succeeded.count) items done")
                .font(.title3).foregroundStyle(.white.opacity(0.8))
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
