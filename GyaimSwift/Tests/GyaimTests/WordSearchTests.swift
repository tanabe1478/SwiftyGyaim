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
        for i in 0..<10_002 {
            ws.study(word: "語\(i)", reading: "go\(i)")
        }
        ws.finish()
        let entries = WordSearch.loadStudyDict(
            dictFile: tempDir.appendingPathComponent("studydict.txt").path)
        XCTAssertLessThanOrEqual(entries.count, 10_000)
    }

    /// Phase 3相当: freq=2の語はfreq=1の古い語より優先して生き残る
    func testScoreBasedEvictsLowFreqOldEntries() throws {
        try XCTSkipIf(ws == nil)
        EvictionMode.setCurrent(.scoreBased)

        let studyPath = tempDir.appendingPathComponent("studydict.txt").path
        let now = Date().timeIntervalSince1970

        // 10,000件のfreq=1エントリを古いタイムスタンプで事前配置
        var entries: [StudyEntry] = (0..<10_000).map { i in
            StudyEntry(reading: "go\(i)", word: "語\(i)",
                       lastAccessTime: now - 86400 - Double(10_000 - i), frequency: 1)
        }
        // うち3件をfreq=5に引き上げ（osaka, kyoto, sapporo相当）
        entries[0].frequency = 5  // go0 → freq=5（古いが頻度高い）
        entries[1].frequency = 5
        entries[2].frequency = 5

        WordSearch.saveStudyDict(dictFile: studyPath, dict: entries)

        // 新しいWordSearchインスタンスで読み込み直し
        let projectDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dictPath = projectDir.appendingPathComponent("Resources/dict.txt").path
        guard FileManager.default.fileExists(atPath: dictPath) else {
            throw XCTSkip("dict.txt not found")
        }
        let ws2 = WordSearch(connectionDictFile: dictPath,
                             localDictFile: tempDir.appendingPathComponent("localdict.txt").path,
                             studyDictFile: studyPath)

        // 3件追加して淘汰を発生させる
        ws2.study(word: "沖縄", reading: "okinawa")
        ws2.study(word: "函館", reading: "hakodate")
        ws2.study(word: "旭川", reading: "asahikawa")

        ws2.finish()
        let result = WordSearch.loadStudyDict(dictFile: studyPath)

        // 件数が上限以内
        XCTAssertLessThanOrEqual(result.count, 10_000)

        // freq=5の語は生き残っている
        let survivedFreq5 = result.filter { $0.frequency >= 5 }
        XCTAssertEqual(survivedFreq5.count, 3,
                       "freq=5の語は3件とも生き残るべき: \(survivedFreq5.map(\.word))")

        // 新しく追加した3件も生き残っている
        let newWords = Set(["沖縄", "函館", "旭川"])
        let survivedNew = result.filter { newWords.contains($0.word) }
        XCTAssertEqual(survivedNew.count, 3,
                       "新規追加した3件は生き残るべき: \(survivedNew.map(\.word))")
    }

    /// freq=2の語が古くても、freq=1のさらに古い語より先に淘汰されないことを確認
    func testScoreBasedFrequencyBoostPreventsEviction() throws {
        try XCTSkipIf(ws == nil)
        EvictionMode.setCurrent(.scoreBased)

        let studyPath = tempDir.appendingPathComponent("studydict.txt").path
        let now = Date().timeIntervalSince1970

        // freq=1の古い語を9,999件
        var entries: [StudyEntry] = (0..<9_999).map { i in
            StudyEntry(reading: "word\(i)", word: "単語\(i)",
                       lastAccessTime: now - 86400 - Double(9_999 - i), frequency: 1)
        }
        // 1件だけfreq=3（最も古いタイムスタンプだがfreqが高い）
        let boosted = StudyEntry(reading: "boosted", word: "ブースト語",
                                  lastAccessTime: now - 86400 * 7, frequency: 3)
        entries.insert(boosted, at: 0)

        WordSearch.saveStudyDict(dictFile: studyPath, dict: entries)

        let projectDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dictPath = projectDir.appendingPathComponent("Resources/dict.txt").path
        guard FileManager.default.fileExists(atPath: dictPath) else {
            throw XCTSkip("dict.txt not found")
        }
        let ws2 = WordSearch(connectionDictFile: dictPath,
                             localDictFile: tempDir.appendingPathComponent("localdict.txt").path,
                             studyDictFile: studyPath)

        // 2件追加（上限10,000を超える → 淘汰発生）
        ws2.study(word: "新語A", reading: "newA")
        ws2.study(word: "新語B", reading: "newB")
        ws2.finish()

        let result = WordSearch.loadStudyDict(dictFile: studyPath)
        XCTAssertLessThanOrEqual(result.count, 10_000)

        // freq=3のブースト語は生き残っている
        let boostedSurvived = result.first { $0.word == "ブースト語" }
        XCTAssertNotNil(boostedSurvived,
                        "freq=3の語は7日前でも淘汰されずに生き残るべき")
    }

    func testSearchStudyDictPriority() throws {
        try XCTSkipIf(ws == nil)
        ws.study(word: "万歳", reading: "man")
        let results = ws.search(query: "man", searchMode: 0)
        // Study dict entry should appear before connection dict entries
        XCTAssertEqual(results.first?.word, "万歳")
    }
}
