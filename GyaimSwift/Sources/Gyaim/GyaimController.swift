import Carbon
import Cocoa
import InputMethodKit

/// Polls NSPasteboard.changeCount to record the actual copy timestamp.
/// Uses both a RunLoop timer (for main thread) and a GCD timer (for background)
/// to ensure at least one fires in the IME process environment.
final class ClipboardMonitor {
    private let lock = NSLock()
    private var _changeCount: Int
    private var _lastChangeDate: Date = .distantPast
    private var gcdTimer: DispatchSourceTimer?
    private var runLoopTimer: Timer?

    var changeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _changeCount
    }

    var lastChangeDate: Date {
        lock.lock()
        defer { lock.unlock() }
        return _lastChangeDate
    }

    init() {
        _changeCount = NSPasteboard.general.changeCount
        startPolling()
    }

    private func startPolling() {
        // GCD timer (works even without a RunLoop)
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + 0.5, repeating: 0.5)
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        gcdTimer = source

        // RunLoop timer (works on main thread in IME process)
        DispatchQueue.main.async { [weak self] in
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.poll()
            }
            RunLoop.main.add(timer, forMode: .common)
            self?.runLoopTimer = timer
        }
    }

    private func poll() {
        let current = NSPasteboard.general.changeCount
        lock.lock()
        if current != _changeCount {
            _changeCount = current
            _lastChangeDate = Date()
            lock.unlock()
            Log.input.debug("ClipboardMonitor: changeCount → \(current)")
        } else {
            lock.unlock()
        }
    }

    deinit {
        gcdTimer?.cancel()
        runLoopTimer?.invalidate()
    }
}

// swiftlint:disable file_length type_body_length
/// Central IME controller implementing InputMethodKit protocol.
/// Ported from GyaimController.rb (Toshiyuki Masui, 2011-2015)
@objc(GyaimController)
class GyaimController: IMKInputController {
    private static var shared: GyaimController?

    /// Input modes declared in Info.plist ComponentInputModeDict.
    /// `.roman` is an ASCII-capable passthrough mode that exists so macOS can
    /// keep Gyaim selectable while Secure Event Input is active (issue #85).
    /// It is hidden from the input menu (tsInputModeIsVisibleKey = false);
    /// the system switches to it automatically and back, so users never
    /// interact with it directly.
    enum InputMode: String {
        case japanese = "com.apple.inputmethod.Japanese"
        case roman = "com.apple.inputmethod.Roman"
    }

    private var inputMode: InputMode = .japanese

    private var inputPat = ""
    private var candidates: [SearchCandidate] = []
    private var nthCand = 0
    private var searchMode = 0
    private var tmpImageDisplayed = false
    private var bsThrough = false
    /// Clipboard text captured at input start.
    private var clipboardCandidate: String?
    /// Selected text captured at the moment of first keystroke.
    private var selectedCandidate: String?
    /// Monitors NSPasteboard.changeCount to record the actual copy time.
    private static let clipboardMonitor = ClipboardMonitor()
    /// The changeCount that was last consumed (shown as candidate to user).
    private static var lastConsumedCC: Int = NSPasteboard.general.changeCount

