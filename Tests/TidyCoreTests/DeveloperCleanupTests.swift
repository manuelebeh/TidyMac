import XCTest
@testable import TidyCore

extension TidyCoreTests {
    // MARK: Simulator runtimes

    func testSimulatorRuntimesAreNeverPreselectedAndHonorDeletable() throws {
        let json = #"""
        {
          "857A3F94-58AF-4EBD-AA4C-418526F656D5": {"build": "24B8117", "deletable": true, "lastUsedAt": "2026-11-05T01:27:42Z",
            "platformIdentifier": "com.apple.platform.iphonesimulator", "sizeBytes": 8315434484, "state": "Ready", "version": "27.2"},
          "C99E494F-4EE0-4AF3-B0B2-63BAB8AB47B3": {"build": "24B91016s", "deletable": true,
            "platformIdentifier": "com.apple.platform.watchsimulator", "sizeBytes": 3000000000, "version": "11.0"},
          "11111111-2222-3333-4444-555555555555": {"build": "X", "deletable": false,
            "platformIdentifier": "com.apple.platform.iphonesimulator", "sizeBytes": 1, "version": "1.0"},
          "not-a-uuid; rm -rf ~": {"build": "X", "deletable": true, "sizeBytes": 1, "version": "1.0"}
        }
        """#
        let items = CleanupEngine.simulatorRuntimeItems(json: Data(json.utf8)).sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        XCTAssertEqual(items.map(\.title), ["iOS 27.2", "watchOS 11.0"])
        XCTAssertEqual(items[0].size, 8_315_434_484)
        XCTAssertEqual(items[0].action, .shell("xcrun simctl runtime delete 857A3F94-58AF-4EBD-AA4C-418526F656D5", admin: false))
        XCTAssertNil(items[0].badge)
        XCTAssertEqual(items[1].badge, "Never Used")
        XCTAssertTrue(items.allSatisfy { !$0.selectedByDefault })
        XCTAssertTrue(CleanupEngine.simulatorRuntimeItems(json: Data()).isEmpty)
    }

    // MARK: Docker

    func testDockerReclaimableLeavesVolumesOut() {
        let output = """
        {"Active":"1","Reclaimable":"1.2GB (50%)","Size":"2.4GB","TotalCount":"5","Type":"Images"}
        {"Active":"0","Reclaimable":"300MB (100%)","Size":"300MB","TotalCount":"2","Type":"Containers"}
        {"Active":"0","Reclaimable":"9GB (100%)","Size":"9GB","TotalCount":"3","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"500kB","Size":"500kB","TotalCount":"1","Type":"Build Cache"}
        WARNING: something on the shared error pipe
        """
        XCTAssertEqual(CleanupEngine.dockerReclaimable(output), 1_200_000_000 + 300_000_000 + 500_000)
        XCTAssertEqual(CleanupEngine.dockerReclaimable(""), 0)
        XCTAssertEqual(CleanupEngine.decimalBytes("0B (0%)"), 0)
        XCTAssertEqual(CleanupEngine.decimalBytes("4.5TB"), 4_500_000_000_000)
        XCTAssertEqual(CleanupEngine.decimalBytes("nonsense"), 0)
    }

    // MARK: Project build folders

    func testProjectArtifactsNeedEvidenceOfAProject() throws {
        for p in ["web/package.json", "web/node_modules/a.bin", "rust/Cargo.toml", "rust/target/a.bin", "py/.venv/pyvenv.cfg", "py/.venv/a.bin",
                  "cpp/CMakeLists.txt", "cpp/cmake-build-debug/a.bin", "swift/Package.swift", "swift/.build/a.bin"] {
            _ = try write(p, p.hasSuffix("a.bin") ? 20_000 : 10)
        }
        // Same names, nothing around them to show they can be recreated.
        for p in ["shop/target/plan.pdf", "docs/node_modules/a.bin", "py2/venv/a.bin", ".gradle/caches/a.bin", "app/.gradle/a.bin"] {
            _ = try write(p, 20_000)
        }
        let g = ClutterEngine.projectArtifacts(root: tmp, minSize: 1)
        XCTAssertEqual(Set(g.items.map(\.title)),
                       ["web: node_modules", "rust: target", "py: .venv", "cpp: cmake-build-debug", "swift: .build"])
    }

    func testProjectArtifactsSkipTheirContentsAndHiddenFolders() throws {
        for p in ["web/package.json", "web/node_modules/a.bin", "web/node_modules/dep/package.json", "web/node_modules/dep/node_modules/b.bin",
                  ".hidden/package.json", ".hidden/node_modules/a.bin"] {
            _ = try write(p, 20_000)
        }
        let g = ClutterEngine.projectArtifacts(root: tmp, minSize: 1)
        XCTAssertEqual(g.items.map(\.title), ["web: node_modules"])
        XCTAssertEqual(g.id, "project-artifacts")
        guard case .trash = g.items[0].action else { return XCTFail("must go to the Trash") }
    }

    func testOnlyArtifactsOfIdleProjectsArePreselected() throws {
        let fm = FileManager.default
        let long = Date(timeIntervalSinceNow: -200 * 86_400)
        for p in ["idle/package.json", "idle/node_modules/a.bin", "busy/package.json", "busy/node_modules/a.bin",
                  "edited/package.json", "edited/node_modules/a.bin"] {
            _ = try write(p, 20_000)
        }
        // `busy` was just installed, `edited` only has a recent change to its project file.
        for p in ["idle/package.json", "idle/node_modules", "idle", "edited/node_modules", "edited"] {
            try fm.setAttributes([.modificationDate: long], ofItemAtPath: tmp.appendingPathComponent(p).path)
        }
        let items = ClutterEngine.projectArtifacts(root: tmp, minSize: 1).items
        let selected = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0.selectedByDefault) })
        XCTAssertEqual(selected, ["idle: node_modules": true, "busy: node_modules": false, "edited: node_modules": false])
        XCTAssertEqual(items.first { $0.title == "idle: node_modules" }?.badge, "Stale")
    }

    func testProjectArtifactsRespectTheMinimumSize() throws {
        _ = try write("web/package.json", 10)
        _ = try write("web/node_modules/a.bin", 1_000)
        XCTAssertTrue(ClutterEngine.projectArtifacts(root: tmp).items.isEmpty)
    }

    // MARK: Security settings

    func testSecuritySettingsReadRealOutput() {
        func status(_ id: String, _ output: String) -> ProtectionEngine.SecurityStatus {
            ProtectionEngine.securityChecks.first { $0.id == id }!.status(output)
        }
        XCTAssertEqual(status("gatekeeper", "assessments enabled"), .on)
        XCTAssertEqual(status("gatekeeper", "assessments disabled"), .off)
        XCTAssertEqual(status("filevault", "FileVault is On."), .on)
        XCTAssertEqual(status("filevault", "FileVault is Off."), .off)
        XCTAssertEqual(status("firewall", "Firewall is enabled. (State = 1)"), .on)
        XCTAssertEqual(status("firewall", "Firewall is disabled. (State = 0)"), .off)
        XCTAssertEqual(status("sip", "System Integrity Protection status: enabled."), .on)
        XCTAssertEqual(status("sip", "System Integrity Protection status: disabled."), .off)
        // Partly off is not reported as on.
        XCTAssertEqual(status("sip", "System Integrity Protection status: enabled (Custom Configuration)."), .unknown)
    }

    func testSecurityGroupListsOnlyWhatNeedsAttention() {
        let ok = Shell.Result(status: 0, output: "")
        func result(_ output: String) -> Shell.Result { Shell.Result(status: 0, output: output) }
        let allOn = ["gatekeeper": result("assessments enabled"), "filevault": result("FileVault is On."),
                     "firewall": result("Firewall is enabled. (State = 1)"), "sip": result("System Integrity Protection status: enabled.")]
        XCTAssertTrue(ProtectionEngine.securityGroup(results: allOn).isEmpty)

        var some = allOn
        some["filevault"] = result("FileVault is Off.")
        some["firewall"] = Shell.Result(status: 1, output: "Firewall is enabled. (State = 1)")
        some["sip"] = ok
        let items = ProtectionEngine.securityGroup(results: some).items
        XCTAssertEqual(items.map(\.title), ["FileVault", "Firewall", "System Integrity Protection"])
        XCTAssertEqual(items.map(\.badge), ["Off", "Unknown", "Unknown"], "a failed command proves nothing")
        XCTAssertTrue(items.allSatisfy { !$0.selectedByDefault })
    }

    // MARK: Homebrew

    func testHomebrewOutdatedParsing() {
        let json = """
        {"formulae": [], "casks": [
          {"name": "iina", "installed_versions": ["1.4.2,164"], "current_version": "1.5.0,170", "pinned": false, "pinned_version": null},
          {"name": "temurin@17", "installed_versions": ["17.0.1"], "current_version": "17.0.2", "pinned": false},
          {"name": "held", "installed_versions": ["1"], "current_version": "2", "pinned": true},
          {"name": "bad; rm -rf ~", "installed_versions": ["1"], "current_version": "2", "pinned": false}
        ]}
        """
        XCTAssertEqual(ApplicationsEngine.parseHomebrewOutdated(Data(json.utf8)), [
            .init(token: "iina", current: "1.4.2", latest: "1.5.0"),
            .init(token: "temurin@17", current: "17.0.1", latest: "17.0.2"),
        ])
        XCTAssertTrue(ApplicationsEngine.parseHomebrewOutdated(Data()).isEmpty)
    }

    func testHomebrewUpdateItemUpgradesOnlyWhenAsked() {
        let u = ApplicationsEngine.HomebrewUpdate(token: "visual-studio-code", current: "1", latest: "2")
        XCTAssertFalse(u.item.selectedByDefault)
        XCTAssertEqual(u.item.action, .shell("HOMEBREW_NO_ANALYTICS=1 brew upgrade --cask 'visual-studio-code'", admin: false))
        XCTAssertTrue(u.isSameApp(as: InstalledApp(url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
                                                   name: "Visual Studio Code", bundleID: nil, size: 0)))
        XCTAssertFalse(u.isSameApp(as: InstalledApp(url: URL(fileURLWithPath: "/Applications/Xcode.app"), name: "Xcode", bundleID: nil, size: 0)))
    }

    func testJSONIsFoundAmongToolWarnings() {
        let r = Shell.Result(status: 0, output: "Warning: something\n{\"casks\": []}\nWarning: more")
        XCTAssertEqual(String(decoding: r.jsonObject, as: UTF8.self), "{\"casks\": []}")
        XCTAssertTrue(Shell.Result(status: 0, output: "no json").jsonObject.isEmpty)
    }

    // MARK: Full Disk Access

    func testPermissionErrorsAreRecognizedByCodeNotByMessage() {
        XCTAssertTrue(Executor.blockedByMacOS(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        XCTAssertTrue(Executor.blockedByMacOS(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        XCTAssertTrue(Executor.blockedByMacOS(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        XCTAssertFalse(Executor.blockedByMacOS(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
        XCTAssertFalse(Executor.blockedByMacOS(Executor.Failure("Outside home folder")))
    }

    func testRetryReportKeepsEarlierResultsAndNeverRetriesTwice() {
        func item(_ name: String) -> ResultItem { ResultItem(title: name, size: 10, action: .shell("true", admin: false)) }
        var first = ActionReport()
        first.succeeded = [item("done")]
        first.failed = [(item("blocked"), "No permission"), (item("still-blocked"), "No permission"), (item("in-use"), "In use")]
        first.needsAccess = [item("blocked"), item("still-blocked")]
        var retry = ActionReport()
        retry.succeeded = [item("blocked")]
        retry.failed = [(item("still-blocked"), "No permission")]
        retry.needsAccess = [item("still-blocked")]
        let merged = first.merging(retry: retry)
        XCTAssertEqual(merged.succeeded.map(\.title), ["done", "blocked"])
        XCTAssertEqual(Set(merged.failed.map(\.0.title)), ["still-blocked", "in-use"])
        XCTAssertTrue(merged.needsAccess.isEmpty)
        XCTAssertEqual(merged.freed, 20)
    }

    // MARK: Catalog

    func testNewGroupsAreMappedEverywhere() {
        for id in ["sim-runtimes", "docker", "project-artifacts"] {
            XCTAssertEqual(ActivityCategory(group: id), .systemJunk, id)
            XCTAssertEqual(IgnoreList.Section(group: id), .systemJunk, id)
            XCTAssertFalse(CleanupEngine.unattended.contains(id), id)
        }
        XCTAssertTrue(Toolbox.tools.contains { $0.id == "developerJunk" && $0.matches("node_modules") })
        XCTAssertTrue(Toolbox.tools.contains { $0.id == "securitySettings" && $0.matches("filevault") })
    }
}
