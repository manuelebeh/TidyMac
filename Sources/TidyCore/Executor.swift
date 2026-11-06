import Foundation

public enum Executor {
    /// Runs the actions of `items`. Every action that needs root is collected into a single
    /// shell script and run through one administrator prompt, so the user authenticates once.
    public static func run(_ items: [ResultItem], fm: FileManager = .default) async -> ActionReport {
        var report = ActionReport()
        var adminItems: [(ResultItem, String)] = []
        let home = Paths.home.standardizedFileURL.path

        for item in items {
            do {
                switch item.action {
                case .trash(let url):
                    try moveToTrash(url, home: home, fm: fm)
                case .trashDuplicate(let url, let keep, let digest):
                    try verifyDuplicate(url, of: keep, digest: digest)
                    try moveToTrash(url, home: home, fm: fm)
                case .delete(let url):
                    try allow(url, permanent: true)
                    // Only items already inside a Trash bin are deleted permanently.
                    guard RemovalGuard.isInsideTrash(url) else { throw Failure(String(localized: "Refusing permanent delete outside a Trash")) }
                    if fm.isDeletableFile(atPath: url.path) {
                        try fm.removeItem(at: url)
                    } else {
                        adminItems.append((item, "rm -rf \(quote(url.path))")); continue
                    }
                case .adminDelete(let url):
                    try allow(url, permanent: true)
                    adminItems.append((item, "rm -rf \(quote(url.path))")); continue
                case .shell(let cmd, let admin):
                    if admin { adminItems.append((item, cmd)); continue }
                    let r = Shell.run("/bin/zsh", ["-c", cmd])
                    if r.status != 0 { throw Failure(r.output.isEmpty ? String(localized: "Exit \(r.status)") : r.output) }
                case .removeLaunchItem(let url, let admin):
                    try allow(url, permanent: admin)
                    if admin {
                        adminItems.append((item, "launchctl bootout system \(quote(url.path)) 2>/dev/null; rm -f \(quote(url.path))")); continue
                    }
                    _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", url.path])
                    try fm.trashItem(at: url, resultingItemURL: nil)
                case .removeLoginItem(let name):
                    let r = Shell.osascript("tell application \"System Events\" to delete login item \"\(appleScriptEscape(name))\"")
                    if r.status != 0 { throw Failure(r.output) }
                case .open(let url):
                    // Store pages are macappstore:// links, which `open` takes whole.
                    _ = Shell.run("/usr/bin/open", [url.isFileURL ? url.path : url.absoluteString])
                }
                report.succeeded.append(item)
            } catch {
                report.failed.append((item, error.localizedDescription))
                if blockedByMacOS(error) { report.needsAccess.append(item) }
            }
        }

        if !adminItems.isEmpty {
            // Each command reports its own status so one failure does not hide the others.
            let script = adminItems.enumerated().map { i, pair in
                "( \(pair.1) ) >/dev/null 2>&1 && echo OK:\(i) || echo KO:\(i)"
            }.joined(separator: "; ")
            let r = Shell.osascript("do shell script \"\(appleScriptEscape(script))\" with administrator privileges")
            for (i, pair) in adminItems.enumerated() {
                if r.status == 0 && r.output.contains("OK:\(i)") { report.succeeded.append(pair.0) }
                else { report.failed.append((pair.0, r.status == 0 ? String(localized: "Command failed") : String(localized: "Administrator authorization was cancelled"))) }
            }
        }
        History.record(report)
        return report
    }

    /// A file operation refused for lack of permission. The message is localized, so the error code is what counts.
    static func blockedByMacOS(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain, e.code == NSFileReadNoPermissionError || e.code == NSFileWriteNoPermissionError { return true }
        return e.domain == NSPOSIXErrorDomain && e.code == Int(EPERM)
    }

    static func allow(_ url: URL, permanent: Bool) throws {
        if let reason = RemovalGuard.refusal(for: url, permanent: permanent) { throw Failure(reason) }
    }

    static func moveToTrash(_ url: URL, home: String, fm: FileManager) throws {
        try allow(url, permanent: false)
        let path = url.standardizedFileURL.path
        let isApp = path.hasPrefix("/Applications/") && url.pathExtension == "app"
        guard path.hasPrefix(home + "/") || isApp else { throw Failure(String(localized: "Outside home folder")) }
        try fm.trashItem(at: url, resultingItemURL: nil)
    }

    /// Time passes between a scan and a cleanup. Both files are read again, so the copy being kept is known to still
    /// be there, to be a separate file and to have the same content before the other one goes.
    static func verifyDuplicate(_ url: URL, of keep: URL, digest: String) throws {
        guard let kept = ClutterEngine.regularFile(keep), ClutterEngine.hash(keep, limit: nil) == digest else {
            throw Failure(String(localized: "The copy to keep is gone or has changed"))
        }
        guard let copy = ClutterEngine.regularFile(url), ClutterEngine.hash(url, limit: nil) == digest else {
            throw Failure(String(localized: "Changed since the scan"))
        }
        guard kept.id != copy.id else { throw Failure(String(localized: "Same file as the copy to keep")) }
    }

    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String

        /// The JSON object in `output`. Errors share the pipe, so a tool's warnings can surround it.
        var jsonObject: Data {
            guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else { return Data() }
            return Data(output[start...end].utf8)
        }
    }

    /// An app opened from the Finder only gets the system folders in its PATH, so tools installed with Homebrew or their
    /// own installer (such as `ollama`) would not be found. They go last, so system tools keep priority.
    static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment, home: URL = Paths.home) -> [String: String] {
        var env = base
        let current = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let tools = ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
        env["PATH"] = (current + tools.filter { !current.contains($0) }).joined(separator: ":")
        return env
    }

    @discardableResult
    public static func run(_ launchPath: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.environment = environment()
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    public static func osascript(_ source: String) -> Result { run("/usr/bin/osascript", ["-e", source]) }
}


