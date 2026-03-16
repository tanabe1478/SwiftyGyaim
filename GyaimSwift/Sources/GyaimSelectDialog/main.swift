import Cocoa
import Carbon.HIToolbox
import LocalAuthentication

// Read items from stdin (one per line)
var items: [String] = []
while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        items.append(trimmed)
    }
}

guard !items.isEmpty else {
    fputs("No items provided on stdin\n", stderr)
    exit(1)
}

let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "選択:"

// Save current input source and switch to ASCII to prevent IME from intercepting keys
let originalInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
if let asciiSource = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
    TISSelectInputSource(asciiSource)
}

func restoreInputSource() {
    if let original = originalInputSource {
        TISSelectInputSource(original)
    }
}

class SelectTableView: NSTableView {
    var onConfirm: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Enter/Return → confirm instead of editing cell
        if event.keyCode == 36 || event.keyCode == 76 {
            onConfirm?()
            return
        }
        super.keyDown(with: event)
    }
}

class SelectDialogHelper: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let items: [String]
    weak var panel: NSPanel?
    var selectedItem: String?

    init(items: [String]) {
        self.items = items
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        items[row]
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        24
    }

    @objc func confirmAction() {
        NSApp.stopModal()
    }

    @objc func cancelAction() {
        panel?.close()
    }

    @objc func doubleClickAction(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < items.count else { return }
        selectedItem = items[row]
        NSApp.stopModal()
    }
}

let helper = SelectDialogHelper(items: items)

NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.activate(ignoringOtherApps: true)

// Layout constants
let panelWidth: CGFloat = 360
let margin: CGFloat = 20
let buttonHeight: CGFloat = 32
let buttonAreaHeight: CGFloat = buttonHeight + 20 // buttons + padding
let promptHeight: CGFloat = 20
let promptPadding: CGFloat = 10
let listHeight = min(CGFloat(items.count) * 24 + 4, 300.0) // +4 for border
let panelHeight = buttonAreaHeight + listHeight + promptPadding + promptHeight + margin

let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
panel.title = "Gyaim"
panel.level = .floating
panel.isReleasedWhenClosed = false
helper.panel = panel

// Prompt label at top
let label = NSTextField(labelWithString: prompt)
label.frame = NSRect(x: margin, y: panelHeight - margin - promptHeight,
                     width: panelWidth - margin * 2, height: promptHeight)
panel.contentView?.addSubview(label)

// Scroll view with table in the middle
let scrollY = buttonAreaHeight
let scrollView = NSScrollView(frame: NSRect(x: margin, y: scrollY,
                                            width: panelWidth - margin * 2, height: listHeight))
scrollView.hasVerticalScroller = true
scrollView.autohidesScrollers = true
scrollView.borderType = .bezelBorder

let tableView = SelectTableView()
tableView.onConfirm = { helper.confirmAction() }
let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
column.title = ""
column.width = panelWidth - margin * 2 - 20
column.isEditable = false
tableView.addTableColumn(column)
tableView.headerView = nil
tableView.rowHeight = 24
tableView.dataSource = helper
tableView.delegate = helper
tableView.doubleAction = #selector(SelectDialogHelper.doubleClickAction(_:))
tableView.target = helper

scrollView.documentView = tableView
panel.contentView?.addSubview(scrollView)

// Buttons at bottom
let ok = NSButton(frame: NSRect(x: panelWidth - margin - 80, y: 10, width: 80, height: buttonHeight))
ok.title = "OK"
ok.bezelStyle = .rounded
ok.keyEquivalent = "\r"
ok.target = helper
ok.action = #selector(SelectDialogHelper.confirmAction)
panel.contentView?.addSubview(ok)

let cancel = NSButton(frame: NSRect(x: panelWidth - margin - 170, y: 10, width: 80, height: buttonHeight))
cancel.title = "Cancel"
cancel.bezelStyle = .rounded
cancel.keyEquivalent = "\u{1b}"
cancel.target = helper
cancel.action = #selector(SelectDialogHelper.cancelAction)
panel.contentView?.addSubview(cancel)

let observer = NotificationCenter.default.addObserver(
    forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
    NSApp.stopModal()
}

// Select first item by default
if !items.isEmpty {
    tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
}

panel.center()
panel.makeKeyAndOrderFront(nil)
panel.makeFirstResponder(tableView)

NSApp.runModal(for: panel)
NotificationCenter.default.removeObserver(observer)

// If closed via Cancel
if !panel.isVisible {
    restoreInputSource()
    exit(1)
}

// Get selection from double-click or table selection
let selected = helper.selectedItem ?? {
    let row = tableView.selectedRow
    guard row >= 0, row < items.count else { return nil }
    return items[row]
}()

guard let result = selected, !result.isEmpty else {
    restoreInputSource()
    exit(1)
}

// Authenticate before returning the selection
let context = LAContext()
var authError: NSError?
if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
    let semaphore = DispatchSemaphore(value: 0)
    var authSuccess = false
    context.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "復号化のために認証が必要です") { success, _ in
        authSuccess = success
        semaphore.signal()
    }
    semaphore.wait()
    if !authSuccess {
        restoreInputSource()
        exit(1)
    }
} else {
    fputs("Authentication not available: \(authError?.localizedDescription ?? "unknown")\n", stderr)
    restoreInputSource()
    exit(1)
}

restoreInputSource()
print(result)
exit(0)
