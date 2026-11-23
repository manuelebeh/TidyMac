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
