import XCTest

/// Tests for the ASCII-capable Roman passthrough mode (issue #85).
/// The mode itself is hidden from the input menu; this covers the
/// pure identifier→mode mapping used by setValue(_:forTag:client:).
final class InputModeTests: XCTestCase {

    func testTISIdentifierMapsToInputModeWithJapaneseFallback() {
        XCTAssertEqual(GyaimController.inputMode(forTISIdentifier: "com.apple.inputmethod.Japanese"), .japanese)
        XCTAssertEqual(GyaimController.inputMode(forTISIdentifier: "com.apple.inputmethod.Roman"), .roman)
        XCTAssertEqual(GyaimController.inputMode(forTISIdentifier: "com.example.unknown"), .japanese)
        XCTAssertEqual(GyaimController.inputMode(forTISIdentifier: nil), .japanese)
    }
}
