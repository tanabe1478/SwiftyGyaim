import Foundation

struct AIRerankCandidate: Codable, Equatable {
    let index: Int
    let text: String
    let reading: String?
    let source: String
    let kind: String
    /// Context-conditioned learning score (0.0...1.0) from ContextDict.
    /// Nil / 0 means no history evidence for this (context, reading, word).
    let contextAffinity: Double?
    /// Study-dict frequency for study-sourced candidates. Nil for other sources.
    let studyFrequency: Int?

    init(index: Int,
         text: String,
         reading: String?,
         source: String,
         kind: String,
         contextAffinity: Double? = nil,
         studyFrequency: Int? = nil) {
        self.index = index
        self.text = text
        self.reading = reading
        self.source = source
        self.kind = kind
        self.contextAffinity = contextAffinity
        self.studyFrequency = studyFrequency
    }
}

struct AIRerankRequest: Codable, Equatable {
    let version: Int
    let mode: String
    let inputPat: String
    let hiragana: String
    let context: String?
    let candidates: [AIRerankCandidate]
}

/// Optional diagnostics from an actual model evaluation (absent for skips/fallback).
/// Indices refer to the request, not the full displayed list including raw/external rows.
struct AIRerankReview: Codable, Equatable {
    let candidateIndices: [Int]
    let scores: [String: Double]
    let topDecision: String
}

struct AIRerankResponse: Codable, Equatable {
    let order: [Int]
    let scores: [String: Double]?
    let model: String?
    var review: AIRerankReview?
}

struct AIRerankScoreBreakdown: Equatable {
    let total: Double
    let contributions: [String: Double]
}

enum AIReranker {
    static func validatedOrder(_ proposedOrder: [Int], candidateCount: Int) -> [Int] {
        guard candidateCount > 0 else { return [] }

        var seen = Set<Int>()
        var result: [Int] = []
        for index in proposedOrder where index >= 0 && index < candidateCount && !seen.contains(index) {
            seen.insert(index)
            result.append(index)
        }
        for index in 0..<candidateCount where !seen.contains(index) {
            result.append(index)
        }
        return result
    }

    static func apply(order proposedOrder: [Int], to candidates: [SearchCandidate]) -> [SearchCandidate] {
        validatedOrder(proposedOrder, candidateCount: candidates.count).map { candidates[$0] }
    }

    static func localRerank(_ request: AIRerankRequest,
                            model: String = "swift-local-heuristic") -> AIRerankResponse {
        var scores: [String: Double] = [:]
        let scored = request.candidates.map { candidate in
            let score = localScore(candidate: candidate, request: request)
            scores[String(candidate.index)] = score
            return (index: candidate.index, score: score)
        }
        let order = scored
            .sorted {
                if $0.score == $1.score { return $0.index < $1.index }
                return $0.score > $1.score
            }
            .map(\.index)
        return AIRerankResponse(order: order, scores: scores, model: model)
    }

    static func localScoreBreakdown(candidate: AIRerankCandidate, request: AIRerankRequest) -> AIRerankScoreBreakdown {
        var contributions: [String: Double] = [
            "positionPenalty": -Double(candidate.index) * 0.03,
            "sourceBias": sourceBias(candidate.source),
            "kindBias": kindBias(candidate.kind)
        ]
        if isExactReadingMatch(candidate: candidate, request: request) {
            contributions["exactReadingMatchBonus"] = 0.20
            if candidate.kind == CandidateKind.exact.rawValue,
               !isLearnedRawHiraganaCandidate(candidate, request: request) {
                contributions["exactReadingKindBonus"] = exactReadingBonus(candidate.text)
            }
        } else {
            contributions["prefixPredictionPenalty"] = -prefixPredictionPenalty(candidate: candidate,
                                                                                 inputPat: request.inputPat)
        }
        contributions["contextPredictionBonus"] = contextPredictionBonus(candidate: candidate, request: request)
        if let affinity = candidate.contextAffinity, affinity > 0,
           !isRawHiraganaCandidate(candidate, request: request) {
            contributions["contextAffinityBonus"] = min(affinity, 1.0) * 1.50
        }
        contributions["studyFrequencyBonus"] = studyFrequencyBonus(candidate)
        contributions["politeNegativePredictionPenalty"] = -politeNegativePredictionPenalty(candidate: candidate,
                                                                                             request: request)
        contributions["kanjiBonus"] = candidate.text.contains(where: isKanji) ? 0.10 : 0
        contributions["corpusFrequencyBonus"] = corpusFrequencyBonus(candidate)
        contributions["naturalFunctionWordPhraseBonus"] = naturalFunctionWordPhraseBonus(candidate.text)
        contributions["punctuationSuffixPenalty"] = -punctuationSuffixPenalty(candidate.text)
        contributions["punctuatedInputMismatchPenalty"] = -punctuatedInputMismatchPenalty(candidate: candidate,
                                                                                         request: request)
        contributions["incompleteStemPenalty"] = -incompleteStemPenalty(candidate: candidate,
                                                                        request: request)
        if candidate.kind == CandidateKind.zenz.rawValue && isAllKanjiWord(candidate.text) {
            contributions["zenzKanjiBonus"] = 0.50
        }
        if candidate.text == request.inputPat && candidate.text.allSatisfy(\.isASCII) {
            contributions["rawAsciiPenalty"] = -8.0
        }
        contributions["scriptTransitionPenalty"] = -unnaturalScriptTransitionPenalty(candidate.text)
        let nonZero = contributions.filter { $0.value != 0 }
        return AIRerankScoreBreakdown(total: nonZero.values.reduce(0, +), contributions: nonZero)
    }

