import SwiftUI
import TidyCore

/// Space Lens: intro, then a bubble map of the current folder with a size list beside it.
/// Selections are kept while moving between folders and reviewed together before removal, as in CleanMyMac.
struct SpaceLensScreen: View {
    @ObservedObject var app: AppState
    @State private var path: [URL] = []
    @State private var nodes: [SpaceNode] = []
    @State private var loading = false
    /// Selected items from every folder visited, with their sizes.
    @State private var selected: [URL: Int64] = [:]
    @State private var hovered: URL?
    @State private var message: String?
    @State private var reviewing = false
    @State private var showLog = false
    @State private var purgeable: Int64?
    @State private var purgeableInfo = false
    @State private var refresh = 0
    private let module = Module.spaceLens

    var body: some View {
        ZStack(alignment: .bottom) {
            if path.isEmpty {
                HStack(spacing: 70) {
                    GlassIcon(module: module)
                    VStack(alignment: .leading, spacing: 14) {
                        Text(module.headline).font(.system(size: 38, weight: .light)).foregroundStyle(.white)
                        Text(module.tagline).font(.system(size: 15)).foregroundStyle(.white.opacity(0.75)).frame(maxWidth: 360, alignment: .leading)
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(module.features, id: \.1) { FeatureRow(symbol: $0.0, title: $0.1, module: module) }
                        }.padding(.top, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 110)
                ScanButton(title: "Scan", module: module) { selected = [:]; message = nil; path = [Paths.home] }.padding(.bottom, 22)
            } else {
                map
            }
        }
        .task(id: "\(path.last?.path ?? "")#\(refresh)") {
            guard let dir = path.last else { return }
            loading = true; nodes = []
            purgeable = await Task.detached { SpaceLens.purgeableSpace() }.value
            for await partial in SpaceLens.childrenProgressively(of: dir) { nodes = partial }
            loading = false
        }
        .sheet(isPresented: $reviewing) {
            SpaceLensReviewSheet(items: selected.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }) { remove($0) }
        }
        .sheet(isPresented: $showLog) { RemovalLogSheet() }
    }

