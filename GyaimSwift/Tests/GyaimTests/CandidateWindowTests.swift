import XCTest
@testable import Gyaim

final class CandidateWindowTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "candidateDisplayMode")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "candidateDisplayMode")
        super.tearDown()
    }

    // MARK: - Phase 1: enum + UserDefaults

    func testDefaultDisplayModeIsClassic() {
        XCTAssertEqual(CandidateDisplayMode.current, .classic)
    }

    func testSetDisplayModeClassic() {
        CandidateDisplayMode.setCurrent(.classic)
        XCTAssertEqual(CandidateDisplayMode.current, .classic)
    }

    func testSetDisplayModeList() {
        CandidateDisplayMode.setCurrent(.classic)
        CandidateDisplayMode.setCurrent(.list)
        XCTAssertEqual(CandidateDisplayMode.current, .list)
    }

    // MARK: - Phase 2: Classic mode rendering

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
        let scrollView = findView(in: window.contentView!) { (sv: NSScrollView) in true }
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

    func testClassicModeKeepsOriginalMinimumHeight() {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()
        window.updateCandidates(["短い候補"], selectedIndex: 0)

        XCTAssertEqual(window.frame.width, 241, accuracy: 0.5)
        XCTAssertEqual(window.frame.height, 126, accuracy: 0.5)

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

    func testClassicModeShowsDownArrowWhenHasMore() {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()
        window.updateCandidates(["候補1", "候補2", "候補3"], selectedIndex: 0, hasMore: true, hasPrev: false)

        let textView = findClassicTextView(in: window)
        XCTAssertNotNil(textView)
        XCTAssertTrue(textView!.string.hasSuffix("▼"), "hasMore時にクラシック表示の末尾に▼があるべき: \(textView!.string)")
        XCTAssertFalse(textView!.string.hasPrefix("▲"), "hasPrev=false時に▲は不要")

        CandidateWindow.shared = nil
    }

    func testClassicModeShowsUpArrowWhenHasPrev() {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()
        window.updateCandidates(["候補1", "候補2", "候補3"], selectedIndex: 0, hasMore: false, hasPrev: true)

        let textView = findClassicTextView(in: window)
        XCTAssertNotNil(textView)
        XCTAssertTrue(textView!.string.hasPrefix("▲"), "hasPrev時にクラシック表示の先頭に▲があるべき: \(textView!.string)")
        XCTAssertFalse(textView!.string.hasSuffix("▼"), "hasMore=false時に▼は不要")

        CandidateWindow.shared = nil
    }

    func testClassicModeShowsBothArrows() {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()
        window.updateCandidates(["候補1", "候補2"], selectedIndex: 0, hasMore: true, hasPrev: true)

        let textView = findClassicTextView(in: window)
        XCTAssertNotNil(textView)
        XCTAssertTrue(textView!.string.hasPrefix("▲"), "両方向のページ送り時に▲があるべき")
        XCTAssertTrue(textView!.string.hasSuffix("▼"), "両方向のページ送り時に▼があるべき")

        CandidateWindow.shared = nil
    }

    func testClassicModeNoArrowsWhenNoPageInfo() {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()
        window.updateCandidates(["候補1", "候補2"], selectedIndex: 0)

        let textView = findClassicTextView(in: window)
        XCTAssertNotNil(textView)
        XCTAssertFalse(textView!.string.contains("▲"), "ページ情報なしでは▲不要")
        XCTAssertFalse(textView!.string.contains("▼"), "ページ情報なしでは▼不要")

        CandidateWindow.shared = nil
    }

    func testListModeShowsIndicatorWhenHasMore() {
        CandidateDisplayMode.setCurrent(.list)
        let window = CandidateWindow()
        window.updateCandidates(["候補1", "候補2"], selectedIndex: 0, hasMore: true, hasPrev: false)

        let labels = findStackViewLabels(in: window)
        let lastLabel = labels.last?.stringValue ?? ""
        XCTAssertTrue(lastLabel.contains("▼"), "hasMore時にリスト表示の末尾に▼インジケータがあるべき: \(lastLabel)")

        CandidateWindow.shared = nil
    }

    func testListModeShowsIndicatorWhenHasPrev() {
        CandidateDisplayMode.setCurrent(.list)
        let window = CandidateWindow()
        window.updateCandidates(["候補1", "候補2"], selectedIndex: 0, hasMore: false, hasPrev: true)

        let labels = findStackViewLabels(in: window)
        let lastLabel = labels.last?.stringValue ?? ""
        XCTAssertTrue(lastLabel.contains("▲"), "hasPrev時にリスト表示に▲インジケータがあるべき: \(lastLabel)")

        CandidateWindow.shared = nil
    }

    func testListModeShowsBothIndicators() {
        CandidateDisplayMode.setCurrent(.list)
        let window = CandidateWindow()
        window.updateCandidates(["候補1", "候補2"], selectedIndex: 0, hasMore: true, hasPrev: true)

        let labels = findStackViewLabels(in: window)
        let lastLabel = labels.last?.stringValue ?? ""
        XCTAssertTrue(lastLabel.contains("▲"), "両方向時に▲があるべき: \(lastLabel)")
        XCTAssertTrue(lastLabel.contains("▼"), "両方向時に▼があるべき: \(lastLabel)")

        CandidateWindow.shared = nil
    }

    // MARK: - Window positioning (pure function tests)

    // lineRect.origin.y = カーソル行の下端 (macOS座標系: Y上向き)
    // lineRect.origin.y + lineRect.height = カーソル行の上端
    // setFrameOrigin = ウィンドウの左下を設定

    func testListModePositionsBelowCursor() {
        // 画面中央のカーソル、リストモード → カーソルの下に配置
        let lineRect = NSRect(x: 100, y: 500, width: 1, height: 20)
        let winSize = NSSize(width: 260, height: 200)
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin = CandidateWindowPositioner.calculate(
            lineRect: lineRect, winSize: winSize,
            screenFrame: screenFrame, mode: .list)

        // ウィンドウ上端 = カーソル下端 - gap
        XCTAssertEqual(origin.y, lineRect.origin.y - winSize.height - 5,
                       "リストモードはカーソルの下に配置")
        XCTAssertEqual(origin.x, lineRect.origin.x - 5)
    }

    func testListModeFlipsAboveWhenNearScreenBottom() {
        // カーソルが画面下端付近 → 下に収まらないので上にフリップ
        let lineRect = NSRect(x: 100, y: 50, width: 1, height: 20)
        let winSize = NSSize(width: 260, height: 200)
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin = CandidateWindowPositioner.calculate(
            lineRect: lineRect, winSize: winSize,
            screenFrame: screenFrame, mode: .list)

        // カーソル上端の上に配置
        XCTAssertEqual(origin.y, lineRect.origin.y + lineRect.height + 5,
                       "画面下端ではカーソルの上に配置")
    }

    func testClassicModePositionsBelowCursor() {
        // クラシックモード: 他のIMEと同様にカーソルの下に配置
        // (吹き出しの三角は装飾であり、位置決めはカーソル下が自然)
        let lineRect = NSRect(x: 100, y: 500, width: 1, height: 20)
        let winSize = NSSize(width: 300, height: 100)
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin = CandidateWindowPositioner.calculate(
            lineRect: lineRect, winSize: winSize,
            screenFrame: screenFrame, mode: .classic)

        // ウィンドウ上端 = カーソル下端 (gap=0でぴったり)
        XCTAssertEqual(origin.y, lineRect.origin.y - winSize.height,
                       "クラシックモードはカーソルの下に配置")
    }

    func testClassicModeFlipsAboveWhenNearScreenBottom() {
        let lineRect = NSRect(x: 100, y: 50, width: 1, height: 20)
        let winSize = NSSize(width: 300, height: 100)
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin = CandidateWindowPositioner.calculate(
            lineRect: lineRect, winSize: winSize,
            screenFrame: screenFrame, mode: .classic)

        // 下に収まらないのでカーソル上端の上に配置
        XCTAssertEqual(origin.y, lineRect.origin.y + lineRect.height,
                       "画面下端ではカーソルの上に配置")
    }

    func testPositionClampsToScreenRight() {
        // カーソルが画面右端付近 → ウィンドウが右にはみ出さない
        let lineRect = NSRect(x: 1400, y: 500, width: 1, height: 20)
        let winSize = NSSize(width: 300, height: 100)
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin = CandidateWindowPositioner.calculate(
            lineRect: lineRect, winSize: winSize,
            screenFrame: screenFrame, mode: .classic)

        XCTAssertLessThanOrEqual(origin.x + winSize.width, screenFrame.maxX,
                                  "ウィンドウが画面右端からはみ出さない")
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

    func testClassicScrollViewInsetsMatchConstants() {
        CandidateDisplayMode.setCurrent(.classic)
        let window = CandidateWindow()
        window.updateCandidates(["テスト", "候補"], selectedIndex: 0)

        window.contentView?.layoutSubtreeIfNeeded()

        guard let contentView = window.contentView else {
            XCTFail("contentView is nil"); return
        }
        guard let scrollView = findView(in: contentView, matching: { (sv: NSScrollView) in !sv.isHidden }) else {
            XCTFail("visible NSScrollView not found"); return
        }
        let containerFrame = contentView.bounds
        let scrollFrame = scrollView.superview?.convert(scrollView.frame, to: contentView) ?? scrollView.frame

        // Verify insets match exactly (within 1pt tolerance for rounding)
        let leftInset = scrollFrame.minX
        let bottomInset = scrollFrame.minY
        let rightInset = containerFrame.maxX - scrollFrame.maxX
        let topInset = containerFrame.maxY - scrollFrame.maxY

        // Print actual values for debugging
        print("Classic layout: container=\(containerFrame), scroll=\(scrollFrame)")
        print("Insets: top=\(topInset), left=\(leftInset), bottom=\(bottomInset), right=\(rightInset)")

        // Match the current classic bubble content insets.
        XCTAssertEqual(leftInset, 20, accuracy: 1, "左インセットが期待値と異なる")
        XCTAssertEqual(rightInset, 20, accuracy: 1, "右インセットが期待値と異なる")
        XCTAssertEqual(topInset, 27, accuracy: 1, "上インセットが期待値と異なる")
        XCTAssertEqual(bottomInset, 20, accuracy: 1, "下インセットが期待値と異なる")

        CandidateWindow.shared = nil
    }

    // MARK: - Helpers

    private func findClassicTextView(in window: CandidateWindow) -> NSTextView? {
        guard let contentView = window.contentView else { return nil }
        // Find NSTextView inside NSScrollView (classic mode structure)
        if let scrollView = findView(in: contentView, matching: { (sv: NSScrollView) in true }),
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
