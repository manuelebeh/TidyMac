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

    func testTrayIssuesForFrozenAppsDevicesAndDrives() {
        let s = SystemMonitor.Storage(name: "HD", total: 500_000_000_000, available: 200_000_000_000)
        let m = SystemMonitor.Memory(total: 1, active: 0, wired: 0, compressed: 0, available: 1, swapUsed: 0, pressureLevel: 1)
        let mouse = SystemMonitor.BluetoothDevice(name: "Mouse", kind: "Mouse", batteries: [.init(label: "", percent: 10)])
        let pods = SystemMonitor.BluetoothDevice(name: "AirPods", kind: "Headphones", batteries: [.init(label: "Case", percent: 5), .init(label: "Left", percent: 90)])
        let usb = SystemMonitor.Drive(url: URL(fileURLWithPath: "/Volumes/USB"), name: "USB", total: 64_000_000_000, available: 2_000_000_000, format: nil, isDiskImage: false)
        let issues = SystemMonitor.issues(storage: s, memory: m, trashSize: nil, trashedApps: 0, hungApps: ["Pages"], bluetooth: [mouse, pods], drives: [usb])
        XCTAssertEqual(issues.map(\.kind), [.hungApps, .bluetoothLow, .externalFull])
        XCTAssertTrue(issues[0].detail.hasPrefix("Pages is not responding"))
        XCTAssertTrue(issues[1].detail.contains("Mouse (10%)"))
        XCTAssertFalse(issues[1].detail.contains("AirPods"), "a low charging case alone does not count")
    }

    func testIgnoredIssuesComeBackWhenDue() throws {
        let s = SystemMonitor.Storage(name: "HD", total: 500_000_000_000, available: 5_000_000_000)
        let m = SystemMonitor.Memory(total: 1, active: 0, wired: 0, compressed: 0, available: 1, swapUsed: 0, pressureLevel: 4)
        let issues = SystemMonitor.issues(storage: s, memory: m, trashSize: nil, trashedApps: 0)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var ignored = SystemMonitor.IgnoredIssues()
        ignored.ignore(.lowDiskSpace, .day, now: now)
        ignored.ignore(.heavyMemory, .forever, now: now)
        XCTAssertEqual(ignored.visible(issues, now: now).count, 0)
        XCTAssertEqual(ignored.visible(issues, now: now.addingTimeInterval(86_401)).map(\.kind), [.lowDiskSpace])

        let cal = Calendar(identifier: .gregorian)
        let tomorrow = SystemMonitor.IgnoreOption.untilTomorrow.until(from: now, calendar: cal)
        XCTAssertEqual(tomorrow, cal.startOfDay(for: now.addingTimeInterval(86_400)))

        let d = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        ignored.save(d)
        XCTAssertEqual(SystemMonitor.IgnoredIssues.load(d), ignored)
    }

    func testMetricSeverities() {
        func mem(_ level: Int, swap: Int64 = 0) -> SystemMonitor.Memory {
            .init(total: 16_000_000_000, active: 0, wired: 0, compressed: 0, available: 1, swapUsed: swap, pressureLevel: level)
        }
        XCTAssertEqual([1, 2, 4].map { Metric.memoryPressure(mem($0)).severity }, [.normal, .warning, .critical])
        XCTAssertEqual(Metric.swap(mem(1, swap: 5_000_000_000)).severity, .warning)
        XCTAssertEqual(Metric.uptime(6 * 86_400).severity, .normal)
        XCTAssertEqual(Metric.uptime(8 * 86_400).severity, .warning)
        XCTAssertEqual(Metric.uptime(8 * 86_400 + 3 * 3600).value, "8d 3h")
        XCTAssertEqual([100, 85, 75, 60].map { Metric.batteryHealth($0).severity }, [.normal, .normal, .warning, .critical])
        XCTAssertEqual(Metric.batteryHealth(85).detail, "Your battery is in good condition, but already lost some capacity.")
        XCTAssertEqual(Metric.batteryTemperature(42).severity, .warning)
        XCTAssertEqual(Metric.driveHealth(.failing).severity, .critical)
    }

    func testNetworkSecurityRatings() {
        XCTAssertEqual(SystemMonitor.WiFiSecurity(coreWLAN: 0)?.rating, .open)
        XCTAssertEqual(SystemMonitor.WiFiSecurity(coreWLAN: 1)?.rating, .weak)
        XCTAssertEqual(SystemMonitor.WiFiSecurity(coreWLAN: 4)?.rating, .good)
        XCTAssertEqual(SystemMonitor.WiFiSecurity(coreWLAN: 11)?.rating, .strong)
        XCTAssertNil(SystemMonitor.WiFiSecurity(coreWLAN: Int.max), "kCWSecurityUnknown")

        let open = SystemMonitor.NetworkInfo(kind: .wifi, interface: "en0", name: nil, security: .init(coreWLAN: 0))
        XCTAssertEqual(Metric.networkSecurity(open)?.severity, .critical)
        let wpa3 = SystemMonitor.NetworkInfo(kind: .wifi, interface: "en0", name: "Home", security: .init(coreWLAN: 11))
        XCTAssertEqual(Metric.networkSecurity(wpa3)?.detail, "Your network security settings are rated as Strong (WPA3 Personal). You’re good!")
        let wired = SystemMonitor.NetworkInfo(kind: .wired, interface: "en5", name: nil, security: nil)
        XCTAssertEqual(Metric.networkSecurity(wired)?.value, "Strong")
        XCTAssertNil(Metric.networkSecurity(.init(kind: .wifi, interface: "en0", name: nil, security: nil)))
    }

    func testSpeedTestLegend() {
        let mbit = 1_000_000.0 / 8
        XCTAssertEqual(SystemMonitor.goodFor(download: 0.2 * mbit, upload: 0.1 * mbit), [])
        XCTAssertEqual(SystemMonitor.goodFor(download: 3 * mbit, upload: 1 * mbit), ["Messaging", "Audio calls", "Music streaming"])
        XCTAssertEqual(SystemMonitor.goodFor(download: 100 * mbit, upload: 20 * mbit).count, 6)
    }

    func testBatteryChartStatus() {
        func battery(charging: Bool, plugged: Bool, charged: Bool) -> SystemMonitor.Battery {
            .init(percent: 50, isCharging: charging, isPluggedIn: plugged, isCharged: charged, minutesRemaining: 135, minutesToFull: 40,
                  cycleCount: nil, healthPercent: nil, temperature: nil)
        }
        XCTAssertEqual(battery(charging: true, plugged: true, charged: false).chartStatus.detail, "40 min until full")
        XCTAssertEqual(battery(charging: false, plugged: false, charged: false).chartStatus.detail, "About 2 h 15 min until empty")
        XCTAssertEqual(battery(charging: false, plugged: true, charged: true).chartStatus.title, "Fully Charged")
    }

    func testNetworkCountersAre64Bit() {
        let counters = SystemMonitor.interfaceCounters()
        XCTAssertTrue(counters.contains { $0.name == "lo0" }, "the loopback interface is always listed")
        XCTAssertTrue(counters.contains { $0.name.hasPrefix("en") }, "interfaces after the first are read too")
        _ = SystemMonitor.network()
        let n = SystemMonitor.network()
        XCTAssertGreaterThanOrEqual(n.download, 0)
        XCTAssertGreaterThanOrEqual(n.received, 0)
    }

    func testBubblePackingDoesNotOverlap() {
        let b = SpaceLens.pack([100, 80, 50, 50, 20, 10, 5], radius: 200)
        XCTAssertEqual(b.count, 7)
        for i in b.indices { for j in b.indices where j > i {
            XCTAssertGreaterThanOrEqual(hypot(b[i].x - b[j].x, b[i].y - b[j].y), b[i].r + b[j].r - 0.001)
        } }
        XCTAssertLessThanOrEqual(b.map { hypot($0.x, $0.y) + $0.r }.max()!, 200.001)
    }

    func testIgnoreListHidesItemsAcrossGroups() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let a = ResultItem(id: "/a", title: "a", action: .open(URL(fileURLWithPath: "/a")))
        let b = ResultItem(id: "/b", title: "b", action: .open(URL(fileURLWithPath: "/b")))
        let cache = ResultGroup(id: "user-cache", title: "Cache", description: "", symbol: "", items: [a, b])
        IgnoreList.add([cache.items[0]], defaults: d)
        IgnoreList.add([cache.items[0]], defaults: d)
        XCTAssertEqual(IgnoreList.entries(defaults: d).count, 1)
        XCTAssertEqual(IgnoreList.entries(defaults: d)[0].section, .systemJunk)
        // Smart Care regroups the same item under another group: it is still hidden, and emptied groups stay.
        let smartCare = ResultGroup(id: "cleanup", title: "Cleanup", description: "", symbol: "", items: [cache.items[0]])
        let out = IgnoreList.apply([cache, smartCare], defaults: d)
        XCTAssertEqual(out.map { $0.items.map(\.id) }, [["/b"], []])
    }

    func testIgnoreListResetBySection() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let dup = ResultGroup(id: "duplicates", title: "", description: "", symbol: "",
                              items: [ResultItem(id: "/d", title: "d", action: .open(URL(fileURLWithPath: "/d")))])
        let upd = ResultGroup(id: "updates", title: "", description: "", symbol: "",
                              items: [ResultItem(id: "update:/u", title: "u", action: .open(URL(fileURLWithPath: "/u")))])
        IgnoreList.add(dup.items + upd.items, defaults: d)
        IgnoreList.reset(.duplicates, defaults: d)
        XCTAssertEqual(IgnoreList.entries(defaults: d).map(\.id), ["update:/u"])
        IgnoreList.remove(["update:/u"], defaults: d)
        XCTAssertTrue(IgnoreList.entries(defaults: d).isEmpty)
        IgnoreList.add(dup.items, defaults: d)
        IgnoreList.reset(defaults: d)
        XCTAssertFalse(IgnoreList.contains("/d", defaults: d))
    }

    func testAppTerminatorMatchesBundleIDAndNameLocations() {
        let slack = AppTerminator.App(pid: 1, name: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                      bundleURL: URL(fileURLWithPath: "/Applications/Slack.app"))
        let notes = AppTerminator.App(pid: 2, name: "Notes", bundleID: "com.apple.Notes", bundleURL: nil)
        let related = { (paths: [String]) in AppTerminator.related(to: paths.map { URL(fileURLWithPath: $0) }, among: [slack, notes]).map(\.pid) }
        XCTAssertEqual(related(["/Applications/Slack.app"]), [1])
        XCTAssertEqual(related(["/Users/me/Library/Caches/com.tinyspeck.slackmacgap"]), [1])
        XCTAssertEqual(related(["/Users/me/Library/Preferences/com.tinyspeck.slackmacgap.plist"]), [1])
        XCTAssertEqual(related(["/Users/me/Library/Group Containers/ABCD1234.com.tinyspeck.slackmacgap"]), [1])
        XCTAssertEqual(related(["/Users/me/Library/Application Support/Slack"]), [1])
        // A name outside Library, or a longer ID that only starts the same, is not a match.
        XCTAssertEqual(related(["/Users/me/Documents/Slack", "/Users/me/Library/Caches/com.tinyspeck.slackmacgapx"]), [])
    }

    func testAppTerminatorOnlyConsidersRemovals() {
        let u = URL(fileURLWithPath: "/Applications/Slack.app")
        let items = [ResultItem(title: "a", url: u, action: .open(u)), ResultItem(title: "b", url: u, action: .trash(u)),
                     ResultItem(title: "c", action: .run(Command("/usr/bin/true"), admin: false))]
        XCTAssertEqual(AppTerminator.removedURLs(items), [u])
    }

    /// A minimal bundle with an Info.plist, enough for `Bundle(url:)`.
    func bundle(_ path: String, id: String, executable: String? = nil) throws -> URL {
        let u = tmp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
        if let executable { info["CFBundleExecutable"] = executable }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: u.appendingPathComponent("Contents/Info.plist"))
        return u
    }

    func testUninstallerFindsLeftoversByIDAndName() throws {
        let home = tmp.appendingPathComponent("home"), sys = tmp.appendingPathComponent("sys")
        _ = try bundle("home/Applications/Super Notes.app", id: "com.acme.SuperNotes", executable: "SuperNotes")
        let app = Uninstaller.installedApps(home: home, system: sys).first { $0.name == "Super Notes" }!
        for f in ["Library/Application Support/Super Notes/db.sqlite", "Library/Caches/com.acme.SuperNotes/c.bin",
                  "Library/Preferences/com.acme.SuperNotes.plist", "Library/Preferences/com.acme.SuperNotes.helper.plist",
                  "Library/Preferences/ByHost/com.acme.SuperNotes.1234-ABCD.plist",
                  "Library/Group Containers/TEAM123.com.acme.SuperNotes.shared/g.bin",
                  "Library/Logs/DiagnosticReports/SuperNotes-2026-10-01-120000.ips",
                  "Library/Application Support/Supernote Lite/other.bin", "Library/Caches/com.acme.SuperNotesPro/x.bin",
                  "Library/Caches/Notes/x.bin", "Library/Caches/acme/SuperNotes2026.1/x.bin", "Library/Caches/acme/Other/x.bin"] {
            _ = try write("home/" + f, 10)
        }
        _ = try write("sys/Library/PrivilegedHelperTools/com.acme.SuperNotes.helper", 10)
        _ = try write("sys/var/db/receipts/com.acme.SuperNotes.pkg.plist", 10)
        let agent = try write("home/Library/LaunchAgents/com.acme.updater.plist", 0)
        try (["Label": "com.acme.updater", "Program": app.url.path + "/Contents/MacOS/Updater"] as NSDictionary).write(to: agent)

        let found = Uninstaller.leftovers(for: app, home: home, system: sys)
        // Listings resolve /var to /private/var, so paths are compared from the resolved temporary folder.
        let base = tmp.resolvingSymlinksInPath().path + "/"
        let rel = { (u: URL) in u.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") }
        XCTAssertEqual(Set(found.map { rel($0.url) }), [
            "home/Library/Application Support/Super Notes", "home/Library/Caches/com.acme.SuperNotes",
            "home/Library/Caches/acme/SuperNotes2026.1", "home/Library/Preferences/com.acme.SuperNotes.plist", "home/Library/Preferences/com.acme.SuperNotes.helper.plist",
            "home/Library/Preferences/ByHost/com.acme.SuperNotes.1234-ABCD.plist",
            "home/Library/Group Containers/TEAM123.com.acme.SuperNotes.shared",
            "home/Library/Logs/DiagnosticReports/SuperNotes-2026-10-01-120000.ips",
            "home/Library/LaunchAgents/com.acme.updater.plist",
            "sys/Library/PrivilegedHelperTools/com.acme.SuperNotes.helper",
            "sys/var/db/receipts/com.acme.SuperNotes.pkg.plist",
        ])
        let byURL = Dictionary(uniqueKeysWithValues: found.map { (rel($0.url), $0) })
        if case .removeLaunchItem(_, admin: false) = byURL["home/Library/LaunchAgents/com.acme.updater.plist"]?.action {} else { XCTFail("user agent") }
        XCTAssertEqual(byURL["sys/Library/PrivilegedHelperTools/com.acme.SuperNotes.helper"]?.kind, .binaries)
        if case .adminDelete = byURL["sys/Library/PrivilegedHelperTools/com.acme.SuperNotes.helper"]?.action {} else { XCTFail("system file needs admin") }
        XCTAssertEqual(byURL["sys/var/db/receipts/com.acme.SuperNotes.pkg.plist"]?.action,
                       .run(Command("/usr/sbin/pkgutil", "--forget", "com.acme.SuperNotes.pkg"), admin: true))
    }

    func testInstalledAppsSourcesAndFilters() throws {
        let home = tmp.appendingPathComponent("home"), sys = tmp.appendingPathComponent("sys")
        _ = try bundle("sys/Applications/Shop.app", id: "com.acme.shop")
        _ = try write("sys/Applications/Shop.app/Contents/_MASReceipt/receipt", 1)
        _ = try bundle("sys/Applications/Setapp/Tool.app", id: "com.acme.tool")
        _ = try bundle("home/Library/Application Support/Steam/steamapps/common/Game/Game.app", id: "com.acme.game")
        _ = try bundle("home/Library/Audio/Plug-Ins/VST3/Synth.vst3", id: "com.acme.synth")
        _ = try bundle("sys/Applications/Word.app", id: "com.microsoft.Word")
        let apps = Dictionary(uniqueKeysWithValues: Uninstaller.installedApps(home: home, system: sys).map { ($0.name, $0) })
        XCTAssertEqual(apps["Shop"]?.store, .appStore)
        XCTAssertEqual(apps["Tool"]?.store, .setapp)
        XCTAssertEqual(apps["Game"]?.store, .steam)
        XCTAssertEqual(apps["Synth"]?.kind, .audioPlugin)
        XCTAssertEqual(apps["Word"]?.vendor, .microsoft)
        var old = apps["Shop"]!
        old.lastUsed = Date(timeIntervalSinceNow: -200 * 86_400)
        XCTAssertTrue(old.isUnused())
        XCTAssertFalse(apps["Tool"]!.isUnused())
    }

    func testAppStoreLookupParsing() {
        let json = """
        {"resultCount": 3, "results": [
          {"trackId": 1402042596, "bundleId": "com.betafish.adblock-mac", "version": "4.0.7", "fileSizeBytes": "28982746"},
          {"trackId": 497799835, "bundleId": "com.apple.dt.Xcode", "version": "27.2"},
          {"bundleId": "broken.entry"}]}
        """
        let entries = AppStoreLookup.parse(Data(json.utf8))
        XCTAssertEqual(entries.map(\.id), [1402042596, 497799835])
        XCTAssertEqual(entries[0].size, 28_982_746)
        XCTAssertNil(entries[1].size)
        XCTAssertEqual(entries[0].storePage?.absoluteString, "macappstore://apps.apple.com/app/id1402042596")
        XCTAssertTrue(AppStoreLookup.parse(Data("not json".utf8)).isEmpty)
    }

    func testScanSettingsRoundTripAndDefaults() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertEqual(ScanSettings.load(defaults: d), ScanSettings())
        var s = ScanSettings()
        s.disabledSmartCare = ["clutter"]; s.disabledCleanup = ["trash"]
        s.save(defaults: d)
        XCTAssertEqual(ScanSettings.load(defaults: d), s)
        XCTAssertFalse(s.scansSmartCare("clutter")); XCTAssertTrue(s.scansCleanup("mail"))
        // A stored value from an older build without one of the keys still loads.
        d.set(Data(#"{"disabledCleanup":["mail"]}"#.utf8), forKey: ScanSettings.key)
        XCTAssertEqual(ScanSettings.load(defaults: d).disabledCleanup, ["mail"])
    }

    func testEnginesSkipDisabledModulesAndCategories() async {
        var s = ScanSettings()
        s.disabledSmartCare = Set(ScanSettings.smartCareModules.map(\.id))
        let smartCare = await SmartCareEngine(settings: s).scan { _ in }
        XCTAssertTrue(smartCare.isEmpty)
        s.disabledCleanup = Set(CleanupEngine.categories.map(\.id)).subtracting(["deleted-users"])
        let cleanup = await CleanupEngine(settings: s).scan { _ in }
        XCTAssertTrue(cleanup.allSatisfy { $0.id == "deleted-users" })
    }
}

extension TidyCoreTests {
    func testAssistantRecommendations() throws {
        let gone = "/nonexistent/Old.app"
        let here = FileManager.default.temporaryDirectory.path
        let facts = AppFacts(updates: ["Notes Plus"], unused: [here, gone])
        XCTAssertEqual(facts.unusedCount, 1)

        let recs = MacHealth.assistant(uptime: 9 * 86_400, driveHealth: .failing, apps: facts)
        XCTAssertEqual(recs.map(\.id), ["drive", "updates", "unused-apps", "restart"])
        XCTAssertTrue(recs[0].severe)
        XCTAssertTrue(recs[1].detail.hasPrefix("Notes Plus is ready"))
        XCTAssertTrue(recs[3].detail.contains("9 days"))

        let two = AppFacts(updates: ["A", "B"], unused: [gone])
        let fewer = MacHealth.assistant(uptime: 2 * 86_400, driveHealth: .good, apps: two)
        XCTAssertEqual(fewer.map(\.id), ["updates"])
        XCTAssertTrue(fewer[0].detail.hasPrefix("2 apps are"))
        XCTAssertTrue(MacHealth.assistant(uptime: 0, driveHealth: nil, apps: nil).isEmpty)
    }

    func testSkippedRecommendationsComeBackTomorrow() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TidyMacTests.skips"))
        defer { defaults.removePersistentDomain(forName: "TidyMacTests.skips") }
        let recs = MacHealth.assistant(uptime: 9 * 86_400, driveHealth: .failing, apps: nil)
        let now = Date()
        var skipped = SkippedRecommendations()
        skipped.skip(["restart"], now: now)
        skipped.save(defaults: defaults)

        let loaded = SkippedRecommendations.load(defaults: defaults)
        XCTAssertEqual(loaded.visible(recs, now: now).map(\.id), ["drive"])
        XCTAssertEqual(loaded.visible(recs, now: now.addingTimeInterval(86_400)).map(\.id), ["drive", "restart"])
        // A skipped severe item no longer drags the state down.
        XCTAssertEqual(MacHealth(recommendations: loaded.visible(recs, now: now)).state, .requiresAttention)
        skipped.skip(["drive"], now: now)
        XCTAssertEqual(MacHealth(recommendations: skipped.visible(recs, now: now)).state, .excellent)
    }
}

