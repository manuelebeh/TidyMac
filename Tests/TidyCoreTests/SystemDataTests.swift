import XCTest
@testable import TidyCore

extension TidyCoreTests {
    // MARK: Hidden in System Data

    func testSnapshotCountOnlyCountsSnapshotLines() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-11-06-101500.local
        com.apple.TimeMachine.2026-11-06-111500.local
        com.apple.os.update-ABC123
        """
        XCTAssertEqual(SystemData.snapshotCount(output), 2)
        XCTAssertEqual(SystemData.snapshotCount("Snapshots for disk /:\n"), 0)
    }

    func testSystemDataSizesItsFoldersAndSkipsSmallOnes() throws {
        _ = try write("Library/Caches/app/blob", 300_000)
        _ = try write("Library/Logs/app.log", 100_000)
        _ = try write(".ollama/models/blobs/sha256-1", 50_000)
        let caches = try XCTUnwrap(SystemData.entry(.caches, home: tmp, fullDiskAccess: false, minimum: 1))
        XCTAssertGreaterThanOrEqual(caches.size ?? 0, 400_000)
        XCTAssertNotNil(SystemData.entry(.localModels, home: tmp, fullDiskAccess: false, minimum: 1))
        // Nothing there, or less than the threshold: no row.
        XCTAssertNil(SystemData.entry(.developer, home: tmp, fullDiskAccess: false, minimum: 1))
        XCTAssertNil(SystemData.entry(.caches, home: tmp, fullDiskAccess: false))
    }

    func testDockerIsOnlyMeasuredWithFullDiskAccess() {
        let docker = tmp.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms")
        XCTAssertFalse(SystemData.developerFolders(home: tmp, fullDiskAccess: false).contains(docker))
        XCTAssertTrue(SystemData.developerFolders(home: tmp, fullDiskAccess: true).contains(docker))
    }

    /// A record shaped like macOS's: the model's description is a keyed archive inside the state file.
    func appleModelRecord(bytes: Int64, onDisk: Bool) throws -> Data {
        let descriptor: [String: Any] = ["downloadedFilesystemBytes": bytes, "isOnFilesystem": onDisk, "isPatch": false]
        let archive = try PropertyListSerialization.data(fromPropertyList: ["$archiver": "NSKeyedArchiver", "$objects": ["$null", descriptor]],
                                                         format: .binary, options: 0)
        let state: [String: Any] = ["SUCorePersistedStateContentsType": "SoftwareUpdateCorePersistedStateFile",
                                    "SUCorePersistedStatePolicySecureCodedObjectsFields": ["assetDescriptor": archive]]
        return try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    func testAppleModelsAddUpWhatMacOSRecordsByKind() throws {
        let records = tmp.appendingPathComponent("AutoAssetDescriptors")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        func record(_ type: String, _ name: String, _ bytes: Int64, onDisk: Bool = true) throws {
            try appleModelRecord(bytes: bytes, onDisk: onDisk)
                .write(to: records.appendingPathComponent("AutoAssetDescriptors_Entry_com.apple.MobileAsset.UAF.\(type)_\(name)_1.0_0.state"))
        }
        try record("FM.GenerativeModels", "com.apple.fm.base", 6_000_000_000)
        try record("FM.GenerativeModels", "com.apple.fm.adapter", 500_000_000)
        try record("FM.GenerativeModels", "com.apple.fm.old", 9_000_000_000, onDisk: false)
        try record("FM.CodeLM", "com.apple.code", 5_200_000_000)
        try record("Siri.TextToSpeech", "com.apple.voice", 600_000_000)
        try Data("not a plist".utf8).write(to: records.appendingPathComponent("AutoAssetDescriptors_Entry_com.apple.MobileAsset.UAF.FM.Visual_x_0.state"))

        let parts = Dictionary(uniqueKeysWithValues: AppleModels.measure(records: records).map { ($0.kind, $0.bytes) })
        XCTAssertEqual(parts[.core], 6_500_000_000)
        XCTAssertEqual(parts[.code], 5_200_000_000)
        XCTAssertEqual(parts[.image], 0)
        XCTAssertEqual(parts.count, AppleModels.Kind.allCases.count)
        XCTAssertTrue(AppleModels.measure(records: tmp.appendingPathComponent("nowhere")).isEmpty)
    }

    func testDeviceFilesCountBackupsAndUpdates() throws {
        _ = try write("Library/Application Support/MobileSync/Backup/0000-1111/Manifest.db", 200_000)
        _ = try write("Library/iTunes/iPhone Software Updates/iPhone_27.2_Restore.ipsw", 300_000)
        let entry = try XCTUnwrap(SystemData.entry(.deviceFiles, home: tmp, fullDiskAccess: true, minimum: 1))
        XCTAssertGreaterThanOrEqual(entry.size ?? 0, 500_000)

        let updates = CleanupEngine.iosUpdates(home: tmp)
        XCTAssertEqual(updates.items.map(\.title), ["iPhone_27.2_Restore.ipsw"])
        XCTAssertEqual(updates.items.first?.subtitle, "iPhone Software Updates")
        XCTAssertTrue(CleanupEngine.iosUpdates(home: tmp.appendingPathComponent("nowhere")).isEmpty)
    }
}
