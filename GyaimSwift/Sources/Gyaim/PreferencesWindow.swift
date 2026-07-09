// swiftlint:disable file_length type_body_length
import Cocoa

/// Preferences window for Gyaim keybinding configuration.
class PreferencesWindow: NSWindow {
    static var shared: PreferencesWindow?

    private var hiraganaRecorders: [ShortcutRecorderRow] = []
    private var katakanaRecorders: [ShortcutRecorderRow] = []
    private let contentBox = NSView()
    private var logSizeLabel: NSTextField?
    private var logToggle: NSButton?
    private var clipboardToggle: NSButton?
    private var selectedTextToggle: NSButton?
    private var displayModeControl: NSSegmentedControl?
    private var googleTriggerField: NSTextField?
    private var googleTransliterateRecorders: [ShortcutRecorderRow] = []
    private var deleteCandidateRecorders: [ShortcutRecorderRow] = []
    private var evictionModeControl: NSSegmentedControl?
    private var studyHiraganaToggle: NSButton?
    private var exactReadingMatchToggle: NSButton?
    private var fastContextRerankToggle: NSButton?
    private var fastContextRerankModelToggle: NSButton?
    private var fastContextRerankLoggingToggle: NSButton?
    private var bundledZenzToggle: NSButton?
    private var zenzGenerationToggle: NSButton?
    private var contextLearningToggle: NSButton?
    private var contextDictCountLabel: NSTextField?
    private var connectionDictURLField: NSTextField?
    private var connectionDictStatusLabel: NSTextField?
    private var connectionDictImportButton: NSButton?

    static func show() {
        if shared == nil {
            shared = PreferencesWindow()
        }
        shared?.level = .floating
        shared?.makeKeyAndOrderFront(nil)
        shared?.becomeKey()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        super.init(contentRect: frame,
                   styleMask: [.titled, .closable],
                   backing: .buffered,
                   defer: false)
        title = "Gyaim 設定"
        center()
        isReleasedWhenClosed = false

        contentBox.frame = frame
        contentView = contentBox

        buildUI()
        loadBindings()
    }

