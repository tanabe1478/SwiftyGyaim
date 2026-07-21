@testable import Gyaim
import XCTest

/// Property tests for WordSearch.mergeKanaEquivalentStudyEntries
/// (formal methods Phase 1).
///
/// The merge runs on every launch, so these are conservation laws:
/// learning must be neither lost nor invented by the migration, and
/// re-running it must be a no-op.
final class StudyMergePropertyTests: XCTestCase {
    /// Generates entries with overlapping readings/words so kana-equivalent
    /// groups (kousin/kousinn shapes) actually occur.
    private func makeEntries(_ random: inout PropertyRandom) -> [StudyEntry] {
        let readings = ["kousin", "kousinn", "kinou", "seisansei", "sinkou", "sinnkou"]
        let words = ["更新", "行進", "機能", "昨日", "生産性", "進行", "信仰"]
        let count = random.int(in: 0...12)
        return (0..<count).map { _ in
            StudyEntry(reading: readings[random.int(in: 0...(readings.count - 1))],
                       word: words[random.int(in: 0...(words.count - 1))],
                       lastAccessTime: Double(random.int(in: 1_000...9_999)),
                       frequency: random.int(in: 1...50))
        }
    }

    func testMergeConservesTotalFrequency() {
        checkProperty("merge neither loses nor invents learning (frequency sum is conserved)") { random in
            let entries = makeEntries(&random)

            let merged = WordSearch.mergeKanaEquivalentStudyEntries(entries)

            let before = entries.reduce(0) { $0 + $1.frequency }
            let after = merged.reduce(0) { $0 + $1.frequency }
            guard before == after else {
                return "frequency sum \(before) -> \(after) for \(entries)"
            }
            return nil
        }
    }

    func testMergeIsIdempotent() {
        checkProperty("merging an already-merged dictionary changes nothing") { random in
            let entries = makeEntries(&random)

            let once = WordSearch.mergeKanaEquivalentStudyEntries(entries)
            let twice = WordSearch.mergeKanaEquivalentStudyEntries(once)

            guard once == twice else {
                return "not idempotent: \(once) -> \(twice)"
            }
            return nil
        }
    }
}
