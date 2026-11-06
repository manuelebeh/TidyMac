import Foundation

/// Asks GitHub whether a newer TidyMac has been published. It only reads: nothing is downloaded or installed, and the
/// request carries nothing about this Mac beyond what any web request does.
public enum SelfUpdate {
    public struct Release: Equatable, Sendable {
        public let version: String
        public let page: URL
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
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page)
    }

    public static func outcome(current: String, latest: Release?) -> Outcome {
        guard let latest, Version(latest.version) > Version(current) else { return .upToDate }
        return .available(latest)
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
