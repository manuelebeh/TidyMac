import XCTest
@testable import TidyCore

/// Translated texts must not leak into logic. The strings themselves are checked by Packaging/check-translations.sh.
final class LocalizationTests: XCTestCase {
    func testBatteryLabelsKeepTheirFixedValue() {
        let battery = SystemMonitor.BluetoothDevice.Battery(label: "Case", percent: 10)
        XCTAssertEqual(battery.label, "Case", "`lowest` recognizes the charging case by this value")
        XCTAssertEqual(SystemMonitor.BluetoothDevice.Battery(label: "", percent: 10).title, "")
    }

    func testToolSearchLooksInTheDescription() {
        let securitySettings = Toolbox.tools.first { $0.id == "securitySettings" }!
        XCTAssertTrue(securitySettings.matches("integrity protection"))
        XCTAssertTrue(securitySettings.matches("INTEGRITY"), "case does not matter")
        XCTAssertFalse(securitySettings.matches("no such words"))
    }

    func testToolSearchIgnoresAccents() {
        let tool = Tool(id: "t", title: "Sécurité", description: "Réglages", symbol: "lock", module: "protection", scanTitle: "", keywords: [], kind: .screenCleaning)
        XCTAssertTrue(tool.matches("securite"))
        XCTAssertTrue(tool.matches("reglages"))
    }

    func testStoredRawValuesStayEnglish() {
        XCTAssertEqual(GeneralSettings.ReduceMotion.enabled.rawValue, "Enabled", "this value is saved in the settings")
    }
}
