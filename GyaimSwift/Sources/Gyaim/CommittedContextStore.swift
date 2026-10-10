import Foundation

/// Process-wide memory of the text each client app most recently committed
/// through Gyaim, keyed by the client's bundle identifier.
///
/// InputMethodKit recreates `GyaimController` whenever focus moves between
/// apps or fields (1,887 times in 10 days of dogfood, median 14 s after the
/// previous commit). The left context used by the fast-context rerank lived
/// only in the controller, so every recreation started the model with no
/// context, and with no context the model made the first candidate worse
/// (top-1 0.794 vs 0.817 heuristic-only) while with any context it made it
/// better (+4 to +6 points). A new controller now inherits the context the
/// previous one built up in the same app, as long as it is recent (ADR-035).
///
/// Main-thread only, like the controller that owns it.
final class CommittedContextStore {
    static let shared = CommittedContextStore()

    struct Entry: Equatable {
        var text: String
        var updatedAt: Date
    }

    /// Default inheritance window. 0 disables inheritance.
    static let defaultCarryOverSeconds = 300
    static let maxCarryOverSeconds = 3600
    static let settingsKey = "aiRerankFastContextCarryOverSeconds"

    let maxCharacters: Int
    private var entries: [String: Entry] = [:]

    init(maxCharacters: Int = 80) {
        self.maxCharacters = maxCharacters
    }

    /// Configured window in seconds (0 = disabled), clamped to a sane range.
    static func carryOverSeconds(configured: Int?) -> Int {
        guard let configured else { return defaultCarryOverSeconds }
        return min(max(configured, 0), maxCarryOverSeconds)
    }

    static var configuredCarryOverSeconds: Int {
        guard GyaimSettings.objectExists(forKey: settingsKey) else {
            return carryOverSeconds(configured: nil)
        }
        return carryOverSeconds(configured: GyaimSettings.integer(forKey: settingsKey))
    }

    /// Appends committed text to the app's entry, keeping only the tail.
    func record(text: String, bundle: String, now: Date = Date()) {
        guard !text.isEmpty, !bundle.isEmpty else { return }
        var combined = (entries[bundle]?.text ?? "") + text
        if combined.count > maxCharacters {
            combined = String(combined.suffix(maxCharacters))
        }
        entries[bundle] = Entry(text: combined, updatedAt: now)
    }

    /// Context a fresh controller for `bundle` may inherit, or "" when there
    /// is none, inheritance is disabled, or the last commit is older than the
    /// window.
    func inheritableContext(bundle: String, now: Date = Date(), carryOverSeconds: Int) -> String {
        guard carryOverSeconds > 0, let entry = entries[bundle] else { return "" }
        return Self.isFresh(entry, now: now, carryOverSeconds: carryOverSeconds) ? entry.text : ""
    }

    func entry(for bundle: String) -> Entry? { entries[bundle] }

    func reset() { entries.removeAll() }

    static func isFresh(_ entry: Entry, now: Date, carryOverSeconds: Int) -> Bool {
        let age = now.timeIntervalSince(entry.updatedAt)
        return age >= 0 && age <= TimeInterval(carryOverSeconds)
    }
}
