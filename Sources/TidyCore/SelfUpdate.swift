import Foundation

/// Asks GitHub whether a newer TidyMac has been published. It only reads: nothing is downloaded or installed, and the
/// request carries nothing about this Mac beyond what any web request does.
public enum SelfUpdate {
    public struct Release: Equatable, Sendable {
        public let version: String
        public let page: URL
        /// The signed, notarized zip attached to the release, when it has one.
        public var archive: URL? = nil
    }

    public enum Outcome: Equatable, Sendable {
        case upToDate
        case available(Release)
    }

    public struct CheckFailed: Error {}

    static let latestRelease = URL(string: "https://api.github.com/repos/manuelebeh/TidyMac/releases/latest")!
    public static let projectPage = URL(string: "https://github.com/manuelebeh/TidyMac")!
    public static let issuesPage = URL(string: "https://github.com/manuelebeh/TidyMac/issues")!
    static let checkInterval: TimeInterval = 86_400
    static let lastCheckKey = "TidyMac.update.lastCheck"
    static let announcedKey = "TidyMac.update.announced"

    /// nil when running outside the app bundle (`swift run`, tests).
    public static var currentVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    public static var currentBuild: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }

    /// Only a published, final release counts, and its page has to be on GitHub since people are sent there to download.
    public static func parse(_ data: Data) -> Release? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = root["tag_name"] as? String,
              root["draft"] as? Bool != true, root["prerelease"] as? Bool != true,
              let link = root["html_url"] as? String, let page = URL(string: link),
              page.scheme == "https", page.host == "github.com" else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page, archive: archive(in: root))
    }

    /// `TidyMac-<version>.zip`, served by GitHub over https. Anything else attached to the release is ignored.
    static func archive(in release: [String: Any]) -> URL? {
        let assets = release["assets"] as? [[String: Any]] ?? []
        for a in assets {
            guard let name = a["name"] as? String, name.hasPrefix("TidyMac-"), name.hasSuffix(".zip"),
                  let link = a["browser_download_url"] as? String, let url = URL(string: link),
                  url.scheme == "https", url.host == "github.com", url.lastPathComponent == name else { continue }
            return url
        }
        return nil
    }

    public static func outcome(current: String, latest: Release?) -> Outcome {
        guard let latest, isNewer(latest.version, than: current) else { return .upToDate }
        return .available(latest)
    }

    /// Release order of TidyMac's own versions: 1.0.0-rc.1 < 1.0.0-rc.2 < 1.0.0 < 1.0.1. `Version` ignores a suffix, which
    /// suits other apps' build numbers but would make a release candidate look equal to its final release.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let (l, c) = (split(latest), split(current))
        if Version(l.core) != Version(c.core) { return Version(l.core) > Version(c.core) }
        switch (l.pre, c.pre) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let a?, let b?): return precedes(b, a)
        }
    }

    private static func split(_ version: String) -> (core: String, pre: [String]?) {
        guard let dash = version.firstIndex(of: "-") else { return (version, nil) }
        return (String(version[..<dash]), version[version.index(after: dash)...].split(separator: ".").map(String.init))
    }

    /// Pre-release identifiers: numbers compare as numbers and come before words, and a shorter list comes first.
    private static func precedes(_ a: [String], _ b: [String]) -> Bool {
        for (x, y) in zip(a, b) where x != y {
            switch (Int(x), Int(y)) {
            case (let m?, let n?): return m < n
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return x < y
            }
        }
        return a.count < b.count
    }

    public static func check(current: String = currentVersion ?? "0") async throws -> Outcome {
        var request = URLRequest(url: latestRelease, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests without a User-Agent.
        request.setValue("TidyMac/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            guard let release = parse(data) else { throw CheckFailed() }
            return outcome(current: current, latest: release)
        // GitHub's answer while no release has been published.
        case 404: return .upToDate
        default: throw CheckFailed()
        }
    }

    // MARK: The optional daily check

    /// Starts the interval too, so a Mac that is offline does not retry every minute.
    public static func beginAutomaticCheck(now: Date = Date(), _ d: UserDefaults = .standard) -> Bool {
        guard GeneralSettings.checksForUpdates(d) else { return false }
        if let last = d.object(forKey: lastCheckKey) as? Date, now.timeIntervalSince(last) < checkInterval { return false }
        d.set(now, forKey: lastCheckKey)
        return true
    }

    /// True once per version, so the notification does not come back every day until the update is installed.
    public static func shouldAnnounce(_ release: Release, _ d: UserDefaults = .standard) -> Bool {
        if let shown = d.string(forKey: announcedKey), Version(shown) >= Version(release.version) { return false }
        d.set(release.version, forKey: announcedKey)
        return true
    }
}
