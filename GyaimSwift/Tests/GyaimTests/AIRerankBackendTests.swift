@testable import Gyaim
import XCTest

private struct StubAIRerankBackend: AIRerankBackend {
    let identifier: String
    let runnable: Bool

    func canRun() -> Bool { runnable }

    func rerank(_ request: AIRerankRequest) -> AIRerankResponse {
        AIReranker.localRerank(request, model: identifier)
    }
}

final class AIRerankBackendTests: XCTestCase {
    func testInProcessRerankerUsesFirstRunnableBackend() {
        let request = makeRequest()
        let reranker = InProcessAIReranker(backends: [
            StubAIRerankBackend(identifier: "unavailable", runnable: false),
            StubAIRerankBackend(identifier: "selected", runnable: true),
            StubAIRerankBackend(identifier: "unused", runnable: true)
        ])

        XCTAssertEqual(reranker.rerank(request).model, "selected")
    }

    func testHeuristicBackendIsAlwaysRunnable() {
        let backend = HeuristicAIRerankBackend()
        XCTAssertTrue(backend.canRun())
        XCTAssertEqual(backend.rerank(makeRequest()).model, "swift-local-heuristic")
    }

    private func makeRequest() -> AIRerankRequest {
        AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "henkan",
            hiragana: "へんかん",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "henkan",
                                  reading: "henkan",
                                  source: "synthetic",
                                  kind: "raw"),
                AIRerankCandidate(index: 1,
                                  text: "変換",
                                  reading: "henkan",
                                  source: "connection",
                                  kind: "exact")
            ]
        )
    }
}
