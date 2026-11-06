import XCTest
@testable import TidyCore

extension TidyCoreTests {
    func testGuardRefusesSystemOtherUsersAndCloudState() {
        let home = URL(fileURLWithPath: "/Users/me")
        func refused(_ path: String, permanent: Bool = false) -> Bool {
            RemovalGuard.refusal(for: URL(fileURLWithPath: path), permanent: permanent, home: home) != nil
        }
        for path in ["/", "/System", "/System/Library/Fonts", "/Library", "/Applications", "/Users", "/usr/bin/ssh", "/etc/hosts",
                     "/private/etc/hosts", "/sbin/mount", "/Users/me", "/Users/me/Documents", "/Users/me/Library/Keychains",
                     "/Users/other/Documents/notes.txt"] {
            XCTAssertTrue(refused(path), path)
        }
        for path in ["/Users/me/Library/Caches/com.apple.bird", "/Users/me/Library/Caches/CloudKit/db",
                     "/Users/me/Library/Application Support/FileProvider/x", "/Users/me/Library/Daemon Containers/x"] {
            XCTAssertTrue(refused(path), path)
        }
        for path in ["/Users/me/Library/Caches/com.acme.app", "/Users/me/.npm/_cacache", "/Applications/Foo.app"] {
            XCTAssertFalse(refused(path), path)
        }
        // A wrong letter case reaches the same folder on a default Mac volume.
        XCTAssertTrue(refused("/SYSTEM/Library"))
    }

    func testGuardIsStricterWhenThereIsNoTrashToGoBackTo() {
        let home = URL(fileURLWithPath: "/Users/me")
        func refused(_ path: String, permanent: Bool) -> Bool {
            RemovalGuard.refusal(for: URL(fileURLWithPath: path), permanent: permanent, home: home) != nil
        }
        // Space Lens may still send these to the Trash, with its warning.
        for path in ["/Users/me/Library/Caches", "/Users/me/Library/Developer", "/Users/me/Library/Mobile Documents/x"] {
            XCTAssertFalse(refused(path, permanent: false), path)
            XCTAssertTrue(refused(path, permanent: true), path)
        }
        for path in ["/Library/Caches", "/Library/Application Support", "/private/var/log", "/Users/Deleted Users"] {
            XCTAssertTrue(refused(path, permanent: true), path)
        }
        // Their contents are what the scans offer.
        for path in ["/Library/Caches/com.acme.app", "/Library/Application Support/Acme", "/private/var/log/system.log.0.gz",
                     "/Users/Deleted Users/old.dmg", "/Library/PrivilegedHelperTools/com.acme.helper"] {
            XCTAssertFalse(refused(path, permanent: true), path)
        }
    }

    func testGuardFollowsFoldersThatAreSymbolicLinks() throws {
        let fm = FileManager.default
        let home = tmp.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/System")
        // What is behind the link is what would be removed.
        XCTAssertNotNil(RemovalGuard.refusal(for: link.appendingPathComponent("Library"), home: home))
        // The link itself is only a link: removing it leaves /System alone.
        XCTAssertNil(RemovalGuard.refusal(for: link, home: home))
    }

    func testPermanentDeleteOnlyInsideARealTrash() throws {
        let fm = FileManager.default
        XCTAssertTrue(RemovalGuard.isInsideTrash(URL(fileURLWithPath: "/Users/me/.Trash/old.zip")))
        XCTAssertTrue(RemovalGuard.isInsideTrash(URL(fileURLWithPath: "/Volumes/USB/.Trashes/501/old.zip")))
        XCTAssertFalse(RemovalGuard.isInsideTrash(URL(fileURLWithPath: "/Users/me/.TrashOld/old.zip")))
        XCTAssertFalse(RemovalGuard.isInsideTrash(URL(fileURLWithPath: "/Users/me/.Trash")))
        // A link inside a Trash does not make what is behind it trash.
        let docs = tmp.appendingPathComponent("docs")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let trash = tmp.appendingPathComponent(".Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: trash.appendingPathComponent("link").path, withDestinationPath: docs.path)
        XCTAssertFalse(RemovalGuard.isInsideTrash(trash.appendingPathComponent("link/report.txt")))
        XCTAssertTrue(RemovalGuard.isInsideTrash(trash.appendingPathComponent("report.txt")))
    }

    func testExecutorRefusesProtectedAdminDeleteWithoutAskingForAPassword() async {
        let u = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let r = await Executor.run([ResultItem(title: "Finder", url: u, action: .adminDelete(u))])
        XCTAssertTrue(r.succeeded.isEmpty)
        XCTAssertEqual(r.failed.first?.1, "Protected folder")
    }

    func testLockedFilesCountAsProtected() throws {
        let u = try write("locked.bin", 10)
        XCTAssertFalse(RemovalGuard.isProtectedByMacOS(u))
        XCTAssertEqual(chflags(u.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(u.path, 0) }
        XCTAssertTrue(RemovalGuard.isProtectedByMacOS(u))
        XCTAssertEqual(RemovalGuard.refusal(for: u, permanent: true), "Protected by macOS")
    }

    func testDuplicatesIgnoreHardLinks() throws {
        let fm = FileManager.default
        let a = try write("a/one.bin", 200_000, byte: 7)
        try fm.createDirectory(at: tmp.appendingPathComponent("b"), withIntermediateDirectories: true)
        try fm.linkItem(at: a, to: tmp.appendingPathComponent("b/link.bin"))
        XCTAssertTrue(ClutterEngine.duplicates(ClutterEngine.index(tmp)).items.isEmpty)
    }

    func testDuplicateIsVerifiedAgainBeforeRemoval() throws {
        let fm = FileManager.default
        let keep = try write("a/keep.bin", 200_000, byte: 7)
        let copy = try write("b/copy.bin", 200_000, byte: 7)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -1000)], ofItemAtPath: copy.path)
        let item = try XCTUnwrap(ClutterEngine.duplicates(ClutterEngine.index(tmp)).items.first)
        guard case .trashDuplicate(let url, let keeping, let digest) = item.action else { return XCTFail("\(item.action)") }
        XCTAssertEqual(url.lastPathComponent, "copy.bin")
        XCTAssertEqual(keeping.lastPathComponent, "keep.bin")
        XCTAssertNoThrow(try Executor.verifyDuplicate(copy, of: keep, digest: digest))

