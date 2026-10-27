import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Live readings for the menu bar, mirroring CleanMyMac Menu's monitors
/// (Storage, Memory, Battery, CPU, Network) and its "Today's Recommendation" issues.
public enum SystemMonitor {

    // MARK: Storage

    public struct Storage: Sendable { public let name: String; public let total: Int64; public let available: Int64 }

    public static func storage() -> Storage {
        let root = URL(fileURLWithPath: "/")
        let v = try? root.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return Storage(name: v?.volumeName ?? "Macintosh HD", total: Int64(v?.volumeTotalCapacity ?? 0),
                       available: v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: Memory

    public struct Memory: Sendable {
        public let total, active, wired, compressed, available, swapUsed: Int64
        /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
        public let pressureLevel: Int
        public var used: Int64 { total - available }
        public var pressure: String { pressureLevel >= 4 ? "Critical" : pressureLevel >= 2 ? "High" : "Normal" }
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

        var boot = timeval(); var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        return CPU(user: du / sum, system: ds / sum, idle: di / sum,
                   uptime: Date().timeIntervalSince1970 - TimeInterval(boot.tv_sec))
    }

    // MARK: Battery

    public struct Battery: Sendable {
        public let percent: Int
        public let isCharging, isPluggedIn, isCharged: Bool
        public let minutesRemaining: Int?
        public let cycleCount: Int?
        public let healthPercent: Int?
        public let temperature: Double?

        public var status: String {
            if isCharged { return "Fully charged" }
            if isCharging { return "Charging" }
            if isPluggedIn { return "Not charging" }
            guard let m = minutesRemaining else { return "Calculating…" }
            return "\(m / 60):\(String(format: "%02d", m % 60)) remaining"
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
            let tte = d[kIOPSTimeToEmptyKey] as? Int
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
                           minutesRemaining: (tte ?? -1) > 0 ? tte : nil,
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

    // MARK: Network

    public struct Network: Sendable { public let download, upload: Double; public let interface: String?; public let connected: Bool }

    nonisolated(unsafe) private static var lastBytes: (rx: UInt64, tx: UInt64, at: Date)?

    /// Bytes per second across physical interfaces since the previous call.
    public static func network() -> Network {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        var rx: UInt64 = 0, tx: UInt64 = 0
        var primary: String?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = p {
                let name = String(cString: cur.pointee.ifa_name)
                let flags = Int32(cur.pointee.ifa_flags)
                if name.hasPrefix("en"), flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                   let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                   let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    rx += UInt64(data.pointee.ifi_ibytes); tx += UInt64(data.pointee.ifi_obytes)
                    if data.pointee.ifi_ibytes > 0, primary == nil { primary = name }
                }
                p = cur.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        tickLock.lock()
        let prev = lastBytes
        lastBytes = (rx, tx, Date())
        tickLock.unlock()
        guard let prev else { return Network(download: 0, upload: 0, interface: primary, connected: primary != nil) }
        let dt = max(Date().timeIntervalSince(prev.at), 0.1)
        return Network(download: Double(rx &- prev.rx) / dt, upload: Double(tx &- prev.tx) / dt,
                       interface: primary, connected: primary != nil)
    }

    /// Uses macOS's built-in `networkQuality` (12+). Returns bytes per second.
    public static func speedTest() -> (download: Double, upload: Double)? {
        let r = Shell.run("/usr/bin/networkQuality", ["-c", "-s"])
        guard r.status == 0, let json = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any],
              let dl = json["dl_throughput"] as? Double, let ul = json["ul_throughput"] as? Double else { return nil }
        return (dl / 8, ul / 8)
    }

    // MARK: Recommendations

    public struct Issue: Identifiable, Sendable {
        public enum Kind: String, Sendable { case lowDiskSpace, trashSize, trashedApps, heavyMemory, screenCleaning }
        public var id: String { kind.rawValue }
        public let kind: Kind
        public let title: String
        public let detail: String
    }

    public static func issues(storage: Storage, memory: Memory, trashSize: Int64?, trashedApps: Int, screenCleaningDue: Bool = false,
                              trashLimit: Int64 = 1_000_000_000) -> [Issue] {
        var out: [Issue] = []
        if storage.total > 0, storage.available < max(storage.total / 10, 15_000_000_000) {
            out.append(Issue(kind: .lowDiskSpace, title: "You are running out of disk space!",
                             detail: "Only \(FileSize.format(storage.available)) left. Remove unneeded items to reclaim space."))
        }
        if let t = trashSize, t > trashLimit {
            out.append(Issue(kind: .trashSize, title: "It’s time to empty your Trash!",
                             detail: "Your Trash holds \(FileSize.format(t))."))
        }
        if trashedApps > 0 {
            out.append(Issue(kind: .trashedApps, title: "Uninstall applications correctly",
                             detail: "\(trashedApps) app\(trashedApps == 1 ? "" : "s") in the Trash may have left files behind."))
        }
        if memory.pressureLevel >= 2 {
            out.append(Issue(kind: .heavyMemory, title: "Heavy memory usage",
                             detail: "Memory pressure is \(memory.pressure.lowercased()). Quitting unused apps can help."))
        }
        if screenCleaningDue {
            out.append(Issue(kind: .screenCleaning, title: "Your screen deserves some care",
                             detail: "Keep your Mac clean inside and out with Screen Cleaning Mode."))
        }
        return out
    }

    /// Trash contents need Full Disk Access; without it this returns nil rather than prompting.
    public static func trash() -> (size: Int64, apps: Int)? {
        let t = Paths.home(".Trash")
        guard let kids = try? FileManager.default.contentsOfDirectory(at: t, includingPropertiesForKeys: nil) else { return nil }
        return (kids.reduce(0) { $0 + FileSize.allocated($1) }, kids.filter { $0.pathExtension == "app" }.count)
    }
}

extension SystemMonitor {
    /// Marketing name such as "MacBook Pro"; `hw.model` only gives the identifier ("Mac16,8").
    public static func machineName() -> String {
        let out = Shell.run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"]).output
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hw = (json["SPHardwareDataType"] as? [[String: Any]])?.first,
              let name = hw["machine_name"] as? String else { return "Mac" }
        return name
    }
}
