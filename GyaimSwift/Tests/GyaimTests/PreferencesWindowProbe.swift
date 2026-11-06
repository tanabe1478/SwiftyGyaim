@testable import Gyaim
import XCTest

/// Finds controls in a PreferencesWindow by walking its view hierarchy, the
/// way a user would see them (titles, segment counts), not by internal names.
struct PreferencesWindowProbe {
    let window: PreferencesWindow

    func checkbox(titled title: String) -> NSButton? {
        all(NSButton.self).first { $0.title == title }
    }

    func button(titled title: String) -> NSButton? {
        all(NSButton.self).first { $0.title == title }
    }

    var displayModeControl: NSSegmentedControl? {
        all(NSSegmentedControl.self).first { $0.segmentCount == 2 }
    }

    var evictionModeControl: NSSegmentedControl? {
        all(NSSegmentedControl.self).first { $0.segmentCount == 3 }
    }

    func label(containing text: String) -> NSTextField? {
        all(NSTextField.self).first { $0.stringValue.contains(text) }
    }

    /// Every view of type `T` in the window, depth first in subview order.
    func all<T: NSView>(_ type: T.Type) -> [T] {
        guard let contentView = window.contentView else { return [] }
        var result: [T] = []
        func walk(_ view: NSView) {
            for subview in view.subviews {
                if let match = subview as? T { result.append(match) }
                walk(subview)
            }
        }
        walk(contentView)
        return result
    }

    func commandKeyEvent(_ key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: modifiers,
                         timestamp: 0,
                         windowNumber: window.windowNumber,
                         context: nil,
                         characters: key,
                         charactersIgnoringModifiers: key.lowercased(),
                         isARepeat: false,
                         keyCode: 0)
    }
}

/// Toggle a checkbox the way the old tests did: set the state, then fire its action.
func click(_ toggle: NSButton, to state: NSControl.StateValue) {
    toggle.state = state
    toggle.sendAction(toggle.action, to: toggle.target)
}
