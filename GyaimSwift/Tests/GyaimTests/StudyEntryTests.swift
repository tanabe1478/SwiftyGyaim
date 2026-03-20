@testable import Gyaim
import XCTest

final class StudyEntryTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "studyDictEvictionMode")
    }

    // MARK: - StudyEntry score

    func testScoreIncreasesWithFrequency() {
        let now = Date().timeIntervalSince1970
        let low = StudyEntry(reading: "tokyo", word: "東京", lastAccessTime: now, frequency: 1)
        let high = StudyEntry(reading: "tokyo", word: "東京", lastAccessTime: now, frequency: 10)
        XCTAssertGreaterThan(high.score(), low.score())
    }

    func testScoreIncreasesWithRecency() {
        let old = StudyEntry(reading: "tokyo", word: "東京",
                             lastAccessTime: Date().timeIntervalSince1970 - 86400, frequency: 1)
        let recent = StudyEntry(reading: "tokyo", word: "東京",
                                lastAccessTime: Date().timeIntervalSince1970, frequency: 1)
        XCTAssertGreaterThan(recent.score(), old.score())
    }

    func testScoreDecreasesWithCharLength() {
        let now = Date().timeIntervalSince1970
        let short = StudyEntry(reading: "a", word: "ab", lastAccessTime: now, frequency: 1)
        let long = StudyEntry(reading: "a", word: "abcdef", lastAccessTime: now, frequency: 1)
        XCTAssertGreaterThan(short.score(), long.score())
    }

    // MARK: - EvictionMode

    func testEvictionModeDefault() {
        UserDefaults.standard.removeObject(forKey: "studyDictEvictionMode")
        XCTAssertEqual(EvictionMode.current, .mru)
    }

    func testEvictionModeSetAndGet() {
        EvictionMode.setCurrent(.mru)
        XCTAssertEqual(EvictionMode.current, .mru)

        EvictionMode.setCurrent(.none)
        XCTAssertEqual(EvictionMode.current, .none)

        EvictionMode.setCurrent(.scoreBased)
        XCTAssertEqual(EvictionMode.current, .scoreBased)
    }

    // MARK: - File I/O

    private func makeTempFile(_ content: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("studydict.txt")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    func testLoadStudyDictLegacyFormat() throws {
        let path = try makeTempFile("tokyo\t東京\nosaka\t大阪\n")
        let entries = WordSearch.loadStudyDict(dictFile: path)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].reading, "tokyo")
        XCTAssertEqual(entries[0].word, "東京")
        XCTAssertEqual(entries[0].frequency, 1)
        // lastAccessTime should be set to a recent value (within last minute)
        XCTAssertGreaterThan(entries[0].lastAccessTime, Date().timeIntervalSince1970 - 60)
    }

    func testLoadStudyDictNewFormat() throws {
        let path = try makeTempFile("tokyo\t東京\t1710000000.0\t5\nosaka\t大阪\t1710086400.0\t3\n")
        let entries = WordSearch.loadStudyDict(dictFile: path)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].reading, "tokyo")
        XCTAssertEqual(entries[0].word, "東京")
        XCTAssertEqual(entries[0].lastAccessTime, 1710000000.0, accuracy: 0.1)
        XCTAssertEqual(entries[0].frequency, 5)
    }

    func testSaveStudyDictWritesFourColumns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("studydict.txt").path
        let entries = [
            StudyEntry(reading: "tokyo", word: "東京", lastAccessTime: 1710000000.0, frequency: 5)
        ]
        WordSearch.saveStudyDict(dictFile: path, dict: entries)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let parts = content.trimmingCharacters(in: .newlines).split(separator: "\t")
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(String(parts[0]), "tokyo")
        XCTAssertEqual(String(parts[1]), "東京")
        XCTAssertEqual(String(parts[2]), "1710000000.0")
        XCTAssertEqual(String(parts[3]), "5")
    }

    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("studydict.txt").path
        let original = [
            StudyEntry(reading: "tokyo", word: "東京", lastAccessTime: 1710000000.0, frequency: 5),
            StudyEntry(reading: "osaka", word: "大阪", lastAccessTime: 1710086400.0, frequency: 3),
        ]
        WordSearch.saveStudyDict(dictFile: path, dict: original)
        let loaded = WordSearch.loadStudyDict(dictFile: path)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].reading, original[0].reading)
        XCTAssertEqual(loaded[0].word, original[0].word)
        XCTAssertEqual(loaded[0].lastAccessTime, original[0].lastAccessTime, accuracy: 0.1)
        XCTAssertEqual(loaded[0].frequency, original[0].frequency)
    }
}
