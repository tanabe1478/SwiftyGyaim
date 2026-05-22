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

    func testRequestEncodesCandidateKind() throws {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "kinou",
            hiragana: "きのう",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "きのう",
                                  reading: "kinou",
                                  source: "synthetic",
                                  kind: "kana")
            ]
        )

        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let candidates = object?["candidates"] as? [[String: Any]]
        XCTAssertEqual(candidates?.first?["kind"] as? String, "kana")
    }

    func testLocalRerankPenalizesRawAndPrefersJapaneseCandidate() {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "ousyuusuru",
            hiragana: "おうしゅうする",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "ousyuusuru",
                                  reading: "ousyuusuru",
                                  source: "synthetic",
                                  kind: "raw"),
                AIRerankCandidate(index: 1,
                                  text: "押収する",
                                  reading: "ousyuusuru",
                                  source: "synthetic",
                                  kind: "compound")
            ]
        )

        let response = AIReranker.localRerank(request)
        XCTAssertEqual(response.order.first, 1)
        XCTAssertEqual(response.model, "swift-local-heuristic")
    }

    func testLocalRerankUsesKindBias() {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "henkan",
            hiragana: "へんかん",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "へんかん",
                                  reading: "henkan",
                                  source: "synthetic",
                                  kind: "kana"),
                AIRerankCandidate(index: 1,
                                  text: "変換",
                                  reading: "henkan",
                                  source: "connection",
                                  kind: "exact")
            ]
        )

        XCTAssertEqual(AIReranker.localRerank(request).order.first, 1)
    }
}
