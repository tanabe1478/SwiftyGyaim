@testable import Gyaim
import XCTest

/// The stale caret rect Google Docs reports is replaced by the last real caret
/// rect (ADR-038).
final class StaleCaretRectDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    // 2026-10-21 12:39 in gyaim.log: the stale rect and the real caret.
    private let stale = NSRect(x: 997, y: 2441, width: 1, height: 17)
    private let caret1 = NSRect(x: 1355, y: 1905, width: 1, height: 45)
    private let caret2 = NSRect(x: 1470, y: 1905, width: 1, height: 45)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testStaleRectReturningAfterTheRealCaretIsReplacedByTheLastCaret() {
        let detector = StaleCaretRectDetector()
        XCTAssertNil(detector.replacement(for: stale, now: at(0)), "first appearance: nothing to compare with")
        XCTAssertNil(detector.replacement(for: stale, now: at(1)))
        XCTAssertNil(detector.replacement(for: caret1, now: at(2)), "a new far rect is the real caret")
        XCTAssertEqual(detector.replacement(for: stale, now: at(3)), caret1, "back to the exact same rect from far away")
        XCTAssertEqual(detector.replacement(for: stale, now: at(4)), caret1, "kept while the stale rect continues")
        XCTAssertNil(detector.replacement(for: caret2, now: at(5)))
        XCTAssertEqual(detector.replacement(for: stale, now: at(6)), caret2, "the replacement is the latest caret")
    }

    func testNearbyOrSameHeightRectsAreNotStale() {
        let detector = StaleCaretRectDetector()
        // ghostty: the caret moves along one line and comes back to the prompt column.
        let prompt = NSRect(x: 244.25, y: 75, width: 1, height: 18.5)
        let later = NSRect(x: 873.25, y: 75, width: 1, height: 18.5)
        XCTAssertNil(detector.replacement(for: prompt, now: at(0)))
        XCTAssertNil(detector.replacement(for: later, now: at(1)))
        XCTAssertNil(detector.replacement(for: prompt, now: at(2)), "same line height: not stale")

        // Slack: message box and a thread pane far apart, line heights 18 vs 17.
        let box = NSRect(x: 552, y: 124, width: 1, height: 18)
        let thread = NSRect(x: 1436, y: 148, width: 1, height: 17)
        XCTAssertNil(detector.replacement(for: box, now: at(10)))
        XCTAssertNil(detector.replacement(for: thread, now: at(11)))
        XCTAssertNil(detector.replacement(for: box, now: at(12)), "height differs by less than 2")

        // Far with a different height, but never seen before.
        let other = NSRect(x: 2000, y: 900, width: 1, height: 26)
        XCTAssertNil(detector.replacement(for: other, now: at(13)))
    }

    func testHistoryExpiresAfterTheWindow() {
        let detector = StaleCaretRectDetector()
        XCTAssertNil(detector.replacement(for: stale, now: at(0)))
        XCTAssertNil(detector.replacement(for: caret1, now: at(1)))
        XCTAssertNil(detector.replacement(for: stale, now: at(1 + StaleCaretRectDetector.windowSeconds + 1)),
                     "the earlier stale run has expired, so this looks like a first appearance")
        detector.reset()
        XCTAssertNil(detector.replacement(for: caret1, now: at(100)))
        XCTAssertNil(detector.replacement(for: stale, now: at(101)))
    }

    func testDetectorsAreSharedPerBundle() {
        StaleCaretRectDetector.resetAll()
        let chrome = StaleCaretRectDetector.shared(for: "com.google.Chrome")
        XCTAssertTrue(chrome === StaleCaretRectDetector.shared(for: "com.google.Chrome"))
        XCTAssertFalse(chrome === StaleCaretRectDetector.shared(for: "com.mitchellh.ghostty"))
        XCTAssertTrue(StaleCaretRectDetector.shared(for: nil) === StaleCaretRectDetector.shared(for: nil))
        StaleCaretRectDetector.resetAll()
    }

    func testResolveLineRectUsesTheReplacementForAUsableButStaleRect() {
        let resolution = CandidateWindowPositioner.resolveLineRect(
            reportedLineRect: stale,
            previousValidLineRect: nil,
            mouseLocation: NSPoint(x: 900, y: 800),
            staleReplacement: caret1)
        XCTAssertEqual(resolution.source, .repeatedStale)
        XCTAssertEqual(resolution.lineRect, caret1)

        let suspicious = NSRect(x: 13.75, y: 12.0, width: 1.0, height: 17.5)
        let fallback = CandidateWindowPositioner.resolveLineRect(
            reportedLineRect: suspicious,
            previousValidLineRect: caret2,
            mouseLocation: NSPoint(x: 900, y: 800),
            staleReplacement: caret1)
        XCTAssertEqual(fallback.source, .previousValid, "the origin-rect check of ADR-018 still comes first")
        XCTAssertEqual(fallback.lineRect, caret2)
    }
}
