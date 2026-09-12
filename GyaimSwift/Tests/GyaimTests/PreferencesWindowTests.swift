@testable import Gyaim
import XCTest

final class PreferencesWindowTests: XCTestCase {

    private var window: PreferencesWindow!

    override func setUp() {
        super.setUp()
        // Reset UserDefaults to ensure clean state
        UserDefaults.standard.removeObject(forKey: "clipboardCandidateEnabled")
        UserDefaults.standard.removeObject(forKey: "selectedTextCandidateEnabled")
        UserDefaults.standard.removeObject(forKey: "candidateDisplayMode")
        UserDefaults.standard.removeObject(forKey: "studyHiraganaEnabled")
        UserDefaults.standard.removeObject(forKey: "aiRerankFastContextEnabled")
        UserDefaults.standard.removeObject(forKey: "aiRerankUseModelForFastContext")
        UserDefaults.standard.removeObject(forKey: "aiRerankFastContextLoggingEnabled")
        UserDefaults.standard.removeObject(forKey: "aiRerankUseBundledZenz")
        UserDefaults.standard.removeObject(forKey: "contextLearningEnabled")
        window = PreferencesWindow()
    }

    override func tearDown() {
        window.close()
        PreferencesWindow.shared = nil
        window = nil
        UserDefaults.standard.removeObject(forKey: "clipboardCandidateEnabled")
        UserDefaults.standard.removeObject(forKey: "selectedTextCandidateEnabled")
        UserDefaults.standard.removeObject(forKey: "candidateDisplayMode")
        UserDefaults.standard.removeObject(forKey: "studyHiraganaEnabled")
        UserDefaults.standard.removeObject(forKey: "aiRerankFastContextEnabled")
        UserDefaults.standard.removeObject(forKey: "aiRerankUseModelForFastContext")
        UserDefaults.standard.removeObject(forKey: "aiRerankFastContextLoggingEnabled")
        UserDefaults.standard.removeObject(forKey: "aiRerankUseBundledZenz")
        UserDefaults.standard.removeObject(forKey: "contextLearningEnabled")
        super.tearDown()
    }

    // MARK: - AI section (issue #61)

    func testAIModelTogglesExistWithDefaults() {
        let zenz = findCheckbox(titled: "AIモデル（同梱Zenz）で候補を評価する")
        let learning = findCheckbox(titled: "文脈学習を使う（確定した文脈で同音異義語を選ぶ）")

        XCTAssertEqual(zenz?.state, .on, "bundled Zenz defaults to on")
        XCTAssertNil(findCheckbox(titled: "Tabで辞書から追加候補を選ぶ（辞書制約付き生成）"),
                     "generation toggle was removed with the Tab pipeline (ADR-024)")
        XCTAssertEqual(learning?.state, .on, "context learning defaults to on")
        XCTAssertNotNil(findLabel(containing: "学習済みの文脈"))
    }

    func testBundledZenzToggleRoundTrips() throws {
        let toggle = try XCTUnwrap(findCheckbox(titled: "AIモデル（同梱Zenz）で候補を評価する"))

        toggle.performClick(nil)
        XCTAssertFalse(GyaimController.isBundledZenzEnabled)
        toggle.performClick(nil)
        XCTAssertTrue(GyaimController.isBundledZenzEnabled)
    }

    func testContextLearningToggleRoundTrips() throws {
        let toggle = try XCTUnwrap(findCheckbox(titled: "文脈学習を使う（確定した文脈で同音異義語を選ぶ）"))

        toggle.performClick(nil)
        XCTAssertFalse(ContextDict.isEnabled)
        toggle.performClick(nil)
        XCTAssertTrue(ContextDict.isEnabled)
    }

    // MARK: - Helpers

    /// Find a checkbox (NSButton) by its title in the window's content view hierarchy.
    private func findCheckbox(titled title: String) -> NSButton? {
        guard let contentView = window.contentView else { return nil }
        return findButton(in: contentView, titled: title)
    }

    private func findSegmentedControl() -> NSSegmentedControl? {
        guard let contentView = window.contentView else { return nil }
        return findSegmented(in: contentView)
    }

