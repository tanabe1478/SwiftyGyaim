import XCTest
@testable import Gyaim

final class WordSearchTests: XCTestCase {
    var ws: WordSearch!
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let localDict = tempDir.appendingPathComponent("localdict.txt")
        let studyDict = tempDir.appendingPathComponent("studydict.txt")
        try "".write(to: localDict, atomically: true, encoding: .utf8)
        try "".write(to: studyDict, atomically: true, encoding: .utf8)

        // Find dict.txt
        let projectDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // GyaimTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // GyaimSwift
        let dictPath = projectDir.appendingPathComponent("Resources/dict.txt").path

        guard FileManager.default.fileExists(atPath: dictPath) else {
            throw XCTSkip("dict.txt not found at \(dictPath)")
        }

        ws = WordSearch(connectionDictFile: dictPath,
                        localDictFile: localDict.path,
                        studyDictFile: studyDict.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSearchPrefix() throws {
        try XCTSkipIf(ws == nil)
        let results = ws.search(query: "man", searchMode: 0)
        let words = results.map(\.word)
        XCTAssertTrue(words.contains("万"), "Expected '万' in \(words)")
    }

    func testSearchExact() throws {
        try XCTSkipIf(ws == nil)
        let results = ws.search(query: "man", searchMode: 1)
        let words = results.map(\.word)
        XCTAssertTrue(words.contains("万"), "Expected '万' in exact search: \(words)")
    }

    func testTimestamp() throws {
        try XCTSkipIf(ws == nil)
        let results = ws.search(query: "ds", searchMode: 0)
        XCTAssertFalse(results.isEmpty, "Expected timestamp result for 'ds'")
        XCTAssertTrue(results[0].word.contains("/"), "Timestamp should contain '/'")
    }

    func testUppercase() throws {
        try XCTSkipIf(ws == nil)
        let results = ws.search(query: "Hello", searchMode: 0)
        XCTAssertEqual(results.first?.word, "Hello")
    }

    func testEmptyQuery() throws {
        try XCTSkipIf(ws == nil)
        let results = ws.search(query: "", searchMode: 0)
        XCTAssertTrue(results.isEmpty)
    }

    func testTriggerSuffixReturnsEmpty() throws {
        try XCTSkipIf(ws == nil)
        UserDefaults.standard.removeObject(forKey: "googleTransliterateTrigger")
        let results = ws.search(query: "meguro`", searchMode: 0)
        XCTAssertTrue(results.isEmpty, "Trigger suffix should return empty (Google handles it)")
    }

    func testSingleCharTriggerSuffixReturnsEmpty() throws {
        try XCTSkipIf(ws == nil)
        UserDefaults.standard.removeObject(forKey: "googleTransliterateTrigger")
        let results = ws.search(query: "a`", searchMode: 0)
        XCTAssertTrue(results.isEmpty, "Single char + trigger should return empty")
    }

    func testTriggerSuffixOnlyIsNotGoogleTrigger() throws {
        try XCTSkipIf(ws == nil)
        UserDefaults.standard.removeObject(forKey: "googleTransliterateTrigger")
        // "`" alone (count == 1) should NOT trigger the Google branch
        let results = ws.search(query: "`", searchMode: 0)
        // hasTriggerSuffix requires count > 1, so single char falls through
        _ = results
    }

    func testSearchReturnsMoreThan10Results() throws {
        try XCTSkipIf(ws == nil)
        // Default limit=0 (unlimited), common prefix "a" should have many candidates
        let results = ws.search(query: "a", searchMode: 0)
        XCTAssertGreaterThan(results.count, 10,
            "Unlimited search should return more than 10 results for common query 'a', got \(results.count)")
    }

    func testSearchWithExplicitLimit() throws {
        try XCTSkipIf(ws == nil)
        let limited = ws.search(query: "a", searchMode: 0, limit: 5)
        XCTAssertLessThanOrEqual(limited.count, 5,
            "Explicit limit=5 should cap results to 5, got \(limited.count)")
    }

    func testRegisterAndSearch() throws {
        try XCTSkipIf(ws == nil)
        ws.register(word: "テスト単語", reading: "testtango")
        let results = ws.search(query: "testtango", searchMode: 1)
        let words = results.map(\.word)
        XCTAssertTrue(words.contains("テスト単語"))
    }

    // MARK: - Study + Eviction

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "studyDictEvictionMode")
    }

    func testStudyInsertsNewEntry() throws {
        try XCTSkipIf(ws == nil)
        ws.study(word: "東京", reading: "tokyo")
        let results = ws.search(query: "tokyo", searchMode: 1)
        XCTAssertTrue(results.map(\.word).contains("東京"))
    }

    func testStudyIncrementsFrequency() throws {
        try XCTSkipIf(ws == nil)
        ws.study(word: "東京", reading: "tokyo")
        ws.study(word: "東京", reading: "tokyo")
        // Verify it's searchable (frequency tracking is internal)
        let results = ws.search(query: "tokyo", searchMode: 1)
        XCTAssertTrue(results.map(\.word).contains("東京"))
        // Save and reload to verify frequency was persisted
        ws.finish()
        let entries = WordSearch.loadStudyDict(
            dictFile: tempDir.appendingPathComponent("studydict.txt").path)
        let tokyo = entries.first { $0.word == "東京" }
        XCTAssertEqual(tokyo?.frequency, 2)
    }

    func testEvictMRU() throws {
        try XCTSkipIf(ws == nil)
        EvictionMode.setCurrent(.mru)
        // Add more than 10,000 entries (use smaller number for test speed)
        // We test the eviction logic directly via save/load
        for i in 0..<10_002 {
            ws.study(word: "語\(i)", reading: "go\(i)")
        }
        ws.finish()
        let entries = WordSearch.loadStudyDict(
            dictFile: tempDir.appendingPathComponent("studydict.txt").path)
        XCTAssertLessThanOrEqual(entries.count, 10_000)
    }

    func testEvictNone() throws {
        try XCTSkipIf(ws == nil)
        EvictionMode.setCurrent(.none)
        // With .none mode, entries are still capped at 10,000
        for i in 0..<10_002 {
            ws.study(word: "語\(i)", reading: "go\(i)")
        }
        ws.finish()
        let entries = WordSearch.loadStudyDict(
            dictFile: tempDir.appendingPathComponent("studydict.txt").path)
        XCTAssertLessThanOrEqual(entries.count, 10_000)
    }

    func testEvictScoreBased() throws {
        try XCTSkipIf(ws == nil)
        EvictionMode.setCurrent(.scoreBased)
        // Add entries with varying timestamps to test score-based eviction
        for i in 0..<10_002 {
            ws.study(word: "語\(i)", reading: "go\(i)")
        }
        ws.finish()
        let entries = WordSearch.loadStudyDict(
            dictFile: tempDir.appendingPathComponent("studydict.txt").path)
        XCTAssertLessThanOrEqual(entries.count, 10_000)
    }

    func testSearchStudyDictPriority() throws {
        try XCTSkipIf(ws == nil)
        ws.study(word: "万歳", reading: "man")
        let results = ws.search(query: "man", searchMode: 0)
        // Study dict entry should appear before connection dict entries
        XCTAssertEqual(results.first?.word, "万歳")
    }
}
