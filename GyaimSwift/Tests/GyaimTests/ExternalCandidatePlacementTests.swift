@testable import Gyaim
import XCTest

/// External candidates sit behind the first dictionary candidate and only
/// short single-line ones are registered on commit (ADR-036).
final class ExternalCandidatePlacementTests: XCTestCase {

    func testBuildLeadsWithExternalCandidatesWhenTheDictionaryHasNothing() {
        let result = GyaimController.buildPrefixCandidates(
            searchResults: [],
            inputPat: "xyzzy",
            clipboardCandidate: "クリップ",
            selectedCandidate: "選択",
            hiragana: ""
        )
        XCTAssertEqual(result.map(\.word), ["xyzzy", "クリップ", "選択"])
    }

    func testOnlyShortSingleLineExternalCandidatesAreRegistered() {
        XCTAssertTrue(GyaimController.shouldRegisterExternalCandidate("濱野"))
        XCTAssertTrue(GyaimController.shouldRegisterExternalCandidate(String(repeating: "あ", count: 30)))
        XCTAssertFalse(GyaimController.shouldRegisterExternalCandidate(String(repeating: "あ", count: 31)))
        XCTAssertFalse(GyaimController.shouldRegisterExternalCandidate("一行目\n二行目"))
        XCTAssertFalse(GyaimController.shouldRegisterExternalCandidate(
            "ssessing OpenSSH network access restrictions"))
    }
}
