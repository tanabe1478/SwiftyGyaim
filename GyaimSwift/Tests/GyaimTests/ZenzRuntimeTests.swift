@testable import Gyaim
import XCTest

private struct StubZenzRuntime: ZenzRuntime {
    let identifier = "stub-zenz"
    let status: ZenzRuntimeStatus
    let response: AIRerankResponse?

    func prepare() -> ZenzRuntimeStatus { status }
    func rerank(_ request: AIRerankRequest) -> AIRerankResponse? { response }
}

final class ZenzRuntimeTests: XCTestCase {
    func testRuntimeStatusReadiness() {
        XCTAssertTrue(ZenzRuntimeStatus.ready.isReady)
        XCTAssertFalse(ZenzRuntimeStatus.unavailable("missing").isReady)
    }

    func testBundledZenzBackendUsesRuntimeResponseWhenAvailable() {
        let expected = AIRerankResponse(order: [1, 0], scores: ["1": 1.0], model: "stub-llama")
        let backend = BundledZenzAIRerankBackend(runtime: StubZenzRuntime(status: .ready, response: expected))

        XCTAssertEqual(backend.rerank(makeRequest()), expected)
    }

    func testBundledZenzBackendFallsBackToHeuristicWhenRuntimeDoesNotScoreYet() {
        let backend = BundledZenzAIRerankBackend(runtime: StubZenzRuntime(status: .ready, response: nil))
        let response = backend.rerank(makeRequest())

        XCTAssertEqual(response.order.first, 1)
        XCTAssertEqual(response.model, "swift-local-heuristic+bundled-zenz-v3.1-xsmall-mapped")
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
