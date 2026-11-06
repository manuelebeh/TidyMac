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
                        adminItems.append((item, Command("/bin/rm", "-rf", url.path).shellText)); continue
                    }
                case .adminDelete(let url):
                    try allow(url, permanent: true)
                    adminItems.append((item, Command("/bin/rm", "-rf", url.path).shellText)); continue
                case .run(let command, let admin):
                    if admin { adminItems.append((item, command.shellText)); continue }
                    let r = Shell.run(command.executable, command.arguments, timeout: nil)
                    if r.status != 0 { throw Failure(r.output.isEmpty ? String(localized: "Exit \(r.status)") : r.output) }
                case .removeLaunchItem(let url, let admin):
                    if admin {
                        try allow(url, permanent: true)
                        let bootout = Command("/bin/launchctl", "bootout", "system", url.path).shellText
                        adminItems.append((item, "\(bootout) 2>/dev/null; \(Command("/bin/rm", "-f", url.path).shellText)")); continue
                    }
                    // Checked before the job is stopped, so a refused item is left running as it was.
                    try allowInTrash(url, home: home)
                    _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", url.path], timeout: 30)
                    try fm.trashItem(at: url, resultingItemURL: nil)
                case .removeLoginItem(let name):
                    let r = Shell.osascript("tell application \"System Events\" to delete login item \(Shell.appleScriptString(name))", timeout: nil)
                    if r.status != 0 { throw Failure(r.output) }
                case .open(let url):
                    // Store pages are macappstore:// links, which `open` takes whole.
                    _ = Shell.run("/usr/bin/open", [url.isFileURL ? url.path : url.absoluteString], timeout: 30)
                }
                report.succeeded.append(item)
            } catch {
                report.failed.append((item, error.localizedDescription))
                // The kind of action only: what it touched, and why it failed, may name files.
                let kind = Mirror(reflecting: item.action).children.first?.label ?? "action"
                Log.executor.error("\(kind, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
                if blockedByMacOS(error) { report.needsAccess.append(item) }
            }
        }

        if !adminItems.isEmpty {
            // Each command reports its own status so one failure does not hide the others.
            let script = adminItems.enumerated().map { i, pair in
                "( \(pair.1) ) >/dev/null 2>&1 && echo OK:\(i) || echo KO:\(i)"
            }.joined(separator: "; ")
            let r = Shell.runAsAdministrator(script)
            let lines = outputLines(r.output)
            for (i, pair) in adminItems.enumerated() {
                if r.status == 0 && lines.contains("OK:\(i)") { report.succeeded.append(pair.0) }
                else { report.failed.append((pair.0, r.status == 0 ? String(localized: "Command failed") : String(localized: "Administrator authorization was cancelled"))) }
            }
        }
        History.record(report)
        return report
    }

    /// Whole lines, so that "OK:10" does not also report item 1 as done. `do shell script` ends its lines with a return.
    static func outputLines(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).map(String.init))
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
        try allowInTrash(url, home: home)
        try fm.trashItem(at: url, resultingItemURL: nil)
    }

    static func allowInTrash(_ url: URL, home: String) throws {
        try allow(url, permanent: false)
        guard RemovalGuard.isTrashable(url, home: home) else { throw Failure(String(localized: "Outside home folder")) }
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

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

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
        /// The program ran past its time limit and was stopped; `status` is -2 and `output` what it had written.
        public var timedOut = false

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

    /// How long a reading may take. A tool that hangs, such as `docker` with a dead daemon or a Bluetooth query, would
    /// otherwise hold a scan or the menu bar for good.
    public static let defaultTimeout: TimeInterval = 60

    /// Collects what a program writes while it is still running, so a full pipe cannot stall it.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        let finished = DispatchSemaphore(value: 0)
        func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs a program and waits for it. Past `timeout` it is stopped (nil waits for as long as it takes, for what the
    /// user asked for). Output and errors come back together.
    @discardableResult
    public static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval? = defaultTimeout) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.environment = environment()
        let pipe = Pipe(), output = Output(), exited = DispatchSemaphore(value: 0)
        p.standardOutput = pipe; p.standardError = pipe
        p.terminationHandler = { _ in exited.signal() }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let more = handle.availableData
            if more.isEmpty { handle.readabilityHandler = nil; output.finished.signal() } else { output.append(more) }
        }
        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            Log.shell.error("could not start \(launchPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return Result(status: -1, output: error.localizedDescription)
        }
        var timedOut = false
        if let timeout, exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            Log.shell.error("\(launchPath, privacy: .public) took more than \(Int(timeout)) s and was stopped")
            if p.isRunning { p.terminate() }
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL); exited.wait() }
        } else if timeout == nil {
            exited.wait()
        }
        // A program can leave a child behind that keeps the pipe open: take what is there once it has had a moment.
        _ = output.finished.wait(timeout: .now() + 2)
        pipe.fileHandleForReading.readabilityHandler = nil
        return Result(status: timedOut ? -2 : p.terminationStatus, output: output.text, timedOut: timedOut)
    }

    @discardableResult
    public static func osascript(_ source: String, timeout: TimeInterval? = defaultTimeout) -> Result {
        run("/usr/bin/osascript", ["-e", source], timeout: timeout)
    }

    /// `text` as an AppleScript string, whatever it contains.
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func administratorScript(_ script: String) -> String {
        "do shell script \(appleScriptString(script)) with administrator privileges"
    }

    /// Runs a shell script as root, after the standard macOS password prompt. The one way TidyMac gets root, so the
    /// quoting cannot be forgotten at a call site.
    @discardableResult
    static func runAsAdministrator(_ script: String) -> Result { osascript(administratorScript(script), timeout: nil) }
}


