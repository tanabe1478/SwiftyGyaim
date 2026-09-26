@testable import Gyaim
import XCTest

#if canImport(llama)
/// Batched and one-by-one candidate scoring on the bundled model.
final class LlamaScoringBenchmarkTests: XCTestCase {
    /// scoreBatch must give the same mean logprobs as score (one llama_decode
    /// for all continuations instead of one per continuation).
    func testBatchScoresMatchOneByOneScores() throws {
        guard let url = BundledAIRerankModel.resolveModelURL(bundle: Bundle(for: Self.self)),
              let sequential = try? LlamaZenzContext(modelURL: url),
              let batched = try? LlamaZenzContext(modelURL: url) else {
            throw XCTSkip("bundled model or llama context unavailable")
        }
        let prompt = "\u{EE02}家に帰る前に設定を\u{EE00}カエル\u{EE01}"
        let words = ["帰る", "変える", "カエル", "蛙", "かえる"]  // single- and multi-token continuations
        let scores = batched.scoreBatch(prompt: prompt, continuations: words)
        for (word, score) in zip(words, scores) {
            let reference = try XCTUnwrap(sequential.score(prompt: prompt, continuation: word))
            // Batch size changes kernel rounding: <=2e-3 on Metal, up to ~0.08 on the
            // CPU backend (CI) even for one-token words scored from the prompt's
            // last logits alone. Homophone margins start at 0.10.
            XCTAssertEqual(try XCTUnwrap(score), reference, accuracy: 0.1, word)
        }
        XCTAssertEqual(batched.scoreBatch(prompt: prompt, continuations: words), scores, "cached on second call")
    }

    /// Timing only; runs with GYAIM_LLAMA_BENCH=1.
    func testSequentialScoringCost() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GYAIM_LLAMA_BENCH"] == "1")
        let url = try XCTUnwrap(BundledAIRerankModel.resolveModelURL(bundle: Bundle(for: Self.self)))
        let context = try LlamaZenzContext(modelURL: url)
        let words = ["帰る", "買える", "カエル", "換える", "返る", "蛙", "替える", "変える", "交える", "代える",
                     "飼える", "かえる", "帰るな", "返るな", "帰れる", "変えるな", "替えるな", "換えるな",
                     "返れる", "変えれる", "替えれる", "換えれる", "飼えるな", "買えるな"]
        for round in 0..<3 {
            let prompt = "\u{EE02}ログの形式を\(round)\u{EE00}カエル\u{EE01}"
            let start = CFAbsoluteTimeGetCurrent()
            var times: [Double] = []
            for word in words {
                let t0 = CFAbsoluteTimeGetCurrent()
                _ = context.score(prompt: prompt, continuation: word)
                times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            let total = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print(String(format: "bench round=%d total=%.1fms first=%.1fms rest-mean=%.1fms", round, total,
                         times[0], times.dropFirst().reduce(0, +) / Double(times.count - 1)))
        }
        // Batched scoring on a fresh context (no score cache) must match one-by-one scoring.
        let batched = try LlamaZenzContext(modelURL: url)
        for count in [6, 24] {
            let prompt = "\u{EE02}ログの形式を\(count)\u{EE00}カエル\u{EE01}"
            let subset = Array(words.prefix(count))
            let start = CFAbsoluteTimeGetCurrent()
            let scores = batched.scoreBatch(prompt: prompt, continuations: subset)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let reference = subset.map { context.score(prompt: prompt, continuation: $0) }
            for (lhs, rhs) in zip(scores, reference) {
                XCTAssertEqual(try XCTUnwrap(lhs), try XCTUnwrap(rhs), accuracy: 5e-3)  // batch kernels round differently
            }
            print(String(format: "bench batch count=%d total=%.1fms vocab=%d", count, elapsed, batched.vocabSize))
        }
    }
}
#endif
