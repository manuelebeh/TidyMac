import Foundation

/// "Move to Applications folder" on first launch, as CleanMyMac offers. Running from Downloads or a disk image breaks
/// Open at Login and updates, so TidyMac copies itself to /Applications and relaunches from there.
public enum MoveToApplications {
    public static let declinedKey = "TidyMac.moveToApplicationsDeclined"

    public static func shouldOffer(bundle: URL, home: URL = Paths.home, defaults: UserDefaults = .standard) -> Bool {
        guard bundle.pathExtension == "app", !defaults.bool(forKey: declinedKey) else { return false }
        let path = bundle.standardizedFileURL.resolvingSymlinksInPath().path
        let homeApps = home.appendingPathComponent("Applications").standardizedFileURL.path
        return !path.hasPrefix("/Applications/") && !path.hasPrefix(homeApps + "/")
    }

    public enum Failure: Error { case needsAdministrator }

    /// Copies `bundle` into `applications`, sending an older copy there to the Trash first. The original is trashed when
    /// it can be (a disk image cannot), so the app is not left in two places. Tests pass their own `trash`.
    @discardableResult
    public static func move(_ bundle: URL, to applications: URL = URL(fileURLWithPath: "/Applications"), fm: FileManager = .default,
                            trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> URL {
        guard fm.isWritableFile(atPath: applications.path) else { throw Failure.needsAdministrator }
        let destination = applications.appendingPathComponent(bundle.lastPathComponent)
        if fm.fileExists(atPath: destination.path) { try trash(destination) }
        try fm.copyItem(at: bundle, to: destination)
        if fm.isDeletableFile(atPath: bundle.path) { try? trash(bundle) }
        return destination
    }
}
