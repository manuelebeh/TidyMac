import Foundation

/// Protection module: Malware Removal (heuristic), Privacy, Application Permissions.
public struct ProtectionEngine: ScanEngine {
    public init() {}

    public func scan(progress: @escaping @Sendable (String) -> Void) async -> [ResultGroup] {
        progress("Launch agents and daemons")
        let threats = Self.suspiciousLaunchItems()
        progress("Browsers")
        let privacy = Self.privacyItems()
        progress("Application permissions")
        let perms = Self.permissions()
        return [threats, privacy, perms].filter { !$0.isEmpty }
    }

    /// Not a signature engine: flags third-party launch items whose executable is missing,
    /// unsigned, or lives in a temporary/hidden location — the usual adware persistence pattern.
    static func suspiciousLaunchItems() -> ResultGroup {
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
                if check.status != 0 { reasons.append("unsigned or invalid signature") }
            }
            if paths.contains(where: { $0.contains("/tmp/") || $0.contains("/private/var/folders/") || $0.split(separator: "/").contains(where: { $0.hasPrefix(".") }) }) {
                reasons.append("runs from a hidden or temporary folder")
            }
            guard !reasons.isEmpty else { continue }
            items.append(ResultItem(id: "threat:\(li.plist.path)", title: li.label,
                                    subtitle: "\(exe) — \(reasons.joined(separator: ", "))", url: li.plist,
                                    action: .removeLaunchItem(li.plist, admin: li.isSystemWide),
                                    selectedByDefault: false, badge: "Suspicious"))
        }
        return ResultGroup(id: "malware", title: "Malware Removal",
                           description: "Background items with traits common to adware and malware. Review before removing.",
                           symbol: "ladybug", items: items, verb: "to remove")
    }

    static func privacyItems() -> ResultGroup {
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
            add("\(rel)/History", "Browsing & Downloads History", "Chrome")
            add("\(rel)/Cookies", "Cookies", "Chrome")
        }
        for p in Paths.children(lib.appendingPathComponent("Application Support/Firefox/Profiles")) {
            let rel = "Application Support/Firefox/Profiles/\(p.lastPathComponent)"
            add("\(rel)/places.sqlite", "Browsing History", "Firefox")
            add("\(rel)/cookies.sqlite", "Cookies", "Firefox")
        }
        add("Safari/History.db", "Browsing History", "Safari")
        add("Cookies/Cookies.binarycookies", "Cookies", "Safari")
        for f in Paths.children(lib.appendingPathComponent("Application Support/com.apple.sharedfilelist"))
            where f.pathExtension.hasPrefix("sfl") {
            items.append(.file(f, subtitle: "Recent Items Lists", selected: false))
        }
        return ResultGroup(id: "privacy", title: "Privacy",
                           description: "Browsing history, cookies and recent items lists. Quit the browser before removing its data.",
                           symbol: "hand.raised", items: items, verb: "to remove")
    }

    /// TCC service → user-facing name, from the Application Permissions strings.
    static let tccServices: [String: String] = [
        "kTCCServiceAccessibility": "Accessibility", "kTCCServiceAppleEvents": "Automation",
        "kTCCServiceCalendar": "Calendar", "kTCCServiceCamera": "Camera", "kTCCServiceAddressBook": "Contacts",
        "kTCCServiceSystemPolicyDesktopFolder": "Desktop Folder", "kTCCServiceSystemPolicyDocumentsFolder": "Documents Folder",
        "kTCCServiceSystemPolicyDownloadsFolder": "Downloads Folder", "kTCCServiceSystemPolicyAllFiles": "Full Disk Access",
        "kTCCServiceListenEvent": "Input Monitoring", "kTCCServiceMicrophone": "Microphone",
        "kTCCServiceSystemPolicyNetworkVolumes": "Network Volumes", "kTCCServicePhotos": "Photos",
        "kTCCServiceReminders": "Reminders", "kTCCServiceSystemPolicyRemovableVolumes": "Removable Volumes",
        "kTCCServiceScreenCapture": "Screen Recording", "kTCCServiceSpeechRecognition": "Speech Recognition",
    ]

    static func permissions() -> ResultGroup {
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
            items.append(ResultItem(id: "tcc-fda", title: "Full Disk Access needed",
                                    subtitle: "Allow TidyMac in Privacy & Security to list app permissions.",
                                    action: .open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!),
                                    selectedByDefault: false))
        } else {
            for line in r.output.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let name = tccServices[parts[0]], !parts[1].hasPrefix("com.apple.") else { continue }
                let service = parts[0].replacingOccurrences(of: "kTCCService", with: "")
                items.append(ResultItem(id: "tcc:\(parts[0]):\(parts[1])", title: parts[1], subtitle: name,
                                        action: .shell("tccutil reset \(service) \(Executor.quote(parts[1]))", admin: false),
                                        selectedByDefault: false))
            }
        }
        return ResultGroup(id: "permissions", title: "Application Permissions",
                           description: "Apps you allowed to use your camera, files, screen and more. Revoking asks again next time.",
                           symbol: "checkmark.shield", items: items.sorted { $0.subtitle ?? "" < $1.subtitle ?? "" }, verb: "to review")
    }
}

extension ResultItem {
    func with(title: String) -> ResultItem {
        ResultItem(id: id, title: title, subtitle: subtitle, size: size, url: url, action: action,
                   selectedByDefault: selectedByDefault, badge: badge)
    }
}
