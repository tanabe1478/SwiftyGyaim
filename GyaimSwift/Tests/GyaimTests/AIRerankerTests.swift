@testable import Gyaim
import XCTest

final class AIRerankerTests: XCTestCase {
    func testValidatedOrderAcceptsCompletePermutation() {
        XCTAssertEqual(AIReranker.validatedOrder([2, 0, 1], candidateCount: 3), [2, 0, 1])
    }

    func testValidatedOrderDropsInvalidAndDuplicateIndexesThenAppendsMissing() {
        XCTAssertEqual(AIReranker.validatedOrder([2, 99, 2, -1], candidateCount: 4), [2, 0, 1, 3])
    }

    func testApplyReordersCandidates() {
        let candidates = [
            SearchCandidate(word: "昨日"),
            SearchCandidate(word: "機能"),
            SearchCandidate(word: "きのう")
        ]

        let words = AIReranker.apply(order: [1, 0, 2], to: candidates).map(\.word)
        XCTAssertEqual(words, ["機能", "昨日", "きのう"])
    }
}
