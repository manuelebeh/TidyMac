import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Live readings for the menu bar's monitors
/// (Storage, Memory, Battery, CPU, Network) and its "Today's Recommendation" issues.
public enum SystemMonitor {

    // MARK: Storage

    public struct Storage: Sendable { public let name: String; public let total: Int64; public let available: Int64 }

    public static func storage() -> Storage {
        let root = URL(fileURLWithPath: "/")
        let v = try? root.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return Storage(name: v?.volumeName ?? String(localized: "Macintosh HD"), total: Int64(v?.volumeTotalCapacity ?? 0),
                       available: v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: Memory

    public struct Memory: Sendable {
        public let total, active, wired, compressed, available, swapUsed: Int64
        /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
        public let pressureLevel: Int
        public var used: Int64 { total - available }
        public var pressure: String { pressureLevel >= 4 ? String(localized: "Critical") : pressureLevel >= 2 ? String(localized: "High") : String(localized: "Normal") }
    }

    public static func memory() -> Memory {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let page = Int64(vm_kernel_page_size)
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        let active = Int64(stats.active_count) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        // Same notion as Activity Monitor's "available": free + inactive + purgeable + speculative.
        let available = Int64(stats.free_count + stats.inactive_count + stats.purgeable_count + stats.speculative_count) * page

        var swap = xsw_usage(); var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var level: Int32 = 1; var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
        return Memory(total: total, active: active, wired: wired, compressed: compressed,
                      available: min(available, total), swapUsed: Int64(swap.xsu_used), pressureLevel: Int(level))
    }

    // MARK: CPU

    public struct CPU: Sendable { public let user, system, idle: Double; public let uptime: TimeInterval
        public var load: Double { user + system }
    }

    /// Previous tick counters, so each call reports load since the last call.
    nonisolated(unsafe) private static var lastTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private static let tickLock = NSLock()

    public static func cpu() -> CPU {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpus: natural_t = 0
        var t = (user: UInt64(0), system: UInt64(0), idle: UInt64(0), nice: UInt64(0))
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &infoCount) == KERN_SUCCESS, let info {
            for i in 0..<Int(cpus) {
                let base = Int(CPU_STATE_MAX) * i
                t.user += UInt64(info[base + Int(CPU_STATE_USER)])
                t.system += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
                t.idle += UInt64(info[base + Int(CPU_STATE_IDLE)])
                t.nice += UInt64(info[base + Int(CPU_STATE_NICE)])
            }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        tickLock.lock()
        let prev = lastTicks ?? (0, 0, 0, 0)
        lastTicks = t
        tickLock.unlock()
        let du = Double(t.user &- prev.user + t.nice &- prev.nice), ds = Double(t.system &- prev.system), di = Double(t.idle &- prev.idle)
        let sum = max(du + ds + di, 1)

        return CPU(user: du / sum, system: ds / sum, idle: di / sum, uptime: uptime())
    }

    public static func uptime() -> TimeInterval {
        var boot = timeval(); var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        return Date().timeIntervalSince1970 - TimeInterval(boot.tv_sec)
    }

    // MARK: Battery

    public struct Battery: Sendable {
        public let percent: Int
        public let isCharging, isPluggedIn, isCharged: Bool
        public let minutesRemaining: Int?
        public let minutesToFull: Int?
        public let cycleCount: Int?
        public let healthPercent: Int?
        public let temperature: Double?

        public var status: String {
            if isCharged { return String(localized: "Fully charged") }
            if isCharging { return String(localized: "Charging") }
            if isPluggedIn { return String(localized: "Not charging") }
            guard let m = minutesRemaining else { return String(localized: "Calculating…") }
            return String(localized: "\(m / 60):\(String(format: "%02d", m % 60)) remaining")
        }

        /// The battery chart's heading and subtitle.
        public var chartStatus: (title: String, detail: String?) {
            func time(_ m: Int) -> String { m >= 60 ? String(localized: "\(m / 60) h \(m % 60) min") : String(localized: "\(m) min") }
            if isCharged { return (String(localized: "Fully Charged"), String(localized: "You're running from a power adapter")) }
            if isCharging { return (String(localized: "Charging"), minutesToFull.map { String(localized: "\(time($0)) until full") }) }
            if isPluggedIn { return (String(localized: "Not Charging"), String(localized: "You're running from a power adapter")) }
            return (String(localized: "Discharging"), minutesRemaining.map { String(localized: "About \(time($0)) until empty") })
        }
    }

    /// nil on Macs without a battery.
    public static func battery() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0, max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let tte = d[kIOPSTimeToEmptyKey] as? Int, ttf = d[kIOPSTimeToFullChargeKey] as? Int
            let smart = smartBattery()
            // Recent Apple silicon Macs only publish the capacities inside the "BatteryData" dictionary.
            let data = smart["BatteryData"] as? [String: Any] ?? [:]
            func value(_ k: String) -> Int? { smart[k] as? Int ?? data[k] as? Int }
            var health: Int?
            if let m = value("AppleRawMaxCapacity") ?? value("NominalChargeCapacity"),
               let design = value("DesignCapacity"), design > 0 { health = min(100, m * 100 / design) }
            return Battery(percent: max > 0 ? cur * 100 / max : cur,
                           isCharging: d[kIOPSIsChargingKey] as? Bool ?? false,
                           isPluggedIn: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                           isCharged: d[kIOPSIsChargedKey] as? Bool ?? false,
                           minutesRemaining: (tte ?? -1) > 0 ? tte : nil, minutesToFull: (ttf ?? -1) > 0 ? ttf : nil,
                           cycleCount: smart["CycleCount"] as? Int, healthPercent: health,
                           temperature: (smart["Temperature"] as? Int).map { Double($0) / 100 })
        }
        return nil
    }

