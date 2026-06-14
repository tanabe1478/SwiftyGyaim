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
        super.tearDown()
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

    // MARK: - Checkbox existence

    func testClipboardToggleExists() {
        let toggle = findCheckbox(titled: "クリップボードの内容を候補に表示する")
        XCTAssertNotNil(toggle, "クリップボード候補のトグルが見つからない")
    }

    func testSelectedTextToggleExists() {
        let toggle = findCheckbox(titled: "選択テキストを候補に表示する")
        XCTAssertNotNil(toggle, "選択テキスト候補のトグルが見つからない")
    }

    func testLogToggleExists() {
        let toggle = findCheckbox(titled: "ロギングを有効にする")
        XCTAssertNotNil(toggle, "ログトグルが見つからない")
    }

    func testFastContextRerankToggleExists() {
        let toggle = findCheckbox(titled: "通常入力で軽量rerankを使う")
        XCTAssertNotNil(toggle, "軽量rerankトグルが見つからない")
    }

    func testFastContextRerankModelToggleExists() {
        let toggle = findCheckbox(titled: "軽量rerankでモデルbackendを使う（実験的）")
        XCTAssertNotNil(toggle, "軽量rerankモデルbackendトグルが見つからない")
    }

    func testFastContextRerankLoggingToggleExists() {
        let toggle = findCheckbox(titled: "軽量rerankのレイテンシをログに出す")
        XCTAssertNotNil(toggle, "軽量rerankログトグルが見つからない")
    }

    func testConnectionDictionaryImportUsageHintExists() {
        let hint = findLabel(containing: "リポジトリURLまたは raw の dict2.txt URL")
        XCTAssertNotNil(hint, "接続辞書インポートで指定すべきURLの説明が見つからない")
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

    func testDisplayModeControlExists() {
        let control = findSegmentedControl()
        XCTAssertNotNil(control, "表示スタイルのセグメントコントロールが見つからない")
    }

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

    // MARK: - Section title exists

    func testCandidateSectionTitleExists() {
        guard let contentView = window.contentView else {
            XCTFail("contentView is nil")
            return
        }
        let labels = contentView.subviews.compactMap { $0 as? NSTextField }
        let found = labels.contains { $0.stringValue == "候補" }
        XCTAssertTrue(found, "「候補」セクションタイトルが見つからない")
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

    func testEvictionModeControlExists() {
        UserDefaults.standard.removeObject(forKey: "studyDictEvictionMode")
        window.close()
        window = PreferencesWindow()
        let control = findEvictionModeControl()
        XCTAssertNotNil(control, "淘汰方式のセグメントコントロールが見つからない")
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

    func testStudyHiraganaToggleExists() {
        let toggle = findCheckbox(titled: "平仮名の確定を学習する")
        XCTAssertNotNil(toggle, "平仮名学習のトグルが見つからない")
    }

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
}