    var map: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button { path.removeLast() } label: { Image(systemName: "chevron.left") }.buttonStyle(PillButtonStyle())
                ForEach(Array(path.enumerated()), id: \.offset) { i, u in
                    Button(i == 0 ? "Home" : u.lastPathComponent) { path = Array(path.prefix(i + 1)) }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(i == path.count - 1 ? 1 : 0.6))
                    if i < path.count - 1 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.5)) }
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                if let purgeable, purgeable > 0 { purgeableChip(purgeable) }
                Text(formatSize(nodes.reduce(0) { $0 + $1.size })).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 20) {
                list.frame(width: 320)
                bubbles
            }
            HStack {
                Button("View Log") { showLog = true }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                if let message { Text(message).foregroundStyle(.white.opacity(0.8)) }
                Spacer()
                let size = selected.values.reduce(0, +)
                Button("Review and Remove \(selected.count) (\(formatSize(size)))") { reviewing = true }
                    .buttonStyle(PillButtonStyle()).disabled(selected.isEmpty)
                    .help("This includes items from all selected folders.")
            }
        }
        .padding(.horizontal, 30).padding(.top, 44).padding(.bottom, 20)
    }

    func purgeableChip(_ size: Int64) -> some View {
        Button { purgeableInfo = true } label: {
            Label("Purgeable Space: \(formatSize(size))", systemImage: "info.circle").font(.callout)
        }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
        .popover(isPresented: $purgeableInfo) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Purgeable space includes files your macOS marks as safe to remove when storage runs low — like caches, temporary data, and redownloadable content. Clean it in the Performance module.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Clean Purgeable Space") { purgeableInfo = false; app.module = .performance }
            }
            .padding().frame(width: 300)
        }
    }

    var list: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(nodes) { n in
                    let protection = SpaceLens.protection(of: n.url)
                    HStack {
                        if protection == .essential {
                            Image(systemName: "lock.fill").foregroundStyle(.white.opacity(0.6)).frame(width: 18)
                                .help("This is an essential system item and it cannot be deleted.")
                        } else {
                            Toggle("", isOn: Binding(get: { selected[n.url] != nil }, set: { _ in toggle(n) })).labelsHidden()
                        }
                        Image(systemName: n.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(.white.opacity(n.isHidden ? 0.5 : 0.9))
                        Text(n.name).lineLimit(1).foregroundStyle(.white.opacity(n.isHidden ? 0.6 : 1))
                        if protection == .systemFolder {
                            Text("System folder").font(.caption2).foregroundStyle(.orange.opacity(0.9))
                                .help("This folder is required for the system to operate. It’s not recommended to remove system folders.")
                        }
                        Spacer()
                        Text(formatSize(n.size)).monospacedDigit().font(.callout).foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hovered == n.url ? 0.14 : 0)))
                    .contentShape(Rectangle())
                    .onHover { if $0 { hovered = n.url } }
                    .onTapGesture(count: 2) { if n.isDirectory { path.append(n.url) } }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.18)))
    }

    var bubbles: some View {
        GeometryReader { geo in
            let shown = Array(nodes.prefix(60))
            let radius = min(geo.size.width, geo.size.height) / 2 - 6
            let packed = SpaceLens.pack(shown.map(\.size), radius: radius)
            ZStack {
                ForEach(Array(zip(shown, packed).enumerated()), id: \.offset) { _, pair in
                    let (n, b) = pair
                    let isSel = selected[n.url] != nil, isHover = hovered == n.url
                    Circle()
                        .fill(RadialGradient(colors: [module.accent.opacity(isHover ? 0.9 : 0.6), module.light.opacity(0.35)],
                                             center: .topLeading, startRadius: 0, endRadius: b.r * 2))
                        .overlay(Circle().stroke(.white.opacity(isSel ? 0.95 : 0.35), lineWidth: isSel ? 3 : 1))
                        .overlay {
                            if b.r > 34 {
                                VStack(spacing: 2) {
                                    Text(n.name).font(.system(size: min(13, b.r / 4), weight: .semibold)).lineLimit(1)
                                    Text(formatSize(n.size)).font(.system(size: min(11, b.r / 5)))
                                }
                                .foregroundStyle(.white).padding(.horizontal, 6)
                            }
                        }
                        .frame(width: b.r * 2, height: b.r * 2)
                        .position(x: geo.size.width / 2 + b.x, y: geo.size.height / 2 + b.y)
                        .onHover { if $0 { hovered = n.url } }
                        .onTapGesture(count: 2) { if n.isDirectory { path.append(n.url) } }
                        .onTapGesture { toggle(n) }
                        .help("\(n.name) — \(formatSize(n.size))")
                }
            }
            .animation(Motion.animation(.spring(duration: 0.5)), value: nodes.map(\.url))
        }
    }

    func toggle(_ n: SpaceNode) {
        guard SpaceLens.protection(of: n.url) != .essential else { return }
        selected[n.url] = selected[n.url] == nil ? n.size : nil
    }

    /// Moves the reviewed items to the Trash through the executor, which also refuses anything outside the home folder.
    func remove(_ urls: [URL]) {
        let items = urls.map { u -> ResultItem in
            var item = ResultItem(title: u.lastPathComponent, size: selected[u], url: u, action: .trash(u))
            item.category = "space-lens"
            return item
        }
        Task {
            let report = await Task.detached { await Executor.run(items) }.value
            RemovalLog.record(report)
            for item in report.succeeded { if let u = item.url { selected[u] = nil } }
            message = report.failed.isEmpty
                ? "Removal complete! \(report.succeeded.count) item\(report.succeeded.count == 1 ? "" : "s") successfully removed."
                : "Removal failed... Some files were not removed. Please make sure none of your apps are using them and try again."
            Sounds.cleanupFinished()
            refresh += 1
        }
    }
}

/// "Review files before removal": everything selected across folders, each item can still be unticked.
struct SpaceLensReviewSheet: View {
    let items: [(URL, Int64)]
    let remove: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kept: Set<URL> = []

    private var chosen: [(URL, Int64)] { items.filter { !kept.contains($0.0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review files before removal").font(.title2.weight(.semibold))
            Text("This includes items from all selected folders.").font(.callout).foregroundStyle(.secondary)
            List(items, id: \.0) { url, size in
                HStack {
                    Toggle("", isOn: Binding(get: { !kept.contains(url) }, set: { on in if on { kept.remove(url) } else { kept.insert(url) } }))
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent).lineLimit(1)
                        Text(Paths.abbreviate(url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if SpaceLens.protection(of: url) == .systemFolder {
                            Label("This folder is required for the system to operate. It’s not recommended to remove system folders.",
                                  systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Text(formatSize(size)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if chosen.contains(where: { SpaceLens.isInCloud($0.0) }) {
                Label("Some selected files are stored in cloud storage. Removing them will permanently delete them from the cloud and all your connected devices.",
                      systemImage: "icloud.fill").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Text("Items go to the Trash.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove \(formatSize(chosen.reduce(0) { $0 + $1.1 }))") { dismiss(); remove(chosen.map(\.0)) }
                    .keyboardShortcut(.defaultAction).disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
    }
}

/// Space Lens's "Removal Log".
struct RemovalLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries = RemovalLog.entries()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Removal Log").font(.title2.weight(.semibold))
            if entries.isEmpty {
                Text("Items you remove with Space Lens are listed here.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { e in
                    HStack {
                        Image(systemName: e.error == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(e.error == nil ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Paths.abbreviate(URL(fileURLWithPath: e.path))).lineLimit(1).truncationMode(.middle)
                            Text(e.error ?? e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatSize(e.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Clear Log") { RemovalLog.clear(); entries = [] }.disabled(entries.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 440)
    }
}
