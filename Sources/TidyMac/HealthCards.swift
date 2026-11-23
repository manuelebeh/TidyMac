import SwiftUI
import TidyCore

/// How the Mac is doing overall, in one word and a sentence.
struct MacHealthCard: View {
    let health: MacHealth?
    let machine: String

    var body: some View {
        HistoryCard(title: String(localized: "Mac Health:"), symbol: "laptopcomputer") {
            VStack(alignment: .leading, spacing: DS.Space.item) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(health?.state.title ?? "...").font(.system(size: 30, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle().fill(health?.state.color() ?? .secondary).frame(width: 7, height: 7)
                        Text(machine).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if let health {
                    Text(health.description).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// What to do next: each recommendation with a way to act on it now or skip it until tomorrow.
struct RecommendationsCard: View {
    @ObservedObject var app: AppState
    @Binding var health: MacHealth?
    @State private var showAll = false
    @State private var showUnused = false
    @State private var confirmRestart = false

    var body: some View {
        let recs = health?.recommendations ?? []
        let title = recs.isEmpty ? String(localized: "Today's Recommendation") : String(localized: "\(recs.count) Recommendations")
        HistoryCard(title: title, symbol: "lightbulb.fill", trailing: AnyView(
            Group {
                if recs.count > 1 {
                    Button("Hide All") { skip(recs.map(\.id)) }.buttonStyle(.plain)
                        .font(.system(size: 12.5)).foregroundStyle(DS.accent)
                        .help("Hide every recommendation until tomorrow")
                }
            })) {
            if recs.isEmpty {
                if health != nil {
                    CardEmpty(symbol: "checkmark.seal.fill", tint: DS.safe, title: String(localized: "You’re all good!"),
                              message: String(localized: "There are no recommendations for today."))
                }
            } else if recs.count == 1 {
                row(recs[0])
            } else {
                stack(recs)
            }
        }
        .sheet(isPresented: $showUnused) { UninstallerSheet(module: .applications, filter: .unused) }
        .alert("Restart your Mac now?", isPresented: $confirmRestart) {
            Button("Cancel", role: .cancel) {}
            Button("Restart") { Shell.osascript("tell application \"System Events\" to restart") }
        } message: {
            Text("Save your work first. Apps with unsaved changes may ask before they quit.")
        }
    }

    /// "Skip for now" and "Hide All": gone until tomorrow, and no longer counted in Mac Health.
    private func skip(_ ids: [String]) {
        var skipped = SkippedRecommendations.load()
        skipped.skip(ids)
        skipped.save()
        health = MacHealth(recommendations: (health?.recommendations ?? []).filter { !ids.contains($0.id) })
    }

    /// Several recommendations as a stack of cards: the first one in full, the next ones peeking out behind it.
    /// Skipping or acting on the first brings the next one forward; "Show more" spreads the whole stack out.
    private func stack(_ recs: [MacHealth.Recommendation]) -> some View {
        let layers = min(recs.count, 3) - 1
        return VStack(alignment: .leading, spacing: DS.Space.item) {
            if showAll {
                VStack(spacing: 0) {
                    ForEach(Array(recs.enumerated()), id: \.element.id) { i, r in
                        row(r)
                        if i < recs.count - 1 { Divider().padding(.vertical, 14) }
                    }
                }
            } else {
                row(recs[0])
                    .padding(DS.Space.item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        // Solid, one step lighter than the card it sits in, so it reads as the top of the stack.
                        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                        shape.fill(DS.window).overlay(shape.fill(DS.card)).overlay(shape.fill(DS.card))
                            .overlay(shape.strokeBorder(DS.border))
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                    }
                    .background(alignment: .top) {
                        ZStack(alignment: .top) {
                            ForEach(Array((1...max(layers, 1)).reversed()), id: \.self) { i in
                                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.window)
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.card))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.14)))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.border))
                                    .padding(.horizontal, CGFloat(i) * 10)
                                    .offset(y: CGFloat(i) * 8)
                                    .opacity(i <= layers ? 1 : 0)
                            }
                        }
                    }
                    .padding(.bottom, CGFloat(layers) * 8)
                    .contentShape(Rectangle())
                    .transition(.opacity)
            }
            Button(showAll ? String(localized: "Show less") : String(localized: "Show \(recs.count - 1) more")) {
                withAnimation(Motion.animation(.easeInOut(duration: 0.2))) { showAll.toggle() }
            }
            .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(DS.accent)
        }
    }

    private func row(_ r: MacHealth.Recommendation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconChip(symbol: r.severe ? "exclamationmark.triangle.fill" : "sparkles", tint: r.severe ? DS.caution : DS.accent, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(r.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("Go") { go(r.target) }.buttonStyle(SecondaryButtonStyle())
                    Button("Skip for now") { skip([r.id]) }.buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func go(_ target: MacHealth.Recommendation.Target) {
        switch target {
        case .fullDiskAccess: NSWorkspace.shared.open(Permissions.fullDiskAccessSettings)
        case .screenCleaning: app.screenCleaning.start()
        case .smartCare: app.controllers[.smartCare]?.scan()
        case .cleanup: app.module = .cleanup
        case .protection: app.module = .protection
        case .performance: app.module = .performance
        case .applications: app.openApplications(.updates)
        case .uninstaller: showUnused = true
        case .clutter: app.module = .clutter
        case .restart: confirmRestart = true
        case .backup: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!)
        }
    }
}
