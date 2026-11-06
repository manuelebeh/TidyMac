import Foundation

/// TidyMac's bundle id used to be a local placeholder, and macOS keeps settings per bundle id. This brings them over once.
public enum BundleMigration {
    public static let bundleID = "io.github.manuelebeh.TidyMac"
    static let previousBundleID = "dev.local.TidyMac"
    static let doneKey = "TidyMac.migratedFromPreviousBundleID"

    /// Runs before anything reads the settings. Outside the app bundle there is no settings domain to migrate into.
    public static func run() {
        guard Bundle.main.bundleIdentifier == bundleID else { return }
        migrate(UserDefaults.standard.persistentDomain(forName: previousBundleID), into: .standard)
    }

    /// A setting already made under the new id wins. The old values stay where they are, in case of a downgrade.
    static func migrate(_ previous: [String: Any]?, into d: UserDefaults) {
        guard !d.bool(forKey: doneKey) else { return }
        for (key, value) in previous ?? [:] where d.object(forKey: key) == nil { d.set(value, forKey: key) }
        d.set(true, forKey: doneKey)
    }
}
