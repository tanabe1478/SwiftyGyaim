@testable import Gyaim
import XCTest

final class StudySuspectsTests: XCTestCase {
    private let now: TimeInterval = 1_800_000_000

    private func entry(_ reading: String, _ word: String, frequency: Int, ageDays: Double = 0) -> StudyEntry {
        StudyEntry(reading: reading, word: word, lastAccessTime: now - ageDays * 86_400, frequency: frequency)
    }

    func testFlagsTypoCompletionOfFrequentWord() {
        // BUG-025 shape: してほしいい (freq 1) next to してほしい (freq 22).
        let suspects = StudySuspects.find(in: [entry("sitehosii", "してほしい", frequency: 22),
                                               entry("sitehosiii", "してほしいい", frequency: 1)], now: now)
        XCTAssertEqual(suspects.map(\.entry.word), ["してほしいい"])
        XCTAssertEqual(suspects.first?.reason, .garbageCompletion)
    }

    func testDoesNotFlagFrequentWordSharingPrefixOrUnrelatedReading() {
        let suspects = StudySuspects.find(in: [
            // 今日 (freq 45) next to 今 (freq 166): a real word, above the frequency bound.
            entry("ima", "今", frequency: 166),
            entry("kyou", "今日", frequency: 45),
            // 文法 vs 文: reading does not extend "bun" by 1-2 chars.
            entry("bun", "文", frequency: 30),
            entry("bunpou", "文法", frequency: 1),
        ], now: now)
        XCTAssertTrue(suspects.isEmpty, "\(suspects)")
    }

    func testFlagsStaleSingletonAndOrdersGarbageFirst() {
        let suspects = StudySuspects.find(in: [
            entry("mukasi", "昔語", frequency: 1, ageDays: 120),
            entry("saikin", "最近語", frequency: 1, ageDays: 10),
            entry("suru", "する", frequency: 16),
            entry("suru?", "する？", frequency: 2),
        ], now: now)
        XCTAssertEqual(suspects.map(\.entry.word), ["する？", "昔語"])
        XCTAssertEqual(suspects.last?.reason, .staleSingleton)
    }
}
