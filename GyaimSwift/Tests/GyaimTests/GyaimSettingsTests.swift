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

    func testSetWritesOnlyTheSettingsFileNotUserDefaults() throws {
        // ADR-027: settings.json is the only write target in production
        // (override set => production path).
        GyaimSettings.set(true, forKey: "settingsTestFlag")
        GyaimSettings.set(Data([0x01]), forKey: "settingsTestData")

        XCTAssertNil(UserDefaults.standard.object(forKey: "settingsTestFlag"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "settingsTestData"))
        XCTAssertTrue(GyaimSettings.bool(forKey: "settingsTestFlag"))
    }

    func testRemoveObjectClearsFileAndLegacyUserDefaults() throws {
        GyaimSettings.set(true, forKey: "settingsTestFlag")
        UserDefaults.standard.set(true, forKey: "settingsTestFlag")

        GyaimSettings.removeObject(forKey: "settingsTestFlag")

        XCTAssertFalse(GyaimSettings.bool(forKey: "settingsTestFlag"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "settingsTestFlag"))
    }

    func testSynchronizeDoesNotCopyFileValuesBackToUserDefaults() throws {
        GyaimSettings.set(false, forKey: "aiRerankFastContextEnabled")
        defer { GyaimSettings.removeObject(forKey: "aiRerankFastContextEnabled") }

        GyaimSettings.synchronizeFileAndUserDefaults()

        XCTAssertNil(UserDefaults.standard.object(forKey: "aiRerankFastContextEnabled"))
        XCTAssertFalse(GyaimSettings.bool(forKey: "aiRerankFastContextEnabled", default: true))
    }

    /// Every settings key literal in Sources/Gyaim must be in `knownKeys`, and
    /// every known key must still be used somewhere, so the migration list and
    /// docs/specs/settings.md cannot drift from the code.
    func testKnownKeysMatchSettingsKeysUsedInSources() throws {
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Gyaim")
        let files = try FileManager.default.contentsOfDirectory(atPath: sourcesDir.path)
            .filter { $0.hasSuffix(".swift") && $0 != "GyaimSettings.swift" }

        let literalPattern = try NSRegularExpression(pattern: #"forKey:\s*"([A-Za-z]+)""#)
        let constantPattern = try NSRegularExpression(pattern: #"[kK]ey\s*=\s*"([A-Za-z]+)""#)
        var used = Set<String>()
        for file in files {
            let text = try String(contentsOf: sourcesDir.appendingPathComponent(file), encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for pattern in [literalPattern, constantPattern] {
                for match in pattern.matches(in: text, range: range) {
                    if let keyRange = Range(match.range(at: 1), in: text) {
                        used.insert(String(text[keyRange]))
                    }
                }
            }
        }
        // Environment-variable names share the `...Key = "..."` shape but are not settings.
        used = used.filter { !$0.hasPrefix("GYAIM_") }

        let known = Set(GyaimSettings.knownKeys)
        XCTAssertEqual(used.subtracting(known), [], "settings keys used in Sources but missing from knownKeys")
        XCTAssertEqual(known.subtracting(used), [], "knownKeys no code reads any more")
    }

    func testSynchronizeMigratesKnownUserDefaultsKeyToSettingsJson() throws {
        UserDefaults.standard.set(false, forKey: "aiRerankFastContextEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "aiRerankFastContextEnabled") }

        GyaimSettings.synchronizeFileAndUserDefaults()
        UserDefaults.standard.removeObject(forKey: "aiRerankFastContextEnabled")

        XCTAssertFalse(GyaimSettings.bool(forKey: "aiRerankFastContextEnabled", default: true))
    }
}
