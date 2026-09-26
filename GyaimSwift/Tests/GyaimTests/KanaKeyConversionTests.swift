@testable import Gyaim
import XCTest

/// ADR-033: kana keys for the connection dictionary.
final class KanaKeyConversionTests: XCTestCase {
    private let rk = RomaKana()

    func testCompleteReadingsBecomeKanaKeys() {
        XCTAssertEqual(rk.roma2kanaKey("shuusei"), "しゅうせい")
        XCTAssertEqual(rk.roma2kanaKey("syuusei"), "しゅうせい")
        XCTAssertEqual(rk.roma2kanaKey("kan"), "かん")
        XCTAssertEqual(rk.roma2kanaKey("kann"), "かん")
        XCTAssertEqual(rk.roma2kanaKey("katta"), "かった")
        XCTAssertEqual(rk.roma2kanaKey("3"), "3", "digits survive as literal keys")
        XCTAssertEqual(rk.roma2kanaKey("ページ"), "ぺーじ", "kana rows are normalized to hiragana")
        XCTAssertEqual(rk.roma2kanaKey("・"), "・")
    }

    func testTypedPrefixKeepsIncompleteLettersAsTail() {
        XCTAssertEqual(rk.roma2kanaPrefix("kak"), KanaPrefixConversion(kana: "か", tail: "k", romajiEnds: [2]))
        XCTAssertEqual(rk.roma2kanaPrefix("kan"), KanaPrefixConversion(kana: "か", tail: "n", romajiEnds: [2]),
                       "a final n may still become な行, so it is not ん yet")
        XCTAssertEqual(rk.roma2kanaPrefix("kann"), KanaPrefixConversion(kana: "かん", tail: "", romajiEnds: [2, 4]))
        XCTAssertEqual(rk.roma2kanaPrefix("katt"), KanaPrefixConversion(kana: "かっ", tail: "t", romajiEnds: [2, 3]))
        XCTAssertEqual(rk.roma2kanaPrefix("ky"), KanaPrefixConversion(kana: "", tail: "ky", romajiEnds: []))
        XCTAssertEqual(rk.roma2kanaPrefix("kya"), KanaPrefixConversion(kana: "きゃ", tail: "", romajiEnds: [3, 3]))
        XCTAssertEqual(rk.roma2kanaPrefix("3ko"), KanaPrefixConversion(kana: "3こ", tail: "", romajiEnds: [1, 3]))
        XCTAssertEqual(rk.roma2kanaPrefix("n"), KanaPrefixConversion(kana: "", tail: "n", romajiEnds: []))
    }

    func testTailMatchesTheNextKanaChunk() {
        XCTAssertTrue(rk.chunkMatches(tail: "k", in: Array("かくにん"), at: 1))
        XCTAssertFalse(rk.chunkMatches(tail: "k", in: Array("かえる"), at: 1))
        XCTAssertTrue(rk.chunkMatches(tail: "n", in: Array("かんすう"), at: 1), "ん spelled nn")
        XCTAssertTrue(rk.chunkMatches(tail: "n", in: Array("かな"), at: 1))
        XCTAssertTrue(rk.chunkMatches(tail: "t", in: Array("かった"), at: 1), "っ binds to the next kana: tta")
        XCTAssertTrue(rk.chunkMatches(tail: "ky", in: Array("きゃく"), at: 0))
        XCTAssertFalse(rk.chunkMatches(tail: "ky", in: Array("きた"), at: 0))
        XCTAssertTrue(rk.chunkMatches(tail: "sh", in: Array("しゅうせい"), at: 0), "either spelling of しゅ")
        XCTAssertTrue(rk.chunkMatches(tail: "sy", in: Array("しゅうせい"), at: 0))
        XCTAssertTrue(rk.firstKanaCharacters(compatibleWith: "n").isSuperset(of: ["な", "に", "ん"]))
        XCTAssertFalse(rk.firstKanaCharacters(compatibleWith: "k").contains("さ"))
    }

