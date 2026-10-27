import SwiftUI
import TidyCore

struct UninstallerSheet: View {
    let module: Module
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledApp] = []
    @State private var selected: InstalledApp?
    @State private var leftovers: [Leftover] = []
    @State private var filter = ""
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Uninstaller").font(.title2.weight(.semibold))
                TextField("Search", text: $filter).textFieldStyle(.roundedBorder).frame(width: 220)
                Spacer()
                if let message { Text(message).foregroundStyle(.secondary) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            HSplitView {
                List(apps.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) },
                     selection: Binding(get: { selected?.id }, set: { id in
                         selected = apps.first { $0.id == id }
                         leftovers = selected.map { Uninstaller.leftovers(for: $0) } ?? []
                     })) { a in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path)).resizable().frame(width: 22, height: 22)
                        Text(a.name)
                        Spacer()
                        Text(a.size > 0 ? formatSize(a.size) : "…").foregroundStyle(.secondary)
                    }.tag(a.id)
                }
                .frame(minWidth: 300, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    if let a = selected {
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path)).resizable().frame(width: 48, height: 48)
                            VStack(alignment: .leading) {
                                Text(a.name).font(.title2.bold())
                                Text(a.bundleID ?? "no bundle id").foregroundStyle(.secondary)
                            }
                        }
                        Text("Files to remove").font(.headline).padding(.top, 8)
                        List {
                            HStack { Text(Paths.abbreviate(a.url)).lineLimit(1); Spacer(); Text(formatSize(a.size)) }
                            ForEach(leftovers) { l in
                                HStack { Text(Paths.abbreviate(l.url)).lineLimit(1); Spacer(); Text(formatSize(l.size)) }
                            }
                        }
                        Button("Uninstall \(a.name)") { uninstall(a) }.buttonStyle(.borderedProminent)
                    } else {
                        Text("Select an app to see everything it leaves on your Mac.").foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 900, height: 580)
        .task {
            apps = await Task.detached { Uninstaller.installedApps() }.value
            for i in apps.indices {
                let app = apps[i]
                let s = await Task.detached { Uninstaller.size(of: app) }.value
                if i < apps.count, apps[i].id == app.id { apps[i].size = s }
            }
        }
    }

    func uninstall(_ a: InstalledApp) {
        let items = ([a.url] + leftovers.map(\.url)).map { u in
            // /Applications is root-owned for some installers; fall back to an admin delete.
            var item = ResultItem.file(u, action: FileManager.default.isDeletableFile(atPath: u.path) ? .trash(u) : .adminDelete(u))
            item.category = u == a.url ? "uninstalled" : "leftovers"
            return item
        }
        Task {
            let r = await Task.detached { await Executor.run(items) }.value
            message = r.failed.isEmpty ? "\(a.name) removed, \(formatSize(r.freed)) freed" : "\(r.failed.count) items could not be removed"
            if r.succeeded.contains(where: { $0.url == a.url }) { apps.removeAll { $0.id == a.id }; selected = nil; leftovers = [] }
        }
    }
}
