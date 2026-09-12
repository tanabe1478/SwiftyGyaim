import Cocoa

/// Review window for suspicious study-dictionary entries (issue #58).
/// Lists StudySuspects results; the user selects rows and deletes them from
/// the shared study dictionary (and ContextDict) in one step.
final class StudySuspectsWindow: NSWindow, NSTableViewDataSource, NSTableViewDelegate {
    static var shared: StudySuspectsWindow?

    private var suspects: [StudySuspects.Suspect] = []
    private let tableView = NSTableView()
    private let summaryLabel = NSTextField(labelWithString: "")

    static func show() {
        if shared == nil {
            shared = StudySuspectsWindow()
        }
        shared?.reload()
        shared?.level = .floating
        shared?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        super.init(contentRect: frame,
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered,
                   defer: false)
        title = "疑わしい学習エントリ"
        center()
        isReleasedWhenClosed = false
        minSize = NSSize(width: 480, height: 300)

        let container = NSView(frame: frame)
        contentView = container

        for (identifier, title, width) in [("reading", "読み", 120), ("word", "単語", 140),
                                           ("frequency", "頻度", 50), ("reason", "理由", 300)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = CGFloat(width)
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.headerView = NSTableHeaderView()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        summaryLabel.font = NSFont.systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(summaryLabel)

        let deleteButton = NSButton(title: "選択したエントリを削除", target: self, action: #selector(deleteSelected))
        deleteButton.bezelStyle = .rounded
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(deleteButton)

        let reloadButton = NSButton(title: "再検出", target: self, action: #selector(reload))
        reloadButton.bezelStyle = .rounded
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(reloadButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: summaryLabel.topAnchor, constant: -8),
            summaryLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            summaryLabel.bottomAnchor.constraint(equalTo: deleteButton.topAnchor, constant: -8),
            deleteButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            deleteButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            reloadButton.leadingAnchor.constraint(equalTo: deleteButton.trailingAnchor, constant: 8),
            reloadButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
    }

    override func close() {
        super.close()
        NSApp.setActivationPolicy(.prohibited)
    }

    // MARK: - Data

    @objc func reload() {
        suspects = StudySuspects.find(in: WordSearch.studyDict)
        tableView.reloadData()
        let garbage = suspects.filter { $0.reason == .garbageCompletion }.count
        summaryLabel.stringValue = "\(WordSearch.studyDict.count) 件中 \(suspects.count) 件（末尾1文字付き \(garbage)、長期未使用 \(suspects.count - garbage)）。"
            + "削除は手動確認のうえで行ってください。"
    }

    @objc private func deleteSelected() {
        let targets = tableView.selectedRowIndexes.compactMap { suspects[safe: $0]?.entry }
        guard !targets.isEmpty else { return }
        WordSearch.deleteStudyEntries(targets)
        reload()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { suspects.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let suspect = suspects[safe: row] else { return nil }
        switch tableColumn?.identifier.rawValue {
        case "reading": return suspect.entry.reading
        case "word": return suspect.entry.word
        case "frequency": return String(suspect.entry.frequency)
        case "reason": return "\(suspect.reason.label): \(suspect.detail)"
        default: return nil
        }
    }
}