extension TidyCoreTests {
    private var roomyDisk: SystemMonitor.Storage { .init(name: "HD", total: 500_000_000_000, available: 200_000_000_000) }
    private var calmMemory: SystemMonitor.Memory {
        .init(total: 16_000_000_000, active: 0, wired: 0, compressed: 0, available: 8_000_000_000, swapUsed: 0, pressureLevel: 1)
    }

    func testTrashedAppsAreAnnouncedOnceAfterTheFirstLook() {
        var state = HealthAlerts.State()
        let t0 = Date()
        func look(_ apps: [String]?, at t: TimeInterval, settings: HealthAlerts.Settings = .init()) -> [String] {
            HealthAlerts.evaluate(.init(storage: roomyDisk, memory: calmMemory, trashedApps: apps), settings: settings, state: &state, now: t0 + t).map(\.key)
        }
        XCTAssertTrue(look(["Old"], at: 0).isEmpty, "the first look only learns what is there")
        XCTAssertEqual(look(["New", "Old"], at: 60), ["trashedApp:New"])
        XCTAssertTrue(look(["New", "Old"], at: 120).isEmpty)
        XCTAssertTrue(look(nil, at: 180).isEmpty, "no access keeps the known list")
        var off = HealthAlerts.Settings(); off.trashedApps = false
        XCTAssertTrue(look(["Another", "New", "Old"], at: 240, settings: off).isEmpty)
        XCTAssertTrue(look(["Another", "New", "Old"], at: 300).isEmpty, "apps trashed while off are not announced later")
    }

