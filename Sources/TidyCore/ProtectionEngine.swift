import Foundation

/// Protection module: Malware Removal (heuristic), Privacy, Application Permissions.
public struct ProtectionEngine: ScanEngine {
    public init() {}

    public func scan(progress: @escaping @Sendable (String) -> Void) async -> [ResultGroup] {
        progress(String(localized: "Launch agents and daemons"))
        let threats = Self.suspiciousLaunchItems()
        progress(String(localized: "Browsers"))
        let privacy = Self.privacyItems()
        progress(String(localized: "Application permissions"))
        let perms = Self.permissions()
        progress(String(localized: "Security settings"))
        let security = Self.securitySettings()
        return [threats, security, privacy, perms].filter { !$0.isEmpty }
    }

    // MARK: Security settings

    public enum SecurityStatus: Sendable { case on, off, unknown }

    /// A built-in protection of macOS: how to read its setting, and what to do when it is off.
    struct SecurityCheck: Sendable {
        let id: String
        let title: String
        let tool: String
        let arguments: [String]
        let offAdvice: String
        let settings: String
        let status: @Sendable (String) -> SecurityStatus
    }

    static let securityPane = "x-apple.systempreferences:com.apple.preference.security"

    static let securityChecks: [SecurityCheck] = [
        SecurityCheck(id: "gatekeeper", title: String(localized: "Gatekeeper"), tool: "/usr/sbin/spctl", arguments: ["--status"],
                      offAdvice: String(localized: "Apps are not checked before they open. Turn it back on in Privacy & Security."),
                      settings: securityPane, status: { readStatus($0, on: "assessments enabled", off: "assessments disabled") }),
        SecurityCheck(id: "filevault", title: "FileVault", tool: "/usr/bin/fdesetup", arguments: ["status"],
                      offAdvice: String(localized: "Your disk is not encrypted. Turn it on in Privacy & Security."),
                      settings: securityPane, status: { readStatus($0, on: "FileVault is On", off: "FileVault is Off") }),
        SecurityCheck(id: "firewall", title: String(localized: "Firewall"), tool: "/usr/libexec/ApplicationFirewall/socketfilterfw", arguments: ["--getglobalstate"],
                      offAdvice: String(localized: "Incoming connections are not filtered. Turn it on in Network › Firewall."),
                      settings: "x-apple.systempreferences:com.apple.Network-Settings.extension",
                      status: { readStatus($0, on: "Firewall is enabled", off: "Firewall is disabled") }),
        SecurityCheck(id: "sip", title: String(localized: "System Integrity Protection"), tool: "/usr/bin/csrutil", arguments: ["status"],
                      offAdvice: String(localized: "System files are not protected. It can only be turned back on from Recovery, with `csrutil enable`."),
                      settings: securityPane, status: { readStatus($0, on: "status: enabled.", off: "status: disabled.") }),
    ]

    /// Anything else, such as a custom SIP configuration, stays unknown rather than being reported as fine.
    static func readStatus(_ output: String, on: String, off: String) -> SecurityStatus {
        output.contains(on) ? .on : output.contains(off) ? .off : .unknown
    }

    @Sendable static func securitySettings() -> ResultGroup {
        securityGroup(results: Dictionary(uniqueKeysWithValues: securityChecks.map { ($0.id, Shell.run($0.tool, $0.arguments)) }))
    }

    /// Only what needs attention is listed. This reads settings; it says nothing about whether the Mac is infected.
    static func securityGroup(results: [String: Shell.Result]) -> ResultGroup {
        let items = securityChecks.compactMap { check -> ResultItem? in
            let status = results[check.id].map { $0.status == 0 ? check.status($0.output) : .unknown } ?? .unknown
            guard status != .on else { return nil }
            return ResultItem(id: "security:\(check.id)", title: check.title,
                              subtitle: status == .off ? check.offAdvice : String(localized: "TidyMac could not read this setting."),
                              action: .open(URL(string: check.settings)!), selectedByDefault: false,
                              badge: status == .off ? String(localized: "Off") : String(localized: "Unknown"))
        }
        return ResultGroup(id: "security-settings", title: String(localized: "Security Settings"),
                           description: String(localized: "Built-in protections of macOS that are turned off. This checks settings; it is not a virus scan."),
                           symbol: "lock.shield", items: items, verb: String(localized: "to review"))
    }

