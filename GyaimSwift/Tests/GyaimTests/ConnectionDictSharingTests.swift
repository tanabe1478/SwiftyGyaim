@testable import Gyaim
import XCTest

/// Process-wide sharing of the connection dictionary. Loading the 40,904-line
/// dict took a measured 0.3–2.1s and ran on EVERY controller creation (each
/// app/field switch) because IMK instantiates controllers per client. The
/// dictionary is immutable after load, so WordSearch shares one instance the
/// same way studyDict is shared (BUG-005 pattern).
final class ConnectionDictSharingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyaim-conn-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        WordSearch.resetConnectionDict()
        WordSearch.resetStudyDict()
    }

    override func tearDownWithError() throws {
        WordSearch.resetConnectionDict()
        WordSearch.resetStudyDict()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFile(_ name: String, _ content: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func makeWordSearch(connectionDictFile: String) throws -> WordSearch {
        WordSearch(connectionDictFile: connectionDictFile,
                   localDictFile: try writeFile("localdict-\(UUID().uuidString).txt", ""),
                   studyDictFile: try writeFile("studydict-\(UUID().uuidString).txt", ""))
    }

    private func surfaces(pat: String) -> [String] {
        var words: [String] = []
        WordSearch.sharedConnectionDict?.search(pat: pat, searchMode: 1) { word, _, _ in
            words.append(word)
        }
        return words
    }

    func testSameFileSharesOneConnectionDictInstance() throws {
        let dictPath = try writeFile("dict.txt", "man\t万\t3\t0\n")

        _ = try makeWordSearch(connectionDictFile: dictPath)
        let first = try XCTUnwrap(WordSearch.sharedConnectionDict)

        _ = try makeWordSearch(connectionDictFile: dictPath)
        let second = try XCTUnwrap(WordSearch.sharedConnectionDict)

        XCTAssertTrue(first === second,
                      "A second WordSearch with the same dict path must reuse the loaded instance")
    }

    func testDifferentFileReloadsConnectionDict() throws {
        _ = try makeWordSearch(connectionDictFile: try writeFile("dict-a.txt", "man\t万\t3\t0\n"))
        _ = try makeWordSearch(connectionDictFile: try writeFile("dict-b.txt", "en\t円\t3\t0\n"))

        XCTAssertTrue(surfaces(pat: "en").contains("円"))
        XCTAssertFalse(surfaces(pat: "man").contains("万"),
                       "Switching dict paths must not keep serving the previous dictionary")
    }

    func testResetPicksUpNewContentAtTheSamePath() throws {
        // Gictionary import rewrites ~/.gyaim/connectiondict.txt in place, so
        // GyaimController.reloadConnectionDictionary calls resetConnectionDict
        // first — a path-keyed cache alone would keep serving the old file.
        let dictPath = try writeFile("dict.txt", "man\t万\t3\t0\n")
        _ = try makeWordSearch(connectionDictFile: dictPath)
        XCTAssertTrue(surfaces(pat: "man").contains("万"))

        _ = try writeFile("dict.txt", "en\t円\t3\t0\n")
        WordSearch.resetConnectionDict()
        _ = try makeWordSearch(connectionDictFile: dictPath)

        XCTAssertTrue(surfaces(pat: "en").contains("円"))
        XCTAssertFalse(surfaces(pat: "man").contains("万"))
    }
}
