@testable import Gyaim
import XCTest

final class GoogleTransliterateTests: XCTestCase {

    // MARK: - filterCandidates (pure function)

    func testFilterRemovesKanaSpellingsOfQuery() {
        let result = GoogleTransliterate.filterCandidates(
            raw: ["東京", "トウキョウ", "とうきょう", "東京都"],
            query: "toukyou"
        )
        XCTAssertEqual(result, ["東京", "東京都"])
    }

    func testFilterDeduplicates() {
        let result = GoogleTransliterate.filterCandidates(
            raw: ["東京", "東京", "東京都"],
            query: "toukyou"
        )
        XCTAssertEqual(result, ["東京", "東京都"])
    }

    // MARK: - buildGoogleCandidates (candidate assembly)

    func testBuildGoogleCandidatesWithResults() {
        let results = ["目黒", "目黒区"]
        let candidates = GoogleTransliterate.buildGoogleCandidates(
            apiResults: results,
            query: "meguro"
        )
        let words = candidates.map(\.word)
        // First should be the raw query
        XCTAssertEqual(words.first, "meguro")
        // API results follow
        XCTAssertTrue(words.contains("目黒"))
        XCTAssertTrue(words.contains("目黒区"))
        // Hiragana/katakana fallback at end
        XCTAssertTrue(words.contains("めぐろ"))
        XCTAssertTrue(words.contains("メグロ"))
        XCTAssertEqual(candidates.first { $0.word == "meguro" }?.kind, .raw)
        XCTAssertEqual(candidates.first { $0.word == "目黒" }?.kind, .google)
        XCTAssertEqual(candidates.first { $0.word == "目黒" }?.source, .google)
        XCTAssertEqual(candidates.first { $0.word == "目黒" }?.reading, "meguro")
        XCTAssertEqual(candidates.first { $0.word == "めぐろ" }?.kind, .kana)
    }

    func testBuildGoogleCandidatesEmptyResults() {
        let candidates = GoogleTransliterate.buildGoogleCandidates(
            apiResults: [],
            query: "meguro"
        )
        let words = candidates.map(\.word)
        XCTAssertEqual(words.first, "meguro")
        XCTAssertTrue(words.contains("めぐろ"))
        XCTAssertTrue(words.contains("メグロ"))
    }

    func testBuildGoogleCandidatesDeduplicates() {
        let candidates = GoogleTransliterate.buildGoogleCandidates(
            apiResults: ["めぐろ", "目黒"],
            query: "meguro"
        )
        let words = candidates.map(\.word)
        // "めぐろ" should appear only once
        XCTAssertEqual(words.filter { $0 == "めぐろ" }.count, 1)
    }

    // MARK: - Trigger suffix configuration

    func testDefaultTriggerSuffix() {
        // Clean up any existing value
        UserDefaults.standard.removeObject(forKey: "googleTransliterateTrigger")
        XCTAssertEqual(GoogleTransliterate.triggerSuffix, "`")
    }

    func testHasAndStripTriggerSuffix() {
        UserDefaults.standard.removeObject(forKey: "googleTransliterateTrigger")
        XCTAssertTrue(GoogleTransliterate.hasTriggerSuffix("meguro`"))
        XCTAssertFalse(GoogleTransliterate.hasTriggerSuffix("meguro"))
        XCTAssertFalse(GoogleTransliterate.hasTriggerSuffix("`"))  // single char only
        XCTAssertEqual(GoogleTransliterate.stripTriggerSuffix("meguro`"), "meguro")
        XCTAssertEqual(GoogleTransliterate.stripTriggerSuffix("meguro"), "meguro")
    }

    func testHasTriggerSuffixCustom() {
        let original = UserDefaults.standard.string(forKey: "googleTransliterateTrigger")
        defer {
            if let orig = original {
                UserDefaults.standard.set(orig, forKey: "googleTransliterateTrigger")
            } else {
                UserDefaults.standard.removeObject(forKey: "googleTransliterateTrigger")
            }
        }

        GoogleTransliterate.setTriggerSuffix("@")
        XCTAssertTrue(GoogleTransliterate.hasTriggerSuffix("meguro@"))
        XCTAssertFalse(GoogleTransliterate.hasTriggerSuffix("meguro`"))
    }

    // MARK: - combineSegments (multi-word issue #14)

    func testCombineSegmentsSingle() {
        let result = GoogleTransliterate.combineSegments([["増井", "桝井"]])
        XCTAssertEqual(result, ["増井", "桝井"])
    }

    func testCombineSegmentsMultiple() {
        let result = GoogleTransliterate.combineSegments([
            ["増井", "桝井"],
            ["俊之", "敏之"]
        ])
        XCTAssertEqual(result, ["増井俊之", "増井敏之", "桝井俊之", "桝井敏之"])
    }

    func testCombineSegmentsThreeSegments() {
        let result = GoogleTransliterate.combineSegments([
            ["A", "B"],
            ["1", "2"],
            ["x"]
        ])
        XCTAssertEqual(result, ["A1x", "A2x", "B1x", "B2x"])
    }

    func testCombineSegmentsRespectsLimit() {
        let result = GoogleTransliterate.combineSegments([
            ["A", "B", "C", "D", "E"],
            ["1", "2", "3", "4", "5"]
        ], limit: 5)
        XCTAssertEqual(result.count, 5)
    }
}
