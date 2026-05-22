import Foundation

/// Backend interface for in-process reranking.
///
/// This keeps `GyaimController` independent from the concrete implementation:
/// the current backends still use Swift heuristic scoring, while a future
/// llama.cpp/GGUF backend can implement the same entry point.
protocol AIRerankBackend {
    var identifier: String { get }
    func canRun() -> Bool
    func rerank(_ request: AIRerankRequest) -> AIRerankResponse
}

struct HeuristicAIRerankBackend: AIRerankBackend {
    let identifier = "swift-local-heuristic"

    func canRun() -> Bool { true }

    func rerank(_ request: AIRerankRequest) -> AIRerankResponse {
        AIReranker.localRerank(request, model: identifier)
    }
}

final class BundledZenzAIRerankBackend: AIRerankBackend {
    let identifier = "swift-local-heuristic+bundled-zenz-v3.1-xsmall-mapped"

    private let model: BundledAIRerankModel
    private let bundle: Bundle

    init(model: BundledAIRerankModel = .shared, bundle: Bundle = .main) {
        self.model = model
        self.bundle = bundle
    }

    func canRun() -> Bool {
        model.loadIfAvailable(bundle: bundle)
    }

    func rerank(_ request: AIRerankRequest) -> AIRerankResponse {
        AIReranker.localRerank(request, model: identifier)
    }
}
