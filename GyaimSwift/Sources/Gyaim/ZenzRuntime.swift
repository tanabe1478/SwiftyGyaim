import Foundation
#if canImport(llama)
import llama
#endif

enum ZenzRuntimeStatus: Equatable {
    case ready
    case unavailable(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Runtime boundary for the bundled Zenz/GGUF model.
///
/// `BundledZenzRuntime` prepares the model file and, when the llama module is
/// linked, creates a llama.cpp model/context/vocab in-process. Rerank combines
/// Swift heuristic scores with lightweight Zenz continuation scores for the top
/// candidates, and returns nil so callers can fall back when runtime scoring is
/// unavailable.
protocol ZenzRuntime {
    var identifier: String { get }
    func prepare() -> ZenzRuntimeStatus
    func rerank(_ request: AIRerankRequest) -> AIRerankResponse?
    func generateCandidates(inputPat: String, hiragana: String, context: String?, limit: Int) -> [SearchCandidate]
    func alternativeCandidates(for request: AIRerankRequest, limit: Int) -> [SearchCandidate]
    /// Dictionary-constrained selection (issue #59, ADR-022): rank the given
    /// dictionary-composable surfaces by conditional log probability and return
    /// the best ones. The model can only choose among `surfaces`, so it can
    /// never emit a word the dictionary cannot form.
    func selectCandidates(inputPat: String,
                          hiragana: String,
                          context: String?,
                          surfaces: [String],
                          limit: Int) -> [SearchCandidate]
}

extension ZenzRuntime {
    func generateCandidates(inputPat: String, hiragana: String, context: String?, limit: Int) -> [SearchCandidate] {
        []
    }

    func alternativeCandidates(for request: AIRerankRequest, limit: Int) -> [SearchCandidate] {
        []
    }

    func selectCandidates(inputPat: String,
                          hiragana: String,
                          context: String?,
                          surfaces: [String],
                          limit: Int) -> [SearchCandidate] {
        []
    }
}

final class BundledZenzRuntime: ZenzRuntime {
    let identifier = "bundled-zenz-v3.1-xsmall"

    private let model: BundledAIRerankModel
    private let bundle: Bundle
    private let lock = NSLock()
    #if canImport(llama)
    private var context: LlamaZenzContext?
    #endif

    init(model: BundledAIRerankModel = .shared, bundle: Bundle = .main) {
        self.model = model
        self.bundle = bundle
    }

    func prepare() -> ZenzRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }

        guard model.loadIfAvailable(bundle: bundle), let url = model.modelURL else {
            return .unavailable("bundled GGUF model is not available")
        }

        #if canImport(llama)
        if context != nil { return .ready }
        do {
            context = try LlamaZenzContext(modelURL: url)
            return .ready
        } catch {
            Log.input.warning("llama.cpp context initialization failed: \(error.localizedDescription)")
            return .unavailable(error.localizedDescription)
        }
        #else
        return .ready
        #endif
    }

