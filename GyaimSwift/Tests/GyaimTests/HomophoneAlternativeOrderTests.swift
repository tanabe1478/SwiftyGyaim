@testable import Gyaim
import XCTest

final class HomophoneAlternativeOrderTests: XCTestCase {
    func testBlockedWinnerCanBecomeSecondWithoutChangingFrequencyProtectedTop() {
        let scores = [0: -3.58, 1: -4.0, 2: -0.18]
        // BUG-036: 君 (31) remains first despite キミ (7) scoring higher.
        XCTAssertNil(BundledZenzRuntime.selectExactHomophoneWinner(scores: scores, currentBest: 0,
                                                                   margin: 0.1, studyFrequencies: [0: 31, 2: 7]))
        XCTAssertEqual(BundledZenzRuntime.rerankScoredAlternatives(localOrder: [0, 1, 2, 3], scores: scores), [0, 2, 1, 3])
    }

    func testUnscoredSlotsAndTopRemainFixed() {
        let order = [8, 7, 6, 5, 4, 3]
        let result = BundledZenzRuntime.rerankScoredAlternatives(localOrder: order, scores: [8: -1, 6: -5, 4: -2])
        XCTAssertEqual(result, [8, 7, 4, 5, 6, 3])
        XCTAssertEqual(Set(result), Set(order))
    }

    func testEqualScoresKeepLocalOrderNotIndexOrder() {
        let order = [8, 6, 4, 2]
        XCTAssertEqual(BundledZenzRuntime.rerankScoredAlternatives(localOrder: order,
                                                                  scores: [8: -1, 6: -2, 4: -2, 2: -2]), order)
    }

    func testMissingOrNonfiniteScoresDoNotMoveTheirSlots() {
        for scores in [[Int: Double](), [1: -1, 2: -2], [0: Double.nan, 1: -2, 2: -1]] {
            XCTAssertEqual(BundledZenzRuntime.rerankScoredAlternatives(localOrder: [0, 1, 2], scores: scores), [0, 1, 2])
        }
        XCTAssertEqual(BundledZenzRuntime.rerankScoredAlternatives(localOrder: [0, 1, 2, 3],
                                                                  scores: [0: -1, 1: .infinity, 2: -3, 3: -2]), [0, 1, 3, 2])
        XCTAssertEqual(BundledZenzRuntime.rerankScoredAlternatives(localOrder: [], scores: [:]), [])
    }

    func testPreviouslyPromotedWinnerStaysFirst() {
        // The existing top-selection policy already promoted index 2.
        XCTAssertEqual(BundledZenzRuntime.rerankScoredAlternatives(localOrder: [2, 0, 1, 3],
                                                                  scores: [0: -4, 1: -2, 2: -1]), [2, 1, 0, 3])
    }

    func testExcludedCandidatesCannotBeReorderedByModel() {
        let request = AIRerankRequest(version: 1, mode: "fast-context-rerank", inputPat: "komi", hiragana: "こみ",
                                      context: "料金に", candidates: [
            AIRerankCandidate(index: 0, text: "込み", reading: "komi", source: "study", kind: "exact"),
            AIRerankCandidate(index: 1, text: "こみ", reading: "komi", source: "study", kind: "exact"),
            AIRerankCandidate(index: 2, text: "コミ", reading: "komi", source: "study", kind: "exact"),
            AIRerankCandidate(index: 3, text: "〇", reading: "komi", source: "study", kind: "exact"),
            AIRerankCandidate(index: 4, text: "小見", reading: "komi", source: "study", kind: "exact"),
            AIRerankCandidate(index: 5, text: "コミット", reading: "komitto", source: "study", kind: "prefix"),
        ])
        let order = Array(0..<6)
        let indices = BundledZenzRuntime.exactHomophoneCandidateIndices(request: request, localOrder: order)
        XCTAssertEqual(indices, [0, 2, 4])
        let scores = Dictionary(uniqueKeysWithValues: indices.map { ($0, Double($0)) })
        let reordered = BundledZenzRuntime.rerankScoredAlternatives(localOrder: order, scores: scores)
        XCTAssertEqual(reordered, [0, 1, 4, 3, 2, 5])
    }

    func testResponseKeepsTopGuardAndReportsTailDecisionWithExactScores() {
        let request = AIRerankRequest(version: 1, mode: "fast-context-rerank", inputPat: "kimi", hiragana: "きみ",
                                      context: "", candidates: [
            AIRerankCandidate(index: 0, text: "君", reading: "kimi", source: "study", kind: "exact", studyFrequency: 31),
            AIRerankCandidate(index: 1, text: "気味", reading: "kimi", source: "connection", kind: "exact"),
            AIRerankCandidate(index: 2, text: "キミ", reading: "kimi", source: "study", kind: "exact", studyFrequency: 7),
        ])
        let baseline = AIRerankResponse(order: [0, 1, 2], scores: ["0": 3], model: "heuristic")
        let response = BundledZenzRuntime.homophoneResponse(request: request, heuristic: baseline,
                                                            indices: [0, 1, 2], scores: [0: -3.58, 1: -4, 2: -0.18])
        XCTAssertEqual(response.order, [0, 2, 1])
        XCTAssertEqual(response.review?.topDecision, "kept-local")
        XCTAssertEqual(response.review?.scores, ["0": -3.58, "1": -4, "2": -0.18])
        XCTAssertEqual(response.scores, baseline.scores, "LM scores must not replace heuristic scores")
        XCTAssertEqual(GyaimController.fastContextRerankOutcome(model: response.model ?? ""), "exact-homophone-tail-reranked")
        let failed = BundledZenzRuntime.homophoneResponse(request: request, heuristic: baseline,
                                                          indices: [0, 1, 2], scores: [0: .nan, 1: -4, 2: -0.18, 9: 100])
        XCTAssertEqual(failed.order, baseline.order)
        XCTAssertEqual(failed.review?.topDecision, "unavailable")
        XCTAssertEqual(failed.review?.scores, ["1": -4, "2": -0.18])
    }

    func testOutcomeLabelDistinguishesTailOnlyChange() {
        let label = "model-review-exact-homophone-tail-reranked+swift-local-heuristic"
        XCTAssertEqual(GyaimController.fastContextRerankOutcome(model: label),
                       "exact-homophone-tail-reranked")
    }
}
