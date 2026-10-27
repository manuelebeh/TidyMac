import SwiftUI
import TidyCore

/// My Activity: Mac Health with today's recommendations on the left, and what TidyMac has done
/// so far in four cards on the right (StatisticsDashboard in CleanMyMac, see REVERSE.md).
struct ActivityScreen: View {
    @ObservedObject var app: AppState
    @State private var summary = ActivitySummary()
    @State private var health: MacHealth?
    @State private var machine = "Mac"
    @State private var showAll = false
    private let module = Module.activity

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("My Activity").font(.system(size: 34, weight: .light)).foregroundStyle(.white)
                if let since = summary.since {
                    Text("From \(since.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.white.opacity(0.6))
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HealthCard(health: health, machine: machine)
                    recommendations
                }
                .frame(width: 300)
                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow { storageCard; timeCard }
                    GridRow { malwareCard; recentCard }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40).padding(.top, 40)
        .task {
            summary = ActivitySummary()
            let due = ScreenCleaningSession.reminderDue
            let fda = Permissions.hasFullDiskAccess
            let (h, m) = await Task.detached {
                (MacHealth.current(hasFullDiskAccess: fda, screenCleaningDue: due), SystemMonitor.machineName())
            }.value
            health = h; machine = m
        }
        .sheet(isPresented: $showAll) { RecommendationsSheet(health: health, go: { showAll = false; go($0) }) }
    }

    // MARK: Recommendations

    @ViewBuilder var recommendations: some View {
        let recs = health?.recommendations ?? []
        HStack {
            Text(recs.isEmpty ? "Today's Recommendation" : "\(recs.count) Recommendations")
                .font(.callout).foregroundStyle(.white.opacity(0.7))
            Spacer()
            if recs.count > 1 { Button("View All") { showAll = true }.buttonStyle(.plain).font(.callout.weight(.semibold)).foregroundStyle(.white) }
        }
        if let r = recs.first {
            ZStack(alignment: .bottom) {
                // The cards behind hint that more recommendations are waiting.
                if recs.count > 2 { card.padding(.horizontal, 24).offset(y: 16).opacity(0.4) }
                if recs.count > 1 { card.padding(.horizontal, 12).offset(y: 8).opacity(0.6) }
                RecommendationRow(rec: r) { go(r.target) }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x2B2541)))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
            }
        } else if health != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("You’re all good!").font(.headline).foregroundStyle(.white)
                Text("There are no recommendations for today.").font(.callout).foregroundStyle(.white.opacity(0.7))
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.08)))
        }
    }

    var card: some View { RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x2B2541)).frame(height: 90) }

    // MARK: Cards

    var storageCard: some View {
        StatCard(info: "Everything you remove on this Mac with TidyMac adds up here. From junk files and clutter to uninstalled apps — the total local storage cleanup is shown in MB or GB.",
                 symbol: "internaldrive.fill", empty: summary.freed == 0 ? ("Clean up storage and watch your free gigabytes add up.", "Go to Smart Care", .smartCare) : nil,
                 go: go) {
            Text("Local Storage Cleaned").font(.callout).foregroundStyle(.white.opacity(0.7))
            Text(formatSize(summary.freed)).font(.system(size: 30, weight: .light)).foregroundStyle(.white)
            Delta(text: "+\(formatSize(summary.freedThisMonth)) this month")
            let total = max(summary.freedBy.map(\.1).max() ?? 1, 1)
            ForEach(summary.freedBy, id: \.0) { part, bytes in
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(part.rawValue); Spacer(); Text(formatSize(bytes)).monospacedDigit() }
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                    Bar(fraction: Double(bytes) / Double(total), color: Module.cleanup.accent)
                }
            }
        }
    }

    var timeCard: some View {
        StatCard(info: "TidyMac estimates the time you’ve saved by skipping manual Mac maintenance: figuring out what to remove, where to find it, and removing it. Each cleanup, including Smart Care, adds to your total here.",
                 symbol: "stopwatch.fill", empty: summary.minutesSaved == 0 ? ("Start using TidyMac to see your recent time saved.", "Go to Smart Care", .smartCare) : nil,
                 go: go) {
            Text("Total Time Saved").font(.callout).foregroundStyle(.white.opacity(0.7))
            Text(ActivitySummary.format(minutes: summary.minutesSaved)).font(.system(size: 30, weight: .light)).foregroundStyle(.white)
            Delta(text: "+\(ActivitySummary.format(minutes: summary.minutesThisMonth)) this month")
            Text(summary.timeSavedHint).font(.caption).foregroundStyle(.white.opacity(0.6))
            Text("Saved by Activity").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7)).padding(.top, 4)
            ForEach(summary.savedBy.prefix(3), id: \.0) { c, m in
                HStack { Text(c.title); Spacer(); Text(ActivitySummary.format(minutes: m)).monospacedDigit() }
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    var malwareCard: some View {
        StatCard(info: "TidyMac counts how many background items were checked and how many looked suspicious — whether through Smart Care, Protection or the Malware Finder tool.",
                 symbol: "hand.raised.fill", empty: summary.malwareScans == 0 ? ("No scans yet. It’s time to protect your Mac.", "Go to Protection", .protection) : nil,
                 go: go) {
            Text("Scanned for Malware").font(.callout).foregroundStyle(.white.opacity(0.7))
            Text("\(summary.itemsScanned) items").font(.system(size: 30, weight: .light)).foregroundStyle(.white)
            Text("Malware History").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7)).padding(.top, 4)
            Group {
                Text("\(summary.malwareScans) scan\(summary.malwareScans == 1 ? "" : "s") run")
                Text(summary.threatsFound == 0 ? "No threats found" : "\(summary.threatsFound) suspicious items found")
                if let d = summary.lastMalwareScan { Text("Last scan \(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()))") }
            }
            .font(.caption).foregroundStyle(.white.opacity(0.8))
        }
    }

    var recentCard: some View {
        StatCard(info: "Your latest runs, with the time each one saved.",
                 symbol: "clock.arrow.circlepath", empty: summary.recentSaves.isEmpty ? ("Your recent saves will show up here.", "Go to My Tools", .myTools) : nil,
                 go: go) {
            Text("Recent Saves").font(.callout).foregroundStyle(.white.opacity(0.7))
            ForEach(Array(summary.recentSaves.enumerated()), id: \.offset) { _, save in
                HStack {
                    Text(save.0.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    Text(ActivitySummary.format(minutes: save.1)).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    func go(_ target: MacHealth.Recommendation.Target) {
        switch target {
        case .fullDiskAccess: NSWorkspace.shared.open(Permissions.fullDiskAccessSettings)
        case .screenCleaning: app.screenCleaning.start()
        case .smartCare: app.module = .smartCare
        case .cleanup: app.module = .cleanup
        case .protection: app.module = .protection
        case .performance: app.module = .performance
        case .applications: app.module = .applications
        case .clutter: app.module = .clutter
        }
    }

    func go(_ module: Module) { app.module = module }
}

struct HealthCard: View {
    let health: MacHealth?
    let machine: String
    @State private var info = false

    var stateColor: Color {
        switch health?.state {
        case .excellent, .good: Color(hex: 0x7EE8C8)
        case .normal: .yellow
        case .requiresAttention: .orange
        case .critical: .red
        case nil: .white
        }
    }

    var body: some View {
        let s = SystemMonitor.storage()
        VStack(alignment: .leading, spacing: 4) {
            Text("Mac Health:").font(.callout).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 6) {
                Text(health?.state.rawValue ?? "…").font(.system(size: 24, weight: .medium)).foregroundStyle(stateColor)
                if let health {
                    Button { info = true } label: { Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.6)) }
                        .buttonStyle(.plain)
                        .popover(isPresented: $info) { Text(health.description).padding().frame(width: 260) }
                }
            }
            Text(machine).font(.caption).foregroundStyle(.white.opacity(0.6))
            Spacer()
            HStack {
                Text(s.name).font(.callout.weight(.semibold))
                Spacer()
                Text("\(formatSize(s.total - s.available)) of \(formatSize(s.total)) used").font(.caption)
            }
            .foregroundStyle(.white)
            Bar(fraction: s.total > 0 ? Double(s.total - s.available) / Double(s.total) : 0, color: .white)
        }
        .padding(18)
        .frame(height: 230)
        .background(alignment: .topTrailing) {
            // The glowing ring around the Mac, as on CleanMyMac's health card.
            ZStack {
                Circle().stroke(LinearGradient(colors: [stateColor, stateColor.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 6)
                    .blur(radius: 2).shadow(color: stateColor, radius: 12)
                Image(systemName: "laptopcomputer").font(.system(size: 56)).foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 210, height: 210).offset(x: 80, y: -50)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
    }
}

struct RecommendationRow: View {
    let rec: MacHealth.Recommendation
    let go: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: rec.severe ? "exclamationmark.triangle.fill" : "sparkles")
                .foregroundStyle(rec.severe ? .orange : .white).frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Module.myTools.accent.opacity(0.45)))
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.title).font(.callout.weight(.semibold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                Text(rec.detail).font(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Go", action: go).buttonStyle(PillButtonStyle())
        }
    }
}

struct RecommendationsSheet: View {
    let health: MacHealth?
    let go: (MacHealth.Recommendation.Target) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recommendations").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(health?.recommendations ?? []) { r in
                        RecommendationRow(rec: r) { go(r.target) }
                            .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x2B2541)))
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .environment(\.colorScheme, .dark)
    }
}

/// One dashboard card: an info button, the figures, or an empty state with a button that leads somewhere useful.
struct StatCard<Content: View>: View {
    let info: String
    let symbol: String
    let empty: (String, String, Module)?
    let go: (Module) -> Void
    @ViewBuilder let content: Content
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let empty {
                Spacer()
                Image(systemName: symbol).font(.system(size: 46)).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity)
                Text(empty.0).font(.callout).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity).padding(.top, 10)
                Spacer()
                Button { go(empty.2) } label: { Text(empty.1).frame(maxWidth: .infinity) }.buttonStyle(PillButtonStyle())
            } else {
                content
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 250, maxHeight: 250, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
        .overlay(alignment: .topTrailing) {
            Button { showInfo = true } label: { Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.5)) }
                .buttonStyle(.plain).padding(12)
                .popover(isPresented: $showInfo) { Text(info).padding().frame(width: 280) }
        }
    }
}

struct Delta: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "arrow.up.right").font(.caption.weight(.medium)).foregroundStyle(Color(hex: 0x7EE8C8))
            .help("Monthly change")
    }
}

struct Bar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(color).frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
    }
}
