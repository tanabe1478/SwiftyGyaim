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
    private let generationSeqId: llama_seq_id = 1
    private var previousTokensBySeq: [llama_seq_id: [llama_token]] = [:]

    /// FIFO-bounded memo for deterministic model outputs. Fast-context reviews
    /// re-run for the same (context, input) on window redraws and backspace
    /// returns (dogfood 2026-07-05: identical reviews within 1s); the model is
    /// frozen so cached results never go stale. Access is serialized by
    /// BundledZenzRuntime's lock.
    private struct BoundedCache<Value> {
        private var storage: [String: Value] = [:]
        private var insertionOrder: [String] = []
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
        }

        subscript(key: String) -> Value? {
            get { storage[key] }
            set {
                guard let newValue else { return }
                if storage[key] == nil {
                    insertionOrder.append(key)
                    if insertionOrder.count > capacity {
                        storage.removeValue(forKey: insertionOrder.removeFirst())
                    }
                }
                storage[key] = newValue
            }
        }
    }

    private var scoreCache = BoundedCache<Double>(capacity: 256)
    private var evaluationCache = BoundedCache<CandidateEvaluation>(capacity: 256)

    private struct GenerationBeam {
        let tokens: [llama_token]
        let generated: [llama_token]
        let score: Float
        let finished: Bool
    }

    private struct TokenScore {
        let token: llama_token
        let score: Float
    }

    struct CandidateEvaluation {
        struct Alternative {
            let prefix: String
            let probabilityRatio: Float
        }

        let fixRequiredPrefix: String?
        let alternatives: [Alternative]
    }

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
        let cacheKey = "\(prompt)\u{0}\(continuation)"
        if let cached = scoreCache[cacheKey] { return cached }

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
        let meanLogProbability = logProbability / Double(continuationTokens.count)
        scoreCache[cacheKey] = meanLogProbability
        return meanLogProbability
    }

    func generate(prompt: String, maxTokens: Int) -> String? {
        generateAlternatives(prompt: prompt, maxTokens: maxTokens, beamWidth: 1, limit: 1).first
    }

    func generateAlternatives(prompt: String,
                              maxTokens: Int,
                              beamWidth: Int,
                              limit: Int) -> [String] {
        let promptTokens = encode(prompt, addBOS: true)
        guard !promptTokens.isEmpty, maxTokens > 0, beamWidth > 0, limit > 0 else { return [] }

        var beams = [GenerationBeam(tokens: promptTokens,
                                    generated: [],
                                    score: 0,
                                    finished: false)]
        for _ in 0..<maxTokens {
            var expanded: [GenerationBeam] = []
            for beam in beams {
                if beam.finished {
                    expanded.append(beam)
                    continue
                }
                let startOffset = max(0, beam.tokens.count - 1)
                guard let logits = logits(tokens: beam.tokens,
                                          startOffset: startOffset,
                                          seqId: generationSeqId) else {
                    continue
                }
                for next in topTokens(from: logits, limit: beamWidth) {
                    var tokens = beam.tokens
                    var generated = beam.generated
                    let finished = next.token == llama_vocab_eos(vocab)
                    tokens.append(next.token)
                    if !finished { generated.append(next.token) }
                    expanded.append(GenerationBeam(tokens: tokens,
                                                   generated: generated,
                                                   score: beam.score + next.score,
                                                   finished: finished))
                }
            }
            beams = Array(expanded.sorted { $0.score > $1.score }.prefix(beamWidth))
            if beams.allSatisfy(\.finished) { break }
        }

        var seen = Set<String>()
        return beams
            .sorted { $0.score > $1.score }
            .compactMap { beam -> String? in
                guard !beam.generated.isEmpty else { return nil }
                let text = beam.generated.compactMap(piece(for:)).joined()
                return seen.insert(text).inserted ? text : nil
            }
            .prefix(limit)
            .map { $0 }
    }

    func preferredPrefix(prompt: String, candidateText: String) -> String? {
        evaluateCandidate(prompt: prompt, candidateText: candidateText, alternativeLimit: 0)?.fixRequiredPrefix
    }

    func evaluateCandidate(prompt: String,
                           candidateText: String,
                           alternativeLimit: Int,
                           failureReason: ((String) -> Void)? = nil) -> CandidateEvaluation? {
        // Successful evaluations are deterministic; failures may be transient
        // (logits allocation), so only successes are cached.
        let cacheKey = "\(alternativeLimit)\u{0}\(prompt)\u{0}\(candidateText)"
        if let cached = evaluationCache[cacheKey] { return cached }

        func fail(_ reason: String) -> CandidateEvaluation? {
            failureReason?(reason)
            return nil
        }

        func succeed(_ evaluation: CandidateEvaluation) -> CandidateEvaluation {
            evaluationCache[cacheKey] = evaluation
            return evaluation
        }

        let promptTokens = encode(prompt, addBOS: true)
        let candidateTokens = encode(candidateText, addBOS: false)
        guard !promptTokens.isEmpty else { return fail("empty-prompt-tokens") }
        guard !candidateTokens.isEmpty else { return fail("empty-candidate-tokens") }
        let tokens = promptTokens + candidateTokens
        let startOffset = promptTokens.count - 1
        guard let logits = logits(tokens: tokens, startOffset: startOffset, seqId: generationSeqId) else {
            return fail("logits-unavailable")
        }
        let vocabCount = vocabSize
        let promptText = promptTokens.compactMap(piece(for:)).joined()
        var alternatives: [CandidateEvaluation.Alternative] = []

        for (tokenIndex, tokenID) in tokens.enumerated().dropFirst(promptTokens.count) {
            let startIndex = (tokenIndex - 1 - startOffset) * vocabCount
            let top = topTokens(from: logits.advanced(by: startIndex), limit: max(1, alternativeLimit + 1))
            guard let best = top.first else { return fail("empty-top-token-list") }
            if best.token != tokenID {
                // The model prefers to end the output here: the candidate is an
                // extension of a form the model already considers complete. This
                // is a judgment, not a failure — treating it as "unavailable"
                // wasted ~25ms per review and hid real failures (dogfood
                // 2026-07: 437/437 review-unavailable were best-token-is-eos).
                // Never promote a truncation from this signal; just pass.
                if best.token == llama_vocab_eos(vocab) {
                    return succeed(CandidateEvaluation(fixRequiredPrefix: nil,
                                                       alternatives: alternatives.sorted { $0.probabilityRatio > $1.probabilityRatio }))
                }
                guard let prefix = decodedCandidatePrefix(tokens: Array(tokens[..<tokenIndex]) + [best.token],
                                                          promptText: promptText) else {
                    return fail("decoded-prefix-mismatch")
                }
                return succeed(CandidateEvaluation(fixRequiredPrefix: prefix, alternatives: []))
            }

            for alternative in top.dropFirst().prefix(alternativeLimit) where alternative.token != llama_vocab_eos(vocab) {
                guard let prefix = decodedCandidatePrefix(tokens: Array(tokens[..<tokenIndex]) + [alternative.token],
                                                          promptText: promptText) else { continue }
                let ratio = expf(alternative.score - best.score)
                alternatives.append(CandidateEvaluation.Alternative(prefix: prefix, probabilityRatio: ratio))
            }
        }
        return succeed(CandidateEvaluation(fixRequiredPrefix: nil,
                                           alternatives: alternatives.sorted { $0.probabilityRatio > $1.probabilityRatio }))
    }

    private func decodedCandidatePrefix(tokens: [llama_token], promptText: String) -> String? {
        let text = tokens.compactMap(piece(for:)).joined()
        guard text.hasPrefix(promptText) else { return nil }
        return String(text.dropFirst(promptText.count))
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

    private func bestToken(logits: UnsafeMutablePointer<Float>, startIndex: Int, count: Int) -> llama_token {
        var best: llama_token = 0
        var bestLogit = -Float.infinity
        for index in 0..<count where logits[startIndex + index] > bestLogit {
            bestLogit = logits[startIndex + index]
            best = llama_token(index)
        }
        return best
    }

    private func greedyToken(from logits: UnsafeMutablePointer<Float>) -> llama_token {
        topTokens(from: logits, limit: 1).first?.token ?? 0
    }

    private func topTokens(from logits: UnsafeMutablePointer<Float>, limit: Int) -> [TokenScore] {
        var best: [TokenScore] = []
        for token in 0..<vocabSize {
            let tokenScore = TokenScore(token: llama_token(token), score: logits[token])
            best.append(tokenScore)
            best.sort { $0.score > $1.score }
            if best.count > limit { best.removeLast() }
        }
        return best
    }

    private func piece(for token: llama_token) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        let count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            var retry = [CChar](repeating: 0, count: Int(-count))
            let retryCount = llama_token_to_piece(vocab, token, &retry, Int32(retry.count), 0, false)
            guard retryCount > 0 else { return nil }
            return String(bytes: retry.prefix(Int(retryCount)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
        }
        guard count > 0 else { return nil }
        return String(bytes: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
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
