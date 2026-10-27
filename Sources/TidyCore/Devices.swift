import DiskArbitration
import Foundation

/// Readings behind CleanMyMac Menu's Top Consumers, External Drives, Connected Devices and drive health.
extension SystemMonitor {

    // MARK: Top Consumers

    public struct Consumer: Identifiable, Sendable, Equatable {
        public var id: String { name }
        public let name: String
        /// The app's main process, used to quit it; nil for plain processes.
        public let pid: Int32?
        public let memory: Int64
        /// Percent of one core, as Activity Monitor shows it (can exceed 100).
        public let cpu: Double
    }

    /// Processes grouped by the app bundle they belong to ("Google Chrome Helper (Renderer)" counts as Google Chrome).
    public static func consumers() -> [Consumer] {
        parseConsumers(Shell.run("/bin/ps", ["-axo", "pid=,rss=,%cpu=,comm="]).output)
    }

    static func parseConsumers(_ psOutput: String) -> [Consumer] {
        var groups: [String: (pid: Int32?, rss: Int64, cpu: Double)] = [:]
        for line in psOutput.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let kb = Int64(parts[1]),
                  let cpu = Double(parts[2].replacingOccurrences(of: ",", with: ".")) else { continue }
            let path = String(parts[3])
            let comps = path.components(separatedBy: "/")
            let name: String
            var mainPid: Int32?
            if let i = comps.firstIndex(where: { $0.hasSuffix(".app") }) {
                name = String(comps[i].dropLast(4))
                // The app's own executable sits directly in <bundle>/Contents/MacOS.
                if comps.count == i + 4, comps[i + 1] == "Contents", comps[i + 2] == "MacOS" { mainPid = pid }
            } else {
                name = (path as NSString).lastPathComponent
            }
            var g = groups[name] ?? (nil, 0, 0)
            g.rss += kb * 1024; g.cpu += cpu
            if let mainPid { g.pid = mainPid }
            groups[name] = g
        }
        return groups.map { Consumer(name: $0.key, pid: $0.value.pid, memory: $0.value.rss, cpu: $0.value.cpu) }
    }

    // MARK: External Drives

    public struct Drive: Identifiable, Sendable, Equatable {
        public var id: String { url.path }
        public let url: URL
        public let name: String
        public let total: Int64
        public let available: Int64
        public let format: String?
        /// Mounted .dmg/.iso: listed and ejectable, but never "almost full" (they are read-only) and not announced.
        public let isDiskImage: Bool
        public init(url: URL, name: String, total: Int64, available: Int64, format: String?, isDiskImage: Bool) {
            self.url = url; self.name = name; self.total = total; self.available = available; self.format = format; self.isDiskImage = isDiskImage
        }
        /// CleanMyMac's "Connected disk is almost full": under 10% free.
        public var almostFull: Bool { !isDiskImage && total > 0 && available * 10 < total }
    }

    /// Mounted volumes other than the startup disk that can be ejected: USB and Thunderbolt drives, SD cards, disk images.
    public static func externalDrives() -> [Drive] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRootFileSystemKey,
                                      .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let session = DASessionCreate(kCFAllocatorDefault)
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true,
                  v.volumeIsInternal == false || v.volumeIsEjectable == true else { return nil }
            return Drive(url: u, name: v.volumeName ?? u.lastPathComponent, total: Int64(v.volumeTotalCapacity ?? 0),
                         available: Int64(v.volumeAvailableCapacity ?? 0), format: v.volumeLocalizedFormatDescription,
                         isDiskImage: session.map { isDiskImage(u, session: $0) } ?? false)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isDiskImage(_ volume: URL, session: DASession) -> Bool {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
              let desc = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        return desc[kDADiskDescriptionDeviceModelKey] as? String == "Disk Image"
            || desc[kDADiskDescriptionDeviceProtocolKey] as? String == "Disk Image"
    }

    // MARK: Connected Devices

    public struct BluetoothDevice: Identifiable, Sendable, Equatable {
        public var id: String { name }
        public let name: String
        /// "Mouse", "Keyboard", "Headphones"…, as System Information reports it.
        public let kind: String?
        /// e.g. [("Left", 80), ("Right", 75), ("Case", 40)] for AirPods, [("", 60)] for a mouse. Empty: no battery data.
        public let batteries: [Battery]
        public struct Battery: Sendable, Equatable { public let label: String; public let percent: Int }
        /// The level that matters for "Time to juice up!": the lowest one, not counting a charging case.
        public var lowest: Int? { batteries.filter { $0.label != "Case" }.map(\.percent).min() }
    }

    /// Connected Bluetooth devices from System Information (about 0.2 s).
    public static func bluetoothDevices() -> [BluetoothDevice] {
        parseBluetooth(Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]).output)
    }

    static func parseBluetooth(_ json: String) -> [BluetoothDevice] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        let levels = [("device_batteryLevelMain", ""), ("device_batteryLevel", ""), ("device_batteryLevelLeft", "Left"),
                      ("device_batteryLevelRight", "Right"), ("device_batteryLevelCase", "Case")]
        var out: [BluetoothDevice] = []
        for c in controllers {
            for entry in c["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    let props = value as? [String: Any] ?? [:]
                    var batteries: [BluetoothDevice.Battery] = []
                    for (key, label) in levels where !batteries.contains(where: { $0.label == label }) {
                        if let s = props[key] as? String, let p = Int(s.filter(\.isNumber)) { batteries.append(.init(label: label, percent: p)) }
                    }
                    out.append(BluetoothDevice(name: name, kind: props["device_minorType"] as? String, batteries: batteries))
                }
            }
        }
        return out
    }

    // MARK: Drive health

    public enum DriveHealth: Sendable { case good, failing, unknown
        /// CleanMyMac Menu's wording.
        public var text: String {
            switch self {
            case .good: "This drive is in good condition."
            case .failing: "Back up immediately. This drive is in bad condition and should be replaced."
            case .unknown: "Drive health could not be read."
            }
        }
    }

    /// The startup disk's S.M.A.R.T. status. macOS only exposes pass/fail, not the wear level CleanMyMac reads with its helper.
    public static func driveHealth() -> DriveHealth {
        let out = Shell.run("/usr/sbin/diskutil", ["info", "-plist", "/"]).output
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil) as? [String: Any],
              let status = plist["SMARTStatus"] as? String else { return .unknown }
        switch status {
        case "Verified": return .good
        case "Failing": return .failing
        default: return .unknown
        }
    }
}
