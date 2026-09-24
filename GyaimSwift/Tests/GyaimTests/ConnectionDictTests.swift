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

    /// Bundled dict.txt regression guard: fixed entries added from logs and the
    /// Mozc manual, plus productive suffix (化/的/性) and conditional (たら)
    /// compositions that must survive dictionary regeneration.
    func testBundledDictionaryTermsAndCompositions() throws {
        assertExactMatches([
            // migrated technical terms
            ("ripojitori", "リポジトリ"),
            ("zeijakuseisiken", "脆弱性試験"),
            ("so-suko-do", "ソースコード"),
            ("saitankeiro", "最短経路"),
            // Mozc manual terms
            ("ki-bo-dosho-tokatto", "キーボードショートカット"),
            ("kaigokannsei", "下位互換性"),
            ("tayousoninnshou", "多要素認証"),
            ("reiwa", "令和"),
            // log-driven fixed entries
            ("kairi", "乖離"),
            ("ruikei", "類型"),
            ("jusinn", "受診"),
            ("manabi", "学び"),
            ("siyou", "私用"),
            // productive 化 suffix
            ("kyokushoka", "局所化"),
            ("kyokusyoka", "局所化"),
            ("gengoka", "言語化"),
            ("kyokushokasuru", "局所化する"),
            ("chuushouka", "抽象化"),
            // productive 的 suffix
            ("chuushouteki", "抽象的"),
            ("chuushoutekina", "抽象的な"),
            ("chuushoutekini", "抽象的に"),
            ("kyokushoteki", "局所的"),
            ("kouzouteki", "構造的"),
            // productive 性 suffix
            ("saigensei", "再現性"),
            ("saigennsei", "再現性"),
            ("anzensei", "安全性"),
            ("gijutsusei", "技術性"),
            ("kouzousei", "構造性"),
            // conditional たら inflection
            ("owattara", "終わったら"),
            ("kawattara", "変わったら"),
            ("kaitara", "書いたら"),
        ])
    }

    func testConstrainedCompositionsReturnExactCompleteConversions() throws {
        // Issue #59 / ADR-022: the constraint set for dictionary-constrained
        // generation contains only complete conversions of the full reading.
        let compositions = dict.constrainedCompositions(pat: "kyokushoka")
        let words = compositions.map(\.word)

        XCTAssertTrue(words.contains("局所化"), "Expected 局所化 in \(words)")
        XCTAssertFalse(words.contains("局所化する"), "Prefix continuations must not appear: \(words)")
        XCTAssertEqual(words.count, Set(words).count, "Surfaces must be deduplicated: \(words)")
    }

    func testConstrainedCompositionsHonorResultCap() throws {
        let capped = dict.constrainedCompositions(pat: "kyokushoka", maxResults: 1)
        XCTAssertEqual(capped.count, 1)
    }

    func testConstrainedCompositionsExcludeExistingSurfacesWithoutConsumingSlots() throws {
        // BUG-028: excluded surfaces (the caller's existing candidates) must be
        // skipped during enumeration, not filtered afterwards — otherwise the
        // result cap fills with already-known compositions and nothing new
        // survives.
        let baseline = dict.constrainedCompositions(pat: "kyokushoka", maxResults: 1)
        let baselineWord = try XCTUnwrap(baseline.first?.word)

        let excluded = dict.constrainedCompositions(pat: "kyokushoka",
                                                    maxResults: 1,
                                                    excluding: [baselineWord])

        XCTAssertFalse(excluded.map(\.word).contains(baselineWord))
        // The slot freed by the exclusion is used for the next composition
        // (or stays empty if none exists) — never wasted on the excluded one.
        if let replacement = excluded.first {
            XCTAssertNotEqual(replacement.word, baselineWord)
        }
    }

    func testConstrainedCompositionsHonorDepthCap() throws {
        // 局所化する = 局所 + 化 + する (depth 3): a depth cap of 2 must block it
        // while the default cap allows it.
        let shallow = dict.constrainedCompositions(pat: "kyokushokasuru", maxDepth: 2)
        XCTAssertFalse(shallow.map(\.word).contains("局所化する"))

        let deep = dict.constrainedCompositions(pat: "kyokushokasuru")
        XCTAssertTrue(deep.map(\.word).contains("局所化する"), "Expected 局所化する in \(deep.map(\.word))")
    }

    /// ADR-030: UniDic サ変 nouns take する forms ("jissousimasu" -> 実装します);
    /// non-サ変 nouns (要件, 時間) must not.
    func testSahenNounsTakeSuruForms() throws {
        assertExactMatches([
            ("jissousimasu", "実装します"),
            ("tourokusite", "登録して"),
            ("kiyosita", "寄与した"),
            ("kakuninnsimasu", "確認します"),
        ])
        for pat in ["youkennsimasu", "jikannsimasu"] {
            var words: [String] = []
            dict.search(pat: pat, searchMode: 1) { word, _, _ in words.append(word) }
            XCTAssertFalse(words.contains { $0.hasSuffix("します") && $0.contains { ("\u{4E00}"..."\u{9FFF}").contains($0) } },
                           "non-サ変 noun composed with する for '\(pat)': \(words)")
        }
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
