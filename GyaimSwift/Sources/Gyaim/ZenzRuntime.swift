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
}

extension ZenzRuntime {
    func generateCandidates(inputPat: String, hiragana: String, context: String?, limit: Int) -> [SearchCandidate] {
        []
    }

    func alternativeCandidates(for request: AIRerankRequest, limit: Int) -> [SearchCandidate] {
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
        // safe from prefix-prediction demotion. When left context exists, allow Zenz
        // to review the current best and move only another exact-reading homophone to
        // the top. This keeps exact protection while enabling context-sensitive
        // homophone choice.
        let shouldReviewExactHomophones = Self.shouldReviewExactHomophones(best: best,
                                                                            request: request,
                                                                            localOrder: localOrder)
        if Self.isProtectedExactReadingCandidate(best, request: request), !shouldReviewExactHomophones {
            Log.input.info("Zenz fast-context review skipped: input=\"\(request.inputPat)\" "
                + "reason=protected-exact best=\"\(best.text)\"")
            return AIRerankResponse(order: localOrder,
                                    scores: heuristic.scores,
                                    model: "swift-local-heuristic+zenz-review-skipped")
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
            let outcome = shouldReviewExactHomophones ? "exact-homophone-unavailable" : "unavailable"
            return AIRerankResponse(order: localOrder,
                                    scores: heuristic.scores,
                                    model: "bundled-zenz-v3.1-xsmall-review-\(outcome)+swift-local-heuristic")
        }

        var order = localOrder
        var outcome = "passed"
        if let prefix = evaluation.fixRequiredPrefix,
           let replacement = Self.fastContextReplacementIndex(forFixRequiredPrefix: prefix,
                                                              localOrder: localOrder,
                                                              request: request,
                                                              restrictToExactReading: shouldReviewExactHomophones) {
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

        if shouldReviewExactHomophones {
            outcome = "exact-homophone-\(outcome)"
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - runtimeStart) * 1000
        Log.input.info("Zenz fast-context review finished: input=\"\(request.inputPat)\" "
            + "outcome=\(outcome) order=\(order) latency=\(String(format: "%.1f", elapsed))ms")
        return AIRerankResponse(order: order,
                                scores: heuristic.scores,
                                model: "bundled-zenz-v3.1-xsmall-review-\(outcome)+swift-local-heuristic")
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
                                            request: AIRerankRequest,
                                            restrictToExactReading: Bool = false) -> Int? {
        let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let minimumPrefixLength = restrictToExactReading ? 1 : 2
        guard normalizedPrefix.count >= minimumPrefixLength,
              let currentBest = localOrder.first,
              let currentBestCandidate = request.candidates.first(where: { $0.index == currentBest }) else { return nil }
        return localOrder.first { index in
            guard index != currentBest,
                  let candidate = request.candidates.first(where: { $0.index == index }) else { return false }
            if restrictToExactReading {
                guard isProtectedExactReadingCandidate(candidate, request: request),
                      !isUnsafeExactHomophoneReplacement(from: currentBestCandidate, to: candidate),
                      !isUnsafeExactHomophoneReplacement(candidate, in: request) else {
                    return false
                }
            }
            return candidate.text.hasPrefix(normalizedPrefix)
        }
    }

    private static func isUnsafeExactHomophoneReplacement(from current: AIRerankCandidate,
                                                          to replacement: AIRerankCandidate) -> Bool {
        isIncompleteISuffixReplacement(stem: replacement.text, completed: current.text)
    }

    private static func isUnsafeExactHomophoneReplacement(_ replacement: AIRerankCandidate,
                                                          in request: AIRerankRequest) -> Bool {
        request.candidates.contains { candidate in
            candidate.index != replacement.index
                && isProtectedExactReadingCandidate(candidate, request: request)
                && isIncompleteISuffixReplacement(stem: replacement.text, completed: candidate.text)
        }
    }

    private static func isIncompleteISuffixReplacement(stem: String, completed: String) -> Bool {
        guard stem != completed,
              isPotentialIncompleteISuffixStem(stem),
              completed.hasPrefix(stem) else { return false }
        let suffix = completed.dropFirst(stem.count)
        return suffix.count == 1 && suffix.first == "い"
    }

    private static func isPotentialIncompleteISuffixStem(_ text: String) -> Bool {
        guard !text.isEmpty,
              !text.unicodeScalars.allSatisfy({ 0x4E00...0x9FFF ~= $0.value }) else { return false }
        return text.unicodeScalars.contains { 0x3041...0x3096 ~= $0.value }
    }

    private static func isAllHiragana(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            0x3041...0x3096 ~= scalar.value || scalar.value == 0x30FC
        }
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
        guard candidate.reading == request.inputPat else { return false }
        switch candidate.kind {
        case CandidateKind.exact.rawValue, CandidateKind.compound.rawValue:
            return true
        default:
            return false
        }
    }
}
