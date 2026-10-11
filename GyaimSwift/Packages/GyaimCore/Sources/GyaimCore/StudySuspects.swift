import Foundation

/// Study-dictionary entries that look like typo commits or dead weight
/// (issue #58). Swift port of Tools/dict/find-suspect-study-entries.py so the
/// list can be reviewed and cleaned from the settings window instead of a
/// terminal. Nothing is deleted automatically: BUG-025 showed a typo entry
/// demoting a real word, but the same shape also matches legitimate words
/// (今日 next to 今), so a human confirms each deletion.
enum StudySuspects {
    enum Reason: String {
        /// The word is another entry's word plus one trailing character and the
        /// shorter word is used far more (してほしいい freq 1 vs してほしい freq 22).
        case garbageCompletion = "garbage-completion"
        /// Frequency 1 and unused for `staleDays`.
        case staleSingleton = "stale-singleton"

        var label: String {
            switch self {
            case .garbageCompletion: return "末尾1文字付きの低頻度語"
            case .staleSingleton: return "長期間未使用（1回のみ）"
            }
        }
    }

    struct Suspect: Equatable {
        let entry: StudyEntry
        let reason: Reason
        let detail: String
    }

    static let defaultStaleDays = 90
    static let defaultMaxGarbageFrequency = 2
    static let dominance = 3

    static func find(in entries: [StudyEntry],
                     now: TimeInterval = Date().timeIntervalSince1970,
                     staleDays: Int = defaultStaleDays,
                     maxGarbageFrequency: Int = defaultMaxGarbageFrequency) -> [Suspect] {
        var frequencyByWord: [String: Int] = [:]
        var readingsByWord: [String: Set<String>] = [:]
        for entry in entries {
            frequencyByWord[entry.word] = max(frequencyByWord[entry.word] ?? 0, entry.frequency)
            readingsByWord[entry.word, default: []].insert(entry.reading)
        }

        let staleCutoff = now - Double(staleDays) * 86_400
        var suspects: [Suspect] = []
        for entry in entries {
            if entry.word.count >= 2, entry.frequency <= maxGarbageFrequency {
                let shorter = String(entry.word.dropLast())
                let shorterFrequency = frequencyByWord[shorter] ?? 0
                // A typo commit extends the shorter word's reading by one or two
                // keystrokes (sitehosiii = sitehosii + i). A different word that
                // merely shares a surface prefix has an unrelated reading
                // (文法 bunpou vs 文 bun) and must not be flagged.
                let readingExtendsShorter = (readingsByWord[shorter] ?? []).contains { shorterReading in
                    entry.reading.hasPrefix(shorterReading)
                        && (1...2).contains(entry.reading.count - shorterReading.count)
                }
                if readingExtendsShorter,
                   shorterFrequency >= max(entry.frequency * dominance, entry.frequency + 2) {
                    suspects.append(Suspect(entry: entry,
                                            reason: .garbageCompletion,
                                            detail: "「\(shorter)」(freq \(shorterFrequency)) の末尾1文字付きで freq \(entry.frequency)"))
                    continue
                }
            }
            if entry.frequency == 1, entry.lastAccessTime < staleCutoff {
                let ageDays = Int((now - entry.lastAccessTime) / 86_400)
                suspects.append(Suspect(entry: entry,
                                        reason: .staleSingleton,
                                        detail: "freq 1、最終使用 \(ageDays) 日前"))
            }
        }
        return suspects.sorted { lhs, rhs in
            if lhs.reason != rhs.reason { return lhs.reason == .garbageCompletion }
            if lhs.entry.frequency != rhs.entry.frequency { return lhs.entry.frequency > rhs.entry.frequency }
            return lhs.entry.reading < rhs.entry.reading
        }
    }
}