        // The kept copy changed: the other one may now be the only good version.
        try Data(repeating: 9, count: 200_000).write(to: keep)
        XCTAssertThrowsError(try Executor.verifyDuplicate(copy, of: keep, digest: digest))

        // The kept copy became another name for the same file.
        try fm.removeItem(at: keep)
        try fm.linkItem(at: copy, to: keep)
        XCTAssertThrowsError(try Executor.verifyDuplicate(copy, of: keep, digest: digest))

        // The kept copy became a link pointing at the file about to be removed.
        try fm.removeItem(at: keep)
        try fm.createSymbolicLink(at: keep, withDestinationURL: copy)
        XCTAssertThrowsError(try Executor.verifyDuplicate(copy, of: keep, digest: digest))

        // The kept copy is gone.
        try fm.removeItem(at: keep)
        XCTAssertThrowsError(try Executor.verifyDuplicate(copy, of: keep, digest: digest))
    }

    func testShellFindsToolsOutsideTheSystemFolders() {
        let home = URL(fileURLWithPath: "/Users/me")
        let env = Shell.environment(["PATH": "/usr/bin:/bin", "LANG": "fr_FR"], home: home)
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/Users/me/.local/bin")
        XCTAssertEqual(env["LANG"], "fr_FR")
        XCTAssertEqual(Shell.environment(["PATH": "/usr/local/bin:/usr/bin"], home: home)["PATH"],
                       "/usr/local/bin:/usr/bin:/opt/homebrew/bin:/Users/me/.local/bin", "no duplicates")
        XCTAssertTrue(Shell.environment([:], home: home)["PATH"]?.hasPrefix("/usr/bin:/bin:/usr/sbin:/sbin:") ?? false)
        XCTAssertTrue(Shell.run("/bin/sh", ["-c", "echo $PATH"]).output.contains("/opt/homebrew/bin"))
    }

    func testCloudCachesAreNeverOffered() {
        for name in ["com.apple.bird", "CloudKit", "com.apple.cloudkit", "com.apple.cloudd", "com.apple.FileProvider"] {
            XCTAssertTrue(CleanupEngine.protectedCaches.contains(name), name)
        }
    }

    func testDeveloperToolCaches() throws {
        let home = tmp!
        for p in [".npm/_cacache/data", ".gradle/caches/data", "Library/pnpm/store/data", ".m2/repository/data",
                  ".cache/puppeteer/data", ".pub-cache/hosted/data", ".pub-cache/bin/tool", ".npm/_npx/data", ".cargo/credentials.toml"] {
            _ = try write(p, 5_000)
        }
        let g = CleanupEngine.devToolCaches(home: home)
        XCTAssertEqual(g.id, "dev-tools")
        let selected = Set(g.items.filter(\.selectedByDefault).map(\.title))
        XCTAssertEqual(selected, ["npm: _cacache", "Gradle: caches", "Dart pub: hosted"])
        XCTAssertEqual(Set(g.items.filter { !$0.selectedByDefault }.map(\.title)), ["pnpm: store", "Maven: repository", "Puppeteer: puppeteer"])
        XCTAssertTrue(g.items.allSatisfy { ($0.size ?? 0) > 0 && $0.category == "dev-tools" })
        for item in g.items { guard case .trash = item.action else { return XCTFail("\(item.title) must go to the Trash") } }
    }

    func testDeveloperToolCachesStayClearOfOtherCategories() {
        XCTAssertEqual(Set(CleanupEngine.devCaches.map(\.path)).count, CleanupEngine.devCaches.count)
        for (path, tool, _) in CleanupEngine.devCaches {
            XCTAssertFalse(path.hasPrefix("Library/Caches/"), "User Cache Files already covers \(tool)")
            XCTAssertNil(RemovalGuard.refusal(for: Paths.home(path), permanent: false), path)
        }
        XCTAssertFalse(CleanupEngine.unattended.contains("dev-tools"), "downloading it all again should be a choice")
        XCTAssertTrue(CleanupEngine.categories.contains { $0.id == "dev-tools" })
        XCTAssertEqual(ActivityCategory(group: "dev-tools"), .systemJunk)
        XCTAssertEqual(IgnoreList.Section(group: "dev-tools"), .systemJunk)
    }
}
