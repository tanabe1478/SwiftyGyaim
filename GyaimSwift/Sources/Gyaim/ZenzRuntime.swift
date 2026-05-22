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
/// linked, creates a llama.cpp model/context/vocab in-process. Candidate scoring
/// still falls back to Swift heuristic until the prompt/evaluation logic is added.
protocol ZenzRuntime {
    var identifier: String { get }
    func prepare() -> ZenzRuntimeStatus
    func rerank(_ request: AIRerankRequest) -> AIRerankResponse?
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
        // Candidate scoring via llama.cpp will be added next. `prepare()` already
        // performs real model/context initialization when the llama module is linked,
        // so returning nil only means scoring is not wired yet.
        nil
    }
}
