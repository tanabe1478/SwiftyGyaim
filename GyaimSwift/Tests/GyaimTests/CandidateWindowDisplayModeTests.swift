@testable import Gyaim
import XCTest

/// Every controller owns a candidate window; Preferences can only call
/// applyDisplayMode on `CandidateWindow.shared`. A window built under the old
/// mode must rebuild itself on its next update instead of showing an empty
/// bubble or an empty grey box (BUG-047).
final class CandidateWindowDisplayModeTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "candidateDisplayMode")
        CandidateWindow.shared = nil
        super.tearDown()
    }

    func testUpdateCandidatesAppliesAModeChangedAfterInit() throws {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()
        XCTAssertEqual(window.appliedDisplayMode, .classic)

        CandidateDisplayMode.setCurrent(.list)
        window.updateCandidates(["候補1", "候補2"], selectedIndex: 0)
        XCTAssertEqual(window.appliedDisplayMode, .list)
        let stack = try XCTUnwrap(find(NSStackView.self, in: window))
        XCTAssertFalse(stack.isHidden, "list stack must be visible after the switch")
        XCTAssertTrue(try XCTUnwrap(window.classicBackgroundView).isHidden)
        XCTAssertEqual(window.frame.width, 260)

        CandidateDisplayMode.setCurrent(.classic)
        window.updateCandidates(["候補1", "候補2"], selectedIndex: 0)
        XCTAssertEqual(window.appliedDisplayMode, .classic)
        XCTAssertFalse(try XCTUnwrap(window.classicBackgroundView).isHidden, "bubble art must be visible again")
        XCTAssertEqual(find(NSTextView.self, in: window)?.string, "候補1 候補2")
        XCTAssertEqual(window.frame.width, 241)
    }

    func testWindowCreatedAfterTheSwitchUsesTheNewModeWithoutAnUpdate() {
        CandidateDisplayMode.setCurrent(.list)
        let window = CandidateWindow()
        XCTAssertEqual(window.appliedDisplayMode, .list)
        window.updateCandidates(["候補1"], selectedIndex: 0)
        XCTAssertEqual(window.appliedDisplayMode, .list)
    }

    private func find<T: NSView>(_ type: T.Type, in window: NSWindow) -> T? {
        func walk(_ view: NSView) -> T? {
            for subview in view.subviews {
                if let match = subview as? T { return match }
                if let found = walk(subview) { return found }
            }
            return nil
        }
        return window.contentView.flatMap(walk)
    }
}