    func rerank(_ request: AIRerankRequest) -> AIRerankResponse? {
        #if canImport(llama)
        lock.lock()
        defer { lock.unlock() }
        let activeContext = context
        guard let activeContext else { return nil }

        if request.mode == "fast-context-rerank" {
            return fastContextReviewRerank(request, activeContext: activeContext)
        }

        let runtimeStart = CFAbsoluteTimeGetCurrent()
        Log.input.info("Zenz rerank start: input=\"\(request.inputPat)\" candidates=\(request.candidates.count)")
        let heuristic = AIReranker.localRerank(request, model: identifier)
        let prompt = Self.prompt(for: request)
        let zenzWeight = Self.scoreWeight()
        let maxScoredCandidates = Self.maxScoredCandidates()
        var scores: [String: Double] = [:]
        var anyRuntimeScore = false

        for candidate in request.candidates {
            let heuristicScore = heuristic.scores?[String(candidate.index)] ?? 0
            if Self.shouldScoreWithZenz(candidate, maxScoredCandidates: maxScoredCandidates),
               let zenzScore = activeContext.score(prompt: prompt, continuation: candidate.text) {
                anyRuntimeScore = true
                let combinedScore = heuristicScore + zenzScore * zenzWeight
                scores[String(candidate.index)] = combinedScore
                let scoreSummary = "heuristic=\(String(format: "%.4f", heuristicScore)) "
                    + "zenz=\(String(format: "%.4f", zenzScore)) "
                    + "combined=\(String(format: "%.4f", combinedScore))"
                Log.input.info("Zenz candidate score: input=\"\(request.inputPat)\" "
                    + "index=\(candidate.index) text=\"\(candidate.text)\" weight=\(String(format: "%.2f", zenzWeight)) \(scoreSummary)")
            } else {
                scores[String(candidate.index)] = heuristicScore
            }
        }
        guard anyRuntimeScore else {
            Log.input.warning("Zenz rerank unavailable: input=\"\(request.inputPat)\" reason=no-runtime-score")
            return nil
        }

        let order = request.candidates
            .sorted {
                let lhs = scores[String($0.index)] ?? 0
                let rhs = scores[String($1.index)] ?? 0
                if lhs == rhs { return $0.index < $1.index }
                return lhs > rhs
            }
            .map(\.index)
        let elapsed = (CFAbsoluteTimeGetCurrent() - runtimeStart) * 1000
        let scoredCount = request.candidates
            .filter { Self.shouldScoreWithZenz($0, maxScoredCandidates: maxScoredCandidates) }
            .count
        Log.input.info("Zenz rerank finished: input=\"\(request.inputPat)\" order=\(order) "
            + "scored=\(scoredCount)/\(request.candidates.count) "
            + "latency=\(String(format: "%.1f", elapsed))ms")
        return AIRerankResponse(order: order,
                                scores: scores,
                                model: "bundled-zenz-v3.1-xsmall+swift-local-heuristic")
        #else
        nil
        #endif
    }

    func generateCandidates(inputPat: String,
                            hiragana: String,
                            context requestContext: String?,
                            limit: Int) -> [SearchCandidate] {
        #if canImport(llama)
        let enabled = GyaimSettings.bool(forKey: "aiRerankUseZenzGeneration", default: true)
        guard limit > 0, enabled else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let activeContext = context else { return [] }

        let request = AIRerankRequest(version: 1,
                                      mode: "generate",
                                      inputPat: inputPat,
                                      hiragana: hiragana,
                                      context: requestContext,
                                      candidates: [])
        let prompt = Self.prompt(for: request)
        var seen = Set<String>()
        let generated = activeContext.generateAlternatives(prompt: prompt,
                                                           maxTokens: 12,
                                                           beamWidth: Self.generationBeamWidth(),
                                                           limit: limit)
        let candidates = generated.compactMap { text -> SearchCandidate? in
            guard let candidate = Self.cleanGeneratedCandidate(text, inputPat: inputPat),
                  seen.insert(candidate).inserted else { return nil }
            Log.input.info("Zenz generated candidate: input=\"\(inputPat)\" text=\"\(candidate)\"")
            return SearchCandidate(word: candidate,
                                   reading: inputPat,
                                   source: .synthetic,
                                   kind: .zenz)
        }
        return Array(candidates.prefix(limit))
        #else
        return []
        #endif
    }

    func selectCandidates(inputPat: String,
                          hiragana: String,
                          context requestContext: String?,
                          surfaces: [String],
                          limit: Int) -> [SearchCandidate] {
        #if canImport(llama)
        guard limit > 0, !surfaces.isEmpty,
              GyaimSettings.bool(forKey: "aiRerankUseZenzGeneration", default: true) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let activeContext = context else { return [] }

        let request = AIRerankRequest(version: 1,
                                      mode: "constrained-select",
                                      inputPat: inputPat,
                                      hiragana: hiragana,
                                      context: requestContext,
                                      candidates: [])
        let prompt = Self.prompt(for: request)
        let scoringBudget = Self.constrainedSelectionMaxSurfaces()
        if surfaces.count > scoringBudget {
            Log.input.info("Zenz constrained selection truncated: input=\"\(inputPat)\" "
                + "surfaces=\(surfaces.count) budget=\(scoringBudget)")
        }
        var scored: [(surface: String, score: Double)] = []
        for surface in surfaces.prefix(scoringBudget) {
            guard let score = activeContext.score(prompt: prompt, continuation: surface) else { continue }
            scored.append((surface, score))
            Log.input.info("Zenz constrained score: input=\"\(inputPat)\" "
                + "surface=\"\(surface)\" score=\(String(format: "%.4f", score))")
        }
        return Self.rankConstrainedSurfaces(scored).prefix(limit).map { surface in
            SearchCandidate(word: surface,
                            reading: inputPat,
                            source: .connection,
                            kind: .zenz)
        }
        #else
        return []
        #endif
    }

