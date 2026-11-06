import XCTest
@testable import TidyCore

final class BundleMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "BundleMigrationTests"

    override func setUp() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite) }

    func testKeepsNewerSettingsAndRunsOnce() {
        defaults.set(false, forKey: "kept")
        BundleMigration.migrate(["kept": true, "copied": 3], into: defaults)
        XCTAssertEqual(defaults.object(forKey: "kept") as? Bool, false)
        XCTAssertEqual(defaults.integer(forKey: "copied"), 3)

        // Something the person cleared since must not come back on the next launch.
        defaults.removeObject(forKey: "copied")
        BundleMigration.migrate(["copied": 3], into: defaults)
        XCTAssertNil(defaults.object(forKey: "copied"))
    }

    func testFinishesWithoutPreviousSettings() {
        BundleMigration.migrate(nil, into: defaults)
        BundleMigration.migrate(["late": 1], into: defaults)
        XCTAssertNil(defaults.object(forKey: "late"))
    }
}
