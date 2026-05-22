import Foundation

struct AIRerankCandidate: Codable, Equatable {
    let index: Int
    let text: String
    let reading: String?
    let source: String
    let kind: String
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
        let defaultsURL = UserDefaults.standard.string(forKey: serverURLDefaultsKey)
        guard let value = envURL ?? defaultsURL,
              let url = URL(string: value),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let configuredTimeout = UserDefaults.standard.integer(forKey: timeoutDefaultsKey)
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
        let defaultsCommand = UserDefaults.standard.string(forKey: commandDefaultsKey)
        guard let command = envCommand ?? defaultsCommand,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let configuredTimeout = UserDefaults.standard.integer(forKey: timeoutDefaultsKey)
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
