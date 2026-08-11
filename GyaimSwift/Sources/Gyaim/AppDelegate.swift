import Carbon
import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var clipboardTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.setup()
        Log.config.info("Gyaim launched")
        Self.enableHiddenRomanInputModeIfNeeded()

        // Clipboard polling (60s interval)
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            CopyText.set(NSPasteboard.general.string(forType: .string))
        }
    }

    /// The Roman input mode is hidden from the input menu
    /// (tsInputModeIsVisibleKey = false), so users cannot enable it in
    /// System Settings. Enable it here so macOS has an ASCII-capable Gyaim
    /// mode to fall back to while Secure Event Input is active (issue #85).
    private static func enableHiddenRomanInputModeIfNeeded() {
        let romanSourceID = "com.pitecan.inputmethod.SwiftyGyaim.Roman"
        let filter = [kTISPropertyInputSourceID as String: romanSourceID] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
                as? [TISInputSource],
              let roman = sources.first else {
            Log.config.error("Roman input mode not found in TIS: \(romanSourceID)")
            return
        }
        if let enabledPtr = TISGetInputSourceProperty(roman, kTISPropertyInputSourceIsEnabled),
           CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enabledPtr).takeUnretainedValue()) {
            return
        }
        let status = TISEnableInputSource(roman)
        Log.config.info("Enabled hidden Roman input mode: status=\(status)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.config.info("Gyaim terminating")
        // セーフティネット: study() が毎回保存するので通常は冗長だが、
        // deactivateServer を経由しない終了ケースに備えて明示的に保存する
        GyaimController.saveStudyDictIfNeeded()
        FileLogger.shared.flush()
        clipboardTimer?.invalidate()
    }
}
