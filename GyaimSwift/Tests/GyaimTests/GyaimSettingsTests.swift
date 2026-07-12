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
        GyaimSettings.cacheRevalidationInterval = 0
        UserDefaults.standard.removeObject(forKey: "settingsTestFlag")
        UserDefaults.standard.removeObject(forKey: "settingsTestData")
    }

    override func tearDownWithError() throws {
        GyaimSettings.settingsFilePathOverride = nil
        GyaimSettings.cacheRevalidationInterval = 0.2
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

    func testCachedReadsReflectExternalFileEdits() throws {
        // BUG-027: reads are served from an mtime-invalidated cache. An
        // external edit to settings.json (different modification date) must
        // still be picked up — same hot-reload semantics as localdict.
        GyaimSettings.set(true, forKey: "settingsTestFlag")
        XCTAssertTrue(GyaimSettings.bool(forKey: "settingsTestFlag"))
        UserDefaults.standard.removeObject(forKey: "settingsTestFlag")

        let external = #"{"settingsTestFlag": false}"#
        try Data(external.utf8).write(to: settingsURL, options: .atomic)

        XCTAssertFalse(GyaimSettings.bool(forKey: "settingsTestFlag"))
    }

    func testCacheFollowsPathOverrideChanges() throws {
        GyaimSettings.set(true, forKey: "settingsTestFlag")
        XCTAssertTrue(GyaimSettings.bool(forKey: "settingsTestFlag"))
        UserDefaults.standard.removeObject(forKey: "settingsTestFlag")

        let otherURL = tempDir.appendingPathComponent("other-settings.json")
        try Data(#"{"settingsTestFlag": false}"#.utf8).write(to: otherURL, options: .atomic)
        GyaimSettings.settingsFilePathOverride = otherURL.path
        defer { GyaimSettings.settingsFilePathOverride = settingsURL.path }

        XCTAssertFalse(GyaimSettings.bool(forKey: "settingsTestFlag"))
    }

    func testRepeatedReadsAreServedFromCache() throws {
        // Not a strict perf assertion — just guards the hot path against an
        // accidental return to per-read disk parsing (BUG-027): 10k cached
        // reads must finish far faster than 10k full file reads would.
        GyaimSettings.cacheRevalidationInterval = 60
        defer { GyaimSettings.cacheRevalidationInterval = 0 }
        GyaimSettings.set(true, forKey: "settingsTestFlag")
        _ = GyaimSettings.bool(forKey: "settingsTestFlag")

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10_000 {
            _ = GyaimSettings.bool(forKey: "settingsTestFlag")
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsedMs, 500)
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
