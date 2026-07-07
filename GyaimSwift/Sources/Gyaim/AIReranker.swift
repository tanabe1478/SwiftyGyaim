import Foundation

struct AIRerankCandidate: Codable, Equatable {
    let index: Int
    let text: String
    let reading: String?
    let source: String
    let kind: String
    /// Context-conditioned learning score (0.0...1.0) from ContextDict.
    /// Nil / 0 means no history evidence for this (context, reading, word).
    let contextAffinity: Double?
    /// Study-dict frequency for study-sourced candidates. Nil for other sources.
    let studyFrequency: Int?

    init(index: Int,
         text: String,
         reading: String?,
         source: String,
         kind: String,
         contextAffinity: Double? = nil,
         studyFrequency: Int? = nil) {
        self.index = index
        self.text = text
        self.reading = reading
        self.source = source
        self.kind = kind
        self.contextAffinity = contextAffinity
        self.studyFrequency = studyFrequency
    }
}

struct AIRerankRequest: Codable, Equatable {
    let version: Int
    let mode: String
    let inputPat: String
    let hiragana: String
    let context: String?
    let candidates: [AIRerankCandidate]
}

struct AIRerankResponse: Codable, Equatable {
    let order: [Int]
    let scores: [String: Double]?
    let model: String?
}

struct AIRerankScoreBreakdown: Equatable {
    let total: Double
    let contributions: [String: Double]
}

enum AIReranker {
    static func validatedOrder(_ proposedOrder: [Int], candidateCount: Int) -> [Int] {
        guard candidateCount > 0 else { return [] }

        var seen = Set<Int>()
        var result: [Int] = []
        for index in proposedOrder where index >= 0 && index < candidateCount && !seen.contains(index) {
            seen.insert(index)
            result.append(index)
        }
        for index in 0..<candidateCount where !seen.contains(index) {
            result.append(index)
        }
        return result
    }

    static func apply(order proposedOrder: [Int], to candidates: [SearchCandidate]) -> [SearchCandidate] {
        validatedOrder(proposedOrder, candidateCount: candidates.count).map { candidates[$0] }
    }

    static func localRerank(_ request: AIRerankRequest,
                            model: String = "swift-local-heuristic") -> AIRerankResponse {
        var scores: [String: Double] = [:]
        let scored = request.candidates.map { candidate in
            let score = localScore(candidate: candidate, request: request)
            scores[String(candidate.index)] = score
            return (index: candidate.index, score: score)
        }
        let order = scored
            .sorted {
                if $0.score == $1.score { return $0.index < $1.index }
                return $0.score > $1.score
            }
            .map(\.index)
        return AIRerankResponse(order: order, scores: scores, model: model)
    }

    static func localScoreBreakdown(candidate: AIRerankCandidate, request: AIRerankRequest) -> AIRerankScoreBreakdown {
        var contributions: [String: Double] = [
            "positionPenalty": -Double(candidate.index) * 0.03,
            "sourceBias": sourceBias(candidate.source),
            "kindBias": kindBias(candidate.kind)
        ]
        if isExactReadingMatch(candidate: candidate, request: request) {
            contributions["exactReadingMatchBonus"] = 0.20
            if candidate.kind == CandidateKind.exact.rawValue {
                contributions["exactReadingKindBonus"] = exactReadingBonus(candidate.text)
            }
        } else {
            contributions["prefixPredictionPenalty"] = -prefixPredictionPenalty(candidate: candidate,
                                                                                 inputPat: request.inputPat)
        }
        contributions["contextPredictionBonus"] = contextPredictionBonus(candidate: candidate, request: request)
        if let affinity = candidate.contextAffinity, affinity > 0 {
            contributions["contextAffinityBonus"] = min(affinity, 1.0) * 1.50
        }
        if candidate.source == "study", let frequency = candidate.studyFrequency, frequency > 1 {
            // Cap at 0.60 so a heavily used homophone (更新 freq 101) can beat a
            // rarely used one (行進 freq 11) even when both are exact-reading
            // study entries — 0.30 saturated at freq 8 and made them tie (BUG-026).
            contributions["studyFrequencyBonus"] = min(0.60, log2(Double(frequency)) * 0.10)
        }
        contributions["politeNegativePredictionPenalty"] = -politeNegativePredictionPenalty(candidate: candidate,
                                                                                             request: request)
        if candidate.text.contains(where: isKanji) {
            contributions["kanjiBonus"] = 0.10
        }
        contributions["naturalFunctionWordPhraseBonus"] = naturalFunctionWordPhraseBonus(candidate.text)
        contributions["punctuationSuffixPenalty"] = -punctuationSuffixPenalty(candidate.text)
        contributions["punctuatedInputMismatchPenalty"] = -punctuatedInputMismatchPenalty(candidate: candidate,
                                                                                         request: request)
        contributions["incompleteStemPenalty"] = -incompleteStemPenalty(candidate: candidate,
                                                                        request: request)
        if candidate.kind == CandidateKind.zenz.rawValue && isAllKanjiWord(candidate.text) {
            contributions["zenzKanjiBonus"] = 0.50
        }
        if candidate.text == request.inputPat && candidate.text.allSatisfy(\.isASCII) {
            contributions["rawAsciiPenalty"] = -8.0
        }
        contributions["scriptTransitionPenalty"] = -unnaturalScriptTransitionPenalty(candidate.text)
        let nonZero = contributions.filter { $0.value != 0 }
        return AIRerankScoreBreakdown(total: nonZero.values.reduce(0, +), contributions: nonZero)
    }

