@testable import Gyaim
import XCTest

#if canImport(llama)
/// Scores the log-reconstructed context cases (Tools/eval/extract-context-cases.py)
/// with a GGUF through the production ranking (ADR-032 / 039 / 040) and reports
/// the top-1 rate per context length plus scoring latency (issue #125 B / E).
/// Runs only with GYAIM_CONTEXT_EVAL=1; see Tools/eval/run-context-cases-eval.sh.
///
/// Environment:
/// - GYAIM_CONTEXT_EVAL_CASES: cases JSONL (default ~/.gyaim/eval/context-cases-2026-10.jsonl)
/// - GYAIM_CONTEXT_EVAL_MODEL: GGUF path (default: the bundled model)
/// - GYAIM_CONTEXT_EVAL_OUT: JSON report path
/// - GYAIM_CONTEXT_EVAL_LENGTHS: context tails to score (default "20,10,5,0")
/// - GYAIM_CONTEXT_EVAL_SUBSET: "gap30" keeps only cases with a >30 s gap inside the context
/// - GYAIM_CONTEXT_EVAL_LIMIT: first N scorable cases
final class ContextCasesEvaluationTests: XCTestCase {
    struct Candidate: Decodable {
        let text: String
        let source: String?
        let kind: String?
        let reading: String?
        let contextAffinity: Double?
        let studyFrequency: Int?
    }

    struct Case: Decodable {
        let time: String
        let input: String
        let context: String
        let chosen: String?
        let truth: String?
        let prevWord: String?
        let prevReading: String?
        let gaps: [[Double]]
        let candidates: [Candidate]
    }

