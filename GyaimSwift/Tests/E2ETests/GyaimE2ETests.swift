import Cocoa
import XCTest

final class GyaimE2ETests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Skip if Accessibility permission not granted
        guard AXIsProcessTrusted() else {
            XCTFail("Accessibility permission required for E2E tests. Enable in System Settings > Privacy & Security > Accessibility.")
            return
        }
    }

    /// Helper: clear TextEdit content before each test
    private func prepareTextEdit() {
        E2EHelper.openTextEdit()
        // Select Gyaim input source
        XCTAssertTrue(E2EHelper.selectGyaimInputSource(), "Failed to activate Gyaim")
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func tearDownTextEdit() {
        E2EHelper.closeTextEdit()
    }

    // MARK: - Tests

    func testBasicRomajiInputAndCommit() {
        prepareTextEdit()
        defer { tearDownTextEdit() }

        // Type "a" and press Enter to commit
        E2EHelper.typeString("a")
        Thread.sleep(forTimeInterval: 0.3)
        E2EHelper.pressEnter() // exact mode search
        Thread.sleep(forTimeInterval: 0.3)
        E2EHelper.pressEnter() // commit first candidate
        Thread.sleep(forTimeInterval: 0.3)

        let result = E2EHelper.getTextViaCopy()
        // Should have committed something (at minimum "a" or a kanji)
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.isEmpty ?? true, "Expected committed text")
    }

    func testEscapeCancelsInput() {
        prepareTextEdit()
        defer { tearDownTextEdit() }

        E2EHelper.typeString("abc")
        Thread.sleep(forTimeInterval: 0.3)
        E2EHelper.pressEscape()
        Thread.sleep(forTimeInterval: 0.3)

        let result = E2EHelper.getTextViaCopy()
        // After escape, no text should be committed (or empty)
        XCTAssertTrue(result?.isEmpty ?? true, "Expected no text after escape")
    }

    func testSpaceCyclesCandidates() {
        prepareTextEdit()
        defer { tearDownTextEdit() }

        // Type "ka" which should have candidates
        E2EHelper.typeString("ka")
        Thread.sleep(forTimeInterval: 0.3)
        E2EHelper.pressSpace() // move to next candidate
        Thread.sleep(forTimeInterval: 0.2)
        E2EHelper.pressEnter() // commit
        Thread.sleep(forTimeInterval: 0.3)

        let result = E2EHelper.getTextViaCopy()
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.isEmpty ?? true, "Expected committed text after space+enter")
    }
}
