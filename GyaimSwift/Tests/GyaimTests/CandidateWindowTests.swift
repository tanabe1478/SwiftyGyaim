@testable import Gyaim
import XCTest

final class CandidateWindowTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "candidateDisplayMode")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "candidateDisplayMode")
        super.tearDown()
    }

    // MARK: - Classic mode rendering

    func testUpdateCandidatesClassicMode() {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()
        window.updateCandidates(["候補1", "候補2", "候補3"], selectedIndex: 0)

        // Classic mode should have NSTextView with space-separated text
        let textView = findClassicTextView(in: window)
        XCTAssertNotNil(textView, "クラシックモードにはテキストビューが必要")
        XCTAssertTrue(textView?.string.contains("候補1") ?? false)
        XCTAssertTrue(textView?.string.contains("候補2") ?? false)

        // Classic mode should have background view
        let scrollView = findView(in: window.contentView!) { (_: NSScrollView) in true }
        XCTAssertNotNil(scrollView, "クラシックモードにはスクロールビューが必要")

        CandidateWindow.shared = nil
    }

    func testClassicModeMaxVisible() {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()
        let words = (0..<15).map { "候補\($0)" }
        window.updateCandidates(words, selectedIndex: 0)

        let textView = findClassicTextView(in: window)
        XCTAssertNotNil(textView)
        // Classic mode shows at most 11 candidates (space separated)
        let parts = textView!.string.components(separatedBy: " ").filter { !$0.isEmpty }
        XCTAssertLessThanOrEqual(parts.count, 11, "クラシックモードは最大11候補")

        CandidateWindow.shared = nil
    }

    func testClassicModeSizesTextViewForWrappedLongCandidates() {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()
        let words = [
            "sitei", "指定", "しているの？", "しているところはない？", "していますか？",
            "しているところないの？", "していないよね？", "していませんか？", "している",
            "しているのかを", "しているよね"
        ]
        window.updateCandidates(words, selectedIndex: 0, hasMore: true)

        let textView = findClassicTextView(in: window)
        XCTAssertNotNil(textView)
        XCTAssertFalse(textView!.string.isEmpty)
        XCTAssertGreaterThan(textView!.frame.width, 0)
        XCTAssertGreaterThanOrEqual(textView!.frame.height, 79)
        XCTAssertGreaterThanOrEqual(window.frame.height, 126)

        CandidateWindow.shared = nil
    }

    func testApplyDisplayModeSwitches() {
        CandidateDisplayMode.setCurrent(.list)
        let window = CandidateWindow()
        window.updateCandidates(["A", "B", "C"], selectedIndex: 0)

        // List mode — stackView should have labels
        let stackLabels = findStackViewLabels(in: window)
        XCTAssertFalse(stackLabels.isEmpty, "リストモードではstackViewにラベルがあるべき")

        // Switch to classic
        CandidateDisplayMode.setCurrent(.classic)
        window.applyDisplayMode()
        window.updateCandidates(["A", "B", "C"], selectedIndex: 0)

        let textView = findClassicTextView(in: window)
        XCTAssertNotNil(textView, "クラシックモード切り替え後にテキストビューがあるべき")

        // Switch back to list
        CandidateDisplayMode.setCurrent(.list)
        window.applyDisplayMode()
        window.updateCandidates(["A", "B", "C"], selectedIndex: 0)

        let stackLabelsAfter = findStackViewLabels(in: window)
        XCTAssertFalse(stackLabelsAfter.isEmpty, "リストモードに戻った後stackViewにラベルがあるべき")

        CandidateWindow.shared = nil
    }

    func testListModeMaxVisible() {
        CandidateDisplayMode.setCurrent(.list)
        let window = CandidateWindow()
        let words = (0..<15).map { "候補\($0)" }
        window.updateCandidates(words, selectedIndex: 0)

        let labels = findStackViewLabels(in: window)
        XCTAssertLessThanOrEqual(labels.count, 9, "リストモードは最大9候補")

        CandidateWindow.shared = nil
    }

    // MARK: - Page indicator tests

    // hasPrev には表示上の効果がない（▲は出さない）。hasMore のみが▼を制御する。

    func testClassicModeShowsDownArrowOnlyWhenHasMore() {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()

        window.updateCandidates(["候補1", "候補2", "候補3"], selectedIndex: 0, hasMore: true, hasPrev: true)
        var text = findClassicTextView(in: window)?.string ?? ""
        XCTAssertTrue(text.hasSuffix("▼"), "hasMore時にクラシック表示の末尾に▼があるべき: \(text)")
        XCTAssertFalse(text.contains("▲"), "▲は表示しない")

        window.updateCandidates(["候補1", "候補2"], selectedIndex: 0, hasMore: false, hasPrev: true)
        text = findClassicTextView(in: window)?.string ?? ""
        XCTAssertFalse(text.contains("▼"), "hasMore=false時に▼は不要")
        XCTAssertFalse(text.contains("▲"), "▲は表示しない")

        CandidateWindow.shared = nil
    }

    func testListModeShowsIndicatorRowOnlyWhenHasMore() {
        CandidateDisplayMode.setCurrent(.list)
        let window = CandidateWindow()

        window.updateCandidates(["候補1", "候補2"], selectedIndex: 0, hasMore: true, hasPrev: true)
        var labels = findStackViewLabels(in: window)
        let lastLabel = labels.last?.stringValue ?? ""
        XCTAssertTrue(lastLabel.contains("▼"), "hasMore時にリスト表示の末尾に▼インジケータがあるべき: \(lastLabel)")
        XCTAssertFalse(lastLabel.contains("▲"), "▲は表示しない: \(lastLabel)")

        window.updateCandidates(["候補1", "候補2"], selectedIndex: 0, hasMore: false, hasPrev: true)
        labels = findStackViewLabels(in: window)
        XCTAssertEqual(labels.count, 2, "hasMore=false ではインジケータ行なし（候補2件のみ）")

        CandidateWindow.shared = nil
    }

    // MARK: - Window positioning (pure function tests)

    // lineRect.origin.y = カーソル行の下端 (macOS座標系: Y上向き)
    // lineRect.origin.y + lineRect.height = カーソル行の上端
    // setFrameOrigin = ウィンドウの左下を設定

    private let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

    func testListModePositionsBelowCursorAndFlipsAboveNearBottom() {
        let winSize = NSSize(width: 260, height: 200)

        // 画面中央のカーソル → カーソルの下に配置（gap 5）
        let center = NSRect(x: 100, y: 500, width: 1, height: 20)
        let below = CandidateWindowPositioner.calculate(
            lineRect: center, winSize: winSize, screenFrame: screenFrame, mode: .list)
        XCTAssertEqual(below.y, center.origin.y - winSize.height - 5, "リストモードはカーソルの下に配置")
        XCTAssertEqual(below.x, center.origin.x - 5)

        // 画面下端付近 → 下に収まらないので上にフリップ
        let nearBottom = NSRect(x: 100, y: 50, width: 1, height: 20)
        let above = CandidateWindowPositioner.calculate(
            lineRect: nearBottom, winSize: winSize, screenFrame: screenFrame, mode: .list)
        XCTAssertEqual(above.y, nearBottom.origin.y + nearBottom.height + 5, "画面下端ではカーソルの上に配置")
    }

    func testClassicModePositionsBelowCursorFlipsAndClampsToScreen() {
        let winSize = NSSize(width: 300, height: 100)

        // クラシックモード: カーソルの下にぴったり（gap 0）
        let center = NSRect(x: 100, y: 500, width: 1, height: 20)
        let below = CandidateWindowPositioner.calculate(
            lineRect: center, winSize: winSize, screenFrame: screenFrame, mode: .classic)
        XCTAssertEqual(below.y, center.origin.y - winSize.height, "クラシックモードはカーソルの下に配置")

        // 画面下端付近 → カーソル上端の上にフリップ
        let nearBottom = NSRect(x: 100, y: 50, width: 1, height: 20)
        let above = CandidateWindowPositioner.calculate(
            lineRect: nearBottom, winSize: winSize, screenFrame: screenFrame, mode: .classic)
        XCTAssertEqual(above.y, nearBottom.origin.y + nearBottom.height, "画面下端ではカーソルの上に配置")

        // 画面右端付近 → ウィンドウが右にはみ出さない
        let nearRight = NSRect(x: 1400, y: 500, width: 1, height: 20)
        let clampedRight = CandidateWindowPositioner.calculate(
            lineRect: nearRight, winSize: winSize, screenFrame: screenFrame, mode: .classic)
        XCTAssertLessThanOrEqual(clampedRight.x + winSize.width, screenFrame.maxX, "ウィンドウが画面右端からはみ出さない")

        // 上下どちらにも収まらない → 画面下端より下には出さない
        let tall = NSSize(width: 300, height: 1000)
        let clampedTop = CandidateWindowPositioner.calculate(
            lineRect: NSRect(x: 100, y: 10, width: 1, height: 20), winSize: tall,
            screenFrame: screenFrame, mode: .classic)
        XCTAssertEqual(clampedTop.y, screenFrame.minY, "上下どちらにも収まらない場合も画面下端より下には出さない")
    }

    func testValidReportedLineRectIsUsedAsIs() {
        let reported = NSRect(x: 300, y: 400, width: 1, height: 18)
        let previous = NSRect(x: 700, y: 600, width: 1, height: 20)

        let resolution = CandidateWindowPositioner.resolveLineRect(
            reportedLineRect: reported,
            previousValidLineRect: previous,
            mouseLocation: NSPoint(x: 900, y: 800))

        XCTAssertEqual(resolution.source, .reported)
        XCTAssertEqual(resolution.lineRect, reported)
    }

    func testSuspiciousOriginLineRectFallsBackToPreviousValidRect() {
        // Issue #10: Web apps can report local coordinates like this instead of screen coordinates.
        let suspicious = NSRect(x: 13.75, y: 12.0, width: 1.0, height: 17.5)
        let previous = NSRect(x: 700, y: 600, width: 1, height: 20)

        let resolution = CandidateWindowPositioner.resolveLineRect(
            reportedLineRect: suspicious,
            previousValidLineRect: previous,
            mouseLocation: NSPoint(x: 900, y: 800))

        XCTAssertEqual(resolution.source, .previousValid)
        XCTAssertEqual(resolution.lineRect, previous)
    }

    func testSuspiciousOriginLineRectFallsBackToMouseWhenNoPreviousRect() {
        let suspicious = NSRect(x: 13.75, y: 12.0, width: 1.0, height: 17.5)
        let mouse = NSPoint(x: 900, y: 800)

        let resolution = CandidateWindowPositioner.resolveLineRect(
            reportedLineRect: suspicious,
            previousValidLineRect: nil,
            mouseLocation: mouse)

        XCTAssertEqual(resolution.source, .mouseLocation)
        XCTAssertEqual(resolution.lineRect.origin, mouse)
        XCTAssertEqual(resolution.lineRect.width, 1)
        XCTAssertEqual(resolution.lineRect.height, suspicious.height)
    }

    // MARK: - Classic layout containment

    func testClassicScrollViewIsContainedInBackground() {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()
        window.updateCandidates(
            ["あてているのに", "あと", "合わせて", "会わせて",
             "あいうえおいそいだふぉう", "ありますか", "ある",
             "あんまり", "あまり", "あったみたい"],
            selectedIndex: 0)

        // Force layout
        window.contentView?.layoutSubtreeIfNeeded()

        guard let contentView = window.contentView else {
            XCTFail("contentView is nil"); return
        }
        guard let scrollView = findView(in: contentView, matching: { (sv: NSScrollView) in !sv.isHidden }) else {
            XCTFail("visible NSScrollView not found"); return
        }
        let containerFrame = contentView.bounds
        let scrollFrame = scrollView.superview?.convert(scrollView.frame, to: contentView) ?? scrollView.frame

        // scrollView must be fully inside container (i.e., inside the green bubble)
        XCTAssertGreaterThanOrEqual(scrollFrame.minX, 0,
            "scrollView左端がコンテナからはみ出している (scrollFrame=\(scrollFrame), container=\(containerFrame))")
        XCTAssertGreaterThanOrEqual(scrollFrame.minY, 0,
            "scrollView下端がコンテナからはみ出している (scrollFrame=\(scrollFrame), container=\(containerFrame))")
        XCTAssertLessThanOrEqual(scrollFrame.maxX, containerFrame.maxX,
            "scrollView右端がコンテナからはみ出している (scrollFrame=\(scrollFrame), container=\(containerFrame))")
        XCTAssertLessThanOrEqual(scrollFrame.maxY, containerFrame.maxY,
            "scrollView上端がコンテナからはみ出している (scrollFrame=\(scrollFrame), container=\(containerFrame))")

        // Verify minimum insets (at least 10pt on each side)
        XCTAssertGreaterThanOrEqual(scrollFrame.minX, 10,
            "左マージンが不足 (scrollFrame=\(scrollFrame))")
        XCTAssertGreaterThanOrEqual(scrollFrame.minY, 10,
            "下マージンが不足 (scrollFrame=\(scrollFrame))")
        XCTAssertGreaterThanOrEqual(containerFrame.maxX - scrollFrame.maxX, 10,
            "右マージンが不足 (scrollFrame=\(scrollFrame), container=\(containerFrame))")
        XCTAssertGreaterThanOrEqual(containerFrame.maxY - scrollFrame.maxY, 10,
            "上マージンが不足 (scrollFrame=\(scrollFrame), container=\(containerFrame))")

        CandidateWindow.shared = nil
    }

    // MARK: - Helpers

    private func findClassicTextView(in window: CandidateWindow) -> NSTextView? {
        guard let contentView = window.contentView else { return nil }
        // Find NSTextView inside NSScrollView (classic mode structure)
        if let scrollView = findView(in: contentView, matching: { (_: NSScrollView) in true }),
           let textView = scrollView.documentView as? NSTextView {
            return textView
        }
        return nil
    }

    private func findStackViewLabels(in window: CandidateWindow) -> [NSTextField] {
        guard let contentView = window.contentView else { return [] }
        var labels: [NSTextField] = []
        findLabelsInStackView(in: contentView, labels: &labels)
        return labels
    }

    private func findLabelsInStackView(in view: NSView, labels: inout [NSTextField]) {
        if let stackView = view as? NSStackView {
            for subview in stackView.arrangedSubviews {
                if let tf = subview as? NSTextField {
                    labels.append(tf)
                }
            }
            return
        }
        for subview in view.subviews {
            findLabelsInStackView(in: subview, labels: &labels)
        }
    }

    private func findView<T: NSView>(in view: NSView, matching predicate: (T) -> Bool) -> T? {
        if let match = view as? T, predicate(match) {
            return match
        }
        for subview in view.subviews {
            if let found = findView(in: subview, matching: predicate) {
                return found
            }
        }
        return nil
    }
}
