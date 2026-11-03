@testable import Gyaim
import XCTest

/// ADR-040: a candidate that completes a dictionary compound with the previous
/// committed word (全体 + ぞう → 全体像) gets a bonus in LLM ranking.
final class CompoundCompletionTests: XCTestCase {
    private var tempDir = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("compound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeDict(_ lines: [String]) throws -> String {
        let path = tempDir.appendingPathComponent("dict.txt").path
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func resourcePaths() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let paths = ["dict.txt", "mozc-dict.txt"].map { root.appendingPathComponent("Resources/\($0)").path }
        for path in paths where !FileManager.default.fileExists(atPath: path) { throw XCTSkip("\(path) missing") }
        return paths
    }

    func testSingleEntryCompoundsYieldTheRemainder() throws {
        let dict = ConnectionDict(dictFile: try writeDict([
            "ぜんたい\t全体\t3\t4", "ぞう\t像\t3\t4", "ぞう\t増\t3\t4", "ぜんたいぞう\t全体像\t3\t4",
            "ぜんたいぞう\t全体増\t3\t4", "かいひさく\t回避さく\t3\t4", "ぜんたいず\t全体図\t3\t4",
        ]))
        XCTAssertEqual(dict.compoundCompletions(previousWord: "全体", kana: "ぜんたいぞう"), ["像", "増"],
                       "dictionary order, prefix removed")
        XCTAssertEqual(dict.compoundCompletions(previousWord: "全体", kana: "ぜんたいず"), ["図"])
        XCTAssertEqual(dict.compoundCompletions(previousWord: "回避", kana: "かいひさく"), ["さく"],
                       "the kana filter lives in WordSearch")
        XCTAssertEqual(dict.compoundCompletions(previousWord: "全部", kana: "ぜんたいぞう"), [],
                       "surface must start with the previous word")
        XCTAssertEqual(dict.compoundCompletions(previousWord: "全体像", kana: "ぜんたいぞう"), [],
                       "nothing left after the prefix")
        XCTAssertEqual(dict.compoundCompletions(previousWord: "", kana: "ぜんたいぞう"), [])
    }

    func testWordSearchConvertsReadingsAndKeepsKanjiOnBothSides() throws {
        let dictPath = try writeDict([
            "ぜんたい\t全体\t3\t4", "ぞう\t像\t3\t4", "ぜんたいぞう\t全体像\t3\t4",
            "かいひさく\t回避さく\t3\t4", "はいぞう\tは胃像\t3\t4",
        ])
        let ws = WordSearch(connectionDictFile: dictPath,
                            localDictFile: tempDir.appendingPathComponent("local.txt").path,
                            studyDictFile: tempDir.appendingPathComponent("study.txt").path)
        XCTAssertEqual(ws.compoundCompletions(previousWord: "全体", previousReading: "zentai", input: "zou"), ["像"],
                       "romaji readings are matched as kana (ADR-033)")
        XCTAssertEqual(ws.compoundCompletions(previousWord: "全体", previousReading: "ぜんたい", input: "zou"), ["像"],
                       "a kana-confirmed previous word keeps its kana reading")
        XCTAssertEqual(ws.compoundCompletions(previousWord: "全体", previousReading: "zentai", input: "zo"), [],
                       "incomplete romaji never matches")
        XCTAssertEqual(ws.compoundCompletions(previousWord: "回避", previousReading: "kaihi", input: "saku"), [],
                       "a kana remainder is reachable with the kana keys")
        XCTAssertEqual(ws.compoundCompletions(previousWord: "は", previousReading: "ha", input: "izou"), [],
                       "a kana previous word (particle) never forms a compound")
    }

    /// The bundled dictionaries: compounds that are one Mozc entry count,
    /// compositions through サ変 connections (分析 + できますか) do not.
    func testBundledDictionaryCases() throws {
        let paths = try resourcePaths()
        let ws = WordSearch(connectionDictFiles: paths,
                            localDictFile: tempDir.appendingPathComponent("local.txt").path,
                            studyDictFile: tempDir.appendingPathComponent("study.txt").path)
        XCTAssertEqual(ws.compoundCompletions(previousWord: "全体", previousReading: "zentai", input: "zou"), ["像"])
        XCTAssertEqual(ws.compoundCompletions(previousWord: "回避", previousReading: "kaihi", input: "saku"), ["策"])
        XCTAssertEqual(ws.compoundCompletions(previousWord: "徒歩", previousReading: "toho", input: "kenn"), ["圏"])
        XCTAssertEqual(ws.compoundCompletions(previousWord: "分析", previousReading: "bunseki", input: "dekimasuka"), [])
        XCTAssertEqual(ws.compoundCompletions(previousWord: "使用", previousReading: "siyou", input: "siyou"), [])
    }

    func testCommonSuffixLength() {
        XCTAssertEqual(GyaimController.commonSuffixLength("残る作業の全体", "業の全体"), 4)
        XCTAssertEqual(GyaimController.commonSuffixLength("abc", "xyz"), 0)
        XCTAssertEqual(GyaimController.commonSuffixLength("", "全体"), 0)
    }
}
