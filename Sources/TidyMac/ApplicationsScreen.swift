import SwiftUI
import TidyCore

enum ApplicationsTab: Hashable { case apps, updates }

/// Applications: opens on the list of installed apps, the thing people come here for. The second tab is the
/// module's scan for updates, leftovers of removed apps and installers left behind.
struct ApplicationsScreen: View {
    @ObservedObject var app: AppState
    @ObservedObject var controller: ModuleController

    private var tabs: some View {
        Picker("", selection: $app.applicationsTab) {
            Text("Apps").tag(ApplicationsTab.apps)
            Text("Updates & Leftovers").tag(ApplicationsTab.updates)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    var body: some View {
        Group {
            switch app.applicationsTab {
            case .apps:
                VStack(alignment: .leading, spacing: 0) {
                    ScreenHeader(title: Module.applications.name, subtitle: String(localized: "Select an app to see everything it leaves on your Mac.")) {
                        tabs
                    }
                    .headerPadding()
                    UninstallerSheet(module: .applications, embedded: true)
                }
            case .updates:
                ModuleScreen(controller: controller, accessory: AnyView(tabs))
            }
        }
    }
}
