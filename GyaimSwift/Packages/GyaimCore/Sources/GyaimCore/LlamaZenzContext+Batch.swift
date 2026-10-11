import Foundation
#if canImport(llama)
import llama

extension LlamaZenzContext {
    /// scoreBatch gives continuation i its own sequence firstBatchSeqId + i
    /// (0 = eval, 1 = generation in LlamaZenzContext).
    private static let firstBatchSeqId: llama_seq_id = 2
    private static let maxBatchContinuations = 48
    private static let batchCapacity: Int32 = 512

    /// Same mean logprobs as `score` for several continuations of one prompt,
    /// with one llama_decode for all of them: each decode costs a fixed few ms
    /// on Metal regardless of its few tokens (24 homophones: ~65ms one by one,
    /// ~15ms batched, Release). The prompt is decoded or reused once; its last
    /// logits score every first token; each continuation's remaining tokens go
    /// into one batch on their own sequence sharing the prompt's KV cells.
    func scoreBatch(prompt: String, continuations: [String]) -> [Double?] {
        var results = continuations.map { scoreCache["\(prompt)\u{0}\($0)"] }
        let pending = continuations.indices.filter { results[$0] == nil }
        guard !pending.isEmpty else { return results }
        let promptTokens = encode(prompt, addBOS: true)
        let tokensByCandidate = pending.map { encode(continuations[$0], addBOS: false) }
        let extraTokens = tokensByCandidate.reduce(0) { $0 + max(0, $1.count - 1) }
        guard !promptTokens.isEmpty, pending.count <= Self.maxBatchContinuations,
              promptTokens.count + extraTokens < Int(Self.batchCapacity),
              let firstLogits = lastPromptLogits(promptTokens),
              let means = decodeContinuations(tokensByCandidate, promptCount: promptTokens.count,
                                              firstLogits: firstLogits) else {
            return continuations.map { score(prompt: prompt, continuation: $0) }
        }
        for (offset, candidateIndex) in pending.enumerated() {
            guard let mean = means[offset] else { continue }
            scoreCache["\(prompt)\u{0}\(continuations[candidateIndex])"] = mean
            results[candidateIndex] = mean
        }
        return results
    }

    /// Log-softmax at the prompt's last token (predicts every first token),
    /// copied because the next decode overwrites the logits buffer.
    private func lastPromptLogits(_ promptTokens: [llama_token]) -> [Float]? {
        guard let logits = logits(tokens: promptTokens, startOffset: promptTokens.count - 1, seqId: evalSeqId) else {
            return nil
        }
        let normalizer = logSumExp(logits: logits, startIndex: 0, count: vocabSize)
        return (0..<vocabSize).map { logits[$0] - normalizer }
    }

    private func decodeContinuations(_ tokensByCandidate: [[llama_token]], promptCount: Int,
                                     firstLogits: [Float]) -> [Double?]? {
        var batch = llama_batch_init(Self.batchCapacity, 0, 1)
        defer { llama_batch_free(batch) }
        var rowsByCandidate: [[Int32]] = []  // batch row whose logits predict token t + 1
        for (offset, tokens) in tokensByCandidate.enumerated() {
            let seqId = Self.firstBatchSeqId + llama_seq_id(offset)
            llama_kv_cache_seq_cp(context, evalSeqId, seqId, -1, -1)
            rowsByCandidate.append(tokens.dropLast().enumerated().map { position, token in
                defer { add(&batch, token: token, position: llama_pos(promptCount + position),
                            seqIds: [seqId], includeLogits: true) }
                return batch.n_tokens
            })
        }
        defer {
            for offset in tokensByCandidate.indices {
                llama_kv_cache_seq_rm(context, Self.firstBatchSeqId + llama_seq_id(offset), -1, -1)
            }
        }
        guard batch.n_tokens == 0 || llama_decode(context, batch) == 0 else { return nil }
        return zip(tokensByCandidate, rowsByCandidate).map { tokens, rows in
            guard let first = tokens.first else { return nil }
            var logProbability = Double(firstLogits[Int(first)])
            for (step, row) in rows.enumerated() {
                guard let rowLogits = llama_get_logits_ith(context, row) else { return nil }
                let normalizer = logSumExp(logits: rowLogits, startIndex: 0, count: vocabSize)
                logProbability += Double(rowLogits[Int(tokens[step + 1])] - normalizer)
            }
            return logProbability / Double(tokens.count)
        }
    }
}
#endif
