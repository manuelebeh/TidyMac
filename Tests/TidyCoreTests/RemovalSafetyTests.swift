import XCTest
@testable import TidyCore

/// Records what would go to the Trash, so tests leave the real one alone.
private final class RecordingFileManager: FileManager {
    var trashed: [URL] = []
    override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws { trashed.append(url) }
}

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
        // Storage Map may still send these to the Trash, with its warning.
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
        XCTAssertEqual(RemovalGuard.refusal(for: u, permanent: true, home: tmp), "Protected by macOS")
    }

    func testPermanentRemovalsOutsideHomeOnlyReachKnownFolders() {
        let home = URL(fileURLWithPath: "/Users/me")
        func refused(_ path: String) -> Bool { RemovalGuard.refusal(for: URL(fileURLWithPath: path), permanent: true, home: home) != nil }
        for path in ["/Library/Frameworks", "/Library/Fonts", "/Library/Keychains/System.keychain", "/Library/Security/x",
                     "/Library/Application Support/Apple", "/Library/Preferences/com.apple.loginwindow.plist",
                     "/Library/LaunchDaemons/com.apple.thing.plist", "/usr/local/bin", "/opt/homebrew", "/private/var/db/dslocal",
                     "/private/var/root", "/var/root", "/private/tmp/x", "/tmp/x", "/Volumes/USB", "/Volumes/USB/notes.txt",
                     "/Volumes/Backup.app", "/Users/Shared/notes.txt", "/Applications/Foo.app/Contents/MacOS/Foo"] {
            XCTAssertTrue(refused(path), path)
        }
        for path in ["/Library/Logs/com.apple.thing", "/private/var/log/system.log.0.gz", "/Library/LaunchDaemons/com.acme.helper.plist",
                     "/Library/Audio/Plug-Ins/VST/Acme.vst", "/Applications/Foo.app", "/Applications/Suite/Foo.app",
                     "/Users/Shared/Foo.app", "/Volumes/USB/Foo.app", "/Volumes/USB/.Trashes/501/old.zip",
                     "/Users/me/.Trash/old.zip", "/Users/me/Downloads/old.zip"] {
            XCTAssertFalse(refused(path), path)
        }
    }

    func testTrashFollowsLinksThatLeadOutOfTheHomeFolder() throws {
        let fm = RecordingFileManager()
        let home = tmp.appendingPathComponent("home"), outside = tmp.appendingPathComponent("outside")
        let kept = try write("outside/victim.txt", 1), own = try write("home/mine.txt", 1)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("link"), withDestinationURL: outside)
        let homeLink = tmp.appendingPathComponent("homeLink")
        try FileManager.default.createSymbolicLink(at: homeLink, withDestinationURL: home)

        XCTAssertThrowsError(try Executor.moveToTrash(kept, home: home.path, fm: fm))
        XCTAssertThrowsError(try Executor.moveToTrash(home.appendingPathComponent("link/victim.txt"), home: home.path, fm: fm))
        XCTAssertEqual(fm.trashed, [], "nothing behind the link moves")

        try Executor.moveToTrash(own, home: home.path, fm: fm)
        // The link itself is here, whatever it points at, and a home folder reached through a link is still the home folder.
        try Executor.moveToTrash(home.appendingPathComponent("link"), home: home.path, fm: fm)
        try Executor.moveToTrash(homeLink.appendingPathComponent("mine.txt"), home: homeLink.path, fm: fm)
        XCTAssertEqual(fm.trashed.map(\.lastPathComponent), ["mine.txt", "link", "mine.txt"])
    }

    func testLaunchItemOutsideHomeIsRefusedBeforeItIsStopped() async throws {
        let u = try write("com.acme.agent.plist", 1)
        let r = await Executor.run([ResultItem(title: "agent", url: u, action: .removeLaunchItem(u, admin: false))])
        XCTAssertEqual(r.failed.first?.1, "Outside home folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.path))
    }

    /// Names that have broken out of a quote somewhere in the past.
    static let awkwardNames = ["it's", "say \"hi\"", "back\\slash", "$(touch x)", "`touch x`", "a; rm -rf b", "-dash", "new\nline", "é ü"]

    func testCommandsReachProgramsAndShellsWordForWord() {
        for name in Self.awkwardNames {
            let command = Command("/usr/bin/printf", "%s", name)
            XCTAssertEqual(Shell.run(command.executable, command.arguments).output, name)
            XCTAssertEqual(Shell.run("/bin/sh", ["-c", command.shellText]).output, name)
        }
        let tool = Command.tool("sh", "-c", "echo found")
        XCTAssertEqual(Shell.run(tool.executable, tool.arguments).output, "found")
        let script = Command.script("echo one; echo two")
        XCTAssertEqual(Shell.run(script.executable, script.arguments).output, "one\ntwo")
    }

    func testAppleScriptStringsSurviveAnyName() throws {
        for name in Self.awkwardNames {
            XCTAssertEqual(Shell.osascript("return " + Shell.appleScriptString(name)).output, name)
            // Compiled, never run: running it is what asks for the password.
            let script = MoveToApplications.administratorScript(from: URL(fileURLWithPath: "/tmp/\(name)/TidyMac.app"),
                                                                to: URL(fileURLWithPath: "/Applications/\(name).app"))
            var error: NSDictionary?
            let compiled = try XCTUnwrap(NSAppleScript(source: Shell.administratorScript(script))).compileAndReturnError(&error)
            XCTAssertTrue(compiled, "\(name): \(String(describing: error))")
        }
    }

    func testAdministratorMoveCopiesAndReplacesWhateverTheName() throws {
        for (i, name) in Self.awkwardNames.enumerated() {
            let source = try write("\(i)/\(name).app/Contents/Info", 3, byte: 7)
            let bundle = source.deletingLastPathComponent().deletingLastPathComponent()
            let destination = try write("to\(i)/\(name).app/old", 1).deletingLastPathComponent()
            // Same script as the prompt runs, here without root.
            let r = Shell.run("/bin/sh", ["-c", MoveToApplications.administratorScript(from: bundle, to: destination)])
            XCTAssertEqual(r.status, 0, r.output)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Contents/Info").path), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old").path), name)
        }
    }

    func testAdministratorMoveRefusesAProtectedDestinationWithoutAskingForAPassword() {
        let bundle = URL(fileURLWithPath: "/tmp/TidyMac.app")
        XCTAssertThrowsError(try MoveToApplications.moveAsAdministrator(bundle, to: URL(fileURLWithPath: "/Library/Keychains")))
    }

    func testAdministratorOutcomesMatchWholeLines() {
        // `do shell script` separates lines with a return.
        let lines = Executor.outputLines("KO:1\rOK:10\rOK:2")
        XCTAssertFalse(lines.contains("OK:1"), "item 10 must not report item 1 as done")
        XCTAssertTrue(lines.contains("OK:10"))
        XCTAssertTrue(lines.contains("OK:2"))
    }

    func testMaintenanceTasksNeedTheirToolOnThisMac() {
        let ids = { (tasks: [PerformanceEngine.Task]) in tasks.map(\.id) }
        let all = ids(PerformanceEngine.tasks)
        XCTAssertEqual(ids(PerformanceEngine.availableTasks { _ in true }), all)
        XCTAssertEqual(ids(PerformanceEngine.availableTasks { $0 != "/usr/sbin/periodic" }), all.filter { $0 != "periodicScripts" })
        // A script only needs its shell, and the check has to see a path it can look up.
        XCTAssertTrue(ids(PerformanceEngine.availableTasks { $0 == "/bin/sh" }).contains("speedUpMail"))
        XCTAssertTrue(PerformanceEngine.tasks.allSatisfy { $0.command.executable.hasPrefix("/") })
        // The real check, on whichever macOS runs the tests.
        let fm = FileManager.default
        XCTAssertEqual(PerformanceEngine.availableTasks().contains { $0.id == "periodicScripts" }, fm.isExecutableFile(atPath: "/usr/sbin/periodic"))
        XCTAssertTrue(PerformanceEngine.availableTasks().contains { $0.id == "freeUpRAM" })
    }

    func testSnapshotDateOnlyComesFromASnapshotLine() {
        XCTAssertEqual(PerformanceEngine.snapshotDate("com.apple.TimeMachine.2026-11-06-101500.local"), "2026-11-06-101500")
        XCTAssertNil(PerformanceEngine.snapshotDate("Snapshots for disk /:"))
        XCTAssertNil(PerformanceEngine.snapshotDate("com.apple.TimeMachine"))
        XCTAssertNil(PerformanceEngine.snapshotDate("com.apple.TimeMachine.$(touch x).local"))
    }

    func testANewAutomationRuleAsksFirst() {
        XCTAssertEqual(Automations.Rule(name: "A", trigger: .driveConnected, categories: ["trash"]).mode, .ask)
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
