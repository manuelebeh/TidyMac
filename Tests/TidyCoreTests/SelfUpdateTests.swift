import XCTest
@testable import TidyCore

final class SelfUpdateTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "SelfUpdateTests"

    override func setUp() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite) }

    private func payload(tag: String = "v1.2.0", url: String = "https://github.com/manuelebeh/TidyMac/releases/tag/v1.2.0",
                         draft: Bool = false, prerelease: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": url, "draft": draft, "prerelease": prerelease] as [String: Any])
    }

    private let release = SelfUpdate.Release(version: "1.2.0", page: URL(string: "https://github.com/manuelebeh/TidyMac/releases/tag/v1.2.0")!)

    func testParsesAPublishedRelease() {
        XCTAssertEqual(SelfUpdate.parse(payload()), release)
    }

    func testIgnoresDraftsPrereleasesAndForeignLinks() {
        XCTAssertNil(SelfUpdate.parse(payload(draft: true)))
        XCTAssertNil(SelfUpdate.parse(payload(prerelease: true)))
        XCTAssertNil(SelfUpdate.parse(payload(url: "https://example.com/TidyMac.dmg")))
        XCTAssertNil(SelfUpdate.parse(payload(url: "http://github.com/manuelebeh/TidyMac")))
        XCTAssertNil(SelfUpdate.parse(Data("not json".utf8)))
    }

    func testOnlyANewerVersionIsAvailable() {
        XCTAssertEqual(SelfUpdate.outcome(current: "1.1.9", latest: release), .available(release))
        XCTAssertEqual(SelfUpdate.outcome(current: "1.2", latest: release), .upToDate)
        XCTAssertEqual(SelfUpdate.outcome(current: "1.10.0", latest: release), .upToDate)
        XCTAssertEqual(SelfUpdate.outcome(current: "1.0.0", latest: nil), .upToDate)
    }

    func testAutomaticCheckIsOptInAndDaily() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertFalse(SelfUpdate.beginAutomaticCheck(now: start, defaults), "off by default")

        defaults.set(true, forKey: GeneralSettings.checkUpdatesKey)
        XCTAssertTrue(SelfUpdate.beginAutomaticCheck(now: start, defaults))
        XCTAssertFalse(SelfUpdate.beginAutomaticCheck(now: start.addingTimeInterval(3_600), defaults))
        XCTAssertTrue(SelfUpdate.beginAutomaticCheck(now: start.addingTimeInterval(86_400), defaults))
    }

    func testEachVersionIsAnnouncedOnce() {
        XCTAssertTrue(SelfUpdate.shouldAnnounce(release, defaults))
        XCTAssertFalse(SelfUpdate.shouldAnnounce(release, defaults))
        let newer = SelfUpdate.Release(version: "1.3.0", page: release.page)
        XCTAssertTrue(SelfUpdate.shouldAnnounce(newer, defaults))
        XCTAssertFalse(SelfUpdate.shouldAnnounce(release, defaults))
    }
}
