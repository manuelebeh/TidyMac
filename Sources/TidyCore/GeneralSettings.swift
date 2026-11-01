import Foundation

/// Settings › General, plus the menu's "Clean up junk automatically on ejection". Stored as plain keys so the Settings window can bind them with `@AppStorage`.
public enum GeneralSettings {
    public enum ReduceMotion: String, CaseIterable, Sendable { case system = "System", enabled = "Enabled", disabled = "Disabled" }

    static let prefix = "TidyMac.general"
    public static let soundsKey = "\(prefix).sounds"
    public static let reduceMotionKey = "\(prefix).reduceMotion"
    public static let keepInDockKey = "\(prefix).keepInDock"
    public static let assistantKey = "\(prefix).assistant"
    public static let cleanOnEjectKey = "\(prefix).cleanOnEject"

    /// Defaults keep TidyMac as it was before these settings existed; cleaning on ejection deletes files, so it is opt-in.
    public static let defaults: [String: Any] = [
        soundsKey: true, reduceMotionKey: ReduceMotion.system.rawValue, keepInDockKey: true, assistantKey: true, cleanOnEjectKey: false,
    ]

    static func bool(_ key: String, _ d: UserDefaults) -> Bool { d.object(forKey: key) as? Bool ?? defaults[key] as? Bool ?? false }

    public static func playsSounds(_ d: UserDefaults = .standard) -> Bool { bool(soundsKey, d) }
    public static func keepsDockIcon(_ d: UserDefaults = .standard) -> Bool { bool(keepInDockKey, d) }
    public static func showsAssistant(_ d: UserDefaults = .standard) -> Bool { bool(assistantKey, d) }
    public static func cleansOnEject(_ d: UserDefaults = .standard) -> Bool { bool(cleanOnEjectKey, d) }

    public static func reduceMotion(_ d: UserDefaults = .standard) -> ReduceMotion {
        d.string(forKey: reduceMotionKey).flatMap(ReduceMotion.init(rawValue:)) ?? .system
    }

    /// "System" follows Accessibility › Display › Reduce motion, which the caller reads through AppKit.
    public static func reducesMotion(system: Bool, _ d: UserDefaults = .standard) -> Bool {
        switch reduceMotion(d) {
        case .system: system
        case .enabled: true
        case .disabled: false
        }
    }
}
