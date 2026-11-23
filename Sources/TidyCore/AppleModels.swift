import Foundation

/// The Apple Intelligence models on this Mac, by kind, as macOS records them. The model folders cannot be read, even
/// with Full Disk Access, but macOS keeps a readable record of each downloaded model with the bytes it took on disk.
/// That is Apple's own figure; part of it may already count as purgeable space.
public enum AppleModels {
    public enum Kind: String, CaseIterable, Sendable {
        case core, image, code, photosCleanUp, spatialPhotos

        /// The MobileAsset type each kind is downloaded as.
        var assetType: String {
            switch self {
            case .core: "com.apple.MobileAsset.UAF.FM.GenerativeModels"
            case .image: "com.apple.MobileAsset.UAF.FM.Visual"
            case .code: "com.apple.MobileAsset.UAF.FM.CodeLM"
            case .photosCleanUp: "com.apple.MobileAsset.UAF.Photos.MagicCleanup"
            case .spatialPhotos: "com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive"
            }
        }
    }

    public struct Part: Sendable, Equatable {
        public let kind: Kind
        public let bytes: Int64
    }

    public static let records = URL(fileURLWithPath: "/System/Library/AssetsV2/persisted/AutoAssetDescriptors")

    /// Every kind, with 0 bytes for one that is not on this Mac. Empty when macOS keeps no record at all.
    public static func measure(records: URL = records) -> [Part] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: records.path) else { return [] }
        var totals: [Kind: Int64] = [:]
        for name in files {
            // AutoAssetDescriptors_Entry_<asset type>_<asset>_<version>_0.state
            guard let kind = Kind.allCases.first(where: { name.hasPrefix("AutoAssetDescriptors_Entry_\($0.assetType)_") }),
                  let data = FileManager.default.contents(atPath: records.appendingPathComponent(name).path),
                  let bytes = bytesOnDisk(record: data) else { continue }
            totals[kind, default: 0] += bytes
        }
        return Kind.allCases.map { Part(kind: $0, bytes: totals[$0] ?? 0) }
    }

    /// The bytes one record says its model takes on disk, or nil when the model is no longer there.
    /// The record holds the model's description as a keyed archive; the fields read here are plain numbers in it.
    static func bytesOnDisk(record data: Data) -> Int64? {
        guard let outer = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let fields = outer["SUCorePersistedStatePolicySecureCodedObjectsFields"] as? [String: Any],
              let archive = fields["assetDescriptor"] as? Data,
              let inner = try? PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
              let objects = inner["$objects"] as? [Any],
              let descriptor = objects.lazy.compactMap({ $0 as? [String: Any] }).first(where: { $0["downloadedFilesystemBytes"] != nil }),
              descriptor["isOnFilesystem"] as? Bool == true,
              let bytes = (descriptor["downloadedFilesystemBytes"] as? NSNumber)?.int64Value else { return nil }
        return bytes
    }
}
