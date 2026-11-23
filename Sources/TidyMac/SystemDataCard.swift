import SwiftUI
import TidyCore

/// "Hidden in System Data": what the grey part of the disk bar holds that can be checked or freed, one row each,
/// with the place in TidyMac (or System Settings) that deals with it.
struct SystemDataSection: View {
    @ObservedObject var app: AppState
    @State private var entries: [SystemData.Entry] = []
    @State private var measuring = true

    /// Apple's Apple Intelligence & Siri settings.
    static let appleIntelligenceSettings = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!

    /// What macOS manages on its own first, then the largest.
    private var sorted: [SystemData.Entry] {
        let fixed: [SystemData.Kind] = [.snapshots, .appleIntelligence]
        return entries.filter { fixed.contains($0.kind) }.sorted { fixed.firstIndex(of: $0.kind)! < fixed.firstIndex(of: $1.kind)! }
            + entries.filter { !fixed.contains($0.kind) }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Hidden in System Data").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                if measuring { ProgressView().controlSize(.small) }
            }
            .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { i, entry in
                    if i > 0 { Divider().padding(.leading, 68) }
                    SystemDataRow(row: row(entry))
                }
                if !sorted.isEmpty { Divider() }
                Button { app.openStorageMap(at: Paths.library) } label: {
                    HStack(spacing: 6) {
                        Text("Explore the rest of your Library in Storage Map")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.card).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            .card()
            .animation(Motion.animation(.easeOut(duration: 0.25)), value: entries)
        }
        .task {
            measuring = true
            for await measured in SystemData.measure() { entries = measured }
            measuring = false
        }
    }

    private func row(_ e: SystemData.Entry) -> SystemDataRow.Model {
        let review = String(localized: "Review")
        func size(_ text: String = String(localized: "Size needs Full Disk Access")) -> String { e.size.map { formatSize($0) } ?? text }
        switch e.kind {
        case .snapshots:
            return .init(symbol: "clock.arrow.circlepath", tint: Color(hex: 0x2FB5A5), title: String(localized: "Time Machine snapshots"),
                         detail: e.count == 0 ? String(localized: "None on this Mac right now") : String(localized: "\(e.count) snapshots"),
                         info: String(localized: "While your backup drive is away, Time Machine keeps snapshots on this disk. macOS removes them when space runs low. Removing them does not touch your backups."),
                         button: e.count == 0 ? nil : review) { app.openTool("timeMachineSnapshot") }
        case .appleIntelligence:
            return .init(symbol: NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: nil) != nil ? "apple.intelligence" : "sparkles",
                         tint: Color(hex: 0x8E6CE0), title: String(localized: "Apple Intelligence models"),
                         detail: String(localized: "Downloaded · about 7 GB, according to Apple"),
                         info: String(localized: "The models behind Apple Intelligence. macOS protects them, so no app can measure or remove them. macOS takes the space back when Apple Intelligence is turned off in System Settings."),
                         button: String(localized: "Manage")) { NSWorkspace.shared.open(Self.appleIntelligenceSettings) }
        case .caches:
            return .init(symbol: "archivebox.fill", tint: Module.cleanup.tint, title: String(localized: "Caches and logs"), detail: size(),
                         info: String(localized: "Data apps keep to load faster, and the logs they write. Apps rebuild what they need."),
                         button: review) { app.openTool("systemJunk") }
        case .developer:
            return .init(symbol: "hammer.fill", tint: Color(hex: 0x4F8EF7), title: String(localized: "Developer files"), detail: size(),
                         info: String(localized: "Xcode build data, device support files, simulators and Docker's disk."),
                         button: review) { app.openTool("developerJunk") }
        case .localModels:
            return .init(symbol: "cpu", tint: Color(hex: 0xE0729B), title: String(localized: "Downloaded AI models"), detail: size(),
                         info: String(localized: "Models downloaded with Ollama, LM Studio or Hugging Face tools."),
                         button: review) { app.openTool("aiClutter") }
        case .deviceFiles:
            return .init(symbol: "iphone", tint: Color(hex: 0x5B8DEF), title: String(localized: "iPhone and iPad files"), detail: size(),
                         info: String(localized: "Local backups of your iPhone and iPad, and the update files your Mac downloaded for them."),
                         button: review) { app.openTool("deviceFiles") }
        case .swap:
            return .init(symbol: "memorychip", tint: Module.spaceLens.tint, title: String(localized: "Swap and sleep image"), detail: size(),
                         info: String(localized: "Memory macOS moved to disk when RAM ran short, and the copy of memory it keeps for sleep. macOS manages both. Restarting gives back the swap space."),
                         button: nil) {}
        }
    }
}

/// One line of the card: badge, name with an (i) that explains it, what was found, and what to do about it.
struct SystemDataRow: View {
    struct Model {
        let symbol: String, tint: Color, title: String, detail: String, info: String
        let button: String?
        let action: () -> Void
    }

    let row: Model
    @State private var showInfo = false

    var body: some View {
        HStack(spacing: DS.Space.item) {
            IconChip(symbol: row.symbol, tint: row.tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13.5, weight: .semibold))
                    Button { showInfo = true } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help(row.info)
                        .popover(isPresented: $showInfo) { Text(row.info).fixedSize(horizontal: false, vertical: true).padding().frame(width: 300) }
                }
                Text(row.detail).font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if let button = row.button {
                Button(button, action: row.action).buttonStyle(SecondaryButtonStyle()).fixedSize()
            }
        }
        .padding(.horizontal, DS.Space.card).padding(.vertical, 12)
    }
}
