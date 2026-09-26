@testable import Gyaim
import XCTest

/// Golden test for dictionary search results on the bundled dict.txt.
///
/// `Tests/GyaimTests/Fixtures/dictionary-search-golden.json` holds, per query
/// and mode, the (word, reading, source, kind) list WordSearch returned and the
/// (word, pat, depth) list ConnectionDict emitted before the kana-keyed index
/// (2026-09-26). The index may return more (romaji spelling variants) but every
/// golden result must still appear, in the same relative order. Known, accepted
/// difference: a query is split at kana boundaries, so "nn" is ん and can no
/// longer be read as the lone-"n" row `n る` followed by an "n…" continuation
/// (old "nn" -> るなさい / るながら); those queries are not in the fixture.
///
/// GYAIM_DICT_GOLDEN_WRITE=<path> regenerates the fixture from the current code.
final class DictionarySearchGoldenTests: XCTestCase {
    private static let queries: [String] = {
        var list = ["k", "ka", "kak", "kaku", "kakuninn", "kakuninnsite", "kakuninnsimasu", "s", "si", "sit", "site",
                    "settei", "setteigamenn", "syuusei", "shuusei", "syu", "sy", "sh", "m", "mi", "mita", "mitai",
                    "yo", "yoi", "youkenn", "youkennteigi", "ko", "kono", "no", "n", "ni", "wo", "de", "t", "to",
                    "tesuto", "jissou", "jissousimasu", "jisso", "zissou", "kan", "kann", "kannsu", "kansu", "kat",
                    "katt", "katta", "tuka", "tsuka", "tukat", "tukatta", "ti", "chi", "tiisai", "chiisai", "hu",
                    "fu", "fuairu", "wa", "wakaranai", "ha", "hatu", "hattu", "kyou", "kyo", "ky", "ripojitori",
                    "ripozitori", "ko-do", "ko-", "kaigokannsei", "reiwa", "owattara", "kudasa", "kudasai", "?",
                    "!", ".", ",", "-", "xa", "ltu", "xtu", "a", "i", "u", "e", "o", "ga", "gap",
                    "onegai", "onegaisimasu", "kaeru", "kaer", "sukuna", "sukunai", "mu", "muki", "toshi", "tosi",
                    "kousin", "kousinn", "kousinnsuru", "kimi", "ki", "hou", "houkoku", "houkokusite", "kai",
                    "kaigi", "ryou", "daigaku", "otyanomizu", "ochanomizu", "otyanomizujosidaigaku", "meguro",
                    "megurotyou", "sannko", "3ko", "2", "10funn", "nenn", "nennnotame", "z", "zu", "zyu", "ju",
                    "jyu", "jyunnbann", "junnbann", "tya", "cha", "tyanto", "chanto"]
        return list
    }()

    private struct Golden: Codable {
        struct WordResult: Codable, Equatable { let word: String; let reading: String?; let source: String; let kind: String }
        struct ConnectionResult: Codable, Equatable { let word: String; let pat: String; let depth: Int }
        var wordSearch: [String: [WordResult]]      // "<mode>:<query>"
        var connection: [String: [ConnectionResult]]
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/dictionary-search-golden.json")

    private func makeSearch(tempDir: URL) throws -> (WordSearch, ConnectionDict) {
        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dictPath = projectDir.appendingPathComponent("Resources/dict.txt").path
        let empty = tempDir.appendingPathComponent("empty.txt").path
        try "".write(toFile: empty, atomically: true, encoding: .utf8)
        let study = tempDir.appendingPathComponent("study.txt").path
        try "".write(toFile: study, atomically: true, encoding: .utf8)
        return (WordSearch(connectionDictFile: dictPath, localDictFile: empty, studyDictFile: study),
                ConnectionDict(dictFile: dictPath))
    }

    /// `head` limits each list (the fixture keeps heads only: a one-letter query's
    /// tail is dictionary-order noise); the comparison side is unlimited.
    private func collect(_ ws: WordSearch, _ cd: ConnectionDict, head: Int) -> Golden {
        var golden = Golden(wordSearch: [:], connection: [:])
        for mode in [0, 1] {
            for query in Self.queries {
                golden.wordSearch["\(mode):\(query)"] = ws.search(query: query, searchMode: mode).prefix(head).map {
                    Golden.WordResult(word: $0.word, reading: $0.reading, source: String(describing: $0.source),
                                      kind: $0.kind.rawValue)
                }
                var results: [Golden.ConnectionResult] = []
                cd.searchDetailed(pat: query, searchMode: mode) {
                    if results.count < head {
                        results.append(Golden.ConnectionResult(word: $0.word, pat: $0.pat, depth: $0.depth))
                    }
                }
                golden.connection["\(mode):\(query)"] = results
            }
        }
        return golden
    }

    func testResultsContainGoldenInOrder() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("gyaim-golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let (ws, cd) = try makeSearch(tempDir: tempDir)
        if let out = ProcessInfo.processInfo.environment["GYAIM_DICT_GOLDEN_WRITE"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(collect(ws, cd, head: 150)).write(to: URL(fileURLWithPath: out))
            print("golden written to \(out)")
            return
        }

        let current = collect(ws, cd, head: .max)
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: Self.fixtureURL))
        for (key, expected) in golden.wordSearch.sorted(by: { $0.key < $1.key }) {
            let actual = current.wordSearch[key] ?? []
            // Words only: readings of predictions may be rendered in another romaji spelling.
            assertSubsequence(expected.map(\.word), actual.map(\.word), "WordSearch \(key)")
            for row in expected where row.kind == "exact" {
                let rows = actual.filter { $0.word == row.word }
                XCTAssertTrue(rows.contains { $0.kind == "exact" },
                              "exact kind lost: \(key) \(row.word) golden=\(row) actual=\(rows)")
            }
        }
        for (key, expected) in golden.connection.sorted(by: { $0.key < $1.key }) {
            // Romaji spelling rows of one word collapse into one kana entry, so compare first occurrences.
            assertSubsequence(firstOccurrences(expected.map(\.word)),
                              firstOccurrences((current.connection[key] ?? []).map(\.word)), "ConnectionDict \(key)")
        }
        ws.finish()
    }

    private func firstOccurrences(_ words: [String]) -> [String] {
        var seen: Set<String> = []
        return words.filter { seen.insert($0).inserted }
    }

    private func assertSubsequence(_ expected: [String], _ actual: [String], _ label: String) {
        var index = 0
        for word in expected {
            while index < actual.count, actual[index] != word { index += 1 }
            if index == actual.count {
                let positions = expected.prefix(40).map { word in actual.firstIndex(of: word).map(String.init) ?? "-" }
                XCTFail("\(label): \(word) missing or out of order (actual count \(actual.count)). "
                    + "positions of expected in actual: \(positions.joined(separator: " "))")
                return
            }
            index += 1
        }
    }
}
