import AppKit
import TidyCore

/// The "Uninstall with TidyMac" service declared in Info.plist (`NSServices`). CleanMyMac adds the same item with a
/// Finder Sync extension; a service needs no extension, which a SwiftPM build cannot produce.
final class FinderService: NSObject {
    static let shared = FinderService()

    @objc func uninstallApplications(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let app = urls.first(where: { $0.pathExtension == "app" }) else {
            error.pointee = "Select an application to uninstall." as NSString
            return
        }
        // The same link Shortcuts can open; it brings the main window forward on the Uninstaller.
        NSWorkspace.shared.open(Uninstaller.uninstallURL(for: app))
    }
}

/// "Move to Applications folder?" on launch when TidyMac runs from somewhere else, such as Downloads or a disk image.
@MainActor
enum MoveOffer {
    static func offerIfNeeded() {
        let bundle = Bundle.main.bundleURL
        guard Bundle.main.bundleIdentifier != nil, MoveToApplications.shouldOffer(bundle: bundle) else { return }
        let alert = NSAlert()
        alert.messageText = "Move to Applications folder?"
        alert.informativeText = "TidyMac works best from your Applications folder: Open at Login and the menu bar item expect to find it there."
        alert.addButton(withTitle: "Move to Applications Folder")
        alert.addButton(withTitle: "Do Not Move")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: MoveToApplications.declinedKey)
            return
        }
        do {
            relaunch(from: try MoveToApplications.move(bundle))
        } catch MoveToApplications.Failure.needsAdministrator {
            // /Applications belongs to admin users; a standard account copies with the administrator prompt.
            let dest = "/Applications/\(bundle.lastPathComponent)"
            let r = Shell.osascript("do shell script \"rm -rf \(Executor.quote(dest)) && /usr/bin/ditto \(Executor.quote(bundle.path)) \(Executor.quote(dest))\" with administrator privileges")
            if r.status == 0 { relaunch(from: URL(fileURLWithPath: dest)) } else { fail(r.output) }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func relaunch(from app: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func fail(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "TidyMac could not be moved to Applications."
        alert.informativeText = reason
        alert.runModal()
    }
}
