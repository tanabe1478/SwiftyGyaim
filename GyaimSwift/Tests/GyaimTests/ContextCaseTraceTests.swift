import Foundation
@testable import Gyaim
import XCTest

final class ContextCaseTraceTests: XCTestCase {
    private var settingsFolder: URL?
    private var previousSettingsPath: String?

    override func setUpWithError() throws {
        previousSettingsPath = GyaimSettings.settingsFilePathOverride
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        settingsFolder = folder
        let settings = folder.appendingPathComponent("settings.json")
        try Data("{\"loggingEnabled\":false}".utf8).write(to: settings)
        GyaimSettings.settingsFilePathOverride = settings.path
    }

    override func tearDownWithError() throws {
        GyaimSettings.settingsFilePathOverride = previousSettingsPath
        if let settingsFolder { try FileManager.default.removeItem(at: settingsFolder) }
    }

    private struct Scenario {
        let request: AIRerankRequest
        let source: String
        let scores: [[Int: Double]]
    }

    private func scenarios() throws -> [Scenario] {
        try [true, false].map { compound in
            let input = compound ? "zou" : "siyou"
            let hiragana = compound ? "ぞう" : "しよう"
            let truth = compound ? "像" : "仕様"
            let rival = compound ? "増" : "使用"
            let frequency = compound ? 0 : 1
            let gap = compound ? 31 : 30
            let candidates = [
                AIRerankCandidate(index: 0, text: truth, reading: input, source: frequency > 0 ? "study" : "connection",
                                  kind: "exact", studyFrequency: frequency, compoundCompletion: compound),
                AIRerankCandidate(index: 1, text: rival, reading: input, source: "connection", kind: "exact"),
            ]
            let request = AIRerankRequest(version: 1, mode: "fast-context-rerank", inputPat: input,
                                          hiragana: hiragana, context: "合成文脈", candidates: candidates)
            let row: [String: Any] = [
                "time": "synthetic", "input": input, "context": "合成文脈", "truth": truth, "gaps": [[0, gap]],
                "candidates": candidates.map { candidate -> [String: Any] in
                    ["text": candidate.text, "reading": input, "source": candidate.source,
                     "kind": "exact", "studyFrequency": candidate.studyFrequency ?? 0]
                },
            ]
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            let source = try XCTUnwrap(String(data: data, encoding: .utf8))
            return Scenario(request: request, source: source,
                            scores: [[0: -2, 1: -1], [0: compound ? -4 : -0.5, 1: -1]])
        }
    }

    private func observation(_ scenario: Scenario, model: Int, lineNumber: Int) -> ContextCaseTrace.Observation {
        let scores = scenario.scores[model]
        let heuristic = AIReranker.localRerank(scenario.request).order
        let production = BundledZenzRuntime.llmPrimaryOrder(request: scenario.request, heuristicOrder: heuristic,
                                                           llmScores: scores, studyWeight: 2, contextWeight: 2,
                                                           rawHiraganaPenalty: 1, compoundWeight: 2)
        let modelOrder = [0, 1].sorted { (scores[$0] ?? -.infinity) > (scores[$1] ?? -.infinity) }
        return .init(lineNumber: lineNumber, sourceLine: scenario.source, length: 20, truthIndex: 0,
                     request: scenario.request, modelScores: scores, modelOrder: modelOrder,
                     production: production, heuristicOrder: heuristic)
    }

    func testNativeAdjustmentsExplainProductionRegressionDespiteAggregateModelGain() throws {
        let cases = try scenarios()
        let before = try cases.enumerated().map { try ContextCaseTrace.record(observation($1, model: 0, lineNumber: $0 + 1)) }
        let after = try cases.enumerated().map { try ContextCaseTrace.record(observation($1, model: 1, lineNumber: $0 + 1)) }
        XCTAssertEqual(before[0]["productionOrder"] as? [Int], [0, 1])
        XCTAssertEqual(after[0]["productionOrder"] as? [Int], [1, 0])
        XCTAssertEqual(before[1]["modelOrder"] as? [Int], [1, 0])
        XCTAssertEqual(after[1]["modelOrder"] as? [Int], [0, 1])
        XCTAssertEqual(before[1]["productionOrder"] as? [Int], after[1]["productionOrder"] as? [Int])
        let offsets = try XCTUnwrap(before[0]["adjustments"] as? [[String: Double]])
        XCTAssertEqual(offsets[0]["compound"], 2)
        XCTAssertNil(before[0]["context"])
        XCTAssertNil(before[0]["candidates"])
    }

    func testWriterDoesNotOverwriteAndCompletesOnlyWithSummary() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("trace.jsonl")
        let writer = try ContextCaseTraceWriter(path: output.path, metadata: ["type": "header"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathExtension("partial").path))
        XCTAssertThrowsError(try ContextCaseTraceWriter(path: output.path, metadata: [:]))
        try writer.finish(summary: ["scored": 0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertThrowsError(try ContextCaseTraceWriter(path: output.path, metadata: [:]))
    }

    /// The shell test runner consumes these actual Swift bytes in the Python analyzer test.
    private func contractHeader(raw: Data, name: String) -> [String: Any] {
        let hash = ContextCaseTrace.digest(Data("synthetic".utf8))
        return [
            "type": "header", "format": "gyaim-native-context-trace", "version": 1,
            "backend": "LlamaZenzContext.scoreBatch", "configuration": "Release", "platform": "synthetic",
            "casesSha256": ContextCaseTrace.digest(raw), "modelSha256": ContextCaseTrace.digest(Data(name.utf8)),
            "dictionarySha256": ["dict.txt": hash, "mozc-dict.txt": hash], "sourceFilesSha256": ["synthetic": hash],
            "weights": ContextCaseTrace.weights, "lengths": [20], "subset": "all", "limit": NSNull(),
        ]
    }

    func testWriteSyntheticContractForPythonWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["GYAIM_NATIVE_TRACE_TEST_DIR"] else { return }
        let folder = URL(fileURLWithPath: path)
        let cases = try scenarios()
        let raw = Data((cases.map(\.source).joined(separator: "\n") + "\n").utf8)
        try raw.write(to: folder.appendingPathComponent("cases.jsonl"), options: .withoutOverwriting)
        for (index, name) in ["base", "trial"].enumerated() {
            let records = try cases.enumerated().map {
                try ContextCaseTrace.record(observation($1, model: index, lineNumber: $0 + 1))
            }
            let writer = try ContextCaseTraceWriter(path: folder.appendingPathComponent("\(name).jsonl").path,
                                                   metadata: contractHeader(raw: raw, name: name))
            for record in records { try writer.append(record) }
            var counts: [String: Any] = ["n": cases.count]
            for prefix in ["model", "production", "heuristic"] {
                let correct = records.filter { ($0["\(prefix)Order"] as? [Int])?.first == 0 }.count
                counts["\(prefix)Top1"] = correct
                counts["\(prefix)Top1Rate"] = Double(correct) / Double(cases.count)
            }
            try writer.finish(summary: ["scored": cases.count, "skipped": 0, "configuration": "Release",
                                        "lengths": [20], "subset": "all", "weights": ContextCaseTrace.weights,
                                        "byLength": ["20": counts]])
        }
    }
}
