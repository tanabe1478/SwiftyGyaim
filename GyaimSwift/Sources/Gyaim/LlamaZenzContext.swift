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
    private let evalSeqId: llama_seq_id = 0
    private var previousTokensBySeq: [llama_seq_id: [llama_token]] = [:]

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

    func score(prompt: String, continuation: String) -> Double? {
        let promptTokens = encode(prompt, addBOS: true)
        let continuationTokens = encode(continuation, addBOS: false)
        guard !promptTokens.isEmpty, !continuationTokens.isEmpty else { return nil }

        let tokens = promptTokens + continuationTokens
        let startOffset = max(0, promptTokens.count - 1)
        guard let logits = logits(tokens: tokens, startOffset: startOffset, seqId: evalSeqId) else {
            return nil
        }

        let vocabCount = vocabSize
        var logProbability = 0.0
        for (tokenIndex, tokenID) in tokens.enumerated().dropFirst(promptTokens.count) {
            let startIndex = (tokenIndex - 1 - startOffset) * vocabCount
            let logsumexp = logSumExp(logits: logits, startIndex: startIndex, count: vocabCount)
            logProbability += Double(logits[startIndex + Int(tokenID)] - logsumexp)
        }
        return logProbability / Double(continuationTokens.count)
    }

    private func encode(_ text: String, addBOS: Bool) -> [llama_token] {
        tokenize(text: preprocess(text), addBOS: addBOS)
    }

    private func preprocess(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{3000}")
            .replacingOccurrences(of: "\n", with: "")
    }

    private func tokenize(text: String, addBOS: Bool) -> [llama_token] {
        let utf8Count = text.utf8.count
        let capacity = max(1, utf8Count + (addBOS ? 1 : 0))
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: capacity)
        defer { tokens.deallocate() }

        let tokenCount = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(capacity), addBOS, false)
        if tokenCount < 0 {
            let requiredCapacity = Int(-tokenCount)
            let retryTokens = UnsafeMutablePointer<llama_token>.allocate(capacity: requiredCapacity)
            defer { retryTokens.deallocate() }
            let retryCount = llama_tokenize(vocab, text, Int32(utf8Count), retryTokens, Int32(requiredCapacity), addBOS, false)
            guard retryCount > 0 else { return [] }
            return (0..<retryCount).map { retryTokens[Int($0)] }
        }
        return (0..<tokenCount).map { tokens[Int($0)] }
    }

    private func logits(tokens: [llama_token], startOffset: Int, seqId: llama_seq_id) -> UnsafeMutablePointer<Float>? {
        let previousTokens = previousTokensBySeq[seqId] ?? []
        let commonPrefixCount = min(commonPrefix(previousTokens, tokens), startOffset)
        llama_kv_cache_seq_rm(context, seqId, llama_pos(commonPrefixCount), -1)

        var batch = llama_batch_init(512, 0, 1)
        defer { llama_batch_free(batch) }

        for tokenIndex in tokens.indices.dropFirst(commonPrefixCount) {
            add(&batch,
                token: tokens[tokenIndex],
                position: llama_pos(tokenIndex),
                seqIds: [seqId],
                includeLogits: startOffset <= tokenIndex)
        }

        guard llama_decode(context, batch) == 0 else { return nil }
        previousTokensBySeq[seqId] = tokens
        return llama_get_logits(context)
    }

    private func add(_ batch: inout llama_batch,
                     token: llama_token,
                     position: llama_pos,
                     seqIds: [llama_seq_id],
                     includeLogits: Bool) {
        let index = Int(batch.n_tokens)
        batch.token[index] = token
        batch.pos[index] = position
        batch.n_seq_id[index] = Int32(seqIds.count)
        for seqIndex in seqIds.indices {
            batch.seq_id[index]![seqIndex] = seqIds[seqIndex]
        }
        batch.logits[index] = includeLogits ? 1 : 0
        batch.n_tokens += 1
    }

    private func logSumExp(logits: UnsafeMutablePointer<Float>, startIndex: Int, count: Int) -> Float {
        var maxLogit = -Float.infinity
        for index in startIndex..<(startIndex + count) {
            maxLogit = max(maxLogit, logits[index])
        }
        var sum: Float = 0
        for index in startIndex..<(startIndex + count) {
            sum += expf(logits[index] - maxLogit)
        }
        return maxLogit + logf(sum)
    }

    private func commonPrefix(_ lhs: [llama_token], _ rhs: [llama_token]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }
}
#endif
