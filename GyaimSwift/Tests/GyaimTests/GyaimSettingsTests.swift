@testable import Gyaim
import XCTest

final class GyaimSettingsTests: XCTestCase {
    private var tempDir: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        settingsURL = tempDir.appendingPathComponent("settings.json")
        GyaimSettings.settingsFilePathOverride = settingsURL.path
        UserDefaults.standard.removeObject(forKey: "settingsTestFlag")
        UserDefaults.standard.removeObject(forKey: "settingsTestData")
    }

    override func tearDownWithError() throws {
        GyaimSettings.settingsFilePathOverride = nil
        UserDefaults.standard.removeObject(forKey: "settingsTestFlag")
        UserDefaults.standard.removeObject(forKey: "settingsTestData")
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testSetWritesSettingsJsonAndReadsWithoutUserDefaults() throws {
        GyaimSettings.set(true, forKey: "settingsTestFlag")
        UserDefaults.standard.removeObject(forKey: "settingsTestFlag")

        XCTAssertTrue(GyaimSettings.bool(forKey: "settingsTestFlag"))

        let data = try Data(contentsOf: settingsURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["settingsTestFlag"] as? Bool, true)
    }

    func testDataRoundTripUsesBase64EntryInSettingsJson() throws {
        let value = Data([0x47, 0x59, 0x41, 0x49, 0x4D])
        GyaimSettings.set(value, forKey: "settingsTestData")
        UserDefaults.standard.removeObject(forKey: "settingsTestData")

        XCTAssertEqual(GyaimSettings.data(forKey: "settingsTestData"), value)
    }

    func testFallsBackToExistingUserDefaultsForBackwardCompatibility() {
        UserDefaults.standard.set(false, forKey: "settingsTestFlag")

        XCTAssertFalse(GyaimSettings.bool(forKey: "settingsTestFlag", default: true))
    }

    func testSynchronizeMigratesKnownUserDefaultsKeyToSettingsJson() throws {
        UserDefaults.standard.set(false, forKey: "aiRerankFastContextEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "aiRerankFastContextEnabled") }

        GyaimSettings.synchronizeFileAndUserDefaults()
        UserDefaults.standard.removeObject(forKey: "aiRerankFastContextEnabled")

        XCTAssertFalse(GyaimSettings.bool(forKey: "aiRerankFastContextEnabled", default: true))
    }
}
