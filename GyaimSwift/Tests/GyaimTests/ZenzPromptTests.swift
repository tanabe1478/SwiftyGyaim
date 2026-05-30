@testable import Gyaim
import XCTest

final class ZenzPromptTests: XCTestCase {
    func testPromptUsesZenzControlTagsAndKatakanaInput() {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "henkan",
            hiragana: "へんかん",
            context: nil,
            candidates: []
        )

        XCTAssertEqual(BundledZenzRuntime.prompt(for: request), "\u{EE00}ヘンカン\u{EE01}")
    }

    func testPromptIncludesTrimmedContext() {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "kinou",
            hiragana: "きのう",
            context: " 昨日は ",
            candidates: []
        )

        XCTAssertEqual(BundledZenzRuntime.prompt(for: request), "\u{EE02}昨日は\u{EE00}キノウ\u{EE01}")
    }
}
