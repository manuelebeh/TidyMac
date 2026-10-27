import Foundation

public enum FileSize {
    /// Allocated size of a file or a whole directory tree. Does not follow symlinks.
    public static func allocated(_ url: URL, fm: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        func own(_ u: URL) -> (Int64, isDir: Bool, isLink: Bool) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let s = Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            return (s, v?.isDirectory ?? false, v?.isSymbolicLink ?? false)
        }
        let top = own(url)
        if !top.isDir || top.isLink { return top.0 }
        var total: Int64 = 0
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let u as URL in e { total += own(u).0 }
        return total
    }

    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
