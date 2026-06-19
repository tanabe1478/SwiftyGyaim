@testable import Gyaim
import XCTest

final class ConnectionDictTests: XCTestCase {
    var dict: ConnectionDict!

    override func setUpWithError() throws {
        // Try test bundle first
        if let path = Bundle(for: type(of: self)).path(forResource: "dict", ofType: "txt") {
            dict = ConnectionDict(dictFile: path)
            return
        }
        // Fall back to source tree path
        let sourceFile = URL(fileURLWithPath: #file)
        let projectDir = sourceFile
            .deletingLastPathComponent() // GyaimTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // GyaimSwift
        let dictPath = projectDir.appendingPathComponent("Resources/dict.txt").path
        if FileManager.default.fileExists(atPath: dictPath) {
            dict = ConnectionDict(dictFile: dictPath)
            return
        }
        throw XCTSkip("dict.txt not found")
    }

    func testSearchSimple() throws {
        var results: [(String, String)] = []
        dict.search(pat: "man", searchMode: 1) { word, pat, _ in
            results.append((word, pat))
        }
        let words = results.map(\.0)
        XCTAssertTrue(words.contains("万"), "Expected '万' in results: \(words)")
    }

    func testSearchPrefixMode() throws {
        var results: [(String, String)] = []
        dict.search(pat: "tou", searchMode: 0) { word, pat, _ in
            results.append((word, pat))
        }
        XCTAssertFalse(results.isEmpty, "Expected results for prefix 'tou'")
    }

    func testSearchCompound() throws {
        // "i"(言, in=10, out=11) + "*います"(in=11) = "言います"
        var results: [(String, String)] = []
        dict.search(pat: "iimasu", searchMode: 1) { word, pat, _ in
            results.append((word, pat))
        }
        let words = results.map(\.0)
        // The compound should include words connected via outConnection
        XCTAssertTrue(words.contains { $0.contains("言") },
                      "Expected compound containing '言' in results: \(words)")
    }

    func testDetailedSearchReportsCompoundDepth() throws {
        var results: [ConnectionSearchResult] = []
        dict.searchDetailed(pat: "kyokushoka", searchMode: 1) { result in
            results.append(result)
        }
        let match = results.first { $0.word == "局所化" }
        XCTAssertNotNil(match, "Expected 局所化 in results: \(results.map(\.word))")
        XCTAssertGreaterThan(match?.depth ?? 0, 1)
    }

    func testInternalConnectionLabelsDoNotContributeSurface() throws {
        var results: [ConnectionSearchResult] = []
        dict.searchDetailed(pat: "omoku", searchMode: 0) { result in
            results.append(result)
        }
        let words = results.map(\.word)
        XCTAssertFalse(words.contains("重い形容詞"), "Internal label should not be surfaced: \(words)")
        XCTAssertFalse(words.contains("おもい形容詞"), "Internal label should not be surfaced: \(words)")
        XCTAssertTrue(words.contains("重く"), "Natural inflection should remain: \(words)")
    }

    func testSearchMigratedTechnicalTerms() throws {
        let expectations = [
            ("ripojitori", "リポジトリ"),
            ("zeijakuseisiken", "脆弱性試験"),
            ("so-suko-do", "ソースコード"),
            ("saitankeiro", "最短経路")
        ]

        assertExactMatches(expectations)
    }

    func testSearchMozcManualTerms() throws {
        let expectations = [
            ("ki-bo-dosho-tokatto", "キーボードショートカット"),
            ("kaigokannsei", "下位互換性"),
            ("tayousoninnshou", "多要素認証"),
            ("reiwa", "令和")
        ]

        assertExactMatches(expectations)
    }

    func testProductiveKaSuffixCompounds() throws {
        let expectations = [
            ("kyokushoka", "局所化"),
            ("kyokusyoka", "局所化"),
            ("gengoka", "言語化"),
            ("kyokushokasuru", "局所化する"),
            ("chuushouka", "抽象化")
        ]

        assertExactMatches(expectations)
    }

    func testLogDrivenFixedDictionaryTerms() throws {
        let expectations = [
            ("kairi", "乖離"),
            ("ruikei", "類型"),
            ("jusinn", "受診"),
            ("manabi", "学び"),
            ("siyou", "私用")
        ]

        assertExactMatches(expectations)
    }

    func testProductiveTekiSuffixCompounds() throws {
        let expectations = [
            ("chuushouteki", "抽象的"),
            ("chuushoutekina", "抽象的な"),
            ("chuushoutekini", "抽象的に"),
            ("kyokushoteki", "局所的"),
            ("kouzouteki", "構造的")
        ]

        assertExactMatches(expectations)
    }

    func testProductiveSeiSuffixCompounds() throws {
        let expectations = [
            ("saigensei", "再現性"),
            ("saigennsei", "再現性"),
            ("anzensei", "安全性"),
            ("gijutsusei", "技術性"),
            ("kouzousei", "構造性")
        ]

        assertExactMatches(expectations)
    }

    func testConditionalTtaraInflection() throws {
        let expectations = [
            ("owattara", "終わったら"),
            ("kawattara", "変わったら"),
            ("kaitara", "書いたら")
        ]

        assertExactMatches(expectations)
    }

    private func assertExactMatches(_ expectations: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        for (pat, expectedWord) in expectations {
            var words: [String] = []
            dict.search(pat: pat, searchMode: 1) { word, _, _ in
                if word.hasSuffix("*") { return }
                words.append(word.replacingOccurrences(of: "*", with: ""))
            }
            XCTAssertTrue(words.contains(expectedWord),
                          "Expected '\(expectedWord)' for '\(pat)' in results: \(words)",
                          file: file,
                          line: line)
        }
    }
}
