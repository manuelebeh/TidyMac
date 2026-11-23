import SwiftUI
import TidyCore

/// Toolkit: every tool in one searchable place, grouped by the area it belongs to, with favorites pinned on top.
/// A tool runs inside its module, so the sidebar shows where it lives and its results stay there.
struct MyToolsScreen: View {
    @ObservedObject var app: AppState
    @AppStorage("TidyMac.favoriteTools") private var favoritesRaw = ""
    @State private var query = ""

    var favorites: Set<String> { Set(favoritesRaw.split(separator: ",").map(String.init)) }

    /// The areas in sidebar order; Screen Cleaning belongs to none of them.
    private static let areas: [Module] = [.cleanup, .clutter, .applications, .protection, .performance, .smartCare]

    private func title(_ area: Module) -> String { area == .smartCare ? String(localized: "More Tools") : area.name }

    var body: some View {
        let shown = Toolbox.tools.filter { $0.matches(query) }
        let pinned = shown.filter { favorites.contains($0.id) }
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
                        ForEach(Self.areas) { area in
                            let tools = shown.filter { $0.module == area.rawValue && !favorites.contains($0.id) }
                            if !tools.isEmpty { section(title(area), tools) }
                        }
                    }
                }
                .pagePadding()
            }
        }
    }

    @ViewBuilder func section(_ title: String, _ tools: [Tool]) -> some View {
        Text(title).font(.headline).foregroundStyle(.primary.opacity(0.85)).padding(.top, 4)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: DS.Space.section)], spacing: DS.Space.section) {
            ForEach(tools) { t in
                ToolCard(tool: t, favorite: favorites.contains(t.id), toggleFavorite: { toggleFavorite(t) }) { app.openTool(t.id) }
            }
        }
    }

    func toggleFavorite(_ t: Tool) {
        var f = favorites
        if f.contains(t.id) { f.remove(t.id) } else { f.insert(t.id) }
        favoritesRaw = f.sorted().joined(separator: ",")
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
                // Always there, so favorites can be found; faint until the card is hovered.
                Button(action: toggleFavorite) {
                    Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? Color.primary : Color.secondary)
                        .opacity(favorite || hover ? 1 : 0.35)
                }
                .buttonStyle(.plain).help(favorite ? String(localized: "Saved") : String(localized: "Save"))
            }
            // The title wraps rather than truncates (long translations); the description gives up the room it needs.
            Text(tool.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).padding(.top, 6)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(tool.description).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(4)
            Spacer(minLength: 0)
            HStack {
                if let lastScan { Text(lastScan).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(buttonTitle, action: open).buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(DS.Space.card)
        .frame(height: 240, alignment: .topLeading)
        .card(hovering: hover)
        .onHover { hover = $0 }
    }
}
