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
    static let enabledDefaultsKey = "aiRerankUseBundledZenz"

    let identifier = "swift-local-heuristic+bundled-zenz-v3.1-xsmall-mapped"

    private let runtime: ZenzRuntime

    convenience init(model: BundledAIRerankModel = .shared, bundle: Bundle = .main) {
        self.init(runtime: BundledZenzRuntime(model: model, bundle: bundle))
    }

    init(runtime: ZenzRuntime) {
        self.runtime = runtime
    }

    func canRun() -> Bool {
        UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) && runtime.prepare().isReady
    }

    func rerank(_ request: AIRerankRequest) -> AIRerankResponse {
        runtime.rerank(request) ?? AIReranker.localRerank(request, model: identifier)
    }
}
