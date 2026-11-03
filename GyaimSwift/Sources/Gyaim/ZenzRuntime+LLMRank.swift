import Foundation

/// LLM-primary ordering of fast-context candidates (ADR-032). The bundled model
/// scores every dictionary candidate in one batch; the order is the model's
/// mean logprob plus the user's study frequency and ContextDict affinity. The
/// heuristic only contributes its safety penalties (incomplete stems, polite
/// negative predictions, punctuation mismatch, raw ASCII) and breaks ties.
/// The literal hiragana of the input is always one kana-key press away, so it
/// needs a clear model margin to be offered first (ADR-039: 1.0; the 3.0 of
/// ADR-032 overrode the model in ください/下さい, それぞれ/夫々, いれば/入れ歯).
extension BundledZenzRuntime {
    static let llmRankDefaultRawHiraganaPenalty = 1.0
    static let llmRankRawHiraganaPenaltyKey = "aiRerankLLMRawHiraganaPenalty"

    /// Subtracted from the candidate that is the input's literal hiragana.
    /// Configurable so dogfood can compare values; negative settings are clamped to 0.
    static func llmRankRawHiraganaPenalty() -> Double {
        guard GyaimSettings.objectExists(forKey: llmRankRawHiraganaPenaltyKey) else {
            return llmRankDefaultRawHiraganaPenalty
        }
        return rawHiraganaPenalty(configured: GyaimSettings.double(forKey: llmRankRawHiraganaPenaltyKey))
    }

    static func rawHiraganaPenalty(configured: Double) -> Double {
        configured.isFinite ? max(configured, 0) : llmRankDefaultRawHiraganaPenalty
    }

    /// Heuristic contributions kept as hard safety rules in LLM ranking.
    static let llmRankSafetyPenalties: Set<String> = [
        "incompleteStemPenalty", "politeNegativePredictionPenalty",
        "punctuatedInputMismatchPenalty", "rawAsciiPenalty",
    ]

    /// Per doubling of study frequency. 2.0 keeps 君 (31) over キミ (7) against
    /// the ~3.4 logprob gap from BUG-036: 2 × (log2 32 − log2 8) = 4.
    static func llmRankStudyWeight() -> Double {
        let configured = GyaimSettings.double(forKey: "aiRerankLLMStudyWeight")
        return configured > 0 ? configured : 2.0
    }

    static func llmRankContextWeight() -> Double {
        let configured = GyaimSettings.double(forKey: "aiRerankLLMContextWeight")
        return configured > 0 ? configured : 2.0
    }

    /// Bonus for a candidate that completes a dictionary compound with the
    /// previous committed word (ADR-040). 2.0 covers the 1.2–1.5 logprob gaps
    /// of 全体像 / 回避策 / 一番下 in the October logs without overriding a
    /// study-backed candidate that led by 2.3.
    static let llmRankDefaultCompoundWeight = 2.0
    static func llmRankCompoundWeight() -> Double {
        let configured = GyaimSettings.double(forKey: "aiRerankLLMCompoundWeight")
        return configured > 0 ? configured : llmRankDefaultCompoundWeight
    }

    /// Candidates without a model score sink below every scored one, in
    /// heuristic order.
    static func llmPrimaryOrder(request: AIRerankRequest, heuristicOrder: [Int], llmScores: [Int: Double],
                                studyWeight: Double, contextWeight: Double,
                                rawHiraganaPenalty: Double = llmRankRawHiraganaPenalty(),
                                compoundWeight: Double = llmRankCompoundWeight()
    ) -> (order: [Int], totals: [Int: Double]) {
        let heuristicRank = Dictionary(uniqueKeysWithValues: heuristicOrder.enumerated().map { ($1, $0) })
        var totals: [Int: Double] = [:]
        for candidate in request.candidates {
            guard let llm = llmScores[candidate.index], llm.isFinite else { continue }
            var total = llm
            if candidate.source == "study", let frequency = candidate.studyFrequency {
                total += studyWeight * log2(1 + Double(frequency))
            }
            total += contextWeight * min(candidate.contextAffinity ?? 0, 1.0)
            if candidate.compoundCompletion == true { total += compoundWeight }
            let breakdown = AIReranker.localScoreBreakdown(candidate: candidate, request: request)
            total += breakdown.contributions.filter { llmRankSafetyPenalties.contains($0.key) }.values.reduce(0, +)
            if candidate.text == request.hiragana { total -= rawHiraganaPenalty }
            totals[candidate.index] = total
        }
        let order = request.candidates.map(\.index).sorted { lhs, rhs in
            switch (totals[lhs], totals[rhs]) {
            case let (left?, right?) where left != right: return left > right
            case (.some, .none): return true
            case (.none, .some): return false
            default: return (heuristicRank[lhs] ?? .max) < (heuristicRank[rhs] ?? .max)
            }
        }
        return (order, totals)
    }

    #if canImport(llama)
    func llmPrimaryRerank(_ request: AIRerankRequest, activeContext: LlamaZenzContext,
                          heuristic: AIRerankResponse, localOrder: [Int]) -> AIRerankResponse {
        let start = CFAbsoluteTimeGetCurrent()
        let prompt = Self.prompt(for: request)
        let batch = activeContext.scoreBatch(prompt: prompt, continuations: request.candidates.map(\.text))
        var llmScores: [Int: Double] = [:]
        for (candidate, score) in zip(request.candidates, batch) {
            if let score, score.isFinite { llmScores[candidate.index] = score }
        }
        guard !llmScores.isEmpty else {
            return AIRerankResponse(order: localOrder, scores: heuristic.scores,
                                    model: "\(identifier)-review-llm-ranked-unavailable+swift-local-heuristic",
                                    review: AIRerankReview(candidateIndices: request.candidates.map(\.index),
                                                           scores: [:], topDecision: "unavailable"))
        }
        let ranked = Self.llmPrimaryOrder(request: request, heuristicOrder: localOrder, llmScores: llmScores,
                                          studyWeight: Self.llmRankStudyWeight(),
                                          contextWeight: Self.llmRankContextWeight(),
                                          rawHiraganaPenalty: Self.llmRankRawHiraganaPenalty(),
                                          compoundWeight: Self.llmRankCompoundWeight())
        let changed = ranked.order.first != localOrder.first
        Log.input.info("Zenz llm-rank finished: input=\"\(request.inputPat)\" scored=\(llmScores.count)/"
            + "\(request.candidates.count) topChanged=\(changed) order=\(ranked.order.prefix(8)) "
            + "latency=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 1000))ms")
        return AIRerankResponse(
            order: ranked.order,
            scores: Dictionary(uniqueKeysWithValues: ranked.totals.map { (String($0.key), $0.value) }),
            model: "\(identifier)-review-llm-ranked+swift-local-heuristic",
            review: AIRerankReview(candidateIndices: request.candidates.map(\.index),
                                   scores: Dictionary(uniqueKeysWithValues: llmScores.map { (String($0.key), $0.value) }),
                                   topDecision: changed ? "fixed" : "passed"))
    }
    #endif
}
