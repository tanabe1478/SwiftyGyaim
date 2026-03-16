import Cocoa
import Carbon.HIToolbox

class DialogHelper: NSObject {
    @objc func confirmAction() {
        NSApp.stopModal()
    }

    @objc func cancelAction(_ sender: NSPanel) {
        sender.close()
    }
}

let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "入力:"
let helper = DialogHelper()

// Save current input source and switch to ASCII
let originalInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
if let asciiSource = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
    TISSelectInputSource(asciiSource)
}

func restoreInputSource() {
    if let original = originalInputSource {
        TISSelectInputSource(original)
    }
}

NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.activate(ignoringOtherApps: true)

let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
panel.title = "Gyaim"
panel.level = .floating
panel.isReleasedWhenClosed = false

let label = NSTextField(labelWithString: prompt)
label.frame = NSRect(x: 20, y: 80, width: 300, height: 20)
panel.contentView?.addSubview(label)

let field = NSTextField(frame: NSRect(x: 20, y: 48, width: 300, height: 24))
panel.contentView?.addSubview(field)

let ok = NSButton(frame: NSRect(x: 240, y: 10, width: 80, height: 32))
ok.title = "OK"
ok.bezelStyle = .rounded
ok.keyEquivalent = "\r"
ok.target = helper
ok.action = #selector(DialogHelper.confirmAction)
panel.contentView?.addSubview(ok)

let cancel = NSButton(frame: NSRect(x: 150, y: 10, width: 80, height: 32))
cancel.title = "Cancel"
cancel.bezelStyle = .rounded
cancel.keyEquivalent = "\u{1b}"
cancel.target = panel
cancel.action = #selector(NSPanel.close)
panel.contentView?.addSubview(cancel)

// Close panel → stop modal loop
let observer = NotificationCenter.default.addObserver(
    forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
    NSApp.stopModal()
}

panel.center()
panel.makeKeyAndOrderFront(nil)
panel.makeFirstResponder(field)

NSApp.runModal(for: panel)
NotificationCenter.default.removeObserver(observer)

// If panel was closed (Cancel or close button), exit 1
if !panel.isVisible {
    restoreInputSource()
    exit(1)
}

let value = field.stringValue
if value.isEmpty {
    restoreInputSource()
    exit(1)
}
restoreInputSource()
print(value)
exit(0)
