@testable import Gyaim
import XCTest

/// BUG-043: a past tense ending in た/だ is a finished word; "+い" is the
/// desiderative (見たい / したい), not a missing adjective ending.
final class IncompleteStemPastTenseTests: XCTestCase {
    func testPastTenseIsNotIncompleteStemOfDesiderative() {
        XCTAssertFalse(AIReranker.isIncompleteStemCompletion(stem: "見た", completed: "見たい"))
        XCTAssertFalse(AIReranker.isIncompleteStemCompletion(stem: "した", completed: "したい"))
        XCTAssertFalse(AIReranker.isIncompleteStemCompletion(stem: "読んだ", completed: "読んだい"))
        // The adjective-stem rule itself stays.
        XCTAssertTrue(AIReranker.isIncompleteStemCompletion(stem: "少な", completed: "少ない"))
    }

    /// Dogfood 2026-09-24: "見た" (study freq 6) sank to rank 23
    /// under "満た" because "見たい" made it look like an unfinished stem.
    func testPastTenseIsNotDemotedByDesiderativeCompletion() {
        let request = AIRerankRequest(
            version: 1, mode: "fast-context-rerank", inputPat: "mita", hiragana: "みた", context: "を変換しましたが",
            candidates: [
                AIRerankCandidate(index: 0, text: "見た", reading: "mita", source: "study", kind: "exact",
                                  studyFrequency: 6),
                AIRerankCandidate(index: 1, text: "見たい", reading: "mitai", source: "study", kind: "prefix",
                                  studyFrequency: 5),
                AIRerankCandidate(index: 2, text: "満た", reading: "mita", source: "study", kind: "exact",
                                  studyFrequency: 3),
                AIRerankCandidate(index: 3, text: "観た", reading: "mita", source: "study", kind: "exact",
                                  studyFrequency: 3),
            ])
        let breakdown = AIReranker.localScoreBreakdown(candidate: request.candidates[0], request: request)
        XCTAssertNil(breakdown.contributions["incompleteStemPenalty"])
        XCTAssertEqual(AIReranker.localRerank(request).order.first, 0)
    }
}
