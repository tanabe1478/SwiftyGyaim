import Cocoa

/// A single row: [shortcut display] [Record button] [Remove button].
/// Reports every change through `onChange` so the owner can persist it
/// immediately; nothing waits for a Save button.
class ShortcutRecorderRow: NSView {
    var shortcut: KeyShortcut?
    var onRemove: ((ShortcutRecorderRow) -> Void)?
    var onChange: ((ShortcutRecorderRow) -> Void)?

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

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

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
        if shortcut == nil {
            displayField.stringValue = "未設定"
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        setShortcut(KeyShortcut.from(event: event))
        stopRecording()
        onChange?(self)
    }

    @objc private func removeSelf() {
        onRemove?(self)
    }
}

/// A vertical list of `ShortcutRecorderRow`s with an add button. Calls
/// `onChange` with the recorded shortcuts whenever a row is recorded, added
/// or removed. `minimumCount` rows are always kept (the hiragana / katakana
/// confirm keys must not end up with no shortcut at all).
final class ShortcutListView: NSView {
    private let stack = NSStackView()
    private let addButton: NSButton
    private(set) var rows: [ShortcutRecorderRow] = []
    private let minimumCount: Int
    var onChange: (([KeyShortcut]) -> Void)?

    init(shortcuts: [KeyShortcut], minimumCount: Int = 0) {
        self.minimumCount = minimumCount
        addButton = NSButton(title: "+ 追加", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addRow)
        stack.addArrangedSubview(addButton)
        setShortcuts(shortcuts)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Recorded shortcuts, in display order. Rows still waiting for a key are skipped.
    var shortcuts: [KeyShortcut] { rows.compactMap(\.shortcut) }

    /// Replace the rows (used by reset to defaults).
    func setShortcuts(_ shortcuts: [KeyShortcut]) {
        rows.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows = []
        for shortcut in shortcuts {
            let row = makeRow()
            row.setShortcut(shortcut)
            insert(row)
        }
    }

    private func makeRow() -> ShortcutRecorderRow {
        let row = ShortcutRecorderRow(frame: .zero)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.onRemove = { [weak self] row in self?.remove(row) }
        row.onChange = { [weak self] _ in self?.notify() }
        return row
    }

    private func insert(_ row: ShortcutRecorderRow) {
        rows.append(row)
        stack.insertArrangedSubview(row, at: rows.count - 1)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc func addRow() {
        insert(makeRow())
    }

    private func remove(_ row: ShortcutRecorderRow) {
        guard rows.count > minimumCount else { return }
        stack.removeArrangedSubview(row)
        row.removeFromSuperview()
        rows.removeAll { $0 === row }
        notify()
    }

    private func notify() {
        onChange?(shortcuts)
    }
}

/// One-character text field for a single-key binding (`;` for hiragana, `q`
/// for katakana, the Google trigger). Validates on end of editing, reverts
/// invalid input, and reports the accepted value through `onChange`.
final class SingleKeyField: NSTextField, NSTextFieldDelegate {
    /// Returns nil when `text` is not acceptable. Empty text is passed through
    /// so the caller can decide whether "no key" is allowed.
    var validate: ((String) -> String?)?
    var onChange: ((String) -> Void)?
    private var accepted: String

    init(value: String, placeholder: String) {
        accepted = value
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stringValue = value
        placeholderString = placeholder
        alignment = .center
        delegate = self
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 48)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Current accepted value (not the text being edited).
    var value: String { accepted }

    func setValue(_ value: String) {
        accepted = value
        stringValue = value
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commit()
    }

    /// Validate the typed text; keep it if acceptable, otherwise revert.
    @discardableResult
    func commit() -> Bool {
        let typed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid: String?
        if let validate {
            valid = validate(typed)
        } else {
            valid = typed
        }
        guard let valid else {
            NSSound.beep()
            stringValue = accepted
            return false
        }
        if valid != accepted {
            accepted = valid
            onChange?(valid)
        }
        stringValue = accepted
        return true
    }
}
