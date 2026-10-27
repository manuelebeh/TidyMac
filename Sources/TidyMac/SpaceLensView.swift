import SwiftUI
import TidyCore

/// Space Lens: intro, then a bubble map of the current folder with a size list beside it.
struct SpaceLensScreen: View {
    @State private var path: [URL] = []
    @State private var nodes: [SpaceNode] = []
    @State private var loading = false
    @State private var selected: Set<URL> = []
    @State private var hovered: URL?
    @State private var message: String?
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
                ScanButton(title: "Scan", module: module) { path = [Paths.home] }.padding(.bottom, 22)
            } else {
                map
            }
        }
        .task(id: path) {
            guard let dir = path.last else { return }
            loading = true; selected = []; nodes = []
            for await partial in SpaceLens.childrenProgressively(of: dir) { nodes = partial }
            loading = false
        }
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
                Text(formatSize(nodes.reduce(0) { $0 + $1.size })).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 20) {
                list.frame(width: 320)
                bubbles
            }
            HStack {
                if let message { Text(message).foregroundStyle(.white.opacity(0.8)) }
                Spacer()
                let size = nodes.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size }
                Button("Move \(selected.count) to Trash (\(formatSize(size)))") { trashSelected() }
                    .buttonStyle(PillButtonStyle()).disabled(selected.isEmpty)
            }
        }
        .padding(.horizontal, 30).padding(.top, 44).padding(.bottom, 20)
    }

    var list: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(nodes) { n in
                    HStack {
                        Toggle("", isOn: Binding(get: { selected.contains(n.url) }, set: { _ in toggle(n.url) })).labelsHidden()
                        Image(systemName: n.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(.white.opacity(n.isHidden ? 0.5 : 0.9))
                        Text(n.name).lineLimit(1).foregroundStyle(.white.opacity(n.isHidden ? 0.6 : 1))
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
                    let isSel = selected.contains(n.url), isHover = hovered == n.url
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
                        .onTapGesture { toggle(n.url) }
                        .help("\(n.name) — \(formatSize(n.size))")
                }
            }
            .animation(.spring(duration: 0.5), value: nodes.map(\.url))
        }
    }

    func toggle(_ u: URL) {
        if selected.contains(u) { selected.remove(u) } else { selected.insert(u) }
    }

    func trashSelected() {
        var failed = 0
        var report = ActionReport()
        for u in selected {
            do {
                try FileManager.default.trashItem(at: u, resultingItemURL: nil)
                var item = ResultItem(title: u.lastPathComponent, size: nodes.first { $0.url == u }?.size, url: u, action: .trash(u))
                item.category = "space-lens"
                report.succeeded.append(item)
            } catch { failed += 1 }
        }
        History.record(report)
        message = failed == 0 ? "Moved \(selected.count) items to Trash" : "\(failed) items could not be moved"
        let dir = path; path = []; path = dir
    }
}
