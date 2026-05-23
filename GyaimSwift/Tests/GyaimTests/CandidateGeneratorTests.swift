@testable import Gyaim
import XCTest

final class CandidateGeneratorTests: XCTestCase {
    private var tempDir: URL?
    private var wordSearch: WordSearch?

    override func setUpWithError() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.tempDir = tempDir
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let localDict = tempDir.appendingPathComponent("localdict.txt")
        let studyDict = tempDir.appendingPathComponent("studydict.txt")
        try "".write(to: localDict, atomically: true, encoding: .utf8)
        try "".write(to: studyDict, atomically: true, encoding: .utf8)
        WordSearch.resetStudyDict()

        let projectDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // GyaimTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // GyaimSwift
        let dictPath = projectDir.appendingPathComponent("Resources/dict.txt").path
        guard FileManager.default.fileExists(atPath: dictPath) else {
            throw XCTSkip("dict.txt not found at \(dictPath)")
        }

        wordSearch = WordSearch(connectionDictFile: dictPath,
                                localDictFile: localDict.path,
                                studyDictFile: studyDict.path)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testGenerateAddsCompoundCandidates() throws {
        let wordSearch = try XCTUnwrap(wordSearch)
        wordSearch.register(word: "変換", reading: "henkan")
        wordSearch.register(word: "候補", reading: "kouho")

        let generator = CandidateGenerator(compoundLimit: 12, completionLimit: 0)
        let generated = generator.generate(inputPat: "henkankouho",
                                           context: "",
                                           baseCandidates: [SearchCandidate(word: "henkankouho", reading: "henkankouho")],
                                           wordSearch: wordSearch)

        let compound = generated.first { $0.word == "変換候補" }
        XCTAssertEqual(compound?.kind, .compound)
    }

    func testGenerateAddsSuffixCompletionsWithoutDuplicatingBaseCandidates() {
        let base = [
            SearchCandidate(word: "konkai", reading: "konkai"),
            SearchCandidate(word: "今回", reading: "konkai")
        ]
        let generator = CandidateGenerator(compoundLimit: 0, completionLimit: 3)
        let generated = generator.generate(inputPat: "konkai",
                                           context: "直前文脈",
                                           baseCandidates: base,
                                           wordSearch: nil)
        let words = generated.map(\.word)

        XCTAssertEqual(words.filter { $0 == "今回" }.count, 1)
        XCTAssertTrue(words.contains("今回でした"))
        XCTAssertTrue(words.contains("今回です"))
        XCTAssertEqual(generated.first { $0.word == "今回でした" }?.kind, .completion)
        XCTAssertFalse(words.contains("konkaiでした"), "raw romaji candidate should not receive Japanese suffixes")
    }

    func testCompoundScoringPenalizesUnnaturalScriptTransitions() throws {
        let wordSearch = try XCTUnwrap(wordSearch)
        wordSearch.register(word: "追う", reading: "ou")
        wordSearch.register(word: "集", reading: "syuu")
        wordSearch.register(word: "押収", reading: "ousyuu")
        wordSearch.register(word: "する", reading: "suru")

        let generator = CandidateGenerator(compoundLimit: 12, completionLimit: 0)
        let generated = generator.generate(inputPat: "ousyuusuru",
                                           context: "",
                                           baseCandidates: [SearchCandidate(word: "ousyuusuru", kind: .raw)],
                                           wordSearch: wordSearch)
        let compoundWords = generated.filter { $0.kind == .compound }.map(\.word)

        XCTAssertTrue(compoundWords.contains("押収する"), "Expected natural compound in \(compoundWords)")
        if let naturalIndex = compoundWords.firstIndex(of: "押収する"),
           let unnaturalIndex = compoundWords.firstIndex(of: "追う集する") {
            XCTAssertLessThan(naturalIndex, unnaturalIndex)
        }
    }

    func testCompoundGenerationSkipsVeryShortQueries() throws {
        let wordSearch = try XCTUnwrap(wordSearch)
        wordSearch.register(word: "二", reading: "ni")
        wordSearch.register(word: "世", reading: "se")

        let generator = CandidateGenerator(compoundLimit: 12, completionLimit: 0)
        let generated = generator.generate(inputPat: "nise",
                                           context: "",
                                           baseCandidates: [SearchCandidate(word: "nise", kind: .raw)],
                                           wordSearch: wordSearch)
        let compoundWords = generated.filter { $0.kind == .compound }.map(\.word)

        XCTAssertFalse(compoundWords.contains("二世"))
    }

    func testCompoundGenerationRejectsSymbolSegments() throws {
        let wordSearch = try XCTUnwrap(wordSearch)
        wordSearch.register(word: "ん", reading: "n")
        wordSearch.register(word: "∩", reading: "ando")
        wordSearch.register(word: "か", reading: "ka")
        wordSearch.register(word: "何度か", reading: "nandoka")

        let generator = CandidateGenerator(compoundLimit: 12, completionLimit: 0)
        let generated = generator.generate(inputPat: "nandoka",
                                           context: "",
                                           baseCandidates: [SearchCandidate(word: "nandoka", kind: .raw)],
                                           wordSearch: wordSearch)
        let compoundWords = generated.filter { $0.kind == .compound }.map(\.word)

        XCTAssertFalse(compoundWords.contains("ん∩か"))
        XCTAssertTrue(compoundWords.contains("何度か"))
    }
}