    func testSmartCareReminderHungAppsAndChrome() {
        var state = HealthAlerts.State()
        let now = Date()
        var s = HealthAlerts.Settings(); s.smartCareInterval = 3
        let r = HealthAlerts.Readings(storage: roomyDisk, memory: calmMemory, hungApps: ["Pages"], chromeMemory: 5_000_000_000,
                                      lastCleanup: now.addingTimeInterval(-4 * 86_400))
        let alerts = HealthAlerts.evaluate(r, settings: s, state: &state, now: now)
        XCTAssertEqual(alerts.map(\.kind), [.smartCare, .hungApps, .heavyChrome])
        XCTAssertTrue(alerts[0].body.contains("4 days"))
        XCTAssertTrue(alerts[1].body.hasPrefix("Pages is not responding"))
        // The reminder comes back after another interval; hung apps and Chrome after six hours.
        XCTAssertTrue(HealthAlerts.evaluate(r, settings: s, state: &state, now: now + 3_600).isEmpty)
        XCTAssertEqual(HealthAlerts.evaluate(r, settings: s, state: &state, now: now + 7 * 3_600).map(\.kind), [.hungApps, .heavyChrome])
        XCTAssertEqual(HealthAlerts.evaluate(r, settings: s, state: &state, now: now + 3 * 86_400).map(\.kind), [.smartCare, .hungApps, .heavyChrome])

        state = HealthAlerts.State(); s.smartCareInterval = 7
        let light = HealthAlerts.Readings(storage: roomyDisk, memory: calmMemory, chromeMemory: 3_000_000_000,
                                          lastCleanup: now.addingTimeInterval(-4 * 86_400))
        XCTAssertTrue(HealthAlerts.evaluate(light, settings: s, state: &state, now: now).isEmpty, "4 GB limit on 16 GB, weekly reminder")
        XCTAssertEqual(HealthAlerts.chromeLimit(totalMemory: 4_000_000_000), 2_000_000_000)
        let consumers = SystemMonitor.parseConsumers("""
          1 1000000 1.0 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
          2 2000000 1.0 /Applications/Google Chrome Dev.app/Contents/MacOS/Google Chrome Dev
          3 500000 1.0 /Applications/Safari.app/Contents/MacOS/Safari
        """)
        XCTAssertEqual(HealthAlerts.chromeMemory(consumers), 3_000_000 * 1024)
        XCTAssertNil(HealthAlerts.chromeMemory([]))
    }

