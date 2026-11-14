import XCTest
@testable import TidyCore

final class UninstallerFoldersTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UninstallerFolders-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testOnlyFoldersInHomeOrOnDrivesCanBeSearched() {
        let home = Paths.home
        XCTAssertTrue(Uninstaller.canSearch(home.appendingPathComponent("Games"), home: home))
        XCTAssertTrue(Uninstaller.canSearch(URL(fileURLWithPath: "/Volumes/Backup/Apps"), home: home))
        XCTAssertFalse(Uninstaller.canSearch(home, home: home))
        XCTAssertFalse(Uninstaller.canSearch(URL(fileURLWithPath: "/System/Applications"), home: home))
        XCTAssertFalse(Uninstaller.canSearch(URL(fileURLWithPath: "/"), home: home))
    }

    func testAppsInAddedFoldersAndDrivesAreListed() throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("home"), extra = home.appendingPathComponent("Games")
        let drive = root.appendingPathComponent("Drive/Applications")
        for app in [extra.appendingPathComponent("Chess.app"), drive.appendingPathComponent("Paint.app")] {
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
        }
        let names = Uninstaller.installedApps(home: home, system: root.appendingPathComponent("system"), extraFolders: [extra], drives: [drive]).map(\.name)
        XCTAssertEqual(Set(names), ["Chess", "Paint"])
    }
}