    func testCanonicalRomajiRoundTrips() {
        XCTAssertEqual(rk.roma2kanaKey(rk.canonicalRomaji(ofKana: "かくにん")), "かくにん")
        XCTAssertEqual(rk.roma2kanaKey(rk.canonicalRomaji(ofKana: "しゅうせい")), "しゅうせい")
        XCTAssertEqual(rk.roma2kanaKey(rk.canonicalRomaji(ofKana: "かった")), "かった")
    }

    func testRomaToKanaLookupMatchesGreedyLongestKey() {
        // Same table, table-lookup instead of a scan over ~350 keys.
        for (roma, kana) in [("kya", "きゃ"), ("xtu", "っ"), ("kkya", "っきゃ"), ("nn", "ん"), ("kan", "かん"),
                             ("shinn", "しん"), ("tsu", "つ"), ("kaigokannsei", "かいごかんせい"), ("-", "ー")] {
            XCTAssertEqual(rk.roma2hiragana(roma), kana, roma)
        }
    }
}

/// ADR-033: the connection dictionary matches every romaji spelling of a reading.
final class ConnectionDictKanaKeyTests: XCTestCase {
    private func makeDict(_ rows: String) throws -> ConnectionDict {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kana-key-\(UUID().uuidString).txt")
        try rows.write(to: url, atomically: true, encoding: .utf8)
        return ConnectionDict(dictFile: url.path)
    }

    private func words(_ dict: ConnectionDict, _ pat: String, mode: Int) -> [(String, String)] {
        var result: [(String, String)] = []
        dict.search(pat: pat, searchMode: mode) { word, pat, _ in result.append((word, pat)) }
        return result
    }

    func testSpellingVariantsReachTheSameEntry() throws {
        let dict = try makeDict("shuusei\t修正\t3\t4\nkannsu\t関数\t3\t4\nkana\t仮名\t3\t4\nkanzi\t漢字\t3\t4\n")
        XCTAssertEqual(words(dict, "syuusei", mode: 1).map(\.0), ["修正"])
        XCTAssertEqual(words(dict, "shuusei", mode: 1).map(\.0), ["修正"])
        XCTAssertEqual(words(dict, "kansu", mode: 1).map(\.0), ["関数"], "kansu and kannsu are the same kana")
        // "kan" while typing: か + pending n reaches かん… and かな…, in dictionary order.
        XCTAssertEqual(words(dict, "kan", mode: 0).map(\.0), ["関数", "仮名", "漢字"])
        XCTAssertEqual(words(dict, "kann", mode: 0).map(\.0), ["関数", "漢字"])
        XCTAssertEqual(words(dict, "sy", mode: 0).map(\.0), ["修正"])
        XCTAssertEqual(words(dict, "sh", mode: 0).map(\.0), ["修正"])
        XCTAssertTrue(words(dict, "kae", mode: 0).isEmpty)
    }

    func testPredictionReadingsExtendTheTypedRomaji() throws {
        let dict = try makeDict("kakuninn\t確認\t3\t4\nkakuninn\t確認\t50\t51\nsite\tして\t51\t84\n")
        XCTAssertEqual(words(dict, "kak", mode: 0).first?.1, "kakuninn")
        XCTAssertEqual(words(dict, "kakuninnsi", mode: 0).map { $0 }.first { $0.0 == "確認して" }?.1, "kakuninnsite")
        XCTAssertEqual(words(dict, "kakuninnsite", mode: 1).first { $0.0 == "確認して" }?.1, "kakuninnsite",
                       "an exact composition reports the typed romaji")
    }

    func testDigitsCompose() throws {
        let dict = try makeDict("3\t3\t56\t56\nko\t個\t56\t4\nko\t子\t3\t4\n")
        XCTAssertEqual(words(dict, "3ko", mode: 1).map(\.0), ["3個"])
        XCTAssertEqual(words(dict, "3k", mode: 0).map(\.0), ["3個"])
    }

    func testResultCapStopsTheWalk() throws {
        let dict = try makeDict((0..<50).map { "ka\(String(repeating: "i", count: 1))\t語\($0)\t3\t4" }.joined(separator: "\n"))
        var count = 0
        dict.searchDetailed(pat: "k", searchMode: 0, maxResults: 7) { _ in count += 1 }
        XCTAssertEqual(count, 7)
    }
}
