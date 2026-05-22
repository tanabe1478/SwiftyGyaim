import Foundation

/// First-choice reranker that runs inside the IME process.
///
/// Today it uses the Swift heuristic scorer while ensuring the bundled GGUF
/// model is resident. The type is intentionally separated from `GyaimController`
/// so the scoring backend can be replaced by llama.cpp token inference without
/// changing the IME input flow.
final class InProcessAIReranker {
    static let shared = InProcessAIReranker()

    private let model: BundledAIRerankModel
    private let bundle: Bundle

    init(model: BundledAIRerankModel = .shared, bundle: Bundle = .main) {
        self.model = model
        self.bundle = bundle
    }

    func rerank(_ request: AIRerankRequest) -> AIRerankResponse {
        let modelLoaded = model.loadIfAvailable(bundle: bundle)
        let modelName = modelLoaded
            ? "swift-local-heuristic+bundled-zenz-v3.1-xsmall-mapped"
            : "swift-local-heuristic"
        return AIReranker.localRerank(request, model: modelName)
    }
}
