import Foundation
@testable import Gyaim

/// Experimental rankers for TypingSimulationTests (GYAIM_TYPING_SIM_LLM_RANK=1):
/// order the dictionary candidates by the bundled LM alone, and by the LM plus
/// the study-frequency bonus, to compare against heuristic + model review.
final class TypingSimulationLLMRanker {
    private let context: LlamaZenzContext
    private let studyWeights: [Double]

    init?(bundle: Bundle, studyWeights: [Double] = [0.25, 0.5, 1.0]) {
        guard let url = BundledAIRerankModel.resolveModelURL(bundle: bundle),
              let context = try? LlamaZenzContext(modelURL: url) else { return nil }
        self.context = context
        self.studyWeights = studyWeights
    }

    /// 1-based ranks of `expected` among the first `limit` distinct dictionary
    /// candidates: `llmRank` (mean logprob only), `llmStudyRank@w` (plus
    /// w * log2(1 + study frequency)) and `llmStudyContextRank@c` (plus
    /// c * ContextDict affinity on top of the study bonus at weight 1).
    /// Nil when it is not among them.
    func ranks(searchResults: [SearchCandidate], input: String, hiragana: String,
               leftContext: String, expected: String, limit: Int = 24) -> [String: Any] {
        var seen: Set<String> = []
        let candidates = searchResults.filter { seen.insert($0.word).inserted }.prefix(limit)
        let request = AIRerankRequest(version: 1, mode: "fast-context-rerank", inputPat: input, hiragana: hiragana,
                                      context: GyaimController.limitedFastContext(leftContext), candidates: [])
        let prompt = BundledZenzRuntime.prompt(for: request)
        let start = CFAbsoluteTimeGetCurrent()
        let batch = context.scoreBatch(prompt: prompt, continuations: candidates.map(\.word))
        let scored = zip(candidates, batch).map { ($0, $1 ?? -99) }
        var result: [String: Any] = ["llmMs": Int((CFAbsoluteTimeGetCurrent() - start) * 1000),
                                     "llmScored": scored.count]
        func rank(_ bonus: (SearchCandidate) -> Double) -> Int? {
            let order = scored.sorted { $0.1 + bonus($0.0) > $1.1 + bonus($1.0) }
            return order.firstIndex { $0.0.word == expected }.map { $0 + 1 }
        }
        result["llmRank"] = rank { _ in 0 }
        func study(_ candidate: SearchCandidate, _ weight: Double) -> Double {
            guard candidate.source == .study, let frequency = candidate.studyFrequency else { return 0 }
            return weight * log2(1 + Double(frequency))
        }
        for weight in studyWeights {
            result["llmStudyRank@\(weight)"] = rank { study($0, weight) }
        }
        for contextWeight in [1.0, 2.0, 4.0] {
            result["llmStudyContextRank@\(contextWeight)"] = rank { candidate in
                study(candidate, 1.0) + contextWeight * ContextDict.shared.affinity(
                    context: leftContext, reading: candidate.reading, word: candidate.word)
            }
        }
        return result
    }
}
