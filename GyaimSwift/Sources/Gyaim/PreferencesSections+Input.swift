import Cocoa

// MARK: - Key operations

/// Confirm keys, Google trigger and delete-candidate keys. Single keys are
/// plain ASCII characters that act while converting; modifier shortcuts are
/// recorded rows. Everything is saved to KeyBindings / settings on change.
final class KeyOperationSection: PreferencesSection {
    private let hiraganaKey: SingleKeyField
    private let katakanaKey: SingleKeyField
    private let deleteKey: SingleKeyField
    private let googleTrigger: SingleKeyField
    private let hiraganaList: ShortcutListView
    private let katakanaList: ShortcutListView
    private let googleList: ShortcutListView
    private let deleteList: ShortcutListView

    init() {
        let bindings = KeyBindings.shared
        hiraganaKey = Self.makeSingleKeyField(bindings.hiraganaChar) { KeyBindings.shared.hiraganaChar = $0 }
        katakanaKey = Self.makeSingleKeyField(bindings.katakanaChar) { KeyBindings.shared.katakanaChar = $0 }
        deleteKey = Self.makeSingleKeyField(bindings.deleteCandidateChar) { KeyBindings.shared.deleteCandidateChar = $0 }
        googleTrigger = SingleKeyField(value: GoogleTransliterate.triggerSuffix, placeholder: "`")
        googleTrigger.validate = Self.validateTrigger
        googleTrigger.onChange = { GoogleTransliterate.setTriggerSuffix($0) }
        hiraganaList = Self.makeShortcutList(bindings.hiragana, minimumCount: 1) { KeyBindings.shared.hiragana = $0 }
        katakanaList = Self.makeShortcutList(bindings.katakana, minimumCount: 1) { KeyBindings.shared.katakana = $0 }
        googleList = Self.makeShortcutList(bindings.googleTransliterate) { KeyBindings.shared.googleTransliterate = $0 }
        deleteList = Self.makeShortcutList(bindings.deleteCandidate) { KeyBindings.shared.deleteCandidate = $0 }
        super.init(title: "キー操作")

        addLabeledRow("ひらがな確定:", hiraganaKey, trailing: Self.makeLabel("単独キー（変換中に押す。空欄で無効）"))
        addRow(Self.makeLabel("ショートカット:"))
        addFullWidthRow(hiraganaList)

        addLabeledRow("カタカナ確定:", katakanaKey, trailing: Self.makeLabel("単独キー"))
        addRow(Self.makeLabel("ショートカット:"))
        addFullWidthRow(katakanaList)

        addLabeledRow("Google 変換:", googleTrigger, trailing: Self.makeLabel("入力末尾に付ける記号（例: meguro`）"))
        addRow(Self.makeLabel("ショートカット:"))
        addFullWidthRow(googleList)

        addLabeledRow("候補削除:", deleteKey, trailing: Self.makeLabel("単独キー（既定は Shift+X）"))
        addHint("候補表示中に押すと、選択中の候補を学習辞書 / ユーザー辞書から削除します", indent: false)
        addRow(Self.makeLabel("ショートカット:"))
        addFullWidthRow(deleteList)
    }

    override func reload() {
        let bindings = KeyBindings.shared
        hiraganaKey.setValue(Self.display(bindings.hiraganaChar))
        katakanaKey.setValue(Self.display(bindings.katakanaChar))
        deleteKey.setValue(Self.display(bindings.deleteCandidateChar))
        googleTrigger.setValue(GoogleTransliterate.triggerSuffix)
        hiraganaList.setShortcuts(bindings.hiragana)
        katakanaList.setShortcuts(bindings.katakana)
        googleList.setShortcuts(bindings.googleTransliterate)
        deleteList.setShortcuts(bindings.deleteCandidate)
    }

    private static func makeSingleKeyField(_ char: UInt8, assign: @escaping (UInt8) -> Void) -> SingleKeyField {
        let field = SingleKeyField(value: display(char), placeholder: "なし")
        field.validate = validateSingleKey
        field.onChange = { text in
            assign(text.first?.asciiValue ?? 0)
            KeyBindings.shared.save()
        }
        return field
    }

    private static func makeShortcutList(_ shortcuts: [KeyShortcut], minimumCount: Int = 0,
                                         assign: @escaping ([KeyShortcut]) -> Void) -> ShortcutListView {
        let list = ShortcutListView(shortcuts: shortcuts, minimumCount: minimumCount)
        list.onChange = { shortcuts in
            assign(shortcuts)
            KeyBindings.shared.save()
        }
        return list
    }