    func testGeneralSettingsDefaultsAndReduceMotion() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "TidyMacTests.general"))
        defer { d.removePersistentDomain(forName: "TidyMacTests.general") }
        XCTAssertTrue(GeneralSettings.playsSounds(d))
        XCTAssertTrue(GeneralSettings.keepsDockIcon(d))
        XCTAssertTrue(GeneralSettings.showsAssistant(d))
        XCTAssertFalse(GeneralSettings.cleansOnEject(d))
        XCTAssertTrue(GeneralSettings.reducesMotion(system: true, d))
        XCTAssertFalse(GeneralSettings.reducesMotion(system: false, d))
        d.set("Enabled", forKey: GeneralSettings.reduceMotionKey)
        XCTAssertTrue(GeneralSettings.reducesMotion(system: false, d))
        d.set("Disabled", forKey: GeneralSettings.reduceMotionKey)
        XCTAssertFalse(GeneralSettings.reducesMotion(system: true, d))
        d.set(false, forKey: GeneralSettings.soundsKey)
        XCTAssertFalse(GeneralSettings.playsSounds(d))
    }

    func testDriveTrashAndTrashedAppsListing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent(".Trashes/\(getuid())")
        try FileManager.default.createDirectory(at: trash.appendingPathComponent("Old.app"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: trash.appendingPathComponent("notes.txt"))
        let drive = SystemMonitor.Drive(url: root, name: "USB", total: 1, available: 1, format: nil, isDiskImage: false)
        let items = SystemMonitor.driveTrash(drive)
        XCTAssertEqual(Set(items.map(\.title)), ["Old.app", "notes.txt"])
        XCTAssertTrue(items.allSatisfy { $0.category == "trash" && $0.subtitle == "USB" })
        if case .delete = items[0].action {} else { XCTFail("drive trash items are deleted for good") }
        XCTAssertEqual(SystemMonitor.trashedApps(trash: trash), ["Old"])
        XCTAssertNil(SystemMonitor.trashedApps(trash: root.appendingPathComponent("missing")))
    }
}