    private static func localScore(candidate: AIRerankCandidate, request: AIRerankRequest) -> Double {
        localScoreBreakdown(candidate: candidate, request: request).total
    }

    /// Exact reading match includes romaji spelling variants of the same kana:
    /// WordSearch assigns `kind=exact` when the candidate reading is
    /// kana-equivalent to the query (e.g. study "kousinn" for typed "kousin",
    /// BUG-026), so a dictionary-derived exact kind with a reading is trusted
    /// here. External candidates also carry `kind=exact` but have no reading.
    static func isExactReadingMatch(candidate: AIRerankCandidate, request: AIRerankRequest) -> Bool {
        if candidate.reading == request.inputPat { return true }
        return candidate.kind == CandidateKind.exact.rawValue && candidate.reading != nil
    }

    private static func exactReadingBonus(_ text: String) -> Double {
        text.count >= 5 ? 2.00 : 0.50
    }

    private static func prefixPredictionPenalty(candidate: AIRerankCandidate, inputPat: String) -> Double {
        guard candidate.kind == CandidateKind.prefix.rawValue,
              let reading = candidate.reading,
              reading.hasPrefix(inputPat),
              reading != inputPat else { return 0 }
        return min(1.50, Double(reading.count - inputPat.count) * 0.35)
    }

    private static func contextPredictionBonus(candidate: AIRerankCandidate, request: AIRerankRequest) -> Double {
        guard candidate.kind == CandidateKind.prefix.rawValue,
              let reading = candidate.reading,
              reading.hasPrefix(request.inputPat),
              reading != request.inputPat,
              let context = request.context else { return 0 }

        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var score = 0.0
        if candidate.text.hasSuffix("な"), hasStrongNegativeImperativeCue(trimmed) {
            score += 2.00
        }
        return score
    }

    private static func hasStrongNegativeImperativeCue(_ context: String) -> Bool {
        ["決して", "絶対に", "してはいけ", "してはなら", "禁止", "だめ", "ダメ", "ないで"].contains { context.contains($0) }
    }

    private static func politeNegativePredictionPenalty(candidate: AIRerankCandidate, request: AIRerankRequest) -> Double {
        guard isPoliteNegativePrediction(candidate.text), !inputExplicitlyRequestsPoliteNegative(request.inputPat) else {
            return 0
        }
        if let context = request.context,
           hasPoliteNegativeContextCue(context.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return 0
        }
        return 4.00
    }

    private static func isPoliteNegativePrediction(_ text: String) -> Bool {
        text.hasSuffix("ません") || text.hasSuffix("ませんか") || text.hasSuffix("ません？") || text.hasSuffix("ませんか？")
    }

    private static func inputExplicitlyRequestsPoliteNegative(_ inputPat: String) -> Bool {
        inputPat.contains("masen") || inputPat.contains("masenn")
    }

