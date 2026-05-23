@testable import Gyaim
import XCTest

final class CandidatePipelineFeedbackTests: XCTestCase {
    private struct FeedbackCase: Decodable {
        let input: String
        let expected: String
        let assertion: Assertion
        let note: String?

        enum Assertion: String, Decodable {
            case top5
            case learnedTop1
        }
    }
    private var tempDir: URL!
    private var wordSearch: WordSearch!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let localDict = tempDir.appendingPathComponent("localdict.txt")
        let studyDict = tempDir.appendingPathComponent("studydict.txt")
        try "".write(to: localDict, atomically: true, encoding: .utf8)
        try "".write(to: studyDict, atomically: true, encoding: .utf8)
        WordSearch.resetStudyDict()

        let projectDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dictPath = projectDir.appendingPathComponent("Resources/dict.txt").path
        guard FileManager.default.fileExists(atPath: dictPath) else {
            throw XCTSkip("dict.txt not found at \(dictPath)")
        }
        wordSearch = WordSearch(connectionDictFile: dictPath,
                                localDictFile: localDict.path,
                                studyDictFile: studyDict.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testNiseCandidatesAvoidShortLatticeNoise() {
        let candidates = generatedCandidates(for: "nise")
        let words = candidates.map(\.word)

        XCTAssertTrue(words.contains("偽"), "Expected dictionary exact candidate 偽 in \(words.prefix(12))")
        XCTAssertTrue(words.contains("偽物"), "Expected prefix candidate 偽物 in \(words.prefix(12))")
        XCTAssertFalse(candidates.contains { $0.word == "二世" && $0.kind == .lattice },
                       "nise should not synthesize ni+se lattice noise")
        XCTAssertFalse(candidates.contains { $0.word == "二千" && $0.kind == .lattice },
                       "nise should not synthesize ni+se lattice noise")
    }

    func testYouseiContainsMedicalCandidateBeforeCommonHomophones() {
        let candidates = generatedCandidates(for: "yousei")
        let words = candidates.map(\.word)

        XCTAssertTrue(words.contains("陽性"), "Expected 陽性 in \(words.prefix(12))")
        XCTAssertLessThan(index(of: "陽性", in: words), index(of: "妖精", in: words))
        XCTAssertLessThan(index(of: "陽性", in: words), index(of: "要請", in: words))
    }

    func testLocalRerankKeepsRawInputOutOfTopCandidate() {
        let candidates = generatedCandidates(for: "yousei")
        let reranked = locallyReranked(candidates: candidates, inputPat: "yousei")

        XCTAssertNotEqual(reranked.first?.word, "yousei")
        XCTAssertEqual(reranked.first?.word, "陽性")
    }

    func testFeedbackFixtureTop5Cases() throws {
        let cases = try loadFeedbackCases().filter { $0.assertion == .top5 }
        var report: [String] = []

        for item in cases {
            let reranked = locallyReranked(candidates: generatedCandidates(for: item.input), inputPat: item.input)
            let words = reranked.map(\.word)
            let rank = index(of: item.expected, in: words)
            let head = Array(words.prefix(5))
            report.append("- \(item.input): expected=\(item.expected) rank=\(rank == Int.max ? -1 : rank + 1) head=\(head)")
            XCTAssertLessThan(rank, 5, "Expected \(item.expected) in top5 for \(item.input): \(head)")
        }
        writeFeedbackReport(title: "Top5 fixture", lines: report)
    }

    func testFeedbackFixtureLearnedTop1Cases() throws {
        let cases = try loadFeedbackCases().filter { $0.assertion == .learnedTop1 }
        var report: [String] = []

        for item in cases {
            wordSearch.study(word: item.expected, reading: item.input)
            let reranked = locallyReranked(candidates: generatedCandidates(for: item.input), inputPat: item.input)
            let head = Array(reranked.prefix(5)).map(\.word)
            report.append("- \(item.input): expected=\(item.expected) head=\(head)")
            XCTAssertEqual(reranked.first?.word,
                           item.expected,
                           "Expected learned \(item.expected) top1 for \(item.input): \(head)")
        }
        writeFeedbackReport(title: "Learned top1 fixture", lines: report)
    }

    private func loadFeedbackCases() throws -> [FeedbackCase] {
        let fixture = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/candidate-feedback-cases.json")
        let data = try Data(contentsOf: fixture)
        return try JSONDecoder().decode([FeedbackCase].self, from: data)
    }

    private func writeFeedbackReport(title: String, lines: [String]) {
        let output = ProcessInfo.processInfo.environment["GYAIM_FEEDBACK_REPORT"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("gyaim-candidate-feedback-report.md")
        let section = (["# \(title)", ""] + lines).joined(separator: "\n") + "\n"
        if FileManager.default.fileExists(atPath: output.path),
           let handle = try? FileHandle(forWritingTo: output) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(("\n" + section).utf8))
        } else {
            try? section.write(to: output, atomically: true, encoding: .utf8)
        }
        print("Candidate feedback report: \(output.path)")
    }

    private func generatedCandidates(for inputPat: String) -> [SearchCandidate] {
        let raw = SearchCandidate(word: inputPat, reading: inputPat, kind: .raw)
        let base = [raw] + wordSearch.search(query: inputPat, searchMode: 0)
        return CandidateGenerator().generate(inputPat: inputPat,
                                             context: "",
                                             baseCandidates: base,
                                             wordSearch: wordSearch)
    }

    private func locallyReranked(candidates: [SearchCandidate], inputPat: String) -> [SearchCandidate] {
        let request = AIRerankRequest(version: 1,
                                      mode: "feedback-test",
                                      inputPat: inputPat,
                                      hiragana: RomaKana().roma2hiragana(inputPat),
                                      context: nil,
                                      candidates: candidates.enumerated().map { index, candidate in
                                          AIRerankCandidate(index: index,
                                                            text: candidate.word,
                                                            reading: candidate.reading,
                                                            source: String(describing: candidate.source),
                                                            kind: candidate.kind.rawValue)
                                      })
        return AIReranker.apply(order: AIReranker.localRerank(request).order, to: candidates)
    }

    private func index(of word: String, in words: [String]) -> Int {
        words.firstIndex(of: word) ?? Int.max
    }
}
