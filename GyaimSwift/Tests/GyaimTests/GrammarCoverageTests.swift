@testable import Gyaim
import XCTest

/// ADR-042: one conversion covers a content word plus its hiragana tail.
/// The matrix is the spec; every cell must compose from dict.txt + grammar-dict.txt.
final class GrammarCoverageTests: XCTestCase {
    private static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    private static let dictPath = resources.appendingPathComponent("dict.txt").path
    private static let grammarPath = resources.appendingPathComponent("grammar-dict.txt").path

    func testEveryPredicateTailComposes() {
        let dict = ConnectionDict(dictFiles: [Self.dictPath, Self.grammarPath])
        let cells = GrammarCoverageMatrix.cells()
        XCTAssertGreaterThan(cells.count, 5000, "the matrix lost cells")

        var missing: [String] = []
        for cell in cells where !compose(cell.reading, in: dict).contains(cell.expected) {
            missing.append("\(cell.lexeme) \(cell.form) + \(cell.tail.isEmpty ? "(なし)" : cell.tail) → \(cell.expected)")
        }
        XCTAssertTrue(missing.isEmpty, "\(missing.count) of \(cells.count) cells do not compose: \(missing.prefix(30))")
    }

    /// Tail compositions come after everything the dictionary alone produces, in
    /// the same order: `settei` also reads 競って + い…, `naiyou` ない + よう…,
    /// and those must not push 設定 / 内容 down the list.
    func testGrammarNeverDisplacesDictionaryResults() {
        let base = ConnectionDict(dictFile: Self.dictPath)
        let withGrammar = ConnectionDict(dictFiles: [Self.dictPath, Self.grammarPath])
        let queries = ["settei", "naiyou", "kaig", "kaiga", "hasin", "kaisyan", "tukat", "tukatte", "takai", "nai",
                       "site", "kaite", "iku", "aru", "s", "ka"]
        for query in queries {
            let expected = predictions(query, in: base)
            let actual = predictions(query, in: withGrammar)
            XCTAssertEqual(Array(actual.prefix(expected.count)), expected, "dictionary results moved for \(query)")
        }
        XCTAssertTrue(predictions("settei", in: withGrammar).count > predictions("settei", in: base).count,
                      "the tail predictions are still there, after the dictionary's")
    }

    func testRomajiInputReachesTheSameTails() {
        let dict = ConnectionDict(dictFiles: [Self.dictPath, Self.grammarPath])
        for (romaji, expected) in [("hokannsarerubeki", "補完されるべき"), ("siyousurubeki", "使用するべき"),
                                   ("tukaubekidehanai", "使うべきではない"), ("kakutameni", "書くために"),
                                   ("takaidesu", "高いです"), ("tukattemiru", "使ってみる"), ("surebaii", "すればいい"),
                                   ("nemukunaru", "眠くなる"), ("kaitemiru", "書いてみる")] {
            XCTAssertTrue(compose(romaji, in: dict).contains(expected), "\(romaji) → \(expected)")
        }
    }

    func testGrammarIsLeftOutWhenAnImportedDictionaryIsActive() {
        XCTAssertEqual(Config.connectionDictFiles(gictionaryPath: "/b/dict.txt", bundleDictPath: "/b/dict.txt",
                                                  grammarDictPath: "/b/grammar-dict.txt", mozcDictPath: "/b/mozc-dict.txt"),
                       ["/b/dict.txt", "/b/grammar-dict.txt", "/b/mozc-dict.txt"])
        XCTAssertEqual(Config.connectionDictFiles(gictionaryPath: "/home/connectiondict.txt", bundleDictPath: "/b/dict.txt",
                                                  grammarDictPath: "/b/grammar-dict.txt", mozcDictPath: "/b/mozc-dict.txt"),
                       ["/home/connectiondict.txt", "/b/mozc-dict.txt"],
                       "an imported dictionary numbers its connection classes differently")
    }

    private func compose(_ reading: String, in dict: ConnectionDict) -> Set<String> {
        var words: Set<String> = []
        dict.searchDetailed(pat: reading, searchMode: 1, maxResults: WordSearch.maxConnectionCandidates) { result in
            words.insert(result.word.replacingOccurrences(of: "*", with: ""))
        }
        return words
    }

    private func predictions(_ reading: String, in dict: ConnectionDict) -> [String] {
        var words: [String] = []
        dict.searchDetailed(pat: reading, searchMode: 0, maxResults: WordSearch.maxConnectionCandidates) { result in
            words.append(result.word)
        }
        return words
    }
}
