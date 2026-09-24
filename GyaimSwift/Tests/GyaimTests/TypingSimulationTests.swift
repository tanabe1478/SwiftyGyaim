@testable import Gyaim
import XCTest

/// Replays a segmented corpus through the real search + fast-context rerank
/// path (heuristic and bundled model) and reports where each expected word
/// ranked. Runs only with GYAIM_TYPING_SIM=1 (see Tools/eval/run-typing-simulation.sh);
/// every dictionary, ContextDict and settings file lives in a temp directory,
/// so the user's ~/.gyaim is never read or written unless
/// GYAIM_TYPING_SIM_STUDYDICT points at a study dict to copy.
final class TypingSimulationTests: XCTestCase {
    private struct Segment {
        let romaji: String
        let expected: String
    }

    private enum CommitPath: String {
        case convert, raw, kanaHiragana = "kana-hiragana", kanaKatakana = "kana-katakana"
    }

    private var tempDir = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GYAIM_TYPING_SIM"] == "1",
                          "typing simulation runs only with GYAIM_TYPING_SIM=1")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyaim-typing-sim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let settings = tempDir.appendingPathComponent("settings.json")
        // Same model switches as the dogfood settings; logging stays off so
        // nothing reaches ~/.gyaim/gyaim.log. GYAIM_TYPING_SIM_SETTINGS (a JSON
        // object) overrides keys for experiments.
        var values: [String: Any] = ["loggingEnabled": false, "aiRerankUseModelForFastContext": true]
        if let extra = ProcessInfo.processInfo.environment["GYAIM_TYPING_SIM_SETTINGS"],
           let object = try JSONSerialization.jsonObject(with: Data(extra.utf8)) as? [String: Any] {
            values.merge(object) { _, new in new }
        }
        values["loggingEnabled"] = false
        try JSONSerialization.data(withJSONObject: values).write(to: settings)
        GyaimSettings.settingsFilePathOverride = settings.path
    }

    override func tearDownWithError() throws {
        GyaimSettings.settingsFilePathOverride = nil
        ContextDict.shared.configure(file: Config.contextDictFile)
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReplayCorpus() throws {
        let env = ProcessInfo.processInfo.environment
        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let corpusPath = env["GYAIM_TYPING_SIM_CORPUS"]
            ?? projectDir.appendingPathComponent("Tools/eval/typing-corpus.jsonl").path
        let outputPath = env["GYAIM_TYPING_SIM_OUTPUT"] ?? tempDir.appendingPathComponent("report.json").path
        let dictPath = projectDir.appendingPathComponent("Resources/dict.txt").path
        let epochs = max(1, Int(env["GYAIM_TYPING_SIM_EPOCHS"] ?? "") ?? 1)

        let modelReady = BundledAIRerankModel.shared.loadIfAvailable(bundle: Bundle(for: Self.self))
        let corpus = try loadCorpus(path: corpusPath)
        var report: [String: Any] = ["corpus": corpusPath, "modelMapped": modelReady, "epochs": epochs,
                                     "settings": env["GYAIM_TYPING_SIM_SETTINGS"] ?? "{}"]
        var bySegmentation: [String: Any] = [:]
        for name in corpus.keys.sorted() {
            bySegmentation[name] = replay(sentences: corpus[name] ?? [], name: name, dictPath: dictPath,
                                          epochs: epochs, studySeed: env["GYAIM_TYPING_SIM_STUDYDICT"])
        }
        report["segmentations"] = bySegmentation
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outputPath))
        print("typing simulation report: \(outputPath)")
    }

    /// JSONL: {"id": "...", "segmentations": {"habit": [["youkenn", "要件"], ...], "natural": [...]}}
    private func loadCorpus(path: String) throws -> [String: [(id: String, segments: [Segment])]] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var result: [String: [(id: String, segments: [Segment])]] = [:]
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let id = object["id"] as? String ?? "?"
            let segmentations = try XCTUnwrap(object["segmentations"] as? [String: [[String]]], "bad line: \(id)")
            for (name, pairs) in segmentations {
                let segments = pairs.compactMap { $0.count == 2 ? Segment(romaji: $0[0], expected: $0[1]) : nil }
                result[name, default: []].append((id, segments))
            }
        }
        return result
    }

    private func replay(sentences: [(id: String, segments: [Segment])], name: String, dictPath: String,
                        epochs: Int, studySeed: String?) -> [String: Any] {
        let runDir = tempDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let studyPath = runDir.appendingPathComponent("studydict.txt").path
        if let studySeed { try? FileManager.default.copyItem(atPath: studySeed, toPath: studyPath) }
        ContextDict.shared.configure(file: runDir.appendingPathComponent("contextdict.txt").path)
        let ws = WordSearch(connectionDictFile: dictPath,
                            localDictFile: runDir.appendingPathComponent("localdict.txt").path,
                            studyDictFile: studyPath)
        let rk = RomaKana()

        var records: [[String: Any]] = []
        var counts: [String: Int] = [:]
        for epoch in 1...epochs {
            for sentence in sentences {
                var context = ""
                for segment in sentence.segments {
                    var record = simulate(segment, context: context, ws: ws, rk: rk)
                    record["sentence"] = sentence.id
                    record["epoch"] = epoch
                    counts["\(epoch):\(record["outcome"] as? String ?? "?")", default: 0] += 1
                    records.append(record)
                    context = String((context + segment.expected).suffix(80))
                }
            }
        }
        ws.finish()
        return ["summary": summarize(records, epochs: epochs), "records": records]
    }

    private func commitPath(for word: String, input: String) -> CommitPath {
        if word == input { return .raw }  // digits / ASCII typed as-is
        if word.unicodeScalars.allSatisfy({ (0x3041...0x309F).contains($0.value) || "、。！？ー".unicodeScalars.contains($0) }) {
            return .kanaHiragana
        }
        if word.unicodeScalars.allSatisfy({ (0x30A0...0x30FF).contains($0.value) }) { return .kanaKatakana }
        return .convert
    }

    /// Mirrors the user's observed habit: hiragana-only units are committed
    /// with the kana key, katakana-only with the katakana key, the rest by
    /// conversion. Learning (study + ContextDict) follows GyaimController.
    private func simulate(_ segment: Segment, context: String, ws: WordSearch, rk: RomaKana) -> [String: Any] {
        let input = segment.romaji
        var record: [String: Any] = ["input": input, "expected": segment.expected]
        if let direct = commitWithoutConversion(segment, ws: ws) {
            return record.merging(direct) { _, new in new }
        }

        let (ranked, reviewed) = rankCandidates(input: input, expected: segment.expected, context: context, ws: ws, rk: rk)
        record.merge(ranked) { _, new in new }
        var committed: SearchCandidate?
        if let rank = record["rank"] as? Int, rank >= 1 {
            record["outcome"] = rank == 1 ? "prefix-top1" : "prefix-lower"
            record["ops"] = rank + 1  // Space x rank, then commit
            committed = reviewed[rank]
        } else {
            let exact = exactModeCandidates(input: input, ws: ws, rk: rk)
            if let index = exact.firstIndex(where: { $0.word == segment.expected }) {
                record["outcome"] = "exact-escape"
                record["exactRank"] = index
                record["ops"] = 1 + index + 1  // Enter into exact mode, Space x index, commit
                committed = exact[index]
            } else {
                record["outcome"] = "absent"
                record["ops"] = 3  // Tab (Google), Space to its first result (assumed right), commit
            }
        }
        // Absent words are what Google Transliterate would supply; learning
        // them keeps later occurrences comparable to real use.
        let reading = committed?.reading ?? input
        ws.study(word: segment.expected, reading: reading)
        ContextDict.shared.record(context: context, reading: reading, word: segment.expected)
        return record
    }

    /// Raw (digits typed as-is) and kana-key commits: one key, no ranking.
    /// Katakana commits are studied, hiragana ones are not (GyaimController).
    private func commitWithoutConversion(_ segment: Segment, ws: WordSearch) -> [String: Any]? {
        switch commitPath(for: segment.expected, input: segment.romaji) {
        case .raw:
            return ["outcome": "raw", "ops": 1]
        case .kanaHiragana:
            return ["outcome": "kana-hiragana", "ops": 1]
        case .kanaKatakana:
            ws.study(word: segment.expected, reading: segment.romaji)
            return ["outcome": "kana-katakana", "ops": 1]
        case .convert:
            return nil
        }
    }

    /// Exact-mode list as GyaimController builds it: hiragana, katakana, then
    /// the exact dictionary matches (the first row is selected on entry).
    private func exactModeCandidates(input: String, ws: WordSearch, rk: RomaKana) -> [SearchCandidate] {
        var candidates = ws.search(query: input, searchMode: 1)
        for kana in [rk.roma2katakana(input), rk.roma2hiragana(input)] where !kana.isEmpty {
            candidates.removeAll { $0.word == kana }
            candidates.insert(SearchCandidate(word: kana, reading: input, kind: .kana), at: 0)
        }
        return candidates
    }

    /// The prefix list the user sees after the model review, plus where the
    /// expected word sat in it and in the heuristic-only order.
    private func rankCandidates(input: String, expected: String, context: String,
                                ws: WordSearch, rk: RomaKana) -> ([String: Any], [SearchCandidate]) {
        let hiragana = rk.roma2hiragana(input)
        let searchResults = ws.search(query: input, searchMode: 0)
        let heuristic = GyaimController.buildPrefixCandidates(
            searchResults: searchResults, inputPat: input, clipboardCandidate: nil, selectedCandidate: nil,
            hiragana: hiragana, context: context, allowModelReview: false)
        var observation: FastContextObservation?
        let start = CFAbsoluteTimeGetCurrent()
        let reviewed = GyaimController.buildPrefixCandidates(
            searchResults: searchResults, inputPat: input, clipboardCandidate: nil, selectedCandidate: nil,
            hiragana: hiragana, context: context, allowModelReview: true, onRerank: { observation = $0 })
        var record: [String: Any] = [
            "reviewMs": Int((CFAbsoluteTimeGetCurrent() - start) * 1000),
            "context": GyaimController.limitedFastContext(context),
            "top": Array(reviewed.dropFirst().prefix(5).map(\.word)),
        ]
        record["heuristicRank"] = heuristic.firstIndex { $0.word == expected }
        record["rank"] = reviewed.firstIndex { $0.word == expected }
        if let observation {
            record["model"] = observation.response.model
            record["modelOutcome"] = GyaimController.fastContextRerankOutcome(model: observation.response.model ?? "")
            if let review = observation.response.review {
                let scored = Set(review.candidateIndices)
                record["inScoredSet"] = observation.request.candidates
                    .contains { scored.contains($0.index) && $0.text == expected }
            }
        }
        return (record, reviewed)
    }

    private func summarize(_ records: [[String: Any]], epochs: Int) -> [String: Any] {
        var result: [String: Any] = [:]
        for epoch in 1...epochs {
            let rows = records.filter { ($0["epoch"] as? Int) == epoch }
            var outcomes: [String: Int] = [:]
            for row in rows { outcomes[row["outcome"] as? String ?? "?", default: 0] += 1 }
            let conversions = rows.filter {
                let outcome = ($0["outcome"] as? String) ?? ""
                return !outcome.hasPrefix("kana-") && outcome != "raw"
            }
            let hits = outcomes["prefix-top1", default: 0]
            let heuristicHits = conversions.filter { ($0["heuristicRank"] as? Int) == 1 }.count
            let misses = conversions.filter { ($0["outcome"] as? String) != "prefix-top1" }
            result["epoch\(epoch)"] = [
                "segments": rows.count,
                "conversions": conversions.count,
                "outcomes": outcomes,
                "firstCandidateRate": conversions.isEmpty ? 0 : Double(hits) / Double(conversions.count),
                "heuristicFirstCandidateRate": conversions.isEmpty ? 0 : Double(heuristicHits) / Double(conversions.count),
                "missNotScored": misses.filter { ($0["inScoredSet"] as? Bool) == false }.count,
                "missScored": misses.filter { ($0["inScoredSet"] as? Bool) == true }.count,
                "missNoReview": misses.filter { $0["inScoredSet"] == nil }.count,
                // Selection keys to commit every unit (typing the romaji itself excluded).
                "ops": rows.reduce(0) { $0 + ($1["ops"] as? Int ?? 0) },
                "opsPerSentence": Double(rows.reduce(0) { $0 + ($1["ops"] as? Int ?? 0) })
                    / Double(max(1, Set(rows.compactMap { $0["sentence"] as? String }).count)),
            ] as [String: Any]
        }
        return result
    }
}
