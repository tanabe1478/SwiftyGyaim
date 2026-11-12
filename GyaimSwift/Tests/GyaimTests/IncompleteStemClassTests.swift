@testable import Gyaim
import XCTest

/// BUG-049: the unfinished-stem rule asks the dictionary whether a candidate is
/// a finished word before trusting a one-character-longer neighbour.
final class IncompleteStemClassTests: XCTestCase {
    private static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    private static let bundled = ["dict.txt", "grammar-dict.txt", "mozc-dict.txt"].map {
        resources.appendingPathComponent($0).path
    }
    private let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("stem-class-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Every (reading, word) here has a one-character-longer candidate ending in
    /// い (or follows a っ) in the same list, which is all the text rule looks at.
    func testOnlyConjugationStemsAreUnfinished() {
        let search = wordSearch(Self.bundled)
        let finished = [("kimoti", "気持ち"), ("kimochi", "気持ち"), ("kakko", "かっこ"), ("nara", "なら"), ("ga", "が"),
                        ("sima", "しま"), ("sina", "しな"), ("kire", "きれ"), ("nasa", "なさ"), ("tadasi", "正し"),
                        ("otetudai", "お手伝")]
        let stems = [("kudasa", "くださ"), ("kudasa", "下さ"), ("muka", "向か"), ("tumarana", "つまらな"),
                     ("aziwa", "味わ"), ("irassha", "いらっしゃ"), ("yasu", "やす"), ("sumana", "済まな"),
                     ("toriatsuka", "取り扱"), ("kona", "こな"), ("suma", "住ま"), ("soxtu", "そっ")]
        for (expected, cases) in [(false, finished), (true, stems)] {
            for (reading, word) in cases {
                let request = request(for: reading, in: search)
                guard let candidate = request.candidates.first(where: { $0.text == word }) else {
                    XCTFail("\(word) is not a candidate of \(reading)")
                    continue
                }
                XCTAssertTrue(request.candidates.contains {
                    AIReranker.isIncompleteStemCompletion(stem: word, completed: $0.text)
                }, "\(reading): no longer candidate completes \(word), the case tests nothing")
                XCTAssertEqual(AIReranker.isIncompleteStem(candidate, in: request), expected, "\(reading) \(word)")
            }
        }
    }

    /// 2026-11-12 12:24:03 `kimoti`: the model scored 気持 -0.009 and 気持ち -0.122,
    /// the user had picked 気持ち 8 times and 気持 6, and 気持 still came first.
    func testLearnedNounBeatsItsShorterSpelling() {
        func order(completeWord: Bool?) -> [Int] {
            let request = AIRerankRequest(version: 1, mode: "fast-context-rerank", inputPat: "kimoti",
                                          hiragana: "きもち", context: "気持ちがで気持が", candidates: [
                AIRerankCandidate(index: 0, text: "気持", reading: "kimoti", source: "study", kind: "exact",
                                  studyFrequency: 6),
                AIRerankCandidate(index: 1, text: "気持ち", reading: "kimoti", source: "study", kind: "exact",
                                  studyFrequency: 8, completeWord: completeWord),
                AIRerankCandidate(index: 2, text: "気持ちい", reading: "kimotii", source: "connection", kind: "prefix"),
            ])
            return BundledZenzRuntime.llmPrimaryOrder(request: request, heuristicOrder: [0, 1, 2],
                                                      llmScores: [0: -0.0088, 1: -0.1218, 2: -5.635],
                                                      studyWeight: 2.0, contextWeight: 2.0, rawHiraganaPenalty: 1.0,
                                                      compoundWeight: 2.0).order
        }
        XCTAssertEqual(order(completeWord: nil).first, 0, "without the dictionary's word class the bug reproduces")
        XCTAssertEqual(order(completeWord: true).first, 1)
    }

    func testImportedDictionaryKeepsTheTextRule() {
        let search = wordSearch(Self.bundled.filter { !$0.hasSuffix("grammar-dict.txt") })
        let request = request(for: "kimoti", in: search)
        XCTAssertNil(request.candidates.first { $0.text == "気持ち" }?.completeWord,
                     "stem classes come with grammar-dict.txt, which an imported dictionary leaves out")
    }

    /// Only conjugation endings follow a stem class (nothing at all follows 180,
    /// a 未然形 class). A class that a word-starting entry can follow is not one.
    func testStemClassesAreFollowedOnlyByEndings() {
        let dict = ConnectionDict(dictFiles: Array(Self.bundled.prefix(2)))
        XCTAssertFalse(dict.stemClasses.isEmpty)
        for stemClass in dict.stemClasses.sorted() {
            let followers = dict.dict.filter { $0.inConnection == stemClass }
            XCTAssertTrue(followers.allSatisfy { !$0.canStart }, "a word can follow class \(stemClass)")
        }
    }

    private func wordSearch(_ files: [String]) -> WordSearch {
        WordSearch(connectionDictFiles: files, localDictFile: tempDir.appendingPathComponent("local.txt").path,
                   studyDictFile: tempDir.appendingPathComponent("study.txt").path)
    }

    private func request(for reading: String, in search: WordSearch) -> AIRerankRequest {
        let head = Array(search.search(query: reading, searchMode: 0).prefix(40))
        let completeWords = WordSearch.sharedConnectionDict?.completeWords(among: head) ?? []
        return AIRerankRequest(version: 1, mode: "fast-context-rerank", inputPat: reading, hiragana: "", context: nil,
                               candidates: head.enumerated().map { index, candidate in
            AIRerankCandidate(index: index, text: candidate.word, reading: candidate.reading,
                              source: String(describing: candidate.source), kind: candidate.kind.rawValue,
                              completeWord: completeWords.contains(candidate.word) ? true : nil)
        })
    }
}
