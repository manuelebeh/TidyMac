import SwiftUI
import TidyCore

/// My Tools: a searchable grid of single-purpose tools, with favorites pinned on top.
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
        .animation(.easeInOut(duration: 0.3), value: running == nil)
        .alert("Go back to My Tools?", isPresented: $confirmBack) {
            Button("Cancel", role: .cancel) {}
            Button("OK") { running?.stop(); running = nil }
        } message: { Text("Your scan results and selections won’t be saved.") }
        .sheet(isPresented: $showUninstaller) { UninstallerSheet(module: .applications) }
    }

    var grid: some View {
        let shown = Toolbox.tools.filter { $0.matches(query) }
        let pinned = shown.filter { favorites.contains($0.id) }, others = shown.filter { !favorites.contains($0.id) }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("My Tools").font(.system(size: 34, weight: .light)).foregroundStyle(.white)
                    Text(Module.myTools.tagline).font(.system(size: 15)).foregroundStyle(.white.opacity(0.75)).frame(maxWidth: 440, alignment: .leading)
                }
                Spacer()
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                    TextField("Search...", text: $query).textFieldStyle(.plain).foregroundStyle(.white)
                }
                .padding(.horizontal, 12).padding(.vertical, 8).frame(width: 260)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.1)))
            }
            .padding(.top, 40)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if shown.isEmpty {
                        Text("No tools match your search.\nTry a different keyword.")
                            .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity).padding(.top, 80)
                    } else if !query.isEmpty {
                        section("\(shown.count) results found", shown)
                    } else {
                        if !pinned.isEmpty { section("Favorites", pinned) }
                        section(pinned.isEmpty ? "" : "Other Tools", others)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder func section(_ title: String, _ tools: [Tool]) -> some View {
        if !title.isEmpty { Text(title).font(.headline).foregroundStyle(.white.opacity(0.85)).padding(.top, 6) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 16) {
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
        ZStack(alignment: .bottomLeading) {
            ModuleBackground(module: controller.module)
            // Back at the intro means the tool is closing: skip the module's own intro screen.
            if controller.phase != .intro { ModuleScreen(controller: controller) }
            Button(action: back) { Label("My Tools", systemImage: "chevron.left") }
                .buttonStyle(PillButtonStyle()).padding(.leading, 30).padding(.bottom, 52)
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
        if Calendar.current.isDateInToday(d) { return "Last Scan: Today" }
        return "Last Scan: " + RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }

    var buttonTitle: String {
        switch tool.kind {
        case .scan: "Scan"
        case .uninstaller, .screenCleaning: "Open"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(
                        LinearGradient(colors: [module.accent, module.light], startPoint: .top, endPoint: .bottom)))
                Spacer()
                if hover || favorite {
                    Button(action: toggleFavorite) {
                        Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? .yellow : .white.opacity(0.7))
                    }
                    .buttonStyle(.plain).help(favorite ? "Saved" : "Save")
                }
            }
            Text(tool.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).padding(.top, 6)
            Text(tool.description).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true).lineLimit(3)
            Spacer(minLength: 0)
            HStack {
                if let lastScan { Text(lastScan).font(.caption).foregroundStyle(.white.opacity(0.55)) }
                Spacer()
                Button(buttonTitle, action: open).buttonStyle(PillButtonStyle())
            }
        }
        .padding(16)
        .frame(height: 200, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(hover ? 0.12 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        .onHover { hover = $0 }
    }
}
