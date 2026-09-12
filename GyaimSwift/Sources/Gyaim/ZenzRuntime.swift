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
}

final class BundledZenzRuntime: ZenzRuntime {
    var identifier: String { BundledAIRerankModel.activeModelLabel }

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

        var zenzScores: [Int: Double] = [:]
        for candidate in request.candidates {
            if Self.shouldScoreWithZenz(candidate, maxScoredCandidates: maxScoredCandidates),
               let zenzScore = activeContext.score(prompt: prompt, continuation: candidate.text) {
                anyRuntimeScore = true
                zenzScores[candidate.index] = zenzScore
            }
        }
        var heuristicScores: [Int: Double] = [:]
        for candidate in request.candidates {
            heuristicScores[candidate.index] = heuristic.scores?[String(candidate.index)] ?? 0
        }
        let combined = Self.combineScores(heuristic: heuristicScores,
                                          zenz: zenzScores,
                                          weight: zenzWeight)
        for candidate in request.candidates {
            let combinedScore = combined[candidate.index] ?? 0
            scores[String(candidate.index)] = combinedScore
            if let zenzScore = zenzScores[candidate.index] {
                Log.input.info("Zenz candidate score: input=\"\(request.inputPat)\" "
                    + "index=\(candidate.index) text=\"\(candidate.text)\" "
                    + "weight=\(String(format: "%.2f", zenzWeight)) "
                    + "heuristic=\(String(format: "%.4f", heuristicScores[candidate.index] ?? 0)) "
                    + "zenz=\(String(format: "%.4f", zenzScore)) "
                    + "combined=\(String(format: "%.4f", combinedScore))")
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
                                model: "\(BundledAIRerankModel.activeModelLabel)+swift-local-heuristic")
        #else
        nil
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

        return normalReviewRerank(request, activeContext: activeContext, heuristic: heuristic,
                                  best: best, runtimeStart: runtimeStart)
    }

    private func normalReviewRerank(_ request: AIRerankRequest, activeContext: LlamaZenzContext,
                                    heuristic: AIRerankResponse, best: AIRerankCandidate,
                                    runtimeStart: CFAbsoluteTime) -> AIRerankResponse {
        let localOrder = heuristic.order
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
            return Self.normalReviewResponse(order: localOrder, scores: heuristic.scores,
                                              outcome: "unavailable", reviewedIndex: best.index)
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
        return Self.normalReviewResponse(order: order, scores: heuristic.scores, outcome: outcome, reviewedIndex: best.index)
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
                  let score = activeContext.score(prompt: prompt, continuation: candidate.text), score.isFinite else { continue }
            scores[index] = score
            Log.input.debug("Zenz exact-homophone score: input=\"\(request.inputPat)\" "
                + "index=\(index) text=\"\(candidate.text)\" score=\(String(format: "%.4f", score))")
        }

        let response = Self.homophoneResponse(request: request, heuristic: heuristic,
                                              indices: indices, scores: scores)
        let elapsed = (CFAbsoluteTimeGetCurrent() - runtimeStart) * 1000
        Log.input.info("Zenz fast-context review finished: input=\"\(request.inputPat)\" "
            + "outcome=\(GyaimController.fastContextRerankOutcome(model: response.model ?? "unknown")) "
            + "order=\(response.order) latency=\(String(format: "%.1f", elapsed))ms")
        return response
    }
    #endif
}
