import SwiftUI
import TidyCore

/// The Uninstaller's list filters (CleanMyMac's `uninstaller_filter_*`).
enum UninstallerFilter: Hashable {
    case all, unused, store(InstalledApp.Store), vendor(Vendor), audioPlugins

    var title: String {
        switch self {
        case .all: "All Applications"
        case .unused: "Unused"
        case .store(let s): s.rawValue
        case .vendor(let v): v.rawValue
        case .audioPlugins: "Audio Plugins"
        }
    }

    func includes(_ a: InstalledApp) -> Bool {
        switch self {
        case .audioPlugins: return a.kind == .audioPlugin
        case _ where a.kind == .audioPlugin: return false
        case .all: return true
        case .unused: return a.isUnused()
        case .store(let s): return a.store == s
        case .vendor(let v): return a.vendor == v
        }
    }
}

enum UninstallerSort: String, CaseIterable { case name = "Name", size = "Size", lastOpened = "Last Opened" }

struct UninstallerSheet: View {
    let module: Module
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledApp] = []
    @State private var selected: InstalledApp?
    @State private var leftovers: [Leftover] = []
    /// Leftovers the user unticked; everything else found is removed with the app.
    @State private var kept: Set<URL> = []
    @State private var loadingLeftovers = false
    @State private var search = ""
    @State private var filter: UninstallerFilter = .all
    @State private var sort: UninstallerSort = .name
    @State private var message: String?
    /// The app waiting to be uninstalled and the running apps to quit first.
    @State private var pending: (app: InstalledApp, running: [NSRunningApplication])?

    private var shown: [InstalledApp] {
        let list = apps.filter { filter.includes($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
        switch sort {
        case .name: return list
        case .size: return list.sorted { $0.size > $1.size }
        case .lastOpened: return list.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    private var filters: [[UninstallerFilter]] {
        [[.all, .unused],
         InstalledApp.Store.allCases.map { .store($0) },
         Vendor.allCases.map { .vendor($0) },
         [.audioPlugins]]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Uninstaller").font(.title2.weight(.semibold))
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                Picker("Show", selection: $filter) {
                    ForEach(filters, id: \.self) { section in
                        ForEach(section, id: \.self) { f in Text("\(f.title) (\(apps.filter(f.includes).count))").tag(f) }
                        Divider()
                    }
                }
                .fixedSize()
                Picker("Sort by", selection: $sort) {
                    ForEach(UninstallerSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Spacer()
                if let message { Text(message).foregroundStyle(.secondary).lineLimit(1) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            HSplitView {
                List(shown, selection: Binding(get: { selected?.id }, set: { id in select(apps.first { $0.id == id }) })) { a in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path)).resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name)
                            if let caption = caption(a) { Text(caption).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(a.size > 0 ? formatSize(a.size) : "…").foregroundStyle(.secondary)
                    }.tag(a.id)
                }
                .overlay { if shown.isEmpty && !apps.isEmpty { Text(emptyText).foregroundStyle(.secondary).padding() } }
                .frame(minWidth: 320, maxHeight: .infinity)
                detail
                    .padding()
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 960, height: 600)
        .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let p = pending {
                QuitAppsSheet(apps: p.running, onContinue: { pending = nil; remove(p.app) }, onCancel: { pending = nil })
            }
        }
        .task {
            apps = await Task.detached { Uninstaller.installedApps() }.value
            for i in apps.indices {
                let app = apps[i]
                let s = await Task.detached { Uninstaller.size(of: app) }.value
                if i < apps.count, apps[i].id == app.id { apps[i].size = s }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let a = selected {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(a.name).font(.title2.bold())
                        Text([a.bundleID ?? "no bundle id", a.store == .other ? nil : a.store.rawValue].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Files to remove").font(.headline)
                    if loadingLeftovers { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(formatSize(a.size + leftovers.filter { !kept.contains($0.url) }.reduce(0) { $0 + $1.size })).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                List {
                    Section(a.kind == .audioPlugin ? "Plugins" : "Applications") {
                        fileRow(a.url, size: a.size, toggle: nil)
                    }
                    ForEach(Leftover.Kind.allCases, id: \.self) { kind in
                        let files = leftovers.filter { $0.kind == kind }
                        if !files.isEmpty {
                            Section(kind.rawValue) {
                                ForEach(files) { l in
                                    fileRow(l.url, size: l.size, toggle: Binding(get: { !kept.contains(l.url) },
                                                                                 set: { if $0 { kept.remove(l.url) } else { kept.insert(l.url) } }))
                                }
                            }
                        }
                    }
                }
                Button("Uninstall \(a.name)") { uninstall(a) }.buttonStyle(.borderedProminent).disabled(loadingLeftovers)
            }
        } else {
            Text("Select an app to see everything it leaves on your Mac.").foregroundStyle(.secondary)
        }
    }

    private func fileRow(_ url: URL, size: Int64, toggle: Binding<Bool>?) -> some View {
        HStack {
            if let toggle { Toggle("", isOn: toggle).labelsHidden() } else { Toggle("", isOn: .constant(true)).labelsHidden().disabled(true) }
            Text(Paths.abbreviate(url)).lineLimit(1).truncationMode(.middle)
            Spacer()
            if size > 0 { Text(formatSize(size)).monospacedDigit().foregroundStyle(.secondary) }
        }
        .contextMenu { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    }

    private var emptyText: String {
        switch filter {
        case .unused: "There are no applications you haven’t used in over six months."
        case .audioPlugins: "Third party audio plugins will appear here."
        default: "No applications match."
        }
    }

    private func caption(_ a: InstalledApp) -> String? {
        guard let d = a.lastUsed else { return a.kind == .audioPlugin ? "Audio plugin" : nil }
        return "Opened " + RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }

    /// Leftover search reads many folders and sizes them, so it runs off the main thread.
    private func select(_ a: InstalledApp?) {
        selected = a; leftovers = []; kept = []
        guard let a else { return }
        loadingLeftovers = true
        Task {
            let found = await Task.detached { Uninstaller.leftovers(for: a) }.value
            guard selected?.id == a.id else { return }
            leftovers = found; loadingLeftovers = false
        }
    }

    /// Asks to quit the app (and anything holding its files) first, as CleanMyMac's Uninstaller does.
    func uninstall(_ a: InstalledApp) {
        let apps = RunningApps.related(to: [a.url] + leftovers.map(\.url))
        if apps.isEmpty { remove(a) } else { pending = (a, apps) }
    }

    func remove(_ a: InstalledApp) {
        var bundle = ResultItem.file(a.url, size: a.size, action: Uninstaller.removalAction(for: a))
        bundle.category = "uninstalled"
        let files = leftovers.filter { !kept.contains($0.url) }.map { l -> ResultItem in
            var item = ResultItem.file(l.url, size: l.size, action: l.action)
            item.category = "leftovers"
            return item
        }
        Task {
            let r = await Task.detached { await Executor.run([bundle] + files) }.value
            message = r.failed.isEmpty ? "\(a.name) removed, \(formatSize(r.freed)) freed" : "\(r.failed.count) items could not be removed"
            if r.succeeded.contains(where: { $0.url == a.url }) { apps.removeAll { $0.id == a.id }; select(nil) }
        }
    }
}