    /// Pure ranking for dictionary-constrained selection: highest conditional
    /// mean log probability first; ties keep the dictionary enumeration order.
    static func rankConstrainedSurfaces(_ scored: [(surface: String, score: Double)]) -> [String] {
        scored.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.score == rhs.element.score { return lhs.offset < rhs.offset }
                return lhs.element.score > rhs.element.score
            }
            .map(\.element.surface)
    }

    private static func constrainedSelectionMaxSurfaces() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankConstrainedSelectionMaxSurfaces")
        return configured > 0 ? min(configured, 24) : 12
    }

    func alternativeCandidates(for request: AIRerankRequest, limit: Int) -> [SearchCandidate] {
        #if canImport(llama)
        guard limit > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let activeContext = context else { return [] }
        let prompt = Self.prompt(for: request)
        let localOrder = AIReranker.localRerank(request, model: identifier).order
        let candidatesByIndex = Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.index, $0) })
        var seen = Set(request.candidates.map(\.text))
        var alternatives: [SearchCandidate] = []

        for index in localOrder where alternatives.count < limit {
            guard let candidate = candidatesByIndex[index], candidate.kind != CandidateKind.raw.rawValue,
                  let evaluation = activeContext.evaluateCandidate(prompt: prompt,
                                                                   candidateText: candidate.text,
                                                                   alternativeLimit: 2) else { continue }
            if let fixed = evaluation.fixRequiredPrefix,
               appendAlternative(fixed,
                                 base: candidate,
                                 inputPat: request.inputPat,
                                 seen: &seen,
                                 alternatives: &alternatives) {
                break
            }
            for alternative in evaluation.alternatives where alternative.probabilityRatio > 0.25 && alternatives.count < limit {
                _ = appendAlternative(alternative.prefix,
                                      base: candidate,
                                      inputPat: request.inputPat,
                                      seen: &seen,
                                      alternatives: &alternatives)
            }
        }
        return alternatives
        #else
        return []
        #endif
    }

    #if canImport(llama)
    private func fastContextReviewRerank(_ request: AIRerankRequest,
                                         activeContext: LlamaZenzContext) -> AIRerankResponse? {
        let runtimeStart = CFAbsoluteTimeGetCurrent()
        let heuristic = AIReranker.localRerank(request, model: identifier)
        let localOrder = AIReranker.validatedOrder(heuristic.order, candidateCount: request.candidates.count)
        guard let bestIndex = localOrder.first,
              let best = request.candidates.first(where: { $0.index == bestIndex }) else {
            return heuristic
        }

        // Fast-context mode is latency-sensitive. Protect the strongest exact-reading
        // decision and avoid evaluating every candidate. This mirrors Zenzai's
        // review-style use: inspect the current best candidate once, then optionally
        // convert the model's preferred prefix into an existing candidate order.
        //
        // Exception: exact-reading homophones such as "向き" / "無機" are already
        // safe from prefix-prediction demotion. When left context exists, compare the
        // exact-reading homophones directly by conditional log probability and move
        // only another exact-reading homophone to the top. This keeps exact
        // protection while enabling context-sensitive homophone choice.
        if Self.isProtectedExactReadingCandidate(best, request: request) {
            if Self.shouldReviewExactHomophones(best: best, request: request, localOrder: localOrder) {
                return exactHomophoneReviewRerank(request,
                                                  activeContext: activeContext,
                                                  heuristic: heuristic,
                                                  localOrder: localOrder,
                                                  best: best,
                                                  runtimeStart: runtimeStart)
            }
            Log.input.info("Zenz fast-context review skipped: input=\"\(request.inputPat)\" "
                + "reason=protected-exact best=\"\(best.text)\"")
            return AIRerankResponse(order: localOrder,
                                    scores: heuristic.scores,
                                    model: "swift-local-heuristic+zenz-review-skipped")
        }

        // Normal (non-homophone) review needs longer input to act: dogfood
        // 2026-07-08 showed 81 reviews at input length 4 with 0 fixes (57
        // kept-local / 24 passed), while all observed review-fixed value
        // started at length 5. Homophone review stays at the global model
        // gate (length 4) where its fix rate is ~30%.
        guard Self.shouldRunNormalReview(inputPat: request.inputPat,
                                         minimumLength: Self.normalReviewMinInputLength()) else {
            Log.input.info("Zenz fast-context review skipped: input=\"\(request.inputPat)\" "
                + "reason=short-input best=\"\(best.text)\"")
            return AIRerankResponse(order: localOrder,
                                    scores: heuristic.scores,
                                    model: "swift-local-heuristic+zenz-review-length-skipped")
        }

        let prompt = Self.prompt(for: request)
        Log.input.info("Zenz fast-context review start: input=\"\(request.inputPat)\" "
            + "best=\"\(best.text)\" candidates=\(request.candidates.count)")
        var failureReason = "unknown"
        guard let evaluation = activeContext.evaluateCandidate(prompt: prompt,
                                                              candidateText: best.text,
                                                              alternativeLimit: 0,
                                                              failureReason: { failureReason = $0 }) else {
            Log.input.warning("Zenz fast-context review unavailable: input=\"\(request.inputPat)\" "
                + "reason=\(failureReason) best=\"\(best.text)\"")
            return AIRerankResponse(order: localOrder,
                                    scores: heuristic.scores,
                                    model: "bundled-zenz-v3.1-xsmall-review-unavailable+swift-local-heuristic")
        }

        var order = localOrder
        var outcome = "passed"
        if let prefix = evaluation.fixRequiredPrefix,
           let replacement = Self.fastContextReplacementIndex(forFixRequiredPrefix: prefix,
                                                              localOrder: localOrder,
                                                              request: request) {
            outcome = "fixed"
            order.removeAll { $0 == replacement }
            order.insert(replacement, at: 0)
            Log.input.info("Zenz fast-context review fixed: input=\"\(request.inputPat)\" "
                + "prefix=\"\(prefix)\" replacementIndex=\(replacement)")
        } else if let prefix = evaluation.fixRequiredPrefix {
            outcome = "kept-local"
            Log.input.info("Zenz fast-context review kept local order: input=\"\(request.inputPat)\" "
                + "unmatchedPrefix=\"\(prefix)\"")
        } else {
            Log.input.info("Zenz fast-context review passed: input=\"\(request.inputPat)\" best=\"\(best.text)\"")
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - runtimeStart) * 1000
        Log.input.info("Zenz fast-context review finished: input=\"\(request.inputPat)\" "
            + "outcome=\(outcome) order=\(order) latency=\(String(format: "%.1f", elapsed))ms")
        return AIRerankResponse(order: order,
                                scores: heuristic.scores,
                                model: "bundled-zenz-v3.1-xsmall-review-\(outcome)+swift-local-heuristic")
    }

    /// Compare exact-reading homophones directly by conditional mean log
    /// probability instead of routing through fixRequiredPrefix replacement.
    /// The scored set is restricted to protected exact-reading candidates, so
    /// prefix-prediction candidates can never be promoted here, and incomplete
    /// stems (e.g. "くださ" while "ください" exists) are excluded up front.
    private func exactHomophoneReviewRerank(_ request: AIRerankRequest,
                                            activeContext: LlamaZenzContext,
                                            heuristic: AIRerankResponse,
                                            localOrder: [Int],
                                            best: AIRerankCandidate,
                                            runtimeStart: CFAbsoluteTime) -> AIRerankResponse {
        // Strong ContextDict evidence means the user already chose this
        // homophone in this context — the model must not override a personal
        // choice, and skipping saves the review latency entirely.
        if Self.shouldSkipHomophoneReviewForAffinity(best: best,
                                                     threshold: Self.exactHomophoneAffinityThreshold()) {
            Log.input.info("Zenz exact-homophone review skipped: input=\"\(request.inputPat)\" "
                + "reason=context-affinity best=\"\(best.text)\" "
                + "affinity=\(String(format: "%.2f", best.contextAffinity ?? 0))")
            return AIRerankResponse(order: localOrder,
                                    scores: heuristic.scores,
                                    model: "swift-local-heuristic+zenz-review-affinity-skipped")
        }

        let indices = Self.exactHomophoneCandidateIndices(request: request,
                                                          localOrder: localOrder,
                                                          limit: Self.exactHomophoneMaxCandidates())
        guard indices.count >= 2, indices.contains(best.index) else {
            // All alternatives were filtered as unsafe stems — nothing to compare.
            Log.input.info("Zenz fast-context review skipped: input=\"\(request.inputPat)\" "
                + "reason=protected-exact best=\"\(best.text)\"")
            return AIRerankResponse(order: localOrder,
                                    scores: heuristic.scores,
                                    model: "swift-local-heuristic+zenz-review-skipped")
        }

        let prompt = Self.prompt(for: request)
        Log.input.info("Zenz exact-homophone review start: input=\"\(request.inputPat)\" "
            + "best=\"\(best.text)\" indices=\(indices)")
        var scores: [Int: Double] = [:]
        for index in indices {
            guard let candidate = request.candidates.first(where: { $0.index == index }),
                  let score = activeContext.score(prompt: prompt, continuation: candidate.text) else { continue }
            scores[index] = score
            Log.input.info("Zenz exact-homophone score: input=\"\(request.inputPat)\" "
                + "index=\(index) text=\"\(candidate.text)\" score=\(String(format: "%.4f", score))")
        }

        var order = localOrder
        let outcome: String
        if scores[best.index] == nil || scores.count < 2 {
            outcome = "unavailable"
            Log.input.warning("Zenz exact-homophone review unavailable: input=\"\(request.inputPat)\" "
                + "reason=too-few-scores scored=\(scores.count)/\(indices.count)")
        } else if let replacement = Self.selectExactHomophoneWinner(scores: scores,
                                                                    currentBest: best.index,
                                                                    margin: Self.exactHomophoneScoreMargin(),
                                                                    affinities: Self.contextAffinities(of: request)) {
            outcome = "fixed"
            order.removeAll { $0 == replacement }
            order.insert(replacement, at: 0)
            Log.input.info("Zenz exact-homophone review fixed: input=\"\(request.inputPat)\" "
                + "replacementIndex=\(replacement)")
        } else if Self.maxScoreIndex(scores) != best.index {
            outcome = "kept-local"
        } else {
            outcome = "passed"
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - runtimeStart) * 1000
        Log.input.info("Zenz fast-context review finished: input=\"\(request.inputPat)\" "
            + "outcome=exact-homophone-\(outcome) order=\(order) latency=\(String(format: "%.1f", elapsed))ms")
        return AIRerankResponse(order: order,
                                scores: heuristic.scores,
                                model: "bundled-zenz-v3.1-xsmall-review-exact-homophone-\(outcome)+swift-local-heuristic")
    }
    #endif

    private func appendAlternative(_ prefix: String,
                                   base: AIRerankCandidate,
                                   inputPat: String,
                                   seen: inout Set<String>,
                                   alternatives: inout [SearchCandidate]) -> Bool {
        guard let cleaned = Self.cleanGeneratedCandidate(prefix, inputPat: inputPat),
              seen.insert(cleaned).inserted else { return false }
        Log.input.info("Zenz alternative constraint: input=\"\(inputPat)\" base=\"\(base.text)\" prefix=\"\(cleaned)\"")
        alternatives.append(SearchCandidate(word: cleaned,
                                            reading: inputPat,
                                            source: .synthetic,
                                            kind: .zenz))
        return true
    }

    static func prompt(for request: AIRerankRequest) -> String {
        var prompt = ""
        if let context = request.context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
            prompt += ZenzPrompt.contextTag + context
        }
        prompt += ZenzPrompt.inputTag + inputForZenz(request)
        prompt += ZenzPrompt.outputTag
        return prompt
    }

    private static func cleanGeneratedCandidate(_ text: String, inputPat: String) -> String? {
        let stopTags = [ZenzPrompt.inputTag, ZenzPrompt.outputTag, ZenzPrompt.contextTag]
        var candidate = text
        for tag in stopTags {
            if let range = candidate.range(of: tag) {
                candidate = String(candidate[..<range.lowerBound])
            }
        }
        candidate = candidate.components(separatedBy: .newlines).first ?? candidate
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate != inputPat,
              candidate.count <= 16,
              candidate.contains(where: isJapaneseLike),
              candidate.allSatisfy(isAllowedGeneratedCharacter) else {
            return nil
        }
        return candidate
    }

    private static func isJapaneseLike(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            0x3040...0x309F ~= scalar.value
                || 0x30A0...0x30FF ~= scalar.value
                || 0x4E00...0x9FFF ~= scalar.value
        }
    }

    private static func isAllowedGeneratedCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x4E00...0x9FFF,
                 0x3005...0x3007, 0x30FC, 0xFF10...0xFF19,
                 0xFF21...0xFF3A, 0xFF41...0xFF5A:
                return true
            default:
                return false
            }
        }
    }

    private static func inputForZenz(_ request: AIRerankRequest) -> String {
        let katakana = RomaKana().roma2katakana(request.inputPat)
        if !katakana.isEmpty { return katakana }
        return hiraganaToKatakana(request.hiragana)
    }

    private static func hiraganaToKatakana(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar in
            if 0x3041...0x3096 ~= scalar.value,
               let converted = UnicodeScalar(scalar.value + 0x60) {
                return Character(converted)
            }
            return Character(scalar)
        })
    }

    private static func scoreWeight() -> Double {
        let configured = GyaimSettings.double(forKey: "aiRerankZenzWeight")
        return configured > 0 ? configured : 0.30
    }

    private static func generationBeamWidth() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankZenzGenerationBeamWidth")
        return configured > 0 ? min(configured, 6) : 1
    }

    private static func maxScoredCandidates() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankZenzMaxCandidates")
        return configured > 0 ? configured : 8
    }

    private static func shouldScoreWithZenz(_ candidate: AIRerankCandidate,
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
            result.append(index)
        }
        return result
    }

    private static func isHiraganaOnlyText(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            0x3041...0x3096 ~= scalar.value || scalar.value == 0x30FC
        }
    }

    private static func isIncompleteStemCandidate(_ candidate: AIRerankCandidate,
                                                  in request: AIRerankRequest) -> Bool {
        guard AIReranker.isPotentialIncompleteStem(candidate.text) else { return false }
        return request.candidates.contains { other in
            other.index != candidate.index
                && AIReranker.isIncompleteStemCompletion(stem: candidate.text, completed: other.text)
        }
    }

    /// A learned context preference raises the log-probability bar the model
    /// must clear to override it: dogfood 2026-07-14 showed the model
    /// demoting the user's own choices (使用 over learned 仕様) when the
    /// context matched only partially (affinity below the 0.75 skip
    /// threshold). One affinity point is worth this many mean-logprob units.
    static let affinityMarginWeight = 2.0

    /// Picks the homophone to promote: the highest-scoring candidate wins only
    /// when it beats the current best by at least `margin` (mean log-probability
    /// units) plus the current best's context-affinity advantage, so model
    /// noise cannot flap the top candidate and cannot override what the user
    /// already taught the IME in this context.
    static func selectExactHomophoneWinner(scores: [Int: Double],
                                           currentBest: Int,
                                           margin: Double,
                                           affinities: [Int: Double] = [:]) -> Int? {
        guard let bestScore = scores[currentBest] else { return nil }
        var winnerIndex = currentBest
        var winnerScore = bestScore
        for (index, score) in scores.sorted(by: { $0.key < $1.key }) where score > winnerScore {
            winnerIndex = index
            winnerScore = score
        }
        guard winnerIndex != currentBest else { return nil }
        let affinityAdvantage = max(0, (affinities[currentBest] ?? 0) - (affinities[winnerIndex] ?? 0))
        let requiredMargin = margin + affinityAdvantage * affinityMarginWeight
        guard winnerScore - bestScore >= requiredMargin else { return nil }
        return winnerIndex
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

    private static func maxScoreIndex(_ scores: [Int: Double]) -> Int? {
        scores.sorted { $0.key < $1.key }.max { $0.value < $1.value }?.key
    }

    static func shouldRunNormalReview(inputPat: String, minimumLength: Int) -> Bool {
        inputPat.count >= minimumLength
    }

    private static func normalReviewMinInputLength() -> Int {
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

    private static func exactHomophoneAffinityThreshold() -> Double {
        let configured = GyaimSettings.double(forKey: "aiRerankExactHomophoneAffinityThreshold")
        return configured > 0 ? min(configured, 1.0) : 0.75
    }

    private static func exactHomophoneScoreMargin() -> Double {
        let configured = GyaimSettings.double(forKey: "aiRerankExactHomophoneMargin")
        return configured > 0 ? configured : 0.10
    }

    private static func exactHomophoneMaxCandidates() -> Int {
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

    private static func hasContext(_ context: String?) -> Bool {
        guard let context else { return false }
        return !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isProtectedExactReadingCandidate(_ candidate: AIRerankCandidate,
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
}
