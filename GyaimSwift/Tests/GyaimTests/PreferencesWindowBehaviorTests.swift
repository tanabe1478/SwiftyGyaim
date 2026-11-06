@testable import Gyaim
import XCTest

/// Key operations save on change, reset covers everything shown, the window
/// fits the screen, and the standard Command shortcuts work without a menu.
final class PreferencesWindowBehaviorTests: XCTestCase {

    private lazy var window = PreferencesWindow()
    private var probe: PreferencesWindowProbe { PreferencesWindowProbe(window: window) }
    private var savedHiraganaChar: UInt8 = 0
    private var savedGoogleShortcuts: [KeyShortcut] = []
    private let keys = PreferencesWindow.resettableKeys

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        savedHiraganaChar = KeyBindings.shared.hiraganaChar
        savedGoogleShortcuts = KeyBindings.shared.googleTransliterate
    }

    override func tearDown() {
        window.close()
        PreferencesWindow.shared = nil
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        KeyBindings.shared.hiraganaChar = savedHiraganaChar
        KeyBindings.shared.googleTransliterate = savedGoogleShortcuts
        KeyBindings.shared.save()
        super.tearDown()
    }

    // MARK: - Key operations save on change

    func testSingleKeyFieldSavesValidKeyAndRejectsInvalid() throws {
        let field = try XCTUnwrap(probe.all(SingleKeyField.self).first, "the first single-key field is the hiragana key")
        XCTAssertEqual(field.value, KeyOperationSection.display(savedHiraganaChar))

        field.stringValue = "k"
        XCTAssertTrue(field.commit())
        XCTAssertEqual(KeyBindings.shared.hiraganaChar, UInt8(ascii: "k"), "saved as soon as editing ends")

        field.stringValue = "ab"
        XCTAssertFalse(field.commit(), "two characters are rejected")
        XCTAssertEqual(field.stringValue, "k", "and the field reverts")
        XCTAssertEqual(KeyBindings.shared.hiraganaChar, UInt8(ascii: "k"))

        field.stringValue = ""
        XCTAssertTrue(field.commit(), "empty disables the key")
        XCTAssertEqual(KeyBindings.shared.hiraganaChar, 0)
    }

    func testGoogleTriggerRejectsLettersAndDigits() {
        XCTAssertNil(KeyOperationSection.validateTrigger("a"))
        XCTAssertNil(KeyOperationSection.validateTrigger("1"))
        XCTAssertNil(KeyOperationSection.validateTrigger("``"))
        XCTAssertNil(KeyOperationSection.validateTrigger(""))
        XCTAssertEqual(KeyOperationSection.validateTrigger("`"), "`")
        XCTAssertEqual(KeyOperationSection.validateTrigger("/"), "/")
    }

    func testRecordedShortcutIsSavedWithoutASaveButton() throws {
        // The Google Transliterate list starts empty by default.
        let list = try XCTUnwrap(probe.all(ShortcutListView.self).first { $0.rows.isEmpty })
        list.addRow()
        let row = try XCTUnwrap(list.rows.last)
        XCTAssertEqual(KeyBindings.shared.googleTransliterate, savedGoogleShortcuts, "an empty row changes nothing")

        let shortcut = KeyShortcut(keyCode: 99, controlKey: true)
        row.setShortcut(shortcut)
        row.onChange?(row)
        XCTAssertEqual(KeyBindings.shared.googleTransliterate, savedGoogleShortcuts + [shortcut])

        XCTAssertNil(probe.button(titled: "保存"), "controls save on change; there is no Save button")
    }

    // MARK: - Reset

    func testResetDefaultsRestoresEverySettingShown() throws {
        GyaimController.setClipboardCandidateEnabled(false)
        CandidateDisplayMode.setCurrent(.list)
        EvictionMode.setCurrent(.scoreBased)
        Log.setEnabled(true)
        ContextDict.setEnabled(false)
        GoogleTransliterate.setTriggerSuffix("/")
        KeyBindings.shared.hiraganaChar = UInt8(ascii: "k")
        KeyBindings.shared.save()

        window.resetDefaults()

        XCTAssertTrue(GyaimController.isClipboardCandidateEnabled)
        XCTAssertEqual(CandidateDisplayMode.current, .classic)
        XCTAssertEqual(EvictionMode.current, .mru)
        XCTAssertFalse(Log.isEnabled)
        XCTAssertTrue(ContextDict.isEnabled)
        XCTAssertEqual(GoogleTransliterate.triggerSuffix, "`")
        XCTAssertEqual(KeyBindings.shared.hiraganaChar, UInt8(ascii: ";"))

        // Controls follow the settings without reopening the window.
        XCTAssertEqual(probe.checkbox(titled: "クリップボードの内容を候補に表示する")?.state, .on)
        XCTAssertEqual(try XCTUnwrap(probe.displayModeControl).selectedSegment, 1)
        XCTAssertEqual(try XCTUnwrap(probe.evictionModeControl).selectedSegment, 0)
        XCTAssertEqual(probe.checkbox(titled: "ロギングを有効にする")?.state, .off)
        XCTAssertEqual(try XCTUnwrap(probe.all(SingleKeyField.self).first).value, ";")
    }

    func testEveryResettableKeyIsKnownToSettings() {
        for key in PreferencesWindow.resettableKeys {
            XCTAssertTrue(GyaimSettings.knownKeys.contains(key), "\(key) is not in GyaimSettings.knownKeys")
        }
    }

    // MARK: - Layout

    func testWindowNeverOpensTallerThanTheScreen() throws {
        let screenHeight = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first).visibleFrame.height
        XCTAssertLessThanOrEqual(window.frame.height, screenHeight)
        XCTAssertGreaterThan(window.preferredContentHeight, 0)
        XCTAssertNotNil(probe.all(NSScrollView.self).first, "sections scroll when they do not fit")
    }

    func testHintsWrapInsteadOfTruncating() {
        let hints = probe.all(NSTextField.self).filter { $0.font?.pointSize == 11 && !$0.isEditable }
        XCTAssertFalse(hints.isEmpty)
        for hint in hints where hint.stringValue.count > 30 {
            XCTAssertEqual(hint.maximumNumberOfLines, 0, "\"\(hint.stringValue.prefix(20))…\" must wrap")
            XCTAssertGreaterThan(hint.preferredMaxLayoutWidth, 0)
        }
    }

    // MARK: - Standard command shortcuts

    func testCommandWClosesPreferencesWindowViaKeyEquivalent() throws {
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isVisible)

        XCTAssertTrue(window.performKeyEquivalent(with: try XCTUnwrap(probe.commandKeyEvent("w"))))

        XCTAssertFalse(window.isVisible)
    }

    func testCommandVDispatchesStandardPasteActionToFirstResponder() throws {
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        window.contentView?.addSubview(textField)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        XCTAssertTrue(window.makeFirstResponder(textField))

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("貼り付け", forType: .string)

        XCTAssertTrue(window.performKeyEquivalent(with: try XCTUnwrap(probe.commandKeyEvent("v"))))

        XCTAssertEqual(textField.stringValue, "貼り付け")
    }
}
