import Foundation

/// What fills the startup disk, in the broad groups System Settings › Storage uses. Measured in the background and
/// reported as each group finishes, so the Overview bar fills in while the folders are still being sized.
public enum StorageBreakdown {
    public enum Kind: String, CaseIterable, Sendable { case applications, documents, photos, media }

    public struct Part: Sendable { public let kind: Kind; public let bytes: Int64 }

    static func folders(_ kind: Kind, home: URL) -> [URL] {
        switch kind {
        case .applications: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        case .documents: ["Documents", "Desktop", "Downloads"].map { home.appendingPathComponent($0) }
        case .photos: [home.appendingPathComponent("Pictures")]
        case .media: ["Movies", "Music"].map { home.appendingPathComponent($0) }
        }
    }

    /// Yields the groups measured so far, each time another one is done. Folders that cannot be read count as empty.
    public static func measure(home: URL = Paths.home) -> AsyncStream<[Part]> {
        AsyncStream { cont in
            let task = Task {
                await withTaskGroup(of: Part.self) { group in
                    for kind in Kind.allCases {
                        group.addTask {
                            let sizes = await withDeadline(120) { FileSize.allocated(all: folders(kind, home: home)) } ?? []
                            return Part(kind: kind, bytes: sizes.reduce(0, +))
                        }
                    }
                    var done: [Part] = []
                    for await part in group {
                        done.append(part)
                        cont.yield(done)
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