    private func findSegmented(in view: NSView) -> NSSegmentedControl? {
        for subview in view.subviews {
            if let sc = subview as? NSSegmentedControl {
                return sc
            }
            if let found = findSegmented(in: subview) {
                return found
            }
        }
        return nil
    }

    private func findLabel(containing text: String) -> NSTextField? {
        guard let contentView = window.contentView else { return nil }
        return findTextField(in: contentView) { $0.stringValue.contains(text) }
    }

    private func findTextField(in view: NSView, matching predicate: (NSTextField) -> Bool) -> NSTextField? {
        for subview in view.subviews {
            if let textField = subview as? NSTextField, predicate(textField) {
                return textField
            }
            if let found = findTextField(in: subview, matching: predicate) {
                return found
            }
        }
        return nil
    }

    private func findButton(in view: NSView, titled title: String) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton, button.title == title {
                return button
            }
            if let found = findButton(in: subview, titled: title) {
                return found
            }
        }
        return nil
    }

    private func commandKeyEvent(_ key: String,
                                 modifiers: NSEvent.ModifierFlags = .command,
                                 keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: modifiers,
                         timestamp: 0,
                         windowNumber: window.windowNumber,
                         context: nil,
                         characters: key,
                         charactersIgnoringModifiers: key.lowercased(),
                         isARepeat: false,
                         keyCode: keyCode)!
    }

    // MARK: - Default state (both ON when UserDefaults unset)

    func testClipboardToggleDefaultOn() {
        let toggle = findCheckbox(titled: "クリップボードの内容を候補に表示する")!
        XCTAssertEqual(toggle.state, .on, "デフォルトでONであるべき")
    }

    func testSelectedTextToggleDefaultOn() {
        let toggle = findCheckbox(titled: "選択テキストを候補に表示する")!
        XCTAssertEqual(toggle.state, .on, "デフォルトでONであるべき")
    }

    func testFastContextRerankToggleDefaultOn() {
        let toggle = findCheckbox(titled: "通常入力で軽量rerankを使う")!
        XCTAssertEqual(toggle.state, .on, "軽量rerankはデフォルトでONであるべき")
    }

    func testFastContextRerankModelToggleDefaultOff() {
        let toggle = findCheckbox(titled: "軽量rerankでモデルbackendを使う（実験的）")!
        XCTAssertEqual(toggle.state, .off, "モデルbackendはデフォルトでOFFであるべき")
    }

    func testFastContextRerankLoggingToggleDefaultOff() {
        let toggle = findCheckbox(titled: "軽量rerankのレイテンシをログに出す")!
        XCTAssertEqual(toggle.state, .off, "軽量rerankログはデフォルトでOFFであるべき")
    }

    // MARK: - Toggle reflects pre-set UserDefaults

    func testClipboardToggleReflectsDisabledSetting() {
        window.close()
        GyaimController.setClipboardCandidateEnabled(false)
        window = PreferencesWindow()

        let toggle = findCheckbox(titled: "クリップボードの内容を候補に表示する")!
        XCTAssertEqual(toggle.state, .off, "UserDefaultsがfalseならOFFであるべき")
    }

    func testSelectedTextToggleReflectsDisabledSetting() {
        window.close()
        GyaimController.setSelectedTextCandidateEnabled(false)
        window = PreferencesWindow()

        let toggle = findCheckbox(titled: "選択テキストを候補に表示する")!
        XCTAssertEqual(toggle.state, .off, "UserDefaultsがfalseならOFFであるべき")
    }

    // MARK: - Click toggle updates UserDefaults

    func testClickClipboardToggleUpdatesUserDefaults() {
        let toggle = findCheckbox(titled: "クリップボードの内容を候補に表示する")!
        // Simulate click: toggle OFF
        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertFalse(GyaimController.isClipboardCandidateEnabled)

        // Simulate click: toggle ON
        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertTrue(GyaimController.isClipboardCandidateEnabled)
    }

    func testClickSelectedTextToggleUpdatesUserDefaults() {
        let toggle = findCheckbox(titled: "選択テキストを候補に表示する")!
        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertFalse(GyaimController.isSelectedTextCandidateEnabled)

        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertTrue(GyaimController.isSelectedTextCandidateEnabled)
    }

    func testClickFastContextRerankToggleUpdatesUserDefaults() {
        let toggle = findCheckbox(titled: "通常入力で軽量rerankを使う")!
        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertFalse(GyaimController.isFastContextRerankEnabled)

        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertTrue(GyaimController.isFastContextRerankEnabled)
    }

    func testClickFastContextRerankModelToggleUpdatesUserDefaults() {
        let toggle = findCheckbox(titled: "軽量rerankでモデルbackendを使う（実験的）")!
        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertTrue(GyaimController.isFastContextRerankModelEnabled)

        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertFalse(GyaimController.isFastContextRerankModelEnabled)
    }

    func testClickFastContextRerankLoggingToggleUpdatesUserDefaults() {
        let toggle = findCheckbox(titled: "軽量rerankのレイテンシをログに出す")!
        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertTrue(GyaimController.isFastContextRerankLoggingEnabled)

        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertFalse(GyaimController.isFastContextRerankLoggingEnabled)
    }

    // MARK: - Display mode control

    func testDisplayModeControlDefaultIsClassic() {
        let control = findSegmentedControl()!
        XCTAssertEqual(control.selectedSegment, 1, "デフォルトはクラシック表示（セグメント1）であるべき")
    }

    func testClickDisplayModeControlUpdatesUserDefaults() {
        let control = findSegmentedControl()!
        // Select classic
        control.selectedSegment = 1
        control.sendAction(control.action, to: control.target)
        XCTAssertEqual(CandidateDisplayMode.current, .classic)

        // Select list
        control.selectedSegment = 0
        control.sendAction(control.action, to: control.target)
        XCTAssertEqual(CandidateDisplayMode.current, .list)
    }

    // MARK: - Eviction mode control

    private func findAllSegmentedControls(in view: NSView) -> [NSSegmentedControl] {
        var results: [NSSegmentedControl] = []
        for subview in view.subviews {
            if let sc = subview as? NSSegmentedControl {
                results.append(sc)
            }
            results.append(contentsOf: findAllSegmentedControls(in: subview))
        }
        return results
    }

    private func findEvictionModeControl() -> NSSegmentedControl? {
        guard let contentView = window.contentView else { return nil }
        let all = findAllSegmentedControls(in: contentView)
        // The eviction mode control has 3 segments (MRU, 淘汰なし, スコアベース)
        return all.first { $0.segmentCount == 3 }
    }

    func testEvictionModeControlDefaultValue() {
        UserDefaults.standard.removeObject(forKey: "studyDictEvictionMode")
        window.close()
        window = PreferencesWindow()
        let control = findEvictionModeControl()!
        XCTAssertEqual(control.selectedSegment, EvictionMode.mru.rawValue,
                       "デフォルトはMRU（セグメント0）であるべき")
    }

    // MARK: - Study Hiragana Toggle

    func testStudyHiraganaToggleDefaultOn() {
        UserDefaults.standard.removeObject(forKey: "studyHiraganaEnabled")
        window.close()
        window = PreferencesWindow()
        let toggle = findCheckbox(titled: "平仮名の確定を学習する")!
        XCTAssertEqual(toggle.state, .on, "デフォルトでONであるべき")
    }

    func testClickStudyHiraganaToggleUpdatesUserDefaults() {
        let toggle = findCheckbox(titled: "平仮名の確定を学習する")!
        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertFalse(WordSearch.isStudyHiraganaEnabled)

        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertTrue(WordSearch.isStudyHiraganaEnabled)
    }

    // MARK: - Standard command shortcuts

    func testCommandWClosesPreferencesWindowViaKeyEquivalent() {
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isVisible)

        XCTAssertTrue(window.performKeyEquivalent(with: commandKeyEvent("w")))

        XCTAssertFalse(window.isVisible)
    }

    func testCommandVDispatchesStandardPasteActionToFirstResponder() {
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        window.contentView?.addSubview(textField)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        XCTAssertTrue(window.makeFirstResponder(textField))

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("貼り付け", forType: .string)

        XCTAssertTrue(window.performKeyEquivalent(with: commandKeyEvent("v")))

        XCTAssertEqual(textField.stringValue, "貼り付け")
    }
}
