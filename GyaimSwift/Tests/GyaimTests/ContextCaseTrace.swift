import CryptoKit
import Foundation
@testable import Gyaim

/// Test-harness diagnostics only. No additional model calls or runtime policy changes.
enum ContextCaseTrace {
    struct Observation {
        let lineNumber: Int
        let sourceLine: String
        let length: Int
        let truthIndex: Int
        let request: AIRerankRequest
        let modelScores: [Int: Double]
        let modelOrder: [Int]
        let production: (order: [Int], totals: [Int: Double])
        let heuristicOrder: [Int]
    }

    enum TraceError: Error { case inconsistentAdjustments }

    static var weights: [String: Double] {
        ["study": BundledZenzRuntime.llmRankStudyWeight(), "context": BundledZenzRuntime.llmRankContextWeight(),
         "rawHiragana": BundledZenzRuntime.llmRankRawHiraganaPenalty(),
         "compound": BundledZenzRuntime.llmRankCompoundWeight()]
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sourceHashes(project: URL) throws -> [String: String] {
        let names = ["AIReranker.swift", "ZenzRuntime.swift", "ZenzRuntime+Scoring.swift", "ZenzRuntime+LLMRank.swift",
                     "LlamaZenzContext.swift", "LlamaZenzContext+Batch.swift", "GyaimSettings.swift", "RomaKana.swift",
                     "WordSearch.swift", "ConnectionDict.swift", "ConnectionDict+Compositions.swift"]
        let paths = names.map { "Sources/Gyaim/\($0)" } + [
            "Tests/GyaimTests/ContextCaseTrace.swift", "Tests/GyaimTests/ContextCasesEvaluationTests.swift",
            "Packages/LlamaCpp/Package.swift", "project.yml",
        ]
        return try Dictionary(uniqueKeysWithValues: paths.map { ($0, try fileDigest(project.appendingPathComponent($0))) })
    }

    static func adjustments(candidate: AIRerankCandidate, request: AIRerankRequest) -> [String: Double] {
        let current = weights
        let breakdown = AIReranker.localScoreBreakdown(candidate: candidate, request: request)
        var result = Dictionary(uniqueKeysWithValues: BundledZenzRuntime.llmRankSafetyPenalties.map {
            ($0, breakdown.contributions[$0] ?? 0)
        })
        let frequency = candidate.source == "study" ? candidate.studyFrequency ?? 0 : 0
        result["study"] = (current["study"] ?? 0) * log2(1 + Double(frequency))
        result["context"] = (current["context"] ?? 0) * min(candidate.contextAffinity ?? 0, 1)
        result["compound"] = candidate.compoundCompletion == true ? current["compound"] : 0
        result["rawHiragana"] = candidate.text == request.hiragana ? -(current["rawHiragana"] ?? 0) : 0
        return result
    }

    static func record(_ observation: Observation) throws -> [String: Any] {
        let candidates = observation.request.candidates
        let offsets = candidates.map { adjustments(candidate: $0, request: observation.request) }
        for (candidate, offset) in zip(candidates, offsets) {
            guard let score = observation.modelScores[candidate.index] else { continue }
            let reconstructed = score + offset.values.reduce(0, +)
            guard let actual = observation.production.totals[candidate.index], reconstructed.isFinite,
                  abs(actual - reconstructed) < 1e-8 else { throw TraceError.inconsistentAdjustments }
        }
        func vector(_ scores: [Int: Double]) -> [Any] {
            candidates.map { candidate in scores[candidate.index].map { $0 as Any } ?? NSNull() }
        }
        return [
            "type": "case", "lineNumber": observation.lineNumber,
            "caseLineSha256": digest(Data(observation.sourceLine.utf8)), "contextLength": observation.length,
            "requestPromptSha256": digest(Data(BundledZenzRuntime.prompt(for: observation.request).utf8)),
            "truthIndex": observation.truthIndex, "modelScores": vector(observation.modelScores),
            "productionScores": vector(observation.production.totals), "adjustments": offsets,
            "modelOrder": observation.modelOrder, "productionOrder": observation.production.order,
            "heuristicOrder": observation.heuristicOrder,
            "literalHiraganaIndices": candidates.filter { $0.text == observation.request.hiragana }.map(\.index),
            "compoundIndices": candidates.filter { $0.compoundCompletion == true }.map(\.index),
        ]
    }
}

/// A failed run leaves only a .partial file. Existing outputs are never overwritten.
final class ContextCaseTraceWriter {
    private let destination: URL
    private let partial: URL
    private let handle: FileHandle

    init(path: String, metadata: [String: Any]) throws {
        destination = URL(fileURLWithPath: path)
        partial = destination.appendingPathExtension("partial")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try Data().write(to: partial, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        handle = try FileHandle(forWritingTo: partial)
        try append(metadata)
    }

    deinit { try? handle.close() }

    func append(_ record: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    func finish(summary: [String: Any]) throws {
        try append(["type": "summary", "report": summary])
        try handle.synchronize()
        try handle.close()
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}
