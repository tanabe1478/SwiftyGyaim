@testable import Gyaim
import XCTest

final class RomaKanaTests: XCTestCase {
    let rk = RomaKana()

    // MARK: - roma2hiragana

    func testRoma2Hiragana() {
        let cases: [(String, String)] = [
            ("masui", "ますい"),
            ("a", "あ"), ("i", "い"), ("u", "う"), ("e", "え"), ("o", "お"),
            // ん: nn, n before consonant, n at end
            ("nn", "ん"), ("hannnya", "はんにゃ"),
            ("kanka", "かんか"), ("senpai", "せんぱい"), ("san", "さん"),
            // っ
            ("kitto", "きっと"), ("gakkari", "がっかり"),
            ("toukyou", "とうきょう"),
            ("sha", "しゃ"), ("chi", "ち"), ("tsu", "つ"),
            // symbols and small kana
            ("-", "ー"), ("xtu", "っ"), ("xa", "ぁ"),
        ]
        for (roma, kana) in cases {
            XCTAssertEqual(rk.roma2hiragana(roma), kana, roma)
        }
    }

    // MARK: - roma2katakana

    func testRoma2Katakana() {
        XCTAssertEqual(rk.roma2katakana("vaiorinn"), "ヴァイオリン")
        XCTAssertEqual(rk.roma2katakana("katto"), "カット")
        XCTAssertEqual(rk.roma2katakana("-"), "ー")
    }

    // MARK: - hiragana2roma

    func testBasicHiragana2Roma() {
        let results = rk.hiragana2roma("ますい")
        XCTAssertTrue(results.contains("masui"), "Expected 'masui' in \(results)")
    }

    func testHiragana2RomaMultiple() {
        let results = rk.hiragana2roma("じしょ")
        XCTAssertTrue(results.contains("jisho") || results.contains("zisho"),
                       "Expected jisho/zisho variant in \(results)")
    }

    // MARK: - katakana2roma

    func testBasicKatakana2Roma() {
        let results = rk.katakana2roma("ヴァイオリン")
        XCTAssertTrue(results.contains("vaiorinn"), "Expected 'vaiorinn' in \(results)")
    }

    // MARK: - Round-trip

    func testRoundTripSimple() {
        // Words where roma->hira->roma round-trips exactly
        let words = ["masui", "toukyou", "kitto", "sha", "chi"]
        for word in words {
            let hira = rk.roma2hiragana(word)
            let back = rk.hiragana2roma(hira)
            XCTAssertTrue(back.contains(word),
                          "Round-trip failed for '\(word)': hira='\(hira)', back=\(back)")
        }
    }

    func testNBeforeConsonantRoundTrip() {
        // "senpai" uses abbreviated 'n' before consonant, reverse always produces "nn"
        let hira = rk.roma2hiragana("senpai")
        XCTAssertEqual(hira, "せんぱい")
        let back = rk.hiragana2roma(hira)
        XCTAssertTrue(back.contains("sennpai"), "Expected 'sennpai' in \(back)")
    }

    // MARK: - Edge cases

    func testEmptyString() {
        XCTAssertEqual(rk.roma2hiragana(""), "")
        XCTAssertEqual(rk.roma2katakana(""), "")
    }
}
