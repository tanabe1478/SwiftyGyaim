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
    private var pendingAIRerankQuery: String?
    private var pendingAIRerankRevision = 0
    private var recentCommittedText = ""
    private let maxAIContextCharacters = 80
    private var rk = RomaKana()
    private var candWindow: CandidateWindow?
    /// Last IMK-reported cursor rect that looked like a valid screen-coordinate rect.
    private var lastValidCandidateLineRect: NSRect?
    /// Tracks the in-flight Google Transliterate query to discard stale results.
    private var pendingGoogleQuery: String?
    /// Diagnostics for very short activate → deactivate cycles caused by input source switching.
    private var lastActivationTime: CFAbsoluteTime?
    private var lastActivationSequence = 0

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)

        if candWindow == nil {
            candWindow = CandidateWindow()
        }

        if ws == nil {
            reloadConnectionDictionary()
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
        ws?.start()
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
        fix(client: sender, skipStudy: true)
        ws?.finish()
    }

    /// AppDelegate.applicationWillTerminate から呼ばれるセーフティネット。
    /// study() 自体が毎回ファイル保存するので通常は冗長だが、deactivateServer が
    /// 呼ばれずに終了するケース（プロセスkill等）への備えとして残す。
    static func saveStudyDictIfNeeded() {
        shared?.ws?.finish()
    }

    static func reloadConnectionDictionary() {
        shared?.reloadConnectionDictionary()
    }

    private func reloadConnectionDictionary() {
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
        inputPat = ""
        candidates = []
        nthCand = 0
        searchMode = 0
        clipboardCandidate = nil
        selectedCandidate = nil
        pendingGoogleQuery = nil
        pendingAIRerankQuery = nil
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

        let keyCode = event.keyCode
        let modifierFlags = event.modifierFlags
        Log.input.debug("keyDown: keyCode=\(keyCode), chars=\(event.characters ?? ""), mods=\(modifierFlags.rawValue)")

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

        // Manual AI shortcut while converting:
        // - Tab: candidate generation + rerank
        // Shift+Tab no longer reranks current candidates because normal input already
        // applies fast-context rerank continuously.
        if converting, event.keyCode == 48 {
            if modifierFlags.contains(.shift) { return true }
            requestAIRerankIfAvailable(client: sender)
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
                captureExternalCandidates(client: sender)
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
            case aiRerank
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

        // Manual AI shortcut: Tab reranks with candidate generation.
        // Shift+Tab is consumed as a no-op; backtick is handled as a printable
        // Google Transliterate suffix below.
        if converting, keyCode == 48 {
            if modifierFlags.contains(.shift) {
                return HandleResult(handled: true, action: .none)
            }
            return HandleResult(handled: true, action: .aiRerank)
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

    /// Check if a string is a valid external candidate (not a Gyazo hash, URL, or code-like identifier).
    static func isValidExternalCandidate(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if ImageManager.isImageCandidate(trimmed) { return false }
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http") { return false }
        if lowercased.contains("://") { return false }
        if isCodeLikeExternalCandidate(trimmed) { return false }
        return true
    }

    static func isExternalCandidateAllowed(forInput inputPat: String) -> Bool {
        !inputPat.contains { character in
            character == "?" || character == "？" || character == "!" || character == "！"
        }
    }

    private static func isCodeLikeExternalCandidate(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { $0.value == 0x5F }) else { return false } // "_"
        return scalars.allSatisfy { scalar in
            (0x41...0x5A).contains(scalar.value)
                || (0x61...0x7A).contains(scalar.value)
                || (0x30...0x39).contains(scalar.value)
                || scalar.value == 0x5F
        }
    }

    /// Build prefix-mode candidate list with external candidates injected.
    /// Extracted for testability.
    static func buildPrefixCandidates(
        searchResults: [SearchCandidate],
        inputPat: String,
        clipboardCandidate: String?,
        selectedCandidate: String?,
        hiragana: String,
        context: String? = nil,
        fastContextRerankEnabled: Bool = true
    ) -> [SearchCandidate] {
        var candidates: [SearchCandidate] = [SearchCandidate(word: inputPat, kind: .raw)]

        // Keep raw input as the selected candidate in prefix mode. This preserves the
        // historical safety behavior: plain Enter does not accidentally commit a long
        // prefix match such as "gu" -> "具体的" or "maeno" -> "前のめり".
        // External candidates follow raw input so they appear at the top of the
        // candidate window, matching the original Gyaim registration workflow.
        let externalAllowedForInput = isExternalCandidateAllowed(forInput: inputPat)
        if let clip = clipboardCandidate {
            if externalAllowedForInput && isValidExternalCandidate(clip) {
                candidates.append(SearchCandidate(word: clip, source: .external, kind: .exact))
            } else if isFastContextRerankLoggingEnabled {
                Log.input.info("External clipboard candidate rejected: \"\(clip.prefix(50))\"")
            }
        }

        if let sel = selectedCandidate {
            if externalAllowedForInput && isValidExternalCandidate(sel) {
                candidates.append(SearchCandidate(word: sel, source: .external, kind: .exact))
            } else if isFastContextRerankLoggingEnabled {
                Log.input.info("External selected-text candidate rejected: \"\(sel.prefix(50))\"")
            }
        }

        let shouldFastContextRerank = fastContextRerankEnabled && isFastContextRerankEnabled
        if isFastContextRerankLoggingEnabled, !shouldFastContextRerank {
            Log.input.info(
                "Fast context rerank skipped: input=\"\(inputPat)\" "
                    + "enabled=\(isFastContextRerankEnabled) testHook=\(fastContextRerankEnabled)"
            )
        }
        let dictionaryCandidates = shouldFastContextRerank
            ? fastContextRerank(searchResults, inputPat: inputPat, hiragana: hiragana, context: context)
            : searchResults
        candidates.append(contentsOf: dictionaryCandidates)

        // Add hiragana if few candidates
        if candidates.count < CandidateDisplayMode.current.maxVisible, !hiragana.isEmpty {
            candidates.append(SearchCandidate(word: hiragana, reading: inputPat, kind: .kana))
        }

        // Deduplicate preserving order
        var seen: Set<String> = []
        candidates = candidates.filter { c in
            if seen.contains(c.word) { return false }
            seen.insert(c.word)
            return true
        }

        return candidates
    }

    private static func fastContextRerank(_ searchResults: [SearchCandidate],
                                          inputPat: String,
                                          hiragana: String,
                                          context: String?) -> [SearchCandidate] {
        guard searchResults.count >= 2 else {
            if isFastContextRerankLoggingEnabled {
                Log.input.info(
                    "Fast context rerank skipped: input=\"\(inputPat)\" "
                        + "reason=too-few-dictionary-candidates count=\(searchResults.count)"
                )
            }
            return searchResults
        }

        let start = CFAbsoluteTimeGetCurrent()
        let maxFastRerankCandidates = Self.maxFastContextRerankCandidates()
        let head = Array(searchResults.prefix(maxFastRerankCandidates))
        let tail = Array(searchResults.dropFirst(maxFastRerankCandidates))
        let trimmedContext = limitedFastContext(context)
        let request = AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: inputPat,
            hiragana: hiragana,
            context: trimmedContext.isEmpty ? nil : trimmedContext,
            candidates: head.enumerated().map { index, candidate in
                AIRerankCandidate(index: index,
                                  text: candidate.word,
                                  reading: candidate.reading,
                                  source: String(describing: candidate.source),
                                  kind: candidate.kind.rawValue,
                                  contextAffinity: ContextDict.shared.affinity(context: trimmedContext,
                                                                               reading: candidate.reading,
                                                                               word: candidate.word),
                                  studyFrequency: candidate.studyFrequency)
            }
        )
        let response = fastContextRerankResponse(for: request)
        let rerankedHead = AIReranker.apply(order: response.order, to: head)
        if isFastContextRerankLoggingEnabled {
            let elapsed = elapsedMilliseconds(since: start)
            let beforeTop = head.prefix(8).map(\.word)
            let afterTop = rerankedHead.prefix(8).map(\.word)
            let model = response.model ?? "unknown"
            Log.input.info(
                "Fast context rerank finished: input=\"\(inputPat)\" "
                    + "model=\(model) outcome=\(fastContextRerankOutcome(model: model)) "
                    + "topChanged=\(beforeTop != afterTop) candidates=\(head.count)/\(searchResults.count) "
                    + "context=\(trimmedContext.isEmpty ? "none" : "present") "
                    + "order=\(response.order) before=\(beforeTop) after=\(afterTop) "
                    + "latency=\(formatMilliseconds(elapsed))ms"
            )
        }
        return rerankedHead + tail
    }

    private static func fastContextRerankResponse(for request: AIRerankRequest) -> AIRerankResponse {
        if shouldUseModelForFastContextRerank(inputPat: request.inputPat) {
            return InProcessAIReranker.shared.rerank(request)
        }
        return AIReranker.localRerank(request, model: "swift-fast-context-heuristic")
    }

    static var isFastContextRerankEnabled: Bool {
        GyaimSettings.bool(forKey: "aiRerankFastContextEnabled", default: true)
    }

    static func setFastContextRerankEnabled(_ value: Bool) {
        GyaimSettings.set(value, forKey: "aiRerankFastContextEnabled")
    }

    static var isFastContextRerankModelEnabled: Bool {
        GyaimSettings.bool(forKey: "aiRerankUseModelForFastContext")
    }

    static func setFastContextRerankModelEnabled(_ value: Bool) {
        GyaimSettings.set(value, forKey: "aiRerankUseModelForFastContext")
    }

    static var isFastContextRerankLoggingEnabled: Bool {
        GyaimSettings.bool(forKey: "aiRerankFastContextLoggingEnabled")
    }

    static func setFastContextRerankLoggingEnabled(_ value: Bool) {
        GyaimSettings.set(value, forKey: "aiRerankFastContextLoggingEnabled")
    }

    private static func shouldUseModelForFastContextRerank(inputPat: String) -> Bool {
        guard isFastContextRerankModelEnabled else { return false }
        return inputPat.count >= minFastContextModelInputLength()
    }

    private static func fastContextRerankOutcome(model: String) -> String {
        if model.contains("review-affinity-skipped") { return "affinity-skip" }
        if model.contains("review-length-skipped") { return "short-input-skip" }
        if model.contains("review-skipped") { return "protected-exact-skip" }
        if model.contains("review-exact-homophone-unavailable") { return "exact-homophone-unavailable" }
        if model.contains("review-exact-homophone-fixed") { return "exact-homophone-fixed" }
        if model.contains("review-exact-homophone-kept-local") { return "exact-homophone-kept-local" }
        if model.contains("review-exact-homophone-passed") { return "exact-homophone-passed" }
        if model.contains("review-unavailable") { return "review-unavailable" }
        if model.contains("review-fixed") { return "review-fixed" }
        if model.contains("review-kept-local") { return "review-kept-local" }
        if model.contains("review-passed") { return "review-passed" }
        if model.contains("review") { return "review-applied" }
        if model.contains("swift-fast-context-heuristic") { return "heuristic" }
        return "fallback"
    }

    private static func minFastContextModelInputLength() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankFastContextModelMinInputLength")
        guard configured > 0 else { return 4 }
        return min(max(configured, 1), 12)
    }

    private static func limitedFastContext(_ context: String?) -> String {
        let trimmed = context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        let configured = GyaimSettings.integer(forKey: "aiRerankFastContextMaxContextLength")
        let limit = configured > 0 ? min(max(configured, 1), 200) : 20
        return String(trimmed.suffix(limit))
    }

    private static func maxFastContextRerankCandidates() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankFastContextCandidateLimit")
        guard configured > 0 else { return 24 }
        return min(max(configured, 2), 48)
    }

    // MARK: - Search & Display

    /// Trigger Google Transliterate for the current inputPat.
    /// Called by either suffix trigger (e.g. "meguro`") or shortcut (e.g. Ctrl+G).
    private func triggerGoogleTransliterate(query: String? = nil, client sender: Any? = nil) {
        let q = query ?? inputPat
        guard !q.isEmpty else { return }

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

    private func searchAndShowCands(client sender: Any?) {
        guard let ws else { return }

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
            let hiragana = rk.roma2hiragana(inputPat)
            candidates = Self.buildPrefixCandidates(
                searchResults: searchResults,
                inputPat: inputPat,
                clipboardCandidate: clipboardCandidate,
                selectedCandidate: selectedCandidate,
                hiragana: hiragana,
                context: recentCommittedText
            )
        }

        nthCand = 0
        showCands(client: sender)
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

    private func requestAIRerankIfAvailable(client sender: Any?) {
        guard searchMode == 0,
              !inputPat.isEmpty else { return }

        let query = inputPat
        pendingAIRerankQuery = query
        pendingAIRerankRevision += 1
        let localRevision = pendingAIRerankRevision

        // Stage 1: local generation + rerank immediately. This keeps Tab responsive even
        // when Google Input Tools takes a few hundred milliseconds.
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        let baseStart = CFAbsoluteTimeGetCurrent()
        let generatedSnapshot = CandidateGenerator().generate(inputPat: query,
                                                              context: recentCommittedText,
                                                              baseCandidates: candidates,
                                                              wordSearch: ws)
        let baseMs = Self.elapsedMilliseconds(since: baseStart)

        let zenzGenerationStart = CFAbsoluteTimeGetCurrent()
        let zenzGeneratedSnapshot = Self.appendingZenzGeneratedCandidates(to: generatedSnapshot,
                                                                         query: query,
                                                                         hiragana: rk.roma2hiragana(query),
                                                                         context: recentCommittedText)
        let zenzGenerationMs = Self.elapsedMilliseconds(since: zenzGenerationStart)

        let reviewStart = CFAbsoluteTimeGetCurrent()
        let localSnapshot = Self.appendingZenzAlternativeCandidates(to: zenzGeneratedSnapshot,
                                                                   query: query,
                                                                   hiragana: rk.roma2hiragana(query),
                                                                   context: recentCommittedText,
                                                                   wordSearch: ws)
        let reviewMs = Self.elapsedMilliseconds(since: reviewStart)
        let totalMs = Self.elapsedMilliseconds(since: pipelineStart)
        Log.input.info("AI candidate pipeline finished: input=\"\(query)\" "
            + "baseCandidates=\(generatedSnapshot.count) zenzGenerated=\(zenzGeneratedSnapshot.count - generatedSnapshot.count) "
            + "reviewAdded=\(localSnapshot.count - zenzGeneratedSnapshot.count) finalCandidates=\(localSnapshot.count) "
            + "baseMs=\(Self.formatMilliseconds(baseMs)) zenzGenerationMs=\(Self.formatMilliseconds(zenzGenerationMs)) "
            + "reviewMs=\(Self.formatMilliseconds(reviewMs)) totalMs=\(Self.formatMilliseconds(totalMs))")
        sendAIRerankRequest(query: query,
                            snapshot: localSnapshot,
                            revision: localRevision,
                            modeLabel: "generated-local",
                            client: sender)

        let googleEnabled = GyaimSettings.bool(forKey: "aiRerankUseGoogle")
        guard googleEnabled else { return }

        // Stage 2: optional Google live update. Disabled by default because a second
        // candidate-window update is visually disruptive during conversion.
        Log.input.info("AI rerank Google request: input=\"\(query)\"")
        let googleStart = CFAbsoluteTimeGetCurrent()
        GoogleTransliterate.searchCands(query) { [weak self] googleWords in
            guard let self else { return }
            guard self.pendingAIRerankQuery == query,
                  self.inputPat == query,
                  self.searchMode == 0 else {
                Log.input.debug("AI rerank Google result discarded for stale query \"\(query)\"")
                return
            }

            let googleElapsed = (CFAbsoluteTimeGetCurrent() - googleStart) * 1000
            Log.input.info("AI rerank Google response: input=\"\(query)\" count=\(googleWords.count) latency=\(String(format: "%.1f", googleElapsed))ms")

            var seed = self.candidates
            var seen = Set(seed.map(\.word))
            for word in googleWords where seen.insert(word).inserted {
                seed.append(SearchCandidate(word: word, reading: query, source: .google, kind: .google))
            }
            self.pendingAIRerankRevision += 1
            let googleRevision = self.pendingAIRerankRevision
            let snapshot = CandidateGenerator().generate(inputPat: query,
                                                         context: self.recentCommittedText,
                                                         baseCandidates: seed,
                                                         wordSearch: self.ws)
            self.sendAIRerankRequest(query: query,
                                     snapshot: snapshot,
                                     revision: googleRevision,
                                     modeLabel: "generated-google",
                                     client: sender)
        }
    }

    private static func appendingZenzGeneratedCandidates(to snapshot: [SearchCandidate],
                                                         query: String,
                                                         hiragana: String,
                                                         context: String) -> [SearchCandidate] {
        var result = snapshot
        var seen = Set(snapshot.map(\.word))
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let generated = InProcessAIReranker.shared.generateCandidates(inputPat: query,
                                                                      hiragana: hiragana,
                                                                      context: trimmedContext.isEmpty ? nil : trimmedContext,
                                                                      limit: 1)
        for candidate in generated where seen.insert(candidate.word).inserted {
            result.append(candidate)
        }
        return result
    }

    private static func appendingZenzAlternativeCandidates(to snapshot: [SearchCandidate],
                                                           query: String,
                                                           hiragana: String,
                                                           context: String,
                                                           wordSearch: WordSearch?) -> [SearchCandidate] {
        var result = snapshot
        var seen = Set(snapshot.map(\.word))
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxReviewRounds = Self.zenzReviewRounds()
        let alternativeLimit = Self.zenzAlternativeLimit()

        for round in 0..<maxReviewRounds {
            let request = AIRerankRequest(version: 1,
                                          mode: "alternative-review-\(round + 1)",
                                          inputPat: query,
                                          hiragana: hiragana,
                                          context: trimmedContext.isEmpty ? nil : trimmedContext,
                                          candidates: result.enumerated().map { index, candidate in
                                              AIRerankCandidate(index: index,
                                                                text: candidate.word,
                                                                reading: candidate.reading,
                                                                source: String(describing: candidate.source),
                                                                kind: candidate.kind.rawValue)
                                          })
            let alternatives = InProcessAIReranker.shared.alternativeCandidates(for: request, limit: alternativeLimit)
            guard !alternatives.isEmpty else { break }

            var appended = 0
            for prefix in alternatives {
                let constrained = CandidateGenerator(compoundLimit: 4, completionLimit: 0)
                    .generate(inputPat: query,
                              context: context,
                              baseCandidates: [],
                              wordSearch: wordSearch,
                              surfacePrefixes: [prefix.word])
                for candidate in constrained where seen.insert(candidate.word).inserted {
                    result.append(candidate)
                    appended += 1
                }
            }
            guard appended > 0 else { break }
        }
        return result
    }

    private static func zenzReviewRounds() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankZenzReviewRounds")
        return configured > 0 ? min(configured, 3) : 2
    }

    private static func zenzAlternativeLimit() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankZenzAlternativeLimit")
        return configured > 0 ? min(configured, 4) : 2
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func sendAIRerankRequest(query: String,
                                     snapshot: [SearchCandidate],
                                     revision: Int,
                                     modeLabel: String,
                                     client sender: Any?) {
        let snapshot = limitedAISnapshot(snapshot, query: query)
        guard snapshot.count >= 2 else { return }
        let context = recentCommittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: query,
            hiragana: rk.roma2hiragana(query),
            context: context.isEmpty ? nil : context,
            candidates: snapshot.enumerated().map { index, candidate in
                AIRerankCandidate(index: index,
                                  text: candidate.word,
                                  reading: candidate.reading,
                                  source: String(describing: candidate.source),
                                  kind: candidate.kind.rawValue,
                                  contextAffinity: ContextDict.shared.affinity(context: context,
                                                                               reading: candidate.reading,
                                                                               word: candidate.word),
                                  studyFrequency: candidate.studyFrequency)
            }
        )

        let requestStart = CFAbsoluteTimeGetCurrent()
        let handleResult: (Result<AIRerankResponse, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.pendingAIRerankQuery == query,
                      self.pendingAIRerankRevision == revision,
                      self.inputPat == query,
                      self.searchMode == 0 else {
                    Log.input.debug("AI rerank stale result discarded for \"\(query)\"")
                    return
                }

                switch result {
                case .success(let response):
                    let order = AIReranker.validatedOrder(response.order, candidateCount: snapshot.count)
                    let reranked = order.map { snapshot[$0] }
                    let rawCandidate = snapshot.first { $0.word == query } ?? SearchCandidate(word: query, kind: .raw)
                    self.candidates = [rawCandidate] + reranked.filter { $0.word != query }
                    self.nthCand = 0
                    let elapsed = (CFAbsoluteTimeGetCurrent() - requestStart) * 1000
                    Log.input.info("AI rerank applied: mode=\(modeLabel) input=\"\(query)\" model=\(response.model ?? "unknown") order=\(order) latency=\(String(format: "%.1f", elapsed))ms")
                    self.showCands(client: sender)
                    self.showWindow()
                case .failure(let error):
                    Log.input.warning("AI rerank failed for \"\(query)\": \(error.localizedDescription)")
                }
            }
        }

        // Fast in-process rerank: avoids Swift/Python HTTP or process boundary and
        // Legacy GPT/command rerankers run only when explicitly enabled for comparison.
        Log.input.info("AI rerank provider start: mode=\(modeLabel) provider=in-process input=\"\(query)\" candidates=\(request.candidates.count)")
        handleResult(.success(InProcessAIReranker.shared.rerank(request)))

        guard Self.shouldRunLegacyExternalAIReranker() else {
            Log.input.info("AI rerank legacy external provider skipped: mode=\(modeLabel) input=\"\(query)\"")
            return
        }

        if let httpReranker = HTTPAIReranker.configured() {
            Log.input.info("AI rerank provider start: mode=\(modeLabel) provider=http input=\"\(query)\"")
            httpReranker.rerank(request, completion: handleResult)
        } else if let commandReranker = ExternalCommandAIReranker.configured() {
            Log.input.info("AI rerank provider start: mode=\(modeLabel) provider=external-command input=\"\(query)\"")
            commandReranker.rerank(request, completion: handleResult)
        }
    }

    private static func shouldRunLegacyExternalAIReranker() -> Bool {
        GyaimSettings.bool(forKey: "aiRerankUseLegacyExternalReranker")
    }

    private func limitedAISnapshot(_ snapshot: [SearchCandidate], query: String) -> [SearchCandidate] {
        let maxAIRerankCandidates = 48
        guard snapshot.count > maxAIRerankCandidates else { return snapshot }

        var result: [SearchCandidate] = []
        var seen = Set<String>()
        func append(_ candidate: SearchCandidate) {
            if result.count < maxAIRerankCandidates, seen.insert(candidate.word).inserted {
                result.append(candidate)
            }
        }

        if let raw = snapshot.first(where: { $0.word == query }) {
            append(raw)
        } else {
            append(SearchCandidate(word: query, kind: .raw))
        }
        snapshot.filter { $0.source == .google }.forEach(append)
        snapshot.filter { $0.source != .google && $0.word != query }.forEach(append)
        return result
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
        ws?.study(word: word, reading: inputPat)
        recordCommittedText(word)
        resetState()
        hideWindow()
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

        // Accepted-rank metric for dogfood evaluation: which rank the user
        // actually committed. rank=0 is the raw input; rank=1 is the first
        // displayed candidate. Aggregated by aggregate-fast-context-log.py.
        if Self.isFastContextRerankLoggingEnabled, !skipStudy, searchMode == 0 {
            Log.input.info("Fast context accepted: input=\"\(self.inputPat)\" word=\"\(word)\" "
                + "rank=\(self.nthCand) candidates=\(self.candidates.count) "
                + "source=\(String(describing: candidate.source)) kind=\(candidate.kind.rawValue)")
        }

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

        // Register or study logic (skip when deactivating — user didn't intentionally select)
        if skipStudy {
            Log.input.info("Study skipped (deactivation): \"\(word)\" (reading: \"\(reading)\")")
        } else {
            let isExternalCandidate = (word == clipboardCandidate || word == selectedCandidate)
            if isExternalCandidate {
                // External candidate (clipboard/selected text) → register to user dict only when the reading is safe.
                if Self.isExternalCandidateAllowed(forInput: inputPat), Self.isValidExternalCandidate(word) {
                    ws?.register(word: word, reading: inputPat)
                    Log.input.info("Registered to user dict: \"\(word)\" (reading: \"\(inputPat)\")")
                } else {
                    Log.input.info("External candidate registration skipped: \"\(word.prefix(50))\" (reading: \"\(inputPat)\")")
                }
            } else if let reading = candidate.reading {
                if reading != "ds" {
                    ws?.study(word: word, reading: reading)
                    ContextDict.shared.record(context: recentCommittedText, reading: reading, word: word)
                    Log.input.info("Studied: \"\(word)\" (reading: \"\(reading)\")")
                }
            } else {
                if inputPat != "ds" {
                    ws?.study(word: word, reading: inputPat)
                    ContextDict.shared.record(context: recentCommittedText, reading: inputPat, word: word)
                    Log.input.info("Studied: \"\(word)\" (reading: \"\(inputPat)\")")
                }
            }
        }

        if !skipStudy {
            recordCommittedText(word)
        }
        resetState()
        hideWindow()
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
        Log.ui.info("showWindow: reportedLineRect=\(reportedLineRect) "
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