    private static func hasPoliteNegativeContextCue(_ context: String) -> Bool {
        guard !context.isEmpty else { return false }
        return ["ない", "ません", "ではなく", "じゃなく", "しない", "できない", "不要", "禁止"].contains { context.contains($0) }
    }

    private static func naturalFunctionWordPhraseBonus(_ text: String) -> Double {
        var score = 0.0
        if text.range(of: #"[一-龯]の[一-龯]"#, options: .regularExpression) != nil {
            score += 1.40
        }
        if text.hasSuffix("では") || text.hasSuffix("には") || text.hasSuffix("とは") {
            score += 0.70
        }
        return score
    }

    private static func punctuationSuffixPenalty(_ text: String) -> Double {
        text.hasSuffix("？") || text.hasSuffix("！") ? 0.10 : 0.0
    }

    private static func punctuatedInputMismatchPenalty(candidate: AIRerankCandidate,
                                                       request: AIRerankRequest) -> Double {
        let expectedPunctuation: [Character]
        if request.inputPat.hasSuffix("?") {
            expectedPunctuation = ["?", "？"]
        } else if request.inputPat.hasSuffix("!") {
            expectedPunctuation = ["!", "！"]
        } else {
            return 0
        }
        guard !candidate.text.contains(where: { expectedPunctuation.contains($0) }) else { return 0 }
        return 3.00
    }

    private static func incompleteStemPenalty(candidate: AIRerankCandidate,
                                              request: AIRerankRequest) -> Double {
        guard isPotentialIncompleteStem(candidate.text) else { return 0 }
        let longerCompletedCandidateExists = request.candidates.contains { other in
            other.index != candidate.index && isIncompleteStemCompletion(stem: candidate.text, completed: other.text)
        }
        return longerCompletedCandidateExists ? 4.00 : 0
    }

    static func isPotentialIncompleteStem(_ text: String) -> Bool {
        guard !text.isEmpty, !text.allSatisfy(isKanji) else { return false }
        return text.unicodeScalars.contains { 0x3041...0x3096 ~= $0.value }
    }

    /// True when `completed` is `stem` plus exactly one character and the pair
    /// looks like a mid-conjugation truncation:
    /// - "少な" → "少ない" (i-adjective missing the final い)
    /// - "使っ" → "使った" / "言っ" → "言って" (no Japanese word ends with っ)
    ///
    /// A stem that already ends with い is NOT missing its い — the premise of
    /// the い rule doesn't apply. Without this guard, a garbage study entry
    /// like "してほしいい" made the legitimate "してほしい" look like an
    /// incomplete stem and demoted it (BUG-025).
    static func isIncompleteStemCompletion(stem: String, completed: String) -> Bool {
        guard completed != stem,
              completed.hasPrefix(stem),
              completed.dropFirst(stem.count).count == 1 else { return false }
        if completed.last == "い", stem.last != "い" { return true }
        if stem.last == "っ" { return true }
        return false
    }

    private static func sourceBias(_ source: String) -> Double {
        switch source {
        case "study": return 0.40
        case "local": return 0.30
        case "connection": return 0.10
        case "google": return 0.60
        case "external": return -0.10
        case "synthetic": return -0.30
        default: return 0.0
        }
    }

    private static func kindBias(_ kind: String) -> Double {
        switch kind {
        case "google": return 0.35
        case "exact": return 0.25
        case "zenz": return 0.40
        case "lattice": return 0.30
        case "compound": return 0.20
        case "prefix": return -0.10
        case "completion": return -0.20
        case "kana": return -0.25
        case "raw": return -1.00
        default: return 0.0
        }
    }

    private static func unnaturalScriptTransitionPenalty(_ text: String) -> Double {
        let chars = Array(text)
        guard chars.count >= 2 else { return 0 }
        var penalty = 0.0
        for index in 1..<chars.count {
            if isHiragana(chars[index - 1]) && isKanji(chars[index]) {
                penalty += 1.50
            }
            if isKatakana(chars[index - 1]) && isHiragana(chars[index]) {
                penalty += 1.00
            }
        }
        return penalty
    }

