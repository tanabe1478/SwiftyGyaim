@testable import Gyaim
import XCTest

/// Where the per-keystroke dictionary search time goes (dogfood: prefix search
/// p50 56ms / p95 102ms on the main thread). Runs with GYAIM_DICT_BENCH=1.
/// Uses the bundled dict.txt and a synthetic 5,000-entry study dict built from
/// its own readings, so nothing personal is read.
final class DictionarySearchBenchmarkTests: XCTestCase {
    private let queries = ["k", "ka", "kak", "kaku", "kakuninn", "kakuninnsite", "s", "si", "sit", "site", "settei",
                           "setteigamenn", "m", "mi", "mita", "yo", "youkenn", "youkennteigi", "ko", "kono", "no",
                           "wo", "jissou", "jissousimasu", "n", "ni", "de", "t", "to", "tesuto"]

    /// Synthetic study dict: 5,000 (reading, word) pairs sampled from dict.txt.
    private func writeStudyDict(from dictPath: String, to studyPath: String) throws {
        let rows = try String(contentsOfFile: dictPath, encoding: .utf8).split(separator: "\n")
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
            .filter { $0.count >= 2 && !$0[1].contains("*") && $0[0].allSatisfy(\.isLetter) }
        var generator = SystemRandomNumberGenerator()
        let now = Date().timeIntervalSince1970
        let studyText = rows.shuffled(using: &generator).prefix(5000).enumerated().map { index, row in
            "\(row[0])\t\(row[1])\t\(now - Double(index))\t\(1 + index % 7)"
        }.joined(separator: "\n") + "\n"
        try studyText.write(toFile: studyPath, atomically: true, encoding: .utf8)
    }

    private func measure(_ label: String, _ body: (String) -> Int) {
        var total = 0.0, worst = 0.0, results = 0
        for query in queries {
            let start = CFAbsoluteTimeGetCurrent()
            results += body(query)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            total += elapsed
            worst = max(worst, elapsed)
        }
        print(String(format: "bench %@ mean=%.1fms max=%.1fms results=%d", label,
                     total / Double(queries.count), worst, results))
    }

    func testSearchBreakdown() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GYAIM_DICT_BENCH"] == "1")
        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dictPath = projectDir.appendingPathComponent("Resources/dict.txt").path
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyaim-dict-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let studyPath = tempDir.appendingPathComponent("studydict.txt").path
        try writeStudyDict(from: dictPath, to: studyPath)
        let emptyStudyPath = tempDir.appendingPathComponent("empty-studydict.txt").path
        try "".write(toFile: emptyStudyPath, atomically: true, encoding: .utf8)
        let localPath = tempDir.appendingPathComponent("localdict.txt").path
        try "".write(toFile: localPath, atomically: true, encoding: .utf8)

        let loadStart = CFAbsoluteTimeGetCurrent()
        let connection = ConnectionDict(dictFile: dictPath)
        print(String(format: "bench connection-dict load %.0fms", (CFAbsoluteTimeGetCurrent() - loadStart) * 1000))

        measure("connection-dict prefix") { query in
            var count = 0
            connection.search(pat: query, searchMode: 0) { _, _, _ in count += 1 }
            return count
        }
        measure("connection-dict exact") { query in
            var count = 0
            connection.search(pat: query, searchMode: 1) { _, _, _ in count += 1 }
            return count
        }
        let empty = WordSearch(connectionDictFile: dictPath, localDictFile: localPath, studyDictFile: emptyStudyPath)
        measure("WordSearch prefix, empty study") { empty.search(query: $0, searchMode: 0).count }
        let full = WordSearch(connectionDictFile: dictPath, localDictFile: localPath, studyDictFile: studyPath)
        measure("WordSearch prefix, 5k study") { full.search(query: $0, searchMode: 0).count }
        measure("WordSearch exact, 5k study") { full.search(query: $0, searchMode: 1).count }
        full.finish()

        measureWithMozc(dictPath: dictPath, mozcPath: projectDir.appendingPathComponent("Resources/mozc-dict.txt").path)
    }

    private func measureWithMozc(dictPath: String, mozcPath: String) {
        guard FileManager.default.fileExists(atPath: mozcPath) else { return }
        let bothStart = CFAbsoluteTimeGetCurrent()
        let both = ConnectionDict(dictFiles: [dictPath, mozcPath])
        print(String(format: "bench dict.txt + mozc-dict.txt load %.0fms entries=%d",
                     (CFAbsoluteTimeGetCurrent() - bothStart) * 1000, both.entryCount))
        measure("dict.txt + mozc prefix (cap 2000)") { query in
            var count = 0
            both.searchDetailed(pat: query, searchMode: 0, maxResults: WordSearch.maxConnectionCandidates) { _ in count += 1 }
            return count
        }
        measure("dict.txt + mozc exact") { query in
            var count = 0
            both.searchDetailed(pat: query, searchMode: 1) { _ in count += 1 }
            return count
        }
    }
}
