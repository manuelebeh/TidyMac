import Foundation

/// Downloads a release, checks it is TidyMac signed by the same developer as the running copy, and swaps it in.
/// The swap waits for TidyMac to quit (a running bundle is never replaced), so an automatic update lands the next time
/// the app is closed, and "Restart to Update" lands right away.
public enum UpdateInstaller {
    public enum Failure: Error, Equatable {
        case noArchive, notSigned, wrongDeveloper, notNewer, damaged, folderNotWritable
    }

    static let stagedKey = "TidyMac.update.staged"
    static let stagedVersionKey = "TidyMac.update.stagedVersion"

    static var stagingRoot: URL { Paths.library.appendingPathComponent("Application Support/TidyMac/Update") }

    /// `TeamIdentifier=ABCDE12345` in the output of `codesign -dvv`.
    static func teamIdentifier(in output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let id = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return id.isEmpty || id == "not set" ? nil : id
        }
        return nil
    }

    static func team(of app: URL) -> String? {
        teamIdentifier(in: Shell.run("/usr/bin/codesign", ["-dvv", app.path]).output)
    }

    /// Same developer as the running copy, a valid signature on every file, and accepted by Gatekeeper (notarized).
    static func verify(_ app: URL, against current: URL) throws {
        guard let mine = team(of: current) else { throw Failure.notSigned }
        guard team(of: app) == mine else { throw Failure.wrongDeveloper }
        guard Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0,
              Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]).status == 0 else { throw Failure.damaged }
    }

    /// Downloads and checks the update, then remembers it for `apply`. Nothing of the running app is touched.
    @discardableResult
    public static func stage(_ release: SelfUpdate.Release, bundle: URL = Bundle.main.bundleURL, fm: FileManager = .default,
                             defaults: UserDefaults = .standard) async throws -> URL {
        guard let archive = release.archive else { throw Failure.noArchive }
        guard fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else { throw Failure.folderNotWritable }
        if let ready = pending(defaults: defaults, fm: fm), ready.version == release.version { return ready.app }

        let (file, response) = try await URLSession.shared.download(for: URLRequest(url: archive, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.damaged }
        defer { try? fm.removeItem(at: file) }

        try? fm.removeItem(at: stagingRoot)
        let folder = stagingRoot.appendingPathComponent(release.version)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard Shell.run("/usr/bin/ditto", ["-x", "-k", file.path, folder.path], timeout: 120).status == 0 else { throw Failure.damaged }
        let app = folder.appendingPathComponent("TidyMac.app")
        do {
            guard fm.fileExists(atPath: app.path) else { throw Failure.damaged }
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard let version = info?["CFBundleShortVersionString"] as? String, version == release.version,
                  SelfUpdate.isNewer(version, than: SelfUpdate.currentVersion ?? "0") else { throw Failure.notNewer }
            try verify(app, against: bundle)
        } catch {
            try? fm.removeItem(at: stagingRoot)
            throw error
        }
        defaults.set(app.path, forKey: stagedKey)
        defaults.set(release.version, forKey: stagedVersionKey)
        return app
    }

    /// An update that is downloaded and checked, waiting for the next quit. Forgotten once it is no longer newer.
    public static func pending(current: String = SelfUpdate.currentVersion ?? "0", defaults: UserDefaults = .standard,
                               fm: FileManager = .default) -> (version: String, app: URL)? {
        guard let path = defaults.string(forKey: stagedKey), let version = defaults.string(forKey: stagedVersionKey) else { return nil }
        guard SelfUpdate.isNewer(version, than: current), fm.fileExists(atPath: path) else {
            clear(defaults: defaults, fm: fm)
            return nil
        }
        return (version, URL(fileURLWithPath: path))
    }

    public static func clear(defaults: UserDefaults = .standard, fm: FileManager = .default) {
        defaults.removeObject(forKey: stagedKey)
        defaults.removeObject(forKey: stagedVersionKey)
        try? fm.removeItem(at: stagingRoot)
    }

    /// Starts the swap in a separate process, which waits for this one to quit. The old copy goes to the Trash (so it can
    /// be put back), and is restored if the new one cannot be copied. The caller quits right after.
    public static func apply(bundle: URL = Bundle.main.bundleURL, relaunch: Bool, defaults: UserDefaults = .standard) {
        guard let ready = pending(defaults: defaults) else { return }
        let script = """
        pid="$1"; staged="$2"; target="$3"; relaunch="$4"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.3; done
        /usr/bin/codesign --verify --deep --strict "$staged" || exit 1
        old="$HOME/.Trash/TidyMac (before update $(date +%s)).app"
        /bin/mv "$target" "$old" || exit 1
        if ! /usr/bin/ditto "$staged" "$target"; then /bin/mv "$old" "$target"; exit 1; fi
        /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
        [ -n "$staged" ] && /bin/rm -rf -- "$(dirname "$staged")"
        [ "$relaunch" = "1" ] && /usr/bin/open "$target"
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), ready.app.path, bundle.path, relaunch ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
            defaults.removeObject(forKey: stagedKey)
            defaults.removeObject(forKey: stagedVersionKey)
        } catch {
            Log.shell.error("could not start the update: \(error.localizedDescription, privacy: .public)")
        }
    }
}
