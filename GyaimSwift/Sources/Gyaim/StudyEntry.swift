import Foundation

/// A study dictionary entry with metadata for score-based eviction.
struct StudyEntry: Equatable {
    let reading: String
    let word: String
    var lastAccessTime: TimeInterval  // seconds since epoch
    var frequency: Int

    /// Mozc-simplified score. Higher = more valuable (less likely to be evicted).
    ///
    /// - `lastAccessTime`: recency (dominant factor)
    /// - `log2(frequency) * 3600`: doubling usage ≈ +1 hour of recency
    /// - `word.count * 600`: each character ≈ -10 minutes (shorter words preferred)
    func score() -> Double {
        let frequencyBonus = log2(Double(max(frequency, 1))) * 3600.0
        let charPenalty = Double(word.count) * 600.0
        return lastAccessTime + frequencyBonus - charPenalty
    }
}

/// Study dictionary eviction mode.
enum EvictionMode: Int, CaseIterable {
    case mru = 0        // Gyaim traditional: MRU tail truncation
    case none = 1       // No eviction (unlimited)
    case scoreBased = 2 // Mozc-style score-based eviction

    static let defaultMode: EvictionMode = .mru
    private static let key = "studyDictEvictionMode"

    static var current: EvictionMode {
        EvictionMode(rawValue: UserDefaults.standard.integer(forKey: key)) ?? defaultMode
    }

    static func setCurrent(_ mode: EvictionMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }
}