    private static func studyFrequencyBonus(_ candidate: AIRerankCandidate) -> Double {
        guard candidate.source == "study", let frequency = candidate.studyFrequency, frequency > 1 else { return 0 }
        // Cap at 0.60 so a heavily used homophone (更新 freq 101) can beat a
        // rarely used one (行進 freq 11) even when both are exact-reading
        // study entries — 0.30 saturated at freq 8 and made them tie (BUG-026).
        return min(0.60, log2(Double(frequency)) * 0.10)
    }

    /// General frequency prior for dictionary candidates (CorpusFrequency, off at weight 0).
    private static func corpusFrequencyBonus(_ candidate: AIRerankCandidate) -> Double {
        let weight = CorpusFrequency.weight
        guard weight > 0, candidate.source != "synthetic", candidate.source != "external",
              let count = CorpusFrequency.shared.count(of: candidate.text) else { return 0 }
        return weight * log10(1 + Double(count))
    }

    private static func localScore(candidate: AIRerankCandidate, request: AIRerankRequest) -> Double {
        localScoreBreakdown(candidate: candidate, request: request).total
    }

    /// Exact reading match includes romaji spelling variants of the same kana:
    /// WordSearch assigns `kind=exact` when the candidate reading is
    /// kana-equivalent to the query (e.g. study "kousinn" for typed "kousin",
    /// BUG-026), so a dictionary-derived exact kind with a reading is trusted
    /// here. External candidates also carry `kind=exact` but have no reading.
    static func isExactReadingMatch(candidate: AIRerankCandidate, request: AIRerankRequest) -> Bool {
        if candidate.reading == request.inputPat { return true }
        return candidate.kind == CandidateKind.exact.rawValue && candidate.reading != nil
    }

    private static func exactReadingBonus(_ text: String) -> Double {
        text.count >= 5 ? 2.00 : 0.50
    }

    /// The literal hiragana rendering is always reachable through kana commit.
    /// A one-off ContextDict entry must not let it permanently override a
    /// frequently selected kanji candidate for the same reading (BUG-030).
    private static func isRawHiraganaCandidate(_ candidate: AIRerankCandidate,
                                               request: AIRerankRequest) -> Bool {
        candidate.text == request.hiragana && WordSearch.isAllHiragana(candidate.text)
    }

    private static func isLearnedRawHiraganaCandidate(_ candidate: AIRerankCandidate,
                                                      request: AIRerankRequest) -> Bool {
        (candidate.source == "study" || candidate.source == "local")
            && isRawHiraganaCandidate(candidate, request: request)
    }

    private static func prefixPredictionPenalty(candidate: AIRerankCandidate, inputPat: String) -> Double {
        guard candidate.kind == CandidateKind.prefix.rawValue,
              let reading = candidate.reading,
              reading.hasPrefix(inputPat),
              reading != inputPat else { return 0 }
        return min(1.50, Double(reading.count - inputPat.count) * 0.35)
    }

    private static func contextPredictionBonus(candidate: AIRerankCandidate, request: AIRerankRequest) -> Double {
        guard candidate.kind == CandidateKind.prefix.rawValue,
              let reading = candidate.reading,
              reading.hasPrefix(request.inputPat),
              reading != request.inputPat,
              let context = request.context else { return 0 }

        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var score = 0.0
        if candidate.text.hasSuffix("な"), hasStrongNegativeImperativeCue(trimmed) {
            score += 2.00
        }
        return score
    }

    private static func hasStrongNegativeImperativeCue(_ context: String) -> Bool {
        ["決して", "絶対に", "してはいけ", "してはなら", "禁止", "だめ", "ダメ", "ないで"].contains { context.contains($0) }
    }

    private static func politeNegativePredictionPenalty(candidate: AIRerankCandidate, request: AIRerankRequest) -> Double {
        guard isPoliteNegativePrediction(candidate.text), !inputExplicitlyRequestsPoliteNegative(request.inputPat) else {
            return 0
        }
        if let context = request.context,
           hasPoliteNegativeContextCue(context.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return 0
        }
        return 4.00
    }

