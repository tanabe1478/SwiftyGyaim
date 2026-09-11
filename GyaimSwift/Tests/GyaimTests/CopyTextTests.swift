@testable import Gyaim
import XCTest

final class CopyTextTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Never touch the real ~/.gyaim/copytext from tests.
        CopyText.fileOverride = tempDir.appendingPathComponent("copytext").path
    }

    override func tearDownWithError() throws {
        CopyText.fileOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSetPersistsContentAndUpdatesTimestampOnlyOnChange() {
        let content = "copytext-\(UUID().uuidString)"
        CopyText.set(content)
        XCTAssertEqual(CopyText.get(), content)
        XCTAssertEqual(try? String(contentsOfFile: CopyText.file, encoding: .utf8), content)
        let timeAfterSet = CopyText.time

        Thread.sleep(forTimeInterval: 0.05)
        CopyText.set(content)
        XCTAssertEqual(CopyText.time, timeAfterSet, "Timestamp should NOT update when content is the same")

        CopyText.set(nil)
        XCTAssertEqual(CopyText.time, timeAfterSet, "set(nil) should not change timestamp")
        XCTAssertEqual(CopyText.get(), content)

        CopyText.set("copytext-\(UUID().uuidString)")
        XCTAssertGreaterThan(CopyText.time, timeAfterSet, "Timestamp should update on new content")
    }
}
