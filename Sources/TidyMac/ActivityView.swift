import SwiftUI
import TidyCore

/// History: what TidyMac has done for the Mac so far. Mac Health and recommendations live on the Overview.
/// A scrolling page of cards in two rows: storage and time, security and recent runs.
struct ActivityScreen: View {
    @ObservedObject var app: AppState
    @State private var summary = ActivitySummary()
    @State private var recent: [History.Entry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: String(localized: "History"),
                         subtitle: summary.since.map { String(localized: "From \($0.formatted(date: .abbreviated, time: .omitted))") }) { EmptyView() }
                .headerPadding()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.section) {
                    row { storageCard; timeCard }
                    row { malwareCard; recentCard }
                }
                .pagePadding()
            }
        }
        .task { reload() }
    }

    /// Two cards side by side, the same height.
    private func row<A: View>(@ViewBuilder _ content: () -> A) -> some View {
        HStack(alignment: .top, spacing: DS.Space.section) { content() }.fixedSize(horizontal: false, vertical: true)
    }

    private func reload() {
        summary = ActivitySummary()
        recent = Array(History.entries.suffix(6).reversed())
    }

    // MARK: Row 1: storage and time

    private static func color(_ part: ActivityCategory.Storage) -> Color {
        switch part {
        case .systemJunk: Module.cleanup.tint
        case .applications: Module.applications.tint
        case .personalFiles: Module.clutter.tint
        }
    }

    private var storageCard: some View {
        HistoryCard(title: String(localized: "Local Storage Cleaned"), symbol: "internaldrive.fill",
                    info: String(localized: "Everything you remove on this Mac with TidyMac adds up here. From junk files and clutter to uninstalled apps - the total local storage cleanup is shown in MB or GB.")) {
            if summary.freed == 0 {
                CardEmpty(message: String(localized: "Clean up storage and watch your free gigabytes add up."),
                          action: String(localized: "Go to Full Scan")) { app.module = .smartCare }
            } else {
                VStack(alignment: .leading, spacing: DS.Space.item) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formatSize(summary.freed)).font(.system(size: 30, weight: .semibold)).monospacedDigit()
                        Delta(text: String(localized: "+\(formatSize(summary.freedThisMonth)) this month"))
                    }
                    let total = max(Double(summary.freed), 1)
                    UsageBar(segments: summary.freedBy.filter { $0.1 > 0 }.map { .init(fraction: Double($0.1) / total, color: Self.color($0.0)) }, height: 8)
                    VStack(spacing: 8) {
                        ForEach(summary.freedBy, id: \.0) { part, bytes in
                            HStack(spacing: 8) {
                                Circle().fill(Self.color(part)).frame(width: 8, height: 8)
                                Text(part.title).font(.system(size: 12.5))
                                Spacer()
                                Text(formatSize(bytes)).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }


    private var timeCard: some View {
        HistoryCard(title: String(localized: "Total Time Saved"), symbol: "stopwatch.fill",
                    info: String(localized: "TidyMac estimates the time you’ve saved by skipping manual Mac maintenance: figuring out what to remove, where to find it, and removing it. Each cleanup, including Full Scan, adds to your total here.")) {
            if summary.minutesSaved == 0 {
                CardEmpty(message: String(localized: "Start using TidyMac to see your recent time saved."),
                          action: String(localized: "Go to Full Scan")) { app.module = .smartCare }
            } else {
                VStack(alignment: .leading, spacing: DS.Space.item) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ActivitySummary.format(minutes: summary.minutesSaved)).font(.system(size: 30, weight: .semibold))
                        Delta(text: String(localized: "+\(ActivitySummary.format(minutes: summary.minutesThisMonth)) this month"))
                    }
                    Text(summary.timeSavedHint).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved by Activity").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(summary.savedBy.prefix(3), id: \.0) { c, m in
                            HStack {
                                Text(c.title).font(.system(size: 12.5)).lineLimit(1)
                                Spacer()
                                Text(ActivitySummary.format(minutes: m)).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Row 2: security and recent runs

    private var malwareCard: some View {
        HistoryCard(title: String(localized: "Scanned for Malware"), symbol: "hand.raised.fill",
                    info: String(localized: "TidyMac counts how many background items were checked and how many looked suspicious - whether through Full Scan, Protection or the Malware Finder tool.")) {
            if summary.malwareScans == 0 {
                CardEmpty(message: String(localized: "No scans yet. It’s time to protect your Mac."),
                          action: String(localized: "Go to Protection")) { app.module = .protection }
            } else {
                VStack(alignment: .leading, spacing: DS.Space.item) {
                    Text("\(summary.itemsScanned) items").font(.system(size: 30, weight: .semibold))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Malware History").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                        factRow("magnifyingglass", String(localized: "\(summary.malwareScans) scans run"))
                        factRow(summary.threatsFound == 0 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                                summary.threatsFound == 0 ? String(localized: "No threats found") : String(localized: "\(summary.threatsFound) suspicious items found"),
                                tint: summary.threatsFound == 0 ? DS.safe : DS.caution)
                        if let d = summary.lastMalwareScan {
                            factRow("clock", String(localized: "Last scan \(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()))"))
                        }
                    }
                }
            }
        }
    }

    private func factRow(_ symbol: String, _ text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint).frame(width: 16)
            Text(text).font(.system(size: 12.5))
        }
    }

    private var recentCard: some View {
        HistoryCard(title: String(localized: "Recent Saves"), symbol: "clock.arrow.circlepath",
                    info: String(localized: "Your latest runs, with the time each one saved.")) {
            if recent.isEmpty {
                CardEmpty(message: String(localized: "Your recent saves will show up here."),
                          action: String(localized: "Go to Toolkit")) { app.module = .myTools }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { i, e in
                        entryRow(e)
                        if i < recent.count - 1 { Divider().padding(.vertical, 13) }
                    }
                }
            }
        }
    }

    private func entryRow(_ e: History.Entry) -> some View {
        let scan = e.scanned != nil
        let parts = (e.categories ?? [:]).compactMap { k, v in ActivityCategory(rawValue: k).map { ($0, v.bytes) } }.sorted { $0.1 > $1.1 }
        let title: String = scan ? ActivityCategory.malwares.title
            : parts.first.map { parts.count > 1 ? "\($0.0.title) +\(parts.count - 1)" : $0.0.title } ?? String(localized: "\(e.items) items done")
        let result: String = scan
            ? ((e.threats ?? 0) == 0 ? String(localized: "No threats found") : String(localized: "\(e.threats ?? 0) suspicious items found"))
            : e.freed > 0 ? formatSize(e.freed) : String(localized: "\(e.items) items done")
        return HStack(spacing: 12) {
            IconChip(symbol: scan ? "hand.raised.fill" : "sparkles", tint: scan ? Module.protection.tint : Module.cleanup.tint, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(result).font(.system(size: 12.5, weight: .medium)).monospacedDigit().lineLimit(1)
                if !scan, e.minutesSaved > 0 {
                    Text(ActivitySummary.format(minutes: e.minutesSaved)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One History card: a small icon and title on top (with an optional info popover), then its content.
struct HistoryCard<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = DS.glyph
    var info: String? = nil
    var trailing: AnyView = AnyView(EmptyView())
    @ViewBuilder var content: Content
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.section) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                trailing
                if let info {
                    Button { showInfo = true } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help(info)
                        .popover(isPresented: $showInfo) { Text(info).padding().frame(width: 280) }
                }
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(DS.Space.card)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .card()
    }
}

/// What a card shows before there is anything to count: a sentence, and a way to start.
struct CardEmpty: View {
    var symbol: String? = nil
    var tint: Color = DS.glyph
    var title: String? = nil
    let message: String
    var action: String? = nil
    var run: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            if let symbol { IconChip(symbol: symbol, tint: tint, size: 40) }
            if let title { Text(title).font(.system(size: 14, weight: .semibold)) }
            Text(message).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action { Button(action, action: run).buttonStyle(SecondaryButtonStyle()).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
    }
}

struct Delta: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "arrow.up.right").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.safe)
            .help("Monthly change")
    }
}
