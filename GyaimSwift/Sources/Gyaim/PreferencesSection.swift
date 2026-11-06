import Cocoa

/// An NSButton that forwards its action to a closure. Target/action are kept
/// so tests can drive it with `sendAction(_:to:)` like any other control.
final class ClosureButton: NSButton {
    var onClick: ((ClosureButton) -> Void)?

    static func checkbox(_ title: String, isOn: Bool, onClick: @escaping (Bool) -> Void) -> ClosureButton {
        let button = ClosureButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = isOn ? .on : .off
        button.onClick = { onClick($0.state == .on) }
        button.target = button
        button.action = #selector(fire)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    static func push(_ title: String, onClick: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.onClick = { _ in onClick() }
        button.target = button
        button.action = #selector(fire)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    @objc private func fire() {
        onClick?(self)
    }
}

/// An NSSegmentedControl that forwards the selected segment to a closure.
final class ClosureSegmentedControl: NSSegmentedControl {
    var onSelect: ((Int) -> Void)?

    static func make(labels: [String], selected: Int, onSelect: @escaping (Int) -> Void) -> ClosureSegmentedControl {
        let control = ClosureSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = selected
        control.onSelect = onSelect
        control.target = control
        control.action = #selector(fire)
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }

    @objc private func fire() {
        onSelect?(selectedSegment)
    }
}

/// One titled block of the preferences window. Rows are stacked vertically;
/// subclasses create their controls, call `super.init(title:)`, then add rows,
/// and re-read settings in `reload()`. Every control writes its setting the
/// moment it changes (ADR-027 keeps a single write target, so there is
/// nothing to batch up for a Save button).
class PreferencesSection: NSView {
    let sectionTitle: String
    /// Width available to rows; hints wrap at this width instead of being cut off.
    static let rowWidth: CGFloat = PreferencesWindow.contentWidth - 2 * PreferencesWindow.contentInset
    private static let indentWidth: CGFloat = 18
    private let rows = NSStackView()

    init(title: String) {
        sectionTitle = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.rowWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Re-read every setting this section shows (after reset to defaults).
    func reload() {}

    // MARK: - Row builders

    func addRow(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        rows.addArrangedSubview(view)
    }

    /// A row that spans the section width (shortcut lists, wrapped hints).
    func addFullWidthRow(_ view: NSView) {
        addRow(view)
        view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    /// A row pushed in under the control it belongs to.
    func addIndentedRow(_ view: NSView) {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: Self.indentWidth).isActive = true
        let line = NSStackView(views: [spacer, view])
        line.orientation = .horizontal
        line.alignment = .top
        line.spacing = 0
        addFullWidthRow(line)
    }

    /// Label + control on one line.
    func addLabeledRow(_ label: String, _ control: NSView, trailing: NSView? = nil) {
        let text = NSTextField(labelWithString: label)
        addControlsRow([text, control] + (trailing.map { [$0] } ?? []))
    }

    /// Controls on one line, left aligned.
    func addControlsRow(_ controls: [NSView]) {
        let line = NSStackView(views: controls)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 8
        addRow(line)
    }

    /// Secondary 11 pt explanation under a control. Wraps instead of truncating.
    @discardableResult
    func addHint(_ text: String, indent: Bool = true) -> NSTextField {
        let label = Self.makeHintLabel(text)
        label.preferredMaxLayoutWidth = Self.rowWidth - (indent ? Self.indentWidth : 0)
        if indent {
            addIndentedRow(label)
        } else {
            addFullWidthRow(label)
        }
        return label
    }

    static func makeHintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    static func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