    override func close() {
        super.close()
        NSApp.setActivationPolicy(.prohibited)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control),
              !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        let hasShift = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
        switch (key, hasShift) {
        case ("w", _):
            close()
            return true
        case ("x", false):
            return sendStandardAction(#selector(NSText.cut(_:)), fallbackEvent: event)
        case ("c", false):
            return sendStandardAction(#selector(NSText.copy(_:)), fallbackEvent: event)
        case ("v", false):
            return sendStandardAction(#selector(NSText.paste(_:)), fallbackEvent: event)
        case ("a", false):
            return sendStandardAction(#selector(NSText.selectAll(_:)), fallbackEvent: event)
        case ("z", false):
            return sendStandardAction(Selector(("undo:")), fallbackEvent: event)
        case ("z", true):
            return sendStandardAction(Selector(("redo:")), fallbackEvent: event)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func sendStandardAction(_ action: Selector, fallbackEvent event: NSEvent) -> Bool {
        if let target = targetForStandardAction(action), target.tryToPerform(action, with: self) {
            return true
        }
        return NSApp.sendAction(action, to: nil, from: self) || super.performKeyEquivalent(with: event)
    }

    private func targetForStandardAction(_ action: Selector) -> NSResponder? {
        var responder = firstResponder
        while let current = responder {
            if current.responds(to: action) {
                return current
            }
            responder = current.nextResponder
        }
        return nil
    }

    private func buildUI() {
        var y = frame.height - 60

        // Title
        let titleLabel = makeLabel("キーボードショートカット", bold: true)
        titleLabel.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(titleLabel)
        y -= 10

        // Hiragana section
        y -= 30
        let hiraLabel = makeLabel("ひらがな確定:")
        hiraLabel.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        contentBox.addSubview(hiraLabel)

        for shortcut in KeyBindings.shared.hiragana {
            y -= 32
            let row = ShortcutRecorderRow(frame: NSRect(x: 30, y: y, width: 420, height: 28))
            row.setShortcut(shortcut)
            row.onRemove = { [weak self] r in self?.removeHiraganaRow(r) }
            contentBox.addSubview(row)
            hiraganaRecorders.append(row)
        }

        y -= 30
        let addHiraBtn = NSButton(title: "+ 追加", target: self, action: #selector(addHiraganaShortcut))
        addHiraBtn.frame = NSRect(x: 30, y: y, width: 80, height: 24)
        addHiraBtn.bezelStyle = .rounded
        addHiraBtn.tag = 1
        contentBox.addSubview(addHiraBtn)

        // Katakana section
        y -= 40
        let kataLabel = makeLabel("カタカナ確定:")
        kataLabel.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        contentBox.addSubview(kataLabel)

        for shortcut in KeyBindings.shared.katakana {
            y -= 32
            let row = ShortcutRecorderRow(frame: NSRect(x: 30, y: y, width: 420, height: 28))
            row.setShortcut(shortcut)
            row.onRemove = { [weak self] r in self?.removeKatakanaRow(r) }
            contentBox.addSubview(row)
            katakanaRecorders.append(row)
        }

        y -= 30
        let addKataBtn = NSButton(title: "+ 追加", target: self, action: #selector(addKatakanaShortcut))
        addKataBtn.frame = NSRect(x: 30, y: y, width: 80, height: 24)
        addKataBtn.bezelStyle = .rounded
        addKataBtn.tag = 2
        contentBox.addSubview(addKataBtn)

        // Candidate section
        y -= 40
        let candTitle = makeLabel("候補", bold: true)
        candTitle.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(candTitle)

        y -= 28
        let styleLabel = makeLabel("表示スタイル:")
        styleLabel.frame = NSRect(x: 20, y: y, width: 100, height: 20)
        contentBox.addSubview(styleLabel)

        let modeControl = NSSegmentedControl(labels: ["リスト表示", "クラシック表示"], trackingMode: .selectOne, target: self, action: #selector(changeDisplayMode(_:)))
        modeControl.frame = NSRect(x: 120, y: y - 2, width: 220, height: 24)
        modeControl.selectedSegment = CandidateDisplayMode.current.rawValue
        contentBox.addSubview(modeControl)
        displayModeControl = modeControl

        y -= 28
        let cbToggle = NSButton(checkboxWithTitle: "クリップボードの内容を候補に表示する", target: self, action: #selector(toggleClipboardCandidate(_:)))
        cbToggle.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        cbToggle.state = GyaimController.isClipboardCandidateEnabled ? .on : .off
        contentBox.addSubview(cbToggle)
        clipboardToggle = cbToggle

        y -= 24
        let stToggle = NSButton(checkboxWithTitle: "選択テキストを候補に表示する", target: self, action: #selector(toggleSelectedTextCandidate(_:)))
        stToggle.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        stToggle.state = GyaimController.isSelectedTextCandidateEnabled ? .on : .off
        contentBox.addSubview(stToggle)
        selectedTextToggle = stToggle

        // Study dict eviction section
        y -= 36
        let studyTitle = makeLabel("学習辞書", bold: true)
        studyTitle.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(studyTitle)

        y -= 28
        let evictLabel = makeLabel("淘汰方式:")
        evictLabel.frame = NSRect(x: 20, y: y, width: 80, height: 20)
        contentBox.addSubview(evictLabel)

        let evictControl = NSSegmentedControl(labels: ["MRU", "淘汰なし", "スコアベース"],
                                               trackingMode: .selectOne,
                                               target: self,
                                               action: #selector(changeEvictionMode(_:)))
        evictControl.frame = NSRect(x: 100, y: y - 2, width: 280, height: 24)
        evictControl.selectedSegment = EvictionMode.current.rawValue
        contentBox.addSubview(evictControl)
        evictionModeControl = evictControl

        y -= 28
        let evictHint = makeLabel("MRU: 最近使った順に保持  淘汰なし: 追加順のまま保持  スコアベース: 使用頻度と時間で評価")
        evictHint.font = NSFont.systemFont(ofSize: 11)
        evictHint.textColor = .secondaryLabelColor
        evictHint.frame = NSRect(x: 20, y: y, width: 440, height: 20)
        contentBox.addSubview(evictHint)

        y -= 24
        let shToggle = NSButton(checkboxWithTitle: "平仮名の確定を学習する",
                                 target: self, action: #selector(toggleStudyHiragana(_:)))
        shToggle.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        shToggle.state = WordSearch.isStudyHiraganaEnabled ? .on : .off
        contentBox.addSubview(shToggle)
        studyHiraganaToggle = shToggle

        y -= 24
        let erToggle = NSButton(checkboxWithTitle: "完全一致の読みを優先する",
                                 target: self, action: #selector(toggleExactReadingMatchPriority(_:)))
        erToggle.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        erToggle.state = WordSearch.isExactReadingMatchPriority ? .on : .off
        contentBox.addSubview(erToggle)
        exactReadingMatchToggle = erToggle

        let erHint = makeLabel("入力と読みが完全に一致する候補を、前方一致の候補より上に表示します")
        erHint.font = NSFont.systemFont(ofSize: 11)
        erHint.textColor = .secondaryLabelColor
        y -= 18
        erHint.frame = NSRect(x: 36, y: y, width: 420, height: 16)
        contentBox.addSubview(erHint)

        addFastContextRerankControls(y: &y)
        addAIModelControls(y: &y)

        // Google Transliterate section
        y -= 40
        let googleTitle = makeLabel("Google変換", bold: true)
        googleTitle.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(googleTitle)

        y -= 28
        let triggerLabel = makeLabel("トリガー文字:")
        triggerLabel.frame = NSRect(x: 20, y: y, width: 100, height: 20)
        contentBox.addSubview(triggerLabel)

        let triggerField = NSTextField()
        triggerField.frame = NSRect(x: 120, y: y - 2, width: 40, height: 24)
        triggerField.stringValue = GoogleTransliterate.triggerSuffix
        triggerField.alignment = .center
        triggerField.placeholderString = "`"
        contentBox.addSubview(triggerField)
        googleTriggerField = triggerField

        let triggerHint = makeLabel("入力末尾に付けてGoogle変換（例: meguro`）")
        triggerHint.font = NSFont.systemFont(ofSize: 11)
        triggerHint.textColor = .secondaryLabelColor
        triggerHint.frame = NSRect(x: 170, y: y, width: 300, height: 20)
        contentBox.addSubview(triggerHint)

        y -= 28
        let shortcutLabel = makeLabel("ショートカット:")
        shortcutLabel.frame = NSRect(x: 20, y: y, width: 120, height: 20)
        contentBox.addSubview(shortcutLabel)

        for shortcut in KeyBindings.shared.googleTransliterate {
            y -= 32
            let row = ShortcutRecorderRow(frame: NSRect(x: 30, y: y, width: 420, height: 28))
            row.setShortcut(shortcut)
            row.onRemove = { [weak self] r in self?.removeGoogleTransliterateRow(r) }
            contentBox.addSubview(row)
            googleTransliterateRecorders.append(row)
        }

        y -= 30
        let addGoogleBtn = NSButton(title: "+ 追加", target: self, action: #selector(addGoogleTransliterateShortcut))
        addGoogleBtn.frame = NSRect(x: 30, y: y, width: 80, height: 24)
        addGoogleBtn.bezelStyle = .rounded
        contentBox.addSubview(addGoogleBtn)

        // Delete candidate section
        y -= 40
        let deleteTitle = makeLabel("候補削除（Shift+X）", bold: true)
        deleteTitle.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(deleteTitle)

        y -= 28
        let deleteShortcutLabel = makeLabel("ショートカット:")
        deleteShortcutLabel.frame = NSRect(x: 20, y: y, width: 120, height: 20)
        contentBox.addSubview(deleteShortcutLabel)

        for shortcut in KeyBindings.shared.deleteCandidate {
            y -= 32
            let row = ShortcutRecorderRow(frame: NSRect(x: 30, y: y, width: 420, height: 28))
            row.setShortcut(shortcut)
            row.onRemove = { [weak self] r in self?.removeDeleteCandidateRow(r) }
            contentBox.addSubview(row)
            deleteCandidateRecorders.append(row)
        }

        y -= 30
        let addDeleteBtn = NSButton(title: "+ 追加", target: self, action: #selector(addDeleteCandidateShortcut))
        addDeleteBtn.frame = NSRect(x: 30, y: y, width: 80, height: 24)
        addDeleteBtn.bezelStyle = .rounded
        contentBox.addSubview(addDeleteBtn)

        let deleteHint = makeLabel("候補表示中にShift+Xまたは上記ショートカットで学習/ユーザー辞書の候補を削除")
        deleteHint.font = NSFont.systemFont(ofSize: 11)
        deleteHint.textColor = .secondaryLabelColor
        y -= 20
        deleteHint.frame = NSRect(x: 20, y: y, width: 440, height: 20)
        contentBox.addSubview(deleteHint)

        addConnectionDictionarySection(y: &y)

        // Log section
        y -= 40
        let logTitle = makeLabel("ログ", bold: true)
        logTitle.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(logTitle)

        y -= 28
        let toggle = NSButton(checkboxWithTitle: "ロギングを有効にする", target: self, action: #selector(toggleLogging(_:)))
        toggle.frame = NSRect(x: 20, y: y, width: 250, height: 20)
        toggle.state = Log.isEnabled ? .on : .off
        contentBox.addSubview(toggle)
        logToggle = toggle

        y -= 24
        let sizeLabel = makeLabel(logSizeString())
        sizeLabel.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        contentBox.addSubview(sizeLabel)
        logSizeLabel = sizeLabel

        let clearBtn = NSButton(title: "ログを削除", target: self, action: #selector(clearLogs))
        clearBtn.frame = NSRect(x: 230, y: y - 2, width: 100, height: 24)
        clearBtn.bezelStyle = .rounded
        contentBox.addSubview(clearBtn)

        let finderBtn = NSButton(title: "Finderで表示", target: self, action: #selector(showInFinder))
        finderBtn.frame = NSRect(x: 340, y: y - 2, width: 120, height: 24)
        finderBtn.bezelStyle = .rounded
        contentBox.addSubview(finderBtn)

        // Bottom buttons
        let bottomMargin: CGFloat = 56 // 12 + 32 (button) + 12 padding
        resizeToFitContent(lastY: y, bottomMargin: bottomMargin)

        let saveBtn = NSButton(title: "保存", target: self, action: #selector(saveAndClose))
        saveBtn.frame = NSRect(x: 380, y: 12, width: 80, height: 32)
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        contentBox.addSubview(saveBtn)

        let resetBtn = NSButton(title: "初期値に戻す", target: self, action: #selector(resetDefaults))
        resetBtn.frame = NSRect(x: 20, y: 12, width: 120, height: 32)
        resetBtn.bezelStyle = .rounded
        contentBox.addSubview(resetBtn)
    }

    private func addFastContextRerankControls(y: inout CGFloat) {
        y -= 28
        let frToggle = NSButton(checkboxWithTitle: "通常入力で軽量rerankを使う",
                                target: self,
                                action: #selector(toggleFastContextRerank(_:)))
        frToggle.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        frToggle.state = GyaimController.isFastContextRerankEnabled ? .on : .off
        contentBox.addSubview(frToggle)
        fastContextRerankToggle = frToggle

        y -= 20
        let frHint = makeLabel("読み完全一致を優先しつつ、直前文脈で予測候補を並び替えます")
        frHint.font = NSFont.systemFont(ofSize: 11)
        frHint.textColor = .secondaryLabelColor
        frHint.frame = NSRect(x: 36, y: y, width: 420, height: 16)
        contentBox.addSubview(frHint)

        y -= 24
        let modelToggle = NSButton(checkboxWithTitle: "軽量rerankでモデルbackendを使う（実験的）",
                                   target: self,
                                   action: #selector(toggleFastContextRerankModel(_:)))
        modelToggle.frame = NSRect(x: 36, y: y, width: 360, height: 20)
        modelToggle.state = GyaimController.isFastContextRerankModelEnabled ? .on : .off
        contentBox.addSubview(modelToggle)
        fastContextRerankModelToggle = modelToggle

        y -= 24
        let logToggle = NSButton(checkboxWithTitle: "軽量rerankのレイテンシをログに出す",
                                 target: self,
                                 action: #selector(toggleFastContextRerankLogging(_:)))
        logToggle.frame = NSRect(x: 36, y: y, width: 320, height: 20)
        logToggle.state = GyaimController.isFastContextRerankLoggingEnabled ? .on : .off
        contentBox.addSubview(logToggle)
        fastContextRerankLoggingToggle = logToggle
    }

    private func addAIModelControls(y: inout CGFloat) {
        y -= 40
        let title = makeLabel("AI・文脈学習", bold: true)
        title.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(title)

        y -= 28
        let zenzToggle = NSButton(checkboxWithTitle: "AIモデル（同梱Zenz）で候補を評価する",
                                  target: self,
                                  action: #selector(toggleBundledZenz(_:)))
        zenzToggle.frame = NSRect(x: 20, y: y, width: 340, height: 20)
        zenzToggle.state = GyaimController.isBundledZenzEnabled ? .on : .off
        contentBox.addSubview(zenzToggle)
        bundledZenzToggle = zenzToggle

        y -= 20
        let zenzHint = makeLabel("OFFにするとTab・同音異義語選択がヒューリスティックのみになります")
        zenzHint.font = NSFont.systemFont(ofSize: 11)
        zenzHint.textColor = .secondaryLabelColor
        zenzHint.frame = NSRect(x: 36, y: y, width: 420, height: 16)
        contentBox.addSubview(zenzHint)

        y -= 24
        let generationToggle = NSButton(checkboxWithTitle: "Tabで辞書から追加候補を選ぶ（辞書制約付き生成）",
                                        target: self,
                                        action: #selector(toggleZenzGeneration(_:)))
        generationToggle.frame = NSRect(x: 20, y: y, width: 400, height: 20)
        generationToggle.state = GyaimController.isZenzGenerationEnabled ? .on : .off
        contentBox.addSubview(generationToggle)
        zenzGenerationToggle = generationToggle

        y -= 24
        let learningToggle = NSButton(checkboxWithTitle: "文脈学習を使う（確定した文脈で同音異義語を選ぶ）",
                                      target: self,
                                      action: #selector(toggleContextLearning(_:)))
        learningToggle.frame = NSRect(x: 20, y: y, width: 400, height: 20)
        learningToggle.state = ContextDict.isEnabled ? .on : .off
        contentBox.addSubview(learningToggle)
        contextLearningToggle = learningToggle

        y -= 24
        let countLabel = makeLabel(contextDictCountString())
        countLabel.frame = NSRect(x: 36, y: y, width: 220, height: 20)
        contentBox.addSubview(countLabel)
        contextDictCountLabel = countLabel

        let clearButton = NSButton(title: "文脈学習をクリア", target: self, action: #selector(clearContextDict))
        clearButton.frame = NSRect(x: 260, y: y - 2, width: 140, height: 24)
        clearButton.bezelStyle = .rounded
        contentBox.addSubview(clearButton)
    }

    private func contextDictCountString() -> String {
        "学習済みの文脈: \(ContextDict.shared.entryCount())件"
    }

    private func loadBindings() {
        for (i, row) in hiraganaRecorders.enumerated() {
            if i < KeyBindings.shared.hiragana.count {
                row.setShortcut(KeyBindings.shared.hiragana[i])
            }
        }
        for (i, row) in katakanaRecorders.enumerated() {
            if i < KeyBindings.shared.katakana.count {
                row.setShortcut(KeyBindings.shared.katakana[i])
            }
        }
    }

    @objc private func addHiraganaShortcut() {
        let row = ShortcutRecorderRow(frame: .zero)
        row.onRemove = { [weak self] r in self?.removeHiraganaRow(r) }
        hiraganaRecorders.append(row)
        contentBox.addSubview(row)
        rebuildLayout()
    }

    @objc private func addKatakanaShortcut() {
        let row = ShortcutRecorderRow(frame: .zero)
        row.onRemove = { [weak self] r in self?.removeKatakanaRow(r) }
        katakanaRecorders.append(row)
        contentBox.addSubview(row)
        rebuildLayout()
    }

    private func removeHiraganaRow(_ row: ShortcutRecorderRow) {
        guard hiraganaRecorders.count > 1 else { return }
        row.removeFromSuperview()
        hiraganaRecorders.removeAll { $0 === row }
        rebuildLayout()
    }

    private func removeKatakanaRow(_ row: ShortcutRecorderRow) {
        guard katakanaRecorders.count > 1 else { return }
        row.removeFromSuperview()
        katakanaRecorders.removeAll { $0 === row }
        rebuildLayout()
    }

    private func rebuildLayout() {
        // Remove all subviews and rebuild
        contentBox.subviews.forEach { $0.removeFromSuperview() }
        hiraganaRecorders.forEach { $0.removeFromSuperview() }
        katakanaRecorders.forEach { $0.removeFromSuperview() }
        googleTransliterateRecorders.forEach { $0.removeFromSuperview() }
        deleteCandidateRecorders.forEach { $0.removeFromSuperview() }

        var y = frame.height - 60

        let titleLabel = makeLabel("キーボードショートカット", bold: true)
        titleLabel.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(titleLabel)

        y -= 40
        let hiraLabel = makeLabel("ひらがな確定:")
        hiraLabel.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        contentBox.addSubview(hiraLabel)

        for row in hiraganaRecorders {
            y -= 32
            row.frame = NSRect(x: 30, y: y, width: 420, height: 28)
            contentBox.addSubview(row)
        }

        y -= 30
        let addHiraBtn = NSButton(title: "+ 追加", target: self, action: #selector(addHiraganaShortcut))
        addHiraBtn.frame = NSRect(x: 30, y: y, width: 80, height: 24)
        addHiraBtn.bezelStyle = .rounded
        contentBox.addSubview(addHiraBtn)

        y -= 40
        let kataLabel = makeLabel("カタカナ確定:")
        kataLabel.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        contentBox.addSubview(kataLabel)

        for row in katakanaRecorders {
            y -= 32
            row.frame = NSRect(x: 30, y: y, width: 420, height: 28)
            contentBox.addSubview(row)
        }

        y -= 30
        let addKataBtn = NSButton(title: "+ 追加", target: self, action: #selector(addKatakanaShortcut))
        addKataBtn.frame = NSRect(x: 30, y: y, width: 80, height: 24)
        addKataBtn.bezelStyle = .rounded
        contentBox.addSubview(addKataBtn)

        // Candidate section in rebuildLayout
        y -= 40
        let candTitle = makeLabel("候補", bold: true)
        candTitle.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(candTitle)

        y -= 28
        let styleLabel = makeLabel("表示スタイル:")
        styleLabel.frame = NSRect(x: 20, y: y, width: 100, height: 20)
        contentBox.addSubview(styleLabel)

        let modeControl = NSSegmentedControl(labels: ["リスト表示", "クラシック表示"], trackingMode: .selectOne, target: self, action: #selector(changeDisplayMode(_:)))
        modeControl.frame = NSRect(x: 120, y: y - 2, width: 220, height: 24)
        modeControl.selectedSegment = CandidateDisplayMode.current.rawValue
        contentBox.addSubview(modeControl)
        displayModeControl = modeControl

        y -= 28
        let cbToggle = NSButton(checkboxWithTitle: "クリップボードの内容を候補に表示する", target: self, action: #selector(toggleClipboardCandidate(_:)))
        cbToggle.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        cbToggle.state = GyaimController.isClipboardCandidateEnabled ? .on : .off
        contentBox.addSubview(cbToggle)
        clipboardToggle = cbToggle

        y -= 24
        let stToggle = NSButton(checkboxWithTitle: "選択テキストを候補に表示する", target: self, action: #selector(toggleSelectedTextCandidate(_:)))
        stToggle.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        stToggle.state = GyaimController.isSelectedTextCandidateEnabled ? .on : .off
        contentBox.addSubview(stToggle)
        selectedTextToggle = stToggle

        // Study dict eviction section in rebuildLayout
        y -= 36
        let studyTitle = makeLabel("学習辞書", bold: true)
        studyTitle.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(studyTitle)

        y -= 28
        let evictLabel = makeLabel("淘汰方式:")
        evictLabel.frame = NSRect(x: 20, y: y, width: 80, height: 20)
        contentBox.addSubview(evictLabel)

        let evictControl = NSSegmentedControl(labels: ["MRU", "淘汰なし", "スコアベース"],
                                               trackingMode: .selectOne,
                                               target: self,
                                               action: #selector(changeEvictionMode(_:)))
        evictControl.frame = NSRect(x: 100, y: y - 2, width: 280, height: 24)
        evictControl.selectedSegment = EvictionMode.current.rawValue
        contentBox.addSubview(evictControl)
        evictionModeControl = evictControl

        y -= 28
        let evictHint = makeLabel("MRU: 最近使った順に保持  淘汰なし: 追加順のまま保持  スコアベース: 使用頻度と時間で評価")
        evictHint.font = NSFont.systemFont(ofSize: 11)
        evictHint.textColor = .secondaryLabelColor
        evictHint.frame = NSRect(x: 20, y: y, width: 440, height: 20)
        contentBox.addSubview(evictHint)

        y -= 24
        let shToggle = NSButton(checkboxWithTitle: "平仮名の確定を学習する",
                                 target: self, action: #selector(toggleStudyHiragana(_:)))
        shToggle.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        shToggle.state = WordSearch.isStudyHiraganaEnabled ? .on : .off
        contentBox.addSubview(shToggle)
        studyHiraganaToggle = shToggle

        y -= 24
        let erToggle = NSButton(checkboxWithTitle: "完全一致の読みを優先する",
                                 target: self, action: #selector(toggleExactReadingMatchPriority(_:)))
        erToggle.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        erToggle.state = WordSearch.isExactReadingMatchPriority ? .on : .off
        contentBox.addSubview(erToggle)
        exactReadingMatchToggle = erToggle

        let erHint = makeLabel("入力と読みが完全に一致する候補を、前方一致の候補より上に表示します")
        erHint.font = NSFont.systemFont(ofSize: 11)
        erHint.textColor = .secondaryLabelColor
        y -= 18
        erHint.frame = NSRect(x: 36, y: y, width: 420, height: 16)
        contentBox.addSubview(erHint)

        addFastContextRerankControls(y: &y)
        addAIModelControls(y: &y)

        // Google Transliterate section in rebuildLayout
        y -= 40
        let googleTitle = makeLabel("Google変換", bold: true)
        googleTitle.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(googleTitle)

        y -= 28
        let triggerLabel = makeLabel("トリガー文字:")
        triggerLabel.frame = NSRect(x: 20, y: y, width: 100, height: 20)
        contentBox.addSubview(triggerLabel)

        let triggerField = NSTextField()
        triggerField.frame = NSRect(x: 120, y: y - 2, width: 40, height: 24)
        triggerField.stringValue = GoogleTransliterate.triggerSuffix
        triggerField.alignment = .center
        triggerField.placeholderString = "`"
        contentBox.addSubview(triggerField)
        googleTriggerField = triggerField

        let triggerHint = makeLabel("入力末尾に付けてGoogle変換（例: meguro`）")
        triggerHint.font = NSFont.systemFont(ofSize: 11)
        triggerHint.textColor = .secondaryLabelColor
        triggerHint.frame = NSRect(x: 170, y: y, width: 300, height: 20)
        contentBox.addSubview(triggerHint)

        y -= 28
        let shortcutLabel = makeLabel("ショートカット:")
        shortcutLabel.frame = NSRect(x: 20, y: y, width: 120, height: 20)
        contentBox.addSubview(shortcutLabel)

        for row in googleTransliterateRecorders {
            y -= 32
            row.frame = NSRect(x: 30, y: y, width: 420, height: 28)
            contentBox.addSubview(row)
        }

        y -= 30
        let addGoogleBtn = NSButton(title: "+ 追加", target: self, action: #selector(addGoogleTransliterateShortcut))
        addGoogleBtn.frame = NSRect(x: 30, y: y, width: 80, height: 24)
        addGoogleBtn.bezelStyle = .rounded
        contentBox.addSubview(addGoogleBtn)

        // Delete candidate section in rebuildLayout
        y -= 40
        let deleteTitle = makeLabel("候補削除（Shift+X）", bold: true)
        deleteTitle.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(deleteTitle)

        y -= 28
        let deleteShortcutLabel = makeLabel("ショートカット:")
        deleteShortcutLabel.frame = NSRect(x: 20, y: y, width: 120, height: 20)
        contentBox.addSubview(deleteShortcutLabel)

        for row in deleteCandidateRecorders {
            y -= 32
            row.frame = NSRect(x: 30, y: y, width: 420, height: 28)
            contentBox.addSubview(row)
        }

        y -= 30
        let addDeleteBtn = NSButton(title: "+ 追加", target: self, action: #selector(addDeleteCandidateShortcut))
        addDeleteBtn.frame = NSRect(x: 30, y: y, width: 80, height: 24)
        addDeleteBtn.bezelStyle = .rounded
        contentBox.addSubview(addDeleteBtn)

        let deleteHint = makeLabel("候補表示中にShift+Xまたは上記ショートカットで学習/ユーザー辞書の候補を削除")
        deleteHint.font = NSFont.systemFont(ofSize: 11)
        deleteHint.textColor = .secondaryLabelColor
        y -= 20
        deleteHint.frame = NSRect(x: 20, y: y, width: 440, height: 20)
        contentBox.addSubview(deleteHint)

        addConnectionDictionarySection(y: &y)

        // Log section in rebuildLayout
        y -= 40
        let logTitle = makeLabel("ログ", bold: true)
        logTitle.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(logTitle)

        y -= 28
        let toggle = NSButton(checkboxWithTitle: "ロギングを有効にする", target: self, action: #selector(toggleLogging(_:)))
        toggle.frame = NSRect(x: 20, y: y, width: 250, height: 20)
        toggle.state = Log.isEnabled ? .on : .off
        contentBox.addSubview(toggle)
        logToggle = toggle

        y -= 24
        let sizeLabel = makeLabel(logSizeString())
        sizeLabel.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        contentBox.addSubview(sizeLabel)
        logSizeLabel = sizeLabel

        let clearBtn = NSButton(title: "ログを削除", target: self, action: #selector(clearLogs))
        clearBtn.frame = NSRect(x: 230, y: y - 2, width: 100, height: 24)
        clearBtn.bezelStyle = .rounded
        contentBox.addSubview(clearBtn)

        let finderBtn = NSButton(title: "Finderで表示", target: self, action: #selector(showInFinder))
        finderBtn.frame = NSRect(x: 340, y: y - 2, width: 120, height: 24)
        finderBtn.bezelStyle = .rounded
        contentBox.addSubview(finderBtn)

        let bottomMargin: CGFloat = 56
        resizeToFitContent(lastY: y, bottomMargin: bottomMargin)

        let saveBtn = NSButton(title: "保存", target: self, action: #selector(saveAndClose))
        saveBtn.frame = NSRect(x: 380, y: 12, width: 80, height: 32)
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        contentBox.addSubview(saveBtn)

        let resetBtn = NSButton(title: "初期値に戻す", target: self, action: #selector(resetDefaults))
        resetBtn.frame = NSRect(x: 20, y: 12, width: 120, height: 32)
        resetBtn.bezelStyle = .rounded
        contentBox.addSubview(resetBtn)
    }

    @objc private func addGoogleTransliterateShortcut() {
        let row = ShortcutRecorderRow(frame: .zero)
        row.onRemove = { [weak self] r in self?.removeGoogleTransliterateRow(r) }
        googleTransliterateRecorders.append(row)
        contentBox.addSubview(row)
        rebuildLayout()
    }

    private func removeGoogleTransliterateRow(_ row: ShortcutRecorderRow) {
        row.removeFromSuperview()
        googleTransliterateRecorders.removeAll { $0 === row }
        rebuildLayout()
    }

    @objc private func addDeleteCandidateShortcut() {
        let row = ShortcutRecorderRow(frame: .zero)
        row.onRemove = { [weak self] r in self?.removeDeleteCandidateRow(r) }
        deleteCandidateRecorders.append(row)
        contentBox.addSubview(row)
        rebuildLayout()
    }

    private func removeDeleteCandidateRow(_ row: ShortcutRecorderRow) {
        row.removeFromSuperview()
        deleteCandidateRecorders.removeAll { $0 === row }
        rebuildLayout()
    }

    @objc private func saveAndClose() {
        KeyBindings.shared.hiragana = hiraganaRecorders.compactMap { $0.shortcut }
        KeyBindings.shared.katakana = katakanaRecorders.compactMap { $0.shortcut }
        KeyBindings.shared.googleTransliterate = googleTransliterateRecorders.compactMap { $0.shortcut }
        KeyBindings.shared.deleteCandidate = deleteCandidateRecorders.compactMap { $0.shortcut }
        KeyBindings.shared.save()

        // Save Google Transliterate trigger suffix (single non-alphanumeric ASCII only)
        if let field = googleTriggerField {
            let trigger = field.stringValue.trimmingCharacters(in: .whitespaces)
            if trigger.count == 1,
               let ascii = trigger.first?.asciiValue,
               !(ascii >= 0x30 && ascii <= 0x39),   // not digit
               !(ascii >= 0x41 && ascii <= 0x5A),   // not uppercase
               !(ascii >= 0x61 && ascii <= 0x7A) {   // not lowercase
                GoogleTransliterate.setTriggerSuffix(trigger)
            }
        }

        close()
    }

    @objc private func resetDefaults() {
        KeyBindings.shared.reset()
        hiraganaRecorders.forEach { $0.removeFromSuperview() }
        katakanaRecorders.forEach { $0.removeFromSuperview() }
        googleTransliterateRecorders.forEach { $0.removeFromSuperview() }
        deleteCandidateRecorders.forEach { $0.removeFromSuperview() }
        hiraganaRecorders = []
        katakanaRecorders = []
        googleTransliterateRecorders = []
        deleteCandidateRecorders = []

        for shortcut in KeyBindings.shared.hiragana {
            let row = ShortcutRecorderRow(frame: .zero)
            row.setShortcut(shortcut)
            row.onRemove = { [weak self] r in self?.removeHiraganaRow(r) }
            hiraganaRecorders.append(row)
        }
        for shortcut in KeyBindings.shared.katakana {
            let row = ShortcutRecorderRow(frame: .zero)
            row.setShortcut(shortcut)
            row.onRemove = { [weak self] r in self?.removeKatakanaRow(r) }
            katakanaRecorders.append(row)
        }

        // Reset trigger suffix and fast context rerank settings to defaults
        GyaimSettings.removeObject(forKey: "googleTransliterateTrigger")
        GyaimSettings.removeObject(forKey: "aiRerankFastContextEnabled")
        GyaimSettings.removeObject(forKey: "aiRerankUseModelForFastContext")
        GyaimSettings.removeObject(forKey: "aiRerankFastContextLoggingEnabled")
        googleTriggerField?.stringValue = GoogleTransliterate.triggerSuffix

        rebuildLayout()
    }

    @objc private func changeDisplayMode(_ sender: NSSegmentedControl) {
        let mode = CandidateDisplayMode(rawValue: sender.selectedSegment) ?? .list
        CandidateDisplayMode.setCurrent(mode)
        CandidateWindow.shared?.applyDisplayMode()
    }

    @objc private func changeEvictionMode(_ sender: NSSegmentedControl) {
        let mode = EvictionMode(rawValue: sender.selectedSegment) ?? .mru
        EvictionMode.setCurrent(mode)
    }

    @objc private func toggleStudyHiragana(_ sender: NSButton) {
        WordSearch.setStudyHiraganaEnabled(sender.state == .on)
    }

    @objc private func toggleExactReadingMatchPriority(_ sender: NSButton) {
        WordSearch.setExactReadingMatchPriority(sender.state == .on)
    }

    @objc private func toggleFastContextRerank(_ sender: NSButton) {
        GyaimController.setFastContextRerankEnabled(sender.state == .on)
    }

    @objc private func toggleFastContextRerankModel(_ sender: NSButton) {
        GyaimController.setFastContextRerankModelEnabled(sender.state == .on)
    }

    @objc private func toggleFastContextRerankLogging(_ sender: NSButton) {
        GyaimController.setFastContextRerankLoggingEnabled(sender.state == .on)
    }

    @objc private func toggleBundledZenz(_ sender: NSButton) {
        GyaimController.setBundledZenzEnabled(sender.state == .on)
    }

    @objc private func toggleZenzGeneration(_ sender: NSButton) {
        GyaimController.setZenzGenerationEnabled(sender.state == .on)
    }

    @objc private func toggleContextLearning(_ sender: NSButton) {
        ContextDict.setEnabled(sender.state == .on)
    }

    @objc private func clearContextDict() {
        ContextDict.shared.clear()
        contextDictCountLabel?.stringValue = contextDictCountString()
    }

    @objc private func toggleClipboardCandidate(_ sender: NSButton) {
        GyaimController.setClipboardCandidateEnabled(sender.state == .on)
    }

    @objc private func toggleSelectedTextCandidate(_ sender: NSButton) {
        GyaimController.setSelectedTextCandidateEnabled(sender.state == .on)
    }

    @objc private func toggleLogging(_ sender: NSButton) {
        let enabled = sender.state == .on
        Log.setEnabled(enabled)
        logSizeLabel?.stringValue = logSizeString()
    }

    @objc private func clearLogs() {
        FileLogger.shared.clearLog()
        // Small delay to let the async queue finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.logSizeLabel?.stringValue = self?.logSizeString() ?? "0 B"
        }
    }

    @objc private func showInFinder() {
        let logPath = "\(Config.gyaimDir)/gyaim.log"
        let fm = FileManager.default
        if fm.fileExists(atPath: logPath) {
            NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Config.gyaimDir)
        }
    }

    private func logSizeString() -> String {
        let size = FileLogger.shared.logFileSize()
        if size == 0 { return "gyaim.log: 0 B" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "gyaim.log: \(formatter.string(fromByteCount: size))"
    }

    /// Resize window so that all content fits. `lastY` is the Y coordinate of
    /// the lowest content element (before bottom buttons). `bottomMargin` is the
    /// space reserved for the save/reset buttons at the bottom.
    private func resizeToFitContent(lastY: CGFloat, bottomMargin: CGFloat) {
        // Content is laid out top-down from frame.height - 50.
        // The required height = (frame.height - lastY) + bottomMargin + topPadding
        let topPadding: CGFloat = 60
        let contentHeight = (frame.height - lastY) + bottomMargin + topPadding
        let requiredHeight = max(contentHeight, 300) // minimum height

        // Calculate the offset to shift all existing subviews down
        let delta = requiredHeight - frame.height
        if abs(delta) > 1 {
            // Move all existing subviews by delta (they were placed relative to old frame.height)
            for subview in contentBox.subviews {
                subview.frame.origin.y += delta
            }
            // Resize the window, keeping the top-left corner stable
            let oldFrame = self.frame
            let newFrame = NSRect(
                x: oldFrame.origin.x,
                y: oldFrame.origin.y - delta,
                width: oldFrame.width,
                height: requiredHeight
            )
            setFrame(newFrame, display: true)
            contentBox.frame = NSRect(x: 0, y: 0, width: newFrame.width, height: newFrame.height)
        }
    }

    private func makeLabel(_ text: String, bold: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        if bold {
            label.font = NSFont.boldSystemFont(ofSize: 14)
        }
        return label
    }
}

private extension PreferencesWindow {
    private func addConnectionDictionarySection(y: inout CGFloat) {
        y -= 40
        let title = makeLabel("接続辞書", bold: true)
        title.frame = NSRect(x: 20, y: y, width: 440, height: 24)
        contentBox.addSubview(title)

        y -= 28
        let urlLabel = makeLabel("URL:")
        urlLabel.frame = NSRect(x: 20, y: y, width: 40, height: 20)
        contentBox.addSubview(urlLabel)

        let urlField = NSTextField(frame: NSRect(x: 60, y: y - 2, width: 300, height: 24))
        urlField.placeholderString = GictionaryConnectionImporter.recommendedDict2URLString
        urlField.stringValue = GictionaryConnectionImporter.sourceURLString
        contentBox.addSubview(urlField)
        connectionDictURLField = urlField

        let importBtn = NSButton(title: "インポート", target: self, action: #selector(importConnectionDictionary))
        importBtn.frame = NSRect(x: 370, y: y - 2, width: 90, height: 24)
        importBtn.bezelStyle = .rounded
        contentBox.addSubview(importBtn)
        connectionDictImportButton = importBtn

        y -= 24
        let hint = makeLabel("推奨: masui/Gictionary のリポジトリURLまたは raw の dict2.txt URL。成功後すぐ反映します")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: y, width: 440, height: 18)
        contentBox.addSubview(hint)

        y -= 22
        let statusLabel = makeLabel(connectionDictionaryStatusText())
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: y, width: 340, height: 18)
        contentBox.addSubview(statusLabel)
        connectionDictStatusLabel = statusLabel

        let restoreBtn = NSButton(title: "内蔵辞書に戻す", target: self, action: #selector(restoreBundledConnectionDictionary))
        restoreBtn.frame = NSRect(x: 340, y: y - 2, width: 120, height: 24)
        restoreBtn.bezelStyle = .rounded
        contentBox.addSubview(restoreBtn)
    }

    @objc private func importConnectionDictionary() {
        let rawInput = connectionDictURLField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = rawInput.isEmpty ? GictionaryConnectionImporter.recommendedDict2URLString : rawInput
        guard let url = URL(string: raw), let scheme = url.scheme, ["http", "https", "file"].contains(scheme) else {
            connectionDictStatusLabel?.stringValue = "URLが正しくありません"
            return
        }

        connectionDictImportButton?.isEnabled = false
        connectionDictStatusLabel?.stringValue = "インポート中..."
        GictionaryConnectionImporter.importFromURL(url) { [weak self] result in
            DispatchQueue.main.async {
                self?.connectionDictImportButton?.isEnabled = true
                switch result {
                case .success(let importResult):
                    GyaimController.reloadConnectionDictionary()
                    self?.connectionDictStatusLabel?.stringValue = "インポート済み: \(importResult.entryCount)件"
                case .failure(let error):
                    self?.connectionDictStatusLabel?.stringValue = "失敗: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func restoreBundledConnectionDictionary() {
        do {
            try GictionaryConnectionImporter.removeImportedDictionary()
            GyaimController.reloadConnectionDictionary()
            connectionDictURLField?.stringValue = ""
            connectionDictStatusLabel?.stringValue = connectionDictionaryStatusText()
        } catch {
            connectionDictStatusLabel?.stringValue = "失敗: \(error.localizedDescription)"
        }
    }

    private func connectionDictionaryStatusText() -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Config.importedConnectionDictFile),
              let size = (try? fm.attributesOfItem(atPath: Config.importedConnectionDictFile)[.size] as? NSNumber)?.intValue,
              size > 0 else {
            return "現在: 内蔵辞書"
        }
        return "現在: インポート辞書 (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
    }

}

/// A single row: [shortcut display] [Record button] [Remove button]
class ShortcutRecorderRow: NSView {
    var shortcut: KeyShortcut?
    var onRemove: ((ShortcutRecorderRow) -> Void)?

    private let displayField = NSTextField()
    private let recordBtn = NSButton()
    private let removeBtn = NSButton()
    private var isRecording = false
    private var eventMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        displayField.isEditable = false
        displayField.isBezeled = true
        displayField.bezelStyle = .roundedBezel
        displayField.stringValue = "未設定"
        displayField.alignment = .center
        addSubview(displayField)

        recordBtn.title = "記録"
        recordBtn.bezelStyle = .rounded
        recordBtn.target = self
        recordBtn.action = #selector(toggleRecording)
        addSubview(recordBtn)

        removeBtn.title = "×"
        removeBtn.bezelStyle = .rounded
        removeBtn.target = self
        removeBtn.action = #selector(removeSelf)
        addSubview(removeBtn)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        displayField.frame = NSRect(x: 0, y: 0, width: w - 150, height: h)
        recordBtn.frame = NSRect(x: w - 140, y: 0, width: 80, height: h)
        removeBtn.frame = NSRect(x: w - 50, y: 0, width: 40, height: h)
    }

    func setShortcut(_ s: KeyShortcut) {
        shortcut = s
        displayField.stringValue = s.displayString
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        recordBtn.title = "入力待ち..."
        displayField.stringValue = "キーを押してください"
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        recordBtn.title = "記録"
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let s = KeyShortcut.from(event: event)
        setShortcut(s)
        stopRecording()
    }

    @objc private func removeSelf() {
        onRemove?(self)
    }
}
