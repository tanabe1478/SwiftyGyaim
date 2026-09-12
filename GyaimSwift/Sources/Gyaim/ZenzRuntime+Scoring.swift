import Foundation

/// Scoring, candidate safety, and ordering helpers; model inference stays in ZenzRuntime.
extension BundledZenzRuntime {
    static func prompt(for request: AIRerankRequest) -> String {
        var prompt = ""
        if let context = request.context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
            prompt += ZenzPrompt.contextTag + context
        }
        prompt += ZenzPrompt.inputTag + inputForZenz(request)
        prompt += ZenzPrompt.outputTag
        return prompt
    }

    static func isJapaneseLike(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            0x3040...0x309F ~= scalar.value
                || 0x30A0...0x30FF ~= scalar.value
                || 0x4E00...0x9FFF ~= scalar.value
        }
    }

    static func inputForZenz(_ request: AIRerankRequest) -> String {
        let katakana = RomaKana().roma2katakana(request.inputPat)
        if !katakana.isEmpty { return katakana }
        return hiraganaToKatakana(request.hiragana)
    }

    static func hiraganaToKatakana(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar in
            if 0x3041...0x3096 ~= scalar.value,
               let converted = UnicodeScalar(scalar.value + 0x60) {
                return Character(converted)
            }
            return Character(scalar)
        })
    }

    static func scoreWeight() -> Double {
        let configured = GyaimSettings.double(forKey: "aiRerankZenzWeight")
        return configured > 0 ? configured : 0.30
    }

    /// Combine heuristic and Zenz scores with mean-centering (BUG-029).
    /// Mean log probabilities are always negative, so adding them raw
    /// penalized every scored candidate relative to unscored ones — garbage
    /// compounds sitting past the scoring budget outranked good words the
    /// model had scored (seisansei: 性三世 above 生産性). Centering on the
    /// scored set's mean makes the model's opinion zero-sum: better-than-
    /// average words gain, worse lose, unscored candidates stay untouched.
    static func combineScores(heuristic: [Int: Double],
                              zenz: [Int: Double],
                              weight: Double) -> [Int: Double] {
        guard !zenz.isEmpty else { return heuristic }
        let meanZenz = zenz.values.reduce(0, +) / Double(zenz.count)
        var combined = heuristic
        for (index, score) in zenz {
            combined[index] = (heuristic[index] ?? 0) + (score - meanZenz) * weight
        }
        return combined
    }

    static func maxScoredCandidates() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankZenzMaxCandidates")
        return configured > 0 ? configured : 8
    }

    static func shouldScoreWithZenz(_ candidate: AIRerankCandidate,
                                            maxScoredCandidates: Int) -> Bool {
        guard candidate.kind != CandidateKind.raw.rawValue else { return false }
        return candidate.index < maxScoredCandidates || candidate.kind == CandidateKind.zenz.rawValue
    }

    static func fastContextReplacementIndex(forFixRequiredPrefix prefix: String,
                                            localOrder: [Int],
                                            request: AIRerankRequest) -> Int? {
        let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrefix.isEmpty, let currentBest = localOrder.first else { return nil }
        // A 1-char prefix is too broad for hasPrefix matching ("こ" would match
        // half the candidate list), but dogfood showed ~48% of reviews end as
        // kept-local no-ops on single-kanji prefixes like "書" / "十". Allow the
        // narrow safe subset: a candidate whose text IS the prefix and whose
        // reading exactly matches the input.
        if normalizedPrefix.count == 1 {
            return localOrder.first { index in
                guard index != currentBest,
                      let candidate = request.candidates.first(where: { $0.index == index }) else { return false }
                return candidate.text == normalizedPrefix
                    && isProtectedExactReadingCandidate(candidate, request: request)
            }
        }
        return localOrder.first { index in
            guard index != currentBest,
                  let candidate = request.candidates.first(where: { $0.index == index }) else { return false }
            return candidate.text.hasPrefix(normalizedPrefix)
        }
    }

    /// Candidates eligible for the exact-homophone direct comparison, in local
    /// order. Restricted to protected exact-reading candidates; incomplete stems
    /// whose completion exists in the candidate set (e.g. "くださ" while
    /// "ください" is present, "使っ" while "使った" is present) are excluded so
    /// the model can never promote a mid-conjugation truncation.
    ///
    /// The raw kana spelling of the input (candidate text == request.hiragana)
    /// is also excluded unless it is the current best: the char-level LM
    /// systematically assigns higher probability to kana sequences, so "こみ"
    /// would beat "込み" and "いっか" would beat "一家" regardless of context
    /// (BUG-024, dogfood 2026-07-05). The kana spelling stays reachable through
    /// the heuristic order and the kana-confirm keys. Hiragana words that are
    /// not the raw spelling (e.g. "ください" for input "kudasa") remain
    /// comparable.
    static func exactHomophoneCandidateIndices(request: AIRerankRequest,
                                               localOrder: [Int],
                                               limit: Int = 3) -> [Int] {
        var result: [Int] = []
        for index in localOrder {
            guard result.count < limit else { break }
            guard let candidate = request.candidates.first(where: { $0.index == index }),
                  isProtectedExactReadingCandidate(candidate, request: request),
                  !isIncompleteStemCandidate(candidate, in: request) else { continue }
            if index != localOrder.first,
               isHiraganaOnlyText(candidate.text),
               candidate.text == request.hiragana { continue }
            // The character LM systematically underrates symbol candidates
            // (〇 scored -8.6 vs 円 -2.9 for reading まる), so a user's
            // repeatedly chosen symbol kept losing the comparison no matter
            // how often it was re-confirmed (BUG-031). Symbols never take
            // part: as current best this skips the override entirely, and as
            // challenger the LM would never fairly promote them anyway.
            if isSymbolOnlyText(candidate.text) { continue }
            result.append(index)
        }
        return result
    }

    static func isSymbolOnlyText(_ text: String) -> Bool {
        !text.isEmpty && !text.contains(where: isJapaneseLike)
    }

    static func isHiraganaOnlyText(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            0x3041...0x3096 ~= scalar.value || scalar.value == 0x30FC
        }
    }

    static func isIncompleteStemCandidate(_ candidate: AIRerankCandidate,
                                                  in request: AIRerankRequest) -> Bool {
        guard AIReranker.isPotentialIncompleteStem(candidate.text) else { return false }
        return request.candidates.contains { other in
            other.index != candidate.index
                && AIReranker.isIncompleteStemCompletion(stem: candidate.text, completed: other.text)
        }
    }

    /// Sort only the already-scored alternative slots. The top selected by the
    /// existing guards, unscored candidates, and equal-score order are preserved.
    static func rerankScoredAlternatives(localOrder: [Int], scores: [Int: Double]) -> [Int] {
        guard let first = localOrder.first, scores[first]?.isFinite == true else { return localOrder }
        let slots = localOrder.indices.dropFirst().filter { scores[localOrder[$0]]?.isFinite == true }
        let ranked = slots.sorted {
            let lhs = scores[localOrder[$0]] ?? 0
            let rhs = scores[localOrder[$1]] ?? 0
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }.map { localOrder[$0] }
        var order = localOrder
        for (slot, index) in zip(slots, ranked) { order[slot] = index }
        return order
    }

    /// A learned context preference raises the log-probability bar the model
    /// must clear to override it: dogfood 2026-07-14 showed the model
    /// demoting the user's own choices (使用 over learned 仕様) when the
    /// context matched only partially (affinity below the 0.75 skip
    /// threshold). One affinity point is worth this many mean-logprob units.
    static let affinityMarginWeight = 2.0

    /// A study-frequency advantage of the current best likewise raises the
    /// bar (BUG-036). Dogfood 2026-09-11: the model promoted キミ (freq 7)
    /// over 君 (freq 31, mean-logprob gap 3.4 because キミ appeared in the
    /// left context) and 私的 (freq 3) over 指摘 (freq 63, gap 0.5); both
    /// were reverted by the user. Each doubling of the best's frequency over
    /// the challenger's is worth this many mean-logprob units.
    static let defaultFrequencyMarginWeight = 2.0

    /// Picks the homophone to promote: the highest-scoring candidate wins only
    /// when it beats the current best by at least `margin` (mean log-probability
    /// units) plus the current best's context-affinity advantage plus its
    /// study-frequency advantage, so model noise cannot flap the top candidate
    /// and cannot override what the user already taught the IME.
    static func selectExactHomophoneWinner(scores: [Int: Double],
                                           currentBest: Int,
                                           margin: Double,
                                           affinities: [Int: Double] = [:],
                                           studyFrequencies: [Int: Int] = [:],
                                           frequencyMarginWeight: Double = defaultFrequencyMarginWeight) -> Int? {
        guard let bestScore = scores[currentBest] else { return nil }
        var winnerIndex = currentBest
        var winnerScore = bestScore
        for (index, score) in scores.sorted(by: { $0.key < $1.key }) where score > winnerScore {
            winnerIndex = index
            winnerScore = score
        }
        guard winnerIndex != currentBest else { return nil }
        let affinityAdvantage = max(0, (affinities[currentBest] ?? 0) - (affinities[winnerIndex] ?? 0))
        let frequencyAdvantage = studyFrequencyAdvantage(best: studyFrequencies[currentBest],
                                                         challenger: studyFrequencies[winnerIndex])
        let requiredMargin = margin
            + affinityAdvantage * affinityMarginWeight
            + frequencyAdvantage * frequencyMarginWeight
        guard winnerScore - bestScore >= requiredMargin else { return nil }
        return winnerIndex
    }

    /// log2(bestFrequency / challengerFrequency), clamped at 0. Only a study
    /// best (frequency known) raises the bar; a challenger without study
    /// history (dictionary-only word) counts as frequency 1.
    static func studyFrequencyAdvantage(best: Int?, challenger: Int?) -> Double {
        guard let best, best > 1 else { return 0 }
        let challengerFrequency = max(challenger ?? 1, 1)
        guard best > challengerFrequency else { return 0 }
        return log2(Double(best) / Double(challengerFrequency))
    }

    static func studyFrequencies(of request: AIRerankRequest) -> [Int: Int] {
        var frequencies: [Int: Int] = [:]
        for candidate in request.candidates where candidate.source == "study" {
            if let frequency = candidate.studyFrequency, frequency > 0 {
                frequencies[candidate.index] = frequency
            }
        }
        return frequencies
    }

    static func contextAffinities(of request: AIRerankRequest) -> [Int: Double] {
        var affinities: [Int: Double] = [:]
        for candidate in request.candidates {
            if let affinity = candidate.contextAffinity, affinity > 0 {
                affinities[candidate.index] = affinity
            }
        }
        return affinities
    }

    static func maxScoreIndex(_ scores: [Int: Double]) -> Int? {
        scores.sorted { $0.key < $1.key }.max { $0.value < $1.value }?.key
    }

    static func shouldRunNormalReview(inputPat: String, minimumLength: Int) -> Bool {
        inputPat.count >= minimumLength
    }

    static func normalReviewMinInputLength() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankFastContextNormalReviewMinInputLength")
        guard configured > 0 else { return 5 }
        return min(max(configured, 1), 12)
    }

    /// True when ContextDict evidence for the current best is strong enough
    /// (suffix overlap >= 3 chars at the default threshold) to settle the
    /// homophone choice without consulting the model.
    static func shouldSkipHomophoneReviewForAffinity(best: AIRerankCandidate,
                                                     threshold: Double) -> Bool {
        guard threshold > 0, let affinity = best.contextAffinity else { return false }
        return affinity >= threshold
    }

    static func exactHomophoneAffinityThreshold() -> Double {
        let configured = GyaimSettings.double(forKey: "aiRerankExactHomophoneAffinityThreshold")
        return configured > 0 ? min(configured, 1.0) : 0.75
    }

    static func exactHomophoneScoreMargin() -> Double {
        let configured = GyaimSettings.double(forKey: "aiRerankExactHomophoneMargin")
        return configured > 0 ? configured : 0.10
    }

    static func exactHomophoneFrequencyMarginWeight() -> Double {
        let configured = GyaimSettings.double(forKey: "aiRerankExactHomophoneFrequencyMarginWeight")
        return configured > 0 ? configured : defaultFrequencyMarginWeight
    }

    static func exactHomophoneMaxCandidates() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankExactHomophoneMaxCandidates")
        return configured > 0 ? min(configured, 6) : 3
    }

    static func shouldReviewExactHomophones(best: AIRerankCandidate,
                                            request: AIRerankRequest,
                                            localOrder: [Int]) -> Bool {
        guard isProtectedExactReadingCandidate(best, request: request), hasContext(request.context) else {
            return false
        }
        return localOrder.contains { index in
            guard index != best.index,
                  let candidate = request.candidates.first(where: { $0.index == index }) else { return false }
            return isProtectedExactReadingCandidate(candidate, request: request)
        }
    }

    static func hasContext(_ context: String?) -> Bool {
        guard let context else { return false }
        return !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isProtectedExactReadingCandidate(_ candidate: AIRerankCandidate,
                                                         request: AIRerankRequest) -> Bool {
        switch candidate.kind {
        case CandidateKind.exact.rawValue:
            // WordSearch assigns .exact only for exact or kana-equivalent
            // readings (BUG-026: study "kousinn" vs typed "kousin"), so an
            // exact kind with a reading is protected. External candidates also
            // use .exact but carry no reading.
            return candidate.reading != nil
        case CandidateKind.compound.rawValue:
            return candidate.reading == request.inputPat
        default:
            return false
        }
    }

    static func normalReviewResponse(order: [Int], scores: [String: Double]?,
                                      outcome: String, reviewedIndex: Int) -> AIRerankResponse {
        AIRerankResponse(order: order, scores: scores,
                         model: "\(BundledAIRerankModel.activeModelLabel)-review-\(outcome)+swift-local-heuristic",
                         review: AIRerankReview(candidateIndices: [reviewedIndex], scores: [:], topDecision: outcome))
    }

    static func homophoneResponse(request: AIRerankRequest, heuristic: AIRerankResponse,
                                   indices: [Int], scores: [Int: Double]) -> AIRerankResponse {
        let localOrder = heuristic.order
        guard let bestIndex = localOrder.first else { return heuristic }
        let finiteScores = scores.filter { indices.contains($0.key) && $0.value.isFinite }
        var order = localOrder
        let outcome: String
        if finiteScores[bestIndex] == nil || finiteScores.count < 2 {
            outcome = "unavailable"
        } else if let replacement = Self.selectExactHomophoneWinner(scores: finiteScores,
                                                                    currentBest: bestIndex,
                                                                    margin: Self.exactHomophoneScoreMargin(),
                                                                    affinities: Self.contextAffinities(of: request),
                                                                    studyFrequencies: Self.studyFrequencies(of: request),
                frequencyMarginWeight: Self.exactHomophoneFrequencyMarginWeight()) {
            outcome = "fixed"
            order.removeAll { $0 == replacement }
            order.insert(replacement, at: 0)
            Log.input.info("Zenz exact-homophone review fixed: input=\"\(request.inputPat)\" "
                + "replacementIndex=\(replacement)")
        } else if Self.maxScoreIndex(finiteScores) != bestIndex {
            outcome = "kept-local"
        } else {
            outcome = "passed"
        }

        // Keep the existing top decision and all unscored slots intact. Reuse
        // only the scores already computed above; no extra model calls.
        let topOrder = order
        if outcome != "unavailable" {
            order = Self.rerankScoredAlternatives(localOrder: order, scores: finiteScores)
        }
        let reportedOutcome = outcome != "fixed" && order != topOrder ? "tail-reranked" : outcome
        let label = "\(BundledAIRerankModel.activeModelLabel)-review-exact-homophone-\(reportedOutcome)+swift-local-heuristic"
        let review = AIRerankReview(candidateIndices: indices,
                                    scores: Dictionary(uniqueKeysWithValues: finiteScores.map { (String($0.key), $0.value) }),
                                    topDecision: outcome)
        return AIRerankResponse(order: order, scores: heuristic.scores, model: label, review: review)
    }

}
