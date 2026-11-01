import Foundation

/// One row of a monitor's details: a value, a severity colour and a line explaining it.
public struct Metric: Identifiable, Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case normal, warning, critical
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { title }
    public let title: String
    public let value: String
    public let severity: Severity
    public let detail: String

    public init(title: String, value: String, severity: Severity, detail: String) {
        self.title = title; self.value = value; self.severity = severity; self.detail = detail
    }
}

extension Metric {
    public static func memoryPressure(_ m: SystemMonitor.Memory) -> Metric {
        switch m.pressureLevel {
        case 4...: Metric(title: "Pressure", value: m.pressure, severity: .critical,
                          detail: "Your Mac is out of memory and may slow down noticeably. Quit the apps you are not using.")
        case 2...: Metric(title: "Pressure", value: m.pressure, severity: .warning,
                          detail: "Consider quitting some unimportant applications to relieve stress on Mac’s memory.")
        default: Metric(title: "Pressure", value: m.pressure, severity: .normal, detail: "Your Mac is ready to take on more tasks.")
        }
    }

    /// Warning once swap passes a quarter of the RAM (TidyMac's threshold).
    public static func swap(_ m: SystemMonitor.Memory) -> Metric {
        let heavy = m.total > 0 && m.swapUsed > m.total / 4
        return Metric(title: "Swap File", value: FileSize.format(m.swapUsed), severity: heavy ? .warning : .normal,
                      detail: heavy ? "Your Mac leans heavily on the swap file, which is slower than memory. Quitting some apps helps."
                                    : "An area on your drive that helps optimize Mac’s memory performance.")
    }

    public static func uptime(_ t: TimeInterval) -> Metric {
        let week = t > 7 * 86_400
        return Metric(title: "Uptime", value: formatUptime(t), severity: week ? .warning : .normal,
                      detail: week ? "It’s been over a week now. Restart your Mac once in a while."
                                   : "Your Mac was restarted less than a week ago.")
    }

    public static func formatUptime(_ t: TimeInterval) -> String {
        let d = Int(t) / 86_400, h = Int(t) % 86_400 / 3600, m = Int(t) % 3600 / 60
        return d > 0 ? "\(d)d \(h)h" : "\(h)h \(m)m"
    }

    /// Four health texts, cut at 95/80/70 %; 70 % matches the critical battery alert.
    public static func batteryHealth(_ percent: Int?) -> Metric {
        guard let p = percent else {
            return Metric(title: "Health", value: "Unknown", severity: .normal, detail: "Battery health could not be calculated at the moment.")
        }
        switch p {
        case 95...: return Metric(title: "Health", value: "\(p)%", severity: .normal, detail: "Your battery is in good condition.")
        case 80...: return Metric(title: "Health", value: "\(p)%", severity: .normal,
                                  detail: "Your battery is in good condition, but already lost some capacity.")
        case 70...: return Metric(title: "Health", value: "\(p)%", severity: .warning,
                                  detail: "Your battery has dropped some capacity, but remains functional.")
        default: return Metric(title: "Health", value: "\(p)%", severity: .critical,
                               detail: "Your battery is in bad condition and should be replaced soon.")
        }
    }

    /// Warning from 40 °C (TidyMac's threshold).
    public static func batteryTemperature(_ celsius: Double) -> Metric {
        let hot = celsius >= 40
        return Metric(title: "Temperature", value: String(format: "%.1f °C", celsius), severity: hot ? .warning : .normal,
                      detail: hot ? "Your battery temperature is not optimal." : "Battery temperature is within its perfect working range.")
    }

    public static func driveHealth(_ h: SystemMonitor.DriveHealth) -> Metric {
        switch h {
        case .good: Metric(title: "Health", value: "Okay", severity: .normal, detail: h.text)
        case .failing: Metric(title: "Health", value: "Failing", severity: .critical, detail: h.text)
        case .unknown: Metric(title: "Health", value: "Unknown", severity: .normal, detail: h.text)
        }
    }

    /// Wi-Fi security rated Open, Basic, Weak, Good or Strong; a wired link is always fine.
    public static func networkSecurity(_ info: SystemMonitor.NetworkInfo) -> Metric? {
        if info.kind == .wired {
            return Metric(title: "Security", value: "Strong", severity: .normal,
                          detail: "The physical connection to your router provides a strong level of network security. You’re good!")
        }
        guard let s = info.security else { return nil }
        let rating = s.rating.rawValue, name = s.name
        switch s.rating {
        case .open:
            return Metric(title: "Security", value: rating, severity: .critical,
                          detail: "You’re putting your data at risk by using an open Wi-Fi network. Use another network or reconfigure your connection for better security.")
        case .weak, .basic:
            return Metric(title: "Security", value: rating, severity: .warning,
                          detail: "Your network security settings use \(name) and are rated as \(rating). Consider switching to a more secure setup.")
        case .good:
            return Metric(title: "Security", value: rating, severity: .normal,
                          detail: "Your network security settings use \(name) and are rated as \(rating). You may continue using this network as is.")
        case .strong:
            return Metric(title: "Security", value: rating, severity: .normal,
                          detail: "Your network security settings are rated as \(rating) (\(name)). You’re good!")
        }
    }
}
