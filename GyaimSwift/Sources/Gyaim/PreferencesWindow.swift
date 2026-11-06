import Cocoa

/// Preferences window. Sections (`PreferencesSection` subclasses in
/// PreferencesSections.swift) are stacked vertically inside a scroll view, so
/// the window never grows past the screen. Every control saves on change;
/// the only window-level actions are "reset to defaults" and close.
class PreferencesWindow: NSWindow {
    static var shared: PreferencesWindow?

    static let contentWidth: CGFloat = 540
    static let contentInset: CGFloat = 20
    private static let bottomBarHeight: CGFloat = 52

    private let scrollView = NSScrollView()
    private let sectionsStack = NSStackView()
    private(set) var sections: [PreferencesSection] = []

    /// Settings keys that have a control in this window. "Reset to defaults"
    /// removes exactly these (plus KeyBindings), so what the window shows and
    /// what it resets stay in step.
    static let resettableKeys: [String] = [
        "candidateDisplayMode",
        "clipboardCandidateEnabled",
        "selectedTextCandidateEnabled",
        "studyDictEvictionMode",
        "studyHiraganaEnabled",
        "exactReadingMatchPriority",
        "aiRerankFastContextEnabled",
        "aiRerankUseModelForFastContext",
        "aiRerankUseBundledZenz",
        "aiRerankFastContextLoggingEnabled",
        "contextLearningEnabled",
        "googleTransliterateTrigger",
        "loggingEnabled",
    ]

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
        let frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: 600)
        super.init(contentRect: frame,
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered,
                   defer: false)
        title = "Gyaim 設定"
        isReleasedWhenClosed = false
        minSize = NSSize(width: Self.contentWidth, height: 300)
        maxSize = NSSize(width: Self.contentWidth, height: CGFloat.greatestFiniteMagnitude)

        buildUI()
        sizeToFitScreen()
        center()
    }

    override func close() {
        super.close()
        NSApp.setActivationPolicy(.prohibited)
    }

    // MARK: - Layout

    private func buildUI() {
        let root = NSView()
        contentView = root
        let document = buildScrollArea(in: root)
        let (separator, resetButton, closeButton) = buildBottomBar(in: root)

        let inset = Self.contentInset
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

            sectionsStack.topAnchor.constraint(equalTo: document.topAnchor, constant: inset),
            sectionsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: inset),
            sectionsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -inset),
            sectionsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -inset),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.bottomBarHeight),

            resetButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            resetButton.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.bottomBarHeight / 2),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            closeButton.centerYAnchor.constraint(equalTo: resetButton.centerYAnchor),
        ])
    }

    /// Scroll view with the sections stacked in a top-anchored document view.
    private func buildScrollArea(in root: NSView) -> NSView {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        root.addSubview(scrollView)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = 28
        sectionsStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(sectionsStack)

        sections = [
            KeyOperationSection(),
            CandidateSection(),
            StudySection(),
            RankingSection(),
            ConnectionDictSection(),
            LogSection(),
        ]
        sections.forEach { sectionsStack.addArrangedSubview($0) }
        return document
    }

    /// Separator plus the two window-level buttons.
    private func buildBottomBar(in root: NSView) -> (separator: NSView, reset: NSButton, close: NSButton) {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)

        let resetButton = NSButton(title: "初期値に戻す", target: self, action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(resetButton)

        let closeButton = NSButton(title: "閉じる", target: self, action: #selector(closeFromButton))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(closeButton)
        return (separator, resetButton, closeButton)
    }

    /// Height of all sections plus the bottom bar; what the window would need
    /// to show everything without scrolling.
    var preferredContentHeight: CGFloat {
        sectionsStack.layoutSubtreeIfNeeded()
        return sectionsStack.fittingSize.height + 2 * Self.contentInset + Self.bottomBarHeight
    }

    /// Open at the full content height when it fits, otherwise at 85 % of the
    /// screen and let the scroll view take over.
    private func sizeToFitScreen() {
        let screenHeight = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        let height = min(preferredContentHeight, floor(screenHeight * 0.85))
        setContentSize(NSSize(width: Self.contentWidth, height: height))
    }

    // MARK: - Actions

    @objc private func closeFromButton() {
        close()
    }

    /// Clear every setting shown here and the key bindings, then let each
    /// section re-read. Nothing is kept: a partial reset is more confusing
    /// than none.
    @objc func resetDefaults() {
        KeyBindings.shared.reset()
        Self.resettableKeys.forEach { GyaimSettings.removeObject(forKey: $0) }
        sections.forEach { $0.reload() }
    }

    // MARK: - Standard command shortcuts

    /// LSBackgroundOnly apps have no main menu, so Cmd+W / Cmd+V etc. would
    /// not reach the window without this.
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
}

/// Scroll view document whose origin is at the top, so the first section
/// sits at the top of the window instead of the bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
