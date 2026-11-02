@testable import Gyaim
import XCTest

/// `unstudy` takes back one study() — the retype correction of ADR-037.
final class WordSearchCorrectionTests: XCTestCase {
    private var searcher: WordSearch?
    private var tempDir = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let localDict = tempDir.appendingPathComponent("localdict.txt")
        let studyDict = tempDir.appendingPathComponent("studydict.txt")
        try "".write(to: localDict, atomically: true, encoding: .utf8)
        try "".write(to: studyDict, atomically: true, encoding: .utf8)
        WordSearch.resetStudyDict()
        let dictPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/dict.txt").path
        guard FileManager.default.fileExists(atPath: dictPath) else { throw XCTSkip("dict.txt not found") }
        searcher = WordSearch(connectionDictFile: dictPath, localDictFile: localDict.path, studyDictFile: studyDict.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testUnstudyStepsFrequencyBackAndRemovesSingleUseEntries() throws {
        // ADR-037: a retype undoes the previous commit's study.
        let ws = try XCTUnwrap(searcher)
        ws.study(word: "起きました", reading: "okimasita")
        XCTAssertTrue(ws.unstudy(word: "起きました", reading: "okimasita"))
        XCTAssertFalse(WordSearch.studyDict.contains { $0.word == "起きました" },
                       "an entry that only existed because of the mistaken commit disappears")

        ws.study(word: "移行", reading: "ikou")
        ws.study(word: "移行", reading: "ikou")
        ws.study(word: "移行", reading: "ikou")
        XCTAssertTrue(ws.unstudy(word: "移行", reading: "ikou"))
        XCTAssertEqual(WordSearch.studyDict.first { $0.word == "移行" }?.frequency, 2)

        XCTAssertFalse(ws.unstudy(word: "以降", reading: "ikou"), "nothing to undo")
    }
}
