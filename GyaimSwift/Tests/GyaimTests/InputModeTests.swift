import XCTest

/// Tests for the ASCII-capable Roman passthrough mode (issue #85).
/// The mode itself is hidden from the input menu; these tests cover the
/// pure identifier→mode mapping used by setValue(_:forTag:client:).
final class InputModeTests: XCTestCase {

    func testJapaneseIdentifierMapsToJapanese() {
        XCTAssertEqual(
            GyaimController.inputMode(forTISIdentifier: "com.apple.inputmethod.Japanese"),
            .japanese
        )
    }

    func testRomanIdentifierMapsToRoman() {
        XCTAssertEqual(
            GyaimController.inputMode(forTISIdentifier: "com.apple.inputmethod.Roman"),
            .roman
        )
    }

    func testUnknownIdentifierFallsBackToJapanese() {
        XCTAssertEqual(
            GyaimController.inputMode(forTISIdentifier: "com.example.unknown"),
            .japanese
        )
    }

    func testNilIdentifierFallsBackToJapanese() {
        XCTAssertEqual(GyaimController.inputMode(forTISIdentifier: nil), .japanese)
    }

    func testInputModeRawValuesMatchInfoPlistModeKeys() {
        XCTAssertEqual(GyaimController.InputMode.japanese.rawValue, "com.apple.inputmethod.Japanese")
        XCTAssertEqual(GyaimController.InputMode.roman.rawValue, "com.apple.inputmethod.Roman")
    }
}