    static func display(_ char: UInt8) -> String {
        char == 0 ? "" : String(UnicodeScalar(char))
    }

    /// One printable ASCII character, or empty to disable.
    static func validateSingleKey(_ text: String) -> String? {
        if text.isEmpty { return "" }
        guard text.count == 1, let ascii = text.first?.asciiValue, ascii > 0x20, ascii < 0x7F else { return nil }
        return text
    }

    /// One ASCII symbol; letters and digits would collide with romaji input.
    static func validateTrigger(_ text: String) -> String? {
        guard text.count == 1, let ascii = text.first?.asciiValue, ascii > 0x20, ascii < 0x7F,
              !(ascii >= 0x30 && ascii <= 0x39),
              !(ascii >= 0x41 && ascii <= 0x5A),
              !(ascii >= 0x61 && ascii <= 0x7A) else { return nil }
        return text
    }
}

// MARK: - Candidate window

final class CandidateSection: PreferencesSection {
    private let displayMode: ClosureSegmentedControl
    private let clipboard: ClosureButton
    private let selectedText: ClosureButton

    init() {
        displayMode = ClosureSegmentedControl.make(labels: ["リスト表示", "クラシック表示"],
                                                   selected: CandidateDisplayMode.current.rawValue) { segment in
            CandidateDisplayMode.setCurrent(CandidateDisplayMode(rawValue: segment) ?? .classic)
        }
        clipboard = ClosureButton.checkbox("クリップボードの内容を候補に表示する",
                                           isOn: GyaimController.isClipboardCandidateEnabled) {
            GyaimController.setClipboardCandidateEnabled($0)
        }
        selectedText = ClosureButton.checkbox("選択テキストを候補に表示する",
                                              isOn: GyaimController.isSelectedTextCandidateEnabled) {
            GyaimController.setSelectedTextCandidateEnabled($0)
        }
        super.init(title: "候補")
        addLabeledRow("表示スタイル:", displayMode)
        addRow(clipboard)
        addRow(selectedText)
    }

    override func reload() {
        displayMode.selectedSegment = CandidateDisplayMode.current.rawValue
        clipboard.state = GyaimController.isClipboardCandidateEnabled ? .on : .off
        selectedText.state = GyaimController.isSelectedTextCandidateEnabled ? .on : .off
    }
}

// MARK: - Study dictionary

final class StudySection: PreferencesSection {
    private let eviction: ClosureSegmentedControl
    private let studyHiragana: ClosureButton
    private let exactReading: ClosureButton

    init() {
        eviction = ClosureSegmentedControl.make(labels: ["MRU", "淘汰なし", "スコアベース"],
                                                selected: EvictionMode.current.rawValue) { segment in
            EvictionMode.setCurrent(EvictionMode(rawValue: segment) ?? .mru)
        }
        studyHiragana = ClosureButton.checkbox("平仮名の確定を学習する", isOn: WordSearch.isStudyHiraganaEnabled) {
            WordSearch.setStudyHiraganaEnabled($0)
        }
        exactReading = ClosureButton.checkbox("完全一致の読みを優先する", isOn: WordSearch.isExactReadingMatchPriority) {
            WordSearch.setExactReadingMatchPriority($0)
        }
        super.init(title: "学習辞書")
        addLabeledRow("淘汰方式:", eviction)
        addHint("MRU: 最近使った順に上限 10,000 件。淘汰なし: 上限なしで全件保持。スコアベース: 使用頻度と時間で評価",
                indent: false)
        addRow(studyHiragana)
        addRow(exactReading)
        addHint("入力と読みが完全に一致する候補を、前方一致の候補より上に表示します")
        addControlsRow([
            ClosureButton.push("疑わしい学習エントリを確認...") { StudySuspectsWindow.show() },
            ClosureButton.push("ユーザー辞書を編集...") { DictEditorWindow.show() },
        ])
        addHint("typo の確定や長期未使用の学習語を一覧し、選んで削除できます", indent: false)
    }

    override func reload() {
        eviction.selectedSegment = EvictionMode.current.rawValue
        studyHiragana.state = WordSearch.isStudyHiraganaEnabled ? .on : .off
        exactReading.state = WordSearch.isExactReadingMatchPriority ? .on : .off
    }
}