extension TidyCoreTests {
    func testSpaceLensProtection() {
        let home = URL(fileURLWithPath: "/Users/someone")
        func p(_ path: String) -> SpaceLens.Protection { SpaceLens.protection(of: URL(fileURLWithPath: path), home: home) }
        XCTAssertEqual(p("/System"), .essential)
        XCTAssertEqual(p("/System/Library/Fonts"), .essential)
        XCTAssertEqual(p("/usr/bin"), .essential)
        XCTAssertEqual(p("/usr/local/lib"), .none)
        XCTAssertEqual(p("/Users/someone/Documents"), .essential)
        XCTAssertEqual(p("/Users/someone/Documents/Old Project"), .none)
        XCTAssertEqual(p("/Users/someone/Library"), .essential)
        XCTAssertEqual(p("/Users/someone/Library/Keychains"), .essential)
        XCTAssertEqual(p("/Users/someone/Library/Caches"), .systemFolder)
        XCTAssertEqual(p("/Users/someone/Library/Caches/com.example.app"), .none)
        XCTAssertEqual(p("/Users/someone/Library/Application Support/Old App"), .none)
        XCTAssertEqual(p("/Users/someone/Projects"), .none)
        XCTAssertTrue(SpaceLens.isInCloud(URL(fileURLWithPath: "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/a.txt")))
        XCTAssertGreaterThanOrEqual(SpaceLens.purgeableSpace() ?? 0, 0)
    }