    private static func isPoliteNegativePrediction(_ text: String) -> Bool {
        text.hasSuffix("ません") || text.hasSuffix("ませんか") || text.hasSuffix("ません？") || text.hasSuffix("ませんか？")
    }

    private static func inputExplicitlyRequestsPoliteNegative(_ inputPat: String) -> Bool {
        inputPat.contains("masen") || inputPat.contains("masenn")
    }

    private static func hasPoliteNegativeContextCue(_ context: String) -> Bool {
        guard !context.isEmpty else { return false }
        return ["ない", "ません", "ではなく", "じゃなく", "しない", "できない", "不要", "禁止"].contains { context.contains($0) }
    }

    private static func naturalFunctionWordPhraseBonus(_ text: String) -> Double {
        var score = 0.0
        if text.range(of: #"[一-龯]の[一-龯]"#, options: .regularExpression) != nil {
            score += 1.40
        }
        if text.hasSuffix("では") || text.hasSuffix("には") || text.hasSuffix("とは") {
            score += 0.70
        }
        return score
    }

    private static func punctuationSuffixPenalty(_ text: String) -> Double {
        text.hasSuffix("？") || text.hasSuffix("！") ? 0.10 : 0.0
    }

    private static func punctuatedInputMismatchPenalty(candidate: AIRerankCandidate,
                                                       request: AIRerankRequest) -> Double {
        let expectedPunctuation: [Character]
        if request.inputPat.hasSuffix("?") {
            expectedPunctuation = ["?", "？"]
        } else if request.inputPat.hasSuffix("!") {
            expectedPunctuation = ["!", "！"]
        } else {
            return 0
        }
        guard !candidate.text.contains(where: { expectedPunctuation.contains($0) }) else { return 0 }
        return 3.00
    }

    private static func incompleteStemPenalty(candidate: AIRerankCandidate,
                                              request: AIRerankRequest) -> Double {
        guard isPotentialIncompleteStem(candidate.text) else { return 0 }
        let longerCompletedCandidateExists = request.candidates.contains { other in
            other.index != candidate.index && isIncompleteStemCompletion(stem: candidate.text, completed: other.text)
        }
        return longerCompletedCandidateExists ? 4.00 : 0
    }

    static func isPotentialIncompleteStem(_ text: String) -> Bool {
        guard !text.isEmpty, !text.allSatisfy(isKanji) else { return false }
        return text.unicodeScalars.contains { 0x3041...0x3096 ~= $0.value }
    }

    /// True when `completed` is `stem` plus exactly one character and the pair
    /// looks like a mid-conjugation truncation:
    /// - "少な" → "少ない" (i-adjective missing the final い)
    /// - "使っ" → "使った" / "言っ" → "言って" (no Japanese word ends with っ)
    ///
    /// A stem that already ends with い is NOT missing its い — the premise of
    /// the い rule doesn't apply. Without this guard, a garbage study entry
    /// like "してほしいい" made the legitimate "してほしい" look like an
    /// incomplete stem and demoted it (BUG-025). A past tense in た/だ is
    /// finished for the same reason: 見た → 見たい is the desiderative (BUG-043).
    static func isIncompleteStemCompletion(stem: String, completed: String) -> Bool {
        guard completed != stem,
              completed.hasPrefix(stem),
              completed.dropFirst(stem.count).count == 1 else { return false }
        if completed.last == "い", let last = stem.last, !"いただ".contains(last) { return true }
        if stem.last == "っ" { return true }
        return false
    }

    private static func sourceBias(_ source: String) -> Double {
        switch source {
        case "study": return 0.40
        case "local": return 0.30
        case "connection": return 0.10
        case "google": return 0.60
        case "external": return -0.10
        case "synthetic": return -0.30
        default: return 0.0
        }
    }

    private static func kindBias(_ kind: String) -> Double {
        switch kind {
        case "google": return 0.35
        case "exact": return 0.25
        case "zenz": return 0.40
        case "lattice": return 0.30
        case "compound": return 0.20
        case "prefix": return -0.10
        case "completion": return -0.20
        case "kana": return -0.25
        case "raw": return -1.00
        default: return 0.0
        }
    }

    private static func unnaturalScriptTransitionPenalty(_ text: String) -> Double {
        let chars = Array(text)
        guard chars.count >= 2 else { return 0 }
        var penalty = 0.0
        for index in 1..<chars.count {
            if isHiragana(chars[index - 1]) && isKanji(chars[index]) {
                penalty += 1.50
            }
            if isKatakana(chars[index - 1]) && isHiragana(chars[index]) {
                penalty += 1.00
            }
        }
        return penalty
    }

    private static func isHiragana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { 0x3040...0x309F ~= $0.value }
    }

    private static func isKatakana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { 0x30A0...0x30FF ~= $0.value }
    }

    private static func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { 0x4E00...0x9FFF ~= $0.value }
    }

    private static func isAllKanjiWord(_ text: String) -> Bool {
        text.count >= 2 && text.allSatisfy(isKanji)
    }
}
