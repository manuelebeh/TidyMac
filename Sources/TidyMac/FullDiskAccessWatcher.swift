import SwiftUI
import TidyCore

/// Notices Full Disk Access being granted while TidyMac is open. macOS sends no event for it, so the status is read
/// every two seconds until access is there. The read happens off the main thread and nothing else polls.
@MainActor
final class FullDiskAccessWatcher: ObservableObject {
    static let shared = FullDiskAccessWatcher()
    @Published private(set) var granted = Permissions.hasFullDiskAccess

    private init() {
        guard !granted else { return }
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if await Task.detached(operation: { Permissions.hasFullDiskAccess }).value { break }
            }
            granted = true
        }
    }
}

/// Explains what Full Disk Access changes at this point, with the one action that helps.
struct FullDiskAccessBanner: View {
    var message = String(localized: "Grant Full Disk Access so TidyMac can scan protected folders without repeated prompts.")
    var symbol = "lock.shield.fill"
    var actionTitle = String(localized: "Open Settings")
    var action: () -> Void = { NSWorkspace.shared.open(Permissions.fullDiskAccessSettings) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.yellow)
            Text(message).font(.callout).foregroundStyle(.white)
            Button(actionTitle, action: action).buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(.black.opacity(0.25)))
    }
}
