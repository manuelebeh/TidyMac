import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// The menu's Network monitor: live speed, the connection info block and the speed test's "Good for:" legend.
extension SystemMonitor {

    // MARK: Speed

    public struct Network: Sendable {
        /// Bytes per second since the previous reading.
        public let download, upload: Double
        public let interface: String?
        public let connected: Bool
        /// Bytes moved through the physical interfaces since they came up.
        public let received, sent: Int64
    }

    nonisolated(unsafe) private static var lastBytes: (rx: UInt64, tx: UInt64, at: Date)?
    private static let bytesLock = NSLock()

    /// Bytes per second across physical (`en*`) interfaces since the previous call.
    public static func network() -> Network {
        let counters = interfaceCounters().filter { $0.name.hasPrefix("en") && $0.up }
        let rx = counters.reduce(UInt64(0)) { $0 + $1.rx }, tx = counters.reduce(UInt64(0)) { $0 + $1.tx }
        let primary = primaryInterface() ?? counters.first { $0.rx > 0 }?.name
        bytesLock.lock()
        let prev = lastBytes
        lastBytes = (rx, tx, Date())
        bytesLock.unlock()
        var down = 0.0, up = 0.0
        // An interface that went down makes the totals drop; that reading counts as no traffic.
        if let prev, rx >= prev.rx, tx >= prev.tx {
            let dt = max(Date().timeIntervalSince(prev.at), 0.1)
            down = Double(rx - prev.rx) / dt; up = Double(tx - prev.tx) / dt
        }
        return Network(download: down, upload: up, interface: primary, connected: primary != nil,
                       received: Int64(clamping: rx), sent: Int64(clamping: tx))
    }

    /// 64-bit byte counters per interface, from the interface MIB as `netstat -ib` reads them. `getifaddrs` and
    /// `NET_RT_IFLIST2` hand out counters cut to 32 bits, which wrap every 4 GB.
    static func interfaceCounters() -> [(name: String, rx: UInt64, tx: UInt64, up: Bool)] {
        guard let list = if_nameindex() else { return [] }
        defer { if_freenameindex(list) }
        var out: [(name: String, rx: UInt64, tx: UInt64, up: Bool)] = []
        var i = 0
        while list[i].if_index != 0 {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(list[i].if_index), IFDATA_GENERAL]
            var data = ifmibdata(), size = MemoryLayout<ifmibdata>.size
            if sysctl(&mib, 6, &data, &size, nil, 0) == 0 {
                let flags = Int32(bitPattern: data.ifmd_flags)
                out.append((String(cString: list[i].if_name), data.ifmd_data.ifi_ibytes, data.ifmd_data.ifi_obytes,
                            flags & IFF_UP != 0 && flags & IFF_RUNNING != 0))
            }
            i += 1
        }
        return out
    }

    /// The interface carrying the default route, as System Settings shows it.
    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "TidyMac" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return global["PrimaryInterface"] as? String
    }

    // MARK: Connection info

    public struct WiFiSecurity: Sendable, Equatable {
        public enum Rating: String, Sendable {
            case open = "Open", weak = "Weak", basic = "Basic", good = "Good", strong = "Strong"

            public var title: String {
                switch self {
                case .open: String(localized: "Open")
                case .weak: String(localized: "Weak")
                case .basic: String(localized: "Basic")
                case .good: String(localized: "Good")
                case .strong: String(localized: "Strong")
                }
            }
        }
        public let name: String
        public let rating: Rating

        /// From `CWSecurity`'s raw value.
        public init?(coreWLAN raw: Int) {
            switch raw {
            case 0: (name, rating) = (String(localized: "no password"), .open)
            case 1, 6: (name, rating) = ("WEP", .weak)
            case 2, 3: (name, rating) = ("WPA Personal", .basic)
            case 7, 8: (name, rating) = ("WPA Enterprise", .basic)
            case 14, 15: (name, rating) = ("OWE", .basic)
            case 4, 5: (name, rating) = ("WPA2 Personal", .good)
            case 13: (name, rating) = ("WPA2/WPA3 Personal", .good)
            case 9, 10: (name, rating) = ("WPA2 Enterprise", .strong)
            case 11: (name, rating) = ("WPA3 Personal", .strong)
            case 12: (name, rating) = ("WPA3 Enterprise", .strong)
            default: return nil
            }
        }
    }

    public struct NetworkInfo: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case wifi = "Wi-Fi", wired = "Wired", vpn = "VPN", other = "Other"

            public var title: String {
                switch self {
                case .wifi: "Wi-Fi"
                case .wired: String(localized: "Wired")
                case .vpn: "VPN"
                case .other: String(localized: "Other")
                }
            }
        }
        public let kind: Kind
        public let interface: String
        /// The Wi-Fi network's name. macOS hides it from apps without Location access, so it is often nil.
        public let name: String?
        public let security: WiFiSecurity?
    }

    /// nil when there is no network connection at all.
    public static func networkInfo() -> NetworkInfo? {
        guard let primary = primaryInterface() else { return nil }
        let wifi = CWWiFiClient.shared().interface()
        let onWiFi = wifi?.interfaceName != nil && wifi?.wlanChannel() != nil
        let kind: NetworkInfo.Kind
        if ["utun", "ipsec", "ppp"].contains(where: primary.hasPrefix) { kind = .vpn }
        else if primary == wifi?.interfaceName { kind = .wifi }
        else if primary.hasPrefix("en") || primary.hasPrefix("bridge") { kind = .wired }
        else { kind = .other }
        // A VPN usually runs over Wi-Fi; its security is still the Wi-Fi network's.
        let wifiDetails = onWiFi && kind != .wired
        return NetworkInfo(kind: kind, interface: primary, name: wifiDetails ? wifi?.ssid() : nil,
                           security: wifiDetails ? (wifi?.security()).flatMap { WiFiSecurity(coreWLAN: $0.rawValue) } : nil)
    }

    // MARK: Speed test

    /// Uses macOS's built-in `networkQuality` (12+). Returns bytes per second.
    public static func speedTest() -> (download: Double, upload: Double)? {
        let r = Shell.run("/usr/bin/networkQuality", ["-c", "-s"], timeout: 120)
        guard r.status == 0, let json = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any],
              let dl = json["dl_throughput"] as? Double, let ul = json["ul_throughput"] as? Double else { return nil }
        return (dl / 8, ul / 8)
    }

    /// The speed test's "Good for:" legend. Inputs are bytes per second; the Mbit/s thresholds are TidyMac's.
    /// Empty means the connection is too slow for any of them.
    public static func goodFor(download: Double, upload: Double) -> [String] {
        let dl = download * 8 / 1_000_000, ul = upload * 8 / 1_000_000
        var out: [String] = []
        if dl >= 0.5 { out.append(String(localized: "Messaging")) }
        if dl >= 1, ul >= 0.5 { out.append(String(localized: "Audio calls")) }
        if dl >= 2 { out.append(String(localized: "Music streaming")) }
        if dl >= 4, ul >= 3 { out.append(String(localized: "Video calls")) }
        if dl >= 15 { out.append(String(localized: "Video streaming")) }
        if dl >= 15, ul >= 5 { out.append(String(localized: "Online gaming")) }
        return out
    }
}
