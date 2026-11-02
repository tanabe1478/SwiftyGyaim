@testable import Gyaim
import XCTest

/// A retype of the same reading as a different word undoes the first commit's
/// learning (ADR-037).
final class StudyCorrectionTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func record(_ word: String, reading: String = "okimasita", readingKey: String = "おきました",
                        bundle: String? = "com.mitchellh.ghostty",
                        learning: StudyCorrectionTracker.Learning = .studied(context: "送って"),
                        at: Date) -> StudyCorrectionTracker.Record {
        StudyCorrectionTracker.Record(readingKey: readingKey, reading: reading, word: word,
                                      bundle: bundle, learning: learning, committedAt: at)
    }

    func testRetypeWithinWindowTargetsThePreviousCommit() {
        let tracker = StudyCorrectionTracker()
        tracker.remember(record("起きました", at: t0))

        let target = tracker.correctionTarget(readingKey: "おきました", word: "おきました",
                                              bundle: "com.mitchellh.ghostty",
                                              now: t0.addingTimeInterval(3), windowSeconds: 15)
        XCTAssertEqual(target?.word, "起きました")
        XCTAssertEqual(target?.learning, .studied(context: "送って"))
    }

    func testSameWordStaleOtherAppOrDisabledWindowIsNotACorrection() {
        let tracker = StudyCorrectionTracker()
        tracker.remember(record("移行", reading: "ikou", readingKey: "いこう", at: t0))

        XCTAssertNil(tracker.correctionTarget(readingKey: "いこう", word: "移行", bundle: "com.mitchellh.ghostty",
                                              now: t0.addingTimeInterval(3), windowSeconds: 15),
                     "committing the same word again is not a correction")
        XCTAssertNil(tracker.correctionTarget(readingKey: "いこう", word: "以降", bundle: "com.mitchellh.ghostty",
                                              now: t0.addingTimeInterval(16), windowSeconds: 15),
                     "outside the window")
        XCTAssertNotNil(tracker.correctionTarget(readingKey: "いこう", word: "以降", bundle: "com.mitchellh.ghostty",
                                                 now: t0.addingTimeInterval(15), windowSeconds: 15),
                        "age equal to the window still counts")
        XCTAssertNil(tracker.correctionTarget(readingKey: "いこう", word: "以降", bundle: "com.google.Chrome",
                                              now: t0.addingTimeInterval(3), windowSeconds: 15),
                     "a different app is a different sentence")
        XCTAssertNotNil(tracker.correctionTarget(readingKey: "いこう", word: "以降", bundle: nil,
                                                 now: t0.addingTimeInterval(3), windowSeconds: 15),
                        "an unknown bundle does not block the correction")
        XCTAssertNil(tracker.correctionTarget(readingKey: "いこう", word: "以降", bundle: "com.mitchellh.ghostty",
                                              now: t0.addingTimeInterval(3), windowSeconds: 0),
                     "0 disables the feature")
        XCTAssertNil(tracker.correctionTarget(readingKey: "いこう", word: "以降", bundle: "com.mitchellh.ghostty",
                                              now: t0.addingTimeInterval(-1), windowSeconds: 15),
                     "clock going backwards is treated as stale")
    }

    func testReadingKeyIgnoresRomajiSpellingAndUnlearnedCommitsAreSkipped() {
        let tracker = StudyCorrectionTracker()
        tracker.remember(record("更新", reading: "kousinn", readingKey: "こうしん", at: t0))
        XCTAssertEqual(tracker.correctionTarget(readingKey: "こうしん", word: "行進", bundle: nil,
                                                now: t0.addingTimeInterval(2), windowSeconds: 15)?.reading,
                       "kousinn", "kousin / kousinn are the same reading")

        tracker.remember(record("おきました", learning: .none, at: t0))
        XCTAssertNil(tracker.correctionTarget(readingKey: "おきました", word: "置きました", bundle: nil,
                                              now: t0.addingTimeInterval(2), windowSeconds: 15),
                     "a kana confirm that learned nothing has nothing to undo")

        tracker.reset()
        XCTAssertNil(tracker.lastRecord())
    }

    func testWindowDefaultAndClamp() {
        XCTAssertEqual(StudyCorrectionTracker.windowSeconds(configured: nil), 15)
        XCTAssertEqual(StudyCorrectionTracker.windowSeconds(configured: -3), 0)
        XCTAssertEqual(StudyCorrectionTracker.windowSeconds(configured: 999), 120)
        XCTAssertEqual(StudyCorrectionTracker.windowSeconds(configured: 20), 20)
    }

    func testCommitOutcomePayloadCarriesTheCorrectedWordOnlyWhenPresent() throws {
        let plain = try XCTUnwrap(GyaimController.commitOutcomePayload(
            path: "kana-hiragana", chosenWord: "おきました", context: "送って", prefixWords: ["okimasita"], trace: nil))
        XCTAssertFalse(plain.contains("correctedWord"))
        let corrected = try XCTUnwrap(GyaimController.commitOutcomePayload(
            path: "kana-hiragana", chosenWord: "おきました", context: "送って", prefixWords: ["okimasita"],
            trace: nil, correctedWord: "起きました"))
        XCTAssertTrue(corrected.contains("\"correctedWord\":\"起きました\""))
    }
}
