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
                    let path = url.standardizedFileURL.path
                    let isApp = path.hasPrefix("/Applications/") && url.pathExtension == "app"
                    guard path.hasPrefix(home + "/") || isApp else { throw Failure("Outside home folder") }
                    try fm.trashItem(at: url, resultingItemURL: nil)
                case .delete(let url):
                    // Only items already inside a Trash bin are deleted permanently.
                    guard url.path.contains("/.Trash") else { throw Failure("Refusing permanent delete outside a Trash") }
                    if fm.isDeletableFile(atPath: url.path) {
                        try fm.removeItem(at: url)
                    } else {
                        adminItems.append((item, "rm -rf \(quote(url.path))")); continue
                    }
                case .adminDelete(let url):
                    adminItems.append((item, "rm -rf \(quote(url.path))")); continue
                case .shell(let cmd, let admin):
                    if admin { adminItems.append((item, cmd)); continue }
                    let r = Shell.run("/bin/zsh", ["-c", cmd])
                    if r.status != 0 { throw Failure(r.output.isEmpty ? "Exit \(r.status)" : r.output) }
                case .removeLaunchItem(let url, let admin):
                    if admin {
                        adminItems.append((item, "launchctl bootout system \(quote(url.path)) 2>/dev/null; rm -f \(quote(url.path))")); continue
                    }
                    _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", url.path])
                    try fm.trashItem(at: url, resultingItemURL: nil)
                case .removeLoginItem(let name):
                    let r = Shell.osascript("tell application \"System Events\" to delete login item \"\(appleScriptEscape(name))\"")
                    if r.status != 0 { throw Failure(r.output) }
                case .open(let url):
                    _ = Shell.run("/usr/bin/open", [url.path])
                }
                report.succeeded.append(item)
            } catch {
                report.failed.append((item, error.localizedDescription))
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
                else { report.failed.append((pair.0, r.status == 0 ? "Command failed" : "Administrator authorization was cancelled")) }
            }
        }
        History.record(report)
        return report
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
    public struct Result: Sendable { public let status: Int32; public let output: String }

    @discardableResult
    public static func run(_ launchPath: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func osascript(_ source: String) -> Result { run("/usr/bin/osascript", ["-e", source]) }
}


