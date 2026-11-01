import SwiftUI
import TidyCore

/// Running apps related to the files about to be removed, read from NSWorkspace.
@MainActor
enum RunningApps {
    /// Regular apps only; Finder and TidyMac itself are never asked to quit.
    static func related(to urls: [URL]) -> [NSRunningApplication] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != getpid()
                && $0.bundleIdentifier != "com.apple.finder"
        }
        let candidates = running.map {
            AppTerminator.App(pid: $0.processIdentifier, name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier, bundleURL: $0.bundleURL)
        }
        let pids = Set(AppTerminator.related(to: urls, among: candidates).map(\.pid))
        return running.filter { pids.contains($0.processIdentifier) }
    }
}

/// Mirrors CleanMyMac's ApplicationsTerminator: Quit / Quit All, Force Quit for apps that do not quit,
/// or Ignore and Continue. It continues on its own once every app has quit.
struct QuitAppsSheet: View {
    @State var apps: [NSRunningApplication]
    let onContinue: () -> Void
    let onCancel: () -> Void
    /// When Quit was asked for each app; after `patience` an app still running is shown as "Can't be quit".
    @State private var asked: [pid_t: Date] = [:]
    @State private var now = Date()
    @State private var finished = false
    private let patience: TimeInterval = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Some applications should be quit.").font(.title3.weight(.semibold))
            Text("Please quit the following applications to clean all of their related items:").foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(apps, id: \.processIdentifier) { app in
                    HStack {
                        Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 28, height: 28)
                        Text(app.localizedName ?? "Application")
                        Spacer()
                        if stuck(app) {
                            Text("Can't be quit").font(.caption).foregroundStyle(.secondary)
                            Button("Force Quit") { app.forceTerminate() }
                        } else if asked[app.processIdentifier] != nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Quit") { quit(app) }
                        }
                    }
                    .padding(.vertical, 6)
                    if app != apps.last { Divider() }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            HStack {
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Ignore and Continue", action: finish)
                Button("Quit All") { apps.filter { asked[$0.processIdentifier] == nil }.forEach(quit) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                apps.removeAll(where: \.isTerminated)
                now = Date()
                if apps.isEmpty { finish(); return }
            }
        }
    }

    /// The poll and the button can both end the sheet; the caller runs only once.
    private func finish() {
        guard !finished else { return }
        finished = true
        onContinue()
    }

    private func quit(_ app: NSRunningApplication) {
        asked[app.processIdentifier] = Date()
        app.terminate()
    }

    private func stuck(_ app: NSRunningApplication) -> Bool {
        asked[app.processIdentifier].map { now.timeIntervalSince($0) > patience } ?? false
    }
}
