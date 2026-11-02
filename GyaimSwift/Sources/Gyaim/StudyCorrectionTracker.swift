import Foundation

/// Detects a retype: the same reading committed again as a different word a
/// few seconds after the previous commit (ADR-037). The first commit was a
/// mistake the user is correcting, so the learning it caused (study frequency,
/// ContextDict entry, external-candidate registration) is undone. Without
/// this, every uncorrected mistake raises the wrong word's frequency and the
/// next commit of the same reading is even more likely to be wrong
/// (dogfood: 移行 34→39 while the user wanted 以降, 起きました 1→2).
///
/// Process-wide like `CommittedContextStore`: IMK recreates the controller on
/// focus changes, and a retype sometimes lands in a new controller.
final class StudyCorrectionTracker {
    static let shared = StudyCorrectionTracker()

    enum Learning: Equatable {
        case none
        case studied(context: String)
        case registered
    }

    struct Record: Equatable {
        /// Kana form of the reading so romaji spelling variants compare equal.
        var readingKey: String
        var reading: String
        var word: String
        var bundle: String?
        var learning: Learning
        var committedAt: Date
    }

    static let defaultWindowSeconds = 15
    static let maxWindowSeconds = 120
    static let settingsKey = "studyUndoOnRetypeSeconds"

    private let lock = NSLock()
    private var last: Record?

    static func windowSeconds(configured: Int?) -> Int {
        guard let configured else { return defaultWindowSeconds }
        return min(max(configured, 0), maxWindowSeconds)
    }

    static var configuredWindowSeconds: Int {
        guard GyaimSettings.objectExists(forKey: settingsKey) else { return defaultWindowSeconds }
        return windowSeconds(configured: GyaimSettings.integer(forKey: settingsKey))
    }

    /// The previous commit this one corrects, or nil. A correction is the same
    /// reading, a different word, within the window, in the same app (when
    /// both bundles are known). Only commits that learned something qualify.
    func correctionTarget(readingKey: String, word: String, bundle: String?,
                          now: Date = Date(), windowSeconds: Int) -> Record? {
        guard windowSeconds > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let last, last.learning != .none,
              last.readingKey == readingKey, last.word != word else { return nil }
        if let bundle, let lastBundle = last.bundle, bundle != lastBundle { return nil }
        let age = now.timeIntervalSince(last.committedAt)
        guard age >= 0, age <= Double(windowSeconds) else { return nil }
        return last
    }

    func remember(_ record: Record) {
        lock.lock()
        defer { lock.unlock() }
        last = record
    }

    func lastRecord() -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        last = nil
    }
}
