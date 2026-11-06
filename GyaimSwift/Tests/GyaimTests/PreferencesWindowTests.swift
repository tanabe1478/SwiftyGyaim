@testable import Gyaim
import XCTest

/// Toggles and selectors: default state, reflecting a pre-set value, and
/// saving on click. Key operations, reset and layout are in
/// PreferencesWindowBehaviorTests.
final class PreferencesWindowTests: XCTestCase {

    private lazy var window = PreferencesWindow()
    private var probe: PreferencesWindowProbe { PreferencesWindowProbe(window: window) }
    private let keys = PreferencesWindow.resettableKeys

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        window.close()
        PreferencesWindow.shared = nil
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    private func reopen() {
        window.close()
        window = PreferencesWindow()
    }

    // MARK: - Ranking section

    func testRankingTogglesExistWithDefaults() {
        XCTAssertEqual(probe.checkbox(titled: "同梱モデルを読み込む")?.state, .on, "bundled model defaults to on")
        XCTAssertEqual(probe.checkbox(titled: "文脈学習を使う")?.state, .on, "context learning defaults to on")
        XCTAssertNil(probe.checkbox(titled: "Tabで辞書から追加候補を選ぶ（辞書制約付き生成）"),
                     "generation toggle was removed with the Tab pipeline (ADR-024)")
        XCTAssertNotNil(probe.label(containing: "学習済みの文脈"))
    }

    func testBundledModelToggleRoundTrips() throws {
        let toggle = try XCTUnwrap(probe.checkbox(titled: "同梱モデルを読み込む"))
        toggle.performClick(nil)
        XCTAssertFalse(GyaimController.isBundledZenzEnabled)
        toggle.performClick(nil)
        XCTAssertTrue(GyaimController.isBundledZenzEnabled)
    }

    func testContextLearningToggleRoundTrips() throws {
        let toggle = try XCTUnwrap(probe.checkbox(titled: "文脈学習を使う"))
        toggle.performClick(nil)
        XCTAssertFalse(ContextDict.isEnabled)
        toggle.performClick(nil)
        XCTAssertTrue(ContextDict.isEnabled)
    }

    // MARK: - Default state

    func testClipboardToggleDefaultOn() {
        XCTAssertEqual(probe.checkbox(titled: "クリップボードの内容を候補に表示する")?.state, .on)
    }

    func testSelectedTextToggleDefaultOn() {
        XCTAssertEqual(probe.checkbox(titled: "選択テキストを候補に表示する")?.state, .on)
    }

    func testFastContextRerankToggleDefaultOn() {
        XCTAssertEqual(probe.checkbox(titled: "通常入力で候補を並べ替える")?.state, .on)
    }

    func testFastContextRerankModelToggleDefaultOff() {
        XCTAssertEqual(probe.checkbox(titled: "並べ替えに同梱モデルを使う")?.state, .off)
    }

    func testFastContextRerankLoggingToggleDefaultOff() {
        XCTAssertEqual(probe.checkbox(titled: "並べ替えのレイテンシと順序をログに出す")?.state, .off)
    }

    func testStudyHiraganaToggleDefaultOn() {
        XCTAssertEqual(probe.checkbox(titled: "平仮名の確定を学習する")?.state, .on)
    }

    func testDisplayModeControlDefaultIsClassic() throws {
        XCTAssertEqual(try XCTUnwrap(probe.displayModeControl).selectedSegment, 1,
                       "デフォルトはクラシック表示（セグメント1）であるべき")
    }

    func testEvictionModeControlDefaultValue() throws {
        XCTAssertEqual(try XCTUnwrap(probe.evictionModeControl).selectedSegment, EvictionMode.mru.rawValue,
                       "デフォルトはMRU（セグメント0）であるべき")
    }

    // MARK: - Toggle reflects pre-set settings

    func testClipboardToggleReflectsDisabledSetting() {
        GyaimController.setClipboardCandidateEnabled(false)
        reopen()
        XCTAssertEqual(probe.checkbox(titled: "クリップボードの内容を候補に表示する")?.state, .off)
    }

    func testSelectedTextToggleReflectsDisabledSetting() {
        GyaimController.setSelectedTextCandidateEnabled(false)
        reopen()
        XCTAssertEqual(probe.checkbox(titled: "選択テキストを候補に表示する")?.state, .off)
    }

    // MARK: - Clicking a control saves immediately

    func testClickClipboardToggleUpdatesSettings() throws {
        let toggle = try XCTUnwrap(probe.checkbox(titled: "クリップボードの内容を候補に表示する"))
        click(toggle, to: .off)
        XCTAssertFalse(GyaimController.isClipboardCandidateEnabled)
        click(toggle, to: .on)
        XCTAssertTrue(GyaimController.isClipboardCandidateEnabled)
    }

    func testClickSelectedTextToggleUpdatesSettings() throws {
        let toggle = try XCTUnwrap(probe.checkbox(titled: "選択テキストを候補に表示する"))
        click(toggle, to: .off)
        XCTAssertFalse(GyaimController.isSelectedTextCandidateEnabled)
        click(toggle, to: .on)
        XCTAssertTrue(GyaimController.isSelectedTextCandidateEnabled)
    }

    func testClickFastContextRerankToggleUpdatesSettings() throws {
        let toggle = try XCTUnwrap(probe.checkbox(titled: "通常入力で候補を並べ替える"))
        click(toggle, to: .off)
        XCTAssertFalse(GyaimController.isFastContextRerankEnabled)
        click(toggle, to: .on)
        XCTAssertTrue(GyaimController.isFastContextRerankEnabled)
    }

    func testClickFastContextRerankModelToggleUpdatesSettings() throws {
        let toggle = try XCTUnwrap(probe.checkbox(titled: "並べ替えに同梱モデルを使う"))
        click(toggle, to: .on)
        XCTAssertTrue(GyaimController.isFastContextRerankModelEnabled)
        click(toggle, to: .off)
        XCTAssertFalse(GyaimController.isFastContextRerankModelEnabled)
    }

    func testClickFastContextRerankLoggingToggleUpdatesSettings() throws {
        let toggle = try XCTUnwrap(probe.checkbox(titled: "並べ替えのレイテンシと順序をログに出す"))
        click(toggle, to: .on)
        XCTAssertTrue(GyaimController.isFastContextRerankLoggingEnabled)
        click(toggle, to: .off)
        XCTAssertFalse(GyaimController.isFastContextRerankLoggingEnabled)
    }

    func testClickStudyHiraganaToggleUpdatesSettings() throws {
        let toggle = try XCTUnwrap(probe.checkbox(titled: "平仮名の確定を学習する"))
        click(toggle, to: .off)
        XCTAssertFalse(WordSearch.isStudyHiraganaEnabled)
        click(toggle, to: .on)
        XCTAssertTrue(WordSearch.isStudyHiraganaEnabled)
    }

    func testClickDisplayModeControlUpdatesSettings() throws {
        let control = try XCTUnwrap(probe.displayModeControl)
        control.selectedSegment = 1
        control.sendAction(control.action, to: control.target)
        XCTAssertEqual(CandidateDisplayMode.current, .classic)

        control.selectedSegment = 0
        control.sendAction(control.action, to: control.target)
        XCTAssertEqual(CandidateDisplayMode.current, .list)
    }

    func testClickEvictionModeControlUpdatesSettings() throws {
        let control = try XCTUnwrap(probe.evictionModeControl)
        control.selectedSegment = EvictionMode.scoreBased.rawValue
        control.sendAction(control.action, to: control.target)
        XCTAssertEqual(EvictionMode.current, .scoreBased)
    }
}
