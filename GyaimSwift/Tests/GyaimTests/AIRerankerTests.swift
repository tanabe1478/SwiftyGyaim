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

    func testLocalRerankBoostsAllKanjiZenzCandidate() {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "kyoukaisen",
            hiragana: "きょうかいせん",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "教会せん",
                                  reading: "kyoukaisen",
                                  source: "synthetic",
                                  kind: "lattice"),
                AIRerankCandidate(index: 1,
                                  text: "境界線",
                                  reading: "kyoukaisen",
                                  source: "synthetic",
                                  kind: "zenz")
            ]
        )

        XCTAssertEqual(AIReranker.localRerank(request).order.first, 1)
    }


    func testLocalRerankPenalizesLongerPrefixPredictionUnlessContextStronglySupportsIt() {
        let neutral = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "shitagau",
            hiragana: "したがう",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "従うな",
                                  reading: "shitagauna",
                                  source: "connection",
                                  kind: "prefix"),
                AIRerankCandidate(index: 1,
                                  text: "従う",
                                  reading: "shitagau",
                                  source: "connection",
                                  kind: "exact")
            ]
        )
        XCTAssertEqual(AIReranker.localRerank(neutral).order.first, 1)

        let negativeImperative = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "shitagau",
            hiragana: "したがう",
            context: "この指示には決して",
            candidates: neutral.candidates
        )
        XCTAssertEqual(AIReranker.localRerank(negativeImperative).order.first, 0)

        let zettainiImperative = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "kiru",
            hiragana: "きる",
            context: "絶対に",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "切る",
                                  reading: "kiru",
                                  source: "connection",
                                  kind: "exact"),
                AIRerankCandidate(index: 1,
                                  text: "切るな",
                                  reading: "kiruna",
                                  source: "connection",
                                  kind: "prefix")
            ]
        )
        XCTAssertEqual(AIReranker.localRerank(zettainiImperative).order.first, 1)
    }

    func testLocalRerankModelLabelCanBeOverridden() {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "henkan",
            hiragana: "へんかん",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "変換",
                                  reading: "henkan",
                                  source: "connection",
                                  kind: "exact")
            ]
        )

        XCTAssertEqual(AIReranker.localRerank(request, model: "test-model").model, "test-model")
    }
}
