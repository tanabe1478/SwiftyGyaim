@testable import Gyaim
import XCTest

/// ADR-029: the model review of prefix candidates runs on a background queue
/// for every keystroke; the synchronous pass stays heuristic-only and Space
/// briefly joins an in-flight review.
final class FastContextReviewSchedulingTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "aiRerankUseModelForFastContext")
        UserDefaults.standard.removeObject(forKey: "aiRerankFastContextReviewDelayMs")
        UserDefaults.standard.removeObject(forKey: "aiRerankFastContextSelectionWaitMs")
        UserDefaults.standard.removeObject(forKey: "aiRerankFastContextEnabled")
        UserDefaults.standard.removeObject(forKey: "aiRerankUseBundledZenz")
        super.tearDown()
    }

    func testThrottleDefaultsToZeroAndIsClamped() {
        XCTAssertEqual(GyaimController.modelReviewDelayMilliseconds(), 0)
        UserDefaults.standard.set(5000, forKey: "aiRerankFastContextReviewDelayMs")
        XCTAssertEqual(GyaimController.modelReviewDelayMilliseconds(), 1000)
        UserDefaults.standard.set(-1, forKey: "aiRerankFastContextReviewDelayMs")
        XCTAssertEqual(GyaimController.modelReviewDelayMilliseconds(), 0)
    }

    func testSelectionWaitDefaultsTo30msAndIsClamped() {
        XCTAssertEqual(GyaimController.modelReviewSelectionWaitMilliseconds(), 30)
        UserDefaults.standard.set(999, forKey: "aiRerankFastContextSelectionWaitMs")
        XCTAssertEqual(GyaimController.modelReviewSelectionWaitMilliseconds(), 200)
        UserDefaults.standard.set(-5, forKey: "aiRerankFastContextSelectionWaitMs")
        XCTAssertEqual(GyaimController.modelReviewSelectionWaitMilliseconds(), 0)
    }

    func testReviewIsScheduledOnlyWhenModelBackendAppliesToInput() {
        XCTAssertFalse(GyaimController.shouldScheduleModelReview(inputPat: "shitagau"), "model backend off")

        UserDefaults.standard.set(true, forKey: "aiRerankUseModelForFastContext")
        XCTAssertTrue(GyaimController.shouldScheduleModelReview(inputPat: "shitagau"))
        XCTAssertFalse(GyaimController.shouldScheduleModelReview(inputPat: "si"), "below the model input-length gate")

        UserDefaults.standard.set(false, forKey: "aiRerankFastContextEnabled")
        XCTAssertFalse(GyaimController.shouldScheduleModelReview(inputPat: "kousin"))
        UserDefaults.standard.set(true, forKey: "aiRerankFastContextEnabled")
        UserDefaults.standard.set(false, forKey: "aiRerankUseBundledZenz")
        XCTAssertFalse(GyaimController.shouldScheduleModelReview(inputPat: "kousin"))
    }

    func testSynchronousPassStaysHeuristicWhenModelIsEnabled() {
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

    func testOutcomeLabelDistinguishesPreReviewHeuristic() {
        XCTAssertEqual(GyaimController.fastContextRerankOutcome(model: "swift-fast-context-heuristic-prereview"), "heuristic-prereview")
        XCTAssertEqual(GyaimController.fastContextRerankOutcome(model: "swift-fast-context-heuristic"), "heuristic")
        XCTAssertEqual(GyaimController.fastContextRerankOutcome(model: "x-review-exact-homophone-fixed+swift-local-heuristic"), "exact-homophone-fixed")
    }

    // MARK: - FastContextReviewTicket

    private func makeTicket(generation: Int = 1) -> FastContextReviewTicket {
        FastContextReviewTicket(generation: generation,
                                input: FastContextPrefixInput(searchResults: [], inputPat: "kousin", hiragana: "こうしん",
                                                              clipboard: nil, selected: nil, context: ""))
    }

    func testTicketWaitReturnsNilOnTimeoutAndOutcomeOnceStored() {
        let ticket = makeTicket()
        let start = CFAbsoluteTimeGetCurrent()
        XCTAssertNil(ticket.waitForResult(timeout: .milliseconds(20)))
        XCTAssertGreaterThanOrEqual((CFAbsoluteTimeGetCurrent() - start) * 1000, 15)

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) {
            ticket.store(FastContextReviewTicket.Outcome(candidates: [SearchCandidate(word: "更新")], observation: nil))
        }
        let outcome = ticket.waitForResult(timeout: .milliseconds(500))
        XCTAssertEqual(outcome?.candidates.map(\.word), ["更新"])
        // A second wait returns immediately without consuming a semaphore signal.
        XCTAssertEqual(ticket.waitForResult(timeout: .milliseconds(0))?.candidates.count, 1)
        XCTAssertEqual(ticket.current?.candidates.count, 1)
    }

    func testTicketAppliesOnceAndReportsCancellation() {
        let ticket = makeTicket()
        XCTAssertFalse(ticket.isCancelled)
        XCTAssertTrue(ticket.markApplied())
        XCTAssertFalse(ticket.markApplied(), "Space join and the worker callback must not both apply")
        ticket.cancel()
        XCTAssertTrue(ticket.isCancelled)
    }
}
