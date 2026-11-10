@testable import Gyaim
import InputMethodKit
import XCTest

/// BUG-048: a composition that ends without `insertText` must still clear the
/// client's marked text. Drives a real controller with a mock client.
final class KanaConfirmMarkedTextTests: XCTestCase {
    private var savedHiraganaChar: UInt8 = 0

    override func setUp() {
        super.setUp()
        savedHiraganaChar = KeyBindings.shared.hiraganaChar
        KeyBindings.shared.hiraganaChar = UInt8(ascii: ";")
    }

    override func tearDown() {
        KeyBindings.shared.hiraganaChar = savedHiraganaChar
        super.tearDown()
    }

    func testKanaConfirmOnConsonantsClearsMarkedText() throws {
        let client = MockIMKTextInput()
        let controller = try XCTUnwrap(GyaimController(server: nil, delegate: nil, client: nil))

        for key in ["k", "l", "j", "f"] {
            XCTAssertTrue(controller.handle(try XCTUnwrap(NSEventFactory.keyDown(key)), client: client))
        }
        client.markedTexts.removeAll()
        XCTAssertTrue(controller.handle(try XCTUnwrap(NSEventFactory.keyDown(";")), client: client))

        XCTAssertEqual(client.insertedTexts, [], "consonants alone convert to nothing")
        XCTAssertEqual(client.markedTexts.last, "", "the underlined kljf must be cleared from the client")

        // The composition is over: Backspace goes back to the client.
        XCTAssertFalse(controller.handle(try XCTUnwrap(NSEventFactory.backspace()), client: client))
    }
}