    static func smartBattery() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return props?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    // MARK: Recommendations

    public struct Issue: Identifiable, Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            case lowDiskSpace, trashSize, trashedApps, heavyMemory, hungApps, bluetoothLow, externalFull, screenCleaning
        }
        public var id: String { kind.rawValue }
        public let kind: Kind
        public let title: String
        public let detail: String
    }

    /// - Parameter hungApps: names of the apps the window server reports as not responding.
    public static func issues(storage: Storage, memory: Memory, trashSize: Int64?, trashedApps: Int, screenCleaningDue: Bool = false,
                              trashLimit: Int64 = 1_000_000_000, hungApps: [String] = [], bluetooth: [BluetoothDevice] = [],
                              drives: [Drive] = []) -> [Issue] {
        var out: [Issue] = []
        if storage.total > 0, storage.available < max(storage.total / 10, 15_000_000_000) {
            out.append(Issue(kind: .lowDiskSpace, title: String(localized: "You are running out of disk space!"),
                             detail: String(localized: "Only \(FileSize.format(storage.available)) left. Remove unneeded items to reclaim space.")))
        }
        if let t = trashSize, t > trashLimit {
            out.append(Issue(kind: .trashSize, title: String(localized: "It’s time to empty your Trash!"),
                             detail: String(localized: "Your Trash holds \(FileSize.format(t)).")))
        }
        if trashedApps > 0 {
            out.append(Issue(kind: .trashedApps, title: String(localized: "Uninstall applications correctly"),
                             detail: String(localized: "\(trashedApps) apps in the Trash may have left files behind.")))
        }
        if memory.pressureLevel >= 2 {
            out.append(Issue(kind: .heavyMemory, title: String(localized: "Heavy memory usage"),
                             detail: String(localized: "Memory pressure is \(memory.pressure.lowercased()). Quitting unused apps can help.")))
        }
        if !hungApps.isEmpty {
            out.append(Issue(kind: .hungApps, title: String(localized: "Non-responsive applications"),
                             detail: hungApps.count == 1
                                 ? String(localized: "\(hungApps[0]) is not responding. Force quit or wait until it responds.")
                                 : String(localized: "\(hungApps.joined(separator: ", ")) are not responding. Force quit or wait until they respond.")))
        }
        let low = bluetooth.filter { ($0.lowest ?? 100) <= HealthAlerts.bluetoothLowLevel }
        if !low.isEmpty {
            out.append(Issue(kind: .bluetoothLow, title: String(localized: "Time to juice up!"),
                             detail: String(localized: "Low on battery: \(low.map { "\($0.name) (\($0.lowest ?? 0)%)" }.joined(separator: ", ")). Connect to a charger before they shut down.")))
        }
        let full = drives.filter(\.almostFull)
        if !full.isEmpty {
            out.append(Issue(kind: .externalFull, title: String(localized: "Connected disk is almost full"),
                             detail: full.map { String(localized: "\($0.name): \(FileSize.format($0.available)) available") }.joined(separator: ", ") + "."))
        }
        if screenCleaningDue {
            out.append(Issue(kind: .screenCleaning, title: String(localized: "Your screen deserves some care"),
                             detail: String(localized: "Keep your Mac clean inside and out with Screen Cleaning Mode.")))
        }
        return out
    }

    /// The Ignore menu on the menu's issues.
    public enum IgnoreOption: String, CaseIterable, Sendable {
        case untilTomorrow, day, threeDays, week, forever

        public var title: String {
            switch self {
            case .untilTomorrow: String(localized: "Until tomorrow")
            case .day: String(localized: "For a day")
            case .threeDays: String(localized: "For 3 days")
            case .week: String(localized: "For a week")
            case .forever: String(localized: "Forever")
            }
        }

        public func until(from now: Date, calendar: Calendar = .current) -> Date {
            switch self {
            case .untilTomorrow: calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
            case .day: now.addingTimeInterval(86_400)
            case .threeDays: now.addingTimeInterval(3 * 86_400)
            case .week: now.addingTimeInterval(7 * 86_400)
            case .forever: .distantFuture
            }
        }
    }

    /// Issues the user chose to ignore, by kind, with the date they come back.
    public struct IgnoredIssues: Codable, Equatable, Sendable {
        public var until: [String: Date] = [:]
        public init() {}

        public static let defaultsKey = "TidyMac.ignoredIssues"
        public static func load(_ d: UserDefaults = .standard) -> IgnoredIssues {
            d.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(IgnoredIssues.self, from: $0) } ?? IgnoredIssues()
        }
        public func save(_ d: UserDefaults = .standard) {
            if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
        }

        public mutating func ignore(_ kind: Issue.Kind, _ option: IgnoreOption, now: Date = Date()) {
            until[kind.rawValue] = option.until(from: now)
        }

        public func visible(_ issues: [Issue], now: Date = Date()) -> [Issue] {
            issues.filter { (until[$0.kind.rawValue] ?? .distantPast) <= now }
        }
    }

    /// Trash contents need Full Disk Access; without it this returns nil rather than prompting.
    public static func trash() -> (size: Int64, apps: Int)? {
        let t = Paths.home(".Trash")
        guard let kids = try? FileManager.default.contentsOfDirectory(at: t, includingPropertiesForKeys: nil) else { return nil }
        return (kids.reduce(0) { $0 + FileSize.allocated($1) }, kids.filter { $0.pathExtension == "app" }.count)
    }
}

extension SystemMonitor {
    /// Names of the apps in the Trash, without walking them; nil without Full Disk Access.
    public static func trashedApps(trash: URL = Paths.home(".Trash")) -> [String]? {
        guard let kids = try? FileManager.default.contentsOfDirectory(atPath: trash.path) else { return nil }
        return kids.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }.sorted()
    }

    /// The user's Trash on an external drive (`.Trashes/<uid>`), as items to delete for good.
    public static func driveTrash(_ drive: Drive, uid: uid_t = getuid()) -> [ResultItem] {
        let dir = drive.url.appendingPathComponent(".Trashes/\(uid)")
        let kids = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return kids.map { ResultItem(title: $0.lastPathComponent, subtitle: drive.name, size: FileSize.allocated($0), url: $0, action: .delete($0)) }
            .map { var i = $0; i.category = "trash"; return i }
    }

    /// Marketing name such as "MacBook Pro"; `hw.model` only gives the identifier ("Mac16,8").
    public static func machineName() -> String {
        let out = Shell.run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"]).output
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hw = (json["SPHardwareDataType"] as? [[String: Any]])?.first,
              let name = hw["machine_name"] as? String else { return String(localized: "Mac") }
        return name
    }
}
