import Foundation

/// What hides in the "System Data" part of the disk: things macOS keeps out of sight that can be checked or freed.
/// Each part is measured in the background and reported as soon as it is done, like `StorageBreakdown`.
public enum SystemData {
    public enum Kind: String, CaseIterable, Sendable {
        case snapshots, appleIntelligence, caches, developer, localModels, deviceFiles, swap
    }

    public struct Entry: Identifiable, Sendable, Equatable {
        public var id: String { kind.rawValue }
        public let kind: Kind
        /// nil when the size cannot be known: snapshots, or a folder that needs Full Disk Access.
        public let size: Int64?
        /// Snapshots: how many there are.
        public var count: Int = 0
        /// Apple Intelligence: the size of each kind of model, Apple's figures.
        public var models: [AppleModels.Part] = []
    }

    /// Below this a sized part is not worth a row.
    public static let minimumSize: Int64 = 100_000_000

    static func cacheFolders(home: URL) -> [URL] { ["Library/Caches", "Library/Logs"].map { home.appendingPathComponent($0) } }

    static func developerFolders(home: URL, fullDiskAccess: Bool) -> [URL] {
        var urls = [home.appendingPathComponent("Library/Developer")]
        // Another app's container: without Full Disk Access, reading it asks the user for permission.
        if fullDiskAccess { urls.append(home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms")) }
        return urls
    }

    static func modelFolders(home: URL) -> [URL] {
        [".ollama/models", ".lmstudio/models", ".cache/lm-studio/models", ".cache/huggingface"].map { home.appendingPathComponent($0) }
    }

    static func backupFolder(home: URL) -> URL { home.appendingPathComponent("Library/Application Support/MobileSync/Backup") }

    static func updateFolders(home: URL) -> [URL] {
        ["iPhone", "iPad", "iPod"].map { home.appendingPathComponent("Library/iTunes/\($0) Software Updates") }
    }

    /// Yields the parts measured so far each time another one is done. Parts with nothing worth showing are left out,
    /// except snapshots, which say there are none.
    public static func measure(home: URL = Paths.home, fullDiskAccess: Bool = Permissions.hasFullDiskAccess) -> AsyncStream<[Entry]> {
        AsyncStream { cont in
            let task = Task {
                await withTaskGroup(of: Entry?.self) { group in
                    for kind in Kind.allCases {
                        // A folder stuck behind a privacy prompt is dropped instead of holding the others.
                        group.addTask { await withDeadline(120) { entry(kind, home: home, fullDiskAccess: fullDiskAccess) } ?? nil }
                    }
                    var done: [Entry] = []
                    for await e in group {
                        if let e { done.append(e) }
                        cont.yield(done)
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func entry(_ kind: Kind, home: URL, fullDiskAccess: Bool, minimum: Int64 = minimumSize) -> Entry? {
        func sized(_ urls: [URL]) -> Entry? {
            let size = FileSize.allocated(all: urls.filter(Paths.exists)).reduce(0, +)
            return size >= minimum ? Entry(kind: kind, size: size) : nil
        }
        switch kind {
        case .snapshots:
            let out = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).output
            return Entry(kind: kind, size: nil, count: snapshotCount(out))
        case .appleIntelligence:
            let parts = AppleModels.measure()
            let total = parts.reduce(0) { $0 + $1.bytes }
            return total >= minimum ? Entry(kind: kind, size: total, models: parts) : nil
        case .caches:
            return sized(cacheFolders(home: home))
        case .developer:
            return sized(developerFolders(home: home, fullDiskAccess: fullDiskAccess))
        case .localModels:
            return sized(modelFolders(home: home))
        case .deviceFiles:
            let backups = backupFolder(home: home)
            // The backups folder is there but cannot be read without Full Disk Access: say so rather than show too little.
            if Paths.exists(backups), (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) == nil {
                return Entry(kind: kind, size: nil)
            }
            return sized([backups] + updateFolders(home: home))
        case .swap:
            let size = swapSize() + FileSize.allocated(URL(fileURLWithPath: "/private/var/vm/sleepimage"))
            return size >= 1_000_000_000 ? Entry(kind: kind, size: size) : nil
        }
    }

    /// Lines of `tmutil listlocalsnapshots /` that name a snapshot.
    static func snapshotCount(_ output: String) -> Int {
        output.split(separator: "\n").filter { PerformanceEngine.snapshotDate($0) != nil }.count
    }

    /// Disk space the swap files take, the "total" of `sysctl vm.swapusage` (the files grow in steps, ahead of what is used).
    static func swapSize() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int64(usage.xsu_total)
    }
}
