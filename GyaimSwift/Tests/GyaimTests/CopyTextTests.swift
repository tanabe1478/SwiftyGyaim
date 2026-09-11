@testable import Gyaim
import XCTest

final class CopyTextTests: XCTestCase {

    /// CI環境では ~/.gyaim/ が存在せず CopyText.set() がファイル書き込みに失敗する。
    /// ローカル開発環境では既にあるので影響なし。createDirectory は冪等。
    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(
            atPath: Config.gyaimDir,
            withIntermediateDirectories: true
        )
    }

    func testSetPersistsContentAndUpdatesTimestampOnlyOnChange() {
        let content = "copytext-\(UUID().uuidString)"
        CopyText.set(content)
        XCTAssertEqual(CopyText.get(), content)
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
