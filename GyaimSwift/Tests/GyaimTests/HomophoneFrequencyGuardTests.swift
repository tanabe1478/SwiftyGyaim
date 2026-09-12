@testable import Gyaim
import XCTest

/// BUG-036: the exact-homophone model override must not demote a study
/// candidate to one the user has committed far less often.
final class HomophoneFrequencyGuardTests: XCTestCase {
    func testStudyFrequencyAdvantageIsLog2RatioClampedAtZero() {
        XCTAssertEqual(BundledZenzRuntime.studyFrequencyAdvantage(best: 31, challenger: 7), log2(31.0 / 7.0), accuracy: 1e-9)
        // Challenger without study history counts as frequency 1.
        XCTAssertEqual(BundledZenzRuntime.studyFrequencyAdvantage(best: 8, challenger: nil), 3.0, accuracy: 1e-9)
        // No advantage when the best is not a repeated study word or is rarer.
        XCTAssertEqual(BundledZenzRuntime.studyFrequencyAdvantage(best: nil, challenger: 5), 0)
        XCTAssertEqual(BundledZenzRuntime.studyFrequencyAdvantage(best: 1, challenger: nil), 0)
        XCTAssertEqual(BundledZenzRuntime.studyFrequencyAdvantage(best: 3, challenger: 10), 0)
    }

    func testDogfoodMisfiresAreBlockedByFrequencyAdvantage() {
        // kimi 2026-09-11: best 君 (freq 31) scored -3.87, challenger キミ (freq 7) -0.48.
        XCTAssertNil(BundledZenzRuntime.selectExactHomophoneWinner(scores: [0: -0.4751, 1: -3.8736],
                                                                   currentBest: 1,
                                                                   margin: 0.10,
                                                                   studyFrequencies: [0: 7, 1: 31]))
        // siteki: best 指摘 (freq 63) -0.67, challenger 私的 (freq 3) -0.16.
        XCTAssertNil(BundledZenzRuntime.selectExactHomophoneWinner(scores: [0: -0.6681, 1: -0.1596, 2: -4.0909],
                                                                   currentBest: 0,
                                                                   margin: 0.10,
                                                                   studyFrequencies: [0: 63, 1: 3]))
    }

    func testOverrideStillAllowedWhenChallengerIsAsFrequentOrModelIsDecisive() {
        // Equal frequency: plain margin applies.
        XCTAssertEqual(BundledZenzRuntime.selectExactHomophoneWinner(scores: [0: -2.0, 1: -1.0],
                                                                     currentBest: 0,
                                                                     margin: 0.10,
                                                                     studyFrequencies: [0: 5, 1: 5]), 1)
        // Challenger is the more frequent word: no extra bar.
        XCTAssertEqual(BundledZenzRuntime.selectExactHomophoneWinner(scores: [0: -2.0, 1: -1.0],
                                                                     currentBest: 0,
                                                                     margin: 0.10,
                                                                     studyFrequencies: [0: 2, 1: 40]), 1)
        // Best is 4x more frequent (+2 doublings = +4.0 at weight 2.0); a
        // decisive model gap can still clear it.
        XCTAssertEqual(BundledZenzRuntime.selectExactHomophoneWinner(scores: [0: -6.0, 1: -1.0],
                                                                     currentBest: 0,
                                                                     margin: 0.10,
                                                                     studyFrequencies: [0: 8, 1: 2]), 1)
        XCTAssertNil(BundledZenzRuntime.selectExactHomophoneWinner(scores: [0: -4.0, 1: -1.0],
                                                                   currentBest: 0,
                                                                   margin: 0.10,
                                                                   studyFrequencies: [0: 8, 1: 2]))
    }

    func testStudyFrequenciesOnlyIncludeStudyCandidates() {
        let request = AIRerankRequest(version: 1, mode: "fast-context-rerank", inputPat: "kimi", hiragana: "きみ",
                                      context: "そもそも",
                                      candidates: [
                                          AIRerankCandidate(index: 0, text: "キミ", reading: "kimi", source: "study", kind: "exact", studyFrequency: 7),
                                          AIRerankCandidate(index: 1, text: "君", reading: "kimi", source: "study", kind: "exact", studyFrequency: 31),
                                          AIRerankCandidate(index: 2, text: "気味", reading: "kimi", source: "connection", kind: "exact", studyFrequency: 9),
                                      ])
        XCTAssertEqual(BundledZenzRuntime.studyFrequencies(of: request), [0: 7, 1: 31])
    }
}
