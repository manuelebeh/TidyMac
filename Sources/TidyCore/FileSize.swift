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

    /// Sizes of several folders, measured side by side: big trees can hold hundreds of thousands of files.
    public static func allocated(all urls: [URL]) -> [Int64] {
        var sizes = [Int64](repeating: 0, count: urls.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            let size = allocated(urls[i])
            lock.lock(); sizes[i] = size; lock.unlock()
        }
        return sizes
    }

    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
