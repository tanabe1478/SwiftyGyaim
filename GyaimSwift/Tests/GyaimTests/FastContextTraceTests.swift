@testable import Gyaim
import XCTest

final class FastContextTraceTests: XCTestCase {
    private let words = ["kou", "甲", "公", "校"]

    private func trace(deferred: Bool = true) -> FastContextTrace {
        FastContextTrace(controllerID: "controller-a", compositionID: 2, generation: 7,
                         heuristicWords: words, proposedWords: nil, modelState: .pending, deferred: deferred)
    }

    private func observation(review: AIRerankReview? = AIRerankReview(candidateIndices: [0, 1, 2],
                                                                      scores: ["0": -1, "1": -3, "2": -2],
                                                                      topDecision: "passed")) -> FastContextObservation {
        let request = AIRerankRequest(version: 1, mode: "fast-context-rerank",
                                      inputPat: "kou", hiragana: "こう", context: "",
                                      candidates: words.dropFirst().enumerated().map {
            AIRerankCandidate(index: $0.offset, text: $0.element, reading: "kou", source: "study", kind: "exact")
        })
        return FastContextObservation(request: request,
                                      response: AIRerankResponse(order: [0, 2, 1], scores: nil,
                                                                model: "test-review-exact-homophone-tail-reranked",
                                                                review: review),
                                      heuristicOrder: [0, 1, 2])
    }

    func testCancellationKeepsRequestIdentityAndBaseline() {
        var value = trace()
        let tag = value.tag
        value.cancel()
        XCTAssertEqual(value.modelState, .cancelled)
        XCTAssertEqual(value.tag, tag)
        XCTAssertEqual(value.heuristicRank(of: "校"), 3)
        XCTAssertFalse(value.complete(words: words, observation: observation(), generation: 7))
        XCTAssertNil(value.proposedWords)
    }

    func testOldGenerationCannotApplyEvenForSameWords() {
        var value = trace()
        XCTAssertFalse(value.complete(words: words, observation: observation(), generation: 6))
        XCTAssertEqual(value.modelState, .pending)
        XCTAssertNil(value.observation)
    }

    func testCompletedReviewSurvivesCommitKeyCancellation() {
        var value = trace()
        XCTAssertTrue(value.complete(words: ["kou", "甲", "校", "公"], observation: observation(), generation: 7))
        value.cancel()
        XCTAssertEqual(value.modelState, .appliedChanged)
        XCTAssertEqual(value.heuristicRank(of: "校"), 3)
        XCTAssertEqual(value.proposedRank(of: "校"), 2)
    }

    func testSkippedAndUnavailableAreNotModelPasses() {
        var skipped = trace()
        skipped.complete(words: words, observation: observation(review: nil), generation: 7)
        XCTAssertEqual(skipped.modelState, .skipped)
        var unavailable = trace()
        let failed = AIRerankReview(candidateIndices: [0], scores: [:], topDecision: "unavailable")
        unavailable.complete(words: words, observation: observation(review: failed), generation: 7)
        XCTAssertEqual(unavailable.modelState, .unavailable)
        var noCandidates = trace()
        noCandidates.complete(words: words, observation: nil, generation: 7)
        XCTAssertEqual(noCandidates.modelState, .skipped)
    }

    func testSynchronousReviewAlsoHasComparableRanksAndScores() throws {
        var value = trace(deferred: false)
        value.complete(words: ["kou", "甲", "校", "公"], observation: observation(), generation: 7)
        let payload = value.payload(chosenWord: "校", displayedWords: ["kou", "甲", "校", "公"])
        XCTAssertEqual(payload["deferred"] as? Bool, false)
        XCTAssertEqual(payload["heuristicRank"] as? Int, 3)
        XCTAssertEqual(payload["proposedRank"] as? Int, 2)
        XCTAssertEqual(payload["displayedOrderHead"] as? [Int], [0, 1, 3, 2])
        XCTAssertEqual(payload["dictionaryHeuristicOrder"] as? [Int], [0, 1, 2])
        let review = try XCTUnwrap(payload["review"] as? [String: Any])
        XCTAssertEqual(review["candidateIndices"] as? [Int], [0, 1, 2])
        XCTAssertEqual(review["scoreOrder"] as? [Int], [0, 2, 1])
        XCTAssertEqual(review["scores"] as? [String: Double], ["0": -1, "1": -3, "2": -2])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
    }

    func testControllerIdentityDistinguishesSameCompositionAndGeneration() {
        let first = trace()
        var second = trace()
        second.controllerID = "controller-b"
        XCTAssertNotEqual(first.tag, second.tag)
    }

    func testOrderHeadIsBoundedButChosenRankIsNot() {
        var value = trace()
        value.heuristicWords = (0..<100).map(String.init)
        let payload = value.payload(chosenWord: "99", displayedWords: value.heuristicWords ?? [])
        XCTAssertEqual((payload["displayedOrderHead"] as? [Int])?.count, 32)
        XCTAssertEqual(payload["heuristicRank"] as? Int, 99)
    }

    func testOldResponseWithoutDiagnosticsStillDecodes() throws {
        let response = try JSONDecoder().decode(AIRerankResponse.self, from: Data("{\"order\":[0],\"model\":\"legacy\"}".utf8))
        XCTAssertNil(response.review)
    }

    /// The 見た/見たい regression shape: the user escaped to exact mode for a
    /// word the prefix list demoted below the model's scored set.
    func testCommitOutcomeRecordsPrefixRankAndScoredSetMembership() throws {
        var value = trace()
        XCTAssertTrue(value.complete(words: ["kou", "公", "甲", "校"], observation: observation(
            review: AIRerankReview(candidateIndices: [0, 1], scores: ["0": -1, "1": -2], topDecision: "fixed")),
            generation: 7))

        let payload = try XCTUnwrap(GyaimController.commitOutcomePayload(
            path: "exact", chosenWord: "校", context: "を変換",
            prefixWords: ["kou", "公", "甲", "校"], trace: value))
        XCTAssertFalse(payload.contains("\n"), "payload must stay a single log line")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(object["path"] as? String, "exact")
        XCTAssertEqual(object["context"] as? String, "を変換")
        XCTAssertEqual(object["prefixRank"] as? Int, 3)
        XCTAssertEqual(object["heuristicRank"] as? Int, 3)
        XCTAssertEqual(object["modelState"] as? String, "applied-changed")
        XCTAssertEqual(object["inDictionarySnapshot"] as? Bool, true)
        XCTAssertEqual(object["inScoredSet"] as? Bool, false)
        XCTAssertEqual(object["scoredCount"] as? Int, 2)
        XCTAssertEqual(object["composition"] as? Int, 2)
    }

    func testCommitOutcomeWithoutPrefixStateOmitsRanks() throws {
        let payload = try XCTUnwrap(GyaimController.commitOutcomePayload(
            path: "kana-hiragana", chosenWord: "した", context: "", prefixWords: [], trace: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(object["path"] as? String, "kana-hiragana")
        XCTAssertEqual(object["prefixCandidateCount"] as? Int, 0)
        XCTAssertNil(object["prefixRank"])
        XCTAssertNil(object["modelState"])
    }
}
