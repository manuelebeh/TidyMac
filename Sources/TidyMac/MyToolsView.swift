import SwiftUI
import TidyCore

/// Toolkit: a searchable grid of single-purpose tools, with favorites pinned on top.
struct MyToolsScreen: View {
    @ObservedObject var screenCleaning: ScreenCleaningSession
    @AppStorage("TidyMac.favoriteTools") private var favoritesRaw = ""
    @State private var query = ""
    @State private var running: ModuleController?
    @State private var confirmBack = false
    @State private var showUninstaller = false

    var favorites: Set<String> { Set(favoritesRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        ZStack {
            if let running {
                ToolRunView(controller: running, back: back) { self.running = nil }.transition(.opacity)
            } else {
                grid.transition(.opacity)
            }
        }
        .animation(Motion.animation(.easeInOut(duration: 0.3)), value: running == nil)
        .alert("Go back to Toolkit?", isPresented: $confirmBack) {
            Button("Cancel", role: .cancel) {}
            Button("OK") { running?.stop(); running = nil }
        } message: { Text("Your scan results and selections won’t be saved.") }
        .sheet(isPresented: $showUninstaller) { UninstallerSheet(module: .applications) }
    }

    var grid: some View {
        let shown = Toolbox.tools.filter { $0.matches(query) }
        let pinned = shown.filter { favorites.contains($0.id) }, others = shown.filter { !favorites.contains($0.id) }
        return VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: String(localized: "Toolkit"), subtitle: Module.myTools.tagline) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search...", text: $query).textFieldStyle(.plain).foregroundStyle(.primary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8).frame(width: 260)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.selection))
            }
            .headerPadding()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.section) {
                    if shown.isEmpty {
                        Text("No tools match your search.\nTry a different keyword.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 80)
                    } else if !query.isEmpty {
                        section(String(localized: "\(shown.count) results found"), shown)
                    } else {
                        if !pinned.isEmpty { section(String(localized: "Favorites"), pinned) }
                        section(pinned.isEmpty ? "" : String(localized: "Other Tools"), others)
                    }
                }
                .pagePadding()
            }
        }
    }

    @ViewBuilder func section(_ title: String, _ tools: [Tool]) -> some View {
        if !title.isEmpty { Text(title).font(.headline).foregroundStyle(.primary.opacity(0.85))}
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: DS.Space.section)], spacing: DS.Space.section) {
            ForEach(tools) { t in
                ToolCard(tool: t, favorite: favorites.contains(t.id), toggleFavorite: { toggleFavorite(t) }) { open(t) }
            }
        }
    }

    func toggleFavorite(_ t: Tool) {
        var f = favorites
        if f.contains(t.id) { f.remove(t.id) } else { f.insert(t.id) }
        favoritesRaw = f.sorted().joined(separator: ",")
    }

    func open(_ t: Tool) {
        ToolHistory.markScanned(t.id)
        switch t.kind {
        case .screenCleaning: screenCleaning.start()
        case .uninstaller: showUninstaller = true
        case .scan:
            let c = ModuleController(tool: t)
            running = c
            c.scan()
        }
    }

    func back() {
        guard let running else { return }
        if running.phase == .results && !running.groups.allSatisfy(\.isEmpty) { confirmBack = true } else { running.stop(); self.running = nil }
    }
}

/// One tool's scan, shown with the regular module screens; returning to the intro closes it.
struct ToolRunView: View {
    @ObservedObject var controller: ModuleController
    let back: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) { Label("Toolkit", systemImage: "chevron.left") }
                .buttonStyle(SecondaryButtonStyle()).padding(.leading, DS.Space.page).padding(.top, DS.Space.headerTop)
            // Back at the intro means the tool is closing: skip the module's own intro screen.
            if controller.phase != .intro { ModuleScreen(controller: controller) }
            Spacer(minLength: 0)
        }
        .onChange(of: controller.phase) { if $0 == .intro { close() } }
    }
}

enum ToolHistory {
    static let key = "TidyMac.toolScans"
    static func markScanned(_ id: String) {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: Date] ?? [:]
        d[id] = Date()
        UserDefaults.standard.set(d, forKey: key)
    }
    static func lastScan(_ id: String) -> Date? { (UserDefaults.standard.dictionary(forKey: key) as? [String: Date])?[id] }
}

struct ToolCard: View {
    let tool: Tool
    let favorite: Bool
    let toggleFavorite: () -> Void
    let open: () -> Void
    @State private var hover = false

    var module: Module { Module(rawValue: tool.module) ?? .myTools }

    var lastScan: String? {
        guard let d = ToolHistory.lastScan(tool.id) else { return nil }
        if Calendar.current.isDateInToday(d) { return String(localized: "Last Scan: Today") }
        return String(localized: "Last Scan: \(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()))")
    }

    var buttonTitle: String {
        switch tool.kind {
        case .scan: String(localized: "Scan")
        case .uninstaller, .screenCleaning: String(localized: "Open")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                IconChip(symbol: tool.symbol, tint: module.tint, size: 38)
                Spacer()
                if hover || favorite {
                    Button(action: toggleFavorite) {
                        Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain).help(favorite ? String(localized: "Saved") : String(localized: "Save"))
                }
            }
            Text(tool.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).padding(.top, 6)
            Text(tool.description).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).lineLimit(3)
            Spacer(minLength: 0)
            HStack {
                if let lastScan { Text(lastScan).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(buttonTitle, action: open).buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(DS.Space.card)
        .frame(height: 200, alignment: .topLeading)
        .card(hovering: hover)
        .onHover { hover = $0 }
    }
}
