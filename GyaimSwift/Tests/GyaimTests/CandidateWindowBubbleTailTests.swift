@testable import Gyaim
import XCTest

/// The classic bubble's tail points at the caret: up below it, down when the
/// window was flipped above it.
final class CandidateWindowBubbleTailTests: XCTestCase {
    private let screenFrame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    private let winSize = NSSize(width: 241, height: 126)

    func testPlacementReportsTheTailDirectionAndPutsTheTailTipOnTheCaret() {
        let caret = NSRect(x: 400, y: 500, width: 1, height: 20)
        let below = CandidateWindowPositioner.place(
            lineRect: caret, winSize: winSize, screenFrame: screenFrame, mode: .classic)
        XCTAssertEqual(below.tail, .up)
        XCTAssertEqual(below.origin.x, caret.origin.x - CandidateWindowPositioner.classicTailTipOffsetX,
                       "the tail tip (16 px from the bubble's left edge) sits on the caret")
        XCTAssertEqual(below.origin, CandidateWindowPositioner.calculate(
            lineRect: caret, winSize: winSize, screenFrame: screenFrame, mode: .classic))

        let nearBottom = NSRect(x: 400, y: 50, width: 1, height: 20)
        let above = CandidateWindowPositioner.place(
            lineRect: nearBottom, winSize: winSize, screenFrame: screenFrame, mode: .classic)
        XCTAssertEqual(above.tail, .down, "flipped above the caret, the tail must point down")
        XCTAssertEqual(above.origin.y, nearBottom.maxY)

        let list = CandidateWindowPositioner.place(
            lineRect: caret, winSize: winSize, screenFrame: screenFrame, mode: .list)
        XCTAssertEqual(list.origin.x, caret.origin.x - 5, "list mode keeps its 5 px offset")
    }

    func testSettingTheTailSwapsTheClassicContentInsets() {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()
        XCTAssertEqual(window.bubbleTailDirection, .up)
        XCTAssertEqual(window.classicContentInsets.top, 27)
        XCTAssertEqual(window.classicContentInsets.bottom, 20)

        window.setBubbleTail(.down)
        XCTAssertEqual(window.bubbleTailDirection, .down)
        XCTAssertEqual(window.classicContentInsets.top, 20, "the tail is now at the bottom")
        XCTAssertEqual(window.classicContentInsets.bottom, 27)
        window.updateCandidates(["候補"], selectedIndex: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.height, 126, "the swap does not change the window height")

        window.setBubbleTail(.up)
        XCTAssertEqual(window.classicContentInsets.top, 27)
    }

    func testBackgroundDrawsTheTailAtTheBottomWhenPointingDown() throws {
        let view = ClassicBackgroundView(metrics: ClassicBubbleMetrics())
        view.frame = NSRect(x: 0, y: 0, width: 241, height: 126)
        let probe = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: probe)
        guard try XCTUnwrap(probe.colorAt(x: probe.pixelsWide / 2, y: probe.pixelsHigh / 2)).alphaComponent > 0.5 else {
            throw XCTSkip("candwin.png is not available to the test bundle")
        }
        // Alpha at (x, row from top) in points; the rep may be 2x on Retina.
        func alpha(_ x: Int, _ rowFromTop: Int) throws -> CGFloat {
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = rep.pixelsWide / Int(view.bounds.width)
            return try XCTUnwrap(rep.colorAt(x: x * scale, y: rowFromTop * scale)).alphaComponent
        }
        XCTAssertGreaterThan(try alpha(17, 8), 0.8, "the tail is at the top-left of the original art")
        XCTAssertLessThan(try alpha(120, 8), 0.3, "nothing but the tail above the body")

        view.tailDirection = .down
        XCTAssertGreaterThan(try alpha(17, 117), 0.8, "mirrored: the tail is at the bottom-left")
        XCTAssertLessThan(try alpha(120, 117), 0.3)
        XCTAssertLessThan(try alpha(17, 2), 0.3, "and the top row is empty")
    }
}