    private static func isHiragana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { 0x3040...0x309F ~= $0.value }
    }

    private static func isKatakana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { 0x30A0...0x30FF ~= $0.value }
    }

    private static func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { 0x4E00...0x9FFF ~= $0.value }
    }

    private static func isAllKanjiWord(_ text: String) -> Bool {
        text.count >= 2 && text.allSatisfy(isKanji)
    }
}

final class HTTPAIReranker {
    static let serverURLDefaultsKey = "aiRerankServerURL"
    static let timeoutDefaultsKey = "aiRerankHTTPTimeoutMs"
    static let serverURLEnvironmentKey = "GYAIM_AI_RERANK_SERVER"

    private let url: URL
    private let timeoutMs: Int

    init(url: URL, timeoutMs: Int = 1200) {
        self.url = url
        self.timeoutMs = timeoutMs
    }

    static func configured() -> HTTPAIReranker? {
        let envURL = ProcessInfo.processInfo.environment[serverURLEnvironmentKey]
        let defaultsURL = GyaimSettings.string(forKey: serverURLDefaultsKey)
        guard let value = envURL ?? defaultsURL,
              let url = URL(string: value),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let configuredTimeout = GyaimSettings.integer(forKey: timeoutDefaultsKey)
        let timeout = configuredTimeout > 0 ? configuredTimeout : 1200
        return HTTPAIReranker(url: url, timeoutMs: timeout)
    }

    func rerank(_ request: AIRerankRequest, completion: @escaping (Result<AIRerankResponse, Error>) -> Void) {
        do {
            let body = try JSONEncoder().encode(request)
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = body
            urlRequest.timeoutInterval = Double(timeoutMs) / 1000.0
            urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

            URLSession.shared.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    completion(.failure(NSError(domain: "HTTPAIReranker",
                                                code: http.statusCode,
                                                userInfo: [NSLocalizedDescriptionKey: "AI reranker HTTP status \(http.statusCode)"])))
                    return
                }
                guard let data else {
                    completion(.failure(NSError(domain: "HTTPAIReranker",
                                                code: -1,
                                                userInfo: [NSLocalizedDescriptionKey: "AI reranker returned no data"])))
                    return
                }
                do {
                    completion(.success(try JSONDecoder().decode(AIRerankResponse.self, from: data)))
                } catch {
                    completion(.failure(error))
                }
            }.resume()
        } catch {
            completion(.failure(error))
        }
    }
}

final class ExternalCommandAIReranker {
    static let commandDefaultsKey = "aiRerankCommand"
    static let timeoutDefaultsKey = "aiRerankTimeoutMs"
    static let commandEnvironmentKey = "GYAIM_AI_RERANK_COMMAND"

    private let command: String
    private let timeoutMs: Int
    private let queue = DispatchQueue(label: "com.pitecan.inputmethod.SwiftyGyaim.ai-reranker")

    init(command: String, timeoutMs: Int = 800) {
        self.command = command
        self.timeoutMs = timeoutMs
    }

    static func configured() -> ExternalCommandAIReranker? {
        let envCommand = ProcessInfo.processInfo.environment[commandEnvironmentKey]
        let defaultsCommand = GyaimSettings.string(forKey: commandDefaultsKey)
        guard let command = envCommand ?? defaultsCommand,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let configuredTimeout = GyaimSettings.integer(forKey: timeoutDefaultsKey)
        let timeout = configuredTimeout > 0 ? configuredTimeout : 800
        return ExternalCommandAIReranker(command: command, timeoutMs: timeout)
    }

    func rerank(_ request: AIRerankRequest, completion: @escaping (Result<AIRerankResponse, Error>) -> Void) {
        queue.async { [command, timeoutMs] in
            do {
                let response = try Self.run(command: command, timeoutMs: timeoutMs, request: request)
                completion(.success(response))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func run(command: String, timeoutMs: Int, request: AIRerankRequest) throws -> AIRerankResponse {
        let input = try JSONEncoder().encode(request)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()

        let killer = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: killer)
        process.waitUntilExit()
        killer.cancel()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw NSError(domain: "ExternalCommandAIReranker",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "AI reranker failed: \(stderrText)"])
        }

        return try JSONDecoder().decode(AIRerankResponse.self, from: stdoutData)
    }
}
