import XCTest
@testable import TidyCore

final class TidyCoreTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func write(_ name: String, _ bytes: Int, byte: UInt8 = 0) throws -> URL {
        let u = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: byte, count: bytes).write(to: u)
        return u
    }

    func testExecutorRefusesTrashOutsideHome() async {
        let item = ResultItem(title: "hosts", url: URL(fileURLWithPath: "/etc/hosts"), action: .trash(URL(fileURLWithPath: "/etc/hosts")))
        let r = await Executor.run([item])
        XCTAssertTrue(r.succeeded.isEmpty)
        XCTAssertEqual(r.failed.count, 1)
    }

    func testExecutorRefusesPermanentDeleteOutsideTrash() async throws {
        let u = try write("keep.bin", 10)
        let r = await Executor.run([ResultItem(title: "x", url: u, action: .delete(u))])
        XCTAssertEqual(r.failed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.path))
    }

    func testDuplicatesKeepNewestCopy() throws {
        let a = try write("a/one.bin", 200_000, byte: 7)
        let b = try write("b/two.bin", 200_000, byte: 7)
        _ = try write("c/other.bin", 200_000, byte: 8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -1000)], ofItemAtPath: a.path)
        let g = ClutterEngine.duplicates(ClutterEngine.index(tmp))
        XCTAssertEqual(g.items.map(\.url?.lastPathComponent), ["one.bin"])
        XCTAssertTrue(g.items[0].subtitle?.contains(b.lastPathComponent) ?? false)
    }

    func testIndexSkipsRepositoriesAndBuildFolders() throws {
        _ = try write("docs/keep.bin", 10)
        _ = try write("repo/.git/HEAD", 10)
        _ = try write("repo/src/code.bin", 10)
        _ = try write("app/node_modules/dep.bin", 10)
        _ = try write("app/target/debug/lib.a", 10)
        XCTAssertEqual(ClutterEngine.index(tmp).map(\.url.lastPathComponent), ["keep.bin"])
    }

    func testDuplicatesOutsideDownloadsAreNotPreselected() throws {
        _ = try write("x/a.bin", 200_000, byte: 3)
        _ = try write("y/b.bin", 200_000, byte: 3)
        XCTAssertEqual(ClutterEngine.duplicates(ClutterEngine.index(tmp)).items.map(\.selectedByDefault), [false])
    }

    func testLargeFiles() throws {
        _ = try write("big.bin", 2_000_000)
        _ = try write("small.bin", 10)
        let g = ClutterEngine.largeAndOld(ClutterEngine.index(tmp), minSize: 1_000_000)
        XCTAssertEqual(g.items.map(\.title), ["big.bin"])
    }

    func testAppcastPicksHighestVersion() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><enclosure url="https://x/1.9.dmg" sparkle:shortVersionString="1.9" /></item>
        <item><sparkle:shortVersionString>1.10.2</sparkle:shortVersionString><enclosure url="https://x/1.10.2.dmg" /></item>
        </channel></rss>
        """
        let e = AppcastParser.latest(in: Data(xml.utf8))
        XCTAssertEqual(e?.version, "1.10.2")
        XCTAssertEqual(e?.url?.lastPathComponent, "1.10.2.dmg")
    }

    func testVersionOrdering() {
        XCTAssertTrue(Version("1.10") > Version("1.9.9"))
        XCTAssertTrue(Version("2.0 (45)") == Version("2"))
    }

    func testBundleIDHeuristic() {
        XCTAssertTrue(ApplicationsEngine.looksLikeBundleID("com.example.App"))
        XCTAssertFalse(ApplicationsEngine.looksLikeBundleID("com.apple.Safari"))
        XCTAssertFalse(ApplicationsEngine.looksLikeBundleID("Google"))
    }

    func testToolSearchUsesKeywords() {
        let ids = Toolbox.tools.filter { $0.matches("ollama") }.map(\.id)
        XCTAssertEqual(ids, ["aiClutter"])
        XCTAssertEqual(Toolbox.tools.filter { $0.matches("") }.count, Toolbox.tools.count)
        XCTAssertEqual(Set(Toolbox.tools.map(\.id)).count, Toolbox.tools.count)
    }

    func testItemsTakeTheirGroupAsCategory() {
        let g = ResultGroup(id: "duplicates", title: "D", description: "", symbol: "", items: [ResultItem(title: "a", action: .open(URL(fileURLWithPath: "/")))])
        XCTAssertEqual(g.items[0].category, "duplicates")
        // Smart Care regroups items; they keep the group they were found in.
        let sc = ResultGroup(id: "clutter", title: "C", description: "", symbol: "", items: g.items)
        XCTAssertEqual(sc.items[0].category, "duplicates")
    }

    func testActivitySummaryTotals() {
        let now = Date()
        let old = History.Entry(date: now.addingTimeInterval(-60 * 86_400), items: 2, freed: 1_000,
                                categories: ["systemJunk": .init(items: 2, bytes: 1_000)])
        let recent = History.Entry(date: now, items: 1, freed: 500, categories: ["duplicates": .init(items: 1, bytes: 500)])
        let scan = History.Entry(date: now, items: 0, freed: 0, categories: ["malwares": .init(items: 0, bytes: 0)], scanned: 12, threats: 1)
        let s = ActivitySummary([old, recent, scan], now: now)
        XCTAssertEqual(s.freed, 1_500)
        XCTAssertEqual(s.freedThisMonth, 500)
        XCTAssertEqual(s.freedBy.first { $0.0 == .systemJunk }?.1, 1_000)
        XCTAssertEqual(s.freedBy.first { $0.0 == .personalFiles }?.1, 500)
        XCTAssertEqual(s.minutesSaved, 10.4 + 10.5 + 15, accuracy: 0.001)
        XCTAssertEqual(s.malwareScans, 1)
        XCTAssertEqual(s.itemsScanned, 12)
        XCTAssertEqual(s.threatsFound, 1)
    }

    func testMacHealthGrades() {
        func rec(_ severe: Bool) -> MacHealth.Recommendation { .init(id: UUID().uuidString, title: "", detail: "", target: .smartCare, severe: severe) }
        XCTAssertEqual(MacHealth(recommendations: []).state, .excellent)
        XCTAssertEqual(MacHealth(recommendations: [rec(false), rec(false)]).state, .good)
        XCTAssertEqual(MacHealth(recommendations: Array(repeating: rec(false), count: 4)).state, .normal)
        XCTAssertEqual(MacHealth(recommendations: [rec(true)]).state, .requiresAttention)
        XCTAssertEqual(MacHealth(recommendations: [rec(true), rec(true)]).state, .critical)
    }

    func testHealthAlertsFireOnceAndRearm() {
        let full = SystemMonitor.Storage(name: "HD", total: 500_000_000_000, available: 3_000_000_000)
        let roomy = SystemMonitor.Storage(name: "HD", total: 500_000_000_000, available: 100_000_000_000)
        let calm = SystemMonitor.Memory(total: 1, active: 0, wired: 0, compressed: 0, available: 1, swapUsed: 0, pressureLevel: 1)
        var state = HealthAlerts.State()
        let t0 = Date()
        let low = HealthAlerts.Readings(storage: full, memory: calm, trashSize: 3_000_000_000)
        XCTAssertEqual(HealthAlerts.evaluate(low, settings: .init(), state: &state, now: t0).map(\.kind), [.lowDisk, .trashSize])
        // Still true an hour later: quiet. A day later: reminded.
        XCTAssertTrue(HealthAlerts.evaluate(low, settings: .init(), state: &state, now: t0 + 3_600).isEmpty)
        XCTAssertEqual(HealthAlerts.evaluate(low, settings: .init(), state: &state, now: t0 + 86_400).map(\.kind), [.lowDisk])
        // Cleared, then back: reported again at once.
        _ = HealthAlerts.evaluate(.init(storage: roomy, memory: calm), settings: .init(), state: &state, now: t0 + 90_000)
        XCTAssertEqual(HealthAlerts.evaluate(low, settings: .init(), state: &state, now: t0 + 90_060).map(\.kind), [.lowDisk, .trashSize])
        // Ignored for a day, or switched off in Settings.
        state = HealthAlerts.State()
        state.ignore("lowDisk", for: 86_400, now: t0)
        XCTAssertEqual(HealthAlerts.evaluate(low, settings: .init(), state: &state, now: t0 + 60).map(\.kind), [.trashSize])
        var off = HealthAlerts.Settings(); off.trashSize = false
        XCTAssertTrue(HealthAlerts.evaluate(low, settings: off, state: &state, now: t0 + 120).isEmpty)
    }

    func testMemoryAlertNeedsSustainedPressure() {
        let disk = SystemMonitor.Storage(name: "HD", total: 500_000_000_000, available: 200_000_000_000)
        func mem(_ level: Int) -> SystemMonitor.Memory { .init(total: 1, active: 0, wired: 0, compressed: 0, available: 1, swapUsed: 0, pressureLevel: level) }
        var state = HealthAlerts.State()
        let t0 = Date()
        XCTAssertTrue(HealthAlerts.evaluate(.init(storage: disk, memory: mem(2)), settings: .init(), state: &state, now: t0).isEmpty)
        let fired = HealthAlerts.evaluate(.init(storage: disk, memory: mem(2), topConsumer: ("Chrome", 3_000_000_000)),
                                          settings: .init(), state: &state, now: t0 + HealthAlerts.memoryGrace)
        XCTAssertEqual(fired.map(\.kind), [.memory])
        XCTAssertTrue(fired[0].body.contains("Chrome"))
        // Pressure drops and comes back within the hour: no second notification.
        _ = HealthAlerts.evaluate(.init(storage: disk, memory: mem(1)), settings: .init(), state: &state, now: t0 + 400)
        XCTAssertTrue(HealthAlerts.evaluate(.init(storage: disk, memory: mem(4)), settings: .init(), state: &state, now: t0 + 500).isEmpty)
        XCTAssertEqual(HealthAlerts.evaluate(.init(storage: disk, memory: mem(4)), settings: .init(), state: &state, now: t0 + 4_000).map(\.kind), [.memory])
    }

    func testThreatAlertsAreOncePerItem() {
        let disk = SystemMonitor.Storage(name: "HD", total: 500_000_000_000, available: 200_000_000_000)
        let mem = SystemMonitor.Memory(total: 1, active: 0, wired: 0, compressed: 0, available: 1, swapUsed: 0, pressureLevel: 1)
        var state = HealthAlerts.State()
        let a = HealthAlerts.Readings(storage: disk, memory: mem, threats: [("threat:a", "com.bad.a")])
        XCTAssertEqual(HealthAlerts.evaluate(a, settings: .init(), state: &state).map(\.key), ["threat:a"])
        // A check without a threat scan keeps it known; a new item is still reported.
        XCTAssertTrue(HealthAlerts.evaluate(.init(storage: disk, memory: mem), settings: .init(), state: &state, now: Date() + 999_999).isEmpty)
        let ab = HealthAlerts.Readings(storage: disk, memory: mem, threats: [("threat:a", "com.bad.a"), ("threat:b", "com.bad.b")])
        XCTAssertEqual(HealthAlerts.evaluate(ab, settings: .init(), state: &state).map(\.key), ["threat:b"])
    }

    func testConsumersGroupHelpersUnderTheirApp() {
        let ps = """
          101 204800  12,5 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
          102 409600  30.0 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/A/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)
          200  10240   1.0 /usr/libexec/logd
        """
        let c = Dictionary(uniqueKeysWithValues: SystemMonitor.parseConsumers(ps).map { ($0.name, $0) })
        XCTAssertEqual(c["Google Chrome"]?.memory, 614_400 * 1024)
        XCTAssertEqual(c["Google Chrome"]?.cpu ?? 0, 42.5, accuracy: 0.001)
        XCTAssertEqual(c["Google Chrome"]?.pid, 101)
        XCTAssertNil(c["logd"]?.pid)
    }

    func testBluetoothBatteryLevels() {
        let json = """
        {"SPBluetoothDataType":[{"device_connected":[
          {"AirPods Pro":{"device_minorType":"Headphones","device_batteryLevelLeft":"15%","device_batteryLevelRight":"80%","device_batteryLevelCase":"5%"}},
          {"Magic Mouse":{"device_minorType":"Mouse","device_batteryLevelMain":"64%"}},
          {"Speaker":{"device_minorType":"Speaker"}}]}]}
        """
        let d = SystemMonitor.parseBluetooth(json)
        XCTAssertEqual(d.map(\.name).sorted(), ["AirPods Pro", "Magic Mouse", "Speaker"])
        XCTAssertEqual(d.first { $0.name == "AirPods Pro" }?.lowest, 15) // the case does not count
        XCTAssertEqual(d.first { $0.name == "Magic Mouse" }?.batteries, [.init(label: "", percent: 64)])
        XCTAssertTrue(d.first { $0.name == "Speaker" }?.batteries.isEmpty ?? false)

        let disk = SystemMonitor.Storage(name: "HD", total: 500_000_000_000, available: 200_000_000_000)
        let mem = SystemMonitor.Memory(total: 1, active: 0, wired: 0, compressed: 0, available: 1, swapUsed: 0, pressureLevel: 1)
        let usb = SystemMonitor.Drive(url: URL(fileURLWithPath: "/Volumes/USB"), name: "USB", total: 64_000_000_000, available: 2_000_000_000, format: "ExFAT", isDiskImage: false)
        let dmg = SystemMonitor.Drive(url: URL(fileURLWithPath: "/Volumes/Installer"), name: "Installer", total: 100, available: 0, format: nil, isDiskImage: true)
        var state = HealthAlerts.State()
        let alerts = HealthAlerts.evaluate(.init(storage: disk, memory: mem, externalDrives: [usb, dmg], bluetooth: d), settings: .init(), state: &state)
        XCTAssertEqual(alerts.map(\.key), ["externalFull:USB", "bluetoothLow"])
        XCTAssertTrue(alerts[1].body.contains("AirPods Pro (15%)"))
    }

    func testSystemMonitorReadings() {
        let s = SystemMonitor.storage()
        XCTAssertGreaterThan(s.total, 0)
        XCTAssertLessThanOrEqual(s.available, s.total)
        let m = SystemMonitor.memory()
        XCTAssertEqual(m.total, Int64(ProcessInfo.processInfo.physicalMemory))
        XCTAssertGreaterThan(m.available, 0)
        _ = SystemMonitor.cpu()
        usleep(200_000)
        let c = SystemMonitor.cpu()
        XCTAssertEqual(c.user + c.system + c.idle, 1, accuracy: 0.01)
        XCTAssertGreaterThan(c.uptime, 0)
    }

    func testIssuesFlagLowDiskAndBigTrash() {
        let s = SystemMonitor.Storage(name: "HD", total: 500_000_000_000, available: 5_000_000_000)
        let m = SystemMonitor.Memory(total: 1, active: 0, wired: 0, compressed: 0, available: 1, swapUsed: 0, pressureLevel: 1)
        let kinds = SystemMonitor.issues(storage: s, memory: m, trashSize: 2_000_000_000, trashedApps: 1).map(\.kind)
        XCTAssertEqual(kinds, [.lowDiskSpace, .trashSize, .trashedApps])
    }

    func testBubblePackingDoesNotOverlap() {
        let b = SpaceLens.pack([100, 80, 50, 50, 20, 10, 5], radius: 200)
        XCTAssertEqual(b.count, 7)
        for i in b.indices { for j in b.indices where j > i {
            XCTAssertGreaterThanOrEqual(hypot(b[i].x - b[j].x, b[i].y - b[j].y), b[i].r + b[j].r - 0.001)
        } }
        XCTAssertLessThanOrEqual(b.map { hypot($0.x, $0.y) + $0.r }.max()!, 200.001)
    }
}
