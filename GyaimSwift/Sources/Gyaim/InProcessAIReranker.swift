import Foundation

/// First-choice reranker that runs inside the IME process.
///
/// It tries backends in priority order. The bundled Zenz/GGUF backend keeps the
/// model resident and, when llama.cpp is available, adds token-level Zenz scores
/// to the Swift heuristic. If the model cannot run or produces no score, the
/// heuristic backend remains the fallback.
final class InProcessAIReranker {
    static let shared = InProcessAIReranker()

    private let backends: [AIRerankBackend]

    convenience init(model: BundledAIRerankModel = .shared, bundle: Bundle = .main) {
        self.init(backends: [
            BundledZenzAIRerankBackend(model: model, bundle: bundle),
            HeuristicAIRerankBackend()
        ])
    }

    init(backends: [AIRerankBackend]) {
        precondition(!backends.isEmpty, "InProcessAIReranker requires at least one backend")
        self.backends = backends
    }

    func rerank(_ request: AIRerankRequest) -> AIRerankResponse {
        let backend = backends.first { $0.canRun() } ?? HeuristicAIRerankBackend()
        let start = CFAbsoluteTimeGetCurrent()
        Log.input.info("AI rerank backend selected: provider=in-process backend=\(backend.identifier) candidates=\(request.candidates.count)")
        let response = backend.rerank(request)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        Log.input.info("AI rerank backend finished: provider=in-process backend=\(backend.identifier) model=\(response.model ?? "unknown") latency=\(String(format: "%.1f", elapsed))ms")
        return response
    }

    func generateCandidates(inputPat: String,
                            hiragana: String,
                            context: String?,
                            limit: Int = 1) -> [SearchCandidate] {
        for backend in backends {
            guard let generator = backend as? AICandidateGenerationBackend else { continue }
            let candidates = generator.generateCandidates(inputPat: inputPat,
                                                          hiragana: hiragana,
                                                          context: context,
                                                          limit: limit)
            if !candidates.isEmpty { return candidates }
        }
        return []
    }

    func alternativeCandidates(for request: AIRerankRequest, limit: Int = 2) -> [SearchCandidate] {
        for backend in backends {
            guard let generator = backend as? AICandidateGenerationBackend else { continue }
            let candidates = generator.alternativeCandidates(for: request, limit: limit)
            if !candidates.isEmpty { return candidates }
        }
        return []
    }
}
