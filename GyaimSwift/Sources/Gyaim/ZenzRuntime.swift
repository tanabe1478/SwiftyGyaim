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

        let heuristic = AIReranker.localRerank(request, model: identifier)
        let prompt = Self.prompt(for: request)
        var scores: [String: Double] = [:]
        var anyRuntimeScore = false

        for candidate in request.candidates {
            let heuristicScore = heuristic.scores?[String(candidate.index)] ?? 0
            if let zenzScore = activeContext.score(prompt: prompt, continuation: candidate.text) {
                anyRuntimeScore = true
                scores[String(candidate.index)] = heuristicScore + zenzScore * 0.08
            } else {
                scores[String(candidate.index)] = heuristicScore
            }
        }
        guard anyRuntimeScore else { return nil }

        let order = request.candidates
            .sorted {
                let lhs = scores[String($0.index)] ?? 0
                let rhs = scores[String($1.index)] ?? 0
                if lhs == rhs { return $0.index < $1.index }
                return lhs > rhs
            }
            .map(\.index)
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
}
