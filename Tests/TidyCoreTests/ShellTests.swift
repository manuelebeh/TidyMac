import XCTest
@testable import TidyCore

final class ShellTests: XCTestCase {
    func testAProgramThatHangsIsStopped() {
        let start = Date()
        let r = Shell.run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertEqual(r.status, -2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testWhatAStoppedProgramHadWrittenIsKept() {
        let r = Shell.run("/bin/sh", ["-c", "echo started; exec sleep 30"], timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertEqual(r.output, "started")
    }

    func testAProgramThatIgnoresTheFirstSignalIsKilled() {
        let start = Date()
        let r = Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 1; done"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }

    func testAFastProgramIsNotTimedOut() {
        let r = Shell.run("/bin/sh", ["-c", "echo done"], timeout: 10)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.output, "done")
    }

    func testNoTimeoutWaitsForTheProgram() {
        let r = Shell.run("/bin/sh", ["-c", "sleep 1; echo late"], timeout: nil)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.output, "late")
    }

    func testOutputBiggerThanThePipeDoesNotStallTheProgram() {
        // A pipe holds 64 KB; a program writing more waits for someone to read.
        let r = Shell.run("/bin/sh", ["-c", "head -c 500000 /dev/zero | tr '\\0' a"], timeout: 10)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.output.utf8.count, 500_000)
    }

    func testAChildLeftBehindDoesNotHoldUpTheResult() {
        let start = Date()
        let r = Shell.run("/bin/sh", ["-c", "sleep 6 & echo hi"], timeout: 20)
        XCTAssertEqual(r.output, "hi")
        XCTAssertFalse(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testErrorsComeBackWithTheStatus() {
        let r = Shell.run("/bin/sh", ["-c", "echo oops 1>&2; exit 3"])
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.output, "oops")
    }

    func testAMissingProgramIsReportedNotThrown() {
        let r = Shell.run("/nonexistent/tool", [])
        XCTAssertEqual(r.status, -1)
        XCTAssertFalse(r.timedOut)
        XCTAssertFalse(r.output.isEmpty)
    }

    func testTheAdministratorPromptHasNoTimeLimit() throws {
        // Reading the source rather than running it: running it would ask for the password.
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/TidyCoreTests/ShellTests.swift", with: "Sources/TidyCore/Executor.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("osascript(administratorScript(script), timeout: nil)"))
    }
}
