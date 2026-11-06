import Darwin
import Foundation

/// The last check before anything is removed. Scanners decide what to offer; this decides what may never go,
/// whatever a stale scan, a symbolic link or a `tidymac://` link points at. Both the path as written and the path
/// it really leads to are checked.
public enum RemovalGuard {
    /// Live state of the cloud sync services, not user files. Removing it leaves them out of step with the disk.
    static let cloudState = [
        "Library/Application Support/FileProvider", "Library/Application Support/CloudDocs", "Library/Daemon Containers",
        "Library/Caches/CloudKit", "Library/Caches/com.apple.bird", "Library/Caches/com.apple.cloudkit",
        "Library/Caches/com.apple.cloudd", "Library/Caches/com.apple.FileProvider",
    ]
    static let systemTrees = ["/bin", "/sbin", "/etc", "/private/etc", "/cores", "/dev"]
    /// The only folders outside the home folder whose contents may be removed without a Trash to go back to: what the
    /// scans and the Uninstaller offer. Anything else is refused, so a folder nobody thought of stays safe by default.
    static let permanentRoots = [
        "/Library/Application Support", "/Library/Audio/Plug-Ins", "/Library/Caches", "/Library/Internet Plug-Ins",
        "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PreferencePanes", "/Library/Preferences",
        "/Library/PrivilegedHelperTools", "/Library/QuickLook", "/Library/Screen Savers", "/Library/Spotlight",
    ] + logRoots
    /// Allowed to hold Apple's items too, since these only hold logs and data of removed accounts.
    /// `standardizedFileURL` turns /private/var into /var, so the path as written and the real path each need their entry.
    static let logRoots = ["/Library/Logs", "/private/var/log", "/var/log", "/Users/Deleted Users"]
    /// Where an app bundle may be, wherever else it is: Finder's "Uninstall with TidyMac" can point at any of these.
    static let applicationRoots = ["/Applications", "/Users/Shared", "/Volumes"]
    /// Folders only their contents may leave when `rm` does the removing. Space Lens can still send them to the Trash,
    /// with a warning, because that can be undone.
    static let homeRoots = ["Library/Caches", "Library/Logs", "Library/Developer", ".cache", ".config", ".ssh", ".gnupg"]

    /// Why `url` must not be removed, or nil when it may be. `permanent` is for removals that skip the Trash.
    public static func refusal(for url: URL, permanent: Bool = false, home: URL = Paths.home) -> String? {
        let literal = url.standardizedFileURL.path, literalHome = home.standardizedFileURL.path
        let reason = check(literal, home: literalHome, permanent: permanent)
            ?? check(physicalPath(literal), home: resolved(literalHome), permanent: permanent)
        if let reason { return reason }
        return permanent && isProtectedByMacOS(url) ? String(localized: "Protected by macOS") : nil
    }

    static func check(_ path: String, home: String, permanent: Bool) -> String? {
        func isInside(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        if path == home || SpaceLens.protection(of: URL(fileURLWithPath: path), home: URL(fileURLWithPath: home)) == .essential {
            return String(localized: "Protected folder")
        }
        if systemTrees.contains(where: isInside) { return String(localized: "Protected system folder") }
        if cloudState.contains(where: { isInside(home + "/" + $0) }) { return String(localized: "Used by iCloud sync") }
        if path.hasPrefix("/Users/"), !isInside(home), !isInside("/Users/Shared"), !isInside("/Users/Deleted Users") {
            return String(localized: "Another user's files")
        }
        guard permanent else { return nil }
        if homeRoots.contains(where: { path == home + "/" + $0 }) { return String(localized: "Protected folder") }
        if isInside(home + "/Library/Mobile Documents") || isInside(home + "/Library/CloudStorage") { return String(localized: "Stored in the cloud") }
        return isInside(home) || mayGoForGood(path) ? nil : String(localized: "Protected folder")
    }

    /// Outside the home folder: an item in a Trash bin, an app bundle or something in `permanentRoots` that is not Apple's.
    static func mayGoForGood(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        if hasTrashFolder(parent) { return true }
        // "/Volumes/Backup.app" would be a whole drive, not an app.
        if (path as NSString).pathExtension == "app", parent != "/Volumes", applicationRoots.contains(where: { path.hasPrefix($0 + "/") }) { return true }
        guard let root = permanentRoots.first(where: { path.hasPrefix($0 + "/") }) else { return false }
        if logRoots.contains(root) { return true }
        let item = path.dropFirst(root.count + 1).prefix { $0 != "/" }
        return item != "Apple" && !item.hasPrefix("com.apple.")
    }

    /// True for an item that sits in a Trash bin, where it is written and where it really is.
    public static func isInsideTrash(_ url: URL) -> Bool {
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        return [parent, resolved(parent)].allSatisfy(hasTrashFolder)
    }

    static func hasTrashFolder(_ folder: String) -> Bool {
        folder.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// True when both where `url` is written and where it really leads stay in the home folder, or it is an app in
    /// /Applications. A link in the home folder can point at another drive; only the link itself counts as being here.
    static func isTrashable(_ url: URL, home: String) -> Bool {
        func allowed(_ path: String, home: String) -> Bool {
            path.hasPrefix(home + "/") || (path.hasPrefix("/Applications/") && (path as NSString).pathExtension == "app")
        }
        let literal = url.standardizedFileURL.path
        return allowed(literal, home: home) && allowed(physicalPath(literal), home: resolved(home))
    }

    /// True for SIP-protected or locked items, which even an administrator cannot delete: BSD flags carry
    /// SF_RESTRICTED, SF_IMMUTABLE or UF_IMMUTABLE, or the item has the `com.apple.rootless` attribute.
    public static func isProtectedByMacOS(_ url: URL) -> Bool {
        let path = url.path
        var info = stat()
        let sfRestricted: UInt32 = 0x0008_0000 // Not exported to Swift.
        if lstat(path, &info) == 0, info.st_flags & (sfRestricted | UInt32(SF_IMMUTABLE) | UInt32(UF_IMMUTABLE)) != 0 { return true }
        return getxattr(path, "com.apple.rootless", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Where a path really is. A symbolic link at the end stays as it is, since it is the link that gets removed.
    static func physicalPath(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return resolved(path) }
        let url = URL(fileURLWithPath: path)
        return URL(fileURLWithPath: resolved(url.deletingLastPathComponent().path)).appendingPathComponent(url.lastPathComponent).path
    }

    /// `realpath` for a path that may not exist yet: its deepest existing folder is resolved. It also restores the
    /// real letter case, so `/SYSTEM` cannot get past a comparison with `/System`.
    static func resolved(_ path: String) -> String {
        var ancestor = URL(fileURLWithPath: path)
        var missing: [String] = []
        while ancestor.path != "/" {
            if let r = realpath(ancestor.path, nil) {
                defer { free(r) }
                return missing.reversed().reduce(URL(fileURLWithPath: String(cString: r))) { $0.appendingPathComponent($1) }.path
            }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return path
    }
}
