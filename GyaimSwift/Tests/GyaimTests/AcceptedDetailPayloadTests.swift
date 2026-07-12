@testable import Gyaim
import XCTest

/// Preference-pair extraction payload (issue #57 / M6-1).
final class AcceptedDetailPayloadTests: XCTestCase {
    private func makeCandidates() -> [SearchCandidate] {
        [
            SearchCandidate(word: "kousin", kind: .raw),
            SearchCandidate(word: "行進", reading: "kousin", source: .study, kind: .exact, studyFrequency: 11),
            SearchCandidate(word: "更新", reading: "kousinn", source: .study, kind: .exact, studyFrequency: 101),
        ]
    }

    func testPayloadEncodesChosenRankMetadataAndAffinity() throws {
        let payload = try XCTUnwrap(GyaimController.acceptedDetailPayload(
            candidates: makeCandidates(),
            chosenIndex: 2,
            context: "アプリを",
            affinityProvider: { $0.word == "更新" ? 0.75 : 0 }))

        XCTAssertFalse(payload.contains("\n"), "payload must stay a single log line")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(object["chosenRank"] as? Int, 2)
        XCTAssertEqual(object["context"] as? String, "アプリを")

        let top = try XCTUnwrap(object["top"] as? [[String: Any]])
        XCTAssertEqual(top.count, 3)
        let chosen = try XCTUnwrap(top.first { ($0["word"] as? String) == "更新" })
        XCTAssertEqual(chosen["reading"] as? String, "kousinn")
        XCTAssertEqual(chosen["studyFrequency"] as? Int, 101)
        XCTAssertEqual(chosen["contextAffinity"] as? Double, 0.75)
        XCTAssertEqual(chosen["rank"] as? Int, 2)

        // Raw input carries no reading — the extractor drops it from pairs.
        let raw = try XCTUnwrap(top.first { ($0["word"] as? String) == "kousin" })
        XCTAssertNil(raw["reading"])
    }

    func testPayloadIncludesChosenBeyondHeadLimit() throws {
        var candidates = makeCandidates()
        for index in 0..<10 {
            candidates.append(SearchCandidate(word: "候補\(index)",
                                              reading: "kouho\(index)",
                                              source: .connection,
                                              kind: .prefix))
        }

        let payload = try XCTUnwrap(GyaimController.acceptedDetailPayload(
            candidates: candidates,
            chosenIndex: 12,
            context: "",
            affinityProvider: { _ in 0 }))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let top = try XCTUnwrap(object["top"] as? [[String: Any]])
        XCTAssertEqual(top.count, 9, "head 8 plus the chosen candidate")
        XCTAssertTrue(top.contains { ($0["rank"] as? Int) == 12 })
    }

    func testShouldStudyKanaConfirmSkipsHiraganaByDefault() {
        UserDefaults.standard.removeObject(forKey: "kanaConfirmStudyEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "kanaConfirmStudyEnabled") }

        // Hiragana confirms are regenerable raw spellings — no learning.
        XCTAssertFalse(GyaimController.shouldStudyKanaConfirm(hiragana: true))
        // Katakana confirms are orthography choices — keep learning.
        XCTAssertTrue(GyaimController.shouldStudyKanaConfirm(hiragana: false))

        // Historical behavior can be restored explicitly.
        UserDefaults.standard.set(true, forKey: "kanaConfirmStudyEnabled")
        XCTAssertTrue(GyaimController.shouldStudyKanaConfirm(hiragana: true))
    }

    func testPayloadNilForInvalidIndex() {
        XCTAssertNil(GyaimController.acceptedDetailPayload(candidates: [],
                                                           chosenIndex: 0,
                                                           context: "",
                                                           affinityProvider: { _ in 0 }))
    }
}
