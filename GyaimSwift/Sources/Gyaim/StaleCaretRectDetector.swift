import Foundation

/// Detects the stale caret rect some web editors report (ADR-038).
///
/// Google Docs in Chrome alternates between two rects for
/// `attributes(forCharacterIndex:lineHeightRectangle:)`: the real caret, whose
/// x advances as text is typed, and the rect of an off-screen input element
/// at the left edge of the Chrome window, which never moves and has the
/// default line height. Dogfood logs (2026-10-19..11-03) show the stale rect
/// starting about half of the compositions on bad days, 600..1200 px from the
/// caret.
///
/// A reported rect is treated as stale when the same (x, y, height) was already
/// reported within the window, the rect reported just before it was a different
/// one at least `minDistance` away with a line height differing by at least
/// `minHeightDifference`. A real caret rarely comes back to the exact same pixel
/// from far away with a different line height; over 15 days of logs the rule
/// matched 514 of 545 stale compositions in Chrome and none in ghostty, Slack,
/// Discord or VS Code. The replacement is the last different rect (the last
/// known real caret), kept while the stale rect keeps being reported.
///
/// Process-wide per client bundle like `CommittedContextStore`: IMK recreates
/// the controller on focus changes and the first composition of a new
/// controller often starts on the stale rect.
final class StaleCaretRectDetector {
    static let windowSeconds: TimeInterval = 60
    static let minDistance: CGFloat = 300
    static let minHeightDifference: CGFloat = 2
    static let maxRuns = 16

    private struct Run {
        var rect: NSRect
        var lastSeenAt: Date
    }

    private var runs: [Run] = []
    private var currentReplacement: NSRect?

    private static var byBundle: [String: StaleCaretRectDetector] = [:]
    private static let registryLock = NSLock()

    static func shared(for bundle: String?) -> StaleCaretRectDetector {
        let key = bundle ?? "unknown"
        registryLock.lock()
        defer { registryLock.unlock() }
        if let detector = byBundle[key] { return detector }
        let detector = StaleCaretRectDetector()
        byBundle[key] = detector
        return detector
    }

    static func resetAll() {
        registryLock.lock()
        defer { registryLock.unlock() }
        byBundle.removeAll()
    }

    /// Records `reported` and returns the rect to show the window at instead when
    /// `reported` is the stale rect, or nil to use `reported` as is.
    func replacement(for reported: NSRect, now: Date = Date()) -> NSRect? {
        if let last = runs.last, Self.sameRect(last.rect, reported) {
            runs[runs.count - 1].lastSeenAt = now
            return currentReplacement
        }
        runs.removeAll { now.timeIntervalSince($0.lastSeenAt) > Self.windowSeconds }
        currentReplacement = nil
        if let previous = runs.last, runs.contains(where: { Self.sameRect($0.rect, reported) }),
           Self.isFarWithDifferentLineHeight(previous.rect, reported) {
            currentReplacement = previous.rect
        }
        runs.append(Run(rect: reported, lastSeenAt: now))
        if runs.count > Self.maxRuns { runs.removeFirst(runs.count - Self.maxRuns) }
        return currentReplacement
    }

    func reset() {
        runs.removeAll()
        currentReplacement = nil
    }

    static func sameRect(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        lhs.origin.x == rhs.origin.x && lhs.origin.y == rhs.origin.y && lhs.height == rhs.height
    }

    static func isFarWithDifferentLineHeight(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        hypot(lhs.origin.x - rhs.origin.x, lhs.origin.y - rhs.origin.y) >= minDistance
            && abs(lhs.height - rhs.height) >= minHeightDifference
    }
}
