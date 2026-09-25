@testable import Gyaim
import XCTest

/// ADR-032: LLM-primary ordering of fast-context candidates.
final class LLMPrimaryOrderTests: XCTestCase {
    private func candidate(_ index: Int, _ text: String, reading: String = "kimi", source: String = "study",
                           kind: String = "exact", frequency: Int? = nil,
                           affinity: Double? = nil) -> AIRerankCandidate {
        AIRerankCandidate(index: index, text: text, reading: reading, source: source, kind: kind,
                          contextAffinity: affinity, studyFrequency: frequency)
    }

    private func request(_ candidates: [AIRerankCandidate], input: String = "kimi") -> AIRerankRequest {
        AIRerankRequest(version: 1, mode: "fast-context-rerank", inputPat: input, hiragana: "きみ",
                        context: "それは", candidates: candidates)
    }

    private func order(_ request: AIRerankRequest, _ scores: [Int: Double], heuristic: [Int]? = nil) -> [Int] {
        BundledZenzRuntime.llmPrimaryOrder(request: request, heuristicOrder: heuristic ?? request.candidates.map(\.index),
                                           llmScores: scores, studyWeight: 2.0, contextWeight: 2.0).order
    }

    func testModelScoreDecidesAmongUnlearnedCandidates() {
        let req = request([candidate(0, "帰る", source: "connection"), candidate(1, "変える", source: "connection"),
                           candidate(2, "蛙", source: "connection")])
        XCTAssertEqual(order(req, [0: -3.0, 1: -1.0, 2: -5.0]), [1, 0, 2])
    }

    /// BUG-036: the user's frequent 君 (31) must survive a ~3.4 logprob gap to キミ (7).
    func testFrequentStudyWordSurvivesModelPreference() {
        let req = request([candidate(0, "君", frequency: 31), candidate(1, "キミ", frequency: 7)])
        XCTAssertEqual(order(req, [0: -4.4, 1: -1.0]).first, 0)
    }

    func testContextAffinityCanOverrideModel() {
        let req = request([candidate(0, "機能", reading: "kinou", source: "connection"),
                           candidate(1, "昨日", reading: "kinou", source: "connection", affinity: 1.0)], input: "kinou")
        XCTAssertEqual(order(req, [0: -1.0, 1: -2.5]).first, 1)
    }

    /// Safety rules stay: an incomplete stem (くださ with ください present) is not promoted.
    func testIncompleteStemStaysBelowItsCompletion() {
        let req = request([candidate(0, "ください", reading: "kudasai", source: "connection", kind: "prefix"),
                           candidate(1, "くださ", reading: "kudasa", source: "connection")], input: "kudasa")
        XCTAssertEqual(order(req, [0: -3.0, 1: -1.0]).first, 0)
    }

    /// The input's literal hiragana is a kana-key press away; the kanji goes first.
    func testLiteralHiraganaIsNotOfferedFirst() {
        let req = AIRerankRequest(version: 1, mode: "fast-context-rerank", inputPat: "sukosi", hiragana: "すこし",
                                  context: "", candidates: [
                                      candidate(0, "すこし", reading: "sukosi", source: "connection"),
                                      candidate(1, "少し", reading: "sukosi", source: "connection"),
                                  ])
        XCTAssertEqual(order(req, [0: -1.0, 1: -2.5]).first, 1)
    }

    func testUnscoredCandidatesSinkInHeuristicOrder() {
        let req = request([candidate(0, "甲", source: "connection"), candidate(1, "乙", source: "connection"),
                           candidate(2, "丙", source: "connection")])
        XCTAssertEqual(order(req, [2: -9.0], heuristic: [1, 0, 2]), [2, 1, 0])
    }

    func testOutcomeLabelIsDistinguishable() {
        XCTAssertEqual(GyaimController.fastContextRerankOutcome(model: "m-review-llm-ranked+swift-local-heuristic"),
                       "llm-ranked")
        XCTAssertEqual(GyaimController.fastContextRerankOutcome(
            model: "m-review-llm-ranked-unavailable+swift-local-heuristic"), "llm-rank-unavailable")
    }
}
