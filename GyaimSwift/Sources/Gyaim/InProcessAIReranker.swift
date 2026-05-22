import Foundation

/// First-choice reranker that runs inside the IME process.
///
/// It tries backends in priority order. The bundled Zenz/GGUF backend currently
/// validates and keeps the model resident, then uses Swift heuristic scoring;
/// the backend boundary is where llama.cpp token inference will be connected.
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
}
