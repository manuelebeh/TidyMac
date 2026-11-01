import Foundation

/// Settings › Scanning (CleanMyMac's "Modules to scan using Smart Care" and "Categories to scan using Cleanup").
/// Stored as what is turned off, so modules and categories added later are on by default.
/// My Tools ignores these settings: a tool runs the one check the user picked.
public struct ScanSettings: Codable, Sendable, Equatable {
    static let key = "TidyMac.scanSettings"

    public var disabledSmartCare: Set<String> = []
    public var disabledCleanup: Set<String> = []

    /// Smart Care's tiles, by `SmartCareEngine` group ID.
    public static let smartCareModules: [(id: String, title: String)] = [
        ("cleanup", "Cleanup"), ("protection", "Protection"), ("performance", "Performance"),
        ("applications", "Applications"), ("clutter", "My Clutter"),
    ]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disabledSmartCare = try c.decodeIfPresent(Set<String>.self, forKey: .disabledSmartCare) ?? []
        disabledCleanup = try c.decodeIfPresent(Set<String>.self, forKey: .disabledCleanup) ?? []
    }

    public func scansSmartCare(_ id: String) -> Bool { !disabledSmartCare.contains(id) }
    public func scansCleanup(_ id: String) -> Bool { !disabledCleanup.contains(id) }

    public static func load(defaults: UserDefaults = .standard) -> ScanSettings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ScanSettings.self, from: $0) } ?? ScanSettings()
    }

    public func save(defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
    }
}
