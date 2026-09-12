@testable import Gyaim
import XCTest

/// ADR-026: the model review of prefix candidates is deferred past the
/// inter-key interval; the synchronous pass stays heuristic-only.
final class FastContextReviewSchedulingTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "aiRerankUseModelForFastContext")
        UserDefaults.standard.removeObject(forKey: "aiRerankFastContextReviewDelayMs")
        UserDefaults.standard.removeObject(forKey: "aiRerankFastContextEnabled")
        UserDefaults.standard.removeObject(forKey: "aiRerankUseBundledZenz")
        super.tearDown()
    }

    func testDelayDefaultsTo80msAndIsClamped() {
        XCTAssertEqual(GyaimController.modelReviewDelayMilliseconds(), 80)
        UserDefaults.standard.set(5000, forKey: "aiRerankFastContextReviewDelayMs")
        XCTAssertEqual(GyaimController.modelReviewDelayMilliseconds(), 1000)
        UserDefaults.standard.set(-1, forKey: "aiRerankFastContextReviewDelayMs")
        XCTAssertEqual(GyaimController.modelReviewDelayMilliseconds(), 0)
    }

    func testDeferralRequiresModelBackendAndPositiveDelay() {
        XCTAssertFalse(GyaimController.shouldDeferModelReview(inputPat: "shitagau"), "model backend off")

        UserDefaults.standard.set(true, forKey: "aiRerankUseModelForFastContext")
        XCTAssertTrue(GyaimController.shouldDeferModelReview(inputPat: "shitagau"))
        XCTAssertFalse(GyaimController.shouldDeferModelReview(inputPat: "si"), "below the model input-length gate")

        UserDefaults.standard.set(0, forKey: "aiRerankFastContextReviewDelayMs")
        XCTAssertFalse(GyaimController.shouldDeferModelReview(inputPat: "shitagau"), "0 restores synchronous review")
    }

    func testSynchronousPassStaysHeuristicWhenReviewIsDeferred() {
        UserDefaults.standard.set(true, forKey: "aiRerankUseModelForFastContext")
        let searchResults = [
            SearchCandidate(word: "従うな", reading: "shitagauna", source: .connection, kind: .prefix),
            SearchCandidate(word: "従う", reading: "shitagau", source: .connection, kind: .exact),
        ]
        let start = CFAbsoluteTimeGetCurrent()
        let words = GyaimController.buildPrefixCandidates(searchResults: searchResults,
                                                          inputPat: "shitagau",
                                                          clipboardCandidate: nil,
                                                          selectedCandidate: nil,
                                                          hiragana: "したがう",
                                                          context: "この文脈で",
                                                          allowModelReview: false).map(\.word)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertEqual(Array(words.prefix(3)), ["shitagau", "従う", "従うな"])
        // The GGUF model must not be loaded on this path (a load takes seconds).
        XCTAssertLessThan(elapsedMs, 500)
    }

    func testDisabledRerankOrBackendDoesNotScheduleModel() {
        UserDefaults.standard.set(true, forKey: "aiRerankUseModelForFastContext")
        UserDefaults.standard.set(false, forKey: "aiRerankFastContextEnabled")
        XCTAssertFalse(GyaimController.shouldDeferModelReview(inputPat: "kousin"))
        UserDefaults.standard.set(true, forKey: "aiRerankFastContextEnabled")
        UserDefaults.standard.set(false, forKey: "aiRerankUseBundledZenz")
        XCTAssertFalse(GyaimController.shouldDeferModelReview(inputPat: "kousin"))
    }

    func testOutcomeLabelDistinguishesPreReviewHeuristic() {
        XCTAssertEqual(GyaimController.fastContextRerankOutcome(model: "swift-fast-context-heuristic-prereview"), "heuristic-prereview")
        XCTAssertEqual(GyaimController.fastContextRerankOutcome(model: "swift-fast-context-heuristic"), "heuristic")
        XCTAssertEqual(GyaimController.fastContextRerankOutcome(model: "x-review-exact-homophone-fixed+swift-local-heuristic"), "exact-homophone-fixed")
    }
}
