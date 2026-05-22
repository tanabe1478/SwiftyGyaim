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
        #if canImport(llama)
        lock.lock()
        defer { lock.unlock() }
        let activeContext = context
        guard let activeContext else { return nil }

        let runtimeStart = CFAbsoluteTimeGetCurrent()
        Log.input.info("Zenz rerank start: input=\"\(request.inputPat)\" candidates=\(request.candidates.count)")
        let heuristic = AIReranker.localRerank(request, model: identifier)
        let prompt = Self.prompt(for: request)
        let zenzWeight = Self.scoreWeight()
        let maxScoredCandidates = Self.maxScoredCandidates()
        var scores: [String: Double] = [:]
        var anyRuntimeScore = false

        for candidate in request.candidates {
            let heuristicScore = heuristic.scores?[String(candidate.index)] ?? 0
            if Self.shouldScoreWithZenz(candidate, maxScoredCandidates: maxScoredCandidates),
               let zenzScore = activeContext.score(prompt: prompt, continuation: candidate.text) {
                anyRuntimeScore = true
                let combinedScore = heuristicScore + zenzScore * zenzWeight
                scores[String(candidate.index)] = combinedScore
                let scoreSummary = "heuristic=\(String(format: "%.4f", heuristicScore)) "
                    + "zenz=\(String(format: "%.4f", zenzScore)) "
                    + "combined=\(String(format: "%.4f", combinedScore))"
                Log.input.info("Zenz candidate score: input=\"\(request.inputPat)\" "
                    + "index=\(candidate.index) text=\"\(candidate.text)\" weight=\(String(format: "%.2f", zenzWeight)) \(scoreSummary)")
            } else {
                scores[String(candidate.index)] = heuristicScore
            }
        }
        guard anyRuntimeScore else {
            Log.input.warning("Zenz rerank unavailable: input=\"\(request.inputPat)\" reason=no-runtime-score")
            return nil
        }

        let order = request.candidates
            .sorted {
                let lhs = scores[String($0.index)] ?? 0
                let rhs = scores[String($1.index)] ?? 0
                if lhs == rhs { return $0.index < $1.index }
                return lhs > rhs
            }
            .map(\.index)
        let elapsed = (CFAbsoluteTimeGetCurrent() - runtimeStart) * 1000
        let scoredCount = request.candidates
            .filter { Self.shouldScoreWithZenz($0, maxScoredCandidates: maxScoredCandidates) }
            .count
        Log.input.info("Zenz rerank finished: input=\"\(request.inputPat)\" order=\(order) "
            + "scored=\(scoredCount)/\(request.candidates.count) "
            + "latency=\(String(format: "%.1f", elapsed))ms")
        return AIRerankResponse(order: order,
                                scores: scores,
                                model: "bundled-zenz-v3.1-xsmall+swift-local-heuristic")
        #else
        nil
        #endif
    }

    static func prompt(for request: AIRerankRequest) -> String {
        var prompt = ""
        if let context = request.context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
            prompt += ZenzPrompt.contextTag + context
        }
        prompt += ZenzPrompt.inputTag + inputForZenz(request)
        prompt += ZenzPrompt.outputTag
        return prompt
    }

    private static func inputForZenz(_ request: AIRerankRequest) -> String {
        let katakana = RomaKana().roma2katakana(request.inputPat)
        if !katakana.isEmpty { return katakana }
        return hiraganaToKatakana(request.hiragana)
    }

    private static func hiraganaToKatakana(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar in
            if 0x3041...0x3096 ~= scalar.value,
               let converted = UnicodeScalar(scalar.value + 0x60) {
                return Character(converted)
            }
            return Character(scalar)
        })
    }

    private static func scoreWeight() -> Double {
        let configured = UserDefaults.standard.double(forKey: "aiRerankZenzWeight")
        return configured > 0 ? configured : 0.30
    }

    private static func maxScoredCandidates() -> Int {
        let configured = UserDefaults.standard.integer(forKey: "aiRerankZenzMaxCandidates")
        return configured > 0 ? configured : 8
    }

    private static func shouldScoreWithZenz(_ candidate: AIRerankCandidate,
                                            maxScoredCandidates: Int) -> Bool {
        candidate.index < maxScoredCandidates && candidate.kind != CandidateKind.raw.rawValue
    }
}
