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
                     ResultItem(title: "c", action: .shell("true", admin: false))]
        XCTAssertEqual(AppTerminator.removedURLs(items), [u])
    }
}