    func testRemovalLogKeepsNewestFirst() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "TidyMacTests.removalLog"))
        defer { d.removePersistentDomain(forName: "TidyMacTests.removalLog") }
        let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b")
        var first = ActionReport()
        first.succeeded = [ResultItem(title: "a", size: 10, url: a, action: .trash(a))]
        RemovalLog.record(first, date: Date(timeIntervalSince1970: 1), defaults: d)
        var second = ActionReport()
        second.failed = [(ResultItem(title: "b", size: 20, url: b, action: .trash(b)), "In use")]
        RemovalLog.record(second, date: Date(timeIntervalSince1970: 2), defaults: d)
        let log = RemovalLog.entries(defaults: d)
        XCTAssertEqual(log.map(\.path), ["/tmp/b", "/tmp/a"])
        XCTAssertEqual(log[0].error, "In use")
        XCTAssertNil(log[1].error)
        RemovalLog.clear(defaults: d)
        XCTAssertTrue(RemovalLog.entries(defaults: d).isEmpty)
    }
}

extension TidyCoreTests {
    func testUninstallLinkRoundTrip() {
        let app = URL(fileURLWithPath: "/Applications/Super Notes.app")
        let link = Uninstaller.uninstallURL(for: app)
        XCTAssertEqual(link.scheme, "tidymac")
        XCTAssertEqual(link.host, "uninstall")
        XCTAssertEqual(Uninstaller.appURL(fromUninstallURL: link)?.path, app.path)
        XCTAssertNil(Uninstaller.appURL(fromUninstallURL: URL(string: "tidymac://open/applications")!))
        XCTAssertNil(Uninstaller.appURL(fromUninstallURL: URL(string: "tidymac://uninstall?path=/etc/passwd")!))
        XCTAssertNil(Uninstaller.appURL(fromUninstallURL: URL(string: "tidymac://uninstall?path=relative/App.app")!))
        XCTAssertNil(Uninstaller.appURL(fromUninstallURL: URL(string: "other://uninstall?path=/Applications/A.app")!))
    }