    private var ws: WordSearch?
    private var recentCommittedText = ""
    private let maxAIContextCharacters = 80
    private var rk = RomaKana()
    private var candWindow: CandidateWindow?
    /// Last IMK-reported cursor rect that looked like a valid screen-coordinate rect.
    private var lastValidCandidateLineRect: NSRect?
    /// Tracks the in-flight Google Transliterate query to discard stale results.
    private var pendingGoogleQuery: String?
    /// Deferred model review of the current prefix candidates (ADR-026). Cancelled
    /// by every keystroke so the model only runs when typing pauses.
    /// Background model review of the current prefix candidates (ADR-029).
    private var inFlightReview: FastContextReviewTicket?
    private static let modelReviewQueue = DispatchQueue(label: "com.pitecan.inputmethod.SwiftyGyaim.fast-context-review",
                                                        qos: .userInitiated)
    private var inputGeneration = 0
    private let traceControllerID = UUID().uuidString
    /// Increments on the first printable key of a composition; joins rerank
    /// logs to its commit together with the controller UUID and generation.
    private var compositionID = 0
    private var fastContextTrace: FastContextTrace?
    /// Prefix-mode state kept when the user leaves it for exact mode or Google,
    /// so the eventual commit can still say where the word was in the prefix
    /// list (escapes were invisible to accepted-detail metrics).
    private var escapedPrefixTrace: FastContextTrace?
    private var escapedPrefixWords: [String] = []
    /// Diagnostics for very short activate → deactivate cycles caused by input source switching.
    private var lastActivationTime: CFAbsoluteTime?
    private var lastActivationSequence = 0

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)

        if candWindow == nil {
            candWindow = CandidateWindow()
        }

        if ws == nil {
            // 新規コントローラは共有キャッシュを再利用するだけ。ここで
            // resetConnectionDict() を呼ぶとIMKのコントローラ再生成（アプリ
            // 切替のたび）ごとに40K行の再パースが走り、PR #83の共有が
            // 無効化される（BUG-033）。
            setupWordSearch()
        }
        Log.input.info("GyaimController initialized")

        if let client = inputClient as? (IMKTextInput & NSObjectProtocol) {
            CopyText.set(NSPasteboard.general.string(forType: .string))
        }

        resetState()
        GyaimController.shared = self
    }

    override func activateServer(_ sender: Any!) {
        lastActivationTime = CFAbsoluteTimeGetCurrent()
        lastActivationSequence += 1
        let senderDescription = describeIMKObject(sender)
        let clientDescription = describeIMKObject(client())
        Log.input.info("IME activated: seq=\(lastActivationSequence) "
            + "sender=\(senderDescription) currentClient=\(clientDescription) "
            + "pasteboardCC=\(NSPasteboard.general.changeCount) "
            + "lastConsumedCC=\(GyaimController.lastConsumedCC)")
        CopyText.set(NSPasteboard.general.string(forType: .string))
        SecureInputDiagnostics.checkAndLog()
        ws?.start()
        if Self.isFastContextRerankModelEnabled {
            InProcessAIReranker.shared.warmUp()
        }
        showWindow()
    }

    override func deactivateServer(_ sender: Any!) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsedMs = lastActivationTime.map { (now - $0) * 1000 }
        let elapsedDescription = elapsedMs.map { String(format: "%.1f", $0) } ?? "unknown"
        let shortCycle = elapsedMs.map { $0 < 1000 } ?? false
        let level = shortCycle ? "short-cycle" : "normal"
        let senderDescription = describeIMKObject(sender)
        let clientDescription = describeIMKObject(client())
        Log.input.info("IME deactivated: level=\(level) seq=\(lastActivationSequence) "
            + "elapsedSinceActivate=\(elapsedDescription)ms converting=\(converting) "
            + "candidates=\(candidates.count) sender=\(senderDescription) "
            + "currentClient=\(clientDescription)")
        hideWindow()
        if Self.shouldCommitOnDeactivation(inputPat: inputPat) {
            fix(client: sender, skipStudy: true)
        } else {
            // Deactivation is frequent when focus moves between apps/fields.
            // Do not call insertText("") when there is no active composition.
            resetState()
        }
        ws?.finish()
    }

    static func shouldCommitOnDeactivation(inputPat: String) -> Bool {
        !inputPat.isEmpty
    }

    /// IMK delivers the current input mode via kTextServiceInputModePropertyTag
    /// on activation and whenever the user (or the system, e.g. Secure Event
    /// Input fallback) switches modes.
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        guard tag == kTextServiceInputModePropertyTag else {
            super.setValue(value, forTag: tag, client: sender)
            return
        }
        let identifier = value as? String
        let newMode = Self.inputMode(forTISIdentifier: identifier)
        guard newMode != inputMode else { return }
        Log.input.info("Input mode changed: \(identifier ?? "nil") -> \(newMode.rawValue)")
        if newMode == .roman {
            // Entering ASCII passthrough: commit any pending preedit first so
            // it is not lost, then hide the candidate window.
            if converting {
                fix(client: sender, skipStudy: true)
            }
            hideWindow()
        }
        inputMode = newMode
    }

    /// Pure mapping from the TIS mode identifier to InputMode (testable).
    /// Unknown identifiers fall back to `.japanese` so a plist/OS mismatch
    /// never leaves the IME stuck in passthrough.
    static func inputMode(forTISIdentifier identifier: String?) -> InputMode {
        identifier.flatMap(InputMode.init(rawValue:)) ?? .japanese
    }

    /// AppDelegate.applicationWillTerminate から呼ばれるセーフティネット。
    /// study() 自体が毎回ファイル保存するので通常は冗長だが、deactivateServer が
    /// 呼ばれずに終了するケース（プロセスkill等）への備えとして残す。
    static func saveStudyDictIfNeeded() {
        shared?.ws?.finish()
    }

    /// 明示リロード（Gictionaryインポート後など）。同じパスへ新しい内容が
    /// 書き込まれるため、共有キャッシュを破棄してから作り直す。
    /// コントローラinitからは呼ばないこと（BUG-033）。
    static func reloadConnectionDictionary() {
        WordSearch.resetConnectionDict()
        shared?.setupWordSearch()
    }

    /// WordSearchを構築する。共有ConnectionDictはパスが同じ限り再利用され、
    /// プロセス内の初回だけロードが走る。
    private func setupWordSearch() {
        guard let bundleDictPath = Bundle.main.path(forResource: "dict", ofType: "txt") else {
            Log.input.error("dict.txt not found in bundle")
            return
        }
        let dictPath = Config.activeConnectionDictFile(bundleDictPath: bundleDictPath)
        ws = WordSearch(connectionDictFile: dictPath,
                        localDictFile: Config.localDictFile,
                        studyDictFile: Config.studyDictFile)
        Log.dict.info("Connection dictionary activated: \(dictPath)")
    }

    private func resetState() {
        cancelDeferredModelReview()
        fastContextTrace = nil
        escapedPrefixTrace = nil
        escapedPrefixWords = []
        inputPat = ""
        candidates = []
        nthCand = 0
        searchMode = 0
        clipboardCandidate = nil
        selectedCandidate = nil
        pendingGoogleQuery = nil
    }

    private var converting: Bool {
        !inputPat.isEmpty
    }

    private func describeIMKObject(_ object: Any?) -> String {
        guard let object else { return "nil" }
        let typeName = String(describing: type(of: object))
        let bundleIdentifier = (object as? IMKTextInput)?.bundleIdentifier() ?? "unknown"
        return "type=\(typeName),bundle=\(bundleIdentifier)"
    }

    // MARK: - Menu & Preferences

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "Gyaim")
        let item = NSMenuItem(title: "Gyaim 設定...",
                              action: #selector(openPreferences(_:)),
                              keyEquivalent: "")
        item.target = self
        menu.addItem(item)

        let dictItem = NSMenuItem(title: "ユーザー辞書...",
                                  action: #selector(openDictEditor(_:)),
                                  keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)
        return menu
    }

    @objc func openDictEditor(_ sender: Any?) {
        DictEditorWindow.show()
    }

    @objc func openPreferences(_ sender: Any?) {
        PreferencesWindow.show()
    }

    override func showPreferences(_ sender: Any!) {
        PreferencesWindow.show()
    }

    // MARK: - Event Handling

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        let kVirtualJISRomanModeKey: UInt16 = 102
        let kVirtualJISKanaModeKey: UInt16 = 104

        guard event.type == .keyDown else { return false }

        // Roman (英数) passthrough mode: hand every key back to the client so
        // it is inserted per the active keyboard layout. No conversion here.
        if inputMode == .roman {
            return false
        }

        let keyCode = event.keyCode
        let modifierFlags = event.modifierFlags
        Log.input.debug("keyDown: keyCode=\(keyCode), chars=\(event.characters ?? ""), mods=\(modifierFlags.rawValue)")
        // Space on the first candidate is the moment the model's opinion is
        // consumed: give an in-flight review a short chance to land first
        // (ADR-029). Every key then invalidates whatever is still pending.
        joinInFlightReviewIfSelectingFirstCandidate(event)
        cancelDeferredModelReview()

        if keyCode == kVirtualJISKanaModeKey || keyCode == kVirtualJISRomanModeKey {
            return true
        }

        // Configurable shortcuts: hiragana / katakana confirm (modifier keys)
        if converting, KeyBindings.shared.matchesHiragana(event: event) {
            fixAsKana(hiragana: true, client: sender)
            return true
        }
        if converting, KeyBindings.shared.matchesKatakana(event: event) {
            fixAsKana(hiragana: false, client: sender)
            return true
        }

        // Google Transliterate shortcut while converting.
        if converting, KeyBindings.shared.matchesGoogleTransliterate(event: event) {
            triggerGoogleTransliterate(client: sender)
            return true
        }

        // Tab while converting triggers Google Transliterate (ADR-024).
        // The local AI generation pipeline was removed: it could only compose
        // dictionary parts, so unknown words produced garbage candidates.
        // Shift+Tab stays a consumed no-op.
        if converting, event.keyCode == 48 {
            if modifierFlags.contains(.shift) { return true }
            triggerGoogleTransliterate(client: sender)
            return true
        }

        // Delete candidate shortcut (modifier-key based)
        if converting, KeyBindings.shared.matchesDeleteCandidate(event: event),
           nthCand > 0 || searchMode > 0 {
            deleteCurrentCandidate(client: sender)
            return true
        }

        guard let eventString = event.characters, !eventString.isEmpty else { return true }

        guard let c = eventString.utf8.first else { return true }

        // Single-key kana confirm: ; → hiragana, q → katakana (configurable)
        if converting, modifierFlags.isDisjoint(with: [.control, .command, .option]) {
            if c == KeyBindings.shared.hiraganaChar {
                fixAsKana(hiragana: true, client: sender)
                return true
            }
            if c == KeyBindings.shared.katakanaChar {
                fixAsKana(hiragana: false, client: sender)
                return true
            }
        }

        var handled = false

        // Backspace / Escape
        if c == 0x08 || c == 0x7f || c == 0x1b {
            if converting, tmpImageDisplayed, !bsThrough {
                tmpImageDisplayed = false
                Emulation.key(Emulation.deleteKeyCode)
                return true
            }
            if !bsThrough, converting {
                if nthCand > 0 {
                    nthCand -= 1
                    showCands(client: sender)
                } else {
                    inputPat = String(inputPat.dropLast())
                    searchAndShowCands(client: sender)
                }
                handled = true
            }
            bsThrough = false
        }
        // Space
        else if c == 0x20 {
            if converting {
                if tmpImageDisplayed {
                    Emulation.key("z", modifier: .maskCommand)
                    Emulation.key(Emulation.spaceKeyCode)
                    tmpImageDisplayed = false
                    return true
                }
                if nthCand < candidates.count - 1 {
                    nthCand += 1
                    showCands(client: sender)
                }
                handled = true
            }
        }
        // Enter
        else if c == 0x0a || c == 0x0d {
            if converting {
                if tmpImageDisplayed {
                    tmpImageDisplayed = false
                    resetState()
                    return true
                }
                if searchMode > 0 {
                    fix(client: sender)
                } else {
                    let currentCandidateIsRawInput = candidates[safe: nthCand]?.word == inputPat
                    if nthCand == 0, currentCandidateIsRawInput {
                        searchMode = 1
                        searchAndShowCands(client: sender)
                    } else {
                        fix(client: sender)
                    }
                }
                handled = true
            }
        }
        // Single-key delete candidate (e.g. Shift+X) when candidates are visible
        else if converting, nthCand > 0 || searchMode > 0,
                KeyBindings.shared.deleteCandidateChar != 0,
                c == KeyBindings.shared.deleteCandidateChar,
                modifierFlags.isDisjoint(with: [.control, .command, .option]) {
            deleteCurrentCandidate(client: sender)
            handled = true
        }
        // Number keys 1-9: select candidate from list (only when list is visible)
        else if converting, nthCand > 0 || searchMode > 0,
                c >= 0x31, c <= 0x39,
                modifierFlags.isDisjoint(with: [.control, .command, .option]) {
            let num = Int(c - 0x30) // 1-9
            let targetIndex = nthCand + num
            if targetIndex < candidates.count {
                nthCand = targetIndex
                fix(client: sender)
            }
            handled = true
        }
        // Printable character (0x21-0x7e), no Control/Command/Option
        else if c >= 0x21, c <= 0x7e,
                modifierFlags.isDisjoint(with: [.control, .command, .option]) {
            if nthCand > 0 || searchMode > 0 {
                fix(client: sender)
            }
            // Capture selected text and clipboard only on the first keystroke of a new input
            if inputPat.isEmpty {
                startComposition(client: sender)
            }
            inputPat += eventString
            searchMode = 0
            searchAndShowCands(client: sender)
            handled = true
        }

        showWindow()
        return handled
    }

    // MARK: - Event Routing (Testable)

    /// Describes the outcome of event routing without side effects.
    struct HandleResult: Equatable {
        var handled: Bool
        var action: HandleAction

        enum HandleAction: Equatable {
            case none
            case searchAndShow
            case showCands
            case fix
            case fixThenSearchAndShow
            case fixAsKana(hiragana: Bool)
            case backspaceInputPat
            case decrementNthCand
            case incrementNthCand
            case setSearchModeAndSearch
            case numberKeySelect(Int)
            case jisModKey
            case emulateDelete
            case resetTmpImage
            case undoAndSpace
            case undoThenInsertChar
            case googleTransliterate
            case deleteCandidate
        }
    }

    /// Pure routing logic extracted from handle(_:client:) for unit testing.
    /// All branching decisions are encoded in the returned HandleResult.
    static func routeEvent(
        character: UInt8,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        converting: Bool,
        nthCand: Int,
        candidateCount: Int,
        searchMode: Int,
        tmpImageDisplayed: Bool,
        bsThrough: Bool,
        hiraganaChar: UInt8,
        katakanaChar: UInt8,
        matchesHiraganaShortcut: Bool,
        matchesKatakanaShortcut: Bool,
        matchesGoogleTransliterateShortcut: Bool = false,
        matchesDeleteCandidateShortcut: Bool = false,
        deleteCandidateChar: UInt8 = 0x58,
        currentCandidateIsRawInput: Bool = true,
        inputPatEmpty: Bool,
        hasEventString: Bool
    ) -> HandleResult {
        let kVirtualJISRomanModeKey: UInt16 = 102
        let kVirtualJISKanaModeKey: UInt16 = 104

        // JIS kana/roman mode keys
        if keyCode == kVirtualJISKanaModeKey || keyCode == kVirtualJISRomanModeKey {
            return HandleResult(handled: true, action: .jisModKey)
        }

        // Configurable shortcuts: hiragana / katakana confirm (modifier keys)
        if converting, matchesHiraganaShortcut {
            return HandleResult(handled: true, action: .fixAsKana(hiragana: true))
        }
        if converting, matchesKatakanaShortcut {
            return HandleResult(handled: true, action: .fixAsKana(hiragana: false))
        }

        // Google Transliterate shortcut.
        if converting, matchesGoogleTransliterateShortcut {
            return HandleResult(handled: true, action: .googleTransliterate)
        }

        // Tab triggers Google Transliterate (ADR-024). Shift+Tab is consumed
        // as a no-op; backtick is handled as a printable Google Transliterate
        // suffix below.
        if converting, keyCode == 48 {
            if modifierFlags.contains(.shift) {
                return HandleResult(handled: true, action: .none)
            }
            return HandleResult(handled: true, action: .googleTransliterate)
        }
        // Delete candidate shortcut (modifier-key based, e.g. Ctrl+X)
        if converting, matchesDeleteCandidateShortcut, nthCand > 0 || searchMode > 0 {
            return HandleResult(handled: true, action: .deleteCandidate)
        }

        // No event string → handled (consumed, no action)
        guard hasEventString else {
            return HandleResult(handled: true, action: .none)
        }

        let c = character

        // Single-key kana confirm: ; → hiragana, q → katakana (configurable)
        if converting, modifierFlags.isDisjoint(with: [.control, .command, .option]) {
            if c == hiraganaChar {
                return HandleResult(handled: true, action: .fixAsKana(hiragana: true))
            }
            if c == katakanaChar {
                return HandleResult(handled: true, action: .fixAsKana(hiragana: false))
            }
        }

        // Backspace / Escape
        if c == 0x08 || c == 0x7f || c == 0x1b {
            if converting, tmpImageDisplayed, !bsThrough {
                return HandleResult(handled: true, action: .emulateDelete)
            }
            if !bsThrough, converting {
                if nthCand > 0 {
                    return HandleResult(handled: true, action: .decrementNthCand)
                } else {
                    return HandleResult(handled: true, action: .backspaceInputPat)
                }
            }
            return HandleResult(handled: false, action: .none)
        }

        // Space
        if c == 0x20 {
            if converting {
                if tmpImageDisplayed {
                    return HandleResult(handled: true, action: .undoAndSpace)
                }
                if nthCand < candidateCount - 1 {
                    return HandleResult(handled: true, action: .incrementNthCand)
                }
                return HandleResult(handled: true, action: .none)
            }
            return HandleResult(handled: false, action: .none)
        }

        // Enter
        if c == 0x0a || c == 0x0d {
            if converting {
                if tmpImageDisplayed {
                    return HandleResult(handled: true, action: .resetTmpImage)
                }
                if searchMode > 0 {
                    return HandleResult(handled: true, action: .fix)
                } else {
                    if nthCand == 0, currentCandidateIsRawInput {
                        return HandleResult(handled: true, action: .setSearchModeAndSearch)
                    } else {
                        return HandleResult(handled: true, action: .fix)
                    }
                }
            }
            return HandleResult(handled: false, action: .none)
        }

        // Single-key delete candidate (e.g. Shift+X) when candidates are visible
        if converting, nthCand > 0 || searchMode > 0,
           deleteCandidateChar != 0, c == deleteCandidateChar,
           modifierFlags.isDisjoint(with: [.control, .command, .option]) {
            return HandleResult(handled: true, action: .deleteCandidate)
        }

        // Number keys 1-9: select candidate from list (only when list is visible)
        if converting, nthCand > 0 || searchMode > 0,
           c >= 0x31, c <= 0x39,
           modifierFlags.isDisjoint(with: [.control, .command, .option]) {
            let num = Int(c - 0x30)
            let targetIndex = nthCand + num
            if targetIndex < candidateCount {
                return HandleResult(handled: true, action: .numberKeySelect(targetIndex))
            }
            return HandleResult(handled: true, action: .none)
        }

        // Printable character (0x21-0x7e), no Control/Command/Option
        if c >= 0x21, c <= 0x7e,
           modifierFlags.isDisjoint(with: [.control, .command, .option]) {
            if nthCand > 0 || searchMode > 0 {
                return HandleResult(handled: true, action: .fixThenSearchAndShow)
            }
            return HandleResult(handled: true, action: .searchAndShow)
        }

        return HandleResult(handled: false, action: .none)
    }

    // MARK: - External Candidate Capture

    /// Capture selected text and clipboard at input start.
    /// Called once when the first printable character is typed.
    static var isClipboardCandidateEnabled: Bool {
        GyaimSettings.bool(forKey: "clipboardCandidateEnabled", default: true)
    }
    static func setClipboardCandidateEnabled(_ value: Bool) {
        GyaimSettings.set(value, forKey: "clipboardCandidateEnabled")
    }

    static var isSelectedTextCandidateEnabled: Bool {
        GyaimSettings.bool(forKey: "selectedTextCandidateEnabled", default: true)
    }
    static func setSelectedTextCandidateEnabled(_ value: Bool) {
        GyaimSettings.set(value, forKey: "selectedTextCandidateEnabled")
    }

    private func captureExternalCandidates(client sender: Any?) {
        // Capture selected text from the active application
        if GyaimController.isSelectedTextCandidateEnabled {
            if let client = sender as? IMKTextInput {
                let range = client.selectedRange()
                if range.length > 0 {
                    if let attrStr = client.attributedSubstring(from: range) {
                        let s = attrStr.string
                        if !s.isEmpty {
                            selectedCandidate = s
                            Log.input.info("Captured selected text: \"\(s)\"")
                        }
                    }
                }
            }
        }

        // Clipboard candidate logic:
        // - ClipboardMonitor polls changeCount every 0.5s to record WHEN the copy happened
        // - We compare current changeCount against lastConsumedCC (static, survives instance recreation)
        // - Only show if: new copy detected AND copy happened within 5 seconds
        guard GyaimController.isClipboardCandidateEnabled else { return }

        let currentCC = NSPasteboard.general.changeCount
        let monitor = GyaimController.clipboardMonitor

        // If the monitor hasn't caught up yet (copy happened between polls),
        // the copy is very recent — treat elapsed as 0.
        let monitorCC = monitor.changeCount
        let elapsed: TimeInterval
        if currentCC == monitorCC {
            elapsed = Date().timeIntervalSince(monitor.lastChangeDate)
        } else {
            elapsed = 0
        }

        if currentCC != GyaimController.lastConsumedCC {
            GyaimController.lastConsumedCC = currentCC

            if elapsed < 5.0 {
                if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                    clipboardCandidate = text
                    Log.input.info("Captured clipboard (elapsed: \(String(format: "%.1f", elapsed))s): \"\(text.prefix(50))\"")
                }
            }
        }
    }

    // MARK: - Asynchronous model review (ADR-029) — scheduling

    private func startComposition(client sender: Any?) {
        compositionID += 1
        captureExternalCandidates(client: sender)
    }

    private func cancelDeferredModelReview() {
        if let ticket = inFlightReview {
            ticket.cancel()
            fastContextTrace?.cancel()
        }
        inFlightReview = nil
        inputGeneration += 1
    }

    private func traceTag(pass: String) -> String {
        "controller=\(traceControllerID) composition=\(compositionID) gen=\(inputGeneration) pass=\(pass)"
    }

    /// Run the model review off the main thread and apply it when it lands, if
    /// the input has not moved on. The heuristic order is already on screen.
    private func startAsyncModelReview(input: FastContextPrefixInput) {
        let ticket = FastContextReviewTicket(generation: inputGeneration, input: input)
        inFlightReview = ticket
        let tag = traceTag(pass: "review")
        let work = { [weak self] in
            guard !ticket.isCancelled else { return }
            var observation: FastContextObservation?
            let reviewed = GyaimController.buildPrefixCandidates(
                searchResults: input.searchResults, inputPat: input.inputPat,
                clipboardCandidate: input.clipboard, selectedCandidate: input.selected,
                hiragana: input.hiragana, context: input.context, allowModelReview: true,
                traceTag: tag, onRerank: { observation = $0 })
            ticket.store(FastContextReviewTicket.Outcome(candidates: reviewed, observation: observation))
            DispatchQueue.main.async { self?.applyReview(ticket) }
        }
        let delay = Self.modelReviewDelayMilliseconds()
        if delay > 0 {
            Self.modelReviewQueue.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
        } else {
            Self.modelReviewQueue.async(execute: work)
        }
    }

    /// Main thread. Applies a finished review once, only while it still
    /// describes what the user is looking at.
    private func applyReview(_ ticket: FastContextReviewTicket) {
        guard inFlightReview === ticket,
              ticket.generation == inputGeneration,
              inputPat == ticket.input.inputPat,
              searchMode == 0,
              nthCand == 0,
              let outcome = ticket.current,
              ticket.markApplied() else { return }
        inFlightReview = nil
        let words = outcome.candidates.map(\.word)
        fastContextTrace?.complete(words: words, observation: outcome.observation, generation: ticket.generation)
        guard words != candidates.map(\.word) else { return }
        candidates = outcome.candidates
        showCands(client: client())
    }

    /// Space on the first candidate is the moment the model's opinion is
    /// consumed; number keys and Enter on a highlighted row pick what is
    /// already displayed and must not be re-ordered underneath the user.
    private func joinInFlightReviewIfSelectingFirstCandidate(_ event: NSEvent) {
        guard converting, nthCand == 0, !tmpImageDisplayed,
              event.characters?.utf8.first == 0x20,
              event.modifierFlags.isDisjoint(with: [.control, .command, .option]) else { return }
        joinInFlightReviewBeforeSelection()
    }

    /// Wait briefly for the in-flight review so the model's order is what the
    /// user is about to select from.
    private func joinInFlightReviewBeforeSelection() {
        guard let ticket = inFlightReview, ticket.generation == inputGeneration else { return }
        let wait = Self.modelReviewSelectionWaitMilliseconds()
        let start = CFAbsoluteTimeGetCurrent()
        if ticket.waitForResult(timeout: .milliseconds(wait)) != nil {
            applyReview(ticket)
            if Self.isFastContextRerankLoggingEnabled {
                Log.input.info("Fast context review joined at selection: input=\"\(inputPat)\" "
                    + "waited=\(Self.formatMilliseconds(Self.elapsedMilliseconds(since: start)))ms")
            }
        } else if Self.isFastContextRerankLoggingEnabled {
            Log.input.info("Fast context review not ready at selection: input=\"\(inputPat)\" waitMs=\(wait)")
        }
    }

    // MARK: - Search & Display

    /// Trigger Google Transliterate for the current inputPat.
    /// Called by either suffix trigger (e.g. "meguro`") or shortcut (e.g. Ctrl+G).
    private func triggerGoogleTransliterate(query: String? = nil, client sender: Any? = nil) {
        let q = query ?? inputPat
        guard !q.isEmpty else { return }

        cancelDeferredModelReview()
        preservePrefixStateForEscape()
        fastContextTrace = nil
        pendingGoogleQuery = q
        searchMode = 2
        Log.input.info("Google Transliterate triggered: \"\(q)\"")

        // Show query as marked text while waiting
        candidates = GoogleTransliterate.buildGoogleCandidates(apiResults: [], query: q)
        nthCand = 0
        showCands(client: sender ?? self.client())

        GoogleTransliterate.searchCands(q) { [weak self] results in
            guard let self else { return }
            // Stale guard: discard if inputPat has changed
            guard self.pendingGoogleQuery == q,
                  self.inputPat == q else {
                Log.input.debug("Google Transliterate stale result discarded for \"\(q)\"")
                return
            }
            self.pendingGoogleQuery = nil

            let googleCandidates = GoogleTransliterate.buildGoogleCandidates(
                apiResults: results, query: q)
            Log.input.info("Google Transliterate results for \"\(q)\": \(results)")
            GyaimController.showCands(googleCandidates)
        }
    }

    /// Only a live prefix trace is kept; a repeated exact/Google search must not
    /// overwrite the prefix snapshot with nothing.
    private func preservePrefixStateForEscape() {
        guard let fastContextTrace else { return }
        escapedPrefixTrace = fastContextTrace
        escapedPrefixWords = candidates.map(\.word)
    }

    private func searchAndShowCands(client sender: Any?) {
        guard let ws else { return }
        // Allocate the request generation BEFORE both passes. Scheduling must
        // not increment it again, or prereview/review/commit cannot be joined.
        cancelDeferredModelReview()
        if searchMode == 1 || GoogleTransliterate.hasTriggerSuffix(inputPat) {
            preservePrefixStateForEscape()
        }
        fastContextTrace = nil

        if GoogleTransliterate.hasTriggerSuffix(inputPat) {
            let query = GoogleTransliterate.stripTriggerSuffix(inputPat)
            inputPat = query
            triggerGoogleTransliterate(query: query, client: sender)
            return
        }

        if searchMode == 1 {
            candidates = PerfLog.measure("search(\(inputPat), exact)", logger: Log.input) {
                ws.search(query: inputPat, searchMode: searchMode)
            }
            let katakana = rk.roma2katakana(inputPat)
            if !katakana.isEmpty {
                candidates = candidates.filter { $0.word != katakana }
                candidates.insert(SearchCandidate(word: katakana, reading: inputPat, kind: .kana), at: 0)
            }
            let hiragana = rk.roma2hiragana(inputPat)
            if !hiragana.isEmpty {
                candidates = candidates.filter { $0.word != hiragana }
                candidates.insert(SearchCandidate(word: hiragana, reading: inputPat, kind: .kana), at: 0)
            }
        } else {
            let searchResults = PerfLog.measure("search(\(inputPat), prefix)", logger: Log.input) {
                ws.search(query: inputPat, searchMode: searchMode)
            }
            updatePrefixCandidates(searchResults: searchResults)
        }

        nthCand = 0
        showCands(client: sender)
    }

    private func updatePrefixCandidates(searchResults: [SearchCandidate]) {
        let input = FastContextPrefixInput(searchResults: searchResults, inputPat: inputPat,
                                           hiragana: rk.roma2hiragana(inputPat), clipboard: clipboardCandidate,
                                           selected: selectedCandidate, context: recentCommittedText)
        let useModel = Self.shouldScheduleModelReview(inputPat: inputPat)
        candidates = Self.buildPrefixCandidates(searchResults: searchResults, inputPat: inputPat,
                                                clipboardCandidate: input.clipboard, selectedCandidate: input.selected,
                                                hiragana: input.hiragana, context: input.context, allowModelReview: false,
                                                traceTag: traceTag(pass: useModel ? "prereview" : "heuristic"))
        fastContextTrace = FastContextTrace(controllerID: traceControllerID, compositionID: compositionID,
                                           generation: inputGeneration, heuristicWords: candidates.map(\.word),
                                           proposedWords: nil, modelState: useModel ? .pending : .notScheduled,
                                           deferred: true)
        if useModel {
            startAsyncModelReview(input: input)
        }
    }

    private func showCands(client sender: Any?) {
        let words = candidates.map(\.word)
        guard nthCand < words.count, let word = words[safe: nthCand] else { return }

        guard let client = sender as? IMKTextInput else { return }

        if ImageManager.isImageCandidate(word) {
            // Image candidate handling
            client.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            bsThrough = true
            Emulation.key(Emulation.deleteKeyCode)
            ImageManager.pasteGyazoToPasteboard(word)
            Emulation.key("v", modifier: .maskCommand)
            tmpImageDisplayed = true
        } else {
            if tmpImageDisplayed {
                Emulation.key("z", modifier: .maskCommand)
                tmpImageDisplayed = false
            }

            let kTSMHiliteRawText = 2
            let attrs = mark(forStyle: kTSMHiliteRawText, at: NSRange(location: 0, length: word.count))
                as? [NSAttributedString.Key: Any] ?? [:]
            let attrStr = NSAttributedString(string: word, attributes: attrs)
            client.setMarkedText(attrStr,
                                 selectionRange: NSRange(location: word.count, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }

        // Update candidate list (count depends on display mode)
        let maxCandList = CandidateDisplayMode.current.maxVisible
        var candList: [String] = []
        for i in 0..<maxCandList {
            let idx = nthCand + 1 + i
            guard idx < words.count, let cand = words[safe: idx] else { break }
            candList.append(cand)
        }
        let hasMore = (nthCand + 1 + maxCandList) < words.count
        let hasPrev = nthCand > 0
        candWindow?.updateCandidates(candList, selectedIndex: -1, hasMore: hasMore, hasPrev: hasPrev)
    }

    /// Single-line JSON payload for preference-pair extraction (issue #57 /
    /// M6-1): the committed candidate plus the displayed head of the list,
    /// with the metadata the offline trainer needs (reading / source / kind /
    /// studyFrequency / contextAffinity). Emitted only when fast-context
    /// logging is enabled; parsed by extract-preference-pairs.py.
    static func acceptedDetailPayload(candidates: [SearchCandidate],
                                      chosenIndex: Int,
                                      context: String,
                                      headLimit: Int = 8,
                                      affinityProvider: ((SearchCandidate) -> Double)? = nil,
                                      trace: FastContextTrace? = nil) -> String? {
        guard candidates.indices.contains(chosenIndex) else { return nil }

        func encode(_ candidate: SearchCandidate, rank: Int) -> [String: Any] {
            var item: [String: Any] = [
                "rank": rank,
                "word": candidate.word,
                "source": String(describing: candidate.source),
                "kind": candidate.kind.rawValue,
            ]
            if let reading = candidate.reading { item["reading"] = reading }
            if let frequency = candidate.studyFrequency { item["studyFrequency"] = frequency }
            let affinity = affinityProvider?(candidate)
                ?? ContextDict.shared.affinity(context: context, reading: candidate.reading, word: candidate.word)
            if affinity > 0 { item["contextAffinity"] = affinity }
            return item
        }

        var top = candidates.prefix(headLimit).enumerated().map { encode($0.element, rank: $0.offset) }
        if chosenIndex >= headLimit {
            top.append(encode(candidates[chosenIndex], rank: chosenIndex))
        }
        var payload: [String: Any] = [
            "chosenRank": chosenIndex,
            "context": context,
            "top": top,
        ]
        if let trace {
            payload.merge(trace.payload(chosenWord: candidates[chosenIndex].word,
                                        displayedWords: candidates.map(\.word))) { _, new in new }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private func recordCommittedText(_ text: String) {
        guard !text.isEmpty else { return }
        recentCommittedText += text
        if recentCommittedText.count > maxAIContextCharacters {
            recentCommittedText = String(recentCommittedText.suffix(maxAIContextCharacters))
        }
    }

    // MARK: - Fix as Kana (F6/F7)

    private func fixAsKana(hiragana: Bool, client sender: Any?) {
        guard converting else { return }
        let word = hiragana ? rk.roma2hiragana(inputPat) : rk.roma2katakana(inputPat)
        let kanaType = hiragana ? "hiragana" : "katakana"
        Log.input.info("Fixed as kana(\(kanaType)): \"\(word)\" (input: \"\(inputPat)\", candidates: \(candidates.count))")

        let resolvedClient = (sender as? IMKTextInput) ?? (self.client() as? IMKTextInput)
        guard !word.isEmpty, let client = resolvedClient else {
            resetState()
            hideWindow()
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [:]
        let attrStr = NSAttributedString(string: word, attributes: attrs)
        client.setMarkedText(attrStr,
                             selectionRange: NSRange(location: word.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        client.insertText(word, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        logCommitOutcome(path: "kana-\(kanaType)", word: word)
        if Self.shouldStudyKanaConfirm(hiragana: hiragana) {
            ws?.study(word: word, reading: inputPat)
        } else {
            Log.input.info("Study skipped (kana confirm): \"\(word)\" (reading: \"\(inputPat)\")")
        }
        recordCommittedText(word)
        resetState()
        hideWindow()
    }

    /// Hiragana kana-confirm output is always the raw kana spelling of the
    /// input — regenerable on every keystroke — so learning it only adds
    /// ranking noise (and captures typos verbatim). Katakana confirms stay
    /// studied: they are real orthography choices (コンテキスト etc.) and feed
    /// the dictionary-suggestion workflow. `kanaConfirmStudyEnabled=true`
    /// restores the historical learn-everything behavior.
    static func shouldStudyKanaConfirm(hiragana: Bool) -> Bool {
        !hiragana || GyaimSettings.bool(forKey: "kanaConfirmStudyEnabled")
    }

    // MARK: - Fix (commit selection)

    private func fix(client sender: Any? = nil, skipStudy: Bool = false) {
        guard nthCand < candidates.count else {
            resetState()
            return
        }
        let candidate = candidates[nthCand]
        let word = candidate.word
        let reading = candidate.reading ?? inputPat
        let candidateWords = candidates.map(\.word)
        Log.input.info("Fixed: \"\(word)\" (reading: \"\(reading)\", index: \(nthCand)/\(candidates.count), candidates: \(candidateWords))")

        let resolvedClient = (sender as? IMKTextInput) ?? (self.client() as? IMKTextInput)
        guard let client = resolvedClient else {
            resetState()
            return
        }

        if ImageManager.isImageCandidate(word) {
            if !tmpImageDisplayed {
                Emulation.key("v", modifier: .maskCommand)
            }
            tmpImageDisplayed = false
        } else {
            client.insertText(word, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }

        let path = skipStudy ? "deactivation" : searchMode == 1 ? "exact" : searchMode == 2 ? "google" : "prefix"
        logCommitOutcome(path: path, word: word)

        // Register or study logic (skip when deactivating — user didn't intentionally select)
        if skipStudy {
            Log.input.info("Study skipped (deactivation): \"\(word)\" (reading: \"\(reading)\")")
        } else {
            logAcceptedCandidate(candidate)
            learnCommittedCandidate(candidate)
        }

        if !skipStudy {
            recordCommittedText(word)
        }
        resetState()
        hideWindow()
    }

    private func logAcceptedCandidate(_ candidate: SearchCandidate) {
        guard Self.isFastContextRerankLoggingEnabled, searchMode == 0 else { return }
        Log.input.info("Fast context accepted: input=\"\(self.inputPat)\" word=\"\(candidate.word)\" "
            + "rank=\(self.nthCand) candidates=\(self.candidates.count) "
            + "source=\(String(describing: candidate.source)) kind=\(candidate.kind.rawValue)")
        if let payload = Self.acceptedDetailPayload(candidates: candidates, chosenIndex: nthCand,
                                                    context: Self.limitedFastContext(recentCommittedText),
                                                    trace: fastContextTrace) {
            Log.input.info("Fast context accepted detail: input=\"\(self.inputPat)\" payload=\(payload)")
        }
    }

    /// One line per commit on every path (prefix / exact / google / kana /
    /// deactivation). Accepted detail stays prefix-only for preference pairs.
    private func logCommitOutcome(path: String, word: String) {
        guard Self.isFastContextRerankLoggingEnabled else { return }
        let inPrefixMode = searchMode == 0
        if let payload = Self.commitOutcomePayload(
            path: path, chosenWord: word, context: Self.limitedFastContext(recentCommittedText),
            prefixWords: inPrefixMode ? candidates.map(\.word) : escapedPrefixWords,
            trace: inPrefixMode ? fastContextTrace : escapedPrefixTrace) {
            Log.input.info("Commit outcome: input=\"\(inputPat)\" payload=\(payload)")
        }
    }

    /// `prefixRank` is the chosen word's position in the last prefix-mode list
    /// (raw=0, first displayed candidate=1, absent=nil). `inScoredSet` says
    /// whether the model review scored that word at all: a miss outside the
    /// scored set cannot be fixed by the model, whatever its quality.
    static func commitOutcomePayload(path: String, chosenWord: String, context: String,
                                     prefixWords: [String], trace: FastContextTrace?) -> String? {
        var payload: [String: Any] = [
            "path": path,
            "context": context,
            "prefixCandidateCount": prefixWords.count,
        ]
        payload["prefixRank"] = prefixWords.firstIndex(of: chosenWord)
        if let trace {
            payload["controller"] = trace.controllerID
            payload["composition"] = trace.compositionID
            payload["generation"] = trace.generation
            payload["modelState"] = trace.modelState.rawValue
            payload["heuristicRank"] = trace.heuristicRank(of: chosenWord)
            payload["proposedRank"] = trace.proposedRank(of: chosenWord)
            if let observation = trace.observation {
                payload["modelOutcome"] = fastContextRerankOutcome(model: observation.response.model ?? "unknown")
                payload["inDictionarySnapshot"] = observation.request.candidates.contains { $0.text == chosenWord }
                if let review = observation.response.review {
                    let scored = Set(review.candidateIndices)
                    payload["scoredCount"] = scored.count
                    payload["inScoredSet"] = observation.request.candidates
                        .contains { scored.contains($0.index) && $0.text == chosenWord }
                }
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private func learnCommittedCandidate(_ candidate: SearchCandidate) {
        let word = candidate.word
        let reading = candidate.reading ?? inputPat
        if word == clipboardCandidate || word == selectedCandidate {
            if Self.isExternalCandidateAllowed(forInput: inputPat), Self.isValidExternalCandidate(word) {
                ws?.register(word: word, reading: inputPat)
                Log.input.info("Registered to user dict: \"\(word)\" (reading: \"\(inputPat)\")")
            } else {
                Log.input.info("External candidate registration skipped: \"\(word.prefix(50))\" (reading: \"\(inputPat)\")")
            }
        } else if reading != "ds" {
            ws?.study(word: word, reading: reading)
            ContextDict.shared.record(context: recentCommittedText, reading: reading, word: word)
            Log.input.info("Studied: \"\(word)\" (reading: \"\(reading)\")")
        }
    }

    // MARK: - Delete Candidate

    private func deleteCurrentCandidate(client sender: Any?) {
        guard nthCand < candidates.count, nthCand > 0 || searchMode > 0 else { return }
        let candidate = candidates[nthCand]
        let reading = candidate.reading ?? inputPat

        switch candidate.source {
        case .study, .local:
            ws?.deleteFromUserDictionaries(word: candidate.word, reading: reading)
            // Context memory must not resurrect a deleted candidate.
            ContextDict.shared.deleteEntries(word: candidate.word, reading: reading)
        case .connection, .google, .external, .synthetic:
            Log.dict.info("Cannot delete candidate: \"\(candidate.word)\" (source: \(candidate.source))")
            return
        }

        // Re-search and adjust nthCand
        let prevNth = nthCand
        searchAndShowCands(client: sender)
        nthCand = min(prevNth, max(candidates.count - 1, 0))
        showCands(client: sender)
    }

    // MARK: - Window Management

    private func showWindow() {
        guard converting else {
            candWindow?.orderOut(nil)
            return
        }
        guard let cw = candWindow,
              let client = client() as? IMKTextInput else { return }
        var reportedLineRect = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &reportedLineRect)

        let resolution = CandidateWindowPositioner.resolveLineRect(
            reportedLineRect: reportedLineRect,
            previousValidLineRect: lastValidCandidateLineRect,
            mouseLocation: NSEvent.mouseLocation)
        if resolution.source == .reported {
            lastValidCandidateLineRect = resolution.lineRect
        }

        let winSize = cw.frame.size
        let mode = CandidateDisplayMode.current
        let screenFrame = NSScreen.screens.first { $0.frame.intersects(resolution.lineRect) }?.visibleFrame
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero

        let origin = CandidateWindowPositioner.calculate(
            lineRect: resolution.lineRect,
            winSize: winSize,
            screenFrame: screenFrame,
            mode: mode)

        let sourceDescription = String(describing: resolution.source)
        let modeDescription = mode == .classic ? "classic" : "list"
        Log.ui.debug("showWindow: reportedLineRect=\(reportedLineRect) "
            + "resolvedLineRect=\(resolution.lineRect) source=\(sourceDescription) "
            + "winSize=\(winSize) mode=\(modeDescription) -> origin=\(origin)")
        cw.setFrameOrigin(origin)
        cw.orderFront(nil)
    }

    private func hideWindow() {
        candWindow?.orderOut(nil)
    }

    /// Class method for async candidate updates (e.g., from Google Transliterate).
    /// Sets searchMode = 2 to indicate "Google results displayed".
    /// searchMode values: 0 = prefix, 1 = exact, 2 = Google Transliterate results.
    static func showCands(_ newCandidates: [SearchCandidate]) {
        guard let gc = shared else { return }
        gc.candidates = newCandidates
        gc.searchMode = 2
        gc.showCands(client: gc.client())
    }
}

// swiftlint:enable type_body_length

// MARK: - Array Extension

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
