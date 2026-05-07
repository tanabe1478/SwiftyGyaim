@testable import Gyaim
import XCTest

final class GictionaryConnectionImporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GictionaryConnectionImporterTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        UserDefaults.standard.removeObject(forKey: GictionaryConnectionImporter.sourceURLDefaultsKey)
    }

    func testImportGictionaryJSONConvertsToConnectionTSV() throws {
        let json = """
        {
          "name": "Gictionary",
          "pages": [
            {
              "title": "目黒",
              "lines": [
                "目黒",
                "めぐろ 山手線駅名 駅名地名接続",
                "めぐろ 名前 名前接続",
                "[山手線駅名] [苗字1] [目] [黒]"
              ]
            },
            {
              "title": "駅",
              "lines": [
                "駅",
                "えき 駅名地名接続 地名接続",
                ""
              ]
            }
          ]
        }
        """
        let output = tempDir.appendingPathComponent("connectiondict.txt").path

        let result = try GictionaryConnectionImporter.importData(Data(json.utf8), outputPath: output)

        XCTAssertGreaterThan(result.entryCount, 0)
        let content = try String(contentsOfFile: output, encoding: .utf8)
        XCTAssertTrue(content.contains("meguro\t目黒"), content)
        XCTAssertTrue(content.contains("eki\t駅"), content)

        let dict = ConnectionDict(dictFile: output)
        var words: [String] = []
        dict.search(pat: "meguroeki", searchMode: 1) { word, _, _ in
            words.append(word)
        }
        XCTAssertTrue(words.contains("目黒駅"), "Expected connected candidate in \(words)")
    }

    func testImportBundledConnectionTSVIsByteIdentical() throws {
        let sourceFile = URL(fileURLWithPath: #file)
        let projectDir = sourceFile
            .deletingLastPathComponent() // GyaimTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // GyaimSwift
        let dictPath = projectDir.appendingPathComponent("Resources/dict.txt")
        let original = try Data(contentsOf: dictPath)
        let output = tempDir.appendingPathComponent("connectiondict.txt").path

        try GictionaryConnectionImporter.importData(original, outputPath: output)

        let imported = try Data(contentsOf: URL(fileURLWithPath: output))
        XCTAssertEqual(imported, original)
    }

    func testGitHubRepositoryURLNormalizesToRecommendedDict2RawURL() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/masui/Gictionary"))

        let normalized = GictionaryConnectionImporter.normalizedSourceURL(from: url)

        XCTAssertEqual(normalized.absoluteString, GictionaryConnectionImporter.recommendedDict2URLString)
    }

    func testGitHubBlobURLNormalizesToRawURL() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/masui/Gictionary/blob/master/dict2.txt"))

        let normalized = GictionaryConnectionImporter.normalizedSourceURL(from: url)

        XCTAssertEqual(normalized.absoluteString, GictionaryConnectionImporter.recommendedDict2URLString)
    }

    func testImportAlreadyConvertedTSVNormalizesRows() throws {
        let tsv = """
        # comment
        meguro\t目黒\t1\t2
        eki\t駅\t2\t0
        invalid\trow
        meguro\t目黒\t1\t2
        """
        let output = tempDir.appendingPathComponent("connectiondict.txt").path

        let result = try GictionaryConnectionImporter.importData(Data(tsv.utf8), outputPath: output)

        XCTAssertEqual(result.entryCount, 3)
        let content = try String(contentsOfFile: output, encoding: .utf8)
        XCTAssertEqual(content, "meguro\t目黒\t1\t2\neki\t駅\t2\t0\nmeguro\t目黒\t1\t2\n")
    }
}
