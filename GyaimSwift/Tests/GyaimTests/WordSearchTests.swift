@testable import Gyaim
import XCTest

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
        UserDefaults.standard.removeObject(forKey: "studyHiraganaEnabled")
        UserDefaults.standard.removeObject(forKey: "exactReadingMatchPriority")
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

    /// BUG: study() はメモリ上のstudyDictに追加するのみで、finish() を呼ぶまでファイルに保存されない。
    /// IMEプロセスがdeactivateServerを経由せず終了すると、学習が失われる（例: Google変換で確定した「明示的」が消える）。
    /// 修正後は study() 呼び出し後、finish() を呼ばずともファイルに永続化されること。
    func testStudyPersistsToFileWithoutFinish() throws {
        try XCTSkipIf(ws == nil)
        ws.study(word: "明示的", reading: "meijiteki")
        // 意図的に finish() を呼ばない
        let entries = WordSearch.loadStudyDict(
            dictFile: tempDir.appendingPathComponent("studydict.txt").path)
        XCTAssertTrue(entries.map(\.word).contains("明示的"),
                      "study() should persist to disk immediately, without requiring finish()")
    }

    /// frequency インクリメントパスも同様に永続化されること
    func testStudyFrequencyIncrementPersistsWithoutFinish() throws {
        try XCTSkipIf(ws == nil)
        ws.study(word: "明示的", reading: "meijiteki")
        ws.study(word: "明示的", reading: "meijiteki")
        // 意図的に finish() を呼ばない
        let entries = WordSearch.loadStudyDict(
            dictFile: tempDir.appendingPathComponent("studydict.txt").path)
        let entry = entries.first { $0.word == "明示的" }
        XCTAssertNotNil(entry, "Entry should exist on disk after study()")
        XCTAssertEqual(entry?.frequency, 2,
                       "Frequency should be 2 after two study() calls, even without finish()")
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

    // MARK: - Study Hiragana Skip

    func testIsAllHiragana() {
        XCTAssertTrue(WordSearch.isAllHiragana("して"))
        XCTAssertTrue(WordSearch.isAllHiragana("の"))
        XCTAssertTrue(WordSearch.isAllHiragana("できる"))
        XCTAssertFalse(WordSearch.isAllHiragana("東京"))
        XCTAssertFalse(WordSearch.isAllHiragana("食べる"))
        XCTAssertFalse(WordSearch.isAllHiragana("カタカナ"))
        XCTAssertFalse(WordSearch.isAllHiragana(""))
        XCTAssertFalse(WordSearch.isAllHiragana("abc"))
    }

    func testStudySkipsHiraganaWhenDisabled() throws {
        try XCTSkipIf(ws == nil)
        WordSearch.setStudyHiraganaEnabled(false)
        ws.study(word: "ふがほげ", reading: "fugahoge")
        ws.finish()
        let entries = WordSearch.loadStudyDict(
            dictFile: tempDir.appendingPathComponent("studydict.txt").path)
        XCTAssertFalse(entries.map(\.word).contains("ふがほげ"),
                       "Hiragana word should not be studied when setting is OFF")
    }

    func testStudyLearnsHiraganaWhenEnabled() throws {
        try XCTSkipIf(ws == nil)
        WordSearch.setStudyHiraganaEnabled(true)
        ws.study(word: "ふがほげ", reading: "fugahoge")
        ws.finish()
        let entries = WordSearch.loadStudyDict(
            dictFile: tempDir.appendingPathComponent("studydict.txt").path)
        XCTAssertTrue(entries.map(\.word).contains("ふがほげ"),
                      "Hiragana word should be studied when setting is ON")
    }

    func testStudyHiraganaDefaultIsEnabled() throws {
        try XCTSkipIf(ws == nil)
        UserDefaults.standard.removeObject(forKey: "studyHiraganaEnabled")
        ws.study(word: "ふがほげ", reading: "fugahoge")
        ws.finish()
        let entries = WordSearch.loadStudyDict(
            dictFile: tempDir.appendingPathComponent("studydict.txt").path)
        XCTAssertTrue(entries.map(\.word).contains("ふがほげ"),
                      "Default should learn hiragana (backward compat)")
    }

    func testStudyAlwaysLearnsKanji() throws {
        try XCTSkipIf(ws == nil)
        WordSearch.setStudyHiraganaEnabled(false)
        ws.study(word: "東京", reading: "tokyo")
        let results = ws.search(query: "tokyo", searchMode: 1)
        XCTAssertTrue(results.map(\.word).contains("東京"),
                      "Kanji words should always be studied")
    }

    func testStudyLearnsMixedKanjiHiragana() throws {
        try XCTSkipIf(ws == nil)
        WordSearch.setStudyHiraganaEnabled(false)
        ws.study(word: "食べる", reading: "taberu")
        let results = ws.search(query: "taberu", searchMode: 1)
        XCTAssertTrue(results.map(\.word).contains("食べる"),
                      "Mixed kanji+hiragana words should always be studied")
    }

    func testSearchStudyDictPriority() throws {
        try XCTSkipIf(ws == nil)
        ws.study(word: "万歳", reading: "man")
        let results = ws.search(query: "man", searchMode: 0)
        // Study dict entry should appear before connection dict entries
        XCTAssertEqual(results.first?.word, "万歳")
    }

    // MARK: - Candidate Source Tagging

    func testSearchStudyCandidateHasStudySource() throws {
        try XCTSkipIf(ws == nil)
        ws.study(word: "東京", reading: "tokyo")
        let results = ws.search(query: "tokyo", searchMode: 1)
        let tokyo = results.first { $0.word == "東京" }
        XCTAssertEqual(tokyo?.source, .study)
    }

    func testSearchLocalCandidateHasLocalSource() throws {
        try XCTSkipIf(ws == nil)
        ws.register(word: "テスト語", reading: "tesutogo")
        let results = ws.search(query: "tesutogo", searchMode: 1)
        let testWord = results.first { $0.word == "テスト語" }
        XCTAssertEqual(testWord?.source, .local)
    }

    func testSearchConnectionCandidateHasConnectionSource() throws {
        try XCTSkipIf(ws == nil)
        let results = ws.search(query: "man", searchMode: 1)
        let man = results.first { $0.word == "万" }
        XCTAssertEqual(man?.source, .connection)
    }

    // MARK: - Delete from Study Dict

    func testDeleteFromStudy_removesEntry() throws {
        try XCTSkipIf(ws == nil)
        ws.study(word: "削除テスト語", reading: "sakujotesutogo")
        let deleted = ws.deleteFromStudy(word: "削除テスト語", reading: "sakujotesutogo")
        XCTAssertTrue(deleted)
        let results = ws.search(query: "sakujotesutogo", searchMode: 1)
        XCTAssertFalse(results.map(\.word).contains("削除テスト語"))
    }

    func testDeleteFromStudy_returnsFalseWhenNotFound() throws {
        try XCTSkipIf(ws == nil)
        let deleted = ws.deleteFromStudy(word: "存在しない", reading: "sonzai")
        XCTAssertFalse(deleted)
    }

    func testDeleteFromStudy_persistsAfterReload() throws {
        try XCTSkipIf(ws == nil)
        ws.study(word: "永続テスト語", reading: "eizokutesutogo")
        ws.finish()
        _ = ws.deleteFromStudy(word: "永続テスト語", reading: "eizokutesutogo")
        let entries = WordSearch.loadStudyDict(
            dictFile: tempDir.appendingPathComponent("studydict.txt").path)
        XCTAssertFalse(entries.map(\.word).contains("永続テスト語"))
    }

    // MARK: - Delete from Local Dict

    func testDeleteFromLocal_removesEntry() throws {
        try XCTSkipIf(ws == nil)
        ws.register(word: "テスト語", reading: "tesutogo")
        let deleted = ws.deleteFromLocal(word: "テスト語", reading: "tesutogo")
        XCTAssertTrue(deleted)
        let results = ws.search(query: "tesutogo", searchMode: 1)
        XCTAssertFalse(results.map(\.word).contains("テスト語"))
    }

    func testDeleteFromLocal_returnsFalseWhenNotFound() throws {
        try XCTSkipIf(ws == nil)
        let deleted = ws.deleteFromLocal(word: "存在しない", reading: "sonzai")
        XCTAssertFalse(deleted)
    }

    func testDeleteFromLocal_persistsAfterReload() throws {
        try XCTSkipIf(ws == nil)
        ws.register(word: "テスト語", reading: "tesutogo")
        let deleted = ws.deleteFromLocal(word: "テスト語", reading: "tesutogo")
        XCTAssertTrue(deleted)
        let entries = WordSearch.loadDict(
            dictFile: tempDir.appendingPathComponent("localdict.txt").path)
        XCTAssertFalse(entries.contains(["tesutogo", "テスト語"]))
    }

    // MARK: - Exact Reading Match Priority

    func testExactReadingMatchPrioritizedOverPrefix() throws {
        try XCTSkipIf(ws == nil)
        WordSearch.setExactReadingMatchPriority(true)
        ws.study(word: "設定", reading: "settei")
        ws.study(word: "設定画面", reading: "setteigamen")
        let results = ws.search(query: "settei", searchMode: 0)
        let words = results.map(\.word)
        guard let idxSettei = words.firstIndex(of: "設定"),
              let idxGamen = words.firstIndex(of: "設定画面") else {
            XCTFail("Expected both 設定 and 設定画面 in results: \(words)")
            return
        }
        XCTAssertLessThan(idxSettei, idxGamen,
            "Exact reading match '設定' should come before prefix-only match '設定画面', got: \(words)")
    }

    func testExactMatchOrderPreservedWithinGroup() throws {
        try XCTSkipIf(ws == nil)
        WordSearch.setExactReadingMatchPriority(true)
        ws.study(word: "設定", reading: "settei")
        ws.study(word: "節程", reading: "settei")
        let results = ws.search(query: "settei", searchMode: 0)
        let words = results.map(\.word)
        guard let idx1 = words.firstIndex(of: "節程"),
              let idx2 = words.firstIndex(of: "設定") else {
            XCTFail("Expected both words in results: \(words)")
            return
        }
        XCTAssertLessThan(idx1, idx2,
            "Within exact matches, MRU order should be preserved: 節程 before 設定")
    }

    func testPrefixMatchOrderPreservedWithinGroup() throws {
        try XCTSkipIf(ws == nil)
        WordSearch.setExactReadingMatchPriority(true)
        ws.study(word: "設定時間", reading: "setteijikan")
        ws.study(word: "設定画面", reading: "setteigamen")
        let results = ws.search(query: "settei", searchMode: 0)
        let words = results.map(\.word)
        guard let idxGamen = words.firstIndex(of: "設定画面"),
              let idxJikan = words.firstIndex(of: "設定時間") else {
            XCTFail("Expected both words in results: \(words)")
            return
        }
        XCTAssertLessThan(idxGamen, idxJikan,
            "Within prefix matches, MRU order should be preserved: 設定画面 before 設定時間")
    }

    func testLocalDictExactReadingMatchPrioritized() throws {
        try XCTSkipIf(ws == nil)
        WordSearch.setExactReadingMatchPriority(true)
        ws.register(word: "設定", reading: "settei")
        ws.register(word: "設定画面", reading: "setteigamen")
        let results = ws.search(query: "settei", searchMode: 0)
        let words = results.map(\.word)
        guard let idxSettei = words.firstIndex(of: "設定"),
              let idxGamen = words.firstIndex(of: "設定画面") else {
            XCTFail("Expected both words in results: \(words)")
            return
        }
        XCTAssertLessThan(idxSettei, idxGamen,
            "Local dict: exact reading match should come before prefix-only match")
    }

    func testDefaultDisabledPreservesExistingBehavior() throws {
        try XCTSkipIf(ws == nil)
        UserDefaults.standard.removeObject(forKey: "exactReadingMatchPriority")
        ws.study(word: "設定", reading: "settei")
        ws.study(word: "設定画面", reading: "setteigamen")
        let results = ws.search(query: "settei", searchMode: 0)
        let words = results.map(\.word)
        guard let idxSettei = words.firstIndex(of: "設定"),
              let idxGamen = words.firstIndex(of: "設定画面") else {
            XCTFail("Expected both words in results: \(words)")
            return
        }
        XCTAssertLessThan(idxGamen, idxSettei,
            "Default OFF: MRU order should be preserved (設定画面 before 設定)")
    }

    func testExactMatchSearchModeUnchanged() throws {
        try XCTSkipIf(ws == nil)
        ws.study(word: "設定", reading: "settei")
        ws.study(word: "設定画面", reading: "setteigamen")
        let results = ws.search(query: "settei", searchMode: 1)
        let words = results.map(\.word)
        XCTAssertTrue(words.contains("設定"))
        XCTAssertFalse(words.contains("設定画面"),
            "Exact search mode should not include prefix-only matches")
    }
}
