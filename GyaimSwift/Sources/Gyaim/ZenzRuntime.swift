import Foundation

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
/// `BundledZenzRuntime` currently prepares the model file by memory-mapping it.
/// The scoring method intentionally returns nil until llama.cpp token inference
/// is connected; callers then fall back to Swift heuristic scoring while keeping
/// the model resident.
protocol ZenzRuntime {
    var identifier: String { get }
    func prepare() -> ZenzRuntimeStatus
    func rerank(_ request: AIRerankRequest) -> AIRerankResponse?
}

final class BundledZenzRuntime: ZenzRuntime {
    let identifier = "bundled-zenz-v3.1-xsmall"

    private let model: BundledAIRerankModel
    private let bundle: Bundle

    init(model: BundledAIRerankModel = .shared, bundle: Bundle = .main) {
        self.model = model
        self.bundle = bundle
    }

    func prepare() -> ZenzRuntimeStatus {
        model.loadIfAvailable(bundle: bundle)
            ? .ready
            : .unavailable("bundled GGUF model is not available")
    }

    func rerank(_ request: AIRerankRequest) -> AIRerankResponse? {
        // llama.cpp token inference will be wired here. Returning nil keeps the
        // current behavior explicit: the backend is available/resident, but
        // scoring still falls through to Swift heuristic for now.
        nil
    }
}
