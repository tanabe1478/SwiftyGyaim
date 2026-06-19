import Foundation

/// Backend interface for in-process reranking.
///
/// This keeps `GyaimController` independent from the concrete implementation:
/// the default path is the Swift heuristic, while the bundled Zenz/GGUF backend
/// can optionally add in-process llama.cpp scoring and fall back to the heuristic
/// when the model or runtime score is unavailable.
protocol AIRerankBackend {
    var identifier: String { get }
    func canRun() -> Bool
    func rerank(_ request: AIRerankRequest) -> AIRerankResponse
}

protocol AICandidateGenerationBackend {
    func generateCandidates(inputPat: String, hiragana: String, context: String?, limit: Int) -> [SearchCandidate]
    func alternativeCandidates(for request: AIRerankRequest, limit: Int) -> [SearchCandidate]
}

struct HeuristicAIRerankBackend: AIRerankBackend {
    let identifier = "swift-local-heuristic"

    func canRun() -> Bool { true }

    func rerank(_ request: AIRerankRequest) -> AIRerankResponse {
        AIReranker.localRerank(request, model: identifier)
    }
}

final class BundledZenzAIRerankBackend: AIRerankBackend, AICandidateGenerationBackend {
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
        let enabled = GyaimSettings.bool(forKey: Self.enabledDefaultsKey, default: true)
        return enabled && runtime.prepare().isReady
    }

    func rerank(_ request: AIRerankRequest) -> AIRerankResponse {
        runtime.rerank(request) ?? AIReranker.localRerank(request, model: identifier)
    }

    func generateCandidates(inputPat: String,
                            hiragana: String,
                            context: String?,
                            limit: Int) -> [SearchCandidate] {
        guard canRun() else { return [] }
        return runtime.generateCandidates(inputPat: inputPat,
                                          hiragana: hiragana,
                                          context: context,
                                          limit: limit)
    }

    func alternativeCandidates(for request: AIRerankRequest, limit: Int) -> [SearchCandidate] {
        guard canRun() else { return [] }
        return runtime.alternativeCandidates(for: request, limit: limit)
    }
}