    private var tempDir = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GYAIM_CONTEXT_EVAL"] == "1",
                          "context cases evaluation runs only with GYAIM_CONTEXT_EVAL=1")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyaim-context-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Default weights (study 2.0, context 2.0, hiragana 1.0, compound 2.0); nothing reaches ~/.gyaim.
        let settings = tempDir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["loggingEnabled": false]).write(to: settings)
        GyaimSettings.settingsFilePathOverride = settings.path
    }

    override func tearDownWithError() throws {
        GyaimSettings.settingsFilePathOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private struct Tally { var n = 0; var model = 0; var production = 0; var heuristic = 0 }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func testScoreCases() throws {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultCases = home.appendingPathComponent(".gyaim/eval/context-cases-2026-10.jsonl").path
        let casesPath = env["GYAIM_CONTEXT_EVAL_CASES"] ?? defaultCases
        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let modelURL: URL
        if let custom = env["GYAIM_CONTEXT_EVAL_MODEL"] {
            modelURL = URL(fileURLWithPath: custom)
        } else {
            modelURL = try XCTUnwrap(BundledAIRerankModel.resolveModelURL(bundle: Bundle(for: Self.self)))
        }
        let lengths = (env["GYAIM_CONTEXT_EVAL_LENGTHS"] ?? "20,10,5,0").split(separator: ",").compactMap { Int($0) }
        let limit = Int(env["GYAIM_CONTEXT_EVAL_LIMIT"] ?? "") ?? .max
        let subset = env["GYAIM_CONTEXT_EVAL_SUBSET"] ?? "all"

        let llama = try LlamaZenzContext(modelURL: modelURL)
        let dictFiles = ["dict.txt", "grammar-dict.txt", "mozc-dict.txt"]
            .map { projectDir.appendingPathComponent("Resources/\($0)").path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        let wordSearch = WordSearch(connectionDictFiles: dictFiles,
                                    localDictFile: tempDir.appendingPathComponent("local.txt").path,
                                    studyDictFile: tempDir.appendingPathComponent("study.txt").path)
        let romaKana = RomaKana()
        let decoder = JSONDecoder()
        let lines = try String(contentsOfFile: casesPath, encoding: .utf8).split(separator: "\n")

        var counts: [Int: Tally] = [:]
        var latencies: [Double] = []
        var seenPrompts = Set<String>()
        var scored = 0
        var skipped = 0
        for line in lines {
            guard let item = try? decoder.decode(Case.self, from: Data(line.utf8)) else { skipped += 1; continue }
            let truth = item.truth ?? item.chosen
            guard let truth, !item.candidates.isEmpty,
                  let truthIndex = item.candidates.firstIndex(where: { $0.text == truth }) else { skipped += 1; continue }
            if subset == "gap30", !item.gaps.contains(where: { $0.count == 2 && $0[1] > 30 }) { continue }
            if scored >= limit { break }
            scored += 1

            var completions = Set<String>()
            if let prevWord = item.prevWord, let prevReading = item.prevReading {
                completions = Set(wordSearch.compoundCompletions(previousWord: prevWord, previousReading: prevReading,
                                                                 input: item.input))
            }
            let hiragana = romaKana.roma2hiragana(item.input)
            let candidates = item.candidates.enumerated().map { index, candidate in
                AIRerankCandidate(index: index, text: candidate.text, reading: candidate.reading,
                                  source: candidate.source ?? "connection", kind: candidate.kind ?? "exact",
                                  contextAffinity: candidate.contextAffinity, studyFrequency: candidate.studyFrequency,
                                  compoundCompletion: completions.contains(candidate.text) ? true : nil)
            }
            for length in lengths {
                let context = length > 0 ? String(item.context.suffix(length)) : ""
                let request = AIRerankRequest(version: 1, mode: "fast-context-rerank", inputPat: item.input,
                                              hiragana: hiragana, context: context.isEmpty ? nil : context,
                                              candidates: candidates)
                let heuristicOrder = AIReranker.localRerank(request).order
                let prompt = BundledZenzRuntime.prompt(for: request)
                let start = CFAbsoluteTimeGetCurrent()
                let batch = llama.scoreBatch(prompt: prompt, continuations: candidates.map(\.text))
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                if length == lengths.max(), seenPrompts.insert(prompt).inserted { latencies.append(elapsed) }
                var llmScores: [Int: Double] = [:]
                for (candidate, score) in zip(candidates, batch) where score.map(\.isFinite) == true {
                    llmScores[candidate.index] = score ?? 0
                }
                let modelOrder = candidates.map(\.index).sorted { lhs, rhs in
                    switch (llmScores[lhs], llmScores[rhs]) {
                    case let (left?, right?) where left != right: return left > right
                    case (.some, .none): return true
                    case (.none, .some): return false
                    default: return lhs < rhs
                    }
                }
                let production = BundledZenzRuntime.llmPrimaryOrder(
                    request: request, heuristicOrder: heuristicOrder, llmScores: llmScores,
                    studyWeight: BundledZenzRuntime.llmRankStudyWeight(),
                    contextWeight: BundledZenzRuntime.llmRankContextWeight(),
                    rawHiraganaPenalty: BundledZenzRuntime.llmRankRawHiraganaPenalty(),
                    compoundWeight: BundledZenzRuntime.llmRankCompoundWeight()).order
                var entry = counts[length] ?? Tally()
                entry.n += 1
                entry.model += modelOrder.first == truthIndex ? 1 : 0
                entry.production += production.first == truthIndex ? 1 : 0
                entry.heuristic += heuristicOrder.first == truthIndex ? 1 : 0
                counts[length] = entry
            }
        }

        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return .nan }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
        }
        var byLength: [String: Any] = [:]
        for (length, entry) in counts {
            byLength[String(length)] = ["n": entry.n, "modelTop1": entry.model, "productionTop1": entry.production,
                                        "heuristicTop1": entry.heuristic,
                                        "modelTop1Rate": Double(entry.model) / Double(max(entry.n, 1)),
                                        "productionTop1Rate": Double(entry.production) / Double(max(entry.n, 1)),
                                        "heuristicTop1Rate": Double(entry.heuristic) / Double(max(entry.n, 1))]
        }
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let report: [String: Any] = [
            "cases": casesPath, "model": modelURL.lastPathComponent, "subset": subset, "configuration": configuration,
            "scored": scored, "skipped": skipped, "lengths": lengths, "byLength": byLength,
            "weights": ["study": BundledZenzRuntime.llmRankStudyWeight(), "context": BundledZenzRuntime.llmRankContextWeight(),
                        "rawHiragana": BundledZenzRuntime.llmRankRawHiraganaPenalty(),
                        "compound": BundledZenzRuntime.llmRankCompoundWeight()],
            "latencyMs": ["n": latencies.count, "p50": percentile(latencies, 0.5), "p95": percentile(latencies, 0.95),
                          "mean": latencies.reduce(0, +) / Double(max(latencies.count, 1)),
                          "note": "scoreBatch wall time for the longest context, first occurrence of each prompt only"],
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let outputPath = env["GYAIM_CONTEXT_EVAL_OUT"] ?? tempDir.appendingPathComponent("report.json").path
        try data.write(to: URL(fileURLWithPath: outputPath))
        print("context-eval report: \(outputPath)")
        print(String(data: data, encoding: .utf8) ?? "")
    }
}
#endif