    /// Not a signature engine: flags third-party launch items whose executable is missing,
    /// unsigned, or lives in a temporary/hidden location — the usual adware persistence pattern.
    @Sendable static func suspiciousLaunchItems() -> ResultGroup {
        var items: [ResultItem] = []
        for li in LaunchItems.all() where !li.label.hasPrefix("com.apple.") {
            guard let exe = li.executable else { continue }
            if li.isBroken { continue } // reported by Cleanup as a broken login item
            var reasons: [String] = []
            // Jobs that start a system tool (sh, open, osascript…) are judged by the paths they pass it.
            let isSystemTool = !exe.hasPrefix("/") || ["/bin/", "/usr/bin/", "/usr/sbin/", "/sbin/", "/System/"].contains { exe.hasPrefix($0) }
            let paths = isSystemTool ? li.arguments.dropFirst().filter { $0.hasPrefix("/") } : [exe]
            if !isSystemTool, FileManager.default.isReadableFile(atPath: exe) {
                // Root-only helpers cannot be read without privileges: unknown, not suspicious.
                let check = Shell.run("/usr/bin/codesign", ["--verify", exe])
                if check.status != 0 { reasons.append(String(localized: "unsigned or invalid signature")) }
            }
            if paths.contains(where: { $0.contains("/tmp/") || $0.contains("/private/var/folders/") || $0.split(separator: "/").contains(where: { $0.hasPrefix(".") }) }) {
                reasons.append(String(localized: "runs from a hidden or temporary folder"))
            }
            guard !reasons.isEmpty else { continue }
            items.append(ResultItem(id: "threat:\(li.plist.path)", title: li.label,
                                    subtitle: "\(exe) — \(reasons.joined(separator: ", "))", url: li.plist,
                                    action: .removeLaunchItem(li.plist, admin: li.isSystemWide),
                                    selectedByDefault: false, badge: String(localized: "Suspicious")))
        }
        return ResultGroup(id: "malware", title: String(localized: "Malware Removal"),
                           description: String(localized: "Background items with traits common to adware and malware. Review before removing."),
                           symbol: "ladybug", items: items, verb: String(localized: "to remove"))
    }

    @Sendable static func privacyItems() -> ResultGroup {
        var items: [ResultItem] = []
        let lib = Paths.library
        func add(_ rel: String, _ title: String, _ app: String) {
            let u = lib.appendingPathComponent(rel)
            guard Paths.exists(u) else { return }
            items.append(.file(u, subtitle: app, selected: false).with(title: "\(app) \(title)"))
        }
        let chromeProfiles = Paths.children(lib.appendingPathComponent("Application Support/Google/Chrome"))
            .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
        for p in chromeProfiles {
            let rel = "Application Support/Google/Chrome/\(p.lastPathComponent)"
            add("\(rel)/History", String(localized: "Browsing & Downloads History"), String(localized: "Chrome"))
            add("\(rel)/Cookies", String(localized: "Cookies"), String(localized: "Chrome"))
        }
        for p in Paths.children(lib.appendingPathComponent("Application Support/Firefox/Profiles")) {
            let rel = "Application Support/Firefox/Profiles/\(p.lastPathComponent)"
            add("\(rel)/places.sqlite", String(localized: "Browsing History"), String(localized: "Firefox"))
            add("\(rel)/cookies.sqlite", String(localized: "Cookies"), String(localized: "Firefox"))
        }
        add("Safari/History.db", String(localized: "Browsing History"), String(localized: "Safari"))
        add("Cookies/Cookies.binarycookies", String(localized: "Cookies"), String(localized: "Safari"))
        for f in Paths.children(lib.appendingPathComponent("Application Support/com.apple.sharedfilelist"))
            where f.pathExtension.hasPrefix("sfl") {
            items.append(.file(f, subtitle: String(localized: "Recent Items Lists"), selected: false))
        }
        return ResultGroup(id: "privacy", title: String(localized: "Privacy"),
                           description: String(localized: "Browsing history, cookies and recent items lists. Quit the browser before removing its data."),
                           symbol: "hand.raised", items: items, verb: String(localized: "to remove"))
    }

