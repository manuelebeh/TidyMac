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

    func testPicksTheSignedZipFromTheRelease() {
        let asset = { (name: String, url: String) in ["name": name, "browser_download_url": url] as [String: Any] }
        let good = "https://github.com/manuelebeh/TidyMac/releases/download/v1.2.0/TidyMac-1.2.0.zip"
        let data = try! JSONSerialization.data(withJSONObject: [
            "tag_name": "v1.2.0", "html_url": release.page.absoluteString, "draft": false, "prerelease": false,
            "assets": [asset("TidyMac-1.2.0.dmg", good.replacingOccurrences(of: ".zip", with: ".dmg")),
                       asset("TidyMac-1.2.0.zip", "https://example.com/releases/TidyMac-1.2.0.zip"),
                       asset("TidyMac-1.2.0.zip", good)],
        ] as [String: Any])
        XCTAssertEqual(SelfUpdate.parse(data)?.archive, URL(string: good))
        XCTAssertNil(SelfUpdate.parse(payload())?.archive)
    }

    func testReadsTheDeveloperFromCodesignOutput() {
        XCTAssertEqual(UpdateInstaller.teamIdentifier(in: "Identifier=x\nTeamIdentifier=ABCDE12345\nSealed Resources=none"), "ABCDE12345")
        XCTAssertNil(UpdateInstaller.teamIdentifier(in: "TeamIdentifier=not set"))
        XCTAssertNil(UpdateInstaller.teamIdentifier(in: "code object is not signed at all"))
    }

    func testAutomaticInstallNeedsTheCheck() {
        defaults.set(true, forKey: GeneralSettings.installUpdatesKey)
        XCTAssertFalse(GeneralSettings.installsUpdates(defaults))
        defaults.set(true, forKey: GeneralSettings.checkUpdatesKey)
        XCTAssertTrue(GeneralSettings.installsUpdates(defaults))
    }

    func testAppearanceAndMenuBarDefaults() {
        XCTAssertEqual(GeneralSettings.appearance(defaults), .system)
        XCTAssertTrue(GeneralSettings.showsMenuBarItem(defaults))
        defaults.set("dark", forKey: GeneralSettings.appearanceKey)
        XCTAssertEqual(GeneralSettings.appearance(defaults), .dark)
    }
}