    func testAppAtAnyLocationAndMoveToApplications() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads"), apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let bundle = downloads.appendingPathComponent("Tidy Test.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.test.tidy"], format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(Uninstaller.app(at: bundle)?.bundleID, "dev.test.tidy")
        XCTAssertNil(Uninstaller.app(at: downloads))

        let d = try XCTUnwrap(UserDefaults(suiteName: "TidyMacTests.move"))
        defer { d.removePersistentDomain(forName: "TidyMacTests.move") }
        XCTAssertTrue(MoveToApplications.shouldOffer(bundle: bundle, home: root, defaults: d))
        XCTAssertFalse(MoveToApplications.shouldOffer(bundle: URL(fileURLWithPath: "/Applications/TidyMac.app"), home: root, defaults: d))
        XCTAssertFalse(MoveToApplications.shouldOffer(bundle: apps.appendingPathComponent("TidyMac.app"), home: root, defaults: d))
        XCTAssertFalse(MoveToApplications.shouldOffer(bundle: downloads.appendingPathComponent("tidymac"), home: root, defaults: d))
        d.set(true, forKey: MoveToApplications.declinedKey)
        XCTAssertFalse(MoveToApplications.shouldOffer(bundle: bundle, home: root, defaults: d))

        // An older copy is replaced and the original leaves Downloads.
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Tidy Test.app"), withIntermediateDirectories: true)
        var trashed: [String] = []
        let moved = try MoveToApplications.move(bundle, to: apps) { u in trashed.append(u.lastPathComponent + "@" + u.deletingLastPathComponent().lastPathComponent)
            try FileManager.default.removeItem(at: u) }
        XCTAssertEqual(moved, apps.appendingPathComponent("Tidy Test.app"))
        XCTAssertEqual(Bundle(url: moved)?.bundleIdentifier, "dev.test.tidy")
        XCTAssertEqual(trashed, ["Tidy Test.app@Applications", "Tidy Test.app@Downloads"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
    }

    func testScheduledAutomationRunsOncePerSlotAndCatchesUp() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))! }
        // Mondays at 10:00; 2 November 2026 is a Monday.
        let rule = Automations.Rule(name: "Weekly", trigger: .schedule(.init(frequency: .weekly, hour: 10, weekday: 2)), categories: ["user-cache"], created: at(1, 12))
        var state = Automations.State()
        func due(_ now: Date) -> Int { Automations.due([rule], .init(), state: &state, now: now, calendar: cal).count }
        XCTAssertEqual(due(at(2, 9, 59)), 0)
        XCTAssertEqual(due(at(2, 10)), 1)
        XCTAssertEqual(due(at(2, 10, 1)), 0)
        // The 9 November slot was missed while the Mac was off.
        XCTAssertEqual(due(at(10, 8)), 1)
        XCTAssertEqual(due(at(10, 12)), 0)
        // A rule added after this week's slot waits for the next one.
        var late = rule; late.id = UUID(); late.created = at(2, 11)
        XCTAssertTrue(Automations.due([late], .init(), state: &state, now: at(2, 11, 1), calendar: cal).isEmpty)
        XCTAssertEqual(Automations.Schedule(frequency: .monthly, hour: 3, day: 15).previous(at(20, 0), calendar: cal), at(15, 3))
    }

    func testConditionAutomationRunsWhenItAppearsAndRearms() {
        var rule = Automations.Rule(name: "Low", trigger: .freeSpaceBelow(10_000_000_000), categories: ["user-cache"])
        var state = Automations.State()
        func due(_ free: Int64?) -> Int { Automations.due([rule], .init(freeSpace: free), state: &state).count }
        XCTAssertEqual(due(5_000_000_000), 1)
        XCTAssertEqual(due(4_000_000_000), 0)
        // An unknown reading changes nothing.
        XCTAssertEqual(due(nil), 0)
        XCTAssertEqual(due(5_000_000_000), 0)
        XCTAssertEqual(due(20_000_000_000), 0)
        XCTAssertEqual(due(5_000_000_000), 1)
        // Turned off, it does not run; turned back on while the condition holds, it does.
        rule.enabled = false
        XCTAssertEqual(due(5_000_000_000), 0)
        rule.enabled = true
        XCTAssertEqual(due(5_000_000_000), 1)
    }

    func testAutomationsSkipWhatNeedsAnAdministrator() throws {
        let u = try write("x.bin", 10)
        XCTAssertTrue(Automations.runsUnattended(.trash(u)))
        XCTAssertTrue(Automations.runsUnattended(.delete(u)))
        XCTAssertFalse(Automations.runsUnattended(.delete(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))))
        XCTAssertFalse(Automations.runsUnattended(.adminDelete(u)))
        XCTAssertFalse(Automations.runsUnattended(.run(Command("/usr/sbin/purge"), admin: true)))
        XCTAssertTrue(Automations.runsUnattended(.run(Command("/usr/bin/true"), admin: false)))
    }

    func testAutomationRulesRoundTrip() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let rules = [Automations.Rule(name: "A", trigger: .schedule(.init(frequency: .daily, hour: 8)), categories: ["trash"], mode: .auto),
                     Automations.Rule(name: "B", trigger: .trashOver(2_000_000_000), categories: ["trash"]),
                     Automations.Rule(name: "C", trigger: .driveConnected, categories: ["trash"])]
        Automations.save(rules, d)
        XCTAssertEqual(Automations.load(d), rules)
        XCTAssertEqual(Automations.onDriveConnected(rules).map(\.name), ["C"])
        XCTAssertTrue(Automations.needs(rules).trash)
        XCTAssertFalse(Automations.needs(rules).drives)
    }
}