    /// TCC service → user-facing name, from the Application Permissions strings.
    static let tccServices: [String: String] = [
        "kTCCServiceAccessibility": String(localized: "Accessibility"), "kTCCServiceAppleEvents": String(localized: "Automation"),
        "kTCCServiceCalendar": String(localized: "Calendar"), "kTCCServiceCamera": String(localized: "Camera"), "kTCCServiceAddressBook": String(localized: "Contacts"),
        "kTCCServiceSystemPolicyDesktopFolder": String(localized: "Desktop Folder"), "kTCCServiceSystemPolicyDocumentsFolder": String(localized: "Documents Folder"),
        "kTCCServiceSystemPolicyDownloadsFolder": String(localized: "Downloads Folder"), "kTCCServiceSystemPolicyAllFiles": String(localized: "Full Disk Access"),
        "kTCCServiceListenEvent": String(localized: "Input Monitoring"), "kTCCServiceMicrophone": String(localized: "Microphone"),
        "kTCCServiceSystemPolicyNetworkVolumes": String(localized: "Network Volumes"), "kTCCServicePhotos": String(localized: "Photos"),
        "kTCCServiceReminders": String(localized: "Reminders"), "kTCCServiceSystemPolicyRemovableVolumes": String(localized: "Removable Volumes"),
        "kTCCServiceScreenCapture": String(localized: "Screen Recording"), "kTCCServiceSpeechRecognition": String(localized: "Speech Recognition"),
    ]

    @Sendable static func permissions() -> ResultGroup {
        // Per-user grants live in the user database; Accessibility, Full Disk Access and
        // Screen Recording live in the system one. Both need Full Disk Access to read.
        let dbs = [Paths.library.appendingPathComponent("Application Support/com.apple.TCC/TCC.db"),
                   URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")]
        let results = dbs.map {
            Shell.run("/usr/bin/sqlite3", ["-readonly", "-separator", "|", $0.path,
                                           "select service, client from access where auth_value = 2 and client_type = 0"])
        }
        let r = Shell.Result(status: results.allSatisfy { $0.status == 0 } ? 0 : 1,
                             output: results.map(\.output).joined(separator: "\n"))
        var items: [ResultItem] = []
        if r.status != 0 {
            items.append(ResultItem(id: "tcc-fda", title: String(localized: "Full Disk Access needed"),
                                    subtitle: String(localized: "Allow TidyMac in Privacy & Security to list app permissions."),
                                    action: .open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!),
                                    selectedByDefault: false))
        } else {
            for line in r.output.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let name = tccServices[parts[0]], !parts[1].hasPrefix("com.apple.") else { continue }
                let service = parts[0].replacingOccurrences(of: "kTCCService", with: "")
                items.append(ResultItem(id: "tcc:\(parts[0]):\(parts[1])", title: parts[1], subtitle: name,
                                        action: .run(Command("/usr/bin/tccutil", "reset", service, parts[1]), admin: false),
                                        selectedByDefault: false))
            }
        }
        return ResultGroup(id: "permissions", title: String(localized: "Application Permissions"),
                           description: String(localized: "Apps you allowed to use your camera, files, screen and more. Revoking asks again next time."),
                           symbol: "checkmark.shield", items: items.sorted { $0.subtitle ?? "" < $1.subtitle ?? "" }, verb: String(localized: "to review"))
    }
}

extension ResultItem {
    func with(title: String) -> ResultItem {
        ResultItem(id: id, title: title, subtitle: subtitle, size: size, url: url, action: action,
                   selectedByDefault: selectedByDefault, badge: badge)
    }
}
