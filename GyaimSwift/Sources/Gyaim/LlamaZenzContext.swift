import Foundation

#if canImport(llama)
import llama

enum LlamaZenzContextError: LocalizedError {
    case couldNotLoadModel(path: String)
    case couldNotLoadContext
    case couldNotLoadVocab

    var errorDescription: String? {
        switch self {
        case .couldNotLoadModel(let path): return "could not load GGUF model at \(path)"
        case .couldNotLoadContext: return "could not create llama.cpp context"
        case .couldNotLoadVocab: return "could not load llama.cpp vocab"
        }
    }
}

/// Thin llama.cpp holder for the bundled Zenz GGUF model.
///
/// This mirrors the loading strategy used by AzooKeyKanaKanjiConverter:
/// `llama_backend_init`, `llama_model_load_from_file(use_mmap: true)`,
/// `llama_init_from_model`, then keep model/context/vocab resident.
final class LlamaZenzContext {
    private var model: OpaquePointer
    private var context: OpaquePointer
    private var vocab: OpaquePointer

    init(modelURL: URL) throws {
        llama_backend_init()

        var modelParameters = llama_model_default_params()
        modelParameters.use_mmap = true

        let path: String
        if #available(macOS 13, *) {
            path = modelURL.path(percentEncoded: false)
        } else {
            path = modelURL.path
        }

        guard let loadedModel = llama_model_load_from_file(path, modelParameters) else {
            llama_backend_free()
            throw LlamaZenzContextError.couldNotLoadModel(path: path)
        }

        var contextParameters = llama_context_default_params()
        let threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        contextParameters.n_ctx = 512
        contextParameters.n_batch = 512
        contextParameters.n_threads = Int32(threads)
        contextParameters.n_threads_batch = Int32(threads)

        guard let loadedContext = llama_init_from_model(loadedModel, contextParameters) else {
            llama_model_free(loadedModel)
            llama_backend_free()
            throw LlamaZenzContextError.couldNotLoadContext
        }

        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            llama_backend_free()
            throw LlamaZenzContextError.couldNotLoadVocab
        }

        self.model = loadedModel
        self.context = loadedContext
        self.vocab = loadedVocab
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
        llama_backend_free()
    }

    var vocabSize: Int {
        Int(llama_vocab_n_tokens(vocab))
    }
}
#endif
